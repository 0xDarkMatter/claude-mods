#!/bin/bash
# hooks/manifest-dep-scan.sh
# PostToolUse hook (matcher: Write|Edit) — the companion to pre-install-scan.sh.
#
# pre-install-scan covers `npm install` at the terminal. But in Claude Code the
# dominant way a dependency enters is the agent EDITING a manifest (package.json,
# requirements.txt, …) directly — no install command, so that hook never fires.
# This hook closes that gap: when a dependency manifest is edited and the change
# looks like it added/changed a version spec, it advises scoring the package via the
# Socket depscore MCP and respecting the release-age cooldown BEFORE it gets installed.
#
# Advisory only (exit 0); never blocks an edit. Reads the tool call as JSON on stdin
# (.tool_input.file_path / .new_string / .content), with a $1 fallback.
#
# Configuration in .claude/settings.json:
#   "PostToolUse": [{ "matcher": "Write|Edit", "hooks": [
#     { "type": "command", "command": "bash \"$HOME/.claude/hooks/manifest-dep-scan.sh\"", "timeout": 5 } ]}]

RAW=""; [[ ! -t 0 ]] && RAW="$(cat 2>/dev/null)"
FILE=""; NEW=""
if [[ -n "$RAW" ]] && command -v jq >/dev/null 2>&1; then
  FILE="$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  NEW="$(printf '%s' "$RAW" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null)"
fi
[[ -z "$FILE" ]] && FILE="${1:-}"
[[ -z "$FILE" ]] && exit 0

case "$(basename "$FILE")" in
  package.json|composer.json|Cargo.toml|go.mod|Gemfile|pyproject.toml) ;;
  requirements*.txt) ;;
  *) exit 0 ;;
esac

# Only nudge when the change looks like a dependency version spec was added/changed —
# avoids firing on unrelated manifest edits (scripts, version bumps, metadata).
if [[ -n "$NEW" ]]; then
  # Find version-spec lines, then exclude the manifest's own metadata keys so a
  # `"version": "2.0.0"` bump or `name`/`description` edit doesn't false-fire.
  echo "$NEW" \
    | grep -E ':[[:space:]]*"[[:space:]~^><=v]*[0-9]|==[[:space:]]*[0-9]|=[[:space:]]*"[0-9]|[[:space:]]v?[0-9]+\.[0-9]' \
    | grep -qvE '"(version|name|description|license|homepage|repository|author|main|type)"[[:space:]]*:' \
    || exit 0
fi

echo "SUPPLY CHAIN: dependency manifest edited ($(basename "$FILE"))."
echo "A dependency was added/changed by editing the manifest — it still has to be"
echo "installed. Before that, score it and respect the release-age cooldown:"
echo "  - depscore (no auth): score the added package(s) via the socket MCP"
echo "  - cooldown/age: bash skills/supply-chain-defense/scripts/preinstall-check.sh <pkg>"
echo "  - never pull a day-zero version into anything that builds/runs."
exit 0
