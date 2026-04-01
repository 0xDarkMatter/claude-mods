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
    read INTEGER DEFAULT 0,
    priority TEXT DEFAULT 'normal'
);
CREATE INDEX IF NOT EXISTS idx_unread ON messages(to_project, read);
CREATE INDEX IF NOT EXISTS idx_timestamp ON messages(timestamp);
SQL
  # Migration: add priority column if missing
  sqlite3 "$MAIL_DB" "SELECT priority FROM messages LIMIT 0;" 2>/dev/null || \
    sqlite3 "$MAIL_DB" "ALTER TABLE messages ADD COLUMN priority TEXT DEFAULT 'normal';" 2>/dev/null
}

# Sanitize string for safe SQL interpolation (escape single quotes)
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Get project name from cwd
get_project() {
  basename "$PWD"
}

# Count unread messages for current project
count_unread() {
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${project}' AND read=0;"
}

# List unread messages (brief) for current project
list_unread() {
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  sqlite3 -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, timestamp FROM messages WHERE to_project='${project}' AND read=0 ORDER BY timestamp DESC;"
}

# Read all unread messages (full) and mark as read
read_mail() {
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, body, timestamp FROM messages WHERE to_project='${project}' AND read=0 ORDER BY timestamp ASC;"
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE to_project='${project}' AND read=0;"
}

# Read a single message by ID and mark as read
read_one() {
  local msg_id="$1"
  # Validate ID is numeric
  if ! [[ "$msg_id" =~ ^[0-9]+$ ]]; then
    echo "Error: message ID must be numeric" >&2
    return 1
  fi
  init_db
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, to_project, subject, body, timestamp FROM messages WHERE id=${msg_id};"
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE id=${msg_id};"
}

# Send a message (optional --urgent flag before args)
send() {
  local priority="normal"
  if [ "${1:-}" = "--urgent" ]; then
    priority="urgent"
    shift
  fi
  local to_project="${1:?to_project required}"
  local subject="${2:-no subject}"
  local body="${3:?body required}"
  if [ -z "$body" ]; then
    echo "Error: message body cannot be empty" >&2
    return 1
  fi
  init_db
  local from_project
  from_project=$(sql_escape "$(get_project)")
  local safe_to safe_subject safe_body
  safe_to=$(sql_escape "$to_project")
  safe_subject=$(sql_escape "$subject")
  safe_body=$(sql_escape "$body")
  sqlite3 "$MAIL_DB" \
    "INSERT INTO messages (from_project, to_project, subject, body, priority) VALUES ('${from_project}', '${safe_to}', '${safe_subject}', '${safe_body}', '${priority}');"
  echo "Sent to ${to_project}: ${subject}$([ "$priority" = "urgent" ] && echo " [URGENT]" || true)"
}

# Search messages by keyword
search() {
  local keyword="$1"
  if [ -z "$keyword" ]; then
    echo "Error: search keyword required" >&2
    return 1
  fi
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  local safe_keyword
  safe_keyword=$(sql_escape "$keyword")
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, CASE WHEN read=0 THEN 'UNREAD' ELSE 'read' END as status, timestamp FROM messages WHERE to_project='${project}' AND (subject LIKE '%${safe_keyword}%' OR body LIKE '%${safe_keyword}%') ORDER BY timestamp DESC LIMIT 20;"
}

# List all messages (read and unread) for current project
list_all() {
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  local limit="${1:-20}"
  # Validate limit is numeric
  if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
    limit=20
  fi
  sqlite3 -header -separator ' | ' "$MAIL_DB" \
    "SELECT id, from_project, subject, CASE WHEN read=0 THEN 'UNREAD' ELSE 'read' END as status, timestamp FROM messages WHERE to_project='${project}' ORDER BY timestamp DESC LIMIT ${limit};"
}

# Clear old read messages (default: older than 7 days)
clear_old() {
  init_db
  local days="${1:-7}"
  # Validate days is numeric
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    days=7
  fi
  local deleted
  deleted=$(sqlite3 "$MAIL_DB" \
    "DELETE FROM messages WHERE read=1 AND timestamp < datetime('now', '-${days} days'); SELECT changes();")
  echo "Cleared ${deleted} read messages older than ${days} days"
}

# Reply to a message by ID
reply() {
  local msg_id="$1"
  local body="$2"
  if ! [[ "$msg_id" =~ ^[0-9]+$ ]]; then
    echo "Error: message ID must be numeric" >&2
    return 1
  fi
  if [ -z "$body" ]; then
    echo "Error: reply body cannot be empty" >&2
    return 1
  fi
  init_db
  # Get original sender and subject
  local orig
  orig=$(sqlite3 -separator '|' "$MAIL_DB" "SELECT from_project, subject FROM messages WHERE id=${msg_id};")
  if [ -z "$orig" ]; then
    echo "Error: message #${msg_id} not found" >&2
    return 1
  fi
  local orig_from orig_subject
  orig_from=$(echo "$orig" | cut -d'|' -f1)
  orig_subject=$(echo "$orig" | cut -d'|' -f2)
  local from_project
  from_project=$(sql_escape "$(get_project)")
  local safe_to safe_subject safe_body
  safe_to=$(sql_escape "$orig_from")
  safe_subject=$(sql_escape "Re: ${orig_subject}")
  safe_body=$(sql_escape "$body")
  sqlite3 "$MAIL_DB" \
    "INSERT INTO messages (from_project, to_project, subject, body) VALUES ('${from_project}', '${safe_to}', '${safe_subject}', '${safe_body}');"
  echo "Replied to ${orig_from}: Re: ${orig_subject}"
}

