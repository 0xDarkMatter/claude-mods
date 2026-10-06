#!/usr/bin/env bash
# sweep.sh — `fleet sweep`: the post-wave sweep. One ordered pass over a repo
# after a wave of chips, background agents or fleet lanes, turning the backlog
# into next actions: what landed (by ancestry OR by content), which lanes fight
# over the same files, which worktrees, branches, empty dirs and stashes are
# leftovers, and which finished sessions should be asked to archive themselves.
#
# CONTRACT
#   * Read-only by default. stdout is the data product (panel, --porcelain TSV,
#     or --json); progress and the ordered next steps go to stderr.
#   * It never reimplements the removal classifier. Worktree buckets come from
#     `fleet prune --porcelain`, and a worktree is only ever removed by
#     `fleet prune --remove`. The sweep adds evidence prune cannot see.
#   * --apply acts on ZERO-LOSS classes only, after a typed confirmation, each
#     re-verified immediately before it acts:
#       1. `git worktree prune`  - admin entries whose directory is already gone
#       2. merged, worktree-less, unheld local branches - every commit is already
#          in <base>; deleted with a compare-and-swap on the verified sha
#       3. empty, unregistered dirs under the worktree roots that no OPEN session
#          claims - `rmdir` refuses a non-empty dir by itself
#     It never removes a worktree, drops a stash, deletes an unmerged branch,
#     pushes, or messages a session.
#   * Resumable by construction: nothing is cached or journalled. Every verdict
#     is recomputed from git and the session store on each run, so after any one
#     step (a land, an archive, a removal) the next run shows exactly what is left.
#   * Messaging sessions is agent-only. ccd_session_mgmt is a Desktop MCP server
#     a script cannot call, so the sweep NAMES the sessions and the agent sends,
#     one gated call each (references/sweep.md has the protocol and template).
#
# SECTION MAP (grep the `=== NAME ===` banners):
#   ARGS          flags, env, --help
#   REPO          repo root, base branch, config via `fleet config`
#   HELPERS       path normalisation, landed-ness, never-push list
#   EVIDENCE      prune buckets, worktree facts, session claims
#   VERDICTS      phase 1 worktrees .. phase 5 sessions -> ROWS
#   OUTPUT        panel / porcelain / json, next steps, exit code
#   APPLY         the three zero-loss actions
#
# Exit codes: 0 nothing to act on · 10 findings (domain signal) · 1 an --apply
# step failed · 2 usage · 5 precondition (not a git repo, base missing, no jq
# for --json).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SH="$SCRIPT_DIR/fleet.sh"
SESSIONS_SH="$SCRIPT_DIR/sessions.sh"

