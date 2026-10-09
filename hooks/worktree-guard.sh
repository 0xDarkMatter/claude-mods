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
#   6. git clean -ff (double-force) — when cwd has a .claude/worktrees dir.
#      Single `-f` git clean SKIPS nested worktrees ("Skipping repository …");
#      only a DOUBLE force (`-ff` / `--force --force`) deletes them — taking any
#      UNCOMMITTED lane work with it (committed work survives in the object store).
#
# On (3) and (5) we use directory existence ([ -d cwd/.claude/worktrees ]) as
# the cheap proxy. True gitlink detection would need `git status --porcelain`
# parsing — a subprocess against a possibly-large repo on EVERY Bash call, and
# gitlinks only show once recorded — too slow/unreliable for a hook, so we
# accept slight over-warning (advisory anyway).
#
# Machine-wide lane root: when WORKTREE_ROOT is set, lanes live at
# $WORKTREE_ROOT/<repo>/<slug> (rules/worktree-boundaries.md "Lane location") and
# are guarded exactly like .claude/worktrees/: (1), (2) and (4) also match a path
# under the root (spelled with either slash, or as the literal $WORKTREE_ROOT),
# and (3) also fires when $WORKTREE_ROOT/<repo> exists. (5) and (6) do NOT
# extend to it: `git add -A` and `git clean` act inside the repo, and a lane
# outside it is structurally out of their reach — that is the point of the root.
#
# Own-worktree exemption: a session whose payload cwd is INSIDE
# .claude/worktrees/<name> or $WORKTREE_ROOT/ is operating in its own worktree
# and may touch itself — it is exempted entirely (tradeoff: such a session is
# also not guarded against touching sibling worktrees; acceptable, the rule
# targets outside sessions doing "cleanup").
#
# Stdin: PreToolUse JSON ({tool_input:{command}, cwd, …}); $1 = command fallback.
#
# Behaviour (silent on clean):
#   no violation             → no output, exit 0
#   violation                → ADVISORY: one additionalContext JSON envelope on
#                              stdout naming the rule, exit 0
#   + WORKTREE_GUARD_BLOCK=1 → HARD DENY: stderr + exit 2 (tool call prevented)
# Channel contract tests: tests/hooks.sh

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
EXT_ROOT=""   # WORKTREE_ROOT, forward slashes, no trailing slash
EXT_FORMS=()  # every spelling of it a command or cwd may use
if [[ -n "${WORKTREE_ROOT:-}" ]]; then
  EXT_ROOT="${WORKTREE_ROOT//\\//}"; EXT_ROOT="${EXT_ROOT%/}"
  EXT_FORMS=("$EXT_ROOT")
  # Windows: one directory, two strings (X:/w and /x/w). Claude Code sends the
  # first, a Git Bash command may say the second; compare in every form or the
  # guard silently matches nothing.
  if command -v cygpath >/dev/null 2>&1; then
    for f in "$(cygpath -m "$EXT_ROOT" 2>/dev/null)" "$(cygpath -u "$EXT_ROOT" 2>/dev/null)"; do
      [[ -n "$f" && "$f" != "$EXT_ROOT" ]] && EXT_FORMS+=("${f%/}")
    done
  fi
  lc() { local p=${1//\\//}; printf '%s' "$p" | tr '[:upper:]' '[:lower:]'; }
  for f in "${EXT_FORMS[@]}"; do
    case "$(lc "$CWD")/" in "$(lc "$f")"/?*) exit 0 ;; esac
  done
fi

WT='\.claude[/\\]worktrees'   # matches forward or back slashes
WHERE=".claude/worktrees"
GI=""
if [[ -n "$EXT_ROOT" ]]; then
  # The root as an ERE: metacharacters escaped, each '/' matching either slash;
  # or the variable itself, as a command usually spells it.
  ext_re=""
  for f in "${EXT_FORMS[@]}"; do
    ext_re="$ext_re|$(printf '%s' "$f" | sed -e 's/[][\.*^$+?(){}|]/\\&/g' -e 's#/#[/\\\\]#g')"
  done
  WT="($WT$ext_re|\\\$\\{?WORKTREE_ROOT\\}?)"
  WHERE=".claude/worktrees or \$WORKTREE_ROOT"
  GI="-i"   # Windows paths are case-insensitive, and the drive letter's case varies
fi
# Does $WORKTREE_ROOT/<repo> hold anything for the cwd's repo? <repo> is the MAIN
# checkout's dir name. Costs one git call, so only the prune branch asks.
ext_lanes_exist() {
  [[ -n "$EXT_ROOT" ]] || return 1
  local common
  common=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ -n "$(ls -A "$EXT_ROOT/$(basename "$(dirname "$common")")" 2>/dev/null)" ]]
}
VIOLATION=""

