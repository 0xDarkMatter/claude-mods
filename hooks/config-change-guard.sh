#!/bin/bash
# hooks/config-change-guard.sh
# ConfigChange hook — single-file worm-persistence scan when a Claude settings
# file changes mid-session.
#
# The 2026 worm family (Shai-Hulud / Mini Shai-Hulud) persists by injecting
# hooks / mcpServers entries into Claude Code and editor settings. The full
# sweep is skills/supply-chain-defense/scripts/integrity-audit.sh; this hook is
# the fast inline tripwire: when the harness reports a settings change, scan
# JUST that file for the same vetted IOC patterns (curl|sh, base64 -d eval,
# Invoke-Expression+Download, /dev/tcp, reads of .claude/settings or
# .aws/credentials).
#
# Event contract (verified against https://code.claude.com/docs/en/hooks):
#   ConfigChange stdin payload carries common fields (cwd, hook_event_name, …)
#   plus `source`: user_settings | project_settings | local_settings |
#   policy_settings | skills. There is NO file_path field — we map source to
#   the file ourselves. We still read .file_path if a future harness adds it,
#   and accept a file path as $1 for manual/offline testing.
#
#   NOTE: ConfigChange does NOT fire for VS Code settings.json or ~/.claude.json
#   — those persistence surfaces are covered by the periodic integrity-audit.sh
#   sweep, not by this event. policy_settings can't be blocked (harness rule)
#   and `skills` has no single file → both are silently skipped.
#
# Behaviour (silent guardian — rules/prompt-injection.md noise discipline):
#   clean              → no output, exit 0
#   IOC found          → ADVISORY: JSON on stdout carrying a desktop notification
#                        (terminalSequence) + systemMessage, exit 0
#   + SUPPLY_CHAIN_BLOCK=1 → HARD GATE: same JSON, reason on stderr, exit 2
#                        (change blocked; blockable for non-policy sources)
#   Why a notification and not a message: see the channel guard at the emit site.
#
# Exit codes: 0 allow (clean or advisory), 2 block (IOC + SUPPLY_CHAIN_BLOCK=1)
# Channel contract tests: tests/hooks.sh

set -uo pipefail   # NOT -e: a guard must not crash into a false block

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1

# ── Resolve the changed file: stdin JSON → source map → $1 fallback ─────────
FILE=""; SRC=""; CWD=""
if [[ ! -t 0 ]]; then
  RAW="$(cat 2>/dev/null)"
  if [[ -n "${RAW:-}" && "$HAS_JQ" -eq 1 ]]; then
    FILE="$(printf '%s' "$RAW" | jq -r '.file_path // empty' 2>/dev/null)"
    SRC="$(printf '%s' "$RAW" | jq -r '.source // empty' 2>/dev/null)"
    CWD="$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null)"
  fi
fi
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ -z "$FILE" ]]; then
  case "$SRC" in
    user_settings)    FILE="$HOME/.claude/settings.json" ;;
    project_settings) FILE="$CWD/.claude/settings.json" ;;
    local_settings)   FILE="$CWD/.claude/settings.local.json" ;;
    policy_settings|skills) exit 0 ;;   # unblockable / no single file
    *) FILE="${1:-}" ;;                 # offline-test fallback: path as $1
  esac
fi
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

# ── IOC patterns — reused verbatim from integrity-audit.sh SHELL_SUSPECT ───
# (curl|sh, wget|sh, base64 decode, eval-of-subshell, settings/cred reads,
# reverse shell, PowerShell download-exec). Vetted there; do not fork them.
SUSPECT='curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh|base64[[:space:]]+--?d|eval[[:space:]]+"?\$\(|\.claude[/\\]\.?settings|\.aws[/\\]credentials|/dev/tcp/|[Ii]nvoke-Expression[^;]*[Dd]ownload'

HITS="$(grep -nEi "$SUSPECT" "$FILE" 2>/dev/null)"
[[ -z "$HITS" ]] && exit 0   # clean → silent

FLAT="$(printf '%s' "$HITS" | head -5 | tr '\n' ';' )"
MSG="CONFIG GUARD: worm-persistence IOC in changed settings file ($FILE): ${FLAT} — confirm YOU added this. If unexplained, treat as an incident: run skills/supply-chain-defense/scripts/integrity-audit.sh, isolate, rotate credentials."

# ── Emit ───────────────────────────────────────────────────────────────────
# Guard: ConfigChange is the one event where no text channel reaches anyone.
# Per "ConfigChange decision control" in https://code.claude.com/docs/en/hooks,
# it DISCARDS systemMessage, has no additionalContext, and even a block
# "surfaces no message to you or to Claude" - plain stdout and stderr land in
# the debug log only. The one field that still reaches a person is
# terminalSequence: a desktop notification (OSC 9) that Claude Code writes
# itself, in interactive sessions only (ignored under -p and the SDK). The
# systemMessage-only original alerted nobody. systemMessage stays for any
# harness that does show it; nothing here reaches the model.
#
# OSC 9 grammar: ESC ] 9 ; <body> BEL. The body is a fixed string plus the file
# path, never the IOC lines (attacker-written settings content), and is stripped
# of control bytes: one stray ESC/BEL would make Claude Code reject the field
# (allowlist: OSC 0/1/2/9/99/777 + BEL). The leading "Claude" keeps the body
# from reading as a ConEmu/Windows Terminal "9;<n>;" sub-command.
NOTE="$(printf 'Claude Code config guard: worm-persistence IOC in %s - review before trusting it' "$FILE" | tr -d '\000-\037\177')"
SEQ="$(printf '\033]9;%s\007' "$NOTE")"
emit_notice() {
  [[ "$HAS_JQ" -eq 1 ]] || return 0   # no jq, no envelope - nothing would be read anyway
  jq -nc --arg m "$MSG" --arg s "$SEQ" '{systemMessage:$m, terminalSequence:$s}'
}

if [[ "${SUPPLY_CHAIN_BLOCK:-0}" == "1" ]]; then
  # exit 2 blocks whatever the JSON says, and Claude Code still reads the JSON,
  # so the notification also explains an otherwise silent block.
  emit_notice
  echo "$MSG" >&2
  echo "Blocked (SUPPLY_CHAIN_BLOCK=1). Review the change before allowing it." >&2
  exit 2
fi

emit_notice
exit 0
