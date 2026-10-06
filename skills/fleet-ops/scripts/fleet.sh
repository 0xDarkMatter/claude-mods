#!/usr/bin/env bash
# fleet-ops — landing discipline for parallel work: sequential landing queue
# with test gate, pre-land scrub, auto-rebase, one-shot revert.
# Spawning/monitoring parallel sessions is native Claude Code territory
# (agent teams, claude --bg / agent view); this script governs landing, and
# reclaiming the worktrees afterwards.
#
# SECTION MAP (grep the `=== NAME ===` banners to jump):
#   CONFIG              parse .claude/fleet/config — parsed, never sourced
#   lane state          encode/decode lane files, state read/write, scrub
#   init / track        create or register lanes
#   status views        fleet_view_panel, fleet_view_verbose, cmd_main, cmd_config
#   SESSION AWARENESS   who owns a lane, and are they still writing (sessions.sh)
#   PRUNE               worktree housekeeping — the only part that DELETES
#   LANDING MARKER      one land at a time; recovering a land that died mid-way;
#                       is the base tip provisional (fleet landing, status line)
#   landing             land_one, rebase_others, cmd_land, cmd_land_all, revert
#   daemon              cmd_start / cmd_stop, PID file lifecycle
#   dispatch            the subcommand case at the bottom
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""

# Where the user actually invoked us from, captured BEFORE the cd below.
# `fleet prune` needs it: the cd lands us in the main checkout no matter which
# worktree we were called from, so without this the invoking worktree looks
# like any other removal candidate and could be deleted out from under the
# caller's own shell.
#
# cygpath -m is not cosmetic here. Git Bash's `pwd` yields "/x/Forge/repo" while
# `git worktree list` yields "D:/code/repo"; string-comparing those two never
# matches, and the guard silently stops guarding. Converting to git's own
# mixed form is what makes the comparison mean anything on Windows.
INVOKED_FROM="$(pwd -P 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  INVOKED_FROM="$(cygpath -m "$INVOKED_FROM" 2>/dev/null || printf '%s' "$INVOKED_FROM")"
fi

# Resolve repo root via git, so fleet works from any worktree.
# cd to it once so all relative paths below resolve correctly.
if GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null); then
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
  cd "$REPO_ROOT"
fi

FLEET_DIR=".claude/fleet"
LANES_DIR="$FLEET_DIR/lanes"
LOG="$FLEET_DIR/activity.log"
CONFIG="$FLEET_DIR/config"
PID_FILE="$FLEET_DIR/daemon.pid"
# The land in progress right now, by any fleet process. Format at claim_landing;
# why it exists at the LANDING MARKER banner.
LANDING_FILE="$FLEET_DIR/landing"

# defaults (overridable via .claude/fleet/config — see load_config below)
MODE="auto"
# Default worktree root sits at repo top, NOT under .claude/. Claude Code's
# headless mode (--dangerously-skip-permissions) bypasses prompts but still
# enforces the global .claude/ sensitive-file guard, so worktrees nested
# under .claude/ can't be written to by lane sessions. See SKILL.md
# "Headless agent compatibility".
WORKTREE_ROOT=".fleet-worktrees"
TEST_CMD=""
# Scrub default. BUILT by string concatenation so this line never contains a
# contiguous marker token — the scrub gate greps every ADDED diff line, so a
# literal here would refuse the very branch that edits this default (same
# trick as the marker note in tests/run.sh). The X-marker term is written
# X{3} with [^X] guards for the same reason, and because a run of 4+ X's is a
# mktemp template (push-gate-paths. plus six X's — false-refused a landing,
# 2026-09-01), not a marker; a lone triple-X followed by a non-letter
# (space, colon) still refuses.
FORBIDDEN_PATTERN='TODO_''SCRUB|(^|[^X])X{3}[^a-zX]|FIXME_''BEFORE_LAND'
BASE_BRANCH="main"
POLL_INTERVAL=5
ICONS="${icons:-}"   # env seed; config `icons=ascii` overrides below
# Session awareness (see scripts/sessions.sh). Enrichment only: when the session
# store is unreadable — a terminal-only machine, no jq, a non-Desktop host —
# every check below degrades to "no info" and landing behaves exactly as it did
# before this existed. It must never become a hard dependency.
SESSION_CHECK="on"
SESSION_LIVE_SECS=600
# Whether `fleet status` surfaces the prunable-worktree backlog. On by default:
# the whole point is that an unswept backlog is invisible otherwise.
PRUNE_HINT="on"

# === ONE-RUN ENV OVERRIDES ====================================================
# FLEET_SKIP_SESSION_CHECK means "skip the live-owner gate for THIS invocation"
# — but an exported env var inherits into every child process, test_cmd
# included. On 2026-09-01 `FLEET_SKIP_SESSION_CHECK=1 fleet land` leaked the
# override into the post-merge test suite, which runs fleet-ops' own self-test;
# the live-owner gate that suite asserts REFUSES was disarmed inside every
# sandboxed test repo, 6 tests failed, and a genuinely green merge was
# hard-reset as a false FAIL. So: read it ONCE here, strip it from the
# environment immediately, and use the internal copy everywhere below. land_one
# additionally sanitizes the wider FLEET_* knob family around test_cmd.
SKIP_SESSION_CHECK="${FLEET_SKIP_SESSION_CHECK:-}"
unset FLEET_SKIP_SESSION_CHECK

# === CONFIG ===================================================================
# The config is PARSED, never `source`d. Two reasons, both learned the hard way
# (2026-07: every documented key had been a silent no-op since the file shipped):
#
#   1. `source` binds the key's own case — the file documents lowercase keys
#      (`test_cmd=`), the script reads UPPERCASE (`$TEST_CMD`), so a sourced
#      config set a variable nothing ever read. `fleet land` therefore never ran
#      a test gate on any repo; it always fell through to signal.sh's log gate.
#   2. `source` is bash, so an unquoted value containing spaces
#      (`test_cmd=python -m pytest`) is not an assignment at all — bash reads it
#      as "run `-m` with test_cmd exported". It fails, and the old `2>/dev/null`
#      swallowed the error, making a broken config indistinguishable from none.
#
# Parsing also means the config can't execute code, which a `source`d file could.
# Keys are matched case-insensitively so configs written either way keep working.
# NEVER silence this parser: a config that yields nothing must say so.

config_warn() {
  local msg="[$(date '+%H:%M:%S')] fleet config: $*"
  echo "$msg" >&2
  # activity.log may not exist yet (ensure_fleet_dir runs later) — best effort.
  [[ -d "$FLEET_DIR" ]] && echo "$msg" >> "$LOG" 2>/dev/null
  return 0
}

# Strip leading and trailing whitespace. bash 3.2-safe (macOS ships 3.2).
config_trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Parse key=value lines. Grammar (documented identically in SKILL.md):
#   - one key=value per line; whitespace around key and '=' is ignored
#   - value runs to end of line, so spaces need NO quoting
#   - optional surrounding "…" or '…' is stripped (protects a literal trailing #)
#   - unquoted values lose a trailing ` # comment`; quoted values keep everything
#   - '#' at line start = comment; blank lines ignored
load_config() {
  local file=$1
  [[ -f "$file" ]] || return 0
  if [[ ! -r "$file" ]]; then
    config_warn "$file exists but is not readable — using defaults"
    return 0
  fi

  local recognised=0 lineno=0 line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"                 # CRLF configs (Windows editors)
    line="$(config_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != *=* ]]; then
      config_warn "$file:$lineno — not a key=value line, ignored: $line"
      continue
    fi
    key="$(config_trim "${line%%=*}")"
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    val="$(config_trim "${line#*=}")"

    case "$val" in
      # Quoted: value is everything up to the closing quote; rest is discarded.
      \"*) val="${val#\"}"; val="${val%%\"*}" ;;
      \'*) val="${val#\'}"; val="${val%%\'*}" ;;
      # Unquoted: drop a trailing ` # comment` (matches shell intuition, and the
      # SKILL.md example block is annotated that way — a verbatim copy must work).
      *)   val="${val%%[[:space:]]#*}"; val="$(config_trim "$val")" ;;
    esac

    case "$key" in
      mode)              MODE="$val" ;;
      worktree_root)     WORKTREE_ROOT="$val" ;;
      test_cmd)          TEST_CMD="$val" ;;
      forbidden_pattern) FORBIDDEN_PATTERN="$val" ;;
      base_branch)       BASE_BRANCH="$val" ;;
      icons)             ICONS="$val" ;;
      session_check)     SESSION_CHECK="$val" ;;
      prune_hint)        PRUNE_HINT="$val" ;;
      session_live_secs)
        if [[ "$val" =~ ^[0-9]+$ ]]; then
          SESSION_LIVE_SECS="$val"
        else
          config_warn "$file:$lineno — session_live_secs must be an integer, got '$val' (keeping $SESSION_LIVE_SECS)"
          continue
        fi
        ;;
      poll_interval)
        if [[ "$val" =~ ^[0-9]+$ ]]; then
          POLL_INTERVAL="$val"
        else
          config_warn "$file:$lineno — poll_interval must be an integer, got '$val' (keeping $POLL_INTERVAL)"
          continue
        fi
        ;;
      *)
        config_warn "$file:$lineno — unrecognised key '$key' (ignored)"
        continue
        ;;
    esac
    recognised=$((recognised + 1))
  done < "$file"

  if [[ $recognised -eq 0 ]]; then
    config_warn "$file set no recognised keys — running on defaults (test gate OFF)"
  fi
  return 0
}
load_config "$CONFIG"
# === END CONFIG ===============================================================

# Shared terminal-output helpers (see docs/TERMINAL-DESIGN.md).
# Sourced AFTER the config so `icons=ascii` in the config can reach term_init —
# when this ran first, that documented key was read before it was ever set.
# shellcheck source=../../_lib/term.sh
. "$SCRIPT_DIR/../../_lib/term.sh"
# Honor legacy FLEET_ASCII alongside TERM_ASCII.
if [[ "${FLEET_ASCII:-}" == "1" || "$ICONS" == "ascii" ]]; then export TERM_ASCII=1; fi
term_init

# Icons resolved through the shared term lib (term_state_icon).
ICON_RUNNING="$(term_state_icon RUNNING)"
ICON_READY="$(term_state_icon READY)"
ICON_LANDED="$(term_state_icon LANDED)"
ICON_FAILED="$(term_state_icon FAILED)"
ICON_CONFLICT="$(term_state_icon CONFLICT)"
ICON_UNKNOWN="?"

# Cross-platform mtime: GNU stat (Linux/Git Bash) vs BSD stat (macOS)
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

# Lane files are named after branches, but branch names can contain '/'
# (feat/x, fleet/x) — which would nest the lane into a nonexistent subdir and
# break `track`/status/daemon. Encode '/' (and the escape char) so every lane is
# one flat file under lanes/, and decode when mapping a filename back to a branch.
# signal.sh carries an identical encoder so the two interoperate.
encode_lane() { local s=${1//\%/%25}; printf '%s' "${s//\//%2F}"; }
decode_lane() { local s=${1//%2F/\/}; printf '%s' "${s//%25/\%}"; }

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }

maybe_commit_gitignore() {
  # Auto-commit the .gitignore append from ensure_fleet_dir, but only when
  # safe: must be on BASE_BRANCH and .gitignore must be the only change in
  # the tree. Otherwise warn loudly — the daemon's land step will refuse
  # otherwise with "main has uncommitted tracked changes".
  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$current" != "$BASE_BRANCH" ]]; then
    log "ACTION REQUIRED: .gitignore updated for fleet-ops runtime paths."
    log "                 You're on '$current', not '$BASE_BRANCH'. Switch to"
    log "                 '$BASE_BRANCH' and commit .gitignore before 'fleet start',"
    log "                 or the daemon will refuse to land with"
    log "                 'uncommitted tracked changes — clean before landing'."
    return 0
  fi
  local other_changes
  other_changes=$(git status --porcelain 2>/dev/null | grep -vE '^.. \.gitignore$' || true)
  if [[ -n "$other_changes" ]]; then
    log "ACTION REQUIRED: .gitignore updated for fleet-ops runtime paths,"
    log "                 but other uncommitted changes exist on $BASE_BRANCH."
    log "                 Commit .gitignore yourself before 'fleet start' or"
    log "                 the daemon will refuse to land. Suggested:"
    log "                   git add .gitignore && git commit -m 'chore: gitignore fleet-ops runtime state'"
    return 0
  fi
  git add .gitignore 2>/dev/null || { log "WARN: git add .gitignore failed"; return 0; }
  if git commit -m "chore: gitignore fleet-ops runtime state" -- .gitignore >/dev/null 2>&1; then
    log "auto-committed .gitignore (fleet-ops runtime paths: .claude/fleet/, .fleet-worktrees/)"
  else
    log "WARN: auto-commit of .gitignore failed — commit it manually before 'fleet start'"
  fi
}

ensure_fleet_dir() {
  mkdir -p "$LANES_DIR"
  [[ -f "$FLEET_DIR/signal.sh" ]] || cp "$SCRIPT_DIR/signal.sh" "$FLEET_DIR/signal.sh"
  chmod +x "$FLEET_DIR/signal.sh" 2>/dev/null || true
  # sessions.sh ships alongside signal.sh so a lane session — which only ever
  # sees .claude/fleet/, never the installed skill dir — can resolve MAIN's
  # address when it signals READY. Refreshed every time so a skill update
  # propagates (signal.sh is deliberately NOT overwritten: a repo may have
  # customised it).
  cp -f "$SCRIPT_DIR/sessions.sh" "$FLEET_DIR/sessions.sh" 2>/dev/null || true
  chmod +x "$FLEET_DIR/sessions.sh" 2>/dev/null || true
  # Auto-ignore fleet-ops runtime state in git so it doesn't show as "dirty"
  # or get committed. Two paths:
  #   .claude/fleet/      — lanes/, daemon.pid, landing, activity.log, signal.sh, config
  #   .fleet-worktrees/   — default worktree root (top-level so headless
  #                         Claude lane sessions can write there)
  if git rev-parse --git-dir >/dev/null 2>&1; then
    [[ -f .gitignore ]] || touch .gitignore
    # Accept the `dir/*` form as already-ignoring, not just `dir/`. A repo that
    # wants to track ONE file in here (e.g. a `config.example` so the landing
    # gate survives a fresh clone) MUST write `.claude/fleet/*` plus a `!`
    # negation — git cannot re-include a file whose parent DIRECTORY is
    # excluded. An exact-match grep does not see that as ignored, so it appended
    # a bare `.claude/fleet/` and auto-committed it, re-excluding the directory
    # and quietly undoing the repo's intent.
    local appended=0
    if ! grep -qxE '\.claude/fleet/\*?' .gitignore 2>/dev/null; then
      echo '.claude/fleet/' >> .gitignore
      appended=1
    fi
    if ! grep -qxE '\.fleet-worktrees/\*?' .gitignore 2>/dev/null; then
      echo '.fleet-worktrees/' >> .gitignore
      appended=1
    fi
    # NB: plain `[[ ... ]] && cmd` here would return 1 when nothing was
    # appended, and under set -e that kills any caller invoked after init.
    if [[ $appended -eq 1 ]]; then
      maybe_commit_gitignore
    fi
  fi
}

is_dirty_tracked() {
  # True only if tracked files have uncommitted changes (ignores untracked files)
  ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null
}

lane_state() { local f="$LANES_DIR/$(encode_lane "$1")"; [[ -f "$f" ]] && head -n1 "$f" || echo "MISSING"; }
set_lane_state() {
  local l=$1 s=$2 f
  f="$LANES_DIR/$(encode_lane "$l")"
  shift 2
  if [[ $# -gt 0 ]]; then
    printf '%s\n%s\n' "$s" "$*" > "$f"
  else
    printf '%s\n' "$s" > "$f"
  fi
}

# Delete a fleet state file (the MAIN pin, the daemon PID file) and PROVE it is
# gone, or fail out loud. These files are read back with `[[ -f ]]`, so one that
# survives its delete keeps meaning exactly what it meant before.
#
# One bare `rm -f` is not enough on Windows. A process holding the file open
# WITHOUT delete-sharing (the Win32/.NET default; antivirus and the search
# indexer do it for a moment after a write) makes the delete fail with EBUSY.
# `-f` does not hide that error, but a single attempt loses a race that a short
# wait wins. On 2026-10-05 the fleet-ops suite failed once under load with
# "release did not restore heuristic" and passed on rerun. A held pin reproduces
# that exactly (tests/run.sh "held-pin-release"): the pin survives and MAIN
# stays pinned. So: retry for up to FLEET_RM_RETRY_SECS (default 5, 0 = one try),
# judge success by the path being gone rather than by rm's status, and when
# giving up name the file, say why, and return 1.
# Callers print "cleared" only AFTER this returns 0.
remove_state_file() {
  local f=$1 what=$2 err="" warned=0 wait=${FLEET_RM_RETRY_SECS:-5}
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=5
  local deadline=$(( SECONDS + wait ))
  while :; do
    if err=$(rm -f -- "$f" 2>&1) && [[ ! -e "$f" ]]; then return 0; fi
    (( SECONDS < deadline )) || break
    if (( ! warned )); then
      echo "fleet: $what is held open by another process; retrying for up to ${wait}s (${err:-still present after rm})" >&2
      warned=1
    fi
    sleep 0.2
  done
  echo "fleet: ERROR: could not remove $what ($f): ${err:-still present after rm}" >&2
  echo "fleet:   another process is holding it open (antivirus, the search indexer, an editor). Close it and re-run." >&2
  return 1
}

scrub_diff() {
  # echoes hits (one per line) for given branch's diff vs base. Empty = clean.
  # ADDED lines only ('+…', not the '+++' file header): deletion lines, context
  # lines, and @@ hunk-header function-context must not trip the gate — removing
  # a forbidden marker is a fix, and a marker merely NEAR an edit is not one
  # (both false-positived here, 2026-07).
  local branch=$1
  git diff "$BASE_BRANCH"..."$branch" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+ ' | grep -nE "$FORBIDDEN_PATTERN" || true
}

refuse_if_shared_tree() {
  local trees lane_count
  trees=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | sort -u | wc -l)
  lane_count=$(ls -1 "$LANES_DIR" 2>/dev/null | wc -l)
  if [[ "$lane_count" -gt 1 && "$trees" -le 1 && "$MODE" != "branch" ]]; then
    log "ERROR: $lane_count lanes but only $trees worktree — sessions will collide"
    log "       Use worktrees, separate clones, or set mode=branch in $CONFIG to override"
    return 1
  fi
}

# The landing gate must be ARMED, or absent LOUDLY — never silently absent.
#
# TEST_CMD comes from $CONFIG, which repos routinely gitignore along with the
# rest of .claude/fleet/ (lane state is machine-local). So a `git clean`, a
# fresh clone, or a new worktree leaves it EMPTY. Until 2026-08-04 that case
# fell through to signal.sh's log gate — which verifies nothing at all when a
# lane signalled READY without a test log. The branch merged to $BASE_BRANCH
# having run zero tests, and the only trace was one line in activity.log.
#
# That is the dangerous shape: not "landing fails" but "landing SUCCEEDS having
# tested nothing". A gate that degrades to no gate is worse than one that
# breaks, because nothing reports the loss. Refuse instead.
#
# Deliberately does NOT touch lane state: an unarmed gate is a repo-level fault,
# not the lane's, and marking every lane CONFLICT would leave a human to undo
# state that was never wrong. Callers refuse BEFORE mutating anything.
require_test_cmd() {
  [[ -n "$TEST_CMD" ]] && return 0
  log "REFUSE: no test_cmd resolved from $CONFIG — the landing gate is UNARMED"
  log "        Landing now would merge without running any tests."
  log "        Set test_cmd in $CONFIG (some repos ship $CONFIG.example — copy it),"
  log "        then confirm with: fleet config"
  return 1
}

cmd_init() {
  ensure_fleet_dir
  [[ $# -eq 0 ]] && { echo "usage: fleet init <name>..." >&2; exit 1; }

  local mode="$MODE"
  [[ "$mode" == "auto" ]] && mode="worktree"   # default: worktree if git allows it

  for name in "$@"; do
    if git rev-parse --verify "$name" >/dev/null 2>&1; then
      log "skip branch (exists): $name"
    else
      git branch "$name" "$BASE_BRANCH"
      log "created branch: $name"
    fi
    if [[ "$mode" == "worktree" ]]; then
      local wt="$WORKTREE_ROOT/$name"
      if [[ -d "$wt" ]]; then
        log "skip worktree (exists): $wt"
      else
        mkdir -p "$WORKTREE_ROOT"
        git worktree add "$wt" "$name"
        log "created worktree: $wt"
      fi
    fi
    set_lane_state "$name" "RUNNING"
  done

  echo ""
  echo "Fleet initialized. Hand each session the prompt template:"
  echo "  $SCRIPT_DIR/../references/session-prompt.md"
  echo "Then: bash $0 start"
}

cmd_track() {
  # Register existing branches as lanes — the bridge from natively-spawned
  # work (agent teams, claude --bg auto-worktrees) into the landing queue.
  # Never creates or touches worktrees; the branch is taken as-is.
  ensure_fleet_dir
  [[ $# -eq 0 ]] && { echo "usage: fleet track <branch>..." >&2; exit 1; }
  local rc=0
  for name in "$@"; do
    if ! git rev-parse --verify "refs/heads/$name" >/dev/null 2>&1; then
      log "ERROR: no local branch '$name' — nothing to track"
      rc=1
      continue
    fi
    if [[ -f "$LANES_DIR/$(encode_lane "$name")" ]]; then
      log "already tracked: $name ($(lane_state "$name"))"
    else
      set_lane_state "$name" "RUNNING"
      log "tracking lane: $name"
    fi
  done
  return $rc
}

format_age() {
  local secs=$1
  if   [[ $secs -lt 60   ]]; then printf '%ds' "$secs"
  elif [[ $secs -lt 3600 ]]; then printf '%dm' "$((secs/60))"
  else printf '%dh%dm' "$((secs/3600))" "$(( (secs%3600)/60 ))"
  fi
}

icon_for_state() {
  case "$1" in
    RUNNING)  echo "$ICON_RUNNING" ;;
    READY)    echo "$ICON_READY" ;;
    LANDED)   echo "$ICON_LANDED" ;;
    FAILED)   echo "$ICON_FAILED" ;;
    CONFLICT) echo "$ICON_CONFLICT" ;;
    *)        echo "$ICON_UNKNOWN" ;;
  esac
}

# Bucket lanes by state into parallel arrays. Sets:
#   total, active                       — globals
#   state_buckets[0..4]                  — newline-joined "branch|age|meta"
#   state_counts[0..4]                   — count per state
# Order: 0=RUNNING 1=READY 2=CONFLICT 3=FAILED 4=LANDED
__fleet_bucket() {
  total=0; active=0
  state_buckets=("" "" "" "" "")
  state_counts=(0 0 0 0 0)
  local now=$(date +%s)
  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    total=$((total+1))
    local branch state meta mtime secs age idx
    branch=$(decode_lane "$(basename "$f")")
    state=$(head -n1 "$f")
    meta=$(sed -n '2p' "$f")
    mtime=$(file_mtime "$f")
    secs=$((now - mtime))
    age=$(format_age "$secs")
    [[ "$state" != "LANDED" && "$state" != "FAILED" ]] && active=$((active+1))
    idx=-1
    case "$state" in
      RUNNING)  idx=0 ;;
      READY)    idx=1 ;;
      CONFLICT) idx=2 ;;
      FAILED)   idx=3 ;;
      LANDED)   idx=4 ;;
    esac
    [[ $idx -lt 0 ]] && continue
    state_counts[$idx]=$(( state_counts[idx] + 1 ))
    state_buckets[$idx]="${state_buckets[$idx]}${branch}|${age}|${meta}"$'\n'
  done
}

