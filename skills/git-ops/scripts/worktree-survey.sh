#!/bin/bash
# worktree-survey.sh - Read-only worktree survey + triage
#
# Enumerates registered worktrees, cross-references with .claude/worktrees/
# filesystem entries, classifies each, and emits a table + summary.
#
# NEVER mutates. Respects rules/worktree-boundaries.md.
#
# Usage:
#   bash worktree-survey.sh              # survey current repo
#   bash worktree-survey.sh <repo-path>  # survey explicit repo
#
# Exit codes:
#   0  All worktrees healthy (no ghosts, orphans, or prunable)
#   1  Attention needed (ghosts, orphans, or prunable candidates found)
#   2  Not a git repo

set -u

REPO="${1:-$PWD}"

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not-a-repo: $REPO"
  exit 2
fi

REPO_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
cd "$REPO_ROOT" || exit 2

# Detect trunk branch
TRUNK="main"
if ! git rev-parse --verify main >/dev/null 2>&1; then
  if git rev-parse --verify master >/dev/null 2>&1; then
    TRUNK="master"
  fi
fi

# Parse `git worktree list --porcelain` into TSV: path \t branch \t head
TMP_REG=$(mktemp)
git worktree list --porcelain 2>/dev/null | awk '
  /^worktree / { p=substr($0,10); b=""; h=""; next }
  /^HEAD /     { h=substr($0,6); next }
  /^branch /   { b=substr($0, 19); next }  # skip "branch refs/heads/" (18 chars)
  /^detached/  { b="(detached)"; next }
  /^$/         { if (p != "") { print p"\t"b"\t"h } p=""; b=""; h=""; next }
  END          { if (p != "") print p"\t"b"\t"h }
' > "$TMP_REG"

WT_COUNT=$(wc -l < "$TMP_REG" | tr -d ' ')

# Enumerate filesystem entries in .claude/worktrees/ (canonical absolute paths)
TMP_FS=$(mktemp)
if [ -d .claude/worktrees ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    (cd "$d" 2>/dev/null && pwd -P)
  done < <(find .claude/worktrees -maxdepth 1 -mindepth 1 -type d 2>/dev/null) > "$TMP_FS"
fi

FS_COUNT=$(wc -l < "$TMP_FS" | tr -d ' ')

# Counters
GHOSTS=0
PRUNABLE=0
WIP=0
UNPUSHED=0
ORPHANS=0

# Header
printf "%-40s %-20s %-22s %-12s %s\n" "PATH" "BRANCH" "STATE" "AGE" "VERDICT"
echo "──────────────────────────────────────────────────────────────────────────────────────────────"

# --- Process each registered worktree ---
while IFS=$'\t' read -r path branch head; do
  [ -z "$path" ] && continue

  # Canonical absolute (for orphan comparison)
  canon_path=$( (cd "$path" 2>/dev/null && pwd -P) || echo "$path" )

  # Display path
  if [ "$path" = "$REPO_ROOT" ]; then
    disp="<trunk>"
  else
    disp="${path#$REPO_ROOT/}"
    [ ${#disp} -gt 38 ] && disp="...${disp: -35}"
  fi

  # Ghost: registered but filesystem gone
  if [ ! -d "$path" ]; then
    printf "%-40s %-20s %-22s %-12s %s\n" "<$disp>" "$branch" "FILESYSTEM GONE" "?" "git worktree prune"
    GHOSTS=$((GHOSTS+1))
    continue
  fi

  # Tree state
  staged=$(git -C "$path" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  unstaged=$(git -C "$path" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

  # Upstream sync
  ahead=0
  behind=0
  if [ "$branch" != "(detached)" ] && git -C "$path" rev-parse '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$path" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  fi

  # Age
  age="?"
  if [ -n "$head" ]; then
    age=$(git log -1 --format='%ar' "$head" 2>/dev/null | sed 's/ ago//')
  fi

  # Merged into trunk?
  merged=false
  if [ -n "$head" ] && [ "$branch" != "$TRUNK" ] && \
     git rev-parse --verify "$TRUNK" >/dev/null 2>&1 && \
     git merge-base --is-ancestor "$head" "$TRUNK" 2>/dev/null; then
    merged=true
  fi

  # Build state string
  state=""
  dirty=false
  [ "$staged"    -gt 0 ] && state="${state} ${staged}s"    && dirty=true
  [ "$unstaged"  -gt 0 ] && state="${state} ${unstaged}u"  && dirty=true
  [ "$untracked" -gt 0 ] && state="${state} ${untracked}?" && dirty=true
  [ "$ahead"     -gt 0 ] && state="${state} +${ahead}"
  [ "$behind"    -gt 0 ] && state="${state} -${behind}"
  state="${state# }"
  [ -z "$state" ] && state="clean"
  [ "$merged" = true ] && state="$state (merged)"

  # Verdict
  if [ "$branch" = "$TRUNK" ]; then
    verdict="(trunk)"
  elif [ "$dirty" = true ]; then
    verdict="has WIP"
    WIP=$((WIP+1))
  elif [ "$ahead" -gt 0 ]; then
    verdict="unpushed"
    UNPUSHED=$((UNPUSHED+1))
  elif [ "$merged" = true ]; then
    verdict="PRUNABLE"
    PRUNABLE=$((PRUNABLE+1))
  else
    verdict="in-flight"
  fi

  printf "%-40s %-20s %-22s %-12s %s\n" "$disp" "$branch" "$state" "$age" "$verdict"
done < "$TMP_REG"

# --- Orphans: filesystem entries in .claude/worktrees/ with no registration ---
while IFS= read -r fs_path; do
  [ -z "$fs_path" ] && continue
  registered=false
  while IFS=$'\t' read -r reg_path _ _; do
    reg_canon=$( (cd "$reg_path" 2>/dev/null && pwd -P) || echo "$reg_path" )
    if [ "$reg_canon" = "$fs_path" ]; then
      registered=true
      break
    fi
  done < "$TMP_REG"
  if [ "$registered" = false ]; then
    disp="${fs_path#$REPO_ROOT/}"
    printf "%-40s %-20s %-22s %-12s %s\n" "$disp" "?" "UNREGISTERED" "?" "manual review (DO NOT touch)"
    ORPHANS=$((ORPHANS+1))
  fi
done < "$TMP_FS"

rm -f "$TMP_REG" "$TMP_FS"

# --- Summary ---
echo ""
echo "Summary: $WT_COUNT registered / $FS_COUNT in .claude/worktrees / $ORPHANS orphan"
echo "  PRUNABLE (merged, clean, linked):   $PRUNABLE"
echo "  WIP (uncommitted changes):          $WIP"
echo "  Unpushed (ahead of upstream):       $UNPUSHED"
echo "  Ghost (registered, FS missing):     $GHOSTS"
echo "  Orphan (FS exists, unregistered):   $ORPHANS    ← read-only, never rm without review"

# Legend note (shown only if abbreviations appear in output)
if [ "$WIP" -gt 0 ] || [ "$UNPUSHED" -gt 0 ]; then
  echo ""
  echo "  STATE legend: Ns=staged, Nu=unstaged, N?=untracked, +N=ahead, -N=behind"
fi

# Exit 1 if anything needs attention
if [ "$GHOSTS" -gt 0 ] || [ "$ORPHANS" -gt 0 ] || [ "$PRUNABLE" -gt 0 ]; then
  exit 1
fi
exit 0
