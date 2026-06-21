#!/usr/bin/env bash
# fleet-doctor.sh - preflight + staleness verifier for the fleet-worker skill.
#
# Two modes (SKILL-RESOURCE-PROTOCOL sec 7):
#   --offline (default): structural / internal-consistency only, NO network.
#                        Asserts the launcher parses, and that the model + endpoint
#                        baked into the launcher are also documented in SKILL.md
#                        (a drift tripwire - bump the launcher, forget the doc -> fail).
#                        Safe for PR CI.
#   --live:              pings the configured Anthropic-compatible endpoint with the
#                        configured model. 200 = model still resolves. No key /
#                        unreachable / rate-limited = UNAVAILABLE (advisory, never a
#                        build failure). A 404 = DRIFT (endpoint/model path gone).
#
# Both modes also print non-fatal PREFLIGHT advisories: whether `claude` is on
# PATH, and whether the host ~/.claude.json carries an oauthAccount (the cause of
# the 401 trap that CLAUDE_CONFIG_DIR isolation fixes - see spec sec 4).
#
# Usage:   fleet-doctor.sh [--offline|--live] [--json] [-q]
# Output:  stdout = data only (TSV rows, or a --json envelope)
# Stderr:  panel framing / human status (term.sh)
# Exit:    0 ok; 2 usage; 4 launcher malformed; 5 missing dep / launcher absent;
#          7 unavailable (live: no key / endpoint unreachable);
#          10 drift (offline: doc/launcher mismatch | live: model 404)
#
# Examples:
#   fleet-doctor.sh --offline
#   FLEET_WORKER_KEYRING_SERVICE=mysvc FLEET_WORKER_KEYRING_KEY=glm fleet-doctor.sh --live
#   fleet-doctor.sh --offline --json | jq '.data[] | select(.status!="ok")'
set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_MALFORMED=4; EXIT_MISSING_DEP=5
EXIT_UNAVAILABLE=7; EXIT_DRIFT=10

# Terminal design system (skills/_lib/term.sh). Framing rides stderr (term_init 2);
# data rows / --json stay plain on stdout. Degrade gracefully if the lib is gone.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; TERM_DOT="|"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/fleet-worker"
SKILL_MD="$SCRIPT_DIR/../SKILL.md"
ASSET_SETTINGS="$SCRIPT_DIR/../assets/worker-settings.json"

MODE="offline"; JSON=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) MODE="offline" ;;
    --live)    MODE="live" ;;
    --json)    JSON=1 ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "$EXIT_OK" ;;
    -*) echo "fleet-doctor.sh: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)  echo "fleet-doctor.sh: unexpected argument: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
done

command -v grep >/dev/null 2>&1 || { echo "fleet-doctor.sh: grep required" >&2; exit "$EXIT_MISSING_DEP"; }
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
[ "$JSON" -eq 1 ] && [ "$HAS_JQ" -eq 0 ] && {
  echo '{"error":{"code":"PRECONDITION","message":"jq required for --json"}}'
  echo "fleet-doctor.sh: jq required for --json" >&2; exit "$EXIT_MISSING_DEP"; }

# Panel framing on the human stream (TTY or FORCE_COLOR); piped/quiet -> tagged lines.
PANEL=0
if [ "$__HAVE_TERM" -eq 1 ] && [ "$QUIET" -eq 0 ] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi
__PANEL_OPEN=0
popen() {
  [ "$PANEL" -eq 1 ] && [ "$__PANEL_OPEN" -eq 0 ] || return 0
  { term_panel_open claude "fleet-worker doctor ${TERM_DOT} ${MODE}"; term_panel_vert; } >&2
  __PANEL_OPEN=1
}
emit() { [ "$QUIET" -eq 1 ] && return; printf '%s\n' "$1" >&2; }
# prow <mark> <legacy-prefix> <label> - panel status row, or the legacy tagged line.
prow() {
  if [ "$PANEL" -eq 1 ]; then popen; term_status_row "$1" "$3" >&2
  else emit "  $2 $3"; fi
}

