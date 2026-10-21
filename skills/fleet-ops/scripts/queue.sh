#!/usr/bin/env bash
# fleet queue: land reviewed lanes one at a time, each only after its would-be merge is audited.
#
# Usage:   fleet queue [OPTIONS] <lane> <tip> [<lane> <tip>...]
#          bash "<skill-dir>/scripts/queue.sh" [OPTIONS] <lane> <tip> [...]
# Input:   pairs of lane branch + the head SHA the coordinator reviewed (its "frozen tip")
# Output:  one TSV row per lane on stdout, as each one finishes:
#            lane TAB tip TAB result TAB detail
#          result: landed | already | clean (--dry-run) | conflict | audit | moved |
#                  dirty | failed | timeout | missing | skipped
#          --json: {"data":[{lane,tip,result,detail}],"meta":{count,schema,exit}} at the end
# Stderr:  progress, each wait, audit findings, the tail of fleet land's log
# Exit:    0  every lane landed or was already in the base (--dry-run: every lane would land)
#          2  usage, 3 a lane or tip does not resolve, 4 an audit failed,
#          5  precondition (no repo, git older than 2.38, fleet.sh missing),
#          6  the deadline passed while waiting (retryable: queue it again later),
#          10 trial merge conflicts with the base, 11 tip moved to different content or a
#             tree is dirty (review again), 12 fleet land ran and did not land
#
# Examples:
#   fleet queue lane/foo 3b34773                       # land one reviewed lane
#   fleet queue --dry-run lane/foo 3b34773 lane/bar 4ccf7bf   # audit only, land nothing
#   fleet queue --deadline 45m --poll 30s lane/foo 3b34773
#   fleet queue --deny-file ~/.private-names.txt lane/foo 3b34773
#   fleet queue --json lane/foo 3b34773 | jq -r '.data[].result'
#
# CONTRACT (each line is a failure this exists to prevent; references/conduct.md has the why):
#   * It never merges by itself. Every land goes through `fleet land`: the landing marker,
#     the test gate, the red-gate reset and the auto-rebase of other lanes stay in one place.
#   * One lane at a time, in argument order, stopping at the first lane that does not land,
#     so nothing lands on top of a surprise. --dry-run checks every lane and lands none.
#   * The deadline bounds WAITING and stops a NEW land from starting. It never interrupts a
#     land in progress: killing a land mid-gate leaves the base holding an untested merge.
#   * It retries only refusals fleet makes BEFORE any merge (a live owner, another land
#     holding the marker, claimants it could not verify), and quietly: it never messages
#     an owner, because a message resets the idle clock the live-owner gate is waiting on.
#   * A moved tip is accepted only when merging it gives exactly the tree that merging the
#     reviewed tip gives. Anything else was not reviewed.
#   * Every audit runs on the would-be merge (`git merge-tree`) against the base as it is
#     at that attempt, and is re-run on every retry, because the base moves between them.
#   * Released changelog sections are immutable: a clean auto-merge can file a lane's
#     bullet under the newest `## [x.y.z]`, and no gate notices.
#   * Deny-list findings name the file, line and pattern number, never the matched text:
#     the list holds names that must not be published, and this output gets pasted.
#   * No `< <(producer)` loops: every producer is captured and its status checked first,
#     so a git that dies part-way fails the audit instead of passing it on empty input.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fleet.sh"
SCHEMA="claude-mods.fleet-ops.queue/v1"

