#!/bin/bash
# mail-db.sh - SQLite mail database operations
# Global mail database at ~/.claude/mail.db
# Project identity derived from basename of working directory

set -euo pipefail

MAIL_DB="$HOME/.claude/mail.db"

# Ensure database and schema exist
init_db() {
  mkdir -p "$(dirname "$MAIL_DB")"
  sqlite3 "$MAIL_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_project TEXT NOT NULL,
    to_project TEXT NOT NULL,
    subject TEXT DEFAULT '',
    body TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now')),
    read INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_unread ON messages(to_project, read);
CREATE INDEX IF NOT EXISTS idx_timestamp ON messages(timestamp);
SQL
}

# Get project name from cwd
get_project() {
  basename "$PWD"
}

# Count unread messages for current project
count_unread() {
  init_db
  local project
  project=$(get_project)
  sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${project}' AND read=0;"
}

# List unread messages (brief) for current project
list_unread() {
  init_db
  local project
  project=$(get_project)
  sqlite3 -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, timestamp FROM messages WHERE to_project='${project}' AND read=0 ORDER BY timestamp DESC;"
}

# Read all unread messages (full) and mark as read
read_mail() {
  init_db
  local project
  project=$(get_project)
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, body, timestamp FROM messages WHERE to_project='${project}' AND read=0 ORDER BY timestamp ASC;"
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE to_project='${project}' AND read=0;"
}

# Read a single message by ID and mark as read
read_one() {
  local msg_id="$1"
  init_db
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, to_project, subject, body, timestamp FROM messages WHERE id=${msg_id};"
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE id=${msg_id};"
}

# Send a message
send() {
  local to_project="$1"
  local subject="$2"
  local body="$3"
  init_db
  local from_project
  from_project=$(get_project)
  sqlite3 "$MAIL_DB" \
    "INSERT INTO messages (from_project, to_project, subject, body) VALUES ('${from_project}', '${to_project}', '${subject}', '${body}');"
  echo "Sent to ${to_project}: ${subject}"
}

# List all messages (read and unread) for current project
list_all() {
  init_db
  local project
  project=$(get_project)
  local limit="${1:-20}"
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, CASE WHEN read=0 THEN 'UNREAD' ELSE 'read' END as status, timestamp FROM messages WHERE to_project='${project}' ORDER BY timestamp DESC LIMIT ${limit};"
}

# Clear old read messages (default: older than 7 days)
clear_old() {
  init_db
  local days="${1:-7}"
  local deleted
  deleted=$(sqlite3 "$MAIL_DB" \
    "DELETE FROM messages WHERE read=1 AND timestamp < datetime('now', '-${days} days'); SELECT changes();")
  echo "Cleared ${deleted} read messages older than ${days} days"
}

# List all known projects (that have sent or received mail)
list_projects() {
  init_db
  sqlite3 "$MAIL_DB" \
    "SELECT DISTINCT from_project FROM messages UNION SELECT DISTINCT to_project FROM messages ORDER BY 1;"
}

# Dispatch
case "${1:-help}" in
  init)       init_db && echo "Mail database initialized at $MAIL_DB" ;;
  count)      count_unread ;;
  unread)     list_unread ;;
  read)       if [ -n "${2:-}" ]; then read_one "$2"; else read_mail; fi ;;
  send)       send "${2:?to_project required}" "${3:-no subject}" "${4:?body required}" ;;
  list)       list_all "${2:-20}" ;;
  clear)      clear_old "${2:-7}" ;;
  projects)   list_projects ;;
  help)
    echo "Usage: mail-db.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init                    Initialize database"
    echo "  count                   Count unread messages"
    echo "  unread                  List unread messages (brief)"
    echo "  read [id]               Read messages and mark as read"
    echo "  send <to> <subj> <body> Send a message"
    echo "  list [limit]            List recent messages (default 20)"
    echo "  clear [days]            Clear read messages older than N days"
    echo "  projects                List known projects"
    ;;
  *)          echo "Unknown command: $1. Run with 'help' for usage." >&2; exit 1 ;;
esac