# === ARGS =====================================================================
usage() {
  cat <<'EOF'
fleet sweep — post-wave housekeeping: landed? competing? leftovers? who is done?

USAGE
  fleet sweep                  Report, in phase order. Changes NOTHING. (default)
  fleet sweep --porcelain      TSV to stdout: phase, subject, verdict, detail, action
  fleet sweep --json           The same rows in a claude-mods JSON envelope (needs jq)
  fleet sweep --apply          Zero-loss actions only, after typing "apply"
  fleet sweep --apply --yes    Same, no prompt (you have read the report)
  fleet sweep --stale-days N   Age that makes a branch or stash stale (default 30)

PHASES (the order is the procedure; re-run after each step)
  1 worktree   every lane worktree, with prune's bucket and the next action
  2 compete    pairs of lanes touching the same non-ledger files
  3 branch     local branches with no worktree: merged, content-landed, stale
  4 hygiene    ghost admin entries, unregistered dirs, stashes
  5 session    finished sessions to ask to archive; hollow ones to archive

VERDICTS that need you (anything else is informational)
  REMOVE  LAND  REBASE  COMPETING  INSPECT  ASK-ARCHIVE  CONTENT-LANDED
  VERIFY-OWNER  FLEETFLOW  GHOST  OVERLAP  DELETE-MERGED  STALE  UNLANDED
  LEAKED  EMPTY-DIR  ORPHAN-DIR  HOLLOW  STALE-STASH  ARCHIVE-REQUEST
  ARCHIVE-DIRECT  SPINNING?  UNKNOWN

ENVIRONMENT
  FLEET_SWEEP_LEDGER     ERE of files that never count as competing (default:
                         CHANGELOG/README/AGENTS/CLAUDE.md, docs/PLAN.md, and
                         per-tree .claude/launch.json + settings.local.json)
  FLEET_SWEEP_KEEP       ERE of branch names --apply never deletes
                         (default: main master trunk develop dev staging
                          production release/* hotfix/*)
  FLEET_NEVER_PUSH       ';'-separated never-push list files. Default:
                         ~/.claude/never-push.txt and <git-dir>/info/never-push.
                         One glob per line, '#' comments. Keep it OUT of the repo.
  FLEET_SWEEP_STALE_DAYS default for --stale-days
  FLEET_SWEEP_MIN_DIR_AGE seconds an empty dir must be old before --apply
                         removes it (default 3600: it may be mid-creation)

EXAMPLES
  fleet sweep                              # what is left after the wave?
  fleet sweep --porcelain | awk -F'\t' '$3=="ASK-ARCHIVE"'
  fleet sweep --apply                      # zero-loss hygiene, typed confirm

EXIT
  0 nothing to act on (with --apply: every step it took succeeded)
  10 findings   1 an --apply step failed   2 usage
  5 precondition (not a git repo, base missing, --json without jq)
EOF
}

MODE=panel APPLY=0 YES=0
STALE_DAYS=${FLEET_SWEEP_STALE_DAYS:-30}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --porcelain)  MODE=porcelain; shift ;;
    --json)       MODE=json; shift ;;
    --apply)      APPLY=1; shift ;;
    --yes|-y)     YES=1; shift ;;
    --dry-run|-n) APPLY=0; shift ;;
    --stale-days)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "fleet sweep: --stale-days needs a whole number" >&2; exit 2; }
      STALE_DAYS=$2; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "fleet sweep: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$STALE_DAYS" =~ ^[0-9]+$ ]] || { echo "fleet sweep: FLEET_SWEEP_STALE_DAYS must be a whole number" >&2; exit 2; }
# Machine-readable modes are report-only, as in `fleet prune`: a mode a script
# can parse that could also delete is one typo away from an unattended sweep.
if [[ $APPLY -eq 1 && $MODE != panel ]]; then
  echo "fleet sweep: --porcelain/--json are report-only; drop --apply or drop them" >&2; exit 2
fi
if [[ $MODE == json ]] && ! command -v jq >/dev/null 2>&1; then
  printf '{"error":{"code":"PRECONDITION","message":"--json needs jq","details":{}}}\n'
  echo "fleet sweep: --json needs jq (install jq, or use --porcelain)" >&2; exit 5
fi

# Files that never make two lanes "competing": shared ledgers every lane appends
# to (they conflict trivially and are resolved at land time), and per-tree local
# config a tool drops into every worktree. Without the second half, three old
# trees each holding an untracked .claude/launch.json read as a 3-way contest.
LEDGER=${FLEET_SWEEP_LEDGER:-'^(CHANGELOG|README|AGENTS|CLAUDE)\.md$|^docs/PLAN\.md$|^\.claude/(launch\.json|settings\.local\.json)$'}
KEEP_RE=${FLEET_SWEEP_KEEP:-'^(main|master|trunk|develop|dev|staging|production|release/.*|hotfix/.*)$'}
MIN_DIR_AGE=${FLEET_SWEEP_MIN_DIR_AGE:-3600}
NOW=$(date +%s)

# === REPO =====================================================================
# Git's own path form (X:/a/b on Windows). A shell path and a git path are
# different strings there, and comparing them raw never matches — the failure
# that silently disarmed prune's invoked-from guard until a test caught it.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else printf '%s' "$1"; fi
}
# Comparison form: forward slashes, no trailing slash, lowercased. MIRRORS
# prune_norm in fleet.sh and np() in sessions.sh; a drift loses claims.
norm() { local p=${1//\\//}; p=${p%/}; printf '%s' "$p" | tr '[:upper:]' '[:lower:]'; }
say() { [[ -t 2 ]] && echo "fleet sweep: $*" >&2; return 0; }

INVOKED_FROM=$(native "$(pwd -P 2>/dev/null || pwd)")
GCD_RAW=$(git rev-parse --git-common-dir 2>/dev/null) || { echo "fleet sweep: not inside a git repository" >&2; exit 5; }
GCD=$(native "$(cd "$GCD_RAW" && pwd -P)")
REPO_ROOT=$(native "$(cd "$GCD_RAW/.." && pwd -P)")

# Config through `fleet config`, so the sweep can never disagree with the
# landing queue about the base branch or the lane root — one parser, not two.
CFG=$(cd "$INVOKED_FROM" && bash "$FLEET_SH" config 2>/dev/null) || CFG=""
cfg() { printf '%s\n' "$CFG" | sed -n "s/^$1=//p" | head -n1; }
BASE=$(cfg base_branch); BASE=${BASE:-main}
WT_ROOT=$(cfg worktree_root); WT_ROOT=${WT_ROOT:-.fleet-worktrees}
LIVE_SECS=$(cfg session_live_secs); LIVE_SECS=${LIVE_SECS:-600}
SESSION_CHECK=$(cfg session_check | tr '[:upper:]' '[:lower:]')
g() { git -C "$REPO_ROOT" "$@"; }
g rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null \
  || { echo "fleet sweep: base branch '$BASE' does not exist (set base_branch in .claude/fleet/config)" >&2; exit 5; }
BASE_TREE=$(g rev-parse "$BASE^{tree}")
HAVE_MERGE_TREE=0
g merge-tree --write-tree "$BASE" "$BASE" >/dev/null 2>&1 && HAVE_MERGE_TREE=1

# === HELPERS ==================================================================
# Every multi-field `read` below splits on US (0x1f), never on a tab. Tab is IFS
# WHITESPACE, so `IFS=$'\t' read` collapses a run of tabs and an EMPTY field
# (no worktree, no upstream, a done session's blank blocker) silently shifts
# every later column — which once emptied the whole branch phase. US is not
# whitespace, so empty fields survive. Convert with "${var//$'\t'/$US}".
US=$'\037'
ROWS=""
# One TSV row. Fields are sanitised: a session title is user text and may hold
# a tab, which would shift every column after it.
row() {
  local f out="" i=0
  for f in "$@"; do
    f=${f//$'\t'/ }; f=${f//$'\n'/ }
    if [[ $i -eq 0 ]]; then out=$f; else out="$out"$'\t'"$f"; fi
    i=$((i + 1))
  done
  ROWS="${ROWS}${out}"$'\n'
}

# landed_state <ref> -> "MERGED" | "CONTENT" | "CLEAN" | "CONFLICT<TAB>files" | "UNKNOWN"
#   MERGED   the ref is an ancestor of base (what prune means by "merged")
#   CONTENT  not an ancestor, but merging it would not change base's tree: the
#            work already reached base under other SHAs (squash, cherry-pick,
#            rebase-and-land, an identical re-implementation). Prune cannot see
#            this and leaves such lanes in REVIEW forever.
#   CLEAN    unlanded and merges cleanly       CONFLICT  unlanded, conflicts
# A landing that was later reverted, or base editing the same lines again,
# reads CLEAN/CONFLICT, never CONTENT: false "unlanded" is safe, false
# "landed" is not. Without merge-tree (git < 2.38) `git cherry` stands in;
# it catches cherry-picks and rebases but not squashes.
landed_state() {
  local ref=$1 out rc
  if g merge-base --is-ancestor "$ref" "$BASE" 2>/dev/null; then echo MERGED; return; fi
  if [[ $HAVE_MERGE_TREE -eq 1 ]]; then
    out=$(g merge-tree --write-tree --name-only --no-messages "$BASE" "$ref" 2>/dev/null); rc=$?
    case $rc in
      0) if [[ "${out%%$'\n'*}" == "$BASE_TREE" ]]; then echo CONTENT; else echo CLEAN; fi ;;
      1) printf 'CONFLICT\t%s\n' "$(printf '%s\n' "$out" | sed '1d;/^$/d' | sort -u | paste -sd, -)" ;;
      *) echo UNKNOWN ;;
    esac
    return
  fi
  out=$(g cherry "$BASE" "$ref" 2>/dev/null) || { echo UNKNOWN; return; }
  if printf '%s\n' "$out" | grep -q '^+'; then echo CLEAN; else echo CONTENT; fi
}

# Paths out of `git status --porcelain` lines (rename: the new name).
status_paths() { sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"\(.*\)"$/\1/'; }
ledger_out() { grep -Ev -- "$LEDGER" || true; }
age_days() { echo $(( (NOW - ${1:-$NOW}) / 86400 )); }
lane_state() {
  local s=${1//\%/%25} f
  f="$REPO_ROOT/.claude/fleet/lanes/${s//\//%2F}"   # encode_lane, as in fleet.sh
  [[ -f "$f" ]] && head -n1 "$f" | tr -d '\r'
  return 0
}
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$NOW"; }

# The never-push list is PRIVATE by design: it names branches whose history
# leaks identifiers that must never reach a remote, so it lives outside every
# repo (and never in this public one). Set-but-empty FLEET_NEVER_PUSH disables it.
NP=()
if [[ -n "${FLEET_NEVER_PUSH+x}" ]]; then
  IFS=';' read -r -a NP_FILES <<< "$FLEET_NEVER_PUSH"
else
  NP_FILES=("${HOME:-/nonexistent}/.claude/never-push.txt" "$GCD/info/never-push")
fi
for f in ${NP_FILES[@]+"${NP_FILES[@]}"}; do
  [[ -n "$f" && -f "$f" ]] || continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}; line=${line//$'\r'/}
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && NP+=("$line")
  done < "$f"
done
never_push() {
  local p
  # $p unquoted on purpose: each entry is a glob pattern.
  # shellcheck disable=SC2053
  for p in ${NP[@]+"${NP[@]}"}; do [[ "$1" == $p ]] && return 0; done
  return 1
}
# remote \t branch-name, for every remote-tracking ref (awk, not sed: a \t in a
# sed replacement is GNU-only and this runs on macOS bash 3.2 too).
REMOTE_REFS=$(g for-each-ref refs/remotes --format='%(refname)' 2>/dev/null \
  | awk '{ sub(/^refs\/remotes\//, ""); i = index($0, "/"); if (i) print substr($0, 1, i - 1) "\t" substr($0, i + 1) }')
remote_copy() { printf '%s\n' "$REMOTE_REFS" | awk -F'\t' -v b="$1" '$2 == b && !f { print $1; f = 1 }'; }

# === EVIDENCE =================================================================
say "reading prune's buckets (session store, fresh claimant read)..."
# Run from where we were invoked, so prune's "you are standing in it" guard
# protects the caller's own tree here exactly as it does under `fleet prune`.
PRUNE_TSV=$(cd "$INVOKED_FROM" && bash "$FLEET_SH" prune --porcelain 2>/dev/null) || PRUNE_TSV=""
prune_of() { printf '%s\n' "$PRUNE_TSV" | awk -F'\t' -v p="$1" '$1 == p && !f { print $3 "\t" $4; f = 1 }'; }

# Registered worktrees (the primary is skipped: it is the integration tree).
W_PATH=(); W_BR=(); W_HEAD=(); W_GONE=()
wp="" wb="" wh="" wg=0 first=1
while IFS= read -r line; do
  case "$line" in
    worktree\ *) wp=${line#worktree }; wb=""; wh=""; wg=0 ;;
    HEAD\ *)     wh=${line#HEAD } ;;
    branch\ *)   wb=${line#branch refs/heads/} ;;
    prunable*)   wg=1 ;;
    "")
      if [[ -n "$wp" ]]; then
        if [[ $first -eq 0 ]]; then W_PATH+=("$wp"); W_BR+=("$wb"); W_HEAD+=("$wh"); W_GONE+=("$wg"); fi
        first=0
      fi
      wp="" ;;
  esac
done <<< "$(g worktree list --porcelain 2>/dev/null)"$'\n'
NW=${#W_PATH[@]}
REG_NORM=$(for p in ${W_PATH[@]+"${W_PATH[@]}"}; do norm "$p"; echo; done)

MERGES=$(g log --merges --format='%h%x09%s' "$BASE" 2>/dev/null)
merge_sha() { printf '%s\n' "$MERGES" | awk -F'\t' -v s="merge: $1" '$2 == s && !f { print $1; f = 1 }'; }

say "checking $NW lane worktree(s)..."
W_LANDED=(); W_CONF=(); W_AHEAD=(); W_DIRTY=(); W_DSAMPLE=(); W_AGE=(); W_LABEL=()
FILES=""   # lane \t file \t c|u — only work NOT yet in base
for ((i = 0; i < NW; i++)); do
  p=${W_PATH[$i]} br=${W_BR[$i]}
  label=${br:-${p##*/}}; W_LABEL+=("$label")
  if [[ ${W_GONE[$i]} -eq 1 || ! -d "$p" ]]; then
    W_LANDED+=("-"); W_CONF+=(""); W_AHEAD+=(0); W_DIRTY+=(0); W_DSAMPLE+=(""); W_AGE+=(0); continue
  fi
  ref=${br:-${W_HEAD[$i]}}
  ls=$(landed_state "$ref"); st=${ls%%$'\t'*}; conf=""; [[ "$ls" == *$'\t'* ]] && conf=${ls#*$'\t'}
  W_LANDED+=("$st"); W_CONF+=("$conf")
  W_AHEAD+=("$(g rev-list --count "$BASE..$ref" 2>/dev/null || echo 0)")
  W_AGE+=("$(age_days "$(g log -1 --format=%ct "$ref" 2>/dev/null)")")
  dl=$(git -c core.quotepath=false -C "$p" status --porcelain -uall 2>/dev/null)
  dpaths=$(printf '%s\n' "$dl" | sed '/^$/d' | status_paths)
  W_DIRTY+=("$(printf '%s\n' "$dpaths" | grep -c . || true)")
  W_DSAMPLE+=("$(printf '%s\n' "$dpaths" | sed '/^$/d' | head -n3 | paste -sd, -)")
  # A never-push lane is never landed, so it cannot collide with anything.
  [[ -n "$br" ]] && never_push "$br" && continue
  if [[ "$st" != MERGED && "$st" != CONTENT ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && FILES="${FILES}${label}"$'\t'"$f"$'\tc\n'; done \
      < <(git -c core.quotepath=false -C "$REPO_ROOT" diff --name-only "$BASE...$ref" 2>/dev/null | ledger_out)
  fi
  while IFS= read -r f; do [[ -n "$f" ]] && FILES="${FILES}${label}"$'\t'"$f"$'\tu\n'; done \
    < <(printf '%s\n' "$dpaths" | sed '/^$/d' | ledger_out)
done

# Unregistered directories under the worktree roots. `.fleetflow/` is not
# scanned: fleetflow owns it, and ff-sweep reclaims it (with history archived).
ORPHANS=()
for root in "$REPO_ROOT/.claude/worktrees" "$REPO_ROOT/$WT_ROOT"; do
  [[ -d "$root" ]] || continue
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    d=$(native "${d%/}")
    printf '%s\n' "$REG_NORM" | grep -qxF -- "$(norm "$d")" || ORPHANS+=("$d")
  done
done

# --- sessions: who claims what --------------------------------------------------
# Same joins as prune (path_claims + owner_row_cached in fleet.sh): an exact
# normalised path or the transcript key claims a directory; the branch index
# claims the tree its branch is checked out in. Liveness and the archive flag
# are then re-read FRESH for every claimant (sessions.sh state), because the
# index is cached for 15 minutes and "archived since" is the whole question.
STORE_OK=0 SIDX="" SPATHS="" SELF_ID="" MAIN_ID=""
if [[ "$SESSION_CHECK" != off && -f "$SESSIONS_SH" ]]; then
  say "reading the session store..."
  if views=$(FLEET_SESSION_LIVE_SECS="$LIVE_SECS" bash "$SESSIONS_SH" views 2>/dev/null); then
    STORE_OK=1
    SIDX=$(printf '%s\n' "$views" | awk '/^I\t/ { print substr($0, 3) }')
    SPATHS=$(printf '%s\n' "$views" | awk '/^P\t/ { print substr($0, 3) }')
    SELF_ID=$(bash "$SESSIONS_SH" self 2>/dev/null || true)
    MAIN_ID=$( (cd "$REPO_ROOT" && bash "$SESSIONS_SH" main 2>/dev/null) | cut -f2 | head -n1)
  fi
fi
JOIN_IN=$(
  for ((i = 0; i < NW; i++)); do printf '%s\t%s\n' "${W_PATH[$i]}" "${W_BR[$i]}"; done
  for d in ${ORPHANS[@]+"${ORPHANS[@]}"}; do printf '%s\t\n' "$d"; done
)
claims_join() { # state-tsv -> path \t id \t title \t archived \t live \t via
  LC_ALL=C awk -F'\t' '
    function np(p) { gsub(/\\/, "/", p); sub(/\/+$/, "", p); return tolower(p) }
    function enc(p) { p = np(p); gsub(/[^a-z0-9]/, "-", p); return p }
    function out(p, id, t, a, l, v) {
      if (id in SL) l = SL[id]; if (id in SA) a = SA[id]
      if (!seen[p SUBSEP id]++) print p "\t" id "\t" t "\t" a "\t" l "\t" v
    }
    FILENAME == ARGV[1] { if ($1 != "") { SL[$1] = $2; if ($3 != "-" && $3 != "") SA[$1] = $3 }; next }
    FILENAME == ARGV[2] { if ($1 == "") next; P[np($1)] = $1; K[enc($1)] = $1; if ($2 != "") B[$2] = $1; next }
    FILENAME == ARGV[3] { if (NF < 8) next; p = ""
                          if ($2 != "" && ($2 in P)) p = P[$2]; else if ($1 in K) p = K[$1]
                          if (p != "") out(p, $3, $4, $6, $7, $8); next }
    NF >= 7 && ($1 in B) { out(B[$1], $2, $3, $6, $7, "branch") }' \
    <(printf '%s\n' "$1") <(printf '%s\n' "$JOIN_IN") <(printf '%s\n' "$SPATHS") <(printf '%s\n' "$SIDX")
}
# Open sessions whose wrapper cwd is a lane dir of THIS repo (index col 5).
cwd_sessions() {
  LC_ALL=C awk -F'\t' -v r1="$(norm "$REPO_ROOT/.claude/worktrees")/" -v r2="$(norm "$REPO_ROOT/$WT_ROOT")/" '
    function np(p) { gsub(/\\/, "/", p); sub(/\/+$/, "", p); return tolower(p) }
    NF >= 7 { c = np($5); if ((index(c, r1) == 1 || index(c, r2) == 1) && !s[$2]++) print $2 "\t" $5 "\t" $3 "\t" $6 "\t" $7 }' \
    <(printf '%s\n' "$SIDX")
}
CLAIMS="" CWDS=""
if [[ $STORE_OK -eq 1 ]]; then
  CLAIMS=$(claims_join "")
  CWDS=$(cwd_sessions)
  ids=$( { printf '%s\n' "$CLAIMS" | cut -f2; printf '%s\n' "$CWDS" | cut -f1; } | sed '/^$/d' | sort -u)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    state=$(FLEET_SESSION_LIVE_SECS="$LIVE_SECS" bash "$SESSIONS_SH" state $ids 2>/dev/null </dev/null) || state=""
    if [[ -n "$state" ]]; then
      CLAIMS=$(claims_join "$state")
      CWDS=$(awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { if ($1 != "") { L[$1] = $2; if ($3 != "-" && $3 != "") A[$1] = $3 }; next }
               NF { if ($1 in L) $5 = L[$1]; if ($1 in A) $4 = A[$1]; print }' <(printf '%s\n' "$state") <(printf '%s\n' "$CWDS"))
    fi
  fi
fi
claims_of() { printf '%s\n' "$CLAIMS" | awk -F'\t' -v p="$1" '$1 == p'; }

# === VERDICTS =================================================================
# --- phase 3 facts first: branch landed-ness feeds the session "done" test -----
say "checking local branches..."
MERGED_SET=$(g for-each-ref --merged="$BASE" --format='%(refname:short)' refs/heads 2>/dev/null)
BR_OK=""   # branch \t 1|0 — "is its work in base" for every local branch
# %(worktreepath) is git 2.23+. Older git rejects the whole format, and an empty
# phase would read as "no leftover branches" - so say so instead (UNKNOWN is a
# finding, exit 10).
BR_FACTS=$(g for-each-ref refs/heads --format='%(refname:short)%1f%(objectname)%1f%(worktreepath)%1f%(upstream:short)%1f%(upstream:track)%1f%(committerdate:unix)' 2>/dev/null) \
  || { BR_FACTS=""; row branch "*" UNKNOWN "git for-each-ref lacks %(worktreepath) (git < 2.23): branch phase skipped" "upgrade git, then re-run"; }
B_ROWS=()   # name US sha US state US upstream US track US date  (worktree-less only)
while IFS=$US read -r b sha wtp up track cdate; do
  [[ -z "$b" || "$b" == "$BASE" ]] && continue
  if printf '%s\n' "$MERGED_SET" | grep -qxF -- "$b"; then s=MERGED
  elif [[ -n "$wtp" ]]; then s=WT   # judged with its worktree in phase 1
  else s=$(landed_state "$b"); s=${s%%$'\t'*}; fi
  ok=0; [[ "$s" == MERGED || "$s" == CONTENT ]] && ok=1
  [[ "$s" != WT ]] && BR_OK="${BR_OK}${b}"$'\t'"$ok"$'\n'
  [[ -z "$wtp" ]] && B_ROWS+=("$b$US$sha$US$s$US$up$US$track$US$cdate")
done <<< "$BR_FACTS"
for ((i = 0; i < NW; i++)); do
  [[ -z "${W_BR[$i]}" ]] && continue
  ok=0; [[ ( "${W_LANDED[$i]}" == MERGED || "${W_LANDED[$i]}" == CONTENT ) && "${W_DIRTY[$i]}" == 0 ]] && ok=1
  BR_OK="${BR_OK}${W_BR[$i]}"$'\t'"$ok"$'\n'
done

# --- session "done" test ------------------------------------------------------
# A session is DONE when every tree it claims is landed + clean and every local
# branch it wrote is in base. Only a done, open, idle session is asked to
# archive; one with unlanded work anywhere is the blocker, named per tree.
WT_OK=$(for ((i = 0; i < NW; i++)); do
  ok=0; [[ ( "${W_LANDED[$i]}" == MERGED || "${W_LANDED[$i]}" == CONTENT ) && "${W_DIRTY[$i]}" == 0 ]] && ok=1
  printf '%s\t%s\t%s\n' "${W_PATH[$i]}" "$ok" "${W_PATH[$i]##*/}"
done)
# A tree prune KEEPs (live, locked) also blocks its claimants: prune and this
# script read liveness moments apart, and an owner that went idle in between
# (a machine that slept mid-run did exactly this) must not get an archive
# request for a tree the same report calls live.
KEEP_PATHS=$(printf '%s\n' "$PRUNE_TSV" | awk -F'\t' '$3 == "KEEP" { print $1 }')
SESS=$(LC_ALL=C awk -F'\t' '
  FILENAME == ARGV[1] { if ($1 != "") KP[$1] = 1; next }
  FILENAME == ARGV[2] { OK[$1] = $2; SLUG[$1] = $3; next }
  FILENAME == ARGV[3] { BOK[$1] = $2; next }
  FILENAME == ARGV[4] { if (!($1 in OK)) next; id = $2
                        if ($5 == "1") { LIVE[id] = 1; next }
                        if ($4 == "1") next
                        ids[id] = 1; T[id] = $3
                        if (index("," TR[id] ",", "," SLUG[$1] ",") == 0) TR[id] = TR[id] (TR[id] == "" ? "" : ",") SLUG[$1]
                        if (($1 in KP) && !(id in BLK)) BLK[id] = SLUG[$1] " (prune keeps it)"
                        if (OK[$1] != "1" && !(id in BLK)) BLK[id] = SLUG[$1]
                        next }
  NF >= 7 && ($2 in ids) && ($1 in BOK) && BOK[$1] == "0" && !($2 in BLK) { BLK[$2] = "branch " $1 }
  END { for (id in ids) if (!(id in LIVE)) print id "\t" T[id] "\t" ((id in BLK) ? 0 : 1) "\t" BLK[id] "\t" TR[id] }' \
  <(printf '%s\n' "$KEEP_PATHS") <(printf '%s\n' "$WT_OK") <(printf '%s\n' "$BR_OK") <(printf '%s\n' "$CLAIMS") <(printf '%s\n' "$SIDX") | sort)
sess_field() { printf '%s\n' "$SESS" | awk -F'\t' -v id="$1" -v c="$2" '$1 == id && !f { print $c; f = 1 }'; }

# --- phase 2: competing lanes (computed before phase 1, which cites it) --------
PAIRS=$(printf '%s' "$FILES" | LC_ALL=C awk -F'\t' '
  NF >= 3 { if (!seen[$2 SUBSEP $1]++) L[$2] = L[$2] (L[$2] == "" ? "" : "\034") $1
            if ($3 == "u") U[$1 SUBSEP $2] = 1 }
  END {
    for (f in L) { n = split(L[f], a, "\034"); if (n < 2) continue
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
        x = a[i]; y = a[j]; if (x > y) { t = x; x = y; y = t }
        k = x "\t" y; C[k]++; F[k] = F[k] (F[k] == "" ? "" : ",") f
        if (U[x SUBSEP f]) UX[k] = 1; if (U[y SUBSEP f]) UY[k] = 1 } }
    for (k in C) print k "\t" C[k] "\t" F[k] "\t" (UX[k] + 0) "\t" (UY[k] + 0) }' | sort)
COMPETING=$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF { print $1; print $2 }' | sort -u)
competes_with() { printf '%s\n' "$PAIRS" | awk -F'\t' -v l="$1" '$1 == l && !f { print $2; f = 1 } $2 == l && !f { print $1; f = 1 }'; }

# --- sessions to archive DIRECTLY (cited by phase 1, emitted in phase 5) -------
# A session whose lane dir is gone, or is no longer a registered worktree, must
# NOT be messaged: a message resumes it, and a session resumed into a missing
# tree spins a core forever (references/prune.md, "Landmine"). It is archived
# directly, and never sent an archive REQUEST, even when all its work landed.
HOLLOW_LIST=""   # id \t dir \t title \t live — open claimants of an orphan dir
for d in ${ORPHANS[@]+"${ORPHANS[@]}"}; do
  held=$(printf '%s\n' "$CLAIMS" | awk -F'\t' -v OFS='\t' -v p="$d" '$1 == p && $4 != "1" { print $2, $1, $3, $5 }')
  [[ -n "$held" ]] && HOLLOW_LIST="${HOLLOW_LIST}${held}"$'\n'
done
DIRECT=""   # id \t lane dir \t title \t live
while IFS=$US read -r id cwd title arch live; do
  [[ -z "$id" || "$arch" == 1 ]] && continue
  # Its lane dir is the first path component under a worktree root.
  nc=$(norm "$cwd") top=""
  for r in "$(norm "$REPO_ROOT/.claude/worktrees")/" "$(norm "$REPO_ROOT/$WT_ROOT")/"; do
    if [[ "$nc" == "$r"* ]]; then rest=${nc#"$r"}; top="$r${rest%%/*}"; break; fi
  done
  [[ -z "$top" ]] && continue
  printf '%s\n' "$REG_NORM" | grep -qxF -- "$top" && continue
  DIRECT="${DIRECT}${id}"$'\t'"${cwd//\\//}"$'\t'"$title"$'\t'"$live"$'\n'
done <<< "${CWDS//$'\t'/$US}"
DIRECT=$(printf '%s%s' "$DIRECT" "$HOLLOW_LIST" | awk -F'\t' 'NF && !s[$1]++')
is_direct() { printf '%s\n' "$DIRECT" | cut -f1 | grep -qxF -- "$1"; }

# --- phase 1: worktrees -------------------------------------------------------
N_ARCH_ASK=0
for ((i = 0; i < NW; i++)); do
  p=${W_PATH[$i]} br=${W_BR[$i]} label=${W_LABEL[$i]} slug=${W_PATH[$i]##*/}
  pb=$(prune_of "$p"); bucket=${pb%%$'\t'*}; reason=${pb#*$'\t'}
  [[ -z "$pb" ]] && { bucket=REVIEW; reason="not classified by prune"; }
  st=${W_LANDED[$i]} dirty=${W_DIRTY[$i]}
  cl=$(claims_of "$p")
  live=$(printf '%s\n' "$cl" | awk -F'\t' '$5 == "1" && !f { print $3; f = 1 }')
  open_ids=$(printf '%s\n' "$cl" | awk -F'\t' 'NF && $4 != "1" && $5 != "1" { print $2 }' | sort -u)
  run=""; [[ "$br" == fleetflow/*/* ]] && { run=${br#fleetflow/}; run=${run%%/*}; }

  if [[ ${W_GONE[$i]} -eq 1 || ! -d "$p" ]]; then
    row worktree "$p" GHOST "directory gone; git still lists it" "git worktree prune  (fleet sweep --apply)"
  elif [[ "$bucket" == KEEP ]]; then
    row worktree "$p" KEEP "$reason" "-"
  elif [[ -n "$live" ]]; then
    row worktree "$p" KEEP "live session: $live (fresh read)" "-"
  elif [[ "$bucket" == SAFE ]]; then
    row worktree "$p" REMOVE "$reason" "fleet prune --remove"
  elif [[ -n "$br" ]] && never_push "$br"; then
    row worktree "$p" PARK "branch is on the private never-push list" "never land or push it; remove the tree by hand when done"
  elif printf '%s\n' "$COMPETING" | grep -qxF -- "$label"; then
    row worktree "$p" COMPETING "shares files with $(competes_with "$label") (phase 2)" "settle the pair before landing either"
  elif [[ "$dirty" -gt 0 ]]; then
    row worktree "$p" INSPECT "$dirty uncommitted: ${W_DSAMPLE[$i]}" "commit it in its lane, or discard after review"
  elif [[ "$st" == MERGED || "$st" == CONTENT ]]; then
    how="merged"; [[ "$st" == CONTENT ]] && how="landed by content (squash/cherry-pick) - prune cannot see it"
    if [[ -n "$open_ids" ]]; then
      blocker="" ask="" direct=""
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if [[ "$id" == "$SELF_ID" ]]; then blocker="owned by this session"; break; fi
        if [[ "$id" == "$MAIN_ID" ]]; then blocker="owned by MAIN"; break; fi
        if [[ "$(sess_field "$id" 3)" != 1 ]]; then
          blocker="owner '$(sess_field "$id" 2)' still has unlanded work: $(sess_field "$id" 4)"; break
        fi
        if is_direct "$id"; then direct="$direct${direct:+, }$id"; else ask="$ask${ask:+, }$id"; fi
      done <<< "$open_ids"
      if [[ -n "$blocker" ]]; then
        row worktree "$p" OWNER-BUSY "$how; $blocker" "land the blocker first, then re-run"
      elif [[ -n "$direct" ]]; then
        row worktree "$p" ASK-ARCHIVE "$how + clean; owner open, its own lane dir gone" "archive $direct directly (phase 5) - never message it"
        N_ARCH_ASK=$((N_ARCH_ASK + 1))
      else
        row worktree "$p" ASK-ARCHIVE "$how + clean; owner open but idle" "ask $ask to archive itself (phase 5)"
        N_ARCH_ASK=$((N_ARCH_ASK + 1))
      fi
    elif [[ -n "$run" ]]; then
      row worktree "$p" FLEETFLOW "$how + clean; a fleetflow lane" "ff-clean.sh --run $run (fleetflow archives the run first)"
    elif [[ "$st" == CONTENT ]]; then
      row worktree "$p" CONTENT-LANDED "$how" "after an OK: git worktree remove '$p' && git branch -D '$br'"
    else
      row worktree "$p" VERIFY-OWNER "merged + clean; prune: $reason" "find its session (search_session_transcripts '$slug'); archived => prune can remove it"
    fi
  elif [[ "$st" == CONFLICT ]]; then
    row worktree "$p" REBASE "${W_AHEAD[$i]} commit(s) conflict with $BASE in ${W_CONF[$i]}" "rebase in the lane, or hand it back to its session"
  elif [[ -z "$br" ]]; then
    row worktree "$p" INSPECT "detached HEAD with commits not in $BASE" "branch it (git branch <name> <sha>) or discard after review"
  else
    stale=""; [[ "${W_AGE[$i]}" -ge "$STALE_DAYS" ]] && stale="; last commit ${W_AGE[$i]}d ago"
    row worktree "$p" LAND "${W_AHEAD[$i]} commit(s), merges cleanly$stale" "fleet land $br"
  fi
done

# --- phase 2 rows ---------------------------------------------------------------
while IFS=$US read -r a b n files ua ub; do
  [[ -z "$a" ]] && continue
  who=""
  [[ "$ua" == 1 ]] && who="$a"; [[ "$ub" == 1 ]] && who="$who${who:+, }$b"
  note="$n file(s): $(printf '%s' "$files" | cut -d, -f1-4)"; [[ $n -gt 4 ]] && note="$note,..."
  [[ -n "$who" ]] && note="$note; uncommitted in $who"
  row compete "$a <> $b" OVERLAP "$note" "pick the winner: land it, then rebase or drop the other"
done <<< "${PAIRS//$'\t'/$US}"

# --- phase 3 rows: branches with no worktree ----------------------------------
for r in ${B_ROWS[@]+"${B_ROWS[@]}"}; do
  IFS=$US read -r b sha s up track cdate <<< "$r"
  gone=""; [[ "$track" == *gone* ]] && gone="; upstream gone"
  if never_push "$b"; then
    rem=$(remote_copy "$b")
    if [[ -n "$up" || -n "$rem" ]]; then
      row branch "$b" LEAKED "never-push branch has a remote copy${rem:+ on $rem}${up:+ (tracks $up)}" "review with the owner now; removing it from the remote is a manual push"
    else
      row branch "$b" PARK "on the private never-push list" "-"
    fi
    continue
  fi
  if [[ "$s" == MERGED ]]; then
    if [[ "$b" =~ $KEEP_RE ]]; then continue; fi
    ls=$(lane_state "$b")
    if [[ -n "$ls" && "$ls" != LANDED ]]; then row branch "$b" TRACKED "fleet lane in state $ls" "-"; continue; fi
    holder=$(printf '%s\n' "$SIDX" | awk -F'\t' -v b="$b" 'NF >= 7 && $1 == b && $6 != "1" && !f { print $3; f = 1 }')
    if [[ -n "$holder" ]]; then row branch "$b" HELD "named by open session '$holder'" "-"; continue; fi
    row branch "$b" DELETE-MERGED "every commit is in $BASE$gone" "git branch -d $b  (fleet sweep --apply)"
  elif [[ "$s" == CONTENT ]]; then
    row branch "$b" CONTENT-LANDED "content already in $BASE under other SHAs$gone" "after an OK: git branch -D $b"
  else
    n=$(g rev-list --count "$BASE..$b" 2>/dev/null || echo "?")
    d=$(age_days "$cdate")
    if [[ "$d" -ge "$STALE_DAYS" ]]; then
      row branch "$b" STALE "$n commit(s) not in $BASE, last ${d}d ago$gone" "land, park, or delete by hand (git branch -D) after review"
    else
      row branch "$b" UNLANDED "$n commit(s) not in $BASE, ${d}d old, no worktree$gone" "fleet land $b when its work is done"
    fi
  fi
done

# --- phase 4 rows: hygiene ------------------------------------------------------
ghosts=$(g worktree prune --dry-run --verbose 2>&1 | grep -c . || true)
[[ "$ghosts" -gt 0 ]] && row hygiene "git worktree prune" GHOST "$ghosts stale admin entr(y/ies)" "git worktree prune  (fleet sweep --apply)"
EMPTY_OK=()      # dirs --apply may rmdir
for d in ${ORPHANS[@]+"${ORPHANS[@]}"}; do
  n=$(ls -A "$d" 2>/dev/null | wc -l | tr -d ' ')
  holder=$(printf '%s\n' "$HOLLOW_LIST" | awk -F'\t' -v p="$d" '$2 == p && !f { print $1; f = 1 }')
  if [[ "$n" -gt 0 ]]; then
    row hygiene "$d" ORPHAN-DIR "$n entr(y/ies), not a registered worktree" "review by hand; never rm -rf a .claude/worktrees/ dir"
  elif [[ -n "$holder" ]]; then
    row hygiene "$d" HOLLOW "empty, but open session $holder still has it as its cwd" "archive that session first (phase 5), then it is removable"
  elif [[ $STORE_OK -ne 1 ]]; then
    row hygiene "$d" EMPTY-DIR "empty; session store unreadable, so no claim can be ruled out" "rmdir by hand once no session uses it"
  elif [[ $(( NOW - $(file_mtime "$d") )) -lt $MIN_DIR_AGE ]]; then
    row hygiene "$d" KEEP "empty but new - may be mid-creation" "-"
  else
    row hygiene "$d" EMPTY-DIR "empty, unregistered, no open session claims it" "rmdir  (fleet sweep --apply)"
    EMPTY_OK+=("$d")
  fi
done
while IFS=$US read -r ref ct msg; do
  [[ -z "$ref" ]] && continue
  d=$(age_days "$ct")
  if [[ "$d" -ge "$STALE_DAYS" ]]; then
    row hygiene "$ref" STALE-STASH "${d}d old: $msg" "git stash show -p $ref; the stack is shared - drop by hand"
  else
    row hygiene "$ref" STASH "${d}d old: $msg" "-"
  fi
done <<< "$(g stash list --format='%gd%x1f%ct%x1f%gs' 2>/dev/null)"
[[ -d "$REPO_ROOT/.fleetflow" ]] && row hygiene "$REPO_ROOT/.fleetflow" FLEETFLOW-RUNS "fleetflow run dirs present" "ff-sweep.sh --list (fleetflow owns .fleetflow/)"

# --- phase 5 rows: sessions -----------------------------------------------------
# DIRECT (computed before phase 1) first; they are excluded from the archive
# REQUESTS below even when all their work is landed.
while IFS=$US read -r id where title live; do
  [[ -z "$id" || "$id" == "$SELF_ID" || "$id" == "$MAIN_ID" ]] && continue
  if [[ "$live" == 1 ]]; then
    row session "$id" "SPINNING?" "$title | LIVE, but its lane dir $where is gone or hollow" "check its CPU now (references/prune.md landmine); stop it, then archive"
  else
    row session "$id" ARCHIVE-DIRECT "$title | its lane dir $where is gone or hollow" "archive_session $id (gated) - do NOT send_message"
  fi
done <<< "${DIRECT//$'\t'/$US}"
while IFS=$US read -r id title done blk trees; do
  [[ -z "$id" || "$done" != 1 || "$id" == "$SELF_ID" || "$id" == "$MAIN_ID" ]] && continue
  is_direct "$id" && continue
  landed=""
  for t in $(printf '%s' "$trees" | tr ',' ' '); do
    for ((i = 0; i < NW; i++)); do
      [[ "${W_PATH[$i]##*/}" == "$t" && -n "${W_BR[$i]}" ]] || continue
      s=$(merge_sha "${W_BR[$i]}"); [[ -z "$s" ]] && s=$(g rev-parse --short "${W_BR[$i]}" 2>/dev/null)
      landed="$landed${landed:+, }${W_BR[$i]}@$s"
    done
  done
  if [[ "$id" == cli:* ]]; then
    row session "$id" ARCHIVE-REQUEST "$title | done: $trees | landed: ${landed:--}" "terminal session: no archive API - close it, or pigeon its project"
  else
    row session "$id" ARCHIVE-REQUEST "$title | done: $trees | landed: ${landed:--}" "send_message: ask it to archive itself (references/sweep.md)"
  fi
done <<< "${SESS//$'\t'/$US}"

# === OUTPUT ===================================================================
INFO_RE='^(KEEP|PARK|TRACKED|HELD|STASH|OWNER-BUSY|FLEETFLOW-RUNS)$'
FINDINGS=$(printf '%s' "$ROWS" | awk -F'\t' -v re="$INFO_RE" 'NF && $3 !~ re' | grep -c . || true)
cnt() { printf '%s' "$ROWS" | awk -F'\t' -v v="$1" 'NF && $3 == v' | grep -c . || true; }

if [[ $MODE == porcelain ]]; then
  printf '%s' "$ROWS"
elif [[ $MODE == json ]]; then
  printf '%s' "$ROWS" | jq -Rn --arg base "$BASE" --argjson findings "${FINDINGS:-0}" '
    [inputs | select(length > 0) | split("\t")
      | {phase: .[0], subject: .[1], verdict: .[2], detail: .[3], action: .[4]}] as $d
    | {data: $d, meta: {count: ($d | length), findings: $findings, base: $base,
                        schema: "claude-mods.fleet-ops.sweep/v1"}}'
else
  # shellcheck source=../../_lib/term.sh
  . "$SCRIPT_DIR/../../_lib/term.sh"
  [[ "${FLEET_ASCII:-}" == "1" ]] && export TERM_ASCII=1
  term_init
  echo ""
  term_panel_open fleet "fleet sweep" "$TERM_GLYPH_BRANCH $BASE"
  term_panel_vert
  term_summary_line "$NW worktree(s), ${#B_ROWS[@]} worktree-less branch(es) - $FINDINGS to act on"
  [[ $STORE_OK -eq 1 ]] || term_summary_line "session store unreadable: no archive requests, no dir removal"
  term_panel_vert
  phase_n=0
  for ph in worktree compete branch hygiene session; do
    phase_n=$((phase_n + 1))
    rows=$(printf '%s' "$ROWS" | awk -F'\t' -v ph="$ph" 'NF && $1 == ph')
    [[ -z "$rows" ]] && continue
    n=$(printf '%s\n' "$rows" | grep -c .)
    term_section CONFLICT "$phase_n $(printf '%s' "$ph" | tr '[:lower:]' '[:upper:]')" "$n"
    if [[ $ph == branch || $ph == hygiene ]]; then
      # Collapsed per verdict: a post-wave repo can carry hundreds of merged
      # branches, and one line each buries everything else. --porcelain lists all.
      for v in $(printf '%s\n' "$rows" | cut -f3 | sort | uniq); do
        vr=$(printf '%s\n' "$rows" | awk -F'\t' -v v="$v" '$3 == v')
        vn=$(printf '%s\n' "$vr" | grep -c .)
        sample=$(printf '%s\n' "$vr" | cut -f2 | sed 's#.*/\.claude/worktrees/##' | head -n3 | paste -sd, -)
        [[ $vn -gt 3 ]] && sample="$sample, +$((vn - 3)) more"
        printf '%s   %s %-15s %s\n' "$(term_color dim "$TERM_TREE_VERT")" \
          "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" "$v ($vn)" "$(term_color dim "$sample")"
        printf '%s        %s\n' "$(term_color dim "$TERM_TREE_VERT")" \
          "$(term_color dim "-> $(printf '%s\n' "$vr" | head -n1 | cut -f5)")"
      done
    else
      while IFS=$US read -r _ subj v det act; do
        [[ -z "$subj" ]] && continue
        # Worktree subjects are paths (show the dir name); compete and session
        # subjects are branch pairs and ids, which contain '/' and stay whole.
        w=28; [[ $ph == worktree ]] && subj=${subj##*/}; [[ $ph == compete ]] && w=52
        printf "%s   %s %-${w}s %-15s %s\n" "$(term_color dim "$TERM_TREE_VERT")" \
          "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
          "$(term_truncate "$subj" "$w")" "$v" "$(term_color dim "$(term_truncate "$det" 70)")"
        [[ "$act" != "-" ]] && printf '%s        %s\n' "$(term_color dim "$TERM_TREE_VERT")" \
          "$(term_color dim "-> $(term_truncate "$act" 96)")"
      done <<< "${rows//$'\t'/$US}"
    fi
    term_panel_vert
  done
  if [[ "$FINDINGS" -gt 0 ]]; then health=$(term_health pending "$FINDINGS to act on")
  else health=$(term_health healthy "nothing left"); fi
  term_panel_close "$(term_hotkey '?' help)" "$health"
  echo ""

  # The ordered procedure. Each step changes what the next run reports, which
  # is what makes the sweep resumable: do one step, re-run, read what is left.
  {
    n_comp=$(cnt OVERLAP) n_land=$(cnt LAND) n_reb=$(cnt REBASE) n_insp=$(cnt INSPECT)
    n_req=$(cnt ARCHIVE-REQUEST) n_dir=$(( $(cnt ARCHIVE-DIRECT) + $(cnt 'SPINNING?') ))
    n_rm=$(cnt REMOVE) n_zero=$(( $(cnt DELETE-MERGED) + (ghosts > 0 ? 1 : 0) + ${#EMPTY_OK[@]} ))
    n_hand=$(( $(cnt CONTENT-LANDED) + $(cnt VERIFY-OWNER) + $(cnt ORPHAN-DIR) + $(cnt STALE) + $(cnt STALE-STASH) + $(cnt LEAKED) + $(cnt UNLANDED) + $(cnt FLEETFLOW) ))
    k=0; echo "  Next, in order - re-run 'fleet sweep' after each step:"
    [[ $n_comp -gt 0 ]] && { k=$((k+1)); echo "    $k. settle $n_comp competing pair(s): pick a winner before landing either"; }
    [[ $((n_land + n_reb)) -gt 0 ]] && { k=$((k+1)); echo "    $k. land $n_land lane(s) (fleet land <branch>); $n_reb need a rebase in their lane first"; }
    [[ $n_insp -gt 0 ]] && { k=$((k+1)); echo "    $k. inspect $n_insp tree(s) with uncommitted work"; }
    [[ $((n_req + n_dir)) -gt 0 ]] && { k=$((k+1)); echo "    $k. sessions: $n_req archive request(s) (send_message), $n_dir to archive directly - agent step, one gated call each"; }
    [[ $n_rm -gt 0 ]] && { k=$((k+1)); echo "    $k. remove $n_rm SAFE worktree(s): fleet prune --remove"; }
    [[ $n_zero -gt 0 ]] && { k=$((k+1)); echo "    $k. zero-loss hygiene ($n_zero): fleet sweep --apply"; }
    [[ $n_hand -gt 0 ]] && { k=$((k+1)); echo "    $k. by hand, after review: $n_hand row(s) (content-landed, verify-owner, orphan dirs, stale, leaked)"; }
    [[ $k -eq 0 ]] && echo "    nothing - the wave is swept"
    echo "  Procedure and the archive-request template: references/sweep.md"
  } >&2
fi

[[ $APPLY -eq 1 ]] || { [[ "${FINDINGS:-0}" -gt 0 ]] && exit 10; exit 0; }

# === APPLY ====================================================================
DEL=(); for r in ${B_ROWS[@]+"${B_ROWS[@]}"}; do
  IFS=$US read -r b sha _ <<< "$r"
  printf '%s' "$ROWS" | awk -F'\t' -v b="$b" '$1 == "branch" && $2 == b && $3 == "DELETE-MERGED" { f = 1 } END { exit !f }' \
    && DEL+=("$b"$'\t'"$sha")
done
total=$(( ${#DEL[@]} + ${#EMPTY_OK[@]} + (ghosts > 0 ? 1 : 0) ))
if [[ $total -eq 0 ]]; then echo "fleet sweep --apply: nothing zero-loss to do" >&2; [[ "$FINDINGS" -gt 0 ]] && exit 10; exit 0; fi
if [[ $YES -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "fleet sweep --apply: no terminal to confirm on. Re-run interactively, or add --yes after reading the report." >&2
    exit 2
  fi
  printf 'Apply %d zero-loss change(s): %d branch delete(s), %d empty dir(s), %s? Type "apply" to confirm: ' \
    "$total" "${#DEL[@]}" "${#EMPTY_OK[@]}" "$([[ $ghosts -gt 0 ]] && echo 'git worktree prune' || echo 'no ghost prune')" >&2
  answer=""; read -r answer || true
  [[ "$answer" == apply ]] || { echo "aborted - nothing changed" >&2; exit 1; }
fi

failed=0 done_n=0
if [[ "$ghosts" -gt 0 ]]; then
  if g worktree prune --verbose >&2; then done_n=$((done_n + 1)); else failed=$((failed + 1)); fi
fi
for r in ${DEL[@]+"${DEL[@]}"}; do
  b=${r%%$'\t'*} sha=${r#*$'\t'}
  # Re-verify immediately before the delete: same sha, still in base, and not
  # checked out anywhere (a ref deleted under a worktree leaves it unborn).
  # update-ref with the old value is a compare-and-swap, so a branch that
  # moved since the check is refused rather than lost.
  if [[ "$(g rev-parse --verify --quiet "refs/heads/$b")" != "$sha" ]] \
     || ! g merge-base --is-ancestor "$sha" "$BASE" 2>/dev/null \
     || g worktree list --porcelain 2>/dev/null | grep -qxF -- "branch refs/heads/$b"; then
    echo "  SKIP branch $b - changed since the report" >&2; continue
  fi
  if g update-ref -d "refs/heads/$b" "$sha" 2>/dev/null; then
    echo "  deleted branch $b (was $sha, in $BASE)" >&2; done_n=$((done_n + 1))
  else
    echo "  FAILED to delete branch $b" >&2; failed=$((failed + 1))
  fi
done
for d in ${EMPTY_OK[@]+"${EMPTY_OK[@]}"}; do
  # Fresh read of every claim on the dir right before removing it: a session
  # can have been unarchived or pointed at it since the report.
  fresh=$(FLEET_SESSION_LIVE_SECS="$LIVE_SECS" bash "$SESSIONS_SH" at --fresh "$d" 2>/dev/null) || fresh="?"
  if [[ "$fresh" == "?" ]] || printf '%s\n' "$fresh" | awk -F'\t' 'NF && $6 != "1" { f = 1 } END { exit !f }'; then
    echo "  SKIP $d - a session may still use it" >&2; continue
  fi
  if [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || printf '%s\n' "$(g worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r x; do norm "$x"; echo; done)" | grep -qxF -- "$(norm "$d")"; then
    echo "  SKIP $d - no longer an empty, unregistered dir" >&2; continue
  fi
  if rmdir "$d" 2>/dev/null; then echo "  removed empty dir $d" >&2; done_n=$((done_n + 1))
  else echo "  FAILED to rmdir $d" >&2; failed=$((failed + 1)); fi
done
echo "fleet sweep --apply: $done_n done, $failed failed - re-run 'fleet sweep' for what is left" >&2
[[ $failed -eq 0 ]] || exit 1
exit 0
