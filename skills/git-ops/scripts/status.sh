#!/bin/bash
# git-status - one-shot read-only repo overview
#
# Usage:
#   bash status.sh             # survey current directory
#   bash status.sh <repo-path> # survey explicit path
#
# Exit codes:
#   0  CLEAN (nothing ahead/behind, tree empty, no stashes)
#   1  NON-CLEAN (at least one signal non-zero)
#   2  Not a git repo

set -u

REPO="${1:-$PWD}"

# Guard: must be inside a git repo
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not-a-repo: $REPO"
  exit 2
fi

REPO_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
cd "$REPO_ROOT" || { echo "cannot-cd: $REPO_ROOT"; exit 2; }

# Best-effort fetch — record failure but don't abort
FETCH_OK=true
git fetch --quiet 2>/dev/null || FETCH_OK=false

# Age of last successful fetch (mtime of FETCH_HEAD)
fetch_age=-1
if [ -f .git/FETCH_HEAD ]; then
  if fetch_mtime=$(stat -c '%Y' .git/FETCH_HEAD 2>/dev/null); then
    :
  elif fetch_mtime=$(stat -f '%m' .git/FETCH_HEAD 2>/dev/null); then
    :
  else
    fetch_mtime=""
  fi
  if [ -n "$fetch_mtime" ]; then
    fetch_age=$(( $(date +%s) - fetch_mtime ))
  fi
fi

# Branch / HEAD
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")
HEAD_INFO=$(git log -1 --format='%h %s (%ar)' 2>/dev/null || echo "(no commits)")

# Sync with upstream (if configured)
AHEAD=0
BEHIND=0
if [ "$BRANCH" != "(detached)" ] && git rev-parse '@{u}' >/dev/null 2>&1; then
  AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  SYNC_LINE="$AHEAD ahead / $BEHIND behind"
else
  SYNC_LINE="no upstream"
fi

# Working tree
STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
UNSTAGED=$(git diff --name-only | wc -l | tr -d ' ')
UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
STASHES=$(git stash list | wc -l | tr -d ' ')

# Shortstat if there's uncommitted change
SHORTSTAT=""
if [ "$STAGED" -gt 0 ] || [ "$UNSTAGED" -gt 0 ]; then
  SHORTSTAT=$(git diff HEAD --shortstat 2>/dev/null \
    | sed 's/^ *//' \
    | sed -E 's/([0-9]+) files? changed, //' \
    | sed -E 's/([0-9]+) insertions?\(\+\)/+\1/' \
    | sed -E 's/([0-9]+) deletions?\(-\)/-\1/' \
    | tr -d '()')
fi

# Worktrees — registered vs filesystem
WT_REGISTERED=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
WT_FS=0
if [ -d .claude/worktrees ]; then
  WT_FS=$(find .claude/worktrees -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
fi

# Branches
BR_LOCAL=$(git branch 2>/dev/null | wc -l | tr -d ' ')
BR_REMOTE=$(git branch -r 2>/dev/null | wc -l | tr -d ' ')

# Optional PR linkage (graceful if gh absent or no PR)
PR_LINE=""
if command -v gh >/dev/null 2>&1 && [ "$BRANCH" != "(detached)" ]; then
  PR_JSON=$(gh pr view --json number,url,state 2>/dev/null || true)
  if [ -n "$PR_JSON" ] && command -v jq >/dev/null 2>&1; then
    PR_LINE=$(printf '%s' "$PR_JSON" \
      | jq -r 'if .number then "PR #\(.number): \(.url) [\(.state)]" else empty end' 2>/dev/null)
  fi
fi

# --- Hygiene checks ---------------------------------------------------------
# Detect if we're in the main checkout or a worktree
GIT_DIR_REL=$(git rev-parse --git-dir 2>/dev/null)
IS_WORKTREE=false
case "$GIT_DIR_REL" in
  *worktrees*) IS_WORKTREE=true ;;
esac

# Detect the repo's default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
if [ -z "$DEFAULT_BRANCH" ]; then
  for b in main master trunk develop; do
    if git show-ref --verify --quiet "refs/heads/$b" 2>/dev/null; then
      DEFAULT_BRANCH="$b"
      break
    fi
  done