if   printf '%s' "$CMD" | grep -q${GI:+i}E "\bgit\b.*\bworktree[[:space:]]+remove\b[^;|&]*$WT"; then
  VIOLATION="git worktree remove on $WHERE"
elif printf '%s' "$CMD" | grep -qE "\bgit\b.*\bworktree[[:space:]]+prune\b" \
     && { [[ -d "$CWD/.claude/worktrees" ]] || ext_lanes_exist; }; then
  VIOLATION="git worktree prune in a repo with $WHERE"
elif printf '%s' "$CMD" | grep -q${GI:+i}E "\bgit\b[^;|&]*\brm\b[^;|&]*$WT"; then
  VIOLATION="git rm on $WHERE paths"
elif printf '%s' "$CMD" | grep -q${GI:+i}E "\brm\b[^;|&]*$WT"; then
  VIOLATION="rm targeting $WHERE"
elif printf '%s' "$CMD" | grep -qE '\bgit\b.*\badd[[:space:]]+([^;|&]*[[:space:]])?(-A|--all|\.)([[:space:]]|$|;)' \
     && [[ -d "$CWD/.claude/worktrees" ]]; then
  VIOLATION="git add -A/. in a repo with .claude/worktrees (may stage worktree gitlinks)"
elif printf '%s' "$CMD" | grep -qE '\bgit\b[^;|&]*\bclean\b' \
     && [[ -d "$CWD/.claude/worktrees" ]]; then
  # git deletes a NESTED worktree only at force level >= 2 (a single -f safely
  # "Skipping repository …"). Force level = count of --force PLUS the count of
  # 'f' chars inside short bundles, so -ff, -f -f, -fd -fx and --force --force
  # all read as 2, while a safe -fdx reads as 1. Bound to the clean invocation.
  SEG=$(printf '%s' "$CMD" | grep -oE '\bclean\b[^;|&]*' | head -1)
  # NB: count OCCURRENCES (grep -o | wc -l), not matching lines (grep -c counts
  # lines, so two --force on one line would wrongly read as 1).
  NLONG=$(printf '%s' "$SEG" | grep -oE -- '--force' | wc -l | tr -d ' ')
  NSHORT=$(printf '%s' "$SEG" | grep -oE -- '(^|[[:space:]])-[A-Za-z]+' | grep -v -- '--' | tr -cd 'fF' | wc -c | tr -d ' ')
  if [[ $(( ${NLONG:-0} + ${NSHORT:-0} )) -ge 2 ]]; then
    VIOLATION="git clean double-force in a repo with .claude/worktrees (force-removes live lanes + their uncommitted work)"
  fi
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

MSG="WORKTREE GUARD: $VIOLATION.
rules/worktree-boundaries.md: .claude/worktrees/ is another session's private
state — it may look orphaned and isn't. Use explicit paths with git add; ask
the user before removing any worktree. (WORKTREE_GUARD_BLOCK=1 to hard-deny.)"

# Guard: do not "simplify" this back to plain echo. For PreToolUse, plain stdout
# on exit 0 goes to the debug log and never reaches the model ("Exit code 0" in
# https://code.claude.com/docs/en/hooks); the echo-only original warned nobody.
# The block path above is already right: exit 2 feeds STDERR to the model.
# Nothing else may write to stdout, or the JSON stops parsing.
command -v jq >/dev/null 2>&1 || exit 0   # no jq, no envelope - stay silent
jq -nc --arg c "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