usage() {
  cat <<'EOF'
Usage: fleet queue [OPTIONS] <lane> <tip> [<lane> <tip>...]

Land reviewed lanes one at a time through `fleet land`. Before each land: wait for the
base to settle, check the tip is still the reviewed one (or an identical-outcome rebase),
trial-merge it, audit the would-be merge, wait for memory headroom (Windows), then land,
retrying while fleet refuses for a live owner or a held landing marker.

Options:
  --dry-run            Check and audit every lane; land nothing, wait for nothing
  --deadline <dur>     Stop waiting, and start no new land, after this (default 75m:
                       longer than one gate, and short enough that a land started at
                       the deadline still finishes inside a ~2 h background limit)
  --poll <dur>         Wait between retries (default 60s)
  --mem-limit <pct>    Windows commit-charge ceiling for starting a gate (default 92; off)
  --changelog <path>   Changelog the audits read (default CHANGELOG.md; skipped if absent)
  --deny-file <path>   A private list of names that must not be published, one regex
                       per line (ripgrep syntax, case-insensitive, '#' comments); the
                       deny audit reads every line the merge adds (repeatable)
  --skip-audit <name>  Skip one audit: dropped | glued | released | dups | deny
                       (repeatable; for a verified false positive, such as a release
                       cut for released; give the reason in the ledger)
  --json               Print one JSON envelope at the end instead of TSV rows
  -h, --help           This help

Durations: 45s, 30m, 2h, or a bare number of minutes.

Audits (on the would-be merge, against the base):
  dropped  a changelog line the merge loses (net of lines it only moves) that none of the
           lane's own commits removed: a removal made in a merge resolution
  glued    an [Unreleased] "- **" entry with no blank line above it, new against the base
  released a released "## [x.y.z]" section the merge changes or removes (a new section,
           as a release cut adds, is fine; link-reference lines are a footer, not content)
  dups     a top-level shell function, Python def or CONSTANT defined twice in a touched
           .sh/.py file, new against the base's copy
  deny     an added line, in any file, matching a --deny-file pattern

EXAMPLES
  fleet queue lane/foo 3b34773
  fleet queue --dry-run lane/foo 3b34773 lane/bar 4ccf7bf
  fleet queue --deadline 45m --poll 30s lane/foo 3b34773
  fleet queue --deny-file ~/.private-names.txt lane/foo 3b34773
  fleet queue --json lane/foo 3b34773 | jq -r '.data[].result'

Exit codes: 0 all landed (or already in the base), 2 usage, 3 not found, 4 audit failed,
5 precondition, 6 deadline passed while waiting (retryable), 10 trial merge conflicts,
11 tip moved to different content or a tree is dirty, 12 fleet land did not land.
EOF
}

# === ARGUMENTS ================================================================
DRY_RUN=0 JSON=0 DEADLINE_ARG="75m" POLL_ARG="60s" MEM_LIMIT="92" CHANGELOG="CHANGELOG.md"
SKIP_AUDITS=" "
PAIRS=()
DENY_FILES=() DENY_N=0   # DENY_N guards every expansion: bash 3.2 + set -u rejects "${a[@]}" on an empty array

die_usage() { echo "fleet queue: $1" >&2; echo "run 'fleet queue --help' for usage" >&2; exit 2; }

# Duration -> seconds on stdout; status 1 when malformed.
dur_secs() {
  case "$1" in
    *[!0-9smh]*|"") return 1 ;;
    *s) [[ "${1%s}" =~ ^[0-9]+$ ]] && echo "${1%s}" ;;
    *m) [[ "${1%m}" =~ ^[0-9]+$ ]] && echo $(( ${1%m} * 60 )) ;;
    *h) [[ "${1%h}" =~ ^[0-9]+$ ]] && echo $(( ${1%h} * 3600 )) ;;
    *)  [[ "$1" =~ ^[0-9]+$ ]] && echo $(( $1 * 60 )) ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON=1; shift ;;
    --deadline|--poll|--mem-limit|--changelog|--skip-audit|--deny-file)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "$1 needs a value"
      case "$1" in
        --deadline) DEADLINE_ARG=$2 ;;
        --poll) POLL_ARG=$2 ;;
        --mem-limit) MEM_LIMIT=$2 ;;
        --changelog) CHANGELOG=$2 ;;
        --deny-file)
          [[ -f "$2" ]] || { echo "fleet queue: deny file not found: $2" >&2; exit 3; }
          DENY_FILES+=("$2"); DENY_N=$((DENY_N + 1)) ;;
        --skip-audit)
          case "$2" in dropped|glued|released|dups|deny) SKIP_AUDITS+="$2 " ;;
            *) die_usage "--skip-audit takes dropped, glued, released, dups or deny, not '$2'" ;; esac ;;
      esac
      shift 2 ;;
    --) shift; PAIRS+=("$@"); break ;;
    -*) die_usage "unknown option: $1" ;;
    *) PAIRS+=("$1"); shift ;;
  esac
done

