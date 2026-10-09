#!/bin/bash
# hooks/worktree-remove.sh
# WorktreeRemove hook — clean up a worktree hooks/worktree-create.sh made, without
# ever destroying work. Rule: rules/worktree-boundaries.md.
#
# EVENT CONTRACT (https://code.claude.com/docs/en/hooks#worktreeremove, checked
# 2026-10-09):
#   fires   when Claude Code removes a worktree a WorktreeCreate hook created:
#           exiting a --worktree session and choosing remove, exiting an unnamed
#           session it found clean, or deleting a background session.
#   stdin   JSON: the common fields plus `worktree_path`, the path the create
#           hook returned.
#   exit    0 = counts as removed (Claude Code reads nothing else). Non-zero =
#           removal FAILS while the directory still exists, and the worktree
#           stays on disk with no git fallback — which is exactly how a dirty
#           tree is kept. Output is ignored; stderr goes to the debug log.
#   Claude Code never deletes the branch of a hook-made worktree; this hook does.
#   Claude Code's "is it clean?" check is git's, so a tree it calls clean can
#   still be refused here only if git disagrees by now (a write since).
#
# BEHAVIOUR
#   directory gone            -> exit 0 (nothing to remove)
#   not a LINKED git worktree -> exit 1, left in place (never rm -rf a dir we
#                                cannot prove is a disposable checkout; the main
#                                checkout is never a candidate)
#   `git worktree remove` WITHOUT --force: git refuses changed or untracked files
#     and locked trees, so dirty work survives -> exit 1 with git's reason.
#   then `git branch -d` (never -D) on the tree's branch, only when it is a
#     `worktree-*` branch (the create hook's): an unmerged branch is KEPT, with a
#     note, and the exit stays 0 because the directory is gone.
#
# Exit: 0 removed (or already gone) | 1 kept (reason on stderr).
# Tests: tests/hooks.sh "worktree-create / worktree-remove".
set -uo pipefail

say() { echo "worktree-remove: $*" >&2; }
command -v jq >/dev/null 2>&1 || { say "jq is required to read the hook input"; exit 1; }
WT="$(jq -r '.worktree_path // empty' 2>/dev/null | tr -d '\r')"
[[ -n "$WT" ]] || { say "no worktree_path in the hook input"; exit 1; }
[[ -e "$WT" ]] || { say "$WT is already gone"; exit 0; }

GITDIR="$(git -C "$WT" rev-parse --path-format=absolute --git-dir 2>/dev/null)" \
  || { say "$WT is not a git worktree - left in place"; exit 1; }
COMMON="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || { say "cannot resolve the repository of $WT - left in place"; exit 1; }
TOP="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)"
# A linked worktree has its own git dir under <common>/worktrees/; the main
# checkout's git dir IS the common dir. Also refuse a path that is merely
# somewhere inside a checkout rather than its root.
if [[ "$GITDIR" == "$COMMON" ]]; then say "$WT is a main checkout - never removed"; exit 1; fi
lc() { local p=${1//\\//}; p=${p%/}; printf '%s' "$p" | tr '[:upper:]' '[:lower:]'; }
if command -v cygpath >/dev/null 2>&1; then
  wt_n="$(cygpath -m "$WT" 2>/dev/null)"; top_n="$(cygpath -m "$TOP" 2>/dev/null)"
else wt_n="$WT"; top_n="$TOP"; fi
[[ "$(lc "$wt_n")" == "$(lc "$top_n")" ]] || { say "$WT is not a worktree root ($TOP is) - left in place"; exit 1; }

MAIN="$(dirname "$COMMON")"
BRANCH="$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

if ! out="$(git -C "$MAIN" worktree remove "$WT" 2>&1)"; then
  say "kept $WT - git refused to remove it: ${out//$'\n'/ }"
  say "commit or discard its work, then remove it by hand: git worktree remove '$WT'"
  exit 1
fi
say "removed $WT"

if [[ "$BRANCH" == worktree-* ]]; then
  if out="$(git -C "$MAIN" branch -d "$BRANCH" 2>&1)"; then
    say "deleted merged branch $BRANCH"
  else
    say "kept branch $BRANCH (git refused -d; its commits are safe): ${out//$'\n'/ }"
  fi
fi
exit 0
