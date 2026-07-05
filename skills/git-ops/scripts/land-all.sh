#!/bin/bash
# land-all.sh — read-only survey that classifies every branch/worktree by HOW it
# should land on trunk, so the git-ops "land all" front-door can plan a batch
# and hand the landable set to fleet-ops (sequential, test-gated landing).
#
# NEVER mutates. It inspects worktrees but never writes, moves, or deletes them.
# Respects rules/worktree-boundaries.md. The actual landing is delegated to
# fleet-ops — this script only decides what SHOULD land, park, or prune.
#
# Classification (per local branch, trunk excluded):
#   LANDABLE  clean, ahead, not merged, recent, no live writer   → land it
#   STALE     clean, ahead, not merged, but old (last commit >    → prune/archive
#             --recent-days ago) — abandoned branch, not auto-landed  or land explicitly
#   WIP       uncommitted tracked changes                        → commit first, park
#   ACTIVE    a session is writing it right now (recent activity) → park, don't touch
#   MERGED    already an ancestor of trunk (incl. nothing-ahead)  → prune candidate
#
# Usage:
#   bash land-all.sh                     # human panel for current repo
#   bash land-all.sh --porcelain         # TSV for the skill to parse (no header/summary)
#   bash land-all.sh <repo-path> [flags]
#
# Flags:
#   --porcelain          machine-readable TSV, one line per candidate:
#                          STATUS \t BRANCH \t WORKTREE \t AHEAD \t BEHIND \t AGE \t NOTE
#   --active-window N     seconds; a worktree touched within N seconds counts as
#                         ACTIVE (live writer). Default 120. 0 disables detection.
#   --recent-days N       a branch whose last commit is within N days is current
#                         work (LANDABLE); older clean branches are STALE. Default 7.
#
# Exit codes:
#   0  nothing landable (no LANDABLE candidates)
#   1  at least one LANDABLE candidate (a batch land is available)
#   2  not a git repo

set -u

REPO="$PWD"
PORCELAIN=0
ACTIVE_WINDOW=120
RECENT_DAYS=7

while [ $# -gt 0 ]; do
  case "$1" in
    --porcelain)     PORCELAIN=1; shift ;;
    --active-window) ACTIVE_WINDOW="${2:-120}"; shift 2 ;;
    --recent-days)   RECENT_DAYS="${2:-7}"; shift 2 ;;
    -h|--help)       sed -n '2,42p' "$0"; exit 0 ;;
    -*)              echo "unknown flag: $1" >&2; exit 2 ;;
    *)               REPO="$1"; shift ;;
  esac
done

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not-a-repo: $REPO" >&2
  exit 2
fi

REPO_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
cd "$REPO_ROOT" || exit 2

# Detect trunk branch (main preferred, then master).
TRUNK="main"
if ! git rev-parse --verify main >/dev/null 2>&1; then
  git rev-parse --verify master >/dev/null 2>&1 && TRUNK="master"
fi

NOW=$(date +%s)
ACTIVE_THRESHOLD=$((NOW - ACTIVE_WINDOW))
RECENT_THRESHOLD=$((NOW - RECENT_DAYS * 86400))

# Which branch is checked out in the MAIN checkout (REPO_ROOT)?
MAIN_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")

# Map branch -> worktree path from `git worktree list --porcelain`.
# (awk parses porcelain records; "branch refs/heads/" prefix is 18 chars.)
TMP_WT=$(mktemp)
git worktree list --porcelain 2>/dev/null | awk '
  /^worktree /{p=substr($0,10); next}
  /^branch /  {b=substr($0,19); if (b!="") print b"\t"p; next}
' > "$TMP_WT"

worktree_for() {
  # Echo the worktree path checked out on branch $1 (empty if none).
  awk -F'\t' -v want="$1" '$1==want{print $2; exit}' "$TMP_WT"
}

