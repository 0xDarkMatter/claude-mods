#!/bin/bash
# hooks/check-mail.sh
# PreToolUse hook - checks for unread inter-session mail
# Runs on every tool call. Silent when inbox is empty.
# Matcher: * (all tools)
#
# Configuration in .claude/settings.json or .claude/settings.local.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "*",
#       "hooks": ["bash hooks/check-mail.sh"]
#     }]
#   }
# }

MAIL_DB="$HOME/.claude/mail.db"
COOLDOWN_FILE="/tmp/agentmail_check_$$"
COOLDOWN_SECONDS=10

# Skip if no database exists yet
[ -f "$MAIL_DB" ] || exit 0

# Cooldown: skip if checked recently (within COOLDOWN_SECONDS)
if [ -f "$COOLDOWN_FILE" ]; then
  last_check=$(stat -c %Y "$COOLDOWN_FILE" 2>/dev/null || stat -f %m "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last_check)) -lt $COOLDOWN_SECONDS ]; then
    exit 0
  fi
fi
touch "$COOLDOWN_FILE"

PROJECT=$(basename "$PWD" | sed "s/'/''/g")

# Single fast query - count unread
UNREAD=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT}' AND read=0;" 2>/dev/null)

# Silent exit if no mail
[ "${UNREAD:-0}" -eq 0 ] && exit 0

# Check for urgent messages
URGENT=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT}' AND read=0 AND priority='urgent';" 2>/dev/null)

# Show notification with preview of first 3 messages
echo ""
if [ "${URGENT:-0}" -gt 0 ]; then
  echo "=== URGENT MAIL: ${UNREAD} unread (${URGENT} urgent) ==="
else
  echo "=== MAIL: ${UNREAD} unread message(s) ==="
fi
sqlite3 -separator '  ' "$MAIL_DB" \
  "SELECT '  ' || CASE WHEN priority='urgent' THEN '[!] ' ELSE '' END || 'From: ' || from_project || '  |  ' || subject FROM messages WHERE to_project='${PROJECT}' AND read=0 ORDER BY priority DESC, timestamp DESC LIMIT 3;" 2>/dev/null
if [ "$UNREAD" -gt 3 ]; then
  echo "  ... and $((UNREAD - 3)) more"
fi
echo "Use /mail to read messages."
echo "==="
