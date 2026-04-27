#!/usr/bin/env bash
# fleet-ops/signal.sh — called by Claude sessions to signal lane status
# Auto-detects the current branch. Refuses dirty trees.
# Resolves .fleet/ via git common dir, so it works from inside worktrees.
set -euo pipefail

GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
[[ -z "$GIT_COMMON_DIR" ]] && { echo "signal.sh ERROR: not in a git repo" >&2; exit 2; }
# git-common-dir is .git/ at main repo root → parent is the main worktree
MAIN_REPO_ROOT=$(cd "$GIT_COMMON_DIR/.." && pwd)
LANES_DIR="$MAIN_REPO_ROOT/.fleet/lanes"
BRANCH=$(git branch --show-current 2>/dev/null || true)

if [[ -z "$BRANCH" ]]; then
  echo "signal.sh ERROR: not on a branch (detached HEAD?)" >&2
  exit 2
fi

if [[ ! -f "$LANES_DIR/$BRANCH" ]]; then
  echo "signal.sh ERROR: branch '$BRANCH' is not a registered lane (run: fleet track $BRANCH)" >&2
  exit 2
fi

STATE=${1:-}
case "$STATE" in
  READY)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "signal.sh REFUSE: '$BRANCH' has uncommitted tracked changes — commit or stash before signaling READY" >&2
      git status --short >&2
      exit 1
    fi
    LOG=${2:-}
    if [[ -n "$LOG" ]]; then
      [[ -f "$LOG" ]] || { echo "signal.sh ERROR: test log '$LOG' not found" >&2; exit 1; }
      # crude pass detection — works for pytest, jest, go test, cargo test, mocha
      if grep -qiE "(failed|error|fail:)" "$LOG" && ! grep -qiE "0 (failed|errors)" "$LOG"; then
        echo "signal.sh REFUSE: test log '$LOG' shows failures" >&2
        grep -iE "(failed|error)" "$LOG" | head -5 >&2
        exit 1
      fi
    fi
    { echo "READY"; [[ -n "$LOG" ]] && echo "log=$LOG"; } > "$LANES_DIR/$BRANCH"
    echo "signal: $BRANCH → READY"
    ;;
  CONFLICT)
    REASON=${2:-"unspecified"}
    { echo "CONFLICT"; echo "reason=$REASON"; } > "$LANES_DIR/$BRANCH"
    echo "signal: $BRANCH → CONFLICT ($REASON)"
    ;;
  RUNNING)
    echo "RUNNING" > "$LANES_DIR/$BRANCH"
    echo "signal: $BRANCH → RUNNING"
    ;;
  *)
    echo "usage: signal.sh READY [test-log]   |   CONFLICT [reason]   |   RUNNING" >&2
    exit 1
    ;;
esac
