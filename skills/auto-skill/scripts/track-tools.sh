#!/bin/bash
# track-tools.sh - PostToolUse hook: lightweight tool call counter
# Appends tool name to a session-specific temp file.
# Designed to be fast (<5ms) - no SQLite, no network, just a file append.
#
# CRITICAL: This hook must NEVER fail visibly. All errors suppressed.

{
  INPUT=$(cat)
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

  [ -z "$TOOL_NAME" ] && exit 0
  [ -z "$SESSION_ID" ] && exit 0

  SHORT_ID="${SESSION_ID:0:8}"
  TRACK_FILE="/tmp/claude_autoskill_${SHORT_ID}"

  # Append tool name (one per line). Cap at 500 lines to prevent runaway.
  if [ ! -f "$TRACK_FILE" ] || [ "$(wc -l < "$TRACK_FILE" 2>/dev/null)" -lt 500 ]; then
    echo "$TOOL_NAME" >> "$TRACK_FILE"
  fi
} 2>/dev/null

exit 0
