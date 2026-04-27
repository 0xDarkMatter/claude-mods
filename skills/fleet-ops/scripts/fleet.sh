#!/usr/bin/env bash
# fleet-ops — landing queue manager for concurrent Claude sessions
# Status: experimental
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""

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

# defaults (overridable via .claude/fleet/config: key=value, no quotes)
MODE="auto"
WORKTREE_ROOT=".claude/fleet/worktrees"
TEST_CMD=""
FORBIDDEN_PATTERN="TODO_SCRUB|XXX[^a-z]|FIXME_BEFORE_LAND"
BASE_BRANCH="main"
POLL_INTERVAL=5
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null || true

# OS-aware icon set: Unicode by default, ASCII fallback for legacy terminals
# Override: FLEET_ASCII=1 or .fleet/config has icons=ascii
if [[ "${FLEET_ASCII:-}" == "1" ]] || [[ "${icons:-}" == "ascii" ]]; then
  ICON_RUNNING="[.]"; ICON_READY="[+]"; ICON_LANDED="[*]"
  ICON_FAILED="[X]";  ICON_CONFLICT="[!]"; ICON_UNKNOWN="[?]"
else
  ICON_RUNNING="⏳";  ICON_READY="✅";  ICON_LANDED="🚀"
  ICON_FAILED="❌";   ICON_CONFLICT="⚠️ "; ICON_UNKNOWN="? "
fi

# Cross-platform mtime: GNU stat (Linux/Git Bash) vs BSD stat (macOS)
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }

ensure_fleet_dir() {
  mkdir -p "$LANES_DIR"
  [[ -f "$FLEET_DIR/signal.sh" ]] || cp "$SCRIPT_DIR/signal.sh" "$FLEET_DIR/signal.sh"
  chmod +x "$FLEET_DIR/signal.sh" 2>/dev/null || true
  # Auto-ignore .claude/fleet/ in git so it doesn't show as "dirty" or get committed
  if [[ -d .git ]] || git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ ! -f .gitignore ]] || ! grep -qxF '.claude/fleet/' .gitignore 2>/dev/null; then
      echo '.claude/fleet/' >> .gitignore
    fi
  fi
}

is_dirty_tracked() {
  # True only if tracked files have uncommitted changes (ignores untracked files)
  ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null
}

