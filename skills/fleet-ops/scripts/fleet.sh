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
# `git worktree list` yields "X:/Forge/repo"; string-comparing those two never
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

# defaults (overridable via .claude/fleet/config — see load_config below)
MODE="auto"
# Default worktree root sits at repo top, NOT under .claude/. Claude Code's
# headless mode (--dangerously-skip-permissions) bypasses prompts but still
# enforces the global .claude/ sensitive-file guard, so worktrees nested
# under .claude/ can't be written to by lane sessions. See SKILL.md
# "Headless agent compatibility".
WORKTREE_ROOT=".fleet-worktrees"
TEST_CMD=""
FORBIDDEN_PATTERN="TODO_SCRUB|XXX[^a-z]|FIXME_BEFORE_LAND"
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
  #   .claude/fleet/      — lanes/, daemon.pid, activity.log, signal.sh, config
  #   .fleet-worktrees/   — default worktree root (top-level so headless
  #                         Claude lane sessions can write there)
  if git rev-parse --git-dir >/dev/null 2>&1; then
    [[ -f .gitignore ]] || touch .gitignore
    local appended=0
    if ! grep -qxF '.claude/fleet/' .gitignore 2>/dev/null; then
      echo '.claude/fleet/' >> .gitignore
      appended=1
    fi
    if ! grep -qxF '.fleet-worktrees/' .gitignore 2>/dev/null; then
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
      if [[ -f "$pin" ]]; then rm -f "$pin"; echo "MAIN pin cleared" >&2
      else echo "no MAIN pin to clear" >&2; fi
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
    else
      echo "# session awareness: ON but no sessions resolved — store missing, jq missing, or terminal-only host" >&2
    fi
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
load_session_index() {
  session_enabled || return 0
  [[ $SESSION_INDEX_LOADED -eq 1 ]] && return 0
  SESSION_INDEX_LOADED=1
  local rc=0
  SESSION_INDEX_CACHE=$(FLEET_SESSION_LIVE_SECS="$SESSION_LIVE_SECS" \
    bash "$SESSIONS_SH" index 2>/dev/null) || rc=$?
  [[ $rc -eq 0 ]] && SESSION_STORE_OK=1
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

# The gate itself. Refuses to land a lane whose owning session is still live —
# landing under a session that is mid-turn means merging a branch it may still
# be committing to, and then rebasing its worktree out from under it.
# Returns 0 = safe to land, 1 = refuse.
session_land_gate() {
  local branch=$1
  session_enabled || return 0
  local row; row=$(lane_owner "$branch" --fresh)
  [[ -z "$row" ]] && return 0            # unknown owner → no opinion → allow
  local live; live=$(sfield "$row" 7)
  [[ "$live" != "1" ]] && return 0       # idle → allow
  local title; title=$(sfield "$row" 3)
  local id;    id=$(sfield "$row" 2)
  log "REFUSE LAND: $branch is owned by a LIVE session — '$title' ($id)"
  log "  that session was active within ${SESSION_LIVE_SECS}s and may still be committing."
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
#   2  owning session is LIVE                     KEEP    someone is writing here
#   3  session store unreadable, or awareness     REVIEW  no evidence of anything
#      switched off                                       => nothing can be SAFE
#   4  detached HEAD                              REVIEW  no branch to attribute
#   5  uncommitted or untracked changes           REVIEW  removal would destroy them
#   6  commits not yet in <base>                  REVIEW  unintegrated work
#   7  merged + clean + owner archived or absent  SAFE    finished and recoverable
#   8  anything else                              REVIEW  default deny
#
# Rule 6 deliberately folds together two readings that cannot both apply to one
# row — "unmerged commits => KEEP" and "unmerged with no live owner => REVIEW".
# Neither is ever removed, so the choice is purely about which bucket the
# operator is asked to look at, and an abandoned unmerged lane is exactly the
# backlog this command exists to surface. KEEP is therefore reserved for one
# meaning only: hands off, not yours to judge.

PRUNE_ROWS=""   # accumulated TSV: path \t branch \t bucket \t reason

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

  # 2 — a live owner outranks every other consideration
  local orow="" olive="0" oarch="0" otitle=""
  if [[ -n "$br" && $SESSION_STORE_OK -eq 1 ]]; then
    orow=$(owner_row_cached "$br")
    if [[ -n "$orow" ]]; then
      olive=$(sfield "$orow" 7); oarch=$(sfield "$orow" 6); otitle=$(sfield "$orow" 3)
    fi
  fi
  if [[ "$olive" == "1" ]]; then
    prune_row "$wt" "$br" KEEP "live session: ${otitle:-?}"; return 0
  fi

  # 3 — no session evidence at all. "The store says nobody owns this" is
  #     evidence of abandonment; "the store could not be read" is not, and an
  #     empty index looks identical to both. Degrade, never guess.
  if [[ $SESSION_STORE_OK -ne 1 ]]; then
    prune_row "$wt" "${br:-<detached>}" REVIEW "no session info - cannot prove abandoned"; return 0
  fi

  # 4 — detached HEAD: no branch, so nothing to attribute an owner to
  if [[ $det -eq 1 || -z "$br" ]]; then
    prune_row "$wt" "<detached>" REVIEW "detached HEAD - no branch to attribute"; return 0
  fi

  local is_merged=0
  if printf '%s\n' "$merged_list" | grep -qxF -- "$br"; then is_merged=1; fi

  # 5 — uncommitted or untracked work: the only bytes git cannot give back
  local dirty
  dirty=$(prune_dirty_count "$wt")
  if [[ "${dirty:-0}" -gt 0 ]]; then
    local mstate="unmerged"
    [[ $is_merged -eq 1 ]] && mstate="merged"
    prune_row "$wt" "$br" REVIEW "$mstate but DIRTY - $dirty uncommitted/untracked"; return 0
  fi

  # 6 — committed but not yet in base
  local ahead
  ahead=$(git -C "$repo" rev-list --count "$base..$br" 2>/dev/null || echo 0)
  if [[ $is_merged -ne 1 || "${ahead:-0}" != "0" ]]; then
    local who="no owner in store"
    if [[ -n "$orow" ]]; then
      if [[ "$oarch" == "1" ]]; then who="owner archived"; else who="owner idle"; fi
    fi
    prune_row "$wt" "$br" REVIEW "unmerged - ${ahead:-?} ahead of $base ($who)"; return 0
  fi

  # 7 — merged, clean, and nobody is coming back for it
  if [[ -z "$orow" ]]; then
    prune_row "$wt" "$br" SAFE "merged + clean, no session owns it"; return 0
  fi
  if [[ "$oarch" == "1" ]]; then
    prune_row "$wt" "$br" SAFE "merged + clean, owner archived"; return 0
  fi

  # 8 — default deny. Merged and clean, but a non-archived session still owns
  #     the branch: idle now, and free to wake up. Not ours to remove.
  prune_row "$wt" "$br" REVIEW "merged + clean, but owner still open: ${otitle:-?}"
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
  local p br bucket reason rows fresh dirty
  rows=$(printf '%s' "$PRUNE_ROWS" | awk -F'\t' 'NF && $3=="SAFE"')
  while IFS=$'\t' read -r p br bucket reason; do
    [[ -z "$p" ]] && continue

    # Re-verify immediately before deleting. Classification read a session index
    # with a long TTL (15 min); a session can wake between the table and the delete, and
    # this is the one operation where being one poll behind destroys data.
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
    # ';'-separated, NOT ':' — a Windows root is "X:/Forge" and would split.
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
  REVIEW  reported, never removed: dirty, unmerged, detached, or no session
          info at all. Your call.
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

land_one() {
  local branch=$1
  if [[ -z "${FLEET_SKIP_SESSION_CHECK:-}" ]]; then
    session_land_gate "$branch" || { set_lane_state "$branch" "CONFLICT" "owning session still live"; return 1; }
  fi
  local hits
  hits=$(scrub_diff "$branch")
  if [[ -n "$hits" ]]; then
    log "REFUSE LAND: $branch failed scrub-check"
    echo "$hits" | head -10 | tee -a "$LOG"
    set_lane_state "$branch" "CONFLICT" "scrub-check failed"
    return 1
  fi
  if is_dirty_tracked; then
    log "REFUSE LAND: $BASE_BRANCH has uncommitted tracked changes — clean before landing"
    return 1
  fi

  log "LANDING: $branch"
  git checkout "$BASE_BRANCH"
  if git merge "$branch" --no-ff -m "merge: $branch"; then
    if [[ -n "$TEST_CMD" ]]; then
      log "running test_cmd: $TEST_CMD"
      if eval "$TEST_CMD" >>"$LOG" 2>&1; then
        log "PASS: $branch landed"
      else
        log "FAIL: tests failed — reverting $branch"
        git reset --hard HEAD^
        set_lane_state "$branch" "FAILED" "tests failed post-merge"
        return 1
      fi
    else
      log "no test_cmd set in $CONFIG — trusting signal.sh's log gate"
    fi
    set_lane_state "$branch" "LANDED"
    git branch -d "$branch" 2>/dev/null || git branch -D "$branch" 2>/dev/null || true
    return 0
  else
    log "MERGE CONFLICT: $branch"
    git merge --abort 2>/dev/null || true
    set_lane_state "$branch" "CONFLICT" "merge conflict with $BASE_BRANCH"
    return 1
  fi
}

worktree_path_for() {
  # Echo the worktree path for branch $1, or empty if branch isn't in a worktree
  local branch=$1
  git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$branch" '
    /^worktree /{p=$2}
    /^branch /{ if ($2==want) print p }
  '
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
  local branch=${1:-}
  [[ -z "$branch" ]] && { echo "usage: fleet land <branch>" >&2; exit 1; }
  land_one "$branch" && rebase_others "$branch"
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

  local landed=0 conflict=0 failed=0
  while IFS=$'\t' read -r ts b; do
    [[ -z "$b" ]] && continue
    if land_one "$b"; then
      rebase_others "$b"
      landed=$((landed+1))
    else
      case "$(lane_state "$b")" in
        CONFLICT) conflict=$((conflict+1)) ;;
        *)        failed=$((failed+1)) ;;
      esac
    fi
  done <<< "$ordered"

  log "land --all: $landed landed, $conflict conflict, $failed failed"
  cmd_fleet
  # Non-zero exit when anything didn't land, so orchestrators can branch on it.
  [[ $((conflict + failed)) -eq 0 ]]
}

