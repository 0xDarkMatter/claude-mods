#!/bin/bash
# hooks/worktree-guard.sh
# PreToolUse hook (matcher: Bash) — enforce rules/worktree-boundaries.md.
#
# `.claude/worktrees/` is the private state of whichever agent, session, or
# human spawned it. Worktrees that look orphaned often aren't (active sessions,
# uncommitted work). This hook catches the command shapes that have actually
# caused damage (2026-04-19 incident: `git add -A` staged worktree gitlinks,
# then `rm -rf .claude/worktrees/` deleted live agent state):
#
#   1. rm targeting a path containing .claude/worktrees
#   2. git worktree remove <path containing .claude/worktrees>
#   3. git worktree prune  — when the cwd's repo has a .claude/worktrees dir
#   4. git rm targeting .claude/worktrees paths
#   5. git add -A / --all / .  — when cwd has a .claude/worktrees dir
#
# On (3) and (5) we use directory existence ([ -d cwd/.claude/worktrees ]) as
# the cheap proxy. True gitlink detection would need `git status --porcelain`
# parsing — a subprocess against a possibly-large repo on EVERY Bash call, and
# gitlinks only show once recorded — too slow/unreliable for a hook, so we
# accept slight over-warning (advisory anyway).
#
# Own-worktree exemption: a session whose payload cwd is INSIDE
# .claude/worktrees/<name> is operating in its own worktree and may touch
# itself — it is exempted entirely (tradeoff: such a session is also not
# guarded against touching sibling worktrees; acceptable, the rule targets
# outside sessions doing "cleanup").
#
# Stdin: PreToolUse JSON ({tool_input:{command}, cwd, …}); $1 = command fallback.
#
# Behaviour (silent on clean):
#   no violation             → no output, exit 0
#   violation                → ADVISORY warning naming the rule, exit 0
#   + WORKTREE_GUARD_BLOCK=1 → HARD DENY: stderr + exit 2 (tool call prevented)

set -uo pipefail

CMD="${1:-}"; CWD=""
if [[ -z "$CMD" && ! -t 0 ]]; then
  RAW="$(cat 2>/dev/null)"
  if [[ -n "${RAW:-}" ]] && command -v jq >/dev/null 2>&1; then
    CMD="$(printf '%s' "$RAW" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    CWD="$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null)"
  fi
fi
[[ -z "$CMD" ]] && exit 0
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

# Own-worktree session → exempt (see header).
case "$CWD" in
  *.claude/worktrees/*|*.claude\\worktrees\\*) exit 0 ;;
esac

WT='\.claude[/\\]worktrees'   # matches forward or back slashes
VIOLATION=""

if   printf '%s' "$CMD" | grep -qE "\bgit\b.*\bworktree[[:space:]]+remove\b[^;|&]*$WT"; then
  VIOLATION="git worktree remove on .claude/worktrees"
elif printf '%s' "$CMD" | grep -qE "\bgit\b.*\bworktree[[:space:]]+prune\b" \
     && [[ -d "$CWD/.claude/worktrees" ]]; then
  VIOLATION="git worktree prune in a repo with .claude/worktrees"
elif printf '%s' "$CMD" | grep -qE "\bgit\b[^;|&]*\brm\b[^;|&]*$WT"; then
  VIOLATION="git rm on .claude/worktrees paths"
elif printf '%s' "$CMD" | grep -qE "\brm\b[^;|&]*$WT"; then
  VIOLATION="rm targeting .claude/worktrees"
elif printf '%s' "$CMD" | grep -qE '\bgit\b.*\badd[[:space:]]+([^;|&]*[[:space:]])?(-A|--all|\.)([[:space:]]|$|;)' \
     && [[ -d "$CWD/.claude/worktrees" ]]; then
  VIOLATION="git add -A/. in a repo with .claude/worktrees (may stage worktree gitlinks)"
fi

[[ -z "$VIOLATION" ]] && exit 0   # clean → silent

if [[ "${WORKTREE_GUARD_BLOCK:-0}" == "1" ]]; then
  {
    echo "WORKTREE GUARD: blocked — $VIOLATION."
    echo "rules/worktree-boundaries.md: worktrees are another session's private state."
    echo "Use explicit file paths with git add; never delete .claude/worktrees without"
    echo "asking the user. Unset WORKTREE_GUARD_BLOCK only after they confirm."
  } >&2
  exit 2
fi

echo "WORKTREE GUARD: $VIOLATION."
echo "rules/worktree-boundaries.md: .claude/worktrees/ is another session's private"
echo "state — it may look orphaned and isn't. Use explicit paths with git add; ask"
echo "the user before removing any worktree. (WORKTREE_GUARD_BLOCK=1 to hard-deny.)"
exit 0
