#!/bin/bash
# hooks/check-mail.sh
# PreToolUse hook - checks for unread inter-session mail
# Runs on every tool call. Silent when inbox is empty.
# Uses hash-based project identity (resolves case sensitivity).

MAIL_DB="$HOME/.claude/mail.db"
COOLDOWN_SECONDS=10

# Skip if disabled for this project
[ -f ".claude/agentmail.disable" ] && exit 0

# Skip if no database exists yet
[ -f "$MAIL_DB" ] || exit 0

# Project identity: git root commit hash, fallback to path hash
ROOT_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
if [ -n "$ROOT_COMMIT" ]; then
  PROJECT_HASH="${ROOT_COMMIT:0:6}"
else
  CANONICAL=$(cd "$PWD" && pwd -P)
  PROJECT_HASH=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-6)
fi

COOLDOWN_FILE="/tmp/agentmail_${PROJECT_HASH}"

# Cooldown: skip if checked recently (within COOLDOWN_SECONDS)
if [ -f "$COOLDOWN_FILE" ]; then
  last_check=$(stat -c %Y "$COOLDOWN_FILE" 2>/dev/null || stat -f %m "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last_check)) -lt $COOLDOWN_SECONDS ]; then
    exit 0
  fi
fi
touch "$COOLDOWN_FILE"

# Single fast query - count unread
UNREAD=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0;" 2>/dev/null)

# Silent exit if no mail
[ "${UNREAD:-0}" -eq 0 ] && exit 0

# Check for urgent messages
URGENT=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0 AND priority='urgent';" 2>/dev/null)

# Resolve display names for preview
show_from() {
  local hash="$1"
  local name
  name=$(sqlite3 "$MAIL_DB" "SELECT name FROM projects WHERE hash='${hash}';" 2>/dev/null)
  [ -n "$name" ] && echo "$name" || echo "$hash"
}

# Show notification with preview of first 3 messages
echo ""
if [ "${URGENT:-0}" -gt 0 ]; then
  echo "=== URGENT MAIL: ${UNREAD} unread (${URGENT} urgent) ==="
else
  echo "=== MAIL: ${UNREAD} unread message(s) ==="
fi

# Preview messages with resolved names
while IFS='|' read -r from_hash priority subject; do
  from_name=$(show_from "$from_hash")
  prefix=""
  [ "$priority" = "urgent" ] && prefix="[!] "
  echo "  ${prefix}From: ${from_name}  |  ${subject}"
done < <(sqlite3 -separator '|' "$MAIL_DB" \
  "SELECT from_project, priority, subject FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0 ORDER BY priority DESC, timestamp DESC LIMIT 3;" 2>/dev/null)

if [ "$UNREAD" -gt 3 ]; then
  echo "  ... and $((UNREAD - 3)) more"
fi
echo "Use agentmail read to read messages."
echo "==="