fi

HYGIENE_FLAGS=""

# Check 1: main checkout on a feature branch
if [ "$IS_WORKTREE" = false ] && \
   [ -n "$DEFAULT_BRANCH" ] && \
   [ "$BRANCH" != "$DEFAULT_BRANCH" ] && \
   [ "$BRANCH" != "(detached)" ]; then
  HYGIENE_FLAGS="${HYGIENE_FLAGS}HYGIENE[1]: main checkout is on '$BRANCH' (default: '$DEFAULT_BRANCH') — feature work belongs in worktrees\n"
fi

# Check 2: stale merged branches
if [ -n "$DEFAULT_BRANCH" ]; then
  MERGED_COUNT=$(git branch --merged "$DEFAULT_BRANCH" 2>/dev/null \
    | grep -v "^\*\|^\s*${DEFAULT_BRANCH}$\|^\s*master$\|^\s*main$\|^\s*trunk$" \
    | wc -l | tr -d ' ')
  if [ "$MERGED_COUNT" -gt 0 ]; then
    HYGIENE_FLAGS="${HYGIENE_FLAGS}HYGIENE[2]: $MERGED_COUNT merged branch(es) not yet deleted — run: git branch --merged $DEFAULT_BRANCH\n"
  fi
fi

# --- Output -----------------------------------------------------------------
echo "repo:    $REPO_ROOT"
echo "branch:  $BRANCH"
echo "HEAD:    $HEAD_INFO"
echo "sync:    $SYNC_LINE"

TREE_LINE="$STAGED staged / $UNSTAGED unstaged / $UNTRACKED untracked / $STASHES stashes"
if [ -n "$SHORTSTAT" ]; then
  TREE_LINE="$TREE_LINE ($SHORTSTAT)"
fi
echo "tree:    $TREE_LINE"

# Only show worktrees line if there are multiple registered OR .claude/worktrees exists
if [ "$WT_REGISTERED" -gt 1 ] || [ "$WT_FS" -gt 0 ]; then
  echo "trees:   $WT_REGISTERED registered / $WT_FS in .claude/worktrees"
fi

echo "branch:  $BR_LOCAL local / $BR_REMOTE remote"

if [ -n "$PR_LINE" ]; then
  echo "pr:      $PR_LINE"
fi

# Hygiene warnings
if [ -n "$HYGIENE_FLAGS" ]; then
  echo ""
  printf "%b" "$HYGIENE_FLAGS" | sed 's/^/⚠  /'
fi

# Fetch failure warning
if [ "$FETCH_OK" = false ]; then
  if [ "$fetch_age" -ge 0 ]; then
    if   [ "$fetch_age" -gt 86400 ]; then age_display="$((fetch_age / 86400))d ago"
    elif [ "$fetch_age" -gt 3600  ]; then age_display="$((fetch_age / 3600))h ago"
    elif [ "$fetch_age" -gt 60    ]; then age_display="$((fetch_age / 60))m ago"
    else age_display="${fetch_age}s ago"
    fi
  else
    age_display="unknown"
  fi
  echo "fetch:   FAILED (last successful: $age_display)"
fi

# --- Verdict ----------------------------------------------------------------
echo ""
if [ "$AHEAD" -eq 0 ] && [ "$BEHIND" -eq 0 ] && \
   [ "$STAGED" -eq 0 ] && [ "$UNSTAGED" -eq 0 ] && \
   [ "$UNTRACKED" -eq 0 ] && [ "$STASHES" -eq 0 ]; then
  echo "verdict: CLEAN"
  exit 0
fi

FLAGS=""
[ "$AHEAD"     -gt 0 ] && FLAGS="$FLAGS ahead"
[ "$BEHIND"    -gt 0 ] && FLAGS="$FLAGS behind"
[ "$STAGED"    -gt 0 ] && FLAGS="$FLAGS staged"
[ "$UNSTAGED"  -gt 0 ] && FLAGS="$FLAGS unstaged"
[ "$UNTRACKED" -gt 0 ] && FLAGS="$FLAGS untracked"
[ "$STASHES"   -gt 0 ] && FLAGS="$FLAGS stashes"
echo "verdict: NON-CLEAN —${FLAGS}"
exit 1
