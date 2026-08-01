#!/usr/bin/env bash
# ff-doctor.sh - fleetflow preflight: prove the heterogeneous fleet can run.
#
# --offline (default): structural checks only - binaries, sibling launchers,
#   script syntax. CI-safe, no network.
# --live: additionally probe each provider - GLM endpoint (via fleet-doctor),
#   Codex auth, Anthropic model availability - plus the codex windows.sandbox
#   tripwire (config-only, no sandbox provisioned) - and report which
#   orchestrator tier is available (fable > opus).
# stdout: one TSV line per check: name<TAB>status<TAB>detail. stderr: chatter.
#
# Exit codes: 0 all required checks ok | 2 usage | 7 live probe unreachable
#             10 structural failure
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.1.0"

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
GROK="${FLEETFLOW_GROK_BIN:-grok}"
if command -v "$GROK" >/dev/null; then say "bin-grok" ok "$("$GROK" --version 2>/dev/null | head -1)"; else say "bin-grok" advisory "missing - grok brain unavailable"; fi
PIBIN="${FLEETFLOW_PI_BIN:-pi}"
# -f fallback matches ff-spawn: bash runs a .cmd shim but command -v rejects it
if command -v "$PIBIN" >/dev/null || [ -f "$PIBIN" ]; then say "bin-pi" ok "pi $("$PIBIN" --version 2>/dev/null | head -1)"; else say "bin-pi" advisory "missing - pi brain unavailable (set FLEETFLOW_PI_BIN)"; fi

FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
if [ -f "$FW" ]; then say "fleet-worker" ok "$FW"; else say "fleet-worker" advisory "not installed - glm brain unavailable"; fi

# --- which windows.sandbox mode will codex lanes actually get? -----------------
# Config read only (no execution) - the behavioural tripwire is in --live below.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    WSB_EFF="${FLEETFLOW_CODEX_WINDOWS_SANDBOX-unelevated}"
    WSB_HOST="$(sed -n '/^\[windows\]/,/^\[/p' "$HOME/.codex/config.toml" 2>/dev/null \
                | sed -n 's/^[[:space:]]*sandbox[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' | head -1)"
    if [ -z "$WSB_EFF" ]; then
      say "codex-winsandbox-mode" advisory "override disabled - lanes defer to config.toml (${WSB_HOST:-unset}); elevated there = headless hang"
    elif [ "$WSB_EFF" = "elevated" ]; then
      say "codex-winsandbox-mode" advisory "FLEETFLOW_CODEX_WINDOWS_SANDBOX=elevated re-arms the headless UAC trap"
    else
      say "codex-winsandbox-mode" ok "lanes pinned $WSB_EFF (host config: ${WSB_HOST:-unset})"
    fi
    ;;
esac

for s in ff-spawn.sh ff-collect.sh ff-status.sh; do
  if bash -n "$HERE/$s" 2>/dev/null; then say "syntax-$s" ok "parses"; else say "syntax-$s" fail "syntax error"; FAIL=1; fi
done
[ -f "$HERE/../assets/guard-preamble.txt" ] && say "guard-preamble" ok "present" || { say "guard-preamble" fail "missing"; FAIL=1; }

# --- install-sync: repo copy vs the installed copy at $HOME/.claude/skills ---
# version-skew guard. Only compares when an installed copy exists AND is a
# different directory from the one being run (running from the install itself
# trivially matches). Drift is advisory, never a hard fail.
INST="$HOME/.claude/skills/fleetflow/scripts"
if [ -d "$INST" ]; then
  INST_ABS="$(cd "$INST" 2>/dev/null && pwd)"
  if [ -n "$INST_ABS" ] && [ "$INST_ABS" != "$HERE" ]; then
    DIFF=0
    for s in ff-spawn.sh ff-collect.sh ff-status.sh ff-doctor.sh ff-run.sh ff-clean.sh; do
      [ -f "$HERE/$s" ] || continue            # not shipped here; skip
      if [ ! -f "$INST/$s" ]; then DIFF=1; break; fi
      h1="$(sha256sum "$HERE/$s" | cut -d' ' -f1)"
      h2="$(sha256sum "$INST/$s" | cut -d' ' -f1)"
      [ "$h1" = "$h2" ] || { DIFF=1; break; }
    done
    if [ "$DIFF" = 0 ]; then say "install-sync" ok "repo and installed copies match"
    else say "install-sync" advisory "repo and installed copies differ - re-run install"; fi
  else
    say "install-sync" ok "running from the installed copy"
  fi
else
  say "install-sync" advisory "no installed copy at $INST"
fi

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