# Daemon health → "healthy" or "busted"
__fleet_daemon_state() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'healthy'
      return
    fi
  fi
  printf 'busted'
}

# Footer composition shared by all panel views.
__fleet_footer() {
  local active=$1 daemon_state=$2
  local hotkeys
  # Separators come from term.sh ($TERM_DOT), never an authored U+00B7. A literal
  # middle dot bypasses the ASCII-fallback registry, so it survives TERM_ASCII=1
  # and mojibakes on non-UTF-8 consoles. tests/check-resources.sh gates this.
  hotkeys="$(term_hotkey R refresh) ${TERM_DOT} $(term_hotkey L land) ${TERM_DOT} $(term_hotkey '?' help)"
  local healths
  healths="$(term_health "$daemon_state" "daemon")"
  [[ "$active" -gt 0 ]] && healths="$healths  $(term_health pending "$active active")"
  term_panel_close "$hotkeys" "$healths"
}

# Default panel view — design-system grouped tree
fleet_view_panel() {
  ensure_fleet_dir

  local order=(RUNNING READY CONFLICT FAILED LANDED)
  local total active
  local state_buckets state_counts
  __fleet_bucket
  load_session_index
  local daemon_state
  daemon_state=$(__fleet_daemon_state)

  echo ""
  term_panel_open fleet fleet "$TERM_GLYPH_BRANCH $BASE_BRANCH"
  # First, above every lane: whether the base tip is safe to act on at all.
  landing_status_row

  if [[ $total -eq 0 ]]; then
    term_panel_vert
    term_panel_vert
    printf '%s   %s\n' "$(term_color dim "$TERM_TREE_VERT")" "no lanes yet"
    term_panel_vert
    term_panel_vert
    printf '%s   %s %s\n' "$(term_color dim "$TERM_TREE_VERT")" "$TERM_GLYPH_TIP" "to get started:"
    term_panel_vert
    printf '%s      1. fleet init <name>...\n' "$(term_color dim "$TERM_TREE_VERT")"
    printf '%s      2. (work in each lane)\n'  "$(term_color dim "$TERM_TREE_VERT")"
    printf '%s      3. fleet start\n'          "$(term_color dim "$TERM_TREE_VERT")"
    term_panel_vert
    term_panel_vert
    term_panel_close "$(term_hotkey '?' help)" "$(term_health unknown "v2.4.9")"
    echo ""
    return
  fi

  term_panel_vert
  term_summary_line "$total $([ "$total" -eq 1 ] && echo lane || echo lanes) ${TERM_DOT} $active active"
  term_panel_vert

  local i
  for i in 0 1 2 3 4; do
    local n=${state_counts[$i]}
    [[ $n -eq 0 ]] && continue
    local state=${order[$i]}

    term_section "$state" "$state" "$n"

    local lines="${state_buckets[$i]}"
    local c_idx=0 c_last=$((n - 1))
    local branch age meta
    while IFS='|' read -r branch age meta; do
      [[ -z "$branch" ]] && continue
      local c_conn
      if [[ $c_idx -eq $c_last ]]; then c_conn="$TERM_TREE_LAST"; else c_conn="$TERM_TREE_BRANCH"; fi

      # Build the rail glyph from this lane's commits-ahead and state.
      local ahead head_kind rail
      ahead=$(git rev-list --count "${BASE_BRANCH}..${branch}" 2>/dev/null || echo 0)
      head_kind="HEAD"
      [[ "$state" == "CONFLICT" || "$state" == "FAILED" ]] && head_kind="CONFLICT"
      rail=$(term_rail "$ahead" "$head_kind")

      local own; own=$(owner_annotation "$branch")
      local shown_meta="${meta:-}"
      if [[ -n "$own" ]]; then
        # ASCII separator on purpose — this row must survive TERM_ASCII=1.
        [[ -n "$shown_meta" ]] && shown_meta="$shown_meta - $own" || shown_meta="$own"
      fi
      term_leaf_line "$c_conn" "$branch" "$rail" "$shown_meta" "$age"
      c_idx=$((c_idx+1))
    done <<< "$lines"
    term_panel_vert
  done

  prune_status_hint
  __fleet_footer "$active" "$daemon_state"
  echo ""
}

# Verbose view — per-lane detail blocks rendered in panel grammar.
# Each lane gets a header row + sub-rows for worktree, commits, and note.
fleet_view_verbose() {
  ensure_fleet_dir

  local total active
  local state_buckets state_counts
  __fleet_bucket
  load_session_index
  local daemon_state
  daemon_state=$(__fleet_daemon_state)
  local now=$(date +%s)

  echo ""
  term_panel_open fleet "fleet ${TERM_DOT} verbose" "$TERM_GLYPH_BRANCH $BASE_BRANCH"
  landing_status_row

  if [[ $total -eq 0 ]]; then
    term_panel_vert
    printf '%s   no lanes yet\n' "$(term_color dim "$TERM_TREE_VERT")"
    term_panel_vert
    term_panel_close "$(term_hotkey '?' help)" "$(term_health unknown "v2.4.9")"
    echo ""
    return
  fi

  term_panel_vert
  term_summary_line "$total $([ "$total" -eq 1 ] && echo lane || echo lanes) ${TERM_DOT} $active active"
  term_panel_vert

  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    local branch state meta mtime age secs wt commits color label_state
    branch=$(decode_lane "$(basename "$f")")
    state=$(head -n1 "$f")
    meta=$(sed -n '2p' "$f")
    mtime=$(file_mtime "$f")
    secs=$((now - mtime))
    age=$(format_age "$secs")
    wt=$(worktree_path_for "$branch" 2>/dev/null || echo "")
    commits=$(git rev-list --count "$BASE_BRANCH..$branch" 2>/dev/null || echo "?")

    color=""
    case "$state" in
      RUNNING|PENDING|CONFLICT|WARN) color="yellow" ;;
      READY|LANDED|DONE|OK)          color="green" ;;
      FAILED|ERROR)                  color="red" ;;
    esac
    label_state="$state"
    [[ -n "$color" ]] && label_state=$(term_color "$color" "$state")

    # Lane header row
    printf '%s%s %-30s %-10s %s\n' \
      "$(term_color dim "$TERM_TREE_VERT")" \
      "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
      "$branch" \
      "$label_state" \
      "$(term_color dim "$age")"

    # Detail sub-rows (under the lane's │ continuation)
    if [[ -n "$wt" ]]; then
      local wt_short="$wt" repo_root="${REPO_ROOT:-}"
      [[ -n "$repo_root" ]] && wt_short="${wt#$repo_root/}"
      if [[ "$wt_short" == "$wt" && -n "$repo_root" ]]; then
        local repo_native
        repo_native=$(cygpath -m "$repo_root" 2>/dev/null || echo "$repo_root")
        wt_short="${wt#$repo_native/}"
      fi
      printf '%s   %s worktree:  %s\n' \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$wt_short")"
    fi
    if [[ "$commits" != "?" && "$commits" != "0" ]]; then
      printf '%s   %s commits:   %s ahead of %s\n' \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$commits")" \
        "$(term_color dim "$BASE_BRANCH")"
    fi
    if [[ -n "$meta" ]]; then
      printf '%s   %s note:      %s\n' \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$meta")"
    fi
    local own_v; own_v=$(owner_annotation "$branch")
    if [[ -n "$own_v" ]]; then
      printf '%s   %s owner:     %s\n' \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$own_v"
    fi
    term_panel_vert
  done

  prune_status_hint
  __fleet_footer "$active" "$daemon_state"
  echo ""
}

cmd_fleet() {
  local mode="panel"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) mode="verbose"; shift ;;
      -g|--grouped) mode="panel"; shift ;;
      *)            shift ;;
    esac
  done
  case "$mode" in
    verbose) fleet_view_verbose ;;
    *)       fleet_view_panel ;;
  esac
}

# MAIN = the one session per repo that coordinates: it lands, deploys, and
# triages. Everyone else is a lane. This is not a new idea — worktree-boundaries
# doctrine already says the base checkout is the integration tree and must not
# host a writing session — `fleet main` just makes the role addressable, so a
# lane can say "I'm ready, come land me" instead of writing a file and hoping.
#
# Resolution is by cwd (the session sitting in the repo root IS the coordinator),
# with an explicit pin in .claude/fleet/main to override when the heuristic is
# wrong or several sessions share the root.
cmd_main() {
  local sub=${1:-show}
  local pin="$FLEET_DIR/main"
  case "$sub" in
    show|"")
      local row; row=$(main_session_row)
      if [[ -z "$row" ]]; then
        echo "no MAIN session resolved for this repo" >&2
        if ! session_enabled; then
          echo "  (session awareness is off or sessions.sh is missing)" >&2
        else
          echo "  no session's cwd matches $REPO_ROOT — open one there, or pin with:" >&2
          echo "  fleet main claim <sessionId>" >&2
        fi
        return 3
      fi
      # stdout is data: sessionId first so `fleet main show | cut -f1` addresses it
      printf '%s\t%s\t%s\t%s\n' \
        "$(sfield "$row" 2)" "$(sfield "$row" 3)" \
        "$([[ "$(sfield "$row" 7)" == "1" ]] && echo live || echo idle)" \
        "$(sfield "$row" 5)"
      [[ -f "$pin" ]] && echo "(pinned via $pin)" >&2
      return 0
      ;;
    claim)
      ensure_fleet_dir
      local id=${2:-}
      if [[ -z "$id" ]]; then
        local row; row=$(main_session_row)
        id=$(sfield "$row" 2)
        [[ -z "$id" ]] && { echo "fleet main claim: could not auto-resolve a session; pass a sessionId" >&2; return 3; }
      fi
      printf '# MAIN coordinator session for this repo (fleet main release to clear)\n%s\n' "$id" > "$pin"
      echo "MAIN pinned: $id" >&2
      printf '%s\n' "$id"
      ;;
    release)
      if [[ ! -f "$pin" ]]; then echo "no MAIN pin to clear" >&2; return 0; fi
      # A pin that survives keeps overriding the heuristic, so a failed delete
      # is a failed release (exit 1), never a "cleared".
      remove_state_file "$pin" "MAIN pin" || return 1
      echo "MAIN pin cleared" >&2
      ;;
    *) echo "usage: fleet main [show|claim [<sessionId>]|release]" >&2; return 2 ;;
  esac
}

cmd_config() {
  # Print the RESOLVED config — the observability that was missing while every
  # documented key was a silent no-op. stdout is data only (key=value, parseable);
  # advice and warnings go to stderr.
  if [[ -f "$CONFIG" ]]; then
    echo "# source: $CONFIG" >&2
  else
    echo "# source: none ($CONFIG absent) — all defaults" >&2
  fi
  echo "mode=$MODE"
  echo "worktree_root=$WORKTREE_ROOT"
  echo "test_cmd=$TEST_CMD"
  echo "forbidden_pattern=$FORBIDDEN_PATTERN"
  echo "base_branch=$BASE_BRANCH"
  echo "poll_interval=$POLL_INTERVAL"
  echo "icons=$ICONS"
  echo "session_check=$SESSION_CHECK"
  echo "session_live_secs=$SESSION_LIVE_SECS"
  echo "prune_hint=$PRUNE_HINT"
  if [[ -z "$TEST_CMD" ]]; then
    echo "WARNING: no test_cmd — 'fleet land' will not run a test gate" >&2
  fi
  # Same observability lesson as test_cmd: say plainly whether the gate is armed,
  # rather than letting an unavailable store look like a passing check.
  if session_enabled; then
    if [[ -n "$(main_session_row)" ]]; then
      echo "# session awareness: ON (store readable)" >&2
      # Whether THIS session can be recognised decides if it can land its own
      # lane unaided; unresolvable self is a silent fallback to refusing, so
      # state it rather than letting it look like a gate misfire.
      if [[ -n "$(bash "$SESSIONS_SH" self 2>/dev/null)" ]]; then
        echo "#   self-identity: resolved — this session can land lanes it owns" >&2
      else
        echo "#   self-identity: UNRESOLVED — landing a lane this session owns will refuse" >&2
      fi
    else
      echo "# session awareness: ON but no sessions resolved — store missing, jq missing, or terminal-only host" >&2
    fi
    # Which stores answered. The 2026-09-28 prune misclassification came from
    # reading one Desktop instance's store out of four, and nothing said so.
    local kind dir
    while IFS=$'\t' read -r kind dir; do
      [[ -n "$kind" ]] && echo "#   $kind: $dir" >&2
    done < <(bash "$SESSIONS_SH" stores 2>/dev/null || true)
  else
    echo "# session awareness: OFF — 'fleet land' will not check for live lane owners" >&2
  fi
  return 0
}

cmd_scrub_check() {
  local branch=${1:-}
  [[ -z "$branch" ]] && { echo "usage: fleet scrub-check <branch>" >&2; exit 1; }
  local hits
  hits=$(scrub_diff "$branch")
  if [[ -n "$hits" ]]; then
    echo "FORBIDDEN PATTERNS in $branch:"
    echo "$hits" | head -20
    return 1
  fi
  echo "OK: $branch (no forbidden patterns)"
}

# === SESSION AWARENESS ========================================================
# Answers "who owns this lane, and are they still writing?" by reading the
# Claude Desktop session store off disk (scripts/sessions.sh explains why disk
# and not the ccd_session_mgmt MCP tools — those exist only inside Desktop and
# cannot be called from a script at all).
#
# EVERY function here is best-effort. sessions.sh exits 3 when the store or jq
# is missing, and fleet.sh runs under `set -e`, so each call MUST be guarded
# with `|| true`. An unguarded call would turn "this machine has no Desktop
# store" into "fleet land crashes".

