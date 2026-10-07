#!/usr/bin/env bash
# push-scope.sh - What would `git push <remote> <branch>` send? The single
# source of truth for push-preflight's scope: preflight.sh (Steps 4 and 7) and
# scan-secrets.sh (Step 6) source it, so the commit count, the secret scan and
# the forbidden-file check always cover the same commits. Run directly, it
# prints that scope as key=value lines (a debugging aid).
#
# Three kinds, decided from the LOCAL remote-tracking refs:
#   update        <remote>/<branch> exists: <remote>/<branch>..<branch>
#   new-branch    it doesn't, but <remote> has refs: commits on <branch> that no
#                 <remote>/* ref reaches (`--not --remotes=<remote>`)
#   empty-remote  <remote> has no refs at all: the whole branch
# Only `empty-remote` is a full-branch scan. A new branch cut from main sends
# just its own commits; rescanning main's history refused pushes over lines
# that were already public (2026-10-07). History audits are security-ops' job.
#
# Usage:   push-scope.sh <remote> <branch>
#          or source it, then call: push_scope <remote> <branch>
# Exit:    0 scope printed, 1 git error (e.g. unknown branch), 2 bad usage

# Sets, in the caller's shell:
#   SCOPE_KIND   update | new-branch | empty-remote
#   SCOPE_REVS   array of rev-list arguments selecting the commits sent
#   SCOPE_COUNT  how many commits that is
#   SCOPE_BASE   diff base: `git diff SCOPE_BASE..<branch>` is the net set of
#                lines (and, with --diff-filter=A, files) the push adds
push_scope() {
  local remote="$1" branch="$2"
  # Git's well-known empty-tree object: diffing from it shows every file as added.
  local empty_tree="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  if git rev-parse --verify --quiet "${remote}/${branch}" >/dev/null; then
    SCOPE_KIND="update"
    SCOPE_REVS=("${remote}/${branch}..${branch}")
    SCOPE_BASE="${remote}/${branch}"
  elif [ -z "$(git for-each-ref --count=1 --format='%(refname)' "refs/remotes/${remote}")" ]; then
    SCOPE_KIND="empty-remote"
    SCOPE_REVS=("$branch")
    SCOPE_BASE="$empty_tree"
  else
    SCOPE_KIND="new-branch"
    # The tracking refs stand in for what the remote holds. A ref the remote
    # has since deleted may hide a commit the push re-sends, but that commit
    # was published once already. Refs that are merely behind only widen the scan.
    SCOPE_REVS=("$branch" --not "--remotes=${remote}")
    SCOPE_BASE="$(_push_scope_base "$branch" "$remote" "$empty_tree")"
  fi
  SCOPE_COUNT="$(git rev-list --count "${SCOPE_REVS[@]}")"
}

# Diff base for a new branch. The boundary commits are the already-published
# parents of the unsent commits. The usual case is one fork point, or several
# where all but one are its ancestors (main merged in mid-branch). There the
# newest one, `--independent`'s sole survivor, is the base, so lines that
# arrived with the merge are not counted as added. Truly separate fork points
# (two remote branches merged in) fall back to their common ancestor: that
# over-scans, which can refuse a push but can never miss a line. No boundary
# (the branch shares no history with the remote) means the whole branch.
_push_scope_base() {
  local branch="$1" remote="$2" empty_tree="$3" boundary base
  boundary="$(git rev-list --boundary "$branch" --not "--remotes=${remote}" | sed -n 's/^-//p')"
  if [ -z "$boundary" ]; then
    if [ -z "$(git rev-list -n 1 "$branch" --not "--remotes=${remote}")" ]; then
      git rev-parse "$branch"      # nothing unsent: the diff is empty
    else
      echo "$empty_tree"
    fi
    return 0
  fi
  # shellcheck disable=SC2046,SC2086  # commit IDs, one per word: nothing to glob
  set -- $(git merge-base --independent $boundary)
  if [ "$#" -eq 1 ]; then
    echo "$1"
    return 0
  fi
  base="$(git merge-base --octopus "$@" 2>/dev/null | head -n 1 || true)"
  echo "${base:-$empty_tree}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  usage() {
    cat <<'EOF'
Usage: push-scope.sh <remote> <branch>

Print what `git push <remote> <branch>` would send, as key=value lines:
kind (update | new-branch | empty-remote), count, base and revs. Reads only
local refs: fetch first for a current answer.

EXAMPLES
  bash push-scope.sh origin main
  bash push-scope.sh origin feature/login

Exit codes: 0 scope printed, 1 git error (e.g. unknown branch), 2 bad usage.
EOF
  }
  case "${1-}" in
    -h|--help) usage; exit 0 ;;
  esac
  if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
  fi
  push_scope "$1" "$2" || exit 1
  printf 'kind=%s\ncount=%s\nbase=%s\nrevs=%s\n' \
    "$SCOPE_KIND" "$SCOPE_COUNT" "$SCOPE_BASE" "${SCOPE_REVS[*]}"
fi