# --- codex windows.sandbox tripwire (guards the 2026-07-27 elevation hang) -----
# ff-spawn pins `-c windows.sandbox=unelevated` so a headless lane never waits on
# a UAC prompt nobody can approve. That guard fails SILENTLY if codex renames or
# drops the key: `-c` accepts unknown dotted keys without complaint (verified -
# `-c nosuch.key=x` exits 0), so the flag would degrade to an inert no-op and
# lanes would hang again with no signal. We therefore probe the OPPOSITE: feed a
# deliberately invalid value and require codex to reject it, naming the key.
# Rejection proves the key still exists and is still typed; silent acceptance
# means the guard has gone inert and this check is the only thing that will say so.
#
# `codex debug prompt-input` is the probe carrier ON PURPOSE: it only loads and
# validates config (~1.2s, no network, no model call, no API tokens) and - unlike
# `codex sandbox` - it does NOT provision a Windows sandbox. Sandbox provisioning
# is machine-global (~/.codex/.sandbox*) and is the very thing that can trigger
# the elevation helper, so a preflight check must never invoke it. Do not
# "simplify" this to a sandbox or exec call.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v codex >/dev/null; then
      WSB_ERR="$(timeout 60 codex debug prompt-input -c windows.sandbox=ff-doctor-invalid 2>&1 >/dev/null)"
      WSB_RC=$?
      if [ "$WSB_RC" = 124 ]; then
        say "codex-winsandbox" unreachable "config probe timed out"; UNREACH=1
      elif [ "$WSB_RC" != 0 ] && printf '%s' "$WSB_ERR" | grep -q 'windows\.sandbox'; then
        say "codex-winsandbox" ok "key recognised - elevation guard live"
      elif [ "$WSB_RC" != 0 ]; then
        say "codex-winsandbox" advisory "probe failed for another reason: $(printf '%s' "$WSB_ERR" | head -1)"
      else
        say "codex-winsandbox" fail "codex accepts an invalid windows.sandbox - ff-spawn's elevation guard is INERT (key renamed/removed?)"
        FAIL=1
      fi
    fi
    ;;
esac

# grok auth is the GROK_DEPLOYMENT_KEY env var (no login-status subcommand exists,
# and OAuth on some accounts lacks chat entitlement). We probe key PRESENCE, not
# validity - a real chat call would burn quota. Only when the binary is installed.
if command -v "$GROK" >/dev/null; then
  if [ -n "${GROK_DEPLOYMENT_KEY:-}" ]; then
    say "grok-auth" ok "GROK_DEPLOYMENT_KEY set"
  else
    say "grok-auth" unreachable "GROK_DEPLOYMENT_KEY not set (deployment key required)"; UNREACH=1
  fi
fi

# pi lanes run with an ISOLATED PI_CODING_AGENT_DIR (ff-spawn), so the host's
# ~/.pi/agent/auth.json never applies - the provider's API key env var is the
# lane's ONLY auth. Probe key PRESENCE for the configured provider, not
# validity (a real call would burn quota, same doctrine as grok-auth).
if command -v "$PIBIN" >/dev/null || [ -f "$PIBIN" ]; then
  PIPROV="${FLEETFLOW_PI_PROVIDER:-}"
  if [ -z "$PIPROV" ]; then
    say "pi-auth" advisory "FLEETFLOW_PI_PROVIDER not set - pi lanes would use pi's default provider with no key check"
  else
    case "$PIPROV" in
      anthropic)  PIKEY="ANTHROPIC_API_KEY" ;;
      openai)     PIKEY="OPENAI_API_KEY" ;;
      google)     PIKEY="GEMINI_API_KEY" ;;
      zai)        PIKEY="ZAI_API_KEY" ;;
      groq)       PIKEY="GROQ_API_KEY" ;;
      xai)        PIKEY="XAI_API_KEY" ;;
      deepseek)   PIKEY="DEEPSEEK_API_KEY" ;;
      mistral)    PIKEY="MISTRAL_API_KEY" ;;
      openrouter) PIKEY="OPENROUTER_API_KEY" ;;
      cerebras)   PIKEY="CEREBRAS_API_KEY" ;;
      *)          PIKEY="" ;;
    esac
    if [ -z "$PIKEY" ]; then
      say "pi-auth" advisory "no env-key mapping for provider '$PIPROV' - lane auth unverified"
    elif [ -n "$(eval "printf '%s' \"\${$PIKEY:-}\"")" ]; then
      say "pi-auth" ok "$PIKEY set (provider $PIPROV)"
    else
      say "pi-auth" unreachable "$PIKEY not set (provider $PIPROV; host auth.json does not reach lanes)"; UNREACH=1
    fi
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
