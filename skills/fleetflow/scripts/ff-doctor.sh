#!/usr/bin/env bash
# ff-doctor.sh - fleetflow preflight: prove the heterogeneous fleet can run.
#
# --offline (default): structural checks only - binaries, sibling launchers,
#   script syntax. CI-safe, no network.
# --live: additionally probe each provider - GLM endpoint (via fleet-doctor),
#   Codex auth, Anthropic model availability - and report which orchestrator
#   tier is available (fable > opus).
# stdout: one TSV line per check: name<TAB>status<TAB>detail. stderr: chatter.
#
# Exit codes: 0 all required checks ok | 2 usage | 7 live probe unreachable
#             10 structural failure
set -u

usage() {
  cat <<'EOF'
Usage: ff-doctor.sh [--offline | --live]

  --offline   structural checks only (default; CI-safe)
  --live      also probe GLM endpoint, Codex auth, Anthropic models;
              reports orchestrator tier (fable|opus)

EXAMPLES
  ff-doctor.sh --offline
  ff-doctor.sh --live
EOF
}

MODE="offline"
case "${1:-}" in
  --offline|"") MODE="offline" ;;
  --live) MODE="live" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ff-doctor: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

FAIL=0; UNREACH=0
say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- structural ---------------------------------------------------------------
for bin in git jq sha256sum; do
  if command -v "$bin" >/dev/null; then say "bin-$bin" ok "found"; else say "bin-$bin" fail "missing"; FAIL=1; fi
done
if command -v claude >/dev/null; then say "bin-claude" ok "found"; else say "bin-claude" fail "missing"; FAIL=1; fi
if command -v codex >/dev/null; then say "bin-codex" ok "$(codex --version 2>/dev/null | head -1)"; else say "bin-codex" advisory "missing - codex brain unavailable"; fi

FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
if [ -f "$FW" ]; then say "fleet-worker" ok "$FW"; else say "fleet-worker" advisory "not installed - glm brain unavailable"; fi

for s in ff-spawn.sh ff-collect.sh; do
  if bash -n "$HERE/$s" 2>/dev/null; then say "syntax-$s" ok "parses"; else say "syntax-$s" fail "syntax error"; FAIL=1; fi
done
[ -f "$HERE/../assets/guard-preamble.txt" ] && say "guard-preamble" ok "present" || { say "guard-preamble" fail "missing"; FAIL=1; }

[ "$MODE" = "live" ] || { [ "$FAIL" = 0 ] && exit 0 || exit 10; }

# --- live probes ----------------------------------------------------------------
FD="$(dirname "$FW")/fleet-doctor.sh"
if [ -f "$FD" ]; then
  if bash "$FD" --live 2>/dev/null | grep -q "live-ping	ok"; then
    say "glm-endpoint" ok "model resolves"
  else
    say "glm-endpoint" unreachable "fleet-doctor --live did not confirm (key/endpoint)"; UNREACH=1
  fi
else
  say "glm-endpoint" advisory "fleet-doctor not installed"
fi

if command -v codex >/dev/null; then
  if timeout 30 codex login status 2>&1 | grep -qi "logged in"; then
    say "codex-auth" ok "$(timeout 30 codex login status 2>&1 | head -1)"
  else
    say "codex-auth" unreachable "not logged in (codex login)"; UNREACH=1
  fi
fi

ORCH="none"
if command -v claude >/dev/null; then
  for m in claude-fable-5 opus; do
    R="$(timeout 120 claude -p "reply with exactly: ok" --model "$m" --max-turns 1 --output-format json 2>/dev/null)"
    if [ -n "$R" ] && [ "$(printf '%s' "$R" | jq -r 'if has("is_error") then (.is_error|tostring) else "true" end' 2>/dev/null)" = "false" ]; then
      case "$m" in claude-fable-5) ORCH="fable" ;; *) ORCH="opus" ;; esac
      say "model-$m" ok "responds"
      break
    else
      say "model-$m" unavailable "no successful reply"
    fi
  done
fi
say "orchestrator" "$([ "$ORCH" = none ] && echo unreachable || echo ok)" "$ORCH"
[ "$ORCH" = "none" ] && UNREACH=1

if [ "$FAIL" != 0 ]; then exit 10; fi
[ "$UNREACH" != 0 ] && exit 7
exit 0