SESSIONS_SH="$SCRIPT_DIR/sessions.sh"

session_enabled() {
  [[ "$(printf '%s' "$SESSION_CHECK" | tr '[:upper:]' '[:lower:]')" != "off" ]] \
    && [[ -f "$SESSIONS_SH" ]]
}

# TSV row for the session owning $1, or empty. $2=--fresh forces an
# authoritative liveness read (used by the land gate).
lane_owner() {
  session_enabled || return 0
  local branch=$1 fresh=${2:-}
  FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" \
    bash "$SESSIONS_SH" owner $fresh "$branch" 2>/dev/null || true
}

# TSV row for this repo's MAIN/coordinator session, or empty.
main_session_row() {
  session_enabled || return 0
  FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" \
    bash "$SESSIONS_SH" main 2>/dev/null || true
}

# Column accessors: 1=branch 2=sessionId 3=title 4=lastActivityMs 5=cwd
#                   6=archived 7=live
sfield() { printf '%s' "$1" | cut -f"$2"; }

# Status views resolve an owner per lane. Doing that with one sessions.sh call
# each would re-pay process spawn N times, so the whole index is pulled once per
# fleet.sh invocation and queried in-memory.
SESSION_INDEX_CACHE=""
SESSION_INDEX_LOADED=0
# 1 only when sessions.sh returned 0 — i.e. the store was actually READ.
# The distinction matters to `fleet prune`: "the store says no session owns this
# branch" is evidence of abandonment, while "the store could not be read" is no
# evidence at all, and the two are indistinguishable from an empty index alone.
# Anything that can't tell them apart must not classify a worktree removable.
SESSION_STORE_OK=0
# Directory claims (sessions.sh `paths`): key, path, sessionId, title, lastMs,
# archived, live, via. Prune needs these as well as the branch index, because
# the branch join is blind in two ways that both occurred on 2026-09-28: a
# wrapper's branch can differ from what its worktree has checked out (a session
# ran branch `claude/keen-mccarthy` in worktree `vigilant-grothendieck`), and a
# session that moved into a lane via EnterWorktree never records that lane in
# its wrapper at all — only its transcript's directory says where it went.
SESSION_PATHS_CACHE=""
# load_session_index [fresh] — `fresh` forces a re-scan even when already
# loaded, for the one caller that must not act on a cached read: prune's
# pre-removal re-classification.
load_session_index() {
  session_enabled || return 0
  local fresh=${1:-}
  [[ $SESSION_INDEX_LOADED -eq 1 && "$fresh" != fresh ]] && return 0
  SESSION_INDEX_LOADED=1
  SESSION_STORE_OK=0
  local rc=0 views="" nocache="${FLEET_SESSION_NOCACHE:-}"
  [[ "$fresh" == fresh ]] && nocache=1
  # One process, one scan, both projections (tagged I/P): a second sessions.sh
  # process costs ~200ms on Windows on every `fleet status`.
  views=$(FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" FLEET_SESSION_NOCACHE="$nocache" \
    bash "$SESSIONS_SH" views 2>/dev/null) || rc=$?
  SESSION_INDEX_CACHE=""; SESSION_PATHS_CACHE=""
  # Both views, or neither: prune reads "no claim" as evidence, which is only
  # true when the claims were actually read.
  if [[ $rc -eq 0 ]]; then
    SESSION_INDEX_CACHE=$(printf '%s\n' "$views" | awk '/^I\t/ { print substr($0, 3) }')
    SESSION_PATHS_CACHE=$(printf '%s\n' "$views" | awk '/^P\t/ { print substr($0, 3) }')
    SESSION_STORE_OK=1
  fi
  return 0
}

# Claude Code's project-dir encoding, lowercased — the key a transcript's
# directory is filed under. MIRRORS path_key() in sessions.sh; a drift between
# the two silently loses transcript claims (tests/run.sh pins the pair).
path_key() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

# Every claim on worktree $1 (git's path form): an exact normalised-path match,
# or a transcript filed under its encoded key. Same TSV as `sessions.sh paths`.
path_claims() {
  [[ -z "$SESSION_PATHS_CACHE" ]] && return 0
  local n k
  n=$(prune_norm "$1"); k=$(path_key "$n")
  printf '%s\n' "$SESSION_PATHS_CACHE" \
    | awk -F'\t' -v n="$n" -v k="$k" 'NF && (($2 != "" && $2 == n) || $1 == k)'
  return 0
}

# Full TSV row of the newest session owning branch $1, from the in-memory index.
# Same tie-break as sessions.sh's own `owner`: non-archived outranks archived
# (col 6 asc), then newest activity (col 4 desc) — a branch reused after its
# original session was archived belongs to whoever is using it now.
owner_row_cached() {
  [[ -z "$SESSION_INDEX_CACHE" ]] && return 0
  printf '%s\n' "$SESSION_INDEX_CACHE" \
    | awk -F'\t' -v w="$1" '$1 == w' \
    | sort -t"$(printf '\t')" -k6,6n -k4,4nr \
    | head -n1
}

# "title<TAB>live" for the newest session owning $1, or empty.
owner_brief() {
  [[ -z "$SESSION_INDEX_CACHE" ]] && return 0
  printf '%s\n' "$SESSION_INDEX_CACHE" \
    | awk -F'\t' -v w="$1" '$1 == w { print $4"\t"$3"\t"$7 }' \
    | sort -k1,1nr | head -n1 | cut -f2,3
}

# One-line owner annotation for a lane row: "· owned by 'X' (live)" or empty.
owner_annotation() {
  local b=$1 brief title live
  brief=$(owner_brief "$b")
  [[ -z "$brief" ]] && return 0
  title=$(printf '%s' "$brief" | cut -f1)
  live=$(printf '%s' "$brief" | cut -f2)
  [[ ${#title} -gt 28 ]] && title="${title:0:25}..."
  # Deliberately ASCII: this string lands inside panel rows that must survive
  # FLEET_ASCII=1 and non-UTF-8 Windows consoles (SKILL.md "Compatibility").
  if [[ "$live" == "1" ]]; then
    printf '%s' "$(term_color yellow "[live]") $title"
  else
    printf '%s' "$(term_color dim "[idle]") $title"
  fi
}

# Is session id $1 the session running THIS script? Empty/unresolvable self is
# always false — an unknown identity must never satisfy an exemption.
SELF_SESSION_ID=""
SELF_SESSION_LOADED=0
session_is_self() {
  session_enabled || return 1
  if [[ $SELF_SESSION_LOADED -eq 0 ]]; then
    SELF_SESSION_LOADED=1
    SELF_SESSION_ID=$(bash "$SESSIONS_SH" self 2>/dev/null </dev/null) || SELF_SESSION_ID=""
  fi
  [[ -n "$SELF_SESSION_ID" && "$1" == "$SELF_SESSION_ID" ]]
}

# Every OTHER live session that also owns branch $1 (excluding session $2), as
# "id<TAB>title" rows. Liveness is re-read per candidate rather than taken from
# the cached index — same standard as `owner --fresh`, because this decides a
# refusal, and the index cache has a 15-minute TTL.
peer_live_owners() {
  local branch=$1 self=$2 row id
  load_session_index
  [[ -z "$SESSION_INDEX_CACHE" ]] && return 0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    id=$(sfield "$row" 2)
    [[ "$id" == "$self" ]] && continue
    [[ "$(bash "$SESSIONS_SH" live "$id" 2>/dev/null)" == "1" ]] || continue
    printf '%s\t%s\n' "$id" "$(sfield "$row" 3)"
  done < <(printf '%s\n' "$SESSION_INDEX_CACHE" | awk -F'\t' -v w="$branch" '$1 == w')
  return 0
}

# Live DIRECTORY claims on worktree $1, one row per session:
# "id<TAB>title<TAB>routes" (routes: cwd,worktree,transcript,live-cwd).
# The branch join alone is blind in the two ways prune hit on 2026-09-28: a
# wrapper's branch drifts from what its worktree has checked out (a session in
# worktree vigilant-grothendieck recorded branch claude/keen-mccarthy), and a
# session that EnterWorktree'd into a lane records that only in its
# transcript. Either way the branch join finds no live owner, and the gate
# merged — then rebased — under a session still writing in that worktree.
# `at --fresh`, never the cached `at`: this decides a refusal, and the index is
# up to 15 minutes old. See cmd_at in sessions.sh for what "fresh" covers.
worktree_live_claims() {
  session_enabled || return 0
  FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" \
    bash "$SESSIONS_SH" at --fresh "$1" 2>/dev/null </dev/null \
    | awk -F'\t' -v OFS='\t' '
        NF && $7 == "1" {
          if (!($3 in t)) { o[++n] = $3; t[$3] = $4; r[$3] = $8 }
          else if (index("," r[$3] ",", "," $8 ",") == 0) r[$3] = r[$3] "," $8
        }
        END { for (i = 1; i <= n; i++) print o[i], t[o[i]], r[o[i]] }' || true
}

# Collapse "id<TAB>title<TAB>how" rows ($1) to one per session, first-seen
# order, the hows joined with "; ".
merge_claimants() {
  printf '%s\n' "$1" | awk -F'\t' -v OFS='\t' '
    NF >= 3 && $1 != "" {
      if (!($1 in t)) { o[++n] = $1; t[$1] = $2; h[$1] = $3 } else h[$1] = h[$1] "; " $3
    }
    END { for (i = 1; i <= n; i++) print o[i], t[o[i]], h[o[i]] }'
}

log_claimants() {
  local id title how
  while IFS=$'\t' read -r id title how; do
    [[ -n "$id" ]] && log "    '$title' ($id) - $how"
  done <<< "$1"
  return 0
}

# The gate itself. Refuses to land a lane any LIVE session is working on —
# landing under a session that is mid-turn means merging a branch it may still
# be committing to, and then rebasing its worktree out from under it.
#
# "Working on" is the union of two joins, because each is blind where the
# other sees: the BRANCH join (the newest session that checked out or wrote
# the lane branch, via `owner --fresh`) and the DIRECTORY join (any session
# claiming the worktree the branch is checked out in — worktree_live_claims).
# Neither trusts the cached index's liveness; both re-read it.
#
# SELF-OWNERSHIP IS EXEMPT, and the reason is the whole design: that hazard is
# about a CONCURRENT writer. A session landing its own lane is not one — it is
# blocked inside this very call, so it is provably not mid-commit, and
# "rebasing its worktree out from under it" describes the tree it is
# deliberately retiring. Before this exemption, a lane session that finished
# its work could only land it with a blanket override, which disarms the gate
# for the peers it genuinely protects. A narrow exemption beats a blunt one.
#
# It stays conservative in both directions: unresolvable self never matches,
# and self must be the ONLY live claimant — by either join, plus every other
# live writer of the branch (peer_live_owners). A second live session is the
# real hazard, and refuses exactly as before. A CLI or headless session has no
# store record, so it can never prove it is self: working in the lane's
# worktree, it refuses even its own land.
# Returns 0 = safe to land, 1 = refuse.
session_land_gate() {
  local branch=$1
  session_enabled || return 0
  local claimants="" row wt claims
  row=$(lane_owner "$branch" --fresh)
  if [[ -n "$row" && "$(sfield "$row" 7)" == "1" ]]; then
    claimants="$(sfield "$row" 2)"$'\t'"$(sfield "$row" 3)"$'\t'"owns $branch"$'\n'
  fi
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    claims=$(worktree_live_claims "$wt")
    [[ -n "$claims" ]] || continue
    claimants+=$(printf '%s\n' "$claims" \
      | awk -F'\t' -v OFS='\t' -v wt="$wt" 'NF { print $1, $2, "working in " wt " (by " $3 ")" }')$'\n'
  done <<< "$(worktree_path_for "$branch")"
  claimants=$(merge_claimants "$claimants")
  [[ -z "$claimants" ]] && return 0      # nobody live → allow

  local id title how others="" self_in=0
  while IFS=$'\t' read -r id title how; do
    [[ -z "$id" ]] && continue
    if session_is_self "$id"; then self_in=1; else others+="$id"$'\t'"$title"$'\t'"$how"$'\n'; fi
  done <<< "$claimants"

  if [[ $self_in -eq 1 ]]; then
    local peers
    peers=$(peer_live_owners "$branch" "$SELF_SESSION_ID")
    [[ -n "$peers" ]] && others+=$(printf '%s\n' "$peers" \
      | awk -F'\t' -v OFS='\t' -v b="$branch" 'NF { print $1, $2, "also writes " b }')$'\n'
    others=$(merge_claimants "$others")
    if [[ -z "$others" ]]; then
      log "landing own lane: $branch is claimed only by THIS session ($SELF_SESSION_ID) — not a concurrent writer"
      return 0
    fi
    # Self plus someone else: the someone else is the hazard, so say who.
    log "REFUSE LAND: $branch is claimed by this session AND another LIVE session:"
    log_claimants "$others"
    log "  a peer may still be committing to it — coordinate before landing."
    return 1
  fi
  log "REFUSE LAND: $branch has a LIVE session on it:"
  log_claimants "$claimants"
  log "  active within ${SESSION_LIVE_SECS}s, so it may still be committing."
  log "  wait for it to finish, or override with: session_check=off (or FLEET_SKIP_SESSION_CHECK=1)"
  return 1
}
# === END SESSION AWARENESS ====================================================

# === PRUNE ====================================================================
# Worktree housekeeping. This is the ONLY part of fleet-ops that deletes
# anything, so read rules/worktree-boundaries.md before changing a line of it.
#
# THE HAZARD, stated plainly: a worktree that looks orphaned frequently is not.
# `.claude/worktrees/<slug>` names are machine-generated and say nothing about
# whether anyone is using them, and a session that looks idle may simply be
# between turns. Removing a worktree destroys its UNCOMMITTED and UNTRACKED
# files permanently — git has never seen those bytes and cannot give them back.
# COMMITTED lane work is different: it lives in the shared object store and
# survives the directory, recoverable with
#     git worktree add <path> <branch>
# Separating "committed and already in base" from everything else is therefore
# the classifier's entire job, and every ambiguous case resolves away from
# deletion.
#
# CLASSIFICATION — first match wins, and the ORDER is the safety argument:
#
#   1  primary / locked / the caller's own tree   KEEP    structurally untouchable
#   1b git says the directory is gone             REVIEW  git's own bookkeeping —
#                                                         `git worktree prune`
#   2  any claiming session is LIVE               KEEP    someone is writing here
#   3  session store unreadable, or awareness     REVIEW  no evidence of anything
#      switched off                                       => nothing can be SAFE
#   4  detached HEAD                              REVIEW  unless: clean, no git op
#                                                         in flight, HEAD in <base>,
#                                                         no open claim, and an
#                                                         archived owner proven => SAFE
#   5  uncommitted or untracked changes           REVIEW  removal would destroy them
#   6  commits not yet in <base>                  REVIEW  unintegrated work
#   7  merged + clean, and no OPEN session        SAFE    finished and recoverable
#      claims it; for .claude/worktrees/ also a
#      positive archived claim
#   8  anything else                              REVIEW  default deny
#
# A session CLAIMS a worktree by any of: its branch (checked-out or written),
# its wrapper cwd or worktreePath, its transcript's project directory, or —
# while live — the last cwd its transcript recorded (sessions.sh `paths`).
# Until 2026-09-28 only the branch join existed, and it read one session store
# out of several; 12 worktrees came back SAFE, five of them the cwd of an OPEN
# session and two of those RUNNING. Rule 7's positive-claim clause is the
# backstop for whatever the joins still miss: a .claude/worktrees/ tree nobody
# claims is "unknown", and unknown is REVIEW.
#
# ARCHIVED OWNERS (2026-10-05). Ten sessions archived after their lanes landed
# left 17 merged, clean worktrees that prune kept as "live session": archiving
# writes the transcript one last time, and that write read as activity. Now
# (sessions.sh header, "ARCHIVED IS NOT LIVE") an archived session is live only
# on a write AFTER its archive, and `fleet prune` re-reads every claimant fresh
# (prune_freshen_sessions) rather than trusting a pre-archive cache. An archive
# flag that cannot be read is "?": treated as live/open, never as archived, and
# every reason it decides says so. POSITIVE archived evidence is an exact path:
# a wrapper cwd/worktreePath, or the cwd an archived session's transcript last
# recorded — that last one is what proves a lane it EnterWorktree'd into, which
# its wrapper (cwd and gitAnchors alike) never names.
#
# Rule 6 deliberately folds together two readings that cannot both apply to one
# row — "unmerged commits => KEEP" and "unmerged with no live owner => REVIEW".
# Neither is ever removed, so the choice is purely about which bucket the
# operator is asked to look at, and an abandoned unmerged lane is exactly the
# backlog this command exists to surface. KEEP is therefore reserved for one
# meaning only: hands off, not yours to judge.

PRUNE_ROWS=""   # accumulated TSV: path \t branch \t bucket \t reason
PRUNE_FRESHEN=0     # 1 under `fleet prune` only — see prune_freshen_sessions
SESSION_LASTCWD=""  # sessionId \t normalised last transcript cwd (archived only)

# Normalise a path for comparison: forward slashes, no trailing slash,
# lowercased (Windows paths are case-insensitive and git's casing of the drive
# letter does not always match the shell's).
prune_norm() {
  local p=${1//\\//}
  p=${p%/}
  printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}

# Changed + untracked entry count. UNTRACKED counts on purpose: those are
# precisely the files git cannot recover, and `git worktree remove` refuses a
# tree containing them anyway.
prune_dirty_count() {
  git -C "$1" status --porcelain 2>/dev/null | grep -c '.' || true
}

# After a FAILED `git worktree remove`: did git finish everything but the
# directory itself? True only when the path is no longer a registered worktree
# AND is an empty directory, so a real failure (dirty, locked, half-deleted)
# still reads as one.
prune_left_empty() {
  local want regs w
  [[ -d "$1" && -z "$(ls -A "$1" 2>/dev/null)" ]] || return 1
  want=$(prune_norm "$(prune_native "$1")")
  # Captured, then compared: an early-exiting `grep -q` at the end of a pipe
  # turns the whole pipe into SIGPIPE under pipefail.
  regs=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p') || return 1
  while IFS= read -r w; do
    [[ -n "$w" && "$(prune_norm "$w")" == "$want" ]] && return 1
  done <<< "$regs"
  return 0
}

prune_row() {
  PRUNE_ROWS="${PRUNE_ROWS}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'
}

# A shell path and a git path are not the same string on Windows: the shell says
# /tmp/x or /c/Users/x, git says C:/Users/x. Comparing them raw NEVER matches,
# which silently turns a guard into a no-op rather than into an error — the
# failure mode that hid both the invoked-from guard and repo discovery until a
# test caught them. Convert to git's mixed form before any such comparison.
# (INVOKED_FROM does the same thing inline at the top of this file, because it
# has to be captured before any function is defined.)
prune_native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# Prune must work in a repo that has never run `fleet init`, so it cannot assume
# .claude/fleet/ exists — and `log`'s `tee -a` into a missing directory fails,
# which under `set -e` kills the whole command (it did: a store-unavailable
# dry run exited 1 instead of reporting). Always to stderr; append to the
# activity log only when there is one. Prune never creates that directory
# itself: a command whose default is "change nothing" must not leave state.
prune_log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo "$msg" >&2
  [[ -d "$FLEET_DIR" ]] && echo "$msg" >> "$LOG" 2>/dev/null
  return 0
}

# Is this path one of Claude Code's own native session worktrees? Those are the
# highest-risk rows: the directory name is meaningless, and the owning session
# is often still open. They are never removable on a guess — only when the store
# was readable AND it says the owner is archived or gone, which rules 3 and 7
# already require. The flag exists to mark them loudly in the table and to
# trigger the re-verify before removal.
prune_is_native() {
  case "$(prune_norm "$1")" in */.claude/worktrees/*) return 0 ;; *) return 1 ;; esac
}

# Re-read, fresh, every session that claims one of this repo's worktrees
# (sessions.sh `state`): liveness, the archive flag, and an archived session's
# last transcript cwd, patched over the cached index before anything is
# classified. WHY: the index is cached for 15 minutes and `fleet land` builds
# it, so the usual sequence — land, archive, prune — classified against rows
# written before the archive. Every just-archived owner still read open, nothing
# was SAFE, and --remove stopped at "nothing to remove" before its own fresh pass.
# Targeted, not a re-scan: one sessions.sh process over the claimants only (a
# few seconds), where a fresh scan of every store takes a minute. A failed read
# changes nothing: the cached values can only be staler, and --remove still
# re-classifies against a full fresh scan. `fleet prune` only (PRUNE_FRESHEN);
# the status-panel hint stays on the cache, where staleness costs a REVIEW.
# The awk's np/enc MIRROR prune_norm and path_key — path_claims' join. The first
# porcelain record is the primary, which prune never classifies.
prune_freshen_sessions() {
  local raw=$1 ids=() id state="" rc=0
  SESSION_LASTCWD=""
  [[ $SESSION_STORE_OK -eq 1 ]] || return 0
  while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(LC_ALL=C awk -F'\t' '
      function np(p) { gsub(/\\/, "/", p); sub(/\/+$/, "", p); return tolower(p) }
      function enc(p) { p = np(p); gsub(/[^a-z0-9]/, "-", p); return p }
      FILENAME == ARGV[1] {
        if (substr($0, 1, 9) == "worktree ") { if (w++) { p = np(substr($0, 10)); N[p] = 1; K[enc(p)] = 1 } }
        else if (w > 1 && substr($0, 1, 18) == "branch refs/heads/") B[substr($0, 19)] = 1
        next
      }
      FILENAME == ARGV[2] { if (NF && (($2 != "" && ($2 in N)) || ($1 in K)) && !s[$3]++) print $3; next }
      NF && ($1 in B) && !s[$2]++ { print $2 }' \
    <(printf '%s\n' "$raw") <(printf '%s\n' "$SESSION_PATHS_CACHE") <(printf '%s\n' "$SESSION_INDEX_CACHE"))
  [[ ${#ids[@]} -gt 0 ]] || return 0
  state=$(FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" \
    bash "$SESSIONS_SH" state "${ids[@]}" 2>/dev/null </dev/null) || rc=$?
  [[ $rc -eq 0 && -n "$state" ]] || return 0
  # state: id live archived(1|0|?|-) lastCwd. '-' = no wrapper read: keep the
  # cached flag rather than invent one.
  local patch='FILENAME == ARGV[1] { if ($1 != "") { L[$1] = $2; if ($3 != "-" && $3 != "") A[$1] = $3 }; next }'
  SESSION_PATHS_CACHE=$(awk -F'\t' -v OFS='\t' "$patch"'
      NF { if ($3 in L) $7 = L[$3]; if ($3 in A) $6 = A[$3]; print }' \
    <(printf '%s\n' "$state") <(printf '%s\n' "$SESSION_PATHS_CACHE"))
  SESSION_INDEX_CACHE=$(awk -F'\t' -v OFS='\t' "$patch"'
      NF { if ($2 in L) $7 = L[$2]; if ($2 in A) $6 = A[$2]; print }' \
    <(printf '%s\n' "$state") <(printf '%s\n' "$SESSION_INDEX_CACHE"))
  SESSION_LASTCWD=$(printf '%s\n' "$state" | awk -F'\t' -v OFS='\t' 'NF >= 4 && $4 != "" { print $1, $4 }')
  return 0
}

# Does an ARCHIVED session positively claim the tree normalised as $1, among
# claims $2? Positive means an exact path: its wrapper cwd/worktreePath is the
# tree, or (after prune_freshen_sessions) the cwd its transcript last recorded
# is the tree or inside it. The bare transcript KEY never counts: every
# non-alphanumeric encodes to '-', so `lane.x` and `lane-x` share one, and a
# neighbour's session would condemn this tree. Prints which proof held.
prune_archived_proof() {
  local n=$1 claims=$2
  if printf '%s\n' "$claims" | awk -F'\t' -v n="$n" '
       NF && $2 == n && $6 == "1" && ($8 == "cwd" || $8 == "worktree") { f = 1 } END { exit !f }'; then
    printf 'cwd'; return 0
  fi
  [[ -n "$SESSION_LASTCWD" ]] || return 1
  if awk -F'\t' -v n="$n" '
       FILENAME == ARGV[1] { if ($1 != "") lc[$1] = $2; next }
       NF && $8 == "transcript" && $6 == "1" && ($3 in lc) && (lc[$3] == n || index(lc[$3], n "/") == 1) { f = 1 }
       END { exit !f }' <(printf '%s\n' "$SESSION_LASTCWD") <(printf '%s\n' "$claims"); then
    printf 'transcript cwd'; return 0
  fi
  return 1
}

# The git operation parked in worktree $1 (rebase, bisect, ...), or nothing. A
# paused rebase or a bisect leaves HEAD detached in a CLEAN tree, so the dirty
# check passes it — and removing the tree discards the operation's state. One
# rev-parse resolves every state path, per-worktree, in a single process.
prune_op_in_progress() {
  local wt=$1 p i=0 f args=()
  local files=(rebase-merge rebase-apply BISECT_LOG MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD sequencer)
  local words=(rebase rebase bisect merge cherry-pick revert sequencer)
  for f in "${files[@]}"; do args+=(--git-path "$f"); done
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then
      [[ "$p" == /* || "$p" == [A-Za-z]:* ]] || p="$wt/$p"
      if [[ -e "$p" ]]; then printf '%s' "${words[$i]}"; return 0; fi
    fi
    i=$((i + 1))
  done < <(git -C "$wt" rev-parse "${args[@]}" 2>/dev/null)
  return 0
}

# prune_emit <repo> <base> <path> <branch> <detached> <locked> <gone> <merged_list>
prune_emit() {
  local repo=$1 base=$2 wt=$3 br=$4 det=$5 locked=$6 gone=$7 merged_list=$8
  local wtn here
  wtn=$(prune_norm "$wt")
  here=$(prune_norm "$INVOKED_FROM")

  # 1 — structurally untouchable
  if [[ $locked -eq 1 ]]; then
    prune_row "$wt" "${br:-<detached>}" KEEP "locked by git"; return 0
  fi
  if [[ "$wtn" == "$here" || "$here" == "$wtn"/* ]]; then
    prune_row "$wt" "${br:-<detached>}" KEEP "you are standing in it"; return 0
  fi
  # git itself says the directory is gone. Nothing to lose and nothing to
  # classify — but this is git's own bookkeeping, so send it to git's own tool
  # rather than silently reporting a vanished tree as "clean".
  if [[ $gone -eq 1 ]]; then
    prune_row "$wt" "${br:-<detached>}" REVIEW "directory missing - run 'git worktree prune'"; return 0
  fi

  # 2 — a live claim outranks every other consideration. Two joins, because
  #     they fail differently: the branch owner (lane-level, sees
  #     writtenBranches) and the directory claims (see the header). Either one
  #     being live is enough.
  local orow="" olive="0" oarch="0" otitle=""
  local claims="" live_claim="" open_claim="" open_flag="" who="no owner in store"
  local unread="archive flag unreadable - treated as live"
  if [[ $SESSION_STORE_OK -eq 1 ]]; then
    if [[ -n "$br" ]]; then
      orow=$(owner_row_cached "$br")
      if [[ -n "$orow" ]]; then
        olive=$(sfield "$orow" 7); oarch=$(sfield "$orow" 6); otitle=$(sfield "$orow" 3)
      fi
    fi
    # First match without `exit`: an early-exiting reader can SIGPIPE the
    # printf, and under pipefail + set -e that kills the whole command.
    claims=$(path_claims "$wt")
    live_claim=$(printf '%s\n' "$claims" | awk -F'\t' -v u="$unread" '
      NF && $7 == "1" && !f { print $4 " (by " $8 ($6 == "?" ? "; " u : "") ")"; f = 1 }')
    # OPEN = anything not provably archived: 0, and ? — an unreadable flag is
    # never presumed archived. "title<TAB>flag", preferring a plainly open one.
    open_claim=$(printf '%s\n' "$claims" | awk -F'\t' '
      NF && $6 != "1" { if ($6 == "0") { if (!z) { zt = $4; z = 1 } } else if (!q) { qt = $4; q = 1 } }
      END { if (z) print zt "\t0"; else if (q) print qt "\t?" }')
    if [[ -n "$open_claim" ]]; then open_flag=${open_claim##*$'\t'}; open_claim=${open_claim%$'\t'*}; fi
    # Who owns it, for the REVIEW reasons below.
    if [[ ( -n "$orow" && "$oarch" == "0" ) || "$open_flag" == "0" ]]; then who="owner idle"
    elif [[ ( -n "$orow" && "$oarch" == "?" ) || "$open_flag" == "?" ]]; then who="owner's archive flag unreadable"
    elif [[ -n "$orow" || -n "$claims" ]]; then who="owner archived"; fi
  fi
  if [[ "$olive" == "1" ]]; then
    local note=""; [[ "$oarch" == "?" ]] && note=" ($unread)"
    prune_row "$wt" "${br:-<detached>}" KEEP "live session: ${otitle:-?}$note"; return 0
  fi
  if [[ -n "$live_claim" ]]; then
    prune_row "$wt" "${br:-<detached>}" KEEP "live session: $live_claim"; return 0
  fi

  # 3 — no session evidence at all. "The store says nobody owns this" is
  #     evidence of abandonment; "the store could not be read" is not, and an
  #     empty index looks identical to both. Degrade, never guess.
  if [[ $SESSION_STORE_OK -ne 1 ]]; then
    prune_row "$wt" "${br:-<detached>}" REVIEW "no session info - cannot prove abandoned"; return 0
  fi

  # 4 — detached HEAD. No branch, so only a DIRECTORY claim can name an owner,
  #     and what Desktop's archive leaves behind is exactly this: the session's
  #     own tree, HEAD detached, its branch deleted. SAFE needs every guard:
  #     clean; no git operation parked in it (a paused rebase or a bisect sits
  #     detached in a clean tree); HEAD already in base, so nothing committed
  #     is lost; no open claim; and an archived owner proven by exact path.
  if [[ $det -eq 1 || -z "$br" ]]; then
    local ddirty op
    ddirty=$(prune_dirty_count "$wt")
    if [[ "${ddirty:-0}" -gt 0 ]]; then
      prune_row "$wt" "<detached>" REVIEW "detached HEAD, DIRTY - $ddirty uncommitted/untracked ($who)"; return 0
    fi
    op=$(prune_op_in_progress "$wt")
    if [[ -n "$op" ]]; then
      prune_row "$wt" "<detached>" REVIEW "detached HEAD - git $op in progress"; return 0
    fi
    if ! git -C "$wt" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
      prune_row "$wt" "<detached>" REVIEW "detached HEAD - commit not in $base ($who)"; return 0
    fi
    if [[ -n "$open_claim" ]]; then
      prune_row "$wt" "<detached>" REVIEW "detached HEAD in $base, but $who: $open_claim"; return 0
    fi
    if prune_archived_proof "$wtn" "$claims" >/dev/null; then
      prune_row "$wt" "<detached>" SAFE "detached + clean, HEAD in $base, owner archived"; return 0
    fi
    prune_row "$wt" "<detached>" REVIEW "detached HEAD - no archived session provably owns it"; return 0
  fi

  local is_merged=0
  if printf '%s\n' "$merged_list" | grep -qxF -- "$br"; then is_merged=1; fi

  # 5 — uncommitted or untracked work: the only bytes git cannot give back
  local dirty
  dirty=$(prune_dirty_count "$wt")
  if [[ "${dirty:-0}" -gt 0 ]]; then
    local mstate="unmerged"
    [[ $is_merged -eq 1 ]] && mstate="merged"
    prune_row "$wt" "$br" REVIEW "$mstate but DIRTY - $dirty uncommitted/untracked ($who)"; return 0
  fi

  # 6 — committed but not yet in base
  local ahead
  ahead=$(git -C "$repo" rev-list --count "$base..$br" 2>/dev/null || echo 0)
  if [[ $is_merged -ne 1 || "${ahead:-0}" != "0" ]]; then
    prune_row "$wt" "$br" REVIEW "unmerged - ${ahead:-?} ahead of $base ($who)"; return 0
  fi

  # 8 (checked before 7) — an OPEN session claims it, by branch or by
  #     directory: idle now, and free to wake up. A session resumed into a
  #     deleted cwd does not error — it spins a core indefinitely (SKILL.md,
  #     "Landmine"). Not ours to remove. An unreadable archive flag lands here
  #     too, and says so.
  local still="owner still open" unopen="owner's archive flag unreadable, treated as open"
  if [[ -n "$orow" && "$oarch" != "1" ]]; then
    [[ "$oarch" == "?" ]] && still=$unopen
    prune_row "$wt" "$br" REVIEW "merged + clean, but $still: ${otitle:-?}"; return 0
  fi
  if [[ -n "$open_claim" ]]; then
    [[ "$open_flag" == "?" ]] && still=$unopen
    prune_row "$wt" "$br" REVIEW "merged + clean, but $still: $open_claim"; return 0
  fi

  # 7 — merged, clean, and every claim is archived. POSITIVE evidence means an
  #     archived branch owner, or an archived session placed EXACTLY in this
  #     tree by path (prune_archived_proof). A transcript-directory claim alone
  #     does not count: its key is lossy, so it may keep a tree but never
  #     condemn one — only the cwd that transcript recorded can.
  local proven=0 how=""
  [[ -n "$orow" && "$oarch" == "1" ]] && proven=1
  if [[ $proven -eq 0 ]] && how=$(prune_archived_proof "$wtn" "$claims"); then proven=1; fi
  if [[ $proven -eq 1 ]]; then
    local by=""; [[ "$how" == "transcript cwd" ]] && by=" (by its transcript cwd)"
    prune_row "$wt" "$br" SAFE "merged + clean, owner archived$by"; return 0
  fi
  # No positive claim. For a .claude/worktrees/ tree that is the ABSENCE of a
  # signal, not evidence: Claude Code made it for a session, and the store we
  # read did not mention that session — a store we cannot see, a session
  # outside the scan window, a claim the joins cannot express. That is the
  # 2026-09-28 failure in general form, so it resolves to REVIEW. A
  # `.fleet-worktrees/` lane or a hand-made tree is not created per session;
  # any session working in one is found by the cwd and transcript joins, so
  # there "nobody claims it" means what it says.
  if prune_is_native "$wt"; then
    if [[ -n "$claims" ]]; then
      prune_row "$wt" "$br" REVIEW "merged + clean, but no archived session provably worked here - cannot prove abandoned"; return 0
    fi
    prune_row "$wt" "$br" REVIEW "merged + clean, but no session record claims it - cannot prove abandoned"; return 0
  fi
  prune_row "$wt" "$br" SAFE "merged + clean, no session owns it"
}

# prune_classify <repo> <base>  — fills PRUNE_ROWS. The PRIMARY worktree is
# skipped entirely: it is the integration tree, not a lane, and listing it would
# only add a row that can never be actioned.
prune_classify() {
  local repo=$1 base=$2
  PRUNE_ROWS=""
  load_session_index

  local merged_list
  merged_list=$(git -C "$repo" branch --merged "$base" 2>/dev/null \
                | sed -e 's/^[*+ ]*//' -e 's/[[:space:]]*$//' || true)

  local raw
  raw=$(git -C "$repo" worktree list --porcelain 2>/dev/null || true)
  [[ -z "$raw" ]] && return 0
  if [[ $PRUNE_FRESHEN -eq 1 ]]; then prune_freshen_sessions "$raw"; fi

  # Porcelain records are blank-line separated. Command substitution ate the
  # trailing newlines, so append one blank line to flush the final record.
  local line wt="" br="" det=0 locked=0 gone=0 first=1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt=${line#worktree }; br=""; det=0; locked=0; gone=0 ;;
      branch\ *)   br=${line#branch }; br=${br#refs/heads/} ;;
      detached)    det=1 ;;
      locked*)     locked=1 ;;
      prunable*)   gone=1 ;;
      bare)        locked=1 ;;
      "")
        if [[ -n "$wt" ]]; then
          [[ $first -eq 1 ]] || prune_emit "$repo" "$base" "$wt" "$br" "$det" "$locked" "$gone" "$merged_list"
          first=0
        fi
        wt=""
        ;;
    esac
  done <<< "$raw"$'\n'
  return 0
}