declare -a JSON_OBJS=()
declare -a TEXT_ROWS=()
add_row() { # check status detail
  TEXT_ROWS+=("$1	$2	$3")
  [ "$HAS_JQ" -eq 1 ] && JSON_OBJS+=("$(jq -cn --arg c "$1" --arg s "$2" --arg d "$3" \
    '{check:$c, status:$s, detail:$d}')")
}

[ "$PANEL" -eq 1 ] && popen || emit "=== fleet-doctor (${MODE}) ==="

drift=0; malformed=0; missing=0; unavailable=0

# -- Preflight advisories (never change exit code) --------------------------
if command -v claude >/dev/null 2>&1; then
  prow ok "[ok]" "claude on PATH"; add_row claude-on-path ok "found"
else
  prow warn "[advisory]" "claude (Claude Code) not on PATH - workers cannot run here"
  add_row claude-on-path advisory "not found"
fi
__hostcfg="${HOME:-}/.claude.json"
if [ -f "$__hostcfg" ] && grep -q '"oauthAccount"' "$__hostcfg" 2>/dev/null; then
  prow warn "[advisory]" "host ~/.claude.json has oauthAccount - workers MUST use an isolated CLAUDE_CONFIG_DIR (spec sec 4)"
  add_row host-oauth-trap advisory "oauthAccount present"
else
  prow ok "[ok]" "no host oauthAccount trap detected"; add_row host-oauth-trap ok "clean"
fi

# -- Launcher presence + syntax ---------------------------------------------
if [ ! -f "$LAUNCHER" ]; then
  prow bad "[MISSING]" "launcher not found: $LAUNCHER"; add_row launcher-present missing "$LAUNCHER"
  missing=1
elif ! bash -n "$LAUNCHER" 2>/dev/null; then
  prow bad "[MALFORMED]" "launcher has a bash syntax error"; add_row launcher-syntax malformed "bash -n failed"
  malformed=1
else
  prow ok "[ok]" "launcher present and parses"; add_row launcher-syntax ok "bash -n clean"
fi

# -- Asset settings is valid JSON -------------------------------------------
if [ -f "$ASSET_SETTINGS" ]; then
  if [ "$HAS_JQ" -eq 1 ] && ! jq -e . "$ASSET_SETTINGS" >/dev/null 2>&1; then
    prow bad "[MALFORMED]" "worker-settings.json is not valid JSON"; add_row asset-settings malformed "invalid"
    malformed=1
  else
    prow ok "[ok]" "worker-settings.json present"; add_row asset-settings ok "valid"
  fi
fi

# -- Extract launcher defaults (model / small model / endpoint) -------------
def_model=""; def_small=""; def_url=""
if [ -f "$LAUNCHER" ]; then
  def_model="$(grep -oE 'FLEET_WORKER_MODEL:-[A-Za-z0-9._-]+' "$LAUNCHER" | head -1 | sed 's/^FLEET_WORKER_MODEL:-//')"
  def_small="$(grep -oE 'FLEET_WORKER_SMALL_MODEL:-[A-Za-z0-9._-]+' "$LAUNCHER" | head -1 | sed 's/^FLEET_WORKER_SMALL_MODEL:-//')"
  def_url="$(grep -oE 'FLEET_WORKER_BASE_URL:-[^}\"]+' "$LAUNCHER" | head -1 | sed 's/^FLEET_WORKER_BASE_URL:-//')"
fi

# -- Offline: launcher defaults must be documented in SKILL.md (drift tripwire)
if [ "$MODE" = "offline" ]; then
  if [ -f "$SKILL_MD" ]; then
    for pair in "model:$def_model" "small-model:$def_small" "endpoint:$def_url"; do
      label="${pair%%:*}"; val="${pair#*:}"
      [ -z "$val" ] && continue
      if grep -qF -- "$val" "$SKILL_MD"; then
        prow ok "[ok]" "SKILL.md documents $label ($val)"; add_row "doc-$label" ok "$val"
      else
        prow bad "[DRIFT]" "launcher $label '$val' is NOT documented in SKILL.md"
        add_row "doc-$label" drift "$val"; drift=1
      fi
    done
  else
    prow warn "[advisory]" "SKILL.md not found beside scripts/ - skipping doc-consistency"
    add_row skill-md advisory "not found"
  fi