# Is a worktree being actively written? True if any tracked-tree file was
# modified within ACTIVE_WINDOW seconds. -print -quit stops at the first hit.
# --active-window 0 disables live-writer detection entirely.
worktree_active() {
  local wt=$1
  [ "$ACTIVE_WINDOW" -le 0 ] 2>/dev/null && return 1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  local hit
  hit=$(find "$wt" -type f -not -path '*/.git/*' -newermt "@$ACTIVE_THRESHOLD" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

# Does a worktree have uncommitted TRACKED changes? (untracked files don't block a
# land — the merge takes committed history — but we surface them in the note.)
worktree_dirty() {
  local wt=$1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  ! git -C "$wt" diff --quiet 2>/dev/null || ! git -C "$wt" diff --cached --quiet 2>/dev/null
}

# Counters
N_LANDABLE=0; N_STALE=0; N_WIP=0; N_ACTIVE=0; N_MERGED=0

emit() {
  # STATUS BRANCH WORKTREE AHEAD BEHIND AGE NOTE
  local status=$1 branch=$2 wt=$3 ahead=$4 behind=$5 age=$6 note=$7
  if [ "$PORCELAIN" -eq 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$branch" "$wt" "$ahead" "$behind" "$age" "$note"
  else
    local disp_wt="$wt"
    [ -n "$wt" ] && disp_wt="${wt#$REPO_ROOT/}"
    [ -z "$disp_wt" ] && disp_wt="-"
    printf '%-10s %-26s %-30s %-9s %-10s %s\n' \
      "$status" "${branch:0:26}" "${disp_wt:0:30}" "+${ahead}/-${behind}" "$age" "$note"
  fi
}

[ "$PORCELAIN" -eq 0 ] && {
  printf '%-10s %-26s %-30s %-9s %-10s %s\n' "STATUS" "BRANCH" "WORKTREE" "A/B" "AGE" "NOTE"
  echo "────────────────────────────────────────────────────────────────────────────────────────────────────"
}

# Walk every local branch except trunk.
while IFS= read -r branch; do
  [ -z "$branch" ] && continue
  [ "$branch" = "$TRUNK" ] && continue

  ahead=$(git rev-list --count "${TRUNK}..${branch}" 2>/dev/null || echo 0)
  behind=$(git rev-list --count "${branch}..${TRUNK}" 2>/dev/null || echo 0)
  age=$(git log -1 --format='%ar' "$branch" 2>/dev/null | sed 's/ ago//')
  [ -z "$age" ] && age="?"
  last_ct=$(git log -1 --format='%ct' "$branch" 2>/dev/null || echo 0)
  recent=false; [ "$last_ct" -ge "$RECENT_THRESHOLD" ] 2>/dev/null && recent=true

  wt=$(worktree_for "$branch")

  merged=false
  if git merge-base --is-ancestor "$branch" "$TRUNK" 2>/dev/null; then
    merged=true
  fi

  dirty=false; worktree_dirty "$wt" && dirty=true
  active=false; worktree_active "$wt" && active=true

  # Note annotations.
  note=""
  [ -n "$wt" ] && [ "$wt" = "$REPO_ROOT" ] && note="main checkout"
  if [ -n "$wt" ]; then
    untracked=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    [ "$untracked" -gt 0 ] && note="${note:+$note; }${untracked} untracked"
  fi

  # A branch far behind trunk will need a big rebase and likely conflicts —
  # surface it as a note whichever bucket it lands in.
  behind_note=""
  [ "$behind" -gt 40 ] && behind_note="far behind (${behind}) — expect conflicts"

  # Classify (order matters: merged before active/dirty; recency splits
  # clean-and-ahead into current LANDABLE vs abandoned STALE). A branch with
  # nothing ahead of trunk is necessarily an ancestor → caught by MERGED.
  if [ "$merged" = true ] || [ "$ahead" -eq 0 ]; then
    status="MERGED";  note="${note:+$note; }in trunk — prune candidate"; N_MERGED=$((N_MERGED+1))
  elif [ "$active" = true ]; then
    status="ACTIVE";  note="${note:+$note; }live writer <${ACTIVE_WINDOW}s — park"; N_ACTIVE=$((N_ACTIVE+1))
  elif [ "$dirty" = true ]; then
    status="WIP";     note="${note:+$note; }uncommitted — commit before landing"; N_WIP=$((N_WIP+1))
  elif [ "$recent" = true ]; then
    status="LANDABLE"; note="${note:+$note; }${behind_note}"; N_LANDABLE=$((N_LANDABLE+1))
  else
    status="STALE";   note="${note:+$note; }last commit >${RECENT_DAYS}d — abandoned?${behind_note:+; $behind_note}"; N_STALE=$((N_STALE+1))
  fi

  emit "$status" "$branch" "$wt" "$ahead" "$behind" "$age" "$note"
done < <(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

rm -f "$TMP_WT"

if [ "$PORCELAIN" -eq 0 ]; then
  echo ""
  echo "Trunk: $TRUNK   Main checkout on: ${MAIN_BRANCH:-<detached>}   (recent = ≤${RECENT_DAYS}d)"
  echo "Summary: $N_LANDABLE landable · $N_STALE stale · $N_WIP WIP · $N_ACTIVE active · $N_MERGED merged"
  echo ""
  if [ "$N_LANDABLE" -gt 0 ]; then
    echo "  → $N_LANDABLE branch(es) ready to land. Hand them to fleet-ops:"
    echo "      fleet track <landable-branches...>   &&   fleet land --all --running"
  else
    echo "  → nothing current to land right now."
  fi
  [ "$N_STALE"  -gt 0 ] && echo "  · $N_STALE stale (clean but >${RECENT_DAYS}d old) — prune/archive, or --recent-days to include."
  [ "$N_ACTIVE" -gt 0 ] && echo "  ⚠ $N_ACTIVE active (a session is writing) — parked, never auto-landed."
  [ "$N_WIP"    -gt 0 ] && echo "  ⚠ $N_WIP with uncommitted work — commit in-lane first, then re-run."
  if [ "$MAIN_BRANCH" != "$TRUNK" ] && [ -n "$MAIN_BRANCH" ]; then
    echo "  ⚠ main checkout is on '$MAIN_BRANCH', not '$TRUNK' — landing checks out $TRUNK there."
  fi
fi

# Exit 1 signals "a batch land is available" (LANDABLE > 0); 0 = nothing to do.
[ "$N_LANDABLE" -gt 0 ] && exit 1
exit 0
