#!/usr/bin/env bash
# fleet-ops — landing queue manager for concurrent Claude sessions
# Status: experimental
set -euo pipefail

FLEET_DIR=".fleet"
LANES_DIR="$FLEET_DIR/lanes"
LOG="$FLEET_DIR/activity.log"
CONFIG="$FLEET_DIR/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# defaults (overridable via .fleet/config: key=value, no quotes)
MODE="auto"
WORKTREE_ROOT=".fleet/worktrees"
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
  # Auto-ignore .fleet/ in git so it doesn't show as "dirty" or get committed
  if [[ -d .git ]] || git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ ! -f .gitignore ]] || ! grep -qxF '.fleet/' .gitignore 2>/dev/null; then
      echo '.fleet/' >> .gitignore
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

cmd_fleet() {
  ensure_fleet_dir
  echo ""
  echo "── Fleet ──────────────────────────────────────────────────────"
  printf "  %-2s  %-32s %-10s %s\n" "" "BRANCH" "STATUS" "AGE"
  echo "────────────────────────────────────────────────────────────────"
  local any=0 now=$(date +%s)
  for f in "$LANES_DIR"/*; do
    [[ -f "$f" ]] || continue
    any=1
    local branch state mtime secs age icon
    branch=$(basename "$f")
    state=$(head -n1 "$f")
    mtime=$(file_mtime "$f")
    secs=$((now - mtime))
    if   [[ $secs -lt 60   ]]; then age="${secs}s"
    elif [[ $secs -lt 3600 ]]; then age="$((secs/60))m"
    else age="$((secs/3600))h$(( (secs%3600)/60 ))m"
    fi
    case $state in
      RUNNING)  icon="$ICON_RUNNING" ;;
      READY)    icon="$ICON_READY" ;;
      LANDED)   icon="$ICON_LANDED" ;;
      FAILED)   icon="$ICON_FAILED" ;;
      CONFLICT) icon="$ICON_CONFLICT" ;;
      *)        icon="$ICON_UNKNOWN" ;;
    esac
    printf "  %s  %-32s %-10s %s\n" "$icon" "$branch" "$state" "$age"
  done
  [[ $any -eq 0 ]] && echo "  (no lanes — run: fleet init <name>...)"
  echo "────────────────────────────────────────────────────────────────"
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

cmd_start() {
  ensure_fleet_dir
  refuse_if_shared_tree || exit 1
  log "daemon start (poll: ${POLL_INTERVAL}s, test_cmd: ${TEST_CMD:-<none>})"

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
  fleet|status) cmd_fleet ;;
  land)         shift; cmd_land "$@" ;;
  revert)       shift; cmd_revert "$@" ;;
  scrub-check)  shift; cmd_scrub_check "$@" ;;
  ""|-h|--help)
    cat <<EOF
fleet-ops — landing queue for concurrent Claude sessions (experimental)

Usage:
  fleet init <name>...        Create branch + worktree per name
  fleet start                 Run the daemon (Ctrl-C to stop)
  fleet fleet                 One-shot status view
  fleet land <branch>         Manual land + rebase others
  fleet revert <branch>       Revert merge commit on $BASE_BRANCH
  fleet scrub-check <branch>  Dry-run forbidden-pattern check

Config (optional): $CONFIG
EOF
    ;;
  *) echo "unknown subcommand: $1" >&2; exit 1 ;;
esac
