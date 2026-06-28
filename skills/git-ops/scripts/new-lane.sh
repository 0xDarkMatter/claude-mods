#!/bin/bash
# new-lane.sh — create an isolated git worktree + branch ("lane") for parallel work, carrying over
# the gitignored env files a fresh worktree won't have. The one-command remedy when the peer-writer
# guard fires, or any time you want to parallelise without two sessions sharing one checkout.
# Part of the git-ops skill (Worktree Operations → "Lane provisioning").
#
# Usage:   new-lane.sh [--sibling] <slug> [base-branch]
#   <slug>        short kebab name -> branch lane/<slug>
#   [base-branch] what to branch from (default: the current branch)
#   --sibling     place the worktree OUTSIDE the repo at <repo>/../<repo>-<slug>
#                 (structural isolation; use for a repo that can't gitignore
#                  .claude/worktrees/, or just before destructive cleanups)
#
# Default is IN-REPO: <main>/.claude/worktrees/<slug> — the native Claude Code worktree
# location: tidy (no sibling dirs littering the parent), and gitignored so `git add -A`
# can't stage its gitlinks (the precondition is verified/ensured below). Committed lane work
# lives in the shared object store and survives even directory deletion; only UNCOMMITTED work
# is at risk from `git clean -ff` / `rm -rf`, so land early/often. See rules/worktree-boundaries.md.
#
# Output contract (SKILL-RESOURCE-PROTOCOL): the new worktree's absolute path is the ONLY thing on
# stdout (so a caller can `cd "$(new-lane.sh foo)"`); all human-facing messages go to stderr.
# Exit: 0 ok | 2 usage/precondition | 1 conflict (branch/path exists).
#
# Examples:
#   new-lane.sh auth-refactor            # lane/auth-refactor in .claude/worktrees/auth-refactor
#   new-lane.sh hotfix main              # lane/hotfix off main, in-repo
#   new-lane.sh --sibling big-migration  # lane/big-migration in ../<repo>-big-migration
set -euo pipefail

show_help() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' >&2; }

SIBLING=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --sibling) SIBLING=1 ;;
    -h|--help) show_help; exit 0 ;;
    --) : ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[ -n "${1:-}" ] || { show_help; exit 2; }

SLUG=$(printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
[ -n "$SLUG" ] || { echo "new-lane: slug empty after sanitising" >&2; exit 2; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "new-lane: not inside a git repo" >&2; exit 2; }

# Anchor at the MAIN worktree root so a lane never nests inside a linked worktree
# (running from .claude/worktrees/<x> would otherwise create worktrees-in-worktrees).
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || echo "$ROOT/.git")
case "$COMMON" in
  /*|[A-Za-z]:[\\/]*) ;;             # already absolute
  *) COMMON="$ROOT/$COMMON" ;;       # relative → resolve under ROOT
esac
MAIN=$(cd "$(dirname "$COMMON")" 2>/dev/null && pwd) || MAIN="$ROOT"

REPO=$(basename "$MAIN")
BRANCH="lane/$SLUG"
BASE="${2:-$(git -C "$MAIN" rev-parse --abbrev-ref HEAD 2>/dev/null)}"

if [ "$SIBLING" -eq 1 ]; then
  WT="$(dirname "$MAIN")/${REPO}-${SLUG}"
else
  # In-repo placement is only safe when the lane dir is gitignored — otherwise
  # `git add -A` from the main checkout stages worktree gitlinks (the 2026-04-19
  # incident). Ensure the ignore so the in-repo default is safe in ANY repo, not
  # just one someone already tidied.
  if ! git -C "$MAIN" check-ignore -q ".claude/worktrees/.probe" 2>/dev/null; then
    printf '\n# git worktrees / lanes — never tracked (new-lane.sh)\n.claude/worktrees/\n' >> "$MAIN/.gitignore"
    echo "new-lane: '.claude/worktrees/' was not gitignored — added it to .gitignore (commit this)" >&2
  fi
  WT="$MAIN/.claude/worktrees/$SLUG"
fi

git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH" && { echo "new-lane: branch $BRANCH already exists" >&2; exit 1; }
[ -e "$WT" ] && { echo "new-lane: path $WT already exists" >&2; exit 1; }

git -C "$MAIN" worktree add "$WT" -b "$BRANCH" "$BASE" >&2

# Carry over gitignored env/secret files the new worktree won't have (Cloudflare/Node/etc.).
for f in .dev.vars .env .env.local .env.development .secrets; do
  if [ -e "$MAIN/$f" ] && [ ! -e "$WT/$f" ]; then
    cp -r "$MAIN/$f" "$WT/$f" 2>/dev/null && echo "new-lane: carried over $f" >&2
  fi
done

echo "new-lane: lane ready — branch $BRANCH (base $BASE)" >&2
echo "new-lane: open a Claude session with cwd '$WT' — one writer per tree; land via fleet-ops" >&2
printf '%s\n' "$WT"
