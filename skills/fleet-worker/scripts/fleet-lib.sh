# fleet-lib.sh - shared defaults + key resolution for fleet-worker and fleet-doctor.
#
# SOURCED, never executed. The ONLY place the endpoint/model defaults and the
# API-key resolution chain live. The launcher and the doctor both source it, so
# the doctor can never again bless a key or model the launcher would not use.
#
# Why this file exists (2026-10-02): the doctor carried its own if/elif copy of
# the key chain. With FLEET_WORKER_KEYRING_SERVICE/KEY set but the keyring entry
# EMPTY, that copy took the keyring branch, got "", and never fell through to
# ZHIPU_API_KEY - so `--live` reported "no API key" (fleetflow: glm-endpoint
# unreachable, rc=7) on a host where the launcher ran fine. tests/run.sh asserts
# there is exactly one `keyring get` across scripts/ - do not inline a copy.
#
# Bash only. fleet-worker.ps1 cannot source this; it mirrors the chain and the
# defaults by hand, so a change here is a change there too.

# Model ids are the provider's canonical lowercase form (z.ai documents glm-*).
# Claude Code 2.1.280 prints `[claude-code:unrecognized_model]` on stderr for ANY
# id outside its catalog, either casing - that line is a notice, not a failure.
FW_DEFAULT_BASE_URL="https://api.z.ai/api/anthropic"
FW_DEFAULT_MODEL="glm-5.3"
FW_DEFAULT_SMALL_MODEL="glm-4.5-air"

# fw_resolve_key - print the API key on stdout (no newline); return 1 if none.
# Callers capture it into a variable and must never echo it. Order:
#   1. ANTHROPIC_AUTH_TOKEN                                  -> as-is
#   2. FLEET_WORKER_KEYRING_SERVICE + _KEY, `keyring` on PATH -> `keyring get`
#      (an EMPTY result falls through - it is not a resolved key)
#   3. ZHIPU_API_KEY, then GLM_API_KEY                       -> as-is
fw_resolve_key() {
  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then printf '%s' "$ANTHROPIC_AUTH_TOKEN"; return 0; fi
  if [ -n "${FLEET_WORKER_KEYRING_SERVICE:-}" ] && [ -n "${FLEET_WORKER_KEYRING_KEY:-}" ] \
     && command -v keyring >/dev/null 2>&1; then
    local k
    k="$(keyring get "$FLEET_WORKER_KEYRING_SERVICE" "$FLEET_WORKER_KEYRING_KEY" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  fi
  if [ -n "${ZHIPU_API_KEY:-}" ]; then printf '%s' "$ZHIPU_API_KEY"; return 0; fi
  if [ -n "${GLM_API_KEY:-}" ];   then printf '%s' "$GLM_API_KEY";   return 0; fi
  return 1
}