lane_state() { [[ -f "$LANES_DIR/$1" ]] && head -n1 "$LANES_DIR/$1" || echo "MISSING"; }
set_lane_state() {
  local l=$1 s=$2
  shift 2
  if [[ $# -gt 0 ]]; then
    printf '%s\n%s\n' "$s" "$*" > "$LANES_DIR/$l"
  else
    printf '%s\n' "$s" > "$LANES_DIR/$l"
  fi
}

scrub_diff() {
  # echoes hits (one per line) for given branch's diff vs base. Empty = clean.
  local branch=$1
  git diff "$BASE_BRANCH"..."$branch" 2>/dev/null | grep -nE "$FORBIDDEN_PATTERN" || true
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

format_age() {
  local secs=$1
  if   [[ $secs -lt 60   ]]; then printf "%ds" "$secs"
  elif [[ $secs -lt 3600 ]]; then printf "%dm" "$((secs/60))"
  else printf "%dh%dm" "$((secs/3600))" "$(( (secs%3600)/60 ))"
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

# Grouped-by-status view (default). Compact, scales to many lanes.
fleet_view_grouped() {
  local now=$(date +%s)
  local total=0 active=0
  declare -A buckets counts
  for state in RUNNING READY CONFLICT FAILED LANDED; do
    buckets[$state]=""
    counts[$state]=0
  done

  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    total=$((total+1))
    local branch state mtime secs age meta
    branch=$(basename "$f")
    state=$(head -n1 "$f")
    meta=$(sed -n '2p' "$f")
    mtime=$(file_mtime "$f")
    secs=$((now - mtime))
    age=$(format_age "$secs")
    [[ "$state" != "LANDED" && "$state" != "FAILED" ]] && active=$((active+1))
    counts[$state]=$(( ${counts[$state]:-0} + 1 ))
    buckets[$state]="${buckets[$state]}${branch}|${age}|${meta}"$'\n'
  done

  echo ""
  echo "── fleet ─────────────────────────────────────────────  ${REPO_LABEL:-$(pwd)}"
  if [[ $total -eq 0 ]]; then
    echo ""
    echo "  (no lanes — run: fleet init <name>...)"
    echo ""
    return
  fi
  echo ""

  for state in RUNNING READY CONFLICT FAILED LANDED; do
    local n=${counts[$state]:-0}
    [[ $n -eq 0 ]] && continue
    local icon
    icon=$(icon_for_state "$state")
    printf "  %s %-9s (%d)\n" "$icon" "$state" "$n"
    local last_idx=$((n - 1)) idx=0
    while IFS='|' read -r branch age meta; do
      [[ -z "$branch" ]] && continue
      local connector="├─"
      [[ $idx -eq $last_idx ]] && connector="└─"
      if [[ -n "$meta" ]]; then
        printf "    %s %-32s %5s   %s\n" "$connector" "$branch" "$age" "$meta"
      else
        printf "    %s %-32s %5s\n" "$connector" "$branch" "$age"
      fi
      idx=$((idx+1))
    done <<< "${buckets[$state]}"
    echo ""
  done

  local daemon_status="not running"
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      daemon_status="running (pid $pid)"
    else
      daemon_status="stale pid file"
    fi
  fi
  echo "──────────────────────────────────────────────────────────────────"
  printf "  total: %d  active: %d  daemon: %s  base: %s\n" "$total" "$active" "$daemon_status" "$BASE_BRANCH"
  echo ""
}

# Verbose per-lane view (--verbose). Best for investigating one lane.
fleet_view_verbose() {
  local now=$(date +%s)
  local total=0
  for f in "$LANES_DIR"/*; do [[ -f "$f" ]] && total=$((total+1)); done

  echo ""
  echo "── fleet (verbose) ───────────────────────────────────  ${REPO_LABEL:-$(pwd)}"
  if [[ $total -eq 0 ]]; then
    echo ""
    echo "  (no lanes — run: fleet init <name>...)"
    echo ""
    return
  fi

  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    local branch state meta mtime age secs icon wt commits
    branch=$(basename "$f")
    state=$(head -n1 "$f")
    meta=$(sed -n '2p' "$f")
    mtime=$(file_mtime "$f")
    secs=$((now - mtime))
    age=$(format_age "$secs")
    icon=$(icon_for_state "$state")
    wt=$(worktree_path_for "$branch" 2>/dev/null || echo "")
    commits=$(git rev-list --count "$BASE_BRANCH..$branch" 2>/dev/null || echo "?")

    echo ""
    printf "  %s %-32s [%s]  %s ago\n" "$icon" "$branch" "$state" "$age"
    local details=()
    if [[ -n "$wt" ]]; then
      local wt_short="$wt" repo_root="${REPO_ROOT:-}"
      [[ -n "$repo_root" ]] && wt_short="${wt#$repo_root/}"
      if [[ "$wt_short" == "$wt" && -n "$repo_root" ]]; then
        local repo_native
        repo_native=$(cygpath -m "$repo_root" 2>/dev/null || echo "$repo_root")
        wt_short="${wt#$repo_native/}"
      fi
      details+=("worktree:  $wt_short")
    fi
    [[ "$commits" != "?" && "$commits" != "0" ]] && details+=("commits:   $commits ahead of $BASE_BRANCH")
    [[ -n "$meta" ]] && details+=("note:      $meta")
    local n_details=${#details[@]} i
    for ((i=0; i<n_details; i++)); do
      local connector="├─"
      [[ $i -eq $((n_details - 1)) ]] && connector="└─"
      printf "     %s %s\n" "$connector" "${details[$i]}"
    done
  done
  echo ""
}

cmd_fleet() {
  ensure_fleet_dir
  REPO_LABEL="${REPO_ROOT:-$(pwd)}"
  REPO_LABEL="${REPO_LABEL/$HOME/~}"

  local mode="grouped"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) mode="verbose"; shift ;;
      -g|--grouped) mode="grouped"; shift ;;
      *)            shift ;;
    esac
  done
  case "$mode" in
    verbose) fleet_view_verbose ;;
    *)       fleet_view_grouped ;;
  esac
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

land_one() {
  local branch=$1
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
      log "running tests: $TEST_CMD"
      if eval "$TEST_CMD" >>"$LOG" 2>&1; then
        log "PASS: $branch landed ✓"
      else
        log "FAIL: tests failed — reverting $branch"
        git reset --hard HEAD^
        set_lane_state "$branch" "FAILED" "tests failed post-merge"
        return 1
      fi
    else
      log "no test_cmd set — trusting signal.sh's log gate"
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
    b=$(basename "$f")
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
      [[ -f "$f" && "$(head -n1 "$f")" == "READY" ]] && ready+=("$(basename "$f")")
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
  start)        shift; cmd_start "$@" ;;
  stop)         cmd_stop ;;
  fleet|status) shift; cmd_fleet "$@" ;;
  land)         shift; cmd_land "$@" ;;
  revert)       shift; cmd_revert "$@" ;;
  scrub-check)  shift; cmd_scrub_check "$@" ;;
  ""|-h|--help)
    cat <<EOF
fleet-ops — landing queue for concurrent Claude sessions (experimental)

Usage:
  fleet init <name>...        Create branch + worktree per name
  fleet start                 Run the daemon (writes pid to $PID_FILE)
  fleet stop                  Signal the running daemon to exit cleanly
  fleet fleet                 One-shot status view
  fleet land <branch>         Manual land + rebase others
  fleet revert <branch>       Revert merge commit on $BASE_BRANCH
  fleet scrub-check <branch>  Dry-run forbidden-pattern check

Config (optional): $CONFIG
EOF
    ;;
  *) echo "unknown subcommand: $1" >&2; exit 1 ;;
esac