[[ ${#PAIRS[@]} -ge 2 ]] || die_usage "give at least one <lane> <tip> pair"
(( ${#PAIRS[@]} % 2 == 0 )) || die_usage "lanes and tips must come in pairs; '${PAIRS[${#PAIRS[@]}-1]}' has no tip"
DEADLINE=$(dur_secs "$DEADLINE_ARG") || die_usage "bad --deadline '$DEADLINE_ARG' (use 45s, 30m, 2h)"
POLL=$(dur_secs "$POLL_ARG") || die_usage "bad --poll '$POLL_ARG' (use 45s, 30m, 2h)"
[[ "$POLL" -ge 1 ]] || POLL=1
if [[ "$MEM_LIMIT" != "off" ]] && ! [[ "$MEM_LIMIT" =~ ^[0-9]+$ && "$MEM_LIMIT" -ge 1 && "$MEM_LIMIT" -le 100 ]]; then
  die_usage "--mem-limit takes 1-100 or off, not '$MEM_LIMIT'"
fi

# === SETUP ====================================================================
# The main checkout, from any worktree: lands happen there (fleet.sh resolves it the
# same way), so the audits must read the same repository the land will write.
if ! GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null); then
  echo "fleet queue: not inside a git repository" >&2; exit 5
fi
REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 5
[[ -f "$FLEET" ]] || { echo "fleet queue: $FLEET is missing" >&2; exit 5; }
# merge-tree --write-tree (git 2.38+) is the trial merge; older git exits 129 on it.
if ! git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; then
  echo "fleet queue: needs git 2.38+ for 'git merge-tree --write-tree' (have: $(git --version))" >&2
  exit 5
fi
# --quiet skips the session-store diagnostics `fleet config` prints, which can scan for
# tens of seconds on a busy machine; the base branch is all this needs.
BASE=$(bash "$FLEET" config --quiet 2>/dev/null | sed -n 's/^base_branch=//p')
BASE=${BASE:-main}
git rev-parse -q --verify "refs/heads/$BASE" >/dev/null || { echo "fleet queue: base branch '$BASE' does not exist" >&2; exit 5; }

LOG_DIR=".claude/fleet/queue"   # one log per lane, the last land attempt's output
WORK="$(mktemp -d)" || exit 5
trap 'rm -rf "$WORK"' EXIT
START=$(date +%s)

say() { echo "[$(date '+%H:%M:%S')] queue: $*" >&2; }
past_deadline() { (( $(date +%s) - START >= DEADLINE )); }
# Sleep one poll, never past the deadline.
nap() {
  local left=$(( START + DEADLINE - $(date +%s) ))
  (( left > 0 )) || return 0
  sleep $(( left < POLL ? left : POLL ))
}

# === RESULTS ==================================================================
ROWS=()        # lane TAB tip TAB result TAB detail, in order
FIRST_RC=0     # exit code of the first lane that did not succeed

row() { # lane tip result detail rc
  local line
  line=$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4//$'\t'/ }")
  ROWS+=("$line")
  [[ $JSON -eq 1 ]] || printf '%s\n' "$line"
  if [[ "$5" -ne 0 && $FIRST_RC -eq 0 ]]; then FIRST_RC=$5; fi
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

emit_json() {
  local i first=1 lane tip result detail
  printf '{"data":['
  for i in "${!ROWS[@]}"; do
    IFS=$'\t' read -r lane tip result detail <<< "${ROWS[$i]}"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"lane":%s,"tip":%s,"result":%s,"detail":%s}' \
      "$(json_str "$lane")" "$(json_str "$tip")" "$(json_str "$result")" "$(json_str "$detail")"
  done
  printf '],"meta":{"count":%d,"schema":"%s","exit":%d,"dry_run":%s}}\n' \
    "${#ROWS[@]}" "$SCHEMA" "$FIRST_RC" "$([[ $DRY_RUN -eq 1 ]] && echo true || echo false)"
}

# === AUDITS ===================================================================
# Each audit reads the would-be merge tree $T against the base tip $B. It prints its
# findings on stdout (one per line) and returns 0 when there are none, 1 when there are,
# 2 when a producer failed: an audit that could not read its input must not pass.

# Removed ($1 = -) or added ($1 = +) lines of a unified diff on stdin, hunk bodies only,
# never the ---/+++ headers. Every line counts: a removed bullet shows as "-- **x**", which
# a '^-[^-]' filter never sees, and a blank line as a bare "-".
hunk_lines() { awk -v s="$1" '/^diff --git/{h=0} /^@@/{h=1; next} h && substr($0, 1, 1) == s {print substr($0, 2)}'; }

audit_dropped() { # B T lane
  local B=$1 T=$2 lane=$3 merged own
  git cat-file -e "$T:$CHANGELOG" 2>/dev/null || return 0
  git cat-file -e "$B:$CHANGELOG" 2>/dev/null || return 0
  merged=$(git diff --no-color "$B" "$T" -- "$CHANGELOG") || return 2
  # The lane's own removals: each non-merge commit's own patch. A removal made inside a
  # merge commit (a "keep both sides" resolution) is in none of them, so it is caught.
  own=$(git log --no-merges --no-color -p --format= "$B..$lane" -- "$CHANGELOG") || return 2
  # Ours + theirs - base, as multisets: a line the merge removes AND adds was moved (git
  # often aligns a reordered changelog as replacements), so only a NET loss counts.
  printf '%s\n' "$merged" | hunk_lines - | LC_ALL=C sort > "$WORK/merged-rm"
  printf '%s\n' "$merged" | hunk_lines + | LC_ALL=C sort > "$WORK/merged-add"
  printf '%s\n' "$own" | hunk_lines - | LC_ALL=C sort > "$WORK/own"
  LC_ALL=C comm -23 "$WORK/merged-rm" "$WORK/merged-add" > "$WORK/merged-net" || return 2
  LC_ALL=C comm -23 "$WORK/merged-net" "$WORK/own" > "$WORK/dropped" || return 2
  [[ -s "$WORK/dropped" ]] || return 0
  sed 's/^/dropped: /' "$WORK/dropped"
  return 1
}

# [Unreleased] "- **" entries whose previous line is neither blank nor a ### heading.
glued_entries() {
  awk '{ sub(/\r$/, "") }
       /^## \[Unreleased\]/ { u = 1 }
       /^## \[[0-9]/        { u = 0 }
       u && /^- \*\*/ && prev != "" && prev !~ /^### / { print }
       { prev = $0 }' | LC_ALL=C sort
}

audit_glued() { # B T
  local B=$1 T=$2 now was
  git cat-file -e "$T:$CHANGELOG" 2>/dev/null || return 0
  now=$(git show "$T:$CHANGELOG") || return 2
  # Baselined against the base, so a glue already there cannot stop every later land.
  was=$(git show "$B:$CHANGELOG" 2>/dev/null) || was=""
  printf '%s\n' "$now" | glued_entries > "$WORK/glued-now"
  printf '%s\n' "$was" | glued_entries > "$WORK/glued-was"
  LC_ALL=C comm -23 "$WORK/glued-now" "$WORK/glued-was" > "$WORK/glued" || return 2
  [[ -s "$WORK/glued" ]] || return 0
  cut -c1-72 "$WORK/glued" | sed 's/^/glued: /'
  return 1
}

# Released sections as "<version> TAB <line>", one row per line. A section runs from its
# "## [x.y.z]" heading to the next "## " heading. Link-reference lines ("[3.9.0]: https://
# ...") are a footer that every release cut rewrites, so they belong to no section.
released_lines() {
  awk '{ sub(/\r$/, "") }
       /^## / { v = ""; if (match($0, /^## \[[0-9][^]]*\]/)) v = substr($0, 5, RLENGTH - 5) }
       /^\[[^]]+\]: / { next }
       v != "" { print v "\t" $0 }'
}

audit_released() { # B T
  local B=$1 T=$2 was now versions v a b gains loses rc=0
  git cat-file -e "$B:$CHANGELOG" 2>/dev/null || return 0
  if ! git cat-file -e "$T:$CHANGELOG" 2>/dev/null; then echo "released: the merge deletes $CHANGELOG"; return 1; fi
  was=$(git show "$B:$CHANGELOG") || return 2
  now=$(git show "$T:$CHANGELOG") || return 2
  printf '%s\n' "$was" | released_lines > "$WORK/rel-was"
  printf '%s\n' "$now" | released_lines > "$WORK/rel-now"
  versions=$(cut -f1 "$WORK/rel-was" | uniq) || return 2
  # procsub guard: the version list is captured and its status checked above, then looped
  # from a here-string, so a cut that died part-way fails the audit, never skips sections.
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    # Every section the base has must come through byte for byte. A section only the
    # merge has (a release cut) is not in this loop, so it is allowed.
    a=$(awk -F'\t' -v v="$v" '$1 == v' "$WORK/rel-was")
    b=$(awk -F'\t' -v v="$v" '$1 == v' "$WORK/rel-now")
    [[ "$a" == "$b" ]] && continue
    rc=1
    if [[ -z "$b" ]]; then echo "released: [$v] is gone from the merge"; continue; fi
    printf '%s\n' "$a" | LC_ALL=C sort > "$WORK/rel-a"
    printf '%s\n' "$b" | LC_ALL=C sort > "$WORK/rel-b"
    gains=$(LC_ALL=C comm -13 "$WORK/rel-a" "$WORK/rel-b" | cut -f2- | sed '/^$/d' | head -n 3)
    loses=$(LC_ALL=C comm -23 "$WORK/rel-a" "$WORK/rel-b" | cut -f2- | sed '/^$/d' | head -n 3)
    [[ -z "$gains" ]] || awk -v p="released: [$v] gains: " '{ print p substr($0, 1, 100) }' <<< "$gains"
    [[ -z "$loses" ]] || awk -v p="released: [$v] loses: " '{ print p substr($0, 1, 100) }' <<< "$loses"
    [[ -n "$gains$loses" ]] || echo "released: [$v] changed (blank lines or order)"
  done <<< "$versions"
  return $rc
}

# Names defined twice at top level: shell "name()", Python "def name", "CONSTANT = ".
dup_defs() {
  grep -oE '^[a-z_][a-z0-9_]*\(\)|^function [a-z_][a-z0-9_]*|^def [a-z_][a-z0-9_]*|^[A-Z_][A-Z0-9_]+ = ' \
    | LC_ALL=C sort | uniq -d
}

audit_dups() { # B T
  local B=$1 T=$2 files f now was rc=0
  files=$(git diff --no-color --name-only "$B" "$T") || return 2
  # procsub guard: the file list is captured and its status checked above, then looped
  # from a here-string, so a diff that died part-way fails this audit rather than
  # quietly auditing fewer files.
  while IFS= read -r f; do
    case "$f" in *.sh|*.py) ;; *) continue ;; esac
    git cat-file -e "$T:$f" 2>/dev/null || continue
    now=$(git show "$T:$f") || return 2
    # A .sh may embed several Python heredocs that each define the same helper; that
    # is already on the base and fine. Only a duplicate the MERGE introduces counts.
    was=$(git show "$B:$f" 2>/dev/null) || was=""
    printf '%s\n' "$now" | dup_defs > "$WORK/dups-now"
    printf '%s\n' "$was" | dup_defs > "$WORK/dups-was"
    LC_ALL=C comm -23 "$WORK/dups-now" "$WORK/dups-was" > "$WORK/dups" || return 2
    if [[ -s "$WORK/dups" ]]; then
      echo "dups: $f: $(tr '\n' ' ' < "$WORK/dups")"
      rc=1
    fi
  done <<< "$files"
  return $rc
}

# Lines the merge adds, as "path TAB line-in-merge TAB text", from a -U0 diff on stdin.
added_lines() {
  awk '/^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
       /^@@/        { split($3, h, ","); n = substr(h[1], 2) + 0; next }
       /^\+/        { print f "\t" n "\t" substr($0, 2); n++ }'
}

# Line numbers (in the text on stdin) matching regex $1, case-insensitive. ripgrep when
# present, since that is the syntax private deny lists are written in; else grep -E.
# Status 0 hits, 1 none, 2 the pattern is not a valid regex.
deny_grep() {
  if command -v rg >/dev/null 2>&1; then rg -i -n --no-heading -e "$1" | cut -d: -f1
  else grep -Ein -e "$1" | cut -d: -f1; fi
}

# Any added line matching a --deny-file pattern. Findings name file, line and the
# pattern's number in its list, NEVER the matched text (see the contract above). Unlike a
# repo's own leak gate, it reads every file, CHANGELOG and plans included: those are
# skipped there because they are history, and this reads only what the merge ADDS.
audit_deny() { # B T
  [[ $DENY_N -gt 0 ]] || return 0
  local B=$1 T=$2 diff f p i hits n loc rc=0 shown=0
  diff=$(git diff --no-color --no-ext-diff -U0 "$B" "$T") || return 2
  printf '%s\n' "$diff" | added_lines > "$WORK/added"
  cut -f3- "$WORK/added" > "$WORK/added-text"
  for f in "${DENY_FILES[@]}"; do
    i=0
    while IFS= read -r p || [[ -n "$p" ]]; do
      p=${p%$'\r'}
      case "$p" in ''|'#'*) continue ;; esac
      i=$((i + 1))
      hits=$(deny_grep "$p" < "$WORK/added-text"); n=$?
      if [[ $n -ge 2 ]]; then echo "error: pattern #$i of $(basename "$f") is not a valid regex"; return 2; fi
      [[ -n "$hits" ]] || continue
      rc=1
      for n in $hits; do
        loc=$(sed -n "${n}p" "$WORK/added" | cut -f1,2 | tr '\t' ':')
        (( shown < 20 )) && echo "deny: $loc matches pattern #$i of $(basename "$f")"
        shown=$((shown + 1))
      done
    done < "$f"
  done
  (( shown <= 20 )) || echo "deny: ... $((shown - 20)) more"
  return $rc
}

# Run every audit not skipped; findings go to $WORK/findings. Status 0 clean, 1 findings,
# 2 a producer failed.
run_audits() { # B T lane
  local name rc worst=0
  : > "$WORK/findings"
  for name in dropped glued released dups deny; do
    [[ "$SKIP_AUDITS" == *" $name "* ]] && continue
    case "$name" in
      dropped)  audit_dropped "$1" "$2" "$3" >> "$WORK/findings"; rc=$? ;;
      glued)    audit_glued "$1" "$2" >> "$WORK/findings"; rc=$? ;;
      released) audit_released "$1" "$2" >> "$WORK/findings"; rc=$? ;;
      dups)     audit_dups "$1" "$2" >> "$WORK/findings"; rc=$? ;;
      deny)     audit_deny "$1" "$2" >> "$WORK/findings"; rc=$? ;;
    esac
    if [[ $rc -eq 2 ]]; then echo "error: the $name audit could not read its input" >> "$WORK/findings"; worst=2
    elif [[ $rc -ne 0 && $worst -eq 0 ]]; then worst=1; fi
  done
  return $worst
}