prune_count() {
  [[ -z "$PRUNE_ROWS" ]] && { printf '0'; return 0; }
  printf '%s' "$PRUNE_ROWS" | awk -F'\t' -v b="$1" 'NF && $3==b {n++} END{print n+0}'
}

# The base branch to classify against in an arbitrary repo. This repo's
# configured base is meaningless next door, so resolve per-repo.
prune_base_for() {
  local r=$1 b
  for b in "$BASE_BRANCH" main master; do
    git -C "$r" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 && { printf '%s' "$b"; return 0; }
  done
  git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'main'
}

prune_render() {
  local total safe review keep
  safe=$(prune_count SAFE); review=$(prune_count REVIEW); keep=$(prune_count KEEP)
  total=$((safe + review + keep))

  echo ""
  term_panel_open fleet "fleet prune" "$TERM_GLYPH_BRANCH $BASE_BRANCH"
  term_panel_vert
  if [[ $total -eq 0 ]]; then
    term_panel_line "no lane worktrees - nothing to classify"
    term_panel_vert
    term_panel_close "$(term_hotkey '?' help)" "$(term_health healthy "clean")"
    echo ""
    return 0
  fi
  term_summary_line "$total worktree(s), $safe safe, $review review, $keep keep"
  term_panel_vert

  local b n rows p br bucket reason label short mark
  for b in SAFE REVIEW KEEP; do
    n=$(prune_count "$b")
    [[ $n -eq 0 ]] && continue
    case "$b" in
      SAFE)   term_section READY    "SAFE"   "$n" ;;
      REVIEW) term_section CONFLICT "REVIEW" "$n" ;;
      KEEP)   term_section RUNNING  "KEEP"   "$n" ;;
    esac
    rows=$(printf '%s' "$PRUNE_ROWS" | awk -F'\t' -v want="$b" 'NF && $3==want')
    while IFS=$'\t' read -r p br bucket reason; do
      [[ -z "$p" ]] && continue
      short=${p##*/}
      # ASCII-only marker: these rows must survive TERM_ASCII=1 on a non-UTF-8
      # Windows console (SKILL.md "Compatibility").
      mark="  "
      prune_is_native "$p" && mark="! "
      label="$mark$short"
      printf '%s   %s %-30s %-26s %s\n' \
        "$(term_color dim "$TERM_TREE_VERT")" \
        "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
        "$(term_truncate "$label" 30)" \
        "$(term_truncate "$br" 26)" \
        "$(term_color dim "$reason")"
    done <<< "$rows"
    term_panel_vert
  done

  local health
  if [[ $safe -gt 0 ]]; then health="$(term_health pending "$safe removable")"
  else health="$(term_health healthy "nothing removable")"; fi
  term_panel_close "$(term_hotkey '?' help)" "$health"
  echo ""
  # '!' marks a native .claude/worktrees/ lane — see rules/worktree-boundaries.md
  if printf '%s' "$PRUNE_ROWS" | cut -f1 | grep -qi '/\.claude/worktrees/'; then
    echo "  ! = Claude Code session worktree (.claude/worktrees/) - owned by a session, not by you" >&2
  fi
  return 0
}

