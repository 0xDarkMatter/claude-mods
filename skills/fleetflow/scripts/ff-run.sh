#!/usr/bin/env bash
# ff-run.sh - whole-run replay/status for a fleetflow run.
#
# resume: replay every packet in <run>/manifest.json through ff-spawn, IN
#   MANIFEST ORDER, sequential. Unchanged packets cache-hit (ff-spawn exit 3)
#   and are reported "cached"; changed/new packets run live. A per-lane summary
#   goes to stderr; a JSON result array goes to stdout. Exit 0 if every lane is
#   ok or cached, 10 if any lane failed.
# status: convenience alias for ff-status (its JSON on stdout, identical exit).
# stdout: the JSON result list (resume) / ff-status JSON (status). stderr: chatter.
#
# Exit codes: 0 all ok/cached | 2 usage | 10 a lane failed
set -u

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-run.sh resume  --run NAME [--repo PATH]
       ff-run.sh status  --run NAME [--repo PATH]

  resume --run NAME   replay every packet in <run>/manifest.json through
                      ff-spawn, in order. Unchanged packets cache-hit ("cached"),
                      changed/new ones run live. JSON result list on stdout.
  status --run NAME   alias for ff-status (run status JSON on stdout).
  --repo PATH         repo root (default: git toplevel of cwd)

EXAMPLES
  ff-run.sh resume --run currency
  ff-run.sh resume --run currency --repo /path/to/repo | jq '.[] | select(.status!="cached")'
  ff-run.sh status --run currency | jq '.lanes | length'
EOF
}

err() { echo "ff-run: $*" >&2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/ff-spawn.sh"

MODE="" RUN="" REPO=""
[ $# -gt 0 ] || { err "a subcommand is required (resume|status)"; usage >&2; exit 2; }
case "$1" in
  resume) MODE="resume"; shift ;;
  status) MODE="status"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) err "unknown subcommand: $1"; usage >&2; exit 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

# status = alias for ff-status (hand off and let it own exit codes)
if [ "$MODE" = "status" ]; then
  if [ -n "$REPO" ]; then exec "$HERE/ff-status.sh" --run "$RUN" --repo "$REPO"; fi
  exec "$HERE/ff-status.sh" --run "$RUN"
fi

RUNDIR="$REPO/.fleetflow/$RUN"
MANIFEST="$RUNDIR/manifest.json"
[ -f "$MANIFEST" ] || { err "no manifest at $MANIFEST (run ff-spawn first)"; exit 2; }

# Snapshot the packets ONCE, before replay. ff-spawn upserts each packet on the
# way in (remove-then-append), which REORDERS the live manifest - so re-reading
# .packets[$i] mid-loop would drift and revisit the same packet. The snapshot is
# the replay contract: spawn order = the order captured here, frozen.
PACKETS="$(jq -c '.packets' "$MANIFEST" 2>/dev/null)"
N="$(printf '%s' "$PACKETS" | jq -r 'length' 2>/dev/null)"
[ "${N:-0}" -gt 0 ] 2>/dev/null || { err "manifest has no packets to replay"; exit 2; }

err "resume: replaying $N packet(s) from $MANIFEST (sequential)"
err "  #   id                       brain     status"
err "  --  -----------------------  --------  --------"
RESULTS="[]"
ANY_FAIL=0
i=0
while [ "$i" -lt "$N" ]; do
  pid="$(printf '%s' "$PACKETS" | jq -r ".[$i].id")"
  pbrain="$(printf '%s' "$PACKETS" | jq -r ".[$i].brain")"
  pphase="$(printf '%s' "$PACKETS" | jq -r ".[$i].phase // \"build\"")"
  ppf="$(printf '%s' "$PACKETS" | jq -r ".[$i].prompt_file")"
  pwt="$(printf '%s' "$PACKETS" | jq -r ".[$i].worktree // false")"
  pmt="$(printf '%s' "$PACKETS" | jq -r ".[$i].max_turns // 100")"
  peff="$(printf '%s' "$PACKETS" | jq -r ".[$i].effort // \"\"")"
  psch="$(printf '%s' "$PACKETS" | jq -r ".[$i].schema // \"\"")"
  # worktree is a boolean string ("true"/"false"); both are non-empty, so gate on
  # the literal value rather than ${pwt:+...} (which would always fire).
  WT_FLAG=""; [ "$pwt" = "true" ] && WT_FLAG="1"

  bash "$SPAWN" --run "$RUN" --id "$pid" --brain "$pbrain" --phase "$pphase" \
    --prompt-file "$ppf" --max-turns "$pmt" --repo "$REPO" \
    ${WT_FLAG:+--worktree} ${peff:+--effort "$peff"} ${psch:+--schema "$psch"} \
    >/dev/null 2>>"$RUNDIR/$pid.resume.err"
  rc=$?
  case "$rc" in
    0) status="ran" ;;
    3) status="cached" ;;
    *) status="failed"; ANY_FAIL=1 ;;
  esac
  err "  $((i+1))   $(printf '%-23s' "$pid")  $(printf '%-8s' "$pbrain")  $status${rc:+ (rc=$rc)}"
  RESULTS="$(jq -nc --argjson R "$RESULTS" --arg id "$pid" --arg s "$status" --argjson rc "$rc" \
    '$R + [{id:$id,status:$s,rc:$rc}]')"
  i=$((i+1))
done

RAN="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="ran")]|length')"
CACHED="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="cached")]|length')"
FAILED="$(printf '%s' "$RESULTS" | jq -r '[.[]|select(.status=="failed")]|length')"
err "  --"
err "  summary: $RAN ran, $CACHED cached, $FAILED failed"

printf '%s\n' "$RESULTS"
[ "$ANY_FAIL" = 1 ] && exit 10
exit 0