fi

# -- Live: does the configured model still resolve at the endpoint? ---------
if [ "$MODE" = "live" ]; then
  command -v curl >/dev/null 2>&1 || { echo "fleet-doctor.sh: curl required for --live" >&2; exit "$EXIT_MISSING_DEP"; }
  url="${FLEET_WORKER_BASE_URL:-${def_url:-https://api.z.ai/api/anthropic}}"
  model="${FLEET_WORKER_MODEL:-${def_model:-GLM-5.2}}"
  # Resolve key without echoing it.
  key=""
  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then key="$ANTHROPIC_AUTH_TOKEN"
  elif [ -n "${FLEET_WORKER_KEYRING_SERVICE:-}" ] && [ -n "${FLEET_WORKER_KEYRING_KEY:-}" ] && command -v keyring >/dev/null 2>&1; then
    key="$(keyring get "$FLEET_WORKER_KEYRING_SERVICE" "$FLEET_WORKER_KEYRING_KEY" 2>/dev/null | tr -d '\r\n')"
  elif [ -n "${ZHIPU_API_KEY:-}" ]; then key="$ZHIPU_API_KEY"
  elif [ -n "${GLM_API_KEY:-}" ]; then key="$GLM_API_KEY"
  fi
  if [ -z "$key" ]; then
    prow warn "[unavailable]" "no API key resolved - cannot run --live (advisory)"
    add_row live-ping unavailable "no key"; unavailable=1
  else
    body="$(printf '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' "$model")"
    code="$(curl -sS -o /dev/null -m 25 -w '%{http_code}' -X POST "${url%/}/v1/messages" \
      -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
      -H "x-api-key: ${key}" --data "$body" 2>/dev/null || echo 000)"
    case "$code" in
      200)
        prow ok "[ok]" "model $model resolves at ${url} (HTTP 200)"; add_row live-ping ok "$model" ;;
      404)
        prow bad "[DRIFT 404]" "model/endpoint not found: $model @ ${url}"; add_row live-ping drift "$model"; drift=1 ;;
      000|401|403|408|429|5??)
        prow warn "[unavailable]" "endpoint unreachable / not authorized / overloaded (HTTP $code)"
        add_row live-ping unavailable "HTTP $code"; unavailable=1 ;;
      *)
        prow warn "[unavailable]" "unexpected response (HTTP $code) - treating as advisory"
        add_row live-ping unavailable "HTTP $code"; unavailable=1 ;;
    esac
  fi
fi

# -- Panel footer -----------------------------------------------------------
if [ "$PANEL" -eq 1 ] && [ "$__PANEL_OPEN" -eq 1 ]; then
  ph_state="healthy"; ph_text="all checks pass"
  if [ "$missing" -eq 1 ] || [ "$malformed" -eq 1 ]; then ph_state="critical"; ph_text="skill broken"
  elif [ "$drift" -eq 1 ]; then ph_state="critical"; ph_text="drift detected"
  elif [ "$unavailable" -eq 1 ]; then ph_state="warning"; ph_text="endpoint advisory"; fi
  { term_panel_vert
    term_panel_close "--live to ping endpoint ${TERM_DOT} --json for data" "$(term_health "$ph_state" "$ph_text")"
  } >&2
fi

# -- Output (data on stdout) ------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "${JSON_OBJS[@]:-}" | jq -s \
    --arg mode "$MODE" \
    '{data: map(select(length>0)),
      meta: {mode:$mode, count:(map(select(length>0))|length),
             schema:"claude-mods.fleet-worker.doctor/v1"}}'
else
  for row in "${TEXT_ROWS[@]:-}"; do [ -n "$row" ] && printf '%s\n' "$row"; done
fi

# -- Exit (precedence: broken > drift > unavailable) ------------------------
[ "$missing" -eq 1 ]   && exit "$EXIT_MISSING_DEP"
[ "$malformed" -eq 1 ] && exit "$EXIT_MALFORMED"
[ "$drift" -eq 1 ]     && exit "$EXIT_DRIFT"
[ "$unavailable" -eq 1 ] && exit "$EXIT_UNAVAILABLE"
exit "$EXIT_OK"