prune_recovery_note() {
  echo "  Committed lane work is NOT destroyed by removal - it lives in the shared" >&2
  echo "  object store and comes back with:  git worktree add <path> <branch>" >&2
  echo "  Only uncommitted/untracked files are unrecoverable, which is why anything" >&2
  echo "  dirty is REVIEW and never SAFE." >&2
}

prune_remove_safe() {
  local removed=0 skipped=0 failed=0
  local p br bucket reason rows fresh dirty fresh_rows now_row
  rows=$(printf '%s' "$PRUNE_ROWS" | awk -F'\t' 'NF && $3=="SAFE"')

  # Re-classify against a FORCED-FRESH scan before touching anything. The table
  # the operator confirmed may rest on a cached index up to 15 minutes old, and
  # in that window a session can wake, be unarchived, or move into a tree.
  # Re-running the SAME classifier, rather than a narrower re-check, is the
  # point: the removal gate can never drift out of step with the rules that
  # produced the SAFE row. A store that has become unreadable reclassifies
  # every row REVIEW, and nothing is removed.
  prune_log "re-reading every session store before removal (a fresh scan can take a minute)..."
  local confirmed_rows=$PRUNE_ROWS
  load_session_index fresh
  prune_classify "$REPO_ROOT" "$BASE_BRANCH"
  fresh_rows=$PRUNE_ROWS
  PRUNE_ROWS=$confirmed_rows

  while IFS=$'\t' read -r p br bucket reason; do
    [[ -z "$p" ]] && continue

    now_row=$(printf '%s' "$fresh_rows" | awk -F'\t' -v p="$p" '$1 == p && !f { print $3 "\t" $4; f = 1 }')
    [[ -n "$now_row" ]] || now_row=$'MISSING\tabsent from the fresh classification'
    if [[ "${now_row%%$'\t'*}" != "SAFE" ]]; then
      prune_log "SKIP $p - no longer SAFE on a fresh read: ${now_row#*$'\t'}"
      skipped=$((skipped + 1)); continue
    fi

    # And once more per row, immediately before its delete: the fresh scan
    # above took time, and this is the one operation where being one poll
    # behind destroys data.
    fresh=$(lane_owner "$br" --fresh)
    if [[ -n "$fresh" && "$(sfield "$fresh" 7)" == "1" ]]; then
      prune_log "SKIP $p - owning session went LIVE since classification"
      skipped=$((skipped + 1)); continue
    fi
    dirty=$(prune_dirty_count "$p")
    if [[ "${dirty:-0}" -gt 0 ]]; then
      prune_log "SKIP $p - became dirty since classification ($dirty entries)"
      skipped=$((skipped + 1)); continue
    fi

    # `git worktree remove`, never `rm -rf`: it refuses a dirty or locked tree
    # (a third independent guard), and it also unregisters the worktree so the
    # repo is not left with a stale administrative entry.
    # stderr is captured rather than appended to $LOG: the log directory may not
    # exist (see prune_log), and a failed redirect would fail the command itself
    # — turning "could not remove" into an unexplained crash.
    local err=""
    if err=$(git -C "$REPO_ROOT" worktree remove "$p" 2>&1); then
      prune_log "removed worktree: $p (branch $br)"
      removed=$((removed + 1))
    elif prune_left_empty "$p"; then
      # Windows: git emptied and unregistered the tree, then could not delete
      # the directory itself because a process still holds it (a shell or an
      # editor standing in it). The worktree IS gone; only an empty dir is left,
      # and calling that "FAILED" sent the operator looking for lost work.
      prune_log "removed worktree: $p (branch $br) - but the empty directory is still held by another process (${err##*: }). It is an empty leftover now: 'fleet sweep' lists it, and 'fleet sweep --apply' removes it once nothing holds it."
      removed=$((removed + 1))
    else
      prune_log "FAILED to remove $p - left in place: ${err:-unknown error}"
      failed=$((failed + 1))
    fi
  done <<< "$rows"

  prune_log "prune: $removed removed, $skipped skipped, $failed failed"
  [[ $removed -gt 0 ]] && prune_recovery_note
  [[ $failed -eq 0 ]]
}

# Sibling-repo sweep. REPORT ONLY, and that is a design constraint, not a
# limitation: a single command must never be able to sweep worktrees across the
# machine. Acting on another repo means running `fleet prune` inside it, where
# that repo's own base branch, config, and lane state apply — and where its own
# session is the one taking the risk.
PRUNE_REPOS=()      # discovered repo dirs
PRUNE_ROOTS_USED="" # human-readable roots, for the header
PRUNE_TRUNCATED=0   # repos dropped by the cap — reported, never silent