# === CHECKS ===================================================================
# Trial merge of $2 into $1. Sets MT_TREE (the would-be tree) and MT_CONFLICTS (file
# names, space-separated). Status 0 clean, 1 conflicts, 2 error.
MT_TREE="" MT_CONFLICTS=""
trial_merge() {
  local out rc
  MT_TREE="" MT_CONFLICTS=""
  out=$(git merge-tree --write-tree --name-only "$1" "$2" 2>&1); rc=$?
  MT_TREE=$(printf '%s\n' "$out" | head -n1)
  if [[ $rc -eq 1 ]]; then
    MT_CONFLICTS=$(printf '%s\n' "$out" | sed -n '2,/^$/p' | sed '/^$/d' | head -n 8 | tr '\n' ' ')
    return 1
  fi
  [[ $rc -eq 0 && "$MT_TREE" =~ ^[0-9a-f]{40,64}$ ]] || return 2
  return 0
}

# Does landing $2 give the same base as landing the reviewed $1? Both must merge cleanly
# into the base, to the same tree. Fleet's auto-rebase, a squash, or a changed merge
# context all pass; any change of content does not.
same_outcome() {
  local t1 t2
  trial_merge "$B" "$1" || return 1; t1=$MT_TREE
  trial_merge "$B" "$2" || return 1; t2=$MT_TREE
  [[ "$t1" == "$t2" ]]
}

