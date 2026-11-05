#!/usr/bin/env bash
# Confirm hosted-sandbox boxes are really gone after a delete, without deleting anything.
#
# Usage:   confirm-gone.sh [--provider P] [--timeout S] [--interval S] [--json] <id>...
# Input:   box ids in argv. --provider is boat (default), e2b, vercel, daytona or fly
#          (Modal has no CLI list: confirm it in its SDK). boat ids are bx_ + lowercase
#          letters/digits; others letters, digits, _ and -. The CLI comes from BOAT_BIN /
#          E2B_BIN / VERCEL_SANDBOX_BIN / DAYTONA_BIN / FLY_BIN, else `boat` / `e2b` /
#          `sandbox` / `daytona` / `fly` on PATH. fly reads its app from FLY_APP. Needs jq.
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
# Other providers have no per-id read this script relies on, so "gone" means the id no
# longer appears anywhere in the provider's widest list, polled until --timeout:
#   e2b      e2b sandbox list --state running,paused --format json   (paused never expire)
#   vercel   sandbox list -a                                         (plain list hides stopped)
#   daytona  daytona list -f json
#   fly      fly machine list --json                                 (app from FLY_APP)
# Any appearance of the id counts as present, so a reshaped output can only err towards
# "present", never towards a false "gone". A list that never succeeds is exit 7.
#
# Examples:
#   confirm-gone.sh bx_ab12cd34
#   confirm-gone.sh --provider e2b --timeout 30 i3abc123def
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

TIMEOUT=90; INTERVAL=2; JSON=0; IDS=(); PROVIDER=boat
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) PROVIDER="${2:-}"; shift ;;
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
case "$PROVIDER" in
  boat|e2b|vercel|daytona|fly) ;;
  modal) echo "confirm-gone.sh: Modal has no CLI list; confirm with sb.poll() or Sandbox.list in its SDK" >&2; exit "$EXIT_USAGE" ;;
  *) echo "confirm-gone.sh: unknown provider '$PROVIDER' (boat, e2b, vercel, daytona, fly)" >&2; exit "$EXIT_USAGE" ;;
esac
[ "${#IDS[@]}" -gt 0 ] || { echo "confirm-gone.sh: no box id given (try --help)" >&2; exit "$EXIT_USAGE"; }
for id in "${IDS[@]}"; do
  # ids are passed to the CLI as argv, but validate anyway: an agent may hand us anything
  if [ "$PROVIDER" = boat ]; then
    [[ "$id" =~ ^bx_[a-z0-9]+$ ]] || { echo "confirm-gone.sh: not a boat box id: '$id'" >&2; exit "$EXIT_USAGE"; }
  else
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo "confirm-gone.sh: not a $PROVIDER id: '$id'" >&2; exit "$EXIT_USAGE"; }
  fi
done
command -v jq >/dev/null 2>&1 \
  || { echo "confirm-gone.sh: jq not found (install jq: https://jqlang.org/download/)" >&2; exit "$EXIT_PRECONDITION"; }

# emit <id> <gone:true|false> <info> <listed:true|false> -- one result row, TSV or JSON
rows=""
emit() {
  if [ "$JSON" = 1 ]; then
    rows="${rows:+$rows,}$(jq -nc --arg id "$1" --argjson gone "$2" --arg info "$3" --argjson listed "$4" \
      '{id:$id, gone:$gone, info:$info, listed:$listed}')"
  else
    printf '%s\t%s\n' "$1" "$([ "$2" = true ] && echo gone || echo present)"
  fi
}
envelope() { # present-count
  [ "$JSON" = 1 ] || return 0
  jq -n --argjson data "[$rows]" --argjson present "$1" --arg provider "$PROVIDER" \
    '{data:$data, meta:{provider:$provider, count:($data|length), present:$present, schema:"claude-mods.sandbox-ops.confirm-gone/v1"}}'
}

# === Providers other than boat: the id must vanish from the widest list ===
if [ "$PROVIDER" != boat ]; then
  case "$PROVIDER" in
    e2b)     var=E2B_BIN;            cmd=e2b;     args=(sandbox list --state running,paused --format json) ;;
    vercel)  var=VERCEL_SANDBOX_BIN; cmd=sandbox; args=(list -a) ;;
    daytona) var=DAYTONA_BIN;        cmd=daytona; args=(list -f json) ;;
    fly)     var=FLY_BIN;            cmd=fly;     args=(machine list --json) ;;
  esac
  CLI="${!var:-$(command -v "$cmd" 2>/dev/null || true)}"
  [ "$PROVIDER" = fly ] && [ -z "$CLI" ] && CLI="$(command -v flyctl 2>/dev/null || true)"
  [ -n "$CLI" ] && [ -f "$CLI" ] \
    || { echo "confirm-gone.sh: $cmd CLI not found (set $var or put $cmd on PATH)" >&2; exit "$EXIT_PRECONDITION"; }
  answered=0; waited=0; listed=""
  while :; do
    if out="$(MSYS_NO_PATHCONV=1 "$CLI" "${args[@]}" 2>/dev/null)"; then
      answered=1; listed="$(tr -d '\r' <<<"$out")"
      still=0
      for id in "${IDS[@]}"; do grep -qF -- "$id" <<<"$listed" && still=1; done
      [ "$still" = 0 ] && break
    fi
    [ "$waited" -ge "$TIMEOUT" ] && break
    sleep "$INTERVAL"; waited=$((waited + INTERVAL))
  done
  if [ "$answered" = 0 ]; then
    say warn "$cmd ${args[*]} never answered: cannot confirm ($PROVIDER unreachable?)"
    exit "$EXIT_UNAVAILABLE"
  fi
  present=0
  for id in "${IDS[@]}"; do
    # Here-string, not a pipe: see the pipefail note in the boat path below.
    if grep -qF -- "$id" <<<"$listed"; then
      present=$((present + 1)); say bad "$id: $cmd ${args[*]} still shows it"; emit "$id" false skipped true
    else emit "$id" true skipped false; fi
  done
  envelope "$present"
  [ "$present" -gt 0 ] && { say bad "$present of ${#IDS[@]} box(es) not confirmed gone"; exit "$EXIT_PRESENT"; }
  say ok "${#IDS[@]} box(es) confirmed gone (absent from $cmd ${args[*]})"
  exit "$EXIT_OK"
fi

# === boat: info answers not_found AND list --all no longer shows it ===
BOAT="${BOAT_BIN:-$(command -v boat 2>/dev/null || true)}"
[ -n "$BOAT" ] && [ -f "$BOAT" ] \
  || { echo "confirm-gone.sh: boat CLI not found (set BOAT_BIN or put boat on PATH)" >&2; exit "$EXIT_PRECONDITION"; }
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

present=0; unanswered=0; i=0
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
  emit "$id" "$gone" "$info" "$in_list"
done
envelope "$present"

if [ "$present" -gt 0 ]; then
  # Every unlisted box that never answered info is an outage, not a finding.
  [ "$unanswered" -eq "$present" ] && { say warn "boat info never answered: cannot confirm"; exit "$EXIT_UNAVAILABLE"; }
  say bad "$present of ${#IDS[@]} box(es) not confirmed gone"
  exit "$EXIT_PRESENT"
fi
say ok "${#IDS[@]} box(es) confirmed gone (info not_found, absent from list --all)"
exit "$EXIT_OK"
