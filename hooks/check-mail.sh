#!/bin/bash
# hooks/check-mail.sh
# PreToolUse hook - event-driven mail delivery with thread context.
# Checks a signal file (stat, nanoseconds) before touching SQLite.
# Silent when no signal. Delivers full thread context for each message.

MAIL_DB="$HOME/.claude/mail.db"
MAIL_SCRIPT="$HOME/.claude/agentmail/mail-db.sh"

# Skip if disabled for this project
[ -f ".claude/agentmail.disable" ] && exit 0

# Project identity: git root commit hash, fallback to path hash
ROOT_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
if [ -n "$ROOT_COMMIT" ]; then
  PROJECT_HASH="${ROOT_COMMIT:0:6}"
else
  CANONICAL=$(cd "$PWD" && pwd -P)
  PROJECT_HASH=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-6)
fi

SIGNAL="/tmp/agentmail_signal_${PROJECT_HASH}"

# Fast path: no signal file = no mail. Stat check only, no SQLite.
[ -f "$SIGNAL" ] || exit 0

# Signal exists - check DB to confirm
[ -f "$MAIL_DB" ] || exit 0

UNREAD=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0;" 2>/dev/null)

if [ "${UNREAD:-0}" -eq 0 ]; then
  # Signal was stale, clean up
  rm -f "$SIGNAL"
  exit 0
fi

# Resolve display name for a hash
show_from() {
  local hash="$1"
  local name
  name=$(sqlite3 "$MAIL_DB" "SELECT name FROM projects WHERE hash='${hash}';" 2>/dev/null)
  [ -n "$name" ] && echo "$name" || echo "$hash"
}

# Deliver each message with thread context
echo ""
echo "=== INCOMING MAIL (${UNREAD} message(s)) ==="

while read -r msg_id; do
  [ -z "$msg_id" ] && continue
  from_hash=$(sqlite3 "$MAIL_DB" "SELECT from_project FROM messages WHERE id=${msg_id};" 2>/dev/null)
  priority=$(sqlite3 "$MAIL_DB" "SELECT priority FROM messages WHERE id=${msg_id};" 2>/dev/null)
  subject=$(sqlite3 "$MAIL_DB" "SELECT subject FROM messages WHERE id=${msg_id};" 2>/dev/null)
  body=$(sqlite3 "$MAIL_DB" "SELECT body FROM messages WHERE id=${msg_id};" 2>/dev/null)
  timestamp=$(sqlite3 "$MAIL_DB" "SELECT timestamp FROM messages WHERE id=${msg_id};" 2>/dev/null)
  thread_id=$(sqlite3 "$MAIL_DB" "SELECT thread_id FROM messages WHERE id=${msg_id};" 2>/dev/null)
  from_name=$(show_from "$from_hash")
  urgent=""
  [ "$priority" = "urgent" ] && urgent=" [URGENT]"

  echo ""
  echo "--- #${msg_id} from ${from_name} (${from_hash})${urgent} @ ${timestamp} ---"
  echo "Subject: ${subject}"
  echo "${body}"

  # Show thread context if this is part of a conversation
  if [ -n "$thread_id" ]; then
    thread_root="$thread_id"
    thread_count=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE id=${thread_root} OR thread_id=${thread_root};" 2>/dev/null)
    if [ "${thread_count:-0}" -gt 1 ]; then
      echo ""
      echo "[Thread #${thread_root} - ${thread_count} messages. Run: agentmail thread ${thread_root}]"
    fi
  fi
done < <(sqlite3 "$MAIL_DB" \
  "SELECT id FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0 ORDER BY priority DESC, timestamp ASC;" 2>/dev/null)

echo ""
echo "=== ACTION REQUIRED: Inform the user about these messages and ask if they want to reply. ==="
echo "=== Then run: agentmail read (to mark as read) ==="
echo "=== To reply: agentmail reply <id> \"message\" ==="

# Clear signal (new sends will re-create it)
rm -f "$SIGNAL"