worktree_of() {
  git worktree list --porcelain 2>/dev/null | awk -v want="branch refs/heads/$1" '
    /^worktree / { p = substr($0, 10) }
    $0 == want   { print p; exit }'
}

# Commit charge, percent, on stdout; status 1 when this host has none to measure (not
# Windows) or the reading failed. FLEET_QUEUE_COMMIT_PCT overrides it on any OS: the
# suite's way in, and an escape hatch when the counter itself is broken.
commit_pct() {
  local pct
  if [[ -n "${FLEET_QUEUE_COMMIT_PCT:-}" ]]; then
    pct=$FLEET_QUEUE_COMMIT_PCT
  else
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
    # Win32_OperatingSystem, not Get-Counter: the counter names are localised on
    # non-English Windows, and one CIM read is about twice as fast as two counters.
    pct=$(powershell.exe -NoProfile -NonInteractive -Command \
      '$o=Get-CimInstance Win32_OperatingSystem; [math]::Round(100*($o.TotalVirtualMemorySize-$o.FreeVirtualMemory)/$o.TotalVirtualMemorySize)' \
      2>/dev/null </dev/null | tr -d '\r')
  fi
  [[ "$pct" =~ ^[0-9]+$ ]] || return 1
  echo "$pct"
}

# Wait until the commit charge is under --mem-limit. Windows commit exhaustion makes
# Git Bash fail to fork (Win32 error 299), which a gate reports as test failures in
# code the lane never touched. Status 0 ok to gate, 1 the deadline passed first.
memory_guard() {
  [[ "$MEM_LIMIT" == "off" ]] && return 0
  local pct
  while true; do
    if ! pct=$(commit_pct); then
      # Fail open, loudly: this guard only spares a gate a fake failure, and a gate
      # that does fail resets the base itself. Blocking forever on a broken counter
      # would stop every land on the machine.
      if [[ -n "${FLEET_QUEUE_COMMIT_PCT:-}" ]]; then
        say "memory guard: FLEET_QUEUE_COMMIT_PCT='$FLEET_QUEUE_COMMIT_PCT' is not a number; gating anyway"
      else
        case "$(uname -s 2>/dev/null)" in
          MINGW*|MSYS*|CYGWIN*) say "memory guard: could not read the commit charge; gating anyway" ;;
        esac
      fi
      return 0
    fi
    if (( pct < MEM_LIMIT )); then return 0; fi
    if past_deadline; then MEM_LAST=$pct; return 1; fi
    say "commit charge ${pct}% >= ${MEM_LIMIT}% - waiting before starting a gate"
    nap
  done
}
MEM_LAST=""

