#!/bin/bash
# new-lane.sh — create an isolated git worktree + branch ("lane") for parallel work, carrying over
# the gitignored env files a fresh worktree won't have. The one-command remedy when the peer-writer
# guard fires, or any time you want to parallelise without two sessions sharing one checkout.
# Part of the git-ops skill (Worktree Operations → "Lane provisioning").
#
# Usage:   new-lane.sh <slug> [base-branch]
#   <slug>        short kebab name -> branch lane/<slug>, worktree <repo>/../<repo>-<slug>
#   [base-branch] what to branch from (default: the current branch)
#
# Output contract (SKILL-RESOURCE-PROTOCOL): the new worktree's absolute path is the ONLY thing on
# stdout (so a caller can `cd "$(new-lane.sh foo)"`); all human-facing messages go to stderr.
# Exit: 0 ok | 2 usage/precondition | 1 conflict (branch/path exists).
#
# Examples:
#   new-lane.sh auth-refactor            # lane/auth-refactor off the current branch
#   new-lane.sh hotfix main              # lane/hotfix off main
set -euo pipefail

case "${1:-}" in
   -h|--help|"")
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
    [ -z "${1:-}" ] && exit 2 || exit 0 ;;
esac

SLUG=$(printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
[ -n "$SLUG" ] || { echo "new-lane: slug empty after sanitising" >&2; exit 2; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "new-lane: not inside a git repo" >&2; exit 2; }
REPO=$(basename "$ROOT")
BRANCH="lane/$SLUG"
BASE="${2:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
WT="$(dirname "$ROOT")/${REPO}-${SLUG}"

git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && { echo "new-lane: branch $BRANCH already exists" >&2; exit 1; }
[ -e "$WT" ] && { echo "new-lane: path $WT already exists" >&2; exit 1; }

git -C "$ROOT" worktree add "$WT" -b "$BRANCH" "$BASE" >&2

# Carry over gitignored env/secret files the new worktree won't have (Cloudflare/Node/etc.).
for f in .dev.vars .env .env.local .env.development .secrets; do
  if [ -e "$ROOT/$f" ] && [ ! -e "$WT/$f" ]; then
    cp -r "$ROOT/$f" "$WT/$f" 2>/dev/null && echo "new-lane: carried over $f" >&2
  fi
done

echo "new-lane: lane ready — branch $BRANCH (base $BASE)" >&2
echo "new-lane: open a Claude session with cwd '$WT' — one writer per tree; land via fleet-ops" >&2
printf '%s\n' "$WT"
