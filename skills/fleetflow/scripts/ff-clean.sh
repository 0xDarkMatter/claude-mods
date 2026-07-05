#!/usr/bin/env bash
# ff-clean.sh - reclaim a fleetflow run's lanes, branches, and cache dirs.
#
# Per lane (worktree lane under <run>/wt-<id>):
#   zero commits + clean      -> git worktree remove + branch -D   ("removed")
#   zero commits + dirty      -> "kept" unless --force              (--force removes)
#   N>0 commits               -> "kept (N commits)"                 (never auto-remove)
#   locked ACL-litter dir     -> "locked (needs elevation)"         (continue, non-fatal)
# Then removes each lane's cache dir under FLEETFLOW_CACHE_ROOT (default
# $HOME/.fleet-worker/cache/<run>-<id>). Removal never aborts the run: a locked
# lane is reported and skipped, and the script exits 0 once it has tried them all.
# stdout: one TSV line per lane: id<TAB>status<TAB>detail. stderr: chatter.
#
# Exit codes: 0 done (incl. some locked lanes) | 2 usage / no such run
set -u

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-clean.sh --run NAME [--repo PATH] [--force]

  --run NAME      run name under <repo>/.fleetflow/
  --repo PATH     repo root (default: git toplevel of cwd)
  --force         also remove DIRTY zero-commit lanes (committed lanes are
                  ALWAYS kept - land or branch them first, then clean)

  Lanes with commits are never removed (their work would be lost); clean only
  after ff-collect has gated them and the orchestrator has landed/branched the
  keepers. Locked codex sandbox-litter dirs are reported and skipped.

EXAMPLES
  ff-clean.sh --run currency
  ff-clean.sh --run currency --force
  ff-clean.sh --run currency --repo /path/to/repo | column -t
EOF
}

err() { echo "ff-clean: $*" >&2; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }   # id <TAB> status <TAB> detail

RUN="" REPO="" FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
MANIFEST="$RUNDIR/manifest.json"
[ -d "$RUNDIR" ] || { err "no such run: $RUNDIR"; exit 2; }

CACHE_ROOT="${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}"
BASE="$(jq -r '.base // "main"' "$MANIFEST" 2>/dev/null)"; [ -n "$BASE" ] || BASE="main"

# enumerate lane ids: manifest packets (authoritative) + any wt-* dirs left on
# disk (e.g. manifest pruned but lanes remain) + journal started ids (fallback).
list_lane_ids() {
  local ids=""
  [ -f "$MANIFEST" ] && ids="$(jq -r '.packets[].id' "$MANIFEST" 2>/dev/null)"
  local d
  for d in "$RUNDIR"/wt-*; do
    [ -d "$d" ] || continue
    ids="$ids
$(basename "$d" | sed 's/^wt-//')"
  done
  if [ -z "$ids" ] && [ -f "$RUNDIR/journal.jsonl" ]; then
    ids="$(jq -r 'select(.type=="started") | .id' "$RUNDIR/journal.jsonl" 2>/dev/null)"
  fi
  printf '%s\n' "$ids" | awk 'NF && !seen[$0]++'
}

# remove_lane <id> <force>: worktree remove (+ branch -D on success). Reports
# "locked" if the OS refuses to delete (codex AppContainer-ACL litter).
remove_lane() {
  local id="$1" f="$2" wt="$RUNDIR/wt-$id" br="fleetflow/$RUN/$id" wflag=""
  [ "$f" = 1 ] && wflag="--force"
  if git -C "$REPO" worktree remove $wflag "$wt" 2>>"$RUNDIR/$id.clean.err"; then
    git -C "$REPO" branch -D "$br" >/dev/null 2>>"$RUNDIR/$id.clean.err" \
      && emit "$id" removed "worktree + branch gone" \
      || emit "$id" removed "worktree gone (branch delete skipped)"
  else
    emit "$id" locked "needs elevation (see $RUNDIR/$id.clean.err)"
  fi
}

# clean_cache <id>: best-effort removal of the lane's cache/tmp dir.
clean_cache() {
  local id="$1" c="$CACHE_ROOT/$RUN-$id"
  [ -d "$c" ] || return 0
  if rm -rf "$c" 2>>"$RUNDIR/$id.clean.err"; then err "cache removed: $c"
  else err "cache locked (needs elevation): $c"; fi
}

NLANES="$(list_lane_ids | wc -l | tr -d ' ')"
err "cleaning run '$RUN': $NLANES lane(s); FORCE=$FORCE; base=$BASE; cache=$CACHE_ROOT"
if [ "$NLANES" = "0" ]; then
  err "no lanes to clean"
  exit 0
fi

# base ref must exist for rev-list counting; fall back to HEAD once for the run
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"

while read -r id; do
  [ -n "$id" ] || continue
  wt="$RUNDIR/wt-$id"
  if [ -d "$wt" ]; then
    commits="$(git -C "$wt" rev-list --count "$BASE..HEAD" 2>/dev/null || echo 0)"
    dirt="$(git -C "$wt" status --porcelain 2>/dev/null)"
    if [ "${commits:-0}" -eq 0 ] && [ -z "$dirt" ]; then
      remove_lane "$id" 0
    elif [ "${commits:-0}" -eq 0 ] && [ -n "$dirt" ]; then
      if [ "$FORCE" = 1 ]; then remove_lane "$id" 1
      else emit "$id" kept "dirty, zero commits (use --force)"; fi
    else
      emit "$id" kept "$commits commits"
    fi
  else
    emit "$id" kept "no worktree lane"
  fi
  clean_cache "$id"
done < <(list_lane_ids)

exit 0
