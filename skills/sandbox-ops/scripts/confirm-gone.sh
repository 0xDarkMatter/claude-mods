#!/usr/bin/env bash
# Confirm boat.dev boxes are really gone after `boat delete`, without deleting anything.
#
# Usage:   confirm-gone.sh [--timeout S] [--interval S] [--json] <bx_id>...
# Input:   box ids in argv (bx_ + lowercase letters/digits). BOAT_BIN = the boat CLI
#          (default: `boat` on PATH). Needs jq.
# Output:  stdout = one TSV row per id, "<id><TAB>gone|present", or with --json the
#          envelope {data:[{id, gone, info, listed}], meta:{...}}. Data only.
# Stderr:  progress, the verdict line, errors.
# Exit:    0 every id gone, 2 usage, 5 no boat CLI or no jq,
#          7 boat unreachable (list --all failed, or info never answered for a box
#          that list --all does not show),
#          10 at least one box is still there (domain signal: delete it or look again)
#
# "Gone" means both of fleetflow's checks (scripts/hosts/boat.sh `down`): `boat info
# <id> --json` answers code "not_found", AND `boat list --all --json` no longer lists
# the id. Plain `boat list` shows only running boxes, so it would miss a stopped one.
# Delete is asynchronous, so info is polled until --timeout (default 90 s, as the
# driver does). This script only ever calls `info` and `list`, always with --no-update
# (the CLI self-updates after a command otherwise).
#
# A box that list --all shows is present (exit 10) even if info never answered: an
# outage must not hide a box known to exist. "Gone" holds only in the scope it ran in:
# run it under the same account and BOAT_ORG / BOAT_API_KEY as the create, or a live
# box in another scope can look missing. Bash 3.2 (macOS) safe: no associative arrays.
#
# Examples:
#   confirm-gone.sh bx_ab12cd34
#   confirm-gone.sh --timeout 30 bx_ab12cd34 bx_ef56gh78
#   confirm-gone.sh --json bx_ab12cd34 | jq '.data[] | select(.gone | not)'
set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_PRECONDITION=5; EXIT_UNAVAILABLE=7; EXIT_PRESENT=10

# Terminal design system (skills/_lib/term.sh): framing rides stderr; stdout stays data.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; fi
say() { # state text
  if [ "$__HAVE_TERM" = 1 ]; then
    case "$1" in ok) term_color green "$2" ;; bad) term_color red "$2" ;; *) term_color yellow "$2" ;; esac >&2
    echo >&2
  else echo "$2" >&2; fi
}

TIMEOUT=90; INTERVAL=2; JSON=0; IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)  TIMEOUT="${2:-}"; shift ;;
    --interval) INTERVAL="${2:-}"; shift ;;
    --json)     JSON=1 ;;
    -h|--help)  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "$EXIT_OK" ;;
    -*)         echo "confirm-gone.sh: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)          IDS+=("$1") ;;
  esac
  shift
done
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[1-9][0-9]*$ ]] \
  || { echo "confirm-gone.sh: --timeout and --interval take whole seconds" >&2; exit "$EXIT_USAGE"; }
[ "${#IDS[@]}" -gt 0 ] || { echo "confirm-gone.sh: no box id given (try --help)" >&2; exit "$EXIT_USAGE"; }
for id in "${IDS[@]}"; do
  # ids are passed to the CLI as argv, but validate anyway: an agent may hand us anything
  [[ "$id" =~ ^bx_[a-z0-9]+$ ]] || { echo "confirm-gone.sh: not a boat box id: '$id'" >&2; exit "$EXIT_USAGE"; }
done

BOAT="${BOAT_BIN:-$(command -v boat 2>/dev/null || true)}"
[ -n "$BOAT" ] && [ -f "$BOAT" ] \
  || { echo "confirm-gone.sh: boat CLI not found (set BOAT_BIN or put boat on PATH)" >&2; exit "$EXIT_PRECONDITION"; }
