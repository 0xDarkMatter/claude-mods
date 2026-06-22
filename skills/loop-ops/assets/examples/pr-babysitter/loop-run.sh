#!/usr/bin/env bash
# loop-run.sh - one tick of the pr-babysitter loop. RUNNER-AGNOSTIC: point any scheduler
# at it. No GitHub Actions required.
#   cron:                 */10 * * * *  /path/.loops/pr-babysitter/loop-run.sh >> tick.log 2>&1
#   Windows Task Scheduler: schtasks /Create /SC MINUTE /MO 10 /TN pr-babysitter \
#                             /TR "bash -lc '/path/.loops/pr-babysitter/loop-run.sh'"
#   by hand:              bash loop-run.sh
# The scheduler is the authorizer; this runs a gated `claude -p` (dontAsk + an allowlist),
# never bypassPermissions on a shared host. (github-actions.yml is one OPTIONAL scheduler.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# 1. Kill switch first.
if [ -f PAUSED ]; then echo "pr-babysitter: paused (PAUSED sentinel) - skipping tick" >&2; exit 0; fi
command -v claude >/dev/null 2>&1 || { echo "pr-babysitter: 'claude' not on PATH" >&2; exit 5; }

# 2. One tick. SAME prompt every time (cache-friendly). Allowlist = exactly what an L1
#    report loop needs: read-only gh + Read + the STATE/run-log writes. No 'gh pr merge'.
claude -p "$(cat run.md)" \
  --permission-mode dontAsk \
  --append-system-prompt "$(cat STATE.md)" \
  --allowedTools 'Bash(gh pr list:*)' 'Bash(gh pr view:*)' 'Bash(gh pr comment:*)' 'Read' 'Write(STATE.md)' 'Write(run-log.md)' \
  --max-turns 30

# 3. Persist STATE + run-log if this dir lives in a git repo.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add STATE.md run-log.md 2>/dev/null || true
  git diff --cached --quiet 2>/dev/null || git commit -q -m "chore(loop): pr-babysitter tick" || true
fi