prune_discover_repos() {
  local roots=()
  if [[ $# -gt 0 ]]; then
    roots=("$@")
  elif [[ -n "${FLEET_PRUNE_ROOTS:-}" ]]; then
    # ';'-separated, NOT ':' — a Windows root is "D:/code" and would split.
    local IFS=';' r
    for r in $FLEET_PRUNE_ROOTS; do [[ -n "$r" ]] && roots+=("$r"); done
  else
    # Default: this repo's siblings. Broader than that is opt-in via --root,
    # because "scan the whole drive" is a different and much slower promise.
    roots=("$(dirname "$REPO_ROOT")")
  fi
  PRUNE_ROOTS_USED="${roots[*]}"

  local max=${FLEET_PRUNE_MAX_REPOS:-60}
  local root d seen=0
  PRUNE_REPOS=(); PRUNE_TRUNCATED=0
  for root in "${roots[@]}"; do
    root=${root%/}
    [[ -d "$root" ]] || { echo "fleet prune: root not a directory: $root" >&2; continue; }
    # One and two levels deep only. Deeper is a full-drive walk, and a nested
    # `.git` two levels down is already an unusual layout.
    for d in "$root"/*/ "$root"/*/*/; do
      [[ -d "$d" ]] || continue
      d=${d%/}
      # A `.git` FILE (not dir) means the dir is itself a worktree or submodule
      # — it has no worktrees of its own to prune.
      [[ -d "$d/.git" ]] || continue
      # …and a `.git` DIR is not proof either. If it isn't a valid repo, git
      # silently WALKS UP and answers for the enclosing repo instead, so the
      # parent's worktrees get counted a second time under the child's name
      # (caught by `tests/sample-project`, whose stub .git did exactly this).
      # Require the dir to be its own toplevel.
      local top dn
      top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue
      dn=$(prune_native "$d")
      [[ "$(prune_norm "$top")" == "$(prune_norm "$dn")" ]] || continue
      if [[ $seen -ge $max ]]; then PRUNE_TRUNCATED=$((PRUNE_TRUNCATED + 1)); continue; fi
      # Store git's own form so downstream paths match `git worktree list`.
      PRUNE_REPOS+=("$dn"); seen=$((seen + 1))
    done
  done
  return 0
}

# repo \t total \t safe \t review \t keep — stdout is data only.
prune_all_repos_porcelain() {
  prune_discover_repos "$@"
  local repo base s rv k
  for repo in ${PRUNE_REPOS[@]+"${PRUNE_REPOS[@]}"}; do
    base=$(prune_base_for "$repo")
    prune_classify "$repo" "$base"
    s=$(prune_count SAFE); rv=$(prune_count REVIEW); k=$(prune_count KEEP)
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$((s + rv + k))" "$s" "$rv" "$k"
  done
  [[ $PRUNE_TRUNCATED -gt 0 ]] && \
    echo "fleet prune: capped; $PRUNE_TRUNCATED repos skipped (raise FLEET_PRUNE_MAX_REPOS)" >&2
  return 0
}

prune_all_repos() {
  prune_discover_repos "$@"
  local roots="$PRUNE_ROOTS_USED" truncated=$PRUNE_TRUNCATED
  local n=0
  for _ in ${PRUNE_REPOS[@]+"${PRUNE_REPOS[@]}"}; do n=$((n + 1)); done

  echo ""
  term_panel_open fleet "fleet prune --all-repos" "report only"
  term_panel_vert
  if [[ $n -eq 0 ]]; then
    term_panel_line "no git repositories found under: $roots"
    term_panel_vert
    term_panel_close "$(term_hotkey '?' help)" "$(term_health unknown "0 repos")"
    echo ""
    return 0
  fi
  term_summary_line "$n repo(s) under $roots"
  term_panel_vert

  local repo base s rv k tot grand_safe=0 grand_rev=0
  for repo in ${PRUNE_REPOS[@]+"${PRUNE_REPOS[@]}"}; do
    base=$(prune_base_for "$repo")
    prune_classify "$repo" "$base"
    s=$(prune_count SAFE); rv=$(prune_count REVIEW); k=$(prune_count KEEP)
    tot=$((s + rv + k))
    [[ $tot -eq 0 ]] && continue
    grand_safe=$((grand_safe + s)); grand_rev=$((grand_rev + rv))
    printf '%s   %s %-34s %s\n' \
      "$(term_color dim "$TERM_TREE_VERT")" \
      "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
      "$(term_truncate "${repo##*/}" 34)" \
      "$(term_color dim "$tot worktrees, $s safe, $rv review, $k keep")"
  done
  term_panel_vert
  term_panel_close "$(term_hotkey '?' help)" "$(term_health pending "$grand_safe safe, $grand_rev review")"
  echo ""

  # No silent caps: if the sweep was bounded, say so. A truncated sweep that
  # reads as a complete one is worse than no sweep.
  [[ $truncated -gt 0 ]] && \
    echo "  NOTE: repo cap reached; $truncated more skipped (raise FLEET_PRUNE_MAX_REPOS)" >&2
  echo "  Report only. To act on a repo, run 'fleet prune' inside it - cross-repo" >&2
  echo "  removal is deliberately impossible from here." >&2
  return 0
}

prune_usage() {
  cat <<EOF
fleet prune — classify (and optionally remove) finished lane worktrees

  fleet prune                  Classify and print. Changes NOTHING. (default)
  fleet prune --dry-run        Same as above, said explicitly.
  fleet prune --remove         Remove the SAFE rows, after a typed confirmation.
  fleet prune --remove --yes   Remove without prompting (scripts/CI).
  fleet prune --all-repos      Sibling-repo counts only; never removes.
  fleet prune --root <dir>     Extra sweep root for --all-repos (repeatable).
  fleet prune --porcelain      TSV to stdout, no panel. Report-only.
                               path<TAB>branch<TAB>bucket<TAB>reason
                               (with --all-repos: repo<TAB>total<TAB>safe<TAB>review<TAB>keep)

Buckets:
  SAFE    merged into $BASE_BRANCH, clean, and the owning session is archived or
          gone from the session store. Removable; committed work is recoverable.
          A detached tree qualifies only with HEAD in $BASE_BRANCH, no git
          operation in progress, and an archived owner placed there by path.
  REVIEW  reported, never removed: dirty, unmerged, detached without proof, an
          owner whose archive flag cannot be read, or no session info at all.
          Your call.
  KEEP    a live session owns it, git has it locked, or it is the tree you are
          standing in. Not touched under any flag.

Without a readable Claude session store (or with session_check=off) NOTHING can
be classified SAFE — abandonment cannot be proven, so nothing is removable.
EOF
}

cmd_prune() {
  local do_remove=0 assume_yes=0 all_repos=0 porcelain=0
  local roots=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n) do_remove=0; shift ;;
      --remove)     do_remove=1; shift ;;
      --yes|-y)     assume_yes=1; shift ;;
      --porcelain)  porcelain=1; shift ;;
      --all-repos)  all_repos=1; shift ;;
      --root)
        [[ -z "${2:-}" ]] && { echo "fleet prune: --root needs a directory" >&2; return 2; }
        roots+=("$2"); shift 2 ;;
      -h|--help)    prune_usage; return 0 ;;
      *) echo "fleet prune: unknown flag '$1'" >&2; prune_usage >&2; return 2 ;;
    esac
  done

  # Classify against a fresh read of every claimant (prune_freshen_sessions),
  # not the 15-minute cache the status hint uses.
  PRUNE_FRESHEN=1

  # --porcelain is report-only by construction: a machine-readable mode that
  # could also delete is one typo away from an unattended sweep.
  if [[ $porcelain -eq 1 && $do_remove -eq 1 ]]; then
    echo "fleet prune: --porcelain is report-only; drop --remove or drop --porcelain" >&2
    return 2
  fi

  if [[ $all_repos -eq 1 ]]; then
    if [[ $do_remove -eq 1 ]]; then
      echo "fleet prune: --all-repos is report-only; run 'fleet prune --remove' inside the repo you mean" >&2
      return 2
    fi
    if [[ $porcelain -eq 1 ]]; then
      prune_all_repos_porcelain ${roots[@]+"${roots[@]}"}
    else
      prune_all_repos ${roots[@]+"${roots[@]}"}
    fi
    return 0
  fi

  prune_classify "$REPO_ROOT" "$BASE_BRANCH"

  if [[ $porcelain -eq 1 ]]; then
    # stdout is DATA ONLY: path \t branch \t bucket \t reason
    printf '%s' "$PRUNE_ROWS"
    return 0
  fi

  prune_render

  if [[ $SESSION_STORE_OK -ne 1 ]]; then
    if session_enabled; then
      echo "  session store unreadable (no store, no jq, or terminal-only host) -" >&2
    else
      echo "  session awareness is OFF (session_check=off) -" >&2
    fi
    echo "  every worktree degraded to REVIEW and nothing can be removed." >&2
  fi

  local safe_n; safe_n=$(prune_count SAFE)

  if [[ $do_remove -eq 0 ]]; then
    if [[ $safe_n -gt 0 ]]; then
      echo "  DRY RUN - nothing changed. To remove the $safe_n SAFE worktree(s):" >&2
      echo "    fleet prune --remove" >&2
      prune_recovery_note
    fi
    return 0
  fi

  if [[ $safe_n -eq 0 ]]; then
    prune_log "prune: nothing classified SAFE - nothing to remove"
    return 0
  fi

  # Explicit confirmation. Two independent gates, because the failure mode is
  # unrecoverable: --remove has to be typed, and then so does the word.
  if [[ $assume_yes -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      echo "fleet prune --remove: no terminal to confirm on." >&2
      echo "  Re-run interactively, or pass --yes if you have already reviewed the table." >&2
      return 2
    fi
    printf 'Remove %d SAFE worktree(s)? Type "remove" to confirm: ' "$safe_n" >&2
    local answer=""
    read -r answer || true
    if [[ "$answer" != "remove" ]]; then
      echo "aborted - nothing removed" >&2
      return 1
    fi
  fi

  prune_remove_safe
}

# Status-panel hint, so a growing backlog is visible instead of silent. Runs the
# same classifier `fleet prune` does — one pass, and only for lane worktrees.
# Off with prune_hint=off in config or FLEET_NO_PRUNE_HINT=1.
prune_status_hint() {
  [[ -n "${FLEET_NO_PRUNE_HINT:-}" ]] && return 0
  [[ "$(printf '%s' "$PRUNE_HINT" | tr '[:upper:]' '[:lower:]')" == "off" ]] && return 0
  prune_classify "$REPO_ROOT" "$BASE_BRANCH" || return 0
  local safe review
  safe=$(prune_count SAFE); review=$(prune_count REVIEW)
  [[ "$safe" -eq 0 && "$review" -eq 0 ]] && return 0
  local msg="$safe worktree(s) prunable"
  [[ "$review" -gt 0 ]] && msg="$msg, $review to review"
  # ASCII on purpose: this row is asserted for ASCII purity under TERM_ASCII=1,
  # and it renders on the same non-UTF-8 Windows consoles the panel supports.
  term_panel_line "$(term_mark warn) $(term_color dim "$msg - fleet prune")"
  return 0
}
# === END PRUNE ================================================================

# === LANDING MARKER ===========================================================
# One land at a time per repo, and the evidence when a land dies half-way.
#
# Every land holds $LANDING_FILE: the daemon's, `fleet land`, and each lane of
# `fleet land --all`. It is taken just before land_one and given back once that
# land's rebase_others pass is done, and ONLY then. So a marker whose process is
# gone means a land was cut short: kill -9, a crash, OOM, a harness tearing down
# the process tree, Ctrl-C, or an agent's Bash tool timing out a slow gate.
#
# The dangerous cut falls after `git merge` and before the gate's PASS/FAIL. The
# merge then sits on $BASE_BRANCH untested while the lane is still READY (or,
# for an untracked branch, has no lane file at all). The next land takes
# land_one's "Already up to date" path and marks it LANDED, which blesses a merge
# no gate ever passed. recover_stranded_landing runs before every land so that
# cannot happen.
#
# Never give the marker back from an EXIT trap or a signal handler. An exit in
# the middle of a land is exactly when it must survive (see daemon_cleanup).

# The marker, one line, built here and nowhere else:
#
#   <pid> TAB <start, epoch seconds> TAB <base tip SHA, or -> TAB <branch>
#
#   pid     whose land it is. cmd_stop trusts it only when this equals the live
#           daemon's PID (landing_of). Recovery treats it as live only while it
#           names a running fleet process (landing_pid_live).
#   start   for the elapsed times cmd_stop and the warnings print.
#   base    $BASE_BRANCH's tip when the land began: the discriminator for a dead
#           land. Tip unchanged means nothing merged and the lane can re-land.
#           A "merge: <branch>" commit after it means a merge no gate judged.
#           "-" when the branch did not resolve, never empty: TAB is IFS
#           whitespace to `read`, so an empty field would collapse and shift
#           the branch into this slot.
#   branch  last, so it is everything after the third TAB. TAB is a safe
#           separator because git refuses control characters in ref names.
#
# Created under noclobber (O_EXCL), so of two lands racing for it exactly one
# wins; the other sees the winner's marker and refuses or waits. It is written
# before land_one touches git, so a marker that stays empty (its writer killed
# between the open and the write) proves that land never began.
claim_landing() {
  local base
  base=$(git rev-parse -q --verify "refs/heads/$BASE_BRANCH" 2>/dev/null) || base="-"
  ( set -C; printf '%s\t%s\t%s\t%s\n' "$$" "$(date +%s)" "$base" "$1" > "$LANDING_FILE" ) 2>/dev/null
}
# Give the marker back once a land reached its verdict. Through remove_state_file,
# never a bare `rm -f`: a briefly-held marker (antivirus, the indexer) fails a
# single delete with EBUSY on Windows, and the daemon loop runs under errexit.
# Never fails. A marker that survives the retry is logged and left: it names
# this process, and once we exit, the next land's recovery finds the lane's
# verdict recorded (or the base unmoved) and clears it.
release_landing() {
  remove_state_file "$LANDING_FILE" "landing marker" \
    || log "WARNING: landing marker $LANDING_FILE survived (held open); the next land examines and clears it" \
    || true
}

# Remove the marker only if it is still the line $1 that recovery examined. Two
# fleet commands can recover the same stranded marker at once; the first one
# done may already have claimed a fresh marker for its own land, and a plain rm
# from the second would delete that live claim and let both land together.
# Status 1 when the examined marker cannot be removed (held open past the
# retry): the caller refuses, rather than misreading it as a live land.
release_examined() {
  local now=""
  { IFS= read -r now < "$LANDING_FILE"; } 2>/dev/null || true
  [[ "$now" == "$1" ]] || return 0
  remove_state_file "$LANDING_FILE" "examined landing marker" && return 0
  log "REFUSE: cannot clear the examined landing marker $LANDING_FILE (held open); rerun once it is free"
  return 1
}

# Parse $LANDING_FILE into M_PID / M_START / M_BASE / M_LANE. Status 1 when there
# is no marker. Globals rather than output, so cmd_stop's once-a-second poll
# costs no subshell.
M_PID="" M_START="" M_BASE="" M_LANE=""
read_landing_marker() {
  M_PID="" M_START="" M_BASE="" M_LANE=""
  [[ -f "$LANDING_FILE" ]] || return 1
  # Grouped so the redirect's own "No such file" goes to /dev/null too: the
  # writer can delete the marker between the test above and this read.
  { IFS=$'\t' read -r M_PID M_START M_BASE M_LANE < "$LANDING_FILE"; } 2>/dev/null || true
  # Three fields: the form before the base tip was recorded (pid, start, branch).
  if [[ -z "$M_LANE" && -n "$M_BASE" ]]; then M_LANE=$M_BASE M_BASE=""; fi
  if [[ "$M_BASE" == "-" ]]; then M_BASE=""; fi
  return 0
}

# Is the daemon with PID $1 mid-land? Status 0 with LANDING_LANE / LANDING_START
# set when it is; 1, both empty, when there is no marker or it belongs to some
# other process (a manual land, or a dead daemon).
LANDING_LANE=""
LANDING_START=""
landing_of() {
  LANDING_LANE="" LANDING_START=""
  read_landing_marker || return 1
  [[ -n "$M_LANE" && "$M_PID" == "$1" ]] || return 1
  LANDING_LANE=$M_LANE LANDING_START=$M_START
}

# Is PID $1 a live fleet process? kill -0 alone is not enough. A stranded marker
# can sit for hours and Windows reuses PIDs fast, so a dead land's PID may now
# name some unrelated process. Trusting it would make the dead land look like
# one in progress: every land refused, and what it left never examined. So the
# command line must mention fleet as well. /proc covers Linux and Git Bash (MSYS
# has /proc but no `ps -o`); `ps -o` covers macOS. When neither can say, assume
# live: a wrong "live" refuses loudly, while a wrong "dead" would recover a land
# that is still running. Never our own PID: we ask before we hold any marker.
landing_pid_live() {
  local p=$1 cmd=""
  [[ "$p" =~ ^[0-9]+$ && "$p" != "$$" ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  if [[ -r "/proc/$p/cmdline" ]]; then
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || cmd=""
  else
    cmd=$(ps -p "$p" -o command= 2>/dev/null) || cmd=""
  fi
  [[ -z "$cmd" || "$cmd" == *fleet* ]]
}

# Log, prefixed $1, which live land holds the marker (M_* already read).
log_landing_busy() {
  local who="pid $M_PID" age=""
  if [[ "$(cat "$PID_FILE" 2>/dev/null)" == "$M_PID" ]]; then who="the daemon (pid $M_PID)"; fi
  if [[ "$M_START" =~ ^[0-9]+$ ]]; then age=", started $(format_age $(( $(date +%s) - M_START ))) ago"; fi
  log "$1: another land is in progress: $who on ${M_LANE:-?}$age. One land at a time, so rerun once it finishes"
}

# Did a dead land's merge of $3 reach $BASE_BRANCH? $1 is the base tip its marker
# recorded (empty if none), $2 the tip now.
landing_merged() {
  local before=$1 now=$2 lane=$3 subj merges
  [[ -n "$now" && "$now" != "$before" ]] || return 1   # never moved: nothing merged
  if [[ -n "$before" ]] && git cat-file -e "$before^{commit}" 2>/dev/null; then
    # The only merge that land could make is land_one's own, subject exactly
    # "merge: <lane>" (matched exactly, as revert_find_merges explains), and
    # only after the tip it began from. Captured, not piped: SIGPIPE under
    # pipefail (see cmd_revert).
    merges=$(git log --merges --format=%s "$before..$now" 2>/dev/null) || merges=""
    while IFS= read -r subj; do
      if [[ "$subj" == "merge: $lane" ]]; then return 0; fi
    done <<< "$merges"
    return 1
  fi
  # No usable tip recorded. Fall back to "the lane's tip is in the base branch",
  # which over-flags only a lane that was already there; one `fleet land` of it
  # clears that.
  git rev-parse -q --verify "refs/heads/$lane" >/dev/null 2>&1 \
    && git merge-base --is-ancestor "refs/heads/$lane" "$now" 2>/dev/null
}

# --- reading the marker: is $BASE_BRANCH provisional? ---------------------------
# `fleet land` merges first and gates second, so for the whole gate (20-45 min on
# a big suite) the base tip is a "merge: <lane>" commit that a red gate
# hard-resets. On 2026-10-06 two peer sessions saw such a merge and read it as
# landed: one branched from it, the other rebased onto it and started a second
# gate. Nothing on disk said "provisional". landing_status is the ONE reader of
# that fact, behind `fleet status`'s top line, `fleet landing` and `fleet sweep`.
# It never recovers or clears a marker; that is a land's job (begin_land), so a
# status call cannot race a live land.
#
# Sets LS_STATE, LS_TIP (the base tip now) and M_* (the marker, if any):
#   CLEAR        nothing landing, nothing untested: act on the tip freely
#   LANDING      a live land that has merged nothing (before its merge, or a red
#                gate already rewound it). The tip is tested but about to move
#   PROVISIONAL  a live land merged and its gate has not ruled. The tip is
#                untested; a red gate resets it to M_BASE
#   SETTLING     its gate passed (lane LANDED) and its rebase pass is rewriting
#                the other lanes. The tip is tested; lane branches are moving
#   UNTESTED     a land died between merge and verdict, so the tip holds a merge
#                no gate judged: from a dead marker, or from the lane recovery
#                flagged (marker cleared, lane CONFLICT until a human settles it)
#   STALE        a land died and left nothing untested; the next land clears it
# Live = landing_pid_live, or our own pid: a reader inside the land itself
# (cmd_fleet at the end of land --all) is looking at a live land. An empty
# marker is a claim caught between its open and its write, so it is live too.
LS_STATE="CLEAR" LS_TIP=""
landing_status() {
  local state="" f s note
  LS_STATE="CLEAR"
  LS_TIP=$(git rev-parse -q --verify "refs/heads/$BASE_BRANCH" 2>/dev/null) || LS_TIP=""
  if ! read_landing_marker; then
    # Read with builtins, not head/sed: one fork per lane file is ~10ms each on
    # Windows, and this runs on every `fleet status`.
    for f in "$LANES_DIR"/*; do
      [[ -f "$f" ]] || continue
      s="" note=""
      { IFS= read -r s; IFS= read -r note; } < "$f" 2>/dev/null || true
      if [[ "${s%$'\r'}" == "CONFLICT" && "$note" == "UNTESTED MERGE"* ]]; then
        M_LANE=$(decode_lane "$(basename "$f")") LS_STATE="UNTESTED"
        return 0
      fi
    done
    return 0
  fi
  if [[ -n "$M_LANE" ]]; then state=$(lane_state "$M_LANE"); fi
  if [[ -z "$M_PID" || "$M_PID" == "$$" ]] || landing_pid_live "$M_PID"; then
    if [[ -z "$M_PID" || "$state" == "FAILED" ]]; then LS_STATE="LANDING"
    elif [[ "$state" == "LANDED" ]]; then LS_STATE="SETTLING"
    # No recorded base (a marker from before the base was recorded): cannot
    # prove nothing merged, so claim the worse case.
    elif [[ -z "$M_BASE" || "$LS_TIP" != "$M_BASE" ]]; then LS_STATE="PROVISIONAL"
    else LS_STATE="LANDING"
    fi
  elif [[ -n "$M_LANE" && "$state" != "LANDED" && "$state" != "FAILED" ]] \
       && landing_merged "$M_BASE" "$LS_TIP" "$M_LANE"; then
    LS_STATE="UNTESTED"
  else
    LS_STATE="STALE"
  fi
  return 0
}

# Epoch seconds -> local HH:MM. GNU date first, then BSD (macOS).
clock_of() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || printf '?'; }

# The one-line verdict for LS_* (call landing_status first); empty for CLEAR.
# ASCII only: it renders on the same non-UTF-8 consoles as the status panel, and
# sweep.sh carries it verbatim. The PROVISIONAL wording is the contract peers
# grep for; tests/run.sh asserts it.
landing_line() {
  local tip=${LS_TIP:0:7} base=${M_BASE:0:7} lane=${M_LANE:-?} since="?" ago=""
  if [[ "$M_START" =~ ^[0-9]+$ ]]; then
    since=$(clock_of "$M_START")
    ago=", $(format_age $(( $(date +%s) - M_START ))) ago"
  fi
  case "$LS_STATE" in
    PROVISIONAL)
      printf '%s %s is PROVISIONAL - gate for %s running since %s (pid %s); red resets to %s\n' \
        "$BASE_BRANCH" "$tip" "$lane" "$since" "${M_PID:-?}" "${base:-its pre-merge tip}" ;;
    LANDING)
      printf 'land of %s in progress since %s (pid %s); %s %s is about to move - wait for its verdict\n' \
        "$lane" "$since" "${M_PID:-?}" "$BASE_BRANCH" "$tip" ;;
    SETTLING)
      printf '%s %s landed %s (gate green); its rebase pass is still running (pid %s) - wait before rebasing a lane\n' \
        "$BASE_BRANCH" "$tip" "$lane" "${M_PID:-?}" ;;
    UNTESTED)
      if [[ -n "$M_PID" ]]; then
        printf '%s %s holds an UNTESTED merge of %s - its land (pid %s, from %s%s) died before the gate ruled; the next land flags it\n' \
          "$BASE_BRANCH" "$tip" "$lane" "$M_PID" "$since" "$ago"
      else
        printf '%s %s holds an UNTESTED merge of %s - verify, then fleet land %s (green) or fleet revert %s (red)\n' \
          "$BASE_BRANCH" "$tip" "$lane" "$lane" "$lane"
      fi ;;
    STALE)
      printf 'a land of %s (pid %s, from %s%s) died; nothing of it is untested on %s %s - the next land clears its marker\n' \
        "$lane" "${M_PID:-?}" "$since" "$ago" "$BASE_BRANCH" "$tip" ;;
  esac
}

# `fleet status`'s top line. Nothing at all when CLEAR.
landing_status_row() {
  landing_status
  [[ "$LS_STATE" == "CLEAR" ]] && return 0
  term_panel_vert
  case "$LS_STATE" in
    STALE) term_panel_line "$(term_mark skip) $(term_color dim "$(landing_line)")" ;;
    UNTESTED|PROVISIONAL) term_panel_line "$(term_mark warn) $(term_color red "$(landing_line)")" ;;
    *)     term_panel_line "$(term_mark warn) $(term_color yellow "$(landing_line)")" ;;
  esac
}

# `fleet landing [--porcelain]`: may a session act on the base tip right now?
# Read-only, so any session may poll it: peers run it (or `fleet status`) before
# branching from or rebasing onto the base. Exit 0 for CLEAR and STALE (the tip
# is tested and nothing is landing); 10 for the rest, the domain signal "wait".
# stdout is the one-line verdict, or with --porcelain one TSV row, read by
# sweep.sh (so the marker has one parser):
#   state TAB tip TAB base TAB lane TAB pid TAB start TAB verdict-line
# with "-" for an empty field (TAB is IFS whitespace to `read`, and an empty
# field would collapse and shift the rest).
cmd_landing() {
  local porcelain=0 line
  case "${1:-}" in
    --porcelain) porcelain=1 ;;
    "") : ;;
    *) echo "usage: fleet landing [--porcelain]" >&2; return 2 ;;
  esac
  landing_status
  line=$(landing_line)
  if [[ "$LS_STATE" == "CLEAR" ]]; then line="$BASE_BRANCH ${LS_TIP:0:7}: no land in progress, nothing untested"; fi
  if [[ $porcelain -eq 1 ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LS_STATE" "${LS_TIP:--}" "${M_BASE:--}" \
      "${M_LANE:--}" "${M_PID:--}" "${M_START:--}" "$line"
  else
    printf '%s\n' "$line"
  fi
  case "$LS_STATE" in CLEAR|STALE) return 0 ;; *) return 10 ;; esac
}

# Lanes recover_stranded_landing flagged in THIS process, one per line.
RECOVERY_FLAGGED=""

# A dead land's rebase_others may have left another lane's worktree stuck
# mid-rebase onto $2 (the base tip it had just landed). worktree_path_for cannot
# find that worktree: mid-rebase, `git worktree list` reports it as "detached".
# So this reads each worktree's own git dir under $1. The rebase is NOT aborted:
# the lane's session may be resolving that conflict right now, and its worktree
# is not fleet's to reset. CONFLICT keeps the lane out of every land until its
# owner finishes or aborts and signals READY again.
recover_stranded_rebases() {
  local gd=$1 tip=$2 wgd rd hb onto wt
  for wgd in "$gd"/worktrees/*; do
    if [[ -d "$wgd/rebase-merge" ]]; then rd="$wgd/rebase-merge"
    elif [[ -d "$wgd/rebase-apply" ]]; then rd="$wgd/rebase-apply"
    else continue
    fi
    hb="" onto="" wt=""
    { read -r hb < "$rd/head-name"; } 2>/dev/null || true
    { read -r onto < "$rd/onto"; } 2>/dev/null || true
    hb=${hb#refs/heads/}
    [[ -n "$hb" && -f "$LANES_DIR/$(encode_lane "$hb")" ]] || continue
    case "$(lane_state "$hb")" in LANDED|FAILED) continue ;; esac
    # rebase_others rebases onto the tip it just landed. A rebase onto anything
    # else is the lane session's own business.
    [[ -z "$onto" || "$onto" == "$tip" ]] || continue
    { read -r wt < "$wgd/gitdir"; } 2>/dev/null || true
    wt=${wt%/.git}
    [[ -n "$wt" ]] || wt=$wgd
    set_lane_state "$hb" "CONFLICT" "rebase onto $BASE_BRANCH cut short by a land that died; finish or abort it in $wt, then signal READY"
    RECOVERY_FLAGGED+="$hb"$'\n'
    log "WARNING: $hb is stuck mid-rebase onto $BASE_BRANCH in $wt"
    log "         The dead land's rebase pass started it and never finished. Marked CONFLICT."
    log "         Look:     git -C \"$wt\" status"
    log "         Undo it:  git -C \"$wt\" rebase --abort   (puts the lane back exactly as it was)"
    log "         then signal READY again from the lane."
  done
}

# Examine a marker left by a land that never reached a verdict, before any new
# land may start. Status:
#   0  no marker now: there was none, or a stranded one was examined and cleared
#   1  refuse: the main checkout is mid-merge or mid-rebase. The marker stays,
#      so the next run examines it again once a human has dealt with that.
#   2  a live fleet process holds it: a land is in progress right now (M_* set)
#
# What a dead land can leave, and what each finding gets:
#   base tip unchanged      nothing merged (it died before the merge, or after a
#                           red gate's rewind). Lane untouched; it re-lands.
#   "merge: <lane>" since   THE hazard: a merge no gate judged, lane not LANDED
#                           or FAILED. Loud WARNING with the verify / revert
#                           commands, and lane -> CONFLICT. Left READY (or
#                           untracked), the next land would bless it.
#   lane worktree mid-rebase  see recover_stranded_rebases.
#   main checkout mid-merge or mid-rebase  refuse, naming the abort command.
#                           Never aborted here: it is the integration tree, and
#                           a human may be resolving it.
# Every finding is re-derived from git each time, so a recovery that is itself
# interrupted is simply redone.
recover_stranded_landing() {
  read_landing_marker || return 0
  if [[ -z "$M_PID" ]]; then
    # Caught between a claim's open and its write; give that writer a moment.
    sleep 1
    read_landing_marker || return 0
  fi
  if landing_pid_live "$M_PID"; then return 2; fi
  local seen=""
  { IFS= read -r seen < "$LANDING_FILE"; } 2>/dev/null || true
  if [[ -z "$M_LANE" ]]; then
    log "NOTE: clearing an unreadable landing marker (pid ${M_PID:-?}); its land died before touching git"
    release_examined "$seen" || return 1
    return 0
  fi

  local age="" tip state shown gd hb=""
  if [[ "$M_START" =~ ^[0-9]+$ ]]; then age=", started $(format_age $(( $(date +%s) - M_START ))) ago"; fi
  # NOTE, not WARNING: only the findings below that need a human say WARNING.
  log "NOTE: a land of $M_LANE (pid $M_PID$age) died before finishing; checking what it left"
  tip=$(git rev-parse -q --verify "refs/heads/$BASE_BRANCH" 2>/dev/null) || tip=""
  state=$(lane_state "$M_LANE")
  shown=$state
  if [[ "$state" == "MISSING" ]]; then shown="untracked"; fi

  case "$state" in
    LANDED|FAILED)
      log "  $M_LANE is $state: land_one recorded its verdict before the process died" ;;
    *)
      if landing_merged "$M_BASE" "$tip" "$M_LANE"; then
        set_lane_state "$M_LANE" "CONFLICT" "UNTESTED MERGE on $BASE_BRANCH: its land died before the gate passed or failed. Verify, then fleet land $M_LANE (green) or fleet revert $M_LANE (red)"
        RECOVERY_FLAGGED+="$M_LANE"$'\n'
        log "WARNING: UNTESTED MERGE on $BASE_BRANCH: $M_LANE"
        log "         Its land merged it, then died before the gate passed or failed: no gate has judged it."
        log "         $BASE_BRANCH moved ${M_BASE:0:12}${M_BASE:+ }-> ${tip:0:12} since that land began."
        log "         $M_LANE is now CONFLICT (was $shown), so nothing lands it as-is. Every other"
        log "         land's gate runs over it too until it is settled. Verify it by hand:"
        log "           cd \"$REPO_ROOT\" && git checkout $BASE_BRANCH && ${TEST_CMD:-<test_cmd>}"
        log "         green: fleet land $M_LANE     marks it LANDED, rebases the other lanes"
        log "         red:   fleet revert $M_LANE   reverts the merge; the lane goes back to RUNNING"
      elif [[ -n "$M_BASE" && "$tip" == "$M_BASE" ]]; then
        log "  $BASE_BRANCH has not moved since that land began, so nothing merged; $M_LANE ($shown) lands normally"
      else
        log "  $BASE_BRANCH holds no merge of $M_LANE from that land; $M_LANE ($shown) lands normally"
      fi ;;
  esac

  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  if [[ -n "$gd" ]]; then
    recover_stranded_rebases "$gd" "$tip"
    # The main checkout is where every land runs. A merge or a plain lane's
    # rebase left half-done there makes the next land refuse with "uncommitted
    # tracked changes", which names the symptom and hides the cause.
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      log "REFUSE: $REPO_ROOT is mid-merge; the dead land's \`git merge\` never finished"
      log "        Nothing of it was committed. Undo it, then rerun:"
      log "          git -C \"$REPO_ROOT\" merge --abort"
      return 1
    fi
    if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
      { read -r hb < "$gd/rebase-merge/head-name"; } 2>/dev/null \
        || { read -r hb < "$gd/rebase-apply/head-name"; } 2>/dev/null || true
      log "REFUSE: $REPO_ROOT is mid-rebase of ${hb#refs/heads/}; the dead land's rebase pass never finished"
      log "        Undo it, then rerun:"
      log "          git -C \"$REPO_ROOT\" rebase --abort"
      log "          git -C \"$REPO_ROOT\" checkout $BASE_BRANCH"
      return 1
    fi
  fi
  release_examined "$seen" || return 1
}

# Examine any stranded marker, then take the marker for a land of $1. Status:
#   0  taken: run the land, then release_landing
#   1  refused, reason already logged
#   2  another fleet process is landing right now (M_* describe it)
begin_land() {
  local branch=$1 rc=0
  recover_stranded_landing || rc=$?
  if [[ $rc -ne 0 ]]; then return "$rc"; fi
  # Never land a lane recovery just flagged. This same call would otherwise take
  # land_one's "Already up to date" path and mark it LANDED right under the
  # warning. A LATER `fleet land` of it is the operator's verified decision.
  if [[ $'\n'"$RECOVERY_FLAGGED" == *$'\n'"$branch"$'\n'* ]]; then
    log "REFUSE LAND: $branch was flagged above. Settle it first, then rerun: fleet land $branch"
    return 1
  fi
  mkdir -p "$FLEET_DIR"
  if claim_landing "$branch"; then return 0; fi
  # Lost a race: another land claimed it between the check and the claim.
  if read_landing_marker && [[ -n "$M_PID" ]]; then return 2; fi
  log "REFUSE LAND: $branch: cannot create $LANDING_FILE"
  return 1
}

# === END LANDING MARKER =======================================================

# LAND_RESULT — how the last land_one() call finished, for callers that need a
# distinction the exit code cannot carry. land_one returns 0 for "this lane's
# work is in $BASE_BRANCH", which is true both when this run merged it and when
# it was already there; cmd_land_all must tally those separately or its summary
# claims lands the batch never performed.
#   LANDED   merge created by THIS run, gate passed
#   ALREADY  no merge performed — already contained in $BASE_BRANCH
#   CONFLICT | FAILED | REFUSED   the return-1 paths
LAND_RESULT=""

land_one() {
  local branch=$1
  LAND_RESULT="REFUSED"
  # Cheapest refusal first, and BEFORE the merge below — an unarmed gate must
  # never reach a state where $BASE_BRANCH has already moved.
  require_test_cmd || return 1
  # $SKIP_SESSION_CHECK is the consumed copy of FLEET_SKIP_SESSION_CHECK — the
  # env var itself was unset at startup so it can never reach test_cmd below.
  if [[ -z "$SKIP_SESSION_CHECK" ]]; then
    session_land_gate "$branch" || { LAND_RESULT="CONFLICT"; set_lane_state "$branch" "CONFLICT" "owning session still live"; return 1; }
  fi
  local hits
  hits=$(scrub_diff "$branch")
  if [[ -n "$hits" ]]; then
    log "REFUSE LAND: $branch failed scrub-check"
    echo "$hits" | head -10 | tee -a "$LOG"
    LAND_RESULT="CONFLICT"
    set_lane_state "$branch" "CONFLICT" "scrub-check failed"
    return 1
  fi
  if is_dirty_tracked; then
    log "REFUSE LAND: $BASE_BRANCH has uncommitted tracked changes — clean before landing"
    return 1
  fi

  log "LANDING: $branch"
  # Everything below reasons about $BASE_BRANCH's tip, so a failed checkout must
  # refuse rather than proceed against the wrong branch's history: it would merge
  # into — and, on a red gate, reset — whichever branch happened to be current.
  # set -e does not cover this: every call site invokes land_one inside `if` or
  # `&&`, which disables errexit for the whole call.
  if ! git checkout "$BASE_BRANCH"; then
    log "REFUSE LAND: cannot check out $BASE_BRANCH"
    return 1
  fi
  # The pre-merge tip, captured for two jobs, both load-bearing:
  #
  #   1. DID WE ACTUALLY MERGE? `git merge --no-ff` exits 0 with "Already up to
  #      date." when $branch is already an ancestor of $BASE_BRANCH — typically
  #      because another session landed it while this one was queued. No merge
  #      commit is created and HEAD does not move, but the exit status is
  #      indistinguishable from a real merge, so fleet used to log
  #      `PASS: <branch> landed` for a land it never performed. Compare SHAs,
  #      never git's prose: "Already up to date." is locale- and version-dependent.
  #   2. WHAT DOES A RED GATE UNDO? The revert below resets to exactly this SHA
  #      rather than to `HEAD^`. On the no-op path `HEAD^` is the first parent of
  #      SOMEONE ELSE'S merge commit, so a failing gate silently discarded a peer
  #      session's landed work on a branch fleet believed it owned (reproduced
  #      2026-09-08). Resetting to $before can only ever undo the merge THIS
  #      invocation created — true even if the detection in (1) is later reworked.
  local before after
  before=$(git rev-parse HEAD)
  if git merge "$branch" --no-ff -m "merge: $branch"; then
    after=$(git rev-parse HEAD)
    if [[ "$before" == "$after" ]]; then
      # Benign no-op, deliberately NOT reported as a land. The end state the
      # caller wanted is already true — the lane's work is in $BASE_BRANCH — so
      # this is success (return 0, state LANDED) and the lane must not be
      # retried. Three things it must not do:
      #   * claim it landed anything. The distinct verb is the point: an operator
      #     reading activity.log has to be able to tell "I landed it" from
      #     "someone else already had".
      #   * run test_cmd. The gate answers "did MY merge break $BASE_BRANCH", and
      #     there is no merge of ours to answer for. This is NOT the 2026-08-04
      #     untested-merge landmine in new clothes — that one merged and then
      #     skipped the gate; here nothing was merged, and a red result would
      #     have no remedy anyway (see the next point).
      #   * fall through to the revert path, which would hard-reset a merge
      #     commit this run did not create.
      # The lane branch is left alone for the same reason: deleting a branch we
      # did not just land is a surprise, and cleanup belongs to whoever did land
      # it (`fleet prune` classifies its worktree SAFE either way).
      log "ALREADY LANDED: $branch — already in $BASE_BRANCH, no merge performed by this run"
      LAND_RESULT="ALREADY"
      set_lane_state "$branch" "LANDED" "already in $BASE_BRANCH — no merge performed by this run"
      return 0
    fi
    # No "$TEST_CMD is empty" branch here by design: require_test_cmd above
    # guarantees it is set, so the gate always runs. The old else-branch
    # ("trusting signal.sh's log gate") is what let untested merges through.
    log "running test_cmd: $TEST_CMD"
    # Sanitized subshell: fleet's own behaviour-altering env knobs must not
    # reach the suite test_cmd invokes — a suite that itself exercises fleet
    # (fleet-ops' self-test, run via this repo's test_cmd) would inherit
    # overrides meant for THIS invocation only and test the wrong behaviour.
    # FLEET_SKIP_SESSION_CHECK is already consumed at startup; strip the rest
    # of the family here for depth.
    if ( unset FLEET_SKIP_SESSION_CHECK FLEET_SESSION_STORE FLEET_SESSION_NOCACHE \
               FLEET_TRANSCRIPT_ROOTS FLEET_SESSION_LIVE_SECS FLEET_SESSION_CACHE_TTL \
               FLEET_SESSION_MAX_AGE_DAYS FLEET_SELF_SESSION_ID \
               FLEET_NO_PRUNE_HINT FLEET_PRUNE_ROOTS FLEET_PRUNE_MAX_REPOS \
               FLEET_ASCII FLEET_RM_RETRY_SECS
         eval "$TEST_CMD" ) >>"$LOG" 2>&1; then
      log "PASS: $branch landed"
    else
      log "FAIL: tests failed — reverting $branch"
      # $before, not HEAD^ — see (2) above. And checked, because an unchecked
      # rewind is the same lie in miniature: if the reset fails (a locked file
      # under Windows is the realistic way), the failing merge stays on
      # $BASE_BRANCH while the lane confidently reports FAILED, and nothing
      # anywhere says the base branch is now broken.
      if git reset --hard "$before"; then
        set_lane_state "$branch" "FAILED" "tests failed post-merge"
      else
        log "ERROR: could not reset $BASE_BRANCH to $before"
        log "       THE FAILING MERGE IS STILL ON $BASE_BRANCH — fix by hand:"
        log "         git checkout $BASE_BRANCH && git reset --hard $before"
        set_lane_state "$branch" "FAILED" "tests failed; rewind to $before FAILED — merge still on $BASE_BRANCH"
      fi
      LAND_RESULT="FAILED"
      return 1
    fi
    LAND_RESULT="LANDED"
    set_lane_state "$branch" "LANDED"
    git branch -d "$branch" 2>/dev/null || git branch -D "$branch" 2>/dev/null || true
    return 0
  else
    log "MERGE CONFLICT: $branch"
    git merge --abort 2>/dev/null || true
    LAND_RESULT="CONFLICT"
    set_lane_state "$branch" "CONFLICT" "merge conflict with $BASE_BRANCH"
    return 1
  fi
}

# Every worktree with branch $1 checked out, in git's own path form (normally
# one — git refuses a second checkout without --force); empty when none.
# The path is everything after "worktree ", never awk's $2: that cut a path
# containing a space at the space, which would point rebase_others at the
# wrong directory and leave the land gate's directory join matching nothing.
worktree_path_for() {
  local branch=$1
  git worktree list --porcelain 2>/dev/null | awk -v want="branch refs/heads/$branch" '
    /^worktree / { p = substr($0, 10) }
    $0 == want   { print p }
  ' || true
}

rebase_others() {
  local landed=$1
  for f in "$LANES_DIR"/*; do
    local b state wt
    b=$(decode_lane "$(basename "$f")")
    [[ "$b" == "$landed" ]] && continue
    state=$(lane_state "$b")
    [[ "$state" == "LANDED" || "$state" == "FAILED" ]] && continue
    git rev-parse --verify "$b" >/dev/null 2>&1 || continue
    log "rebase: $b onto $BASE_BRANCH"

    wt=$(worktree_path_for "$b")
    if [[ -n "$wt" ]]; then
      # Branch is checked out in a worktree — run rebase from there
      if git -C "$wt" rebase "$BASE_BRANCH" 2>>"$LOG"; then
        log "rebase OK: $b (in worktree $wt)"
      else
        log "rebase CONFLICT: $b"
        git -C "$wt" rebase --abort 2>/dev/null || true
        set_lane_state "$b" "CONFLICT" "rebase against $BASE_BRANCH failed"
      fi
    else
      # Plain branch (no worktree) — rebase via the main repo
      if git rebase "$BASE_BRANCH" "$b" 2>>"$LOG"; then
        log "rebase OK: $b"
      else
        log "rebase CONFLICT: $b"
        git rebase --abort 2>/dev/null || true
        set_lane_state "$b" "CONFLICT" "rebase against $BASE_BRANCH failed"
      fi
    fi
  done
  git checkout "$BASE_BRANCH" 2>/dev/null || true
}

cmd_land() {
  local branch=${1:-} rc=0
  [[ -z "$branch" ]] && { echo "usage: fleet land <branch>" >&2; exit 1; }
  begin_land "$branch" || rc=$?
  if [[ $rc -eq 2 ]]; then log_landing_busy "REFUSE LAND: $branch"; fi
  if [[ $rc -ne 0 ]]; then return 1; fi
  # The marker is released only after a verdict. If this process dies anywhere
  # in between, it stays behind for the next land's recovery to examine.
  if ! land_one "$branch"; then release_landing; return 1; fi
  rebase_others "$branch"
  release_landing
}

# Batch-land every landable lane in one pass. Default: READY lanes only
# (daemon semantics — a session signalled it's done). --running also includes
# RUNNING lanes, for the git-ops "land all" path where landability was vetted
# out of band (clean, ahead, not a live writer) before the branches were
# tracked. Lands OLDEST-BRANCH-FIRST so the sequence is stable and explainable,
# rebases the remaining lanes after each land, and CONTINUES past a lane that
# conflicts or fails — reporting a one-shot summary at the end rather than
# aborting the whole batch on the first bad lane.
cmd_land_all() {
  local include_running=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --running|--include-running) include_running=1; shift ;;
      *) echo "usage: fleet land --all [--running]" >&2; exit 1 ;;
    esac
  done
  ensure_fleet_dir

  # Before choosing candidates, so a dead land's lane is flagged, not picked.
  local rrc=0
  recover_stranded_landing || rrc=$?
  if [[ $rrc -eq 2 ]]; then log_landing_busy "land --all: REFUSED"; fi
  if [[ $rrc -ne 0 ]]; then return 1; fi

  # Collect candidate lanes with their tip-commit time, so we can order them.
  local candidates=() f b state ts
  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    b=$(decode_lane "$(basename "$f")")
    state=$(head -n1 "$f")
    case "$state" in
      READY)   : ;;
      RUNNING) [[ $include_running -eq 1 ]] || continue ;;
      *)       continue ;;
    esac
    git rev-parse --verify "refs/heads/$b" >/dev/null 2>&1 || continue
    ts=$(git log -1 --format=%ct "$b" 2>/dev/null || echo 0)
    candidates+=("$ts"$'\t'"$b")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    local scope; scope=$([[ $include_running -eq 1 ]] && echo "RUNNING/READY" || echo "READY")
    log "land --all: no landable lanes ($scope)"
    cmd_fleet
    return 0
  fi

  # Oldest-commit-first — a stable, explainable landing order.
  local ordered
  ordered=$(printf '%s\n' "${candidates[@]}" | sort -n)

  local landed=0 already=0 conflict=0 failed=0 brc stopped=""
  while IFS=$'\t' read -r ts b; do
    [[ -z "$b" ]] && continue
    # Re-read: the scan above is a snapshot, and recovery or a concurrent land
    # can have moved this lane since. Only what is landable NOW is landed.
    case "$(lane_state "$b")" in
      READY)   : ;;
      RUNNING) [[ $include_running -eq 1 ]] || continue ;;
      *)       continue ;;
    esac
    brc=0
    begin_land "$b" || brc=$?
    if [[ $brc -ne 0 ]]; then
      if [[ $brc -eq 2 ]]; then log_landing_busy "land --all: stopping before $b"; fi
      stopped=$b
      break
    fi
    if land_one "$b"; then
      rebase_others "$b"
      # A no-op land — the branch was already in $BASE_BRANCH, another session
      # got there first — returns 0 exactly like a real one, so it has to be
      # tallied apart or the summary reports lands this batch never performed.
      if [[ "$LAND_RESULT" == "ALREADY" ]]; then
        already=$((already+1))
      else
        landed=$((landed+1))
      fi
    else
      case "$(lane_state "$b")" in
        CONFLICT) conflict=$((conflict+1)) ;;
        *)        failed=$((failed+1)) ;;
      esac
    fi
    release_landing
  done <<< "$ordered"

  # The "already" clause appears only when it is non-zero, so an ordinary batch
  # logs the same line it always did and the extra term reads as a real event.
  local summary="land --all: $landed landed"
  # NB: `[[ ... ]] && summary=...` would return 1 when already==0, and cmd_land_all
  # runs with errexit live (dispatched directly, not from an `if`) — see the same
  # trap noted in ensure_fleet_dir.
  if [[ $already -gt 0 ]]; then summary="$summary, $already already in $BASE_BRANCH"; fi
  summary="$summary, $conflict conflict, $failed failed"
  if [[ -n "$stopped" ]]; then summary="$summary; stopped before $stopped, the rest not tried"; fi
  log "$summary"
  cmd_fleet
  # Non-zero exit when anything didn't land, so orchestrators can branch on it.
  [[ $((conflict + failed)) -eq 0 && -z "$stopped" ]]
}

# `fleet stop` asks, then waits, and NEVER SIGKILLs a daemon that is mid-land.
#
# The daemon defers SIGTERM to a safe point (see daemon_request_stop), so during
# a land the signal only queues. The old fixed "5s grace, then SIGKILL" fired
# straight through that: with any test_cmd slower than 5s (this repo's own gate
# takes minutes) it killed the daemon mid-gate. The merge stayed on $BASE_BRANCH
# untested because the gate's rewind never ran, the lane stayed READY, and
# test_cmd ran on orphaned. Worse, the next pass took land_one's "Already up to
# date" path and marked the lane LANDED, blessing a merge no gate ever passed.
#
# So the grace clock runs only while the daemon is NOT landing, judged by the
# landing marker (format at claim_landing). Mid-land, this waits as long
# as the gate takes, printing progress, and the clock restarts from zero once
# the land is done. Do not "simplify" this back to a fixed deadline: there is no
# deadline that is safe for every repo's test_cmd. SIGKILL stays only as the
# backstop for a daemon that is idle and still ignoring SIGTERM.
#
# Interrupting `fleet stop` itself is always safe: the request is already
# delivered, and the daemon exits after the land either way. To abort a hung
# gate, kill test_cmd's process, never the daemon: the gate then fails and
# land_one rewinds the merge before the daemon exits.
cmd_stop() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "no daemon running (no $PID_FILE)" >&2
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if ! kill -0 "$pid" 2>/dev/null; then
    log "stale PID file (pid $pid not alive) — clearing"
    remove_state_file "$PID_FILE" "stale PID file" || return 1
    return 0
  fi
  log "sending SIGTERM to daemon (pid $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  local idle=0 waited=0 told=""
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    kill -0 "$pid" 2>/dev/null || break
    if landing_of "$pid"; then
      idle=0
      if [[ "$told" != "$LANDING_LANE" ]]; then
        log "daemon is mid-land on $LANDING_LANE (started $(( $(date +%s) - LANDING_START ))s ago) — waiting for its gate; it exits once that land finishes. Interrupting this command is safe"
        told=$LANDING_LANE
      elif (( waited % 15 == 0 )); then
        echo "  ...still landing $LANDING_LANE ($(( $(date +%s) - LANDING_START ))s)" >&2
      fi
    else
      idle=$((idle + 1))
      if (( idle >= 5 )); then
        log "daemon didn't exit on SIGTERM, sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        remove_state_file "$PID_FILE" "daemon PID file" || return 1
        return 0
      fi
    fi
  done
  log "daemon stopped"
}

# Every merge commit on $BASE_BRANCH whose subject is EXACTLY "merge: <branch>",
# newest first. The exactness is the whole point, and it is why this cannot be
# `git log --grep`:
#
#   * --grep matches a SUBSTRING, so `--grep="merge: lane/auth"` also matches
#     `merge: lane/auth-refactor`. With `-n1` picking the newest match, a
#     `fleet revert lane/auth` run after lane/auth-refactor landed reverted the
#     REFACTOR branch and logged `reverted: lane/auth` (reproduced 2026-09-08) —
#     a destructive operation aimed at the wrong target, reported as the right
#     one. Sibling lane names differing only by suffix are the norm, not an edge
#     case.
#   * --grep is a REGEX, and the branch name is interpolated raw. `feat/a.b`
#     matched a landed `merge: feat/aXb`; a name containing `*`, `[`, or `\`
#     is worse still. Branch names are data, never patterns.
#
# The subject is the contract fleet itself writes in land_one, and SKILL.md
# says so ("this message is what fleet revert finds later") — matching it
# exactly is therefore both the correct lookup and the documented one. Structural
# alternatives (second parent == branch tip) do not survive land_one deleting the
# lane branch, which is why the message is load-bearing.
revert_find_merges() {
  local branch=$1 want="merge: $branch" raw sha subj
  raw=$(git log "$BASE_BRANCH" --merges --format='%H%x09%s' 2>/dev/null || true)
  [[ -z "$raw" ]] && return 0
  while IFS=$'\t' read -r sha subj; do
    # `if`, not `[[ ]] && printf`: a non-matching final line would make the loop
    # — and this function — return 1, which errexit turns into a dead `fleet
    # revert`. Same trap noted in ensure_fleet_dir.
    if [[ "$subj" == "$want" ]]; then printf '%s\n' "$sha"; fi
  done <<< "$raw"
  return 0
}

cmd_revert() {
  local branch=${1:-}
  [[ -z "$branch" ]] && { echo "usage: fleet revert <branch>" >&2; exit 1; }

  local shas sha line n k
  shas=$(revert_find_merges "$branch")
  if [[ -z "$shas" ]]; then
    log "ERROR: no merge commit found for $branch on $BASE_BRANCH"
    exit 1
  fi
  # Collected into an array rather than counted and sliced with `| wc -l` and
  # `| head -n1`: under `set -o pipefail` a reader that exits early can kill the
  # writer with SIGPIPE (141) and fail the whole command substitution — the same
  # trap tests/run.sh documents for `git log | grep -q`. No pipe, no trap.
  local -a cand=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then cand+=("$line"); fi
  done <<< "$shas"
  n=${#cand[@]}
  sha=${cand[0]}   # git log walks newest-first

  # Refuse on a dirty base for the same reason land_one does, and BEFORE
  # announcing an intent we may not be able to carry out: git revert would fail
  # here anyway, but later and with a message about the tree rather than about
  # the land queue.
  if is_dirty_tracked; then
    log "REFUSE REVERT: $BASE_BRANCH has uncommitted tracked changes — clean before reverting"
    exit 1
  fi
  if ! git checkout "$BASE_BRANCH"; then
    log "ERROR: cannot check out $BASE_BRANCH — nothing reverted"
    exit 1
  fi

  # A branch landed, reverted, then re-landed has more than one `merge: X` on
  # $BASE_BRANCH. Reverting the newest is right, but it must be SAID: silently
  # choosing among several candidates is how the substring bug above stayed
  # invisible for so long.
  if [[ "$n" -gt 1 ]]; then
    log "NOTE: $n merges of $branch on $BASE_BRANCH — reverting the most recent, $sha"
    for (( k = 1; k < n; k++ )); do
      log "      not reverted (older): ${cand[$k]}"
    done
  fi
  log "reverting merge $sha (was: $branch)"

  if ! git revert -m 1 "$sha" --no-edit; then
    # Leave no sequencer behind. Without this, a conflicting revert stranded the
    # repo mid-`git revert` with a conflicted index and no message saying so —
    # and the operator's next `fleet land` refused with "uncommitted tracked
    # changes", which describes the symptom and hides the cause.
    log "REVERT FAILED: $branch — conflict, or this merge is already reverted"
    git revert --abort 2>/dev/null || git revert --quit 2>/dev/null || true
    log "              aborted; $BASE_BRANCH left as it was"
    exit 1
  fi
  log "reverted: $branch ($sha)"

  # The lane claimed LANDED and no longer is; leaving it there is a status panel
  # that lies about where the work lives. RUNNING rather than a new REVERTED
  # state on purpose: an unknown state string would fall through the panel's
  # count map (idx=-1), and the daemon's terminal test is literally
  # "not LANDED and not FAILED", so a REVERTED lane would keep the daemon alive
  # forever. RUNNING is also simply true — the commits are on the branch, not in
  # $BASE_BRANCH — and non-terminal, which is what a reverted lane is.
  # Only ever UPDATES a lane; `fleet revert` on an untracked branch must not
  # conjure one into the status panel.
  if [[ "$(lane_state "$branch")" != "MISSING" ]]; then
    set_lane_state "$branch" "RUNNING" "reverted from $BASE_BRANCH ($sha)"
  fi
}

# A signal is a STOP REQUEST, never an exit from inside the handler. Two ways to
# get this wrong, the first shipped until 2026-09-28:
#
#   1. `trap daemon_cleanup INT TERM HUP` with a handler that did not exit. A
#      trapped signal runs its handler and then RESUMES the script, so the daemon
#      logged "daemon stopping", deleted its PID file, and kept polling. SIGHUP is
#      what it gets when its Claude session ends: the ghost landed a lane 3s
#      later, invisible to `fleet stop` ("no daemon running") and to the
#      double-start guard, both of which trust the PID file.
#   2. Calling `exit` in the handler instead. bash runs a trap between commands,
#      so the exit can fall between land_one's `git merge` and its test gate —
#      an untested merge left on $BASE_BRANCH, the landmine require_test_cmd
#      exists to prevent.
#
# So the handler only records the request and cuts the poll sleep short; the
# loop checks it at two safe points (before starting a land, and before
# sleeping) and returns normally, and the EXIT trap does the cleanup. A land
# already in progress always finishes, test gate included.
DAEMON_STOP=""
DAEMON_SLEEP_PID=""

daemon_request_stop() {
  DAEMON_STOP=$1
  # The poll `sleep` is a child the loop waits on with the `wait` builtin, which
  # a trapped signal interrupts at once; kill the child too so it does not
  # outlive the daemon holding the repo as its cwd (on Windows that blocks
  # deleting the directory).
  if [[ -n "$DAEMON_SLEEP_PID" ]]; then kill "$DAEMON_SLEEP_PID" 2>/dev/null || true; fi
}

daemon_cleanup() {
  # PID file first: it is the one step that must happen. `log` can fail (its
  # stderr may be gone after a SIGHUP), and under errexit that ends the handler.
  # The helper's stderr is dropped for the same reason: its retry notice must
  # not be what kills the handler. A file that survives anyway is recorded in
  # activity.log. The next start/stop sees a dead pid and clears it as stale,
  # unless that pid has been reused by then.
  remove_state_file "$PID_FILE" "daemon PID file" 2>/dev/null \
    || log "WARNING: daemon PID file survived exit (held open); next fleet start/stop clears it as stale" \
    || true
  # The landing marker is deliberately NOT removed here, not even with a bare
  # `rm -f`. Every path out of the loop releases it first, so it is only still
  # present when the daemon exits in the middle of a land, e.g. errexit in
  # rebase_others when `log` loses its stderr. That is exactly when it is
  # evidence: removing it would hide an untested merge or a half-done rebase
  # from the next run's recovery (see the LANDING MARKER banner).
  if [[ -n "$DAEMON_SLEEP_PID" ]]; then kill "$DAEMON_SLEEP_PID" 2>/dev/null || true; fi
  log "daemon stopping (pid $$)" || true
}

cmd_start() {
  ensure_fleet_dir
  refuse_if_shared_tree || exit 1
  # Fail fast rather than starting an unattended daemon that would refuse every
  # lane on every poll — the loudest moment to report an unarmed gate is before
  # anything is running.
  require_test_cmd || exit 1

  # Refuse if a daemon is already running
  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log "ERROR: daemon already running (pid $existing_pid). Run: fleet stop"
      exit 1
    else
      log "stale PID file (pid $existing_pid not alive) — clearing"
      remove_state_file "$PID_FILE" "stale PID file" || exit 1
    fi
  fi

  # A daemon killed mid-land leaves its marker behind. Examine it before
  # anything runs, and refuse to start over a main checkout that needs a human,
  # the way require_test_cmd refuses an unarmed gate. A live land elsewhere
  # (status 2) is no reason not to start: the loop waits for it.
  local rrc=0
  recover_stranded_landing || rrc=$?
  if [[ $rrc -eq 1 ]]; then exit 1; fi

  # Cleanup on EXIT only; the signals merely request a stop (see daemon_cleanup).
  # Installed BEFORE the PID file exists, so no signal can hit the default
  # action and leave a stale PID file behind. SIGINT is untrappable when the
  # daemon runs as a non-interactive background job (bash ignores it there), so
  # TERM and HUP are the ones that matter.
  trap daemon_cleanup EXIT
  trap 'daemon_request_stop SIGTERM' TERM
  trap 'daemon_request_stop SIGINT' INT
  trap 'daemon_request_stop SIGHUP' HUP
  echo "$$" > "$PID_FILE"
  log "daemon start (pid $$, poll: ${POLL_INTERVAL}s, test_cmd: ${TEST_CMD:-<none>})"

  local halt="" waiting_on=""
  while [[ -z "$DAEMON_STOP" ]]; do
    local ready=()
    # Every pass, not just at start: a `fleet land` run beside the daemon can
    # die mid-land too, and the daemon's next land would bless what it left.
    rrc=0
    recover_stranded_landing || rrc=$?
    if [[ $rrc -eq 1 ]]; then
      log "daemon stopping: a land that died left the main checkout needing a human (see above)"
      halt=1
      break
    elif [[ $rrc -eq 2 ]]; then
      # Logged once per holder, not once per poll.
      if [[ "$waiting_on" != "$M_PID" ]]; then log_landing_busy "daemon: waiting"; waiting_on=$M_PID; fi
    else
      waiting_on=""
      for f in "$LANES_DIR"/*; do
        [[ -f "$f" && "$(head -n1 "$f")" == "READY" ]] && ready+=("$(decode_lane "$(basename "$f")")")
      done
    fi

    if [[ ${#ready[@]} -gt 0 ]]; then
      for branch in "${ready[@]}"; do
        # Safe point 1: never START a land once a stop was requested. Checked
        # again AFTER the marker is taken, so a stop request that slips in
        # between finds either no land (second check) or the marker already in
        # place (cmd_stop then waits). No land ever runs unmarked.
        if [[ -n "$DAEMON_STOP" ]]; then break; fi
        # Re-read: a land earlier in this pass may have moved this lane.
        [[ "$(lane_state "$branch")" == "READY" ]] || continue
        # Another fleet process took the marker first: never land beside it.
        # The next pass waits for it, or recovers it if it died.
        claim_landing "$branch" || break
        if [[ -n "$DAEMON_STOP" ]]; then release_landing; break; fi
        if land_one "$branch"; then
          rebase_others "$branch"
        fi
        release_landing
      done
      cmd_fleet
    fi
    if [[ -n "$DAEMON_STOP" ]]; then break; fi

    local active=0
    for f in "$LANES_DIR"/*; do
      [[ -f "$f" ]] || continue
      local s
      s=$(head -n1 "$f")
      [[ "$s" != "LANDED" && "$s" != "FAILED" ]] && active=$((active+1))
    done
    if [[ $active -eq 0 ]]; then
      log "all lanes terminal — daemon exiting"
      cmd_fleet
      break
    fi
    # Safe point 2: an interruptible sleep. A foreground `sleep` defers the trap
    # until it returns — up to poll_interval, which at the default is the whole
    # of `fleet stop`'s 5s grace, so SIGTERM raced the SIGKILL escalation.
    # The flag is re-checked AFTER the sleep is spawned: a signal that arrives
    # before that point finds no sleep to kill, and would otherwise cost a full
    # interval (measured 5.3s — the lane scan above forks per lane, so the
    # window is wide on Windows). One that arrives after it kills the sleep.
    sleep "$POLL_INTERVAL" & DAEMON_SLEEP_PID=$!
    if [[ -z "$DAEMON_STOP" ]]; then wait "$DAEMON_SLEEP_PID" 2>/dev/null || true; fi
    DAEMON_SLEEP_PID=""
  done
  if [[ -n "$halt" ]]; then exit 1; fi
  if [[ -n "$DAEMON_STOP" ]]; then
    log "daemon: $DAEMON_STOP received — stopped between lands, none interrupted"
  fi
}

case "${1:-}" in
  init)         shift; cmd_init "$@" ;;
  track)        shift; cmd_track "$@" ;;
  start)        shift; cmd_start "$@" ;;
  stop)         cmd_stop ;;
  status|fleet) shift; cmd_fleet "$@" ;;
  land)         shift
                if [[ "${1:-}" == "--all" ]]; then shift; cmd_land_all "$@"; else cmd_land "$@"; fi ;;
  revert)       shift; cmd_revert "$@" ;;
  landing)      shift; cmd_landing "$@" ;;
  scrub-check)  shift; cmd_scrub_check "$@" ;;
  prune)        shift; cmd_prune "$@" ;;
  # The post-wave sweep lives in its own script (scripts/sweep.sh) and builds
  # on prune rather than inside it. Back to the caller's dir first: the cd at
  # the top of this file would otherwise make prune's "you are standing in it"
  # guard protect the main checkout instead of the tree the caller is in.
  sweep)        shift; cd "$INVOKED_FROM" 2>/dev/null || true
                exec bash "$SCRIPT_DIR/sweep.sh" "$@" ;;
  config)       shift; cmd_config "$@" ;;
  main)         shift; cmd_main "$@" ;;
  owner)        shift; [[ -z "${1:-}" ]] && { echo "usage: fleet owner <branch>" >&2; exit 1; }
                lane_owner "$1" --fresh ;;
  ""|-h|--help)
    cat <<EOF
fleet-ops — landing discipline for parallel work (queue + test gate)

Usage:
  fleet init <name>...        Create branch + worktree per name (manual spawn)
  fleet track <branch>...     Register existing branches as lanes (native spawn)
  fleet start                 Run the daemon (writes pid to $PID_FILE)
  fleet stop                  Stop the daemon; a land in progress finishes first
  fleet status                One-shot status view
  fleet land <branch>         Manual land + rebase others
  fleet land --all [--running]  Batch-land all READY lanes (oldest-first);
                              --running also lands vetted RUNNING lanes
  fleet revert <branch>       Revert merge commit on $BASE_BRANCH
  fleet landing [--porcelain] Is $BASE_BRANCH safe to branch from / rebase onto?
                              Exit 0 yes; 10 = a land holds it (PROVISIONAL
                              while its gate runs) or it holds an untested merge
  fleet scrub-check <branch>  Dry-run forbidden-pattern check
  fleet prune [--remove]      Classify finished lane worktrees. DRY RUN by
                              default; --remove deletes only the SAFE ones,
                              after a typed confirmation. --all-repos reports
                              sibling repos and can never remove.
  fleet sweep [--apply]       Post-wave housekeeping, in procedure order:
                              landed? competing? leftovers? who is done?
                              Report by default; --apply = zero-loss only.
  fleet config                Print resolved config (is the test gate actually on?)
  fleet main [show|claim|release]
                              The coordinator session for this repo (lands,
                              deploys, triages). Lanes address it to hand off.
  fleet owner <branch>        Which session owns a lane, and is it still live?

Config (optional): $CONFIG  — key=value per line, values need no quoting
EOF
    ;;
  *) echo "unknown subcommand: $1" >&2; exit 1 ;;
esac