# Fleet refusals that happen before any merge and clear by themselves. The texts are
# fleet.sh's own log lines (session_land_gate, log_landing_busy); tests/queue.sh pins
# them against the real fleet.sh so a rewording cannot silently stop the retry.
RETRYABLE='REFUSE LAND: .* has a LIVE session|REFUSE LAND: .* AND another LIVE session|REFUSE LAND: .*another land is in progress|could not verify live claimants'

# === ONE LANE =================================================================
# Settle, check, audit, guard, land; retry what clears by itself. Emits one row.
B=""
queue_one() {
  local lane=$1 want=$2 frozen tip wt dirty findings log name rc before after waited=0 tracked=0 note=""
  name=${lane//\//_}
  log="$LOG_DIR/$name.log"
  if ! git rev-parse -q --verify "refs/heads/$lane" >/dev/null; then
    row "$lane" "$want" missing "no local branch $lane" 3; return
  fi
  if ! frozen=$(git rev-parse -q --verify "$want^{commit}" 2>/dev/null); then
    row "$lane" "$want" missing "tip $want is not a commit here" 3; return
  fi

  while true; do
    # 1. The base must be settled: audits against a PROVISIONAL tip judge a merge a red
    #    gate may reset, and fleet land would refuse anyway.
    bash "$FLEET" landing >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 10 && $DRY_RUN -eq 1 ]]; then
      say "$BASE is not settled (fleet landing exit 10): dry-run results are against a provisional tip"
    elif [[ $rc -eq 10 ]]; then
      if past_deadline; then row "$lane" "${frozen:0:7}" timeout "$BASE never settled before the deadline" 6; return; fi
      [[ $waited -eq 1 ]] || say "$lane: waiting for $BASE to settle (fleet landing exit 10)"
      waited=1; nap; continue
    elif [[ $rc -ne 0 ]]; then
      row "$lane" "${frozen:0:7}" failed "fleet landing exited $rc" 5; return
    fi
    waited=0
    B=$(git rev-parse "refs/heads/$BASE")

    # 2. Still the reviewed tip, or a rebase with the identical outcome.
    tip=$(git rev-parse "refs/heads/$lane")
    if [[ "$tip" != "$frozen" ]]; then
      if same_outcome "$frozen" "$tip"; then
        say "$lane: tip ${frozen:0:7} -> ${tip:0:7} merges to the same tree (a rebase); continuing"
        note=" (rebased from ${frozen:0:7})"
        frozen=$tip
      else
        row "$lane" "${frozen:0:7}" moved "tip is now ${tip:0:7} and merges to different content: review it again" 11; return
      fi
    fi

    # 3. Clean trees: tracked changes in the lane mean its owner may still be working (the
    #    same rule signal.sh READY applies); a dirty base checkout makes fleet land refuse.
    #    Untracked files (a lane's tee'd test log) do not block the land, but they are
    #    named, because archiving the session later would delete them with the worktree.
    wt=$(worktree_of "$lane")
    if [[ -n "$wt" ]]; then
      dirty=$(git -C "$wt" status --porcelain --untracked-files=no 2>&1) || dirty="status failed: $dirty"
      if [[ -n "$dirty" ]]; then row "$lane" "${frozen:0:7}" dirty "lane worktree $wt has uncommitted tracked changes" 11; return; fi
      dirty=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | head -n 3 | tr '\n' ' ')
      [[ -z "$dirty" ]] || say "$lane: untracked files in $wt (not landed; archiving would delete them): $dirty"
    fi
    dirty=$(git status --porcelain --untracked-files=no 2>&1) || dirty="status failed: $dirty"
    if [[ -n "$dirty" ]]; then row "$lane" "${frozen:0:7}" dirty "$BASE checkout $REPO_ROOT has uncommitted tracked changes" 11; return; fi

    # 4. Trial merge. Nothing to add means it is already in the base by content (a
    #    squash or cherry-pick); landing it again would be an empty merge and a gate.
    trial_merge "$B" "$frozen"; rc=$?
    if [[ $rc -eq 1 ]]; then row "$lane" "${frozen:0:7}" conflict "conflicts with $BASE ${B:0:7}: ${MT_CONFLICTS% }" 10; return; fi
    if [[ $rc -ne 0 ]]; then row "$lane" "${frozen:0:7}" failed "git merge-tree failed" 1; return; fi
    if [[ "$MT_TREE" == "$(git rev-parse "$B^{tree}")" ]]; then
      row "$lane" "${frozen:0:7}" already "its content is already in $BASE ${B:0:7}$note" 0; return
    fi

    # 5. Audit the would-be merge.
    run_audits "$B" "$MT_TREE" "$frozen"; rc=$?
    if [[ $rc -ne 0 ]]; then
      findings=$(cat "$WORK/findings")
      say "$lane: audit of the would-be merge into $BASE ${B:0:7} failed:"
      sed 's/^/  /' <<< "$findings" >&2
      row "$lane" "${frozen:0:7}" audit "$(printf '%s' "$findings" | head -n 3 | tr '\n' ';' | cut -c1-200)" 4; return
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      row "$lane" "${frozen:0:7}" clean "merges into $BASE ${B:0:7} cleanly; audits clean$note" 0; return
    fi

    # 6. Memory headroom for the gate (Windows only; a no-op elsewhere).
    if ! memory_guard; then
      row "$lane" "${frozen:0:7}" timeout "commit charge stayed at ${MEM_LAST}% >= ${MEM_LIMIT}% until the deadline" 6; return
    fi
    if past_deadline; then
      row "$lane" "${frozen:0:7}" timeout "deadline passed before the land could start" 6; return
    fi

    # 7. Land. Track it once so fleet rebases it if another land gets in first.
    if [[ $tracked -eq 0 ]]; then bash "$FLEET" track "$lane" >/dev/null 2>&1 || true; tracked=1; fi
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    before=$(git rev-parse "refs/heads/$BASE")
    say "$lane: fleet land (attempt log: $log)"
    bash "$FLEET" land "$lane" > "$log" 2>&1; rc=$?
    after=$(git rev-parse "refs/heads/$BASE")
    if [[ $rc -ne 0 ]] && grep -Eq "$RETRYABLE" "$log"; then
      if past_deadline; then
        row "$lane" "${frozen:0:7}" timeout "still refused at the deadline: $(grep -Em1 "$RETRYABLE" "$log" | sed 's/^\[[0-9:]*\] //')" 6; return
      fi
      say "$lane: $(grep -Em1 "$RETRYABLE" "$log" | sed 's/^\[[0-9:]*\] //' | cut -c1-120) - retry in ${POLL}s"
      [[ "$after" == "$before" ]] || say "$lane: $BASE moved meanwhile (${before:0:7} -> ${after:0:7}); re-auditing"
      nap; continue
    fi
    if [[ $rc -eq 0 ]]; then
      if grep -q 'ALREADY LANDED' "$log"; then
        row "$lane" "${frozen:0:7}" already "fleet land: already in $BASE$note" 0
      else
        row "$lane" "${frozen:0:7}" landed "$BASE ${after:0:7} (gate green)$note" 0
      fi
      return
    fi
    grep -E 'running test_cmd|PASS|FAIL|REFUSE|CONFLICT|reset|ERROR' "$log" | tail -n 8 >&2
    row "$lane" "${frozen:0:7}" failed \
      "$(grep -E 'REFUSE|FAIL|MERGE CONFLICT|ERROR' "$log" | tail -n1 | sed 's/^\[[0-9:]*\] //' | cut -c1-160) (log: $log)" 12
    return
  done
}

# === MAIN =====================================================================
i=0 stopped=""
while [[ $i -lt ${#PAIRS[@]} ]]; do
  lane=${PAIRS[$i]} tip=${PAIRS[$((i+1))]}
  i=$((i+2))
  if [[ -n "$stopped" ]]; then
    row "$lane" "$tip" skipped "not attempted: $stopped stopped the queue" 0
    continue
  fi
  before_rc=$FIRST_RC
  queue_one "$lane" "$tip"
  if [[ $DRY_RUN -eq 0 && $FIRST_RC -ne 0 && $before_rc -eq 0 ]]; then stopped=$lane; fi
done

if [[ $JSON -eq 1 ]]; then emit_json; fi
exit "$FIRST_RC"
