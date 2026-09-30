#!/bin/bash
# hooks/pre-install-scan.sh
# PreToolUse hook — surfaces supply-chain hygiene before a dependency install runs.
# Matcher: Bash
#
# The 2026 worm campaign (Shai-Hulud / Mini Shai-Hulud) executes via package
# lifecycle scripts (postinstall, sdist setup.py) the moment you install, and
# poisons brand-new releases that are pulled before any advisory exists. This hook
# recognises install/add verbs and reminds you to scan + respect the release-age
# cooldown, routing through the Socket CLI when available.
#
# Configuration in .claude/settings.json (auto-wired by hooks/hooks.json on
# plugin installs; the tool call arrives as JSON on stdin):
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "hooks": [{ "type": "command", "command": "bash hooks/pre-install-scan.sh" }]
#     }]
#   }
# }
#
# Behaviour:
#   Default          → ADVISORY. One additionalContext JSON envelope on stdout
#                      (the model sees it next to the tool result), exit 0.
#   SUPPLY_CHAIN_BLOCK=1 → HARD GATE. Reason on STDERR, exit 2 (command blocked).
#
# Exit codes:
#   0 = allow (not an install, already wrapped, or advisory mode)
#   2 = block with message (install verb matched AND SUPPLY_CHAIN_BLOCK=1)
# Channel contract tests: tests/hooks.sh

INPUT="$1"
# Modern Claude Code delivers the tool call as JSON on stdin
# ({"tool_input":{"command":"..."}}); older configs pass it as $TOOL_INPUT/$1.
# Support both so the hook works regardless of harness version.
if [[ -z "$INPUT" && ! -t 0 ]]; then
  RAW="$(cat 2>/dev/null)"
  if [[ -n "$RAW" ]] && command -v jq >/dev/null 2>&1; then
    INPUT="$(printf '%s' "$RAW" | jq -r '.tool_input.command // .tool_input // empty' 2>/dev/null)"
  fi
  [[ -z "$INPUT" ]] && INPUT="$RAW"
fi
[[ -z "$INPUT" ]] && exit 0

# Already routed through the behavioural scanner — let it through silently.
echo "$INPUT" | grep -qE '\bsocket\s+(npm|npx|scan|ci|package)\b' && exit 0

# Lockfile-pinned installs are the safer path we recommend — don't nag them.
echo "$INPUT" | grep -qE '\bnpm\s+ci\b|--frozen-lockfile|--locked\b' && exit 0

# ─── Recognise ecosystem install/add verbs ─────────────────────────────────
ECO=""
SAFE=""
if   echo "$INPUT" | grep -qE '\b(npm|pnpm)\s+(install|i|add)\b'; then
  ECO="npm";  SAFE="socket npm install <pkg>   # or: socket wrapper on"
elif echo "$INPUT" | grep -qE '\byarn\s+(add|install)\b'; then
  ECO="npm";  SAFE="socket npm install <pkg>   # yarn has no socket wrapper"
elif echo "$INPUT" | grep -qE '\bbun\s+(add|install)\b'; then
  ECO="npm";  SAFE="socket scan create .       # bun has no socket wrapper"
elif echo "$INPUT" | grep -qE '\b(pip|pip3)\s+install\b'; then
  ECO="pypi"; SAFE="socket scan create .       # no socket pip wrapper exists"
elif echo "$INPUT" | grep -qE '\buv\s+(add|pip\s+install)\b'; then
  ECO="pypi"; SAFE="socket scan create .       # scan the manifest after uv add"
elif echo "$INPUT" | grep -qE '\bpoetry\s+add\b'; then
  ECO="pypi"; SAFE="socket scan create ."
elif echo "$INPUT" | grep -qE '\bcomposer\s+(require|install|update)\b'; then
  ECO="composer"; SAFE="socket scan create .   # composer update re-resolves tags — tag-rewrite risk (Laravel-Lang)"
elif echo "$INPUT" | grep -qE '\bgem\s+install\b'; then
  ECO="rubygems"; SAFE="socket scan create ."
elif echo "$INPUT" | grep -qE '\bcargo\s+(add|install)\b'; then
  ECO="cargo"; SAFE="socket scan create ."
else
  exit 0
fi

# ─── Compose the advisory ──────────────────────────────────────────────────
HAS_SOCKET=0; command -v socket >/dev/null 2>&1 && HAS_SOCKET=1

MSG="SUPPLY CHAIN: dependency install detected (${ECO}).
Lifecycle scripts run on install — the 2026 worm vector. Before proceeding:
  1. Behavioural scan (not just npm audit / pip-audit — those miss fresh malware).
  2. Respect the 7-day release-age cooldown for anything that hits prod/CI."
if [[ "$HAS_SOCKET" -eq 1 ]]; then
  MSG+=$'\n'"  Route it through Socket:  ${SAFE}"
else
  MSG+=$'\n'"  Socket CLI not installed (free):  npm install -g socket"
  MSG+=$'\n'"  Or add depscore MCP (no key):  claude mcp add --transport http socket-mcp https://mcp.socket.dev/"
fi
MSG+=$'\n'"  Cooldown check:  bash skills/supply-chain-defense/scripts/preinstall-check.sh <pkg>"

# ─── Emit ──────────────────────────────────────────────────────────────────
# Guard: do not "simplify" this back to plain echo. For PreToolUse, plain stdout
# on exit 0 goes to the debug log and never reaches the model, and on exit 2
# Claude Code feeds the model STDERR, not stdout ("Exit code 0" / "Exit code 2"
# in https://code.claude.com/docs/en/hooks). The echo-only original was invisible
# on both paths: advisories reached nobody, and the hard gate blocked the agent
# without telling it why. Nothing else may write to stdout, or the JSON stops
# parsing.
if [[ "${SUPPLY_CHAIN_BLOCK:-0}" == "1" ]]; then
  {
    printf '%s\n\n' "$MSG"
    echo "Blocked (SUPPLY_CHAIN_BLOCK=1). Scan the package, then re-run via the Socket"
    echo "wrapper or unset SUPPLY_CHAIN_BLOCK after you've confirmed it's safe."
  } >&2
  exit 2
fi

# No jq, no envelope - stay silent (plain text would only reach the debug log).
command -v jq >/dev/null 2>&1 || exit 0
jq -nc --arg c "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