# Broadcast a message to all known projects (except self)
broadcast() {
  local subject="$1"
  local body="$2"
  if [ -z "$body" ]; then
    echo "Error: message body cannot be empty" >&2
    return 1
  fi
  init_db
  local from_project
  from_project=$(get_project)
  local targets
  targets=$(sqlite3 "$MAIL_DB" \
    "SELECT DISTINCT from_project FROM messages UNION SELECT DISTINCT to_project FROM messages ORDER BY 1;")
  local count=0
  local safe_subject safe_body safe_from
  safe_from=$(sql_escape "$from_project")
  safe_subject=$(sql_escape "$subject")
  safe_body=$(sql_escape "$body")
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    [ "$target" = "$from_project" ] && continue
    local safe_to
    safe_to=$(sql_escape "$target")
    sqlite3 "$MAIL_DB" \
      "INSERT INTO messages (from_project, to_project, subject, body) VALUES ('${safe_from}', '${safe_to}', '${safe_subject}', '${safe_body}');"
    count=$((count + 1))
  done <<< "$targets"
  echo "Broadcast to ${count} project(s): ${subject}"
}

# Show inbox status summary
status() {
  init_db
  local project
  project=$(sql_escape "$(get_project)")
  local unread total
  unread=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${project}' AND read=0;")
  total=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${project}';")
  local projects
  projects=$(sqlite3 "$MAIL_DB" \
    "SELECT COUNT(DISTINCT from_project) FROM messages WHERE to_project='${project}' AND read=0;")
  echo "Inbox: ${unread} unread / ${total} total"
  if [ "${unread:-0}" -gt 0 ]; then
    echo "From: ${projects} project(s)"
    sqlite3 -separator ': ' "$MAIL_DB" \
      "SELECT from_project, COUNT(*) || ' message(s)' FROM messages WHERE to_project='${project}' AND read=0 GROUP BY from_project ORDER BY COUNT(*) DESC;"
  fi
}

# Purge all messages for current project (or all projects with --all)
purge() {
  init_db
  if [ "${1:-}" = "--all" ]; then
    local count
    count=$(sqlite3 "$MAIL_DB" "DELETE FROM messages; SELECT changes();")
    echo "Purged all ${count} message(s) from database"
  else
    local project
    project=$(sql_escape "$(get_project)")
    local count
    count=$(sqlite3 "$MAIL_DB" \
      "DELETE FROM messages WHERE to_project='${project}' OR from_project='${project}'; SELECT changes();")
    echo "Purged ${count} message(s) for $(get_project)"
  fi
}

# Rename a project in all messages (for directory renames/moves)
alias_project() {
  local old_name="$1"
  local new_name="$2"
  if [ -z "$old_name" ] || [ -z "$new_name" ]; then
    echo "Error: both old and new project names required" >&2
    return 1
  fi
  init_db
  local safe_old safe_new
  safe_old=$(sql_escape "$old_name")
  safe_new=$(sql_escape "$new_name")
  local updated=0
  local count
  count=$(sqlite3 "$MAIL_DB" \
    "UPDATE messages SET from_project='${safe_new}' WHERE from_project='${safe_old}'; SELECT changes();")
  updated=$((updated + count))
  count=$(sqlite3 "$MAIL_DB" \
    "UPDATE messages SET to_project='${safe_new}' WHERE to_project='${safe_old}'; SELECT changes();")
  updated=$((updated + count))
  echo "Renamed '${old_name}' -> '${new_name}' in ${updated} message(s)"
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
  send)       shift; send "$@" ;;
  reply)      reply "${2:?message_id required}" "${3:?body required}" ;;
  list)       list_all "${2:-20}" ;;
  clear)      clear_old "${2:-7}" ;;
  broadcast)  broadcast "${2:-no subject}" "${3:?body required}" ;;
  search)     search "${2:?keyword required}" ;;
  status)     status ;;
  purge)      purge "${2:-}" ;;
  alias)      alias_project "${2:?old name required}" "${3:?new name required}" ;;
  projects)   list_projects ;;
  help)
    echo "Usage: mail-db.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init                    Initialize database"
    echo "  count                   Count unread messages"
    echo "  unread                  List unread messages (brief)"
    echo "  read [id]               Read messages and mark as read"
    echo "  send [--urgent] <to> <subj> <body>"
    echo "                          Send a message"
    echo "  reply <id> <body>       Reply to a message"
    echo "  list [limit]            List recent messages (default 20)"
    echo "  clear [days]            Clear read messages older than N days"
    echo "  broadcast <subj> <body> Send to all known projects"
    echo "  search <keyword>        Search messages by keyword"
    echo "  status                  Inbox summary"
    echo "  purge [--all]           Delete all messages for this project"
    echo "  alias <old> <new>       Rename project in all messages"
    echo "  projects                List known projects"
    ;;
  *)          echo "Unknown command: $1. Run with 'help' for usage." >&2; exit 1 ;;
esac