cmd_stop() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "no daemon running (no $PID_FILE)" >&2
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if ! kill -0 "$pid" 2>/dev/null; then
    log "stale PID file (pid $pid not alive) — clearing"
    rm -f "$PID_FILE"
    return 0
  fi
  log "sending SIGTERM to daemon (pid $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  # Wait up to 5s for graceful exit
  local i
  for i in 1 2 3 4 5; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || { log "daemon stopped"; return 0; }
  done
  log "daemon didn't exit on SIGTERM, sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
}

cmd_revert() {
  local branch=${1:-}
  [[ -z "$branch" ]] && { echo "usage: fleet revert <branch>" >&2; exit 1; }
  local sha
  sha=$(git log "$BASE_BRANCH" --merges --grep="merge: $branch" -n1 --format=%H)
  [[ -z "$sha" ]] && { log "ERROR: no merge commit found for $branch on $BASE_BRANCH"; exit 1; }
  log "reverting merge $sha (was: $branch)"
  git checkout "$BASE_BRANCH"
  git revert -m 1 "$sha" --no-edit
  log "reverted: $branch"
}

daemon_cleanup() {
  log "daemon stopping (pid $$)"
  rm -f "$PID_FILE"
}

cmd_start() {
  ensure_fleet_dir
  refuse_if_shared_tree || exit 1

  # Refuse if a daemon is already running
  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log "ERROR: daemon already running (pid $existing_pid). Run: fleet stop"
      exit 1
    else
      log "stale PID file (pid $existing_pid not alive) — clearing"
      rm -f "$PID_FILE"
    fi
  fi

  echo "$$" > "$PID_FILE"
  trap daemon_cleanup EXIT INT TERM HUP
  log "daemon start (pid $$, poll: ${POLL_INTERVAL}s, test_cmd: ${TEST_CMD:-<none>})"

  while true; do
    local ready=()
    for f in "$LANES_DIR"/*; do
      [[ -f "$f" && "$(head -n1 "$f")" == "READY" ]] && ready+=("$(decode_lane "$(basename "$f")")")
    done

    if [[ ${#ready[@]} -gt 0 ]]; then
      for branch in "${ready[@]}"; do
        if land_one "$branch"; then
          rebase_others "$branch"
        fi
      done
      cmd_fleet
    fi

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
    sleep "$POLL_INTERVAL"
  done
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
  scrub-check)  shift; cmd_scrub_check "$@" ;;
  prune)        shift; cmd_prune "$@" ;;
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
  fleet stop                  Signal the running daemon to exit cleanly
  fleet status                One-shot status view
  fleet land <branch>         Manual land + rebase others
  fleet land --all [--running]  Batch-land all READY lanes (oldest-first);
                              --running also lands vetted RUNNING lanes
  fleet revert <branch>       Revert merge commit on $BASE_BRANCH
  fleet scrub-check <branch>  Dry-run forbidden-pattern check
  fleet prune [--remove]      Classify finished lane worktrees. DRY RUN by
                              default; --remove deletes only the SAFE ones,
                              after a typed confirmation. --all-repos reports
                              sibling repos and can never remove.
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