command -v jq >/dev/null 2>&1 \
  || { echo "confirm-gone.sh: jq not found (install jq: https://jqlang.org/download/)" >&2; exit "$EXIT_PRECONDITION"; }
# MSYS_NO_PATHCONV: Git Bash would rewrite path-like args before boat.exe sees them.
b() { MSYS_NO_PATHCONV=1 "$BOAT" --no-update "$@"; }

INFO=()   # indexed, in argv order: bash 3.2 has no associative arrays
for id in "${IDS[@]}"; do
  state="no-answer"; waited=0
  while :; do
    # info exits non-zero for a missing box, so read its JSON, not its exit code.
    # Windows jq.exe prints CRLF: strip it from every capture.
    out="$(b info "$id" --json 2>/dev/null)"
    code="$(printf '%s' "$out" | jq -r '.code // .error.code // empty' 2>/dev/null | tr -d '\r')"
    if [ "$code" = "not_found" ]; then state="not_found"; break; fi
    s="$(printf '%s' "$out" | jq -r '(.sandbox // .).state // empty' 2>/dev/null | tr -d '\r')"
    [ -n "$s" ] && state="$s"
    [ "$waited" -ge "$TIMEOUT" ] && break
    sleep "$INTERVAL"; waited=$((waited + INTERVAL))
  done
  INFO+=("$state")
  [ "$state" = "not_found" ] && say ok "$id: info answers not_found" || say bad "$id: still answers info (state $state) after ${TIMEOUT}s"
done

rc=0; listed_json="$(b list --all --json 2>/dev/null)" || rc=$?
listed="$(printf '%s' "$listed_json" | jq -r '.sandboxes[]?.id' 2>/dev/null | tr -d '\r')" || rc=1
if [ "$rc" -ne 0 ] || ! printf '%s' "$listed_json" | jq -e 'has("sandboxes")' >/dev/null 2>&1; then
  say warn "boat list --all failed: cannot confirm (boat unreachable?)"
  exit "$EXIT_UNAVAILABLE"
fi

present=0; unanswered=0; rows=""; i=0
for id in "${IDS[@]}"; do
  info="${INFO[$i]}"; i=$((i + 1))
  in_list=false
  # Here-string, never `printf | grep -q`: under pipefail grep exits at the first match,
  # printf takes SIGPIPE, the pipeline fails and a still-listed box reads as gone.
  grep -qx "$id" <<<"$listed" && in_list=true
  gone=false
  [ "$info" = "not_found" ] && [ "$in_list" = false ] && gone=true
  [ "$gone" = true ] || present=$((present + 1))
  [ "$info" = "no-answer" ] && [ "$in_list" = false ] && unanswered=$((unanswered + 1))
  [ "$in_list" = true ] && say bad "$id: boat list --all still shows it"
  if [ "$JSON" = 1 ]; then
    rows="${rows:+$rows,}$(jq -nc --arg id "$id" --arg info "$info" --argjson gone "$gone" --argjson listed "$in_list" \
      '{id:$id, gone:$gone, info:$info, listed:$listed}')"
  else
    printf '%s\t%s\n' "$id" "$([ "$gone" = true ] && echo gone || echo present)"
  fi
done
if [ "$JSON" = 1 ]; then
  jq -n --argjson data "[$rows]" --argjson present "$present" \
    '{data:$data, meta:{count:($data|length), present:$present, schema:"claude-mods.sandbox-ops.confirm-gone/v1"}}'
fi

if [ "$present" -gt 0 ]; then
  # Every unlisted box that never answered info is an outage, not a finding.
  [ "$unanswered" -eq "$present" ] && { say warn "boat info never answered: cannot confirm"; exit "$EXIT_UNAVAILABLE"; }
  say bad "$present of ${#IDS[@]} box(es) not confirmed gone"
  exit "$EXIT_PRESENT"
fi
say ok "${#IDS[@]} box(es) confirmed gone (info not_found, absent from list --all)"
exit "$EXIT_OK"
