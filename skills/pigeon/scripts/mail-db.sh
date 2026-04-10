#!/bin/bash
# mail-db.sh - SQLite pmail database operations
# Global mail database at ~/.claude/pmail.db
# Project identity: 6-char ID derived from git root commit (stable across
# renames, moves, clones) with fallback to canonical path hash for non-git dirs.

set -euo pipefail

MAIL_DB="$HOME/.claude/pmail.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Identity - git-rooted project IDs
# ============================================================================

# Get canonical path (resolves symlinks + case on macOS)
canonical_path() {
  if [ -d "${1:-$PWD}" ]; then
    (cd "${1:-$PWD}" && pwd -P)
  else
    printf '%s' "${1:-$PWD}"
  fi
}

# Generate 6-char project ID
# Priority: git root commit hash > canonical path hash
project_hash() {
  local dir="${1:-$PWD}"

  # Try git root commit (first commit in repo history)
  if [ -d "$dir" ]; then
    local root_commit
    root_commit=$(git -C "$dir" rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
    if [ -n "$root_commit" ]; then
      echo "${root_commit:0:6}"
      return 0
    fi
  fi

  # Fallback: hash of canonical path
  local path
  path=$(canonical_path "$dir")
  printf '%s' "$path" | shasum -a 256 | cut -c1-6
}

# Get display name (basename of canonical path)
project_name() {
  basename "$(canonical_path "${1:-$PWD}")"
}

# ============================================================================
# Database
# ============================================================================

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

CREATE TABLE IF NOT EXISTS projects (
    hash TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    registered TEXT DEFAULT (datetime('now'))
);
SQL
  # Migration: add priority column if missing
  sqlite3 "$MAIL_DB" "SELECT priority FROM messages LIMIT 0;" 2>/dev/null || \
    sqlite3 "$MAIL_DB" "ALTER TABLE messages ADD COLUMN priority TEXT DEFAULT 'normal';" 2>/dev/null
  # Migration: create projects table if missing (for existing installs)
  sqlite3 "$MAIL_DB" "SELECT hash FROM projects LIMIT 0;" 2>/dev/null || \
    sqlite3 "$MAIL_DB" "CREATE TABLE IF NOT EXISTS projects (hash TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, registered TEXT DEFAULT (datetime('now')));" 2>/dev/null
  # Migration: add thread_id column if missing
  sqlite3 "$MAIL_DB" "SELECT thread_id FROM messages LIMIT 0;" 2>/dev/null || \
    sqlite3 "$MAIL_DB" "ALTER TABLE messages ADD COLUMN thread_id INTEGER REFERENCES messages(id);" 2>/dev/null
  # Migration: add attachments column if missing
  sqlite3 "$MAIL_DB" "SELECT attachments FROM messages LIMIT 0;" 2>/dev/null || \
    sqlite3 "$MAIL_DB" "ALTER TABLE messages ADD COLUMN attachments TEXT DEFAULT '';" 2>/dev/null
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Resolve attachment path to absolute, validate existence
resolve_attach() {
  local p="$1"
  if [ ! -e "$p" ]; then
    echo "Error: attachment not found: $p" >&2
    return 1
  fi
  (cd "$(dirname "$p")" && echo "$(pwd -P)/$(basename "$p")")
}

# Read body from argument or stdin (use - or omit for stdin)
read_body() {
  local arg="$1"
  if [ "$arg" = "-" ] || [ -z "$arg" ]; then
    cat
  else
    printf '%s' "$arg"
  fi
}

# Register current project in the projects table (idempotent)
register_project() {
  local hash name path
  hash=$(project_hash "${1:-$PWD}")
  name=$(sql_escape "$(project_name "${1:-$PWD}")")
  path=$(sql_escape "$(canonical_path "${1:-$PWD}")")
  sqlite3 "$MAIL_DB" \
    "INSERT OR REPLACE INTO projects (hash, name, path) VALUES ('${hash}', '${name}', '${path}');"
}

# Get project ID for current directory
get_project_id() {
  project_hash "${1:-$PWD}"
}

# Resolve a user-supplied name/hash to a project hash
# Accepts: hash (6 chars), project name, or path
resolve_target() {
  local target="$1"
  local safe_target
  safe_target=$(sql_escape "$target")

  # 1. Exact hash match
  if [[ ${#target} -eq 6 ]] && [[ "$target" =~ ^[0-9a-f]+$ ]]; then
    local found
    found=$(sqlite3 "$MAIL_DB" "SELECT hash FROM projects WHERE hash='${safe_target}';")
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  fi

  # 2. Name match (case-insensitive)
  local by_name
  by_name=$(sqlite3 "$MAIL_DB" "SELECT hash FROM projects WHERE LOWER(name)=LOWER('${safe_target}') ORDER BY registered DESC LIMIT 1;")
  if [ -n "$by_name" ]; then
    echo "$by_name"
    return 0
  fi

  # 3. Path match - target might be a directory
  if [ -d "$target" ]; then
    local hash
    hash=$(project_hash "$target")
    echo "$hash"
    return 0
  fi

  # 4. Generate hash from target as a string (for unknown projects)
  # Register it so replies work
  local hash
  hash=$(printf '%s' "$target" | shasum -a 256 | cut -c1-6)
  sqlite3 "$MAIL_DB" \
    "INSERT OR IGNORE INTO projects (hash, name, path) VALUES ('${hash}', '${safe_target}', '${safe_target}');"
  echo "$hash"
}

# Look up display name for a hash
display_name() {
  local hash="$1"
  local name
  name=$(sqlite3 "$MAIL_DB" "SELECT name FROM projects WHERE hash='${hash}';")
  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "$hash"
  fi
}

# ============================================================================
# Identicon display (inline, compact)
# ============================================================================

show_identicon() {
  local target="${1:-$PWD}"
  if [ -f "$SCRIPT_DIR/identicon.sh" ]; then
    bash "$SCRIPT_DIR/identicon.sh" "$target"
  fi
}

# ============================================================================
# Mail operations
# ============================================================================

count_unread() {
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${pid}' AND read=0;"
}

list_unread() {
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  local rows
  rows=$(sqlite3 -separator '|' "$MAIL_DB" \
    "SELECT id, from_project, subject, timestamp FROM messages WHERE to_project='${pid}' AND read=0 ORDER BY timestamp DESC;")
  [ -z "$rows" ] && return 0
  while IFS='|' read -r id from_hash subj ts; do
    local from_name
    from_name=$(display_name "$from_hash")
    echo "${id} | ${from_name} (${from_hash}) | ${subj} | ${ts}"
  done <<< "$rows"
}

read_mail() {
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  # Use ASCII record separator (0x1E) to avoid splitting on pipes/newlines in body
  local RS=$'\x1e'
  local count
  count=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${pid}' AND read=0;")
  [ "${count:-0}" -eq 0 ] && return 0
  # Query each message individually to preserve multi-line bodies
  local ids
  ids=$(sqlite3 "$MAIL_DB" "SELECT id FROM messages WHERE to_project='${pid}' AND read=0 ORDER BY timestamp ASC;")
  echo "id | from_project | subject | body | timestamp"
  while read -r msg_id; do
    [ -z "$msg_id" ] && continue
    local from_hash subj body ts from_name attachments
    from_hash=$(sqlite3 "$MAIL_DB" "SELECT from_project FROM messages WHERE id=${msg_id};")
    subj=$(sqlite3 "$MAIL_DB" "SELECT subject FROM messages WHERE id=${msg_id};")
    body=$(sqlite3 "$MAIL_DB" "SELECT body FROM messages WHERE id=${msg_id};")
    ts=$(sqlite3 "$MAIL_DB" "SELECT timestamp FROM messages WHERE id=${msg_id};")
    attachments=$(sqlite3 "$MAIL_DB" "SELECT COALESCE(attachments,'') FROM messages WHERE id=${msg_id};")
    from_name=$(display_name "$from_hash")
    echo "${msg_id} | ${from_name} (${from_hash}) | ${subj} | ${body} | ${ts}"
    if [ -n "$attachments" ]; then
      while IFS= read -r apath; do
        [ -z "$apath" ] && continue
        local astat="missing"
        [ -e "$apath" ] && astat="$(wc -c < "$apath" | tr -d ' ') bytes"
        echo "  [Attached: ${apath} (${astat})]"
      done <<< "$attachments"
    fi
  done <<< "$ids"
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE to_project='${pid}' AND read=0;"
  # Clear signal file
  rm -f "/tmp/pigeon_signal_${pid}"
}

read_one() {
  local msg_id="$1"
  if ! [[ "$msg_id" =~ ^[0-9]+$ ]]; then
    echo "Error: message ID must be numeric" >&2
    return 1
  fi
  init_db
  local exists
  exists=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE id=${msg_id};")
  [ "${exists:-0}" -eq 0 ] && return 0
  local from_hash to_hash subj body ts from_name to_name attachments
  from_hash=$(sqlite3 "$MAIL_DB" "SELECT from_project FROM messages WHERE id=${msg_id};")
  to_hash=$(sqlite3 "$MAIL_DB" "SELECT to_project FROM messages WHERE id=${msg_id};")
  subj=$(sqlite3 "$MAIL_DB" "SELECT subject FROM messages WHERE id=${msg_id};")
  body=$(sqlite3 "$MAIL_DB" "SELECT body FROM messages WHERE id=${msg_id};")
  ts=$(sqlite3 "$MAIL_DB" "SELECT timestamp FROM messages WHERE id=${msg_id};")
  attachments=$(sqlite3 "$MAIL_DB" "SELECT COALESCE(attachments,'') FROM messages WHERE id=${msg_id};")
  from_name=$(display_name "$from_hash")
  to_name=$(display_name "$to_hash")
  echo "id | from_project | to_project | subject | body | timestamp"
  echo "${msg_id} | ${from_name} (${from_hash}) | ${to_name} (${to_hash}) | ${subj} | ${body} | ${ts}"
  if [ -n "$attachments" ]; then
    while IFS= read -r apath; do
      [ -z "$apath" ] && continue
      local astat="missing"
      [ -e "$apath" ] && astat="$(wc -c < "$apath" | tr -d ' ') bytes"
      echo "  [Attached: ${apath} (${astat})]"
    done <<< "$attachments"
  fi
  sqlite3 "$MAIL_DB" \
    "UPDATE messages SET read=1 WHERE id=${msg_id};"
}

send() {
  local priority="normal"
  local -a attach_paths=()
  # Parse flags before positional args
  while [ $# -gt 0 ]; do
    case "$1" in
      --urgent) priority="urgent"; shift ;;
      --attach) shift; local resolved; resolved=$(resolve_attach "$1") || return 1; attach_paths+=("$resolved"); shift ;;
      *) break ;;
    esac
  done
  local to_input="${1:?to_project required}"
  local subject="${2:-no subject}"
  local body
  body=$(read_body "${3:-}")
  if [ -z "$body" ]; then
    echo "Error: message body cannot be empty" >&2
    return 1
  fi
  init_db
  register_project
  local from_id to_id
  from_id=$(get_project_id)
  to_id=$(resolve_target "$to_input")
  local safe_subject safe_body safe_attachments
  safe_subject=$(sql_escape "$subject")
  safe_body=$(sql_escape "$body")
  # Join attachment paths with newlines
  local attachments=""
  if [ ${#attach_paths[@]} -gt 0 ]; then
    attachments=$(IFS=$'\n'; echo "${attach_paths[*]}")
  fi
  safe_attachments=$(sql_escape "$attachments")
  sqlite3 "$MAIL_DB" \
    "INSERT INTO messages (from_project, to_project, subject, body, priority, attachments) VALUES ('${from_id}', '${to_id}', '${safe_subject}', '${safe_body}', '${priority}', '${safe_attachments}');"
  # Signal the recipient
  touch "/tmp/pigeon_signal_${to_id}"
  local to_name
  to_name=$(display_name "$to_id")
  local attach_note=""
  [ ${#attach_paths[@]} -gt 0 ] && attach_note=" [${#attach_paths[@]} attachment(s)]"
  echo "Sent to ${to_name} (${to_id}): ${subject}${attach_note}$([ "$priority" = "urgent" ] && echo " [URGENT]" || true)"
}

sent() {
  local limit="${1:-20}"
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  local rows
  rows=$(sqlite3 -separator '|' "$MAIL_DB" \
    "SELECT id, to_project, subject, timestamp FROM messages WHERE from_project='${pid}' ORDER BY timestamp DESC LIMIT ${limit};")
  [ -z "$rows" ] && echo "No sent messages" && return 0
  echo "id | to | subject | timestamp"
  while IFS='|' read -r id to_hash subj ts; do
    local to_name
    to_name=$(display_name "$to_hash")
    echo "${id} | ${to_name} (${to_hash}) | ${subj} | ${ts}"
  done <<< "$rows"
}

search() {
  local keyword="$1"
  if [ -z "$keyword" ]; then
    echo "Error: search keyword required" >&2
    return 1
  fi
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  local safe_keyword
  safe_keyword=$(sql_escape "$keyword")
  local rows
  rows=$(sqlite3 -separator '|' "$MAIL_DB" \
    "SELECT id, from_project, subject, CASE WHEN read=0 THEN 'UNREAD' ELSE 'read' END, timestamp FROM messages WHERE to_project='${pid}' AND (subject LIKE '%${safe_keyword}%' OR body LIKE '%${safe_keyword}%') ORDER BY timestamp DESC LIMIT 20;")
  [ -z "$rows" ] && return 0
  echo "id | from | subject | status | timestamp"
  while IFS='|' read -r id from_hash subj status ts; do
    local from_name
    from_name=$(display_name "$from_hash")
    echo "${id} | ${from_name} (${from_hash}) | ${subj} | ${status} | ${ts}"
  done <<< "$rows"
}

list_all() {
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  local limit="${1:-20}"
  if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
    limit=20
  fi
  local rows
  rows=$(sqlite3 -separator '|' "$MAIL_DB" \
    "SELECT id, from_project, subject, CASE WHEN read=0 THEN 'UNREAD' ELSE 'read' END, timestamp FROM messages WHERE to_project='${pid}' ORDER BY timestamp DESC LIMIT ${limit};")
  [ -z "$rows" ] && return 0
  echo "id | from | subject | status | timestamp"
  while IFS='|' read -r id from_hash subj status ts; do
    local from_name
    from_name=$(display_name "$from_hash")
    echo "${id} | ${from_name} (${from_hash}) | ${subj} | ${status} | ${ts}"
  done <<< "$rows"
}

clear_old() {
  init_db
  local days="${1:-7}"
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    days=7
  fi
  local deleted
  deleted=$(sqlite3 "$MAIL_DB" \
    "DELETE FROM messages WHERE read=1 AND timestamp < datetime('now', '-${days} days'); SELECT changes();")
  echo "Cleared ${deleted} read messages older than ${days} days"
}

reply() {
  local -a attach_paths=()
  # Parse flags before positional args
  while [ $# -gt 0 ]; do
    case "$1" in
      --attach) shift; local resolved; resolved=$(resolve_attach "$1") || return 1; attach_paths+=("$resolved"); shift ;;
      *) break ;;
    esac
  done
  local msg_id="$1"
  local body
  body=$(read_body "${2:-}")
  if ! [[ "$msg_id" =~ ^[0-9]+$ ]]; then
    echo "Error: message ID must be numeric" >&2
    return 1
  fi
  if [ -z "$body" ]; then
    echo "Error: reply body cannot be empty" >&2
    return 1
  fi
  init_db
  register_project
  local orig
  orig=$(sqlite3 -separator '|' "$MAIL_DB" "SELECT from_project, subject, thread_id FROM messages WHERE id=${msg_id};")
  if [ -z "$orig" ]; then
    echo "Error: message #${msg_id} not found" >&2
    return 1
  fi
  local orig_from_hash orig_subject orig_thread
  orig_from_hash=$(echo "$orig" | cut -d'|' -f1)
  orig_subject=$(echo "$orig" | cut -d'|' -f2)
  orig_thread=$(echo "$orig" | cut -d'|' -f3)
  # Thread ID: inherit from parent, or use parent's ID as thread root
  local thread_id="${orig_thread:-$msg_id}"
  local from_id
  from_id=$(get_project_id)
  local safe_subject safe_body safe_attachments
  safe_subject=$(sql_escape "Re: ${orig_subject}")
  safe_body=$(sql_escape "$body")
  local attachments=""
  if [ ${#attach_paths[@]} -gt 0 ]; then
    attachments=$(IFS=$'\n'; echo "${attach_paths[*]}")
  fi
  safe_attachments=$(sql_escape "$attachments")
  sqlite3 "$MAIL_DB" \
    "INSERT INTO messages (from_project, to_project, subject, body, thread_id, attachments) VALUES ('${from_id}', '${orig_from_hash}', '${safe_subject}', '${safe_body}', ${thread_id}, '${safe_attachments}');"
  # Signal the recipient
  touch "/tmp/pigeon_signal_${orig_from_hash}"
  local orig_name
  orig_name=$(display_name "$orig_from_hash")
  local attach_note=""
  [ ${#attach_paths[@]} -gt 0 ] && attach_note=" [${#attach_paths[@]} attachment(s)]"
  echo "Replied to ${orig_name} (${orig_from_hash}): Re: ${orig_subject}${attach_note}"
}

thread() {
  local msg_id="$1"
  if ! [[ "$msg_id" =~ ^[0-9]+$ ]]; then
    echo "Error: message ID must be numeric" >&2
    return 1
  fi
  init_db
  # Find the thread root: either the message itself or its thread_id
  local thread_root
  thread_root=$(sqlite3 "$MAIL_DB" "SELECT COALESCE(thread_id, id) FROM messages WHERE id=${msg_id};" 2>/dev/null)
  [ -z "$thread_root" ] && echo "Message not found" && return 1
  # Get all message IDs in this thread (root + replies)
  local ids
  ids=$(sqlite3 "$MAIL_DB" \
    "SELECT id FROM messages WHERE id=${thread_root} OR thread_id=${thread_root} ORDER BY timestamp ASC;")
  [ -z "$ids" ] && echo "No thread found" && return 0
  local msg_count=0
  echo "=== Thread #${thread_root} ==="
  while read -r tid; do
    [ -z "$tid" ] && continue
    local from_hash body ts from_name attachments
    from_hash=$(sqlite3 "$MAIL_DB" "SELECT from_project FROM messages WHERE id=${tid};")
    body=$(sqlite3 "$MAIL_DB" "SELECT body FROM messages WHERE id=${tid};")
    ts=$(sqlite3 "$MAIL_DB" "SELECT timestamp FROM messages WHERE id=${tid};")
    attachments=$(sqlite3 "$MAIL_DB" "SELECT COALESCE(attachments,'') FROM messages WHERE id=${tid};")
    from_name=$(display_name "$from_hash")
    echo ""
    echo "--- #${tid} ${from_name} @ ${ts} ---"
    echo "${body}"
    if [ -n "$attachments" ]; then
      while IFS= read -r apath; do
        [ -z "$apath" ] && continue
        local astat="missing"
        [ -e "$apath" ] && astat="$(wc -c < "$apath" | tr -d ' ') bytes"
        echo "  [Attached: ${apath} (${astat})]"
      done <<< "$attachments"
    fi
    msg_count=$((msg_count + 1))
  done <<< "$ids"
  echo ""
  echo "=== End of thread (${msg_count} messages) ==="
}

broadcast() {
  local subject="$1"
  local body="$2"
  if [ -z "$body" ]; then
    echo "Error: message body cannot be empty" >&2
    return 1
  fi
  init_db
  register_project
  local from_id
  from_id=$(get_project_id)
  local targets
  targets=$(sqlite3 "$MAIL_DB" \
    "SELECT hash FROM projects WHERE hash != '${from_id}' ORDER BY name;")
  local count=0
  local safe_subject safe_body
  safe_subject=$(sql_escape "$subject")
  safe_body=$(sql_escape "$body")
  while IFS= read -r target_hash; do
    [ -z "$target_hash" ] && continue
    sqlite3 "$MAIL_DB" \
      "INSERT INTO messages (from_project, to_project, subject, body) VALUES ('${from_id}', '${target_hash}', '${safe_subject}', '${safe_body}');"
    touch "/tmp/pigeon_signal_${target_hash}"
    count=$((count + 1))
  done <<< "$targets"
  echo "Broadcast to ${count} project(s): ${subject}"
}

status() {
  init_db
  register_project
  local pid
  pid=$(get_project_id)
  local unread total
  unread=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${pid}' AND read=0;")
  total=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${pid}';")
  echo "Inbox: ${unread} unread / ${total} total"
  if [ "${unread:-0}" -gt 0 ]; then
    local senders
    senders=$(sqlite3 -separator '|' "$MAIL_DB" \
      "SELECT from_project, COUNT(*) FROM messages WHERE to_project='${pid}' AND read=0 GROUP BY from_project ORDER BY COUNT(*) DESC;")
    while IFS='|' read -r from_hash cnt; do
      local from_name
      from_name=$(display_name "$from_hash")
      echo "  ${from_name} (${from_hash}): ${cnt} message(s)"
    done <<< "$senders"
  fi
}

purge() {
  init_db
  if [ "${1:-}" = "--all" ]; then
    local count
    count=$(sqlite3 "$MAIL_DB" "DELETE FROM messages; SELECT changes();")
    echo "Purged all ${count} message(s) from database"
  else
    register_project
    local pid
    pid=$(get_project_id)
    local count
    count=$(sqlite3 "$MAIL_DB" \
      "DELETE FROM messages WHERE to_project='${pid}' OR from_project='${pid}'; SELECT changes();")
    local name
    name=$(project_name)
    echo "Purged ${count} message(s) for ${name} (${pid})"
  fi
}

alias_project() {
  local old_name="$1"
  local new_name="$2"
  if [ -z "$old_name" ] || [ -z "$new_name" ]; then
    echo "Error: both old and new project names required" >&2
    return 1
  fi
  init_db
  # Resolve old name to hash, then update the display name
  local old_hash
  old_hash=$(resolve_target "$old_name")
  local safe_new
  safe_new=$(sql_escape "$new_name")
  local safe_old
  safe_old=$(sql_escape "$old_name")
  sqlite3 "$MAIL_DB" \
    "UPDATE projects SET name='${safe_new}' WHERE hash='${old_hash}';"
  # Also update path if it matches the old name (phantom projects)
  sqlite3 "$MAIL_DB" \
    "UPDATE projects SET path='${safe_new}' WHERE hash='${old_hash}' AND path='${safe_old}';"
  echo "Renamed '${old_name}' -> '${new_name}' (hash: ${old_hash})"
}

list_projects() {
  init_db
  register_project
  local rows
  rows=$(sqlite3 -separator '|' "$MAIL_DB" \
    "SELECT hash, name, path FROM projects ORDER BY name;")
  [ -z "$rows" ] && echo "No known projects" && return 0
  local my_id
  my_id=$(get_project_id)
  while IFS='|' read -r hash name path; do
    local marker=""
    [ "$hash" = "$my_id" ] && marker=" (you)"
    echo ""
    # Show identicon if available
    if [ -f "$SCRIPT_DIR/identicon.sh" ]; then
      bash "$SCRIPT_DIR/identicon.sh" "$path" --compact 2>/dev/null || true
    fi
    echo "${name} ${hash}${marker}"
    echo "${path}"
  done <<< "$rows"
}

# Migrate old basename-style messages to hash IDs
migrate() {
  init_db
  register_project
  echo "Migrating old messages to hash-based IDs..."
  # Find all unique project names in messages that aren't 6-char hex hashes
  local old_names
  old_names=$(sqlite3 "$MAIL_DB" \
    "SELECT DISTINCT from_project FROM messages WHERE LENGTH(from_project) != 6 OR from_project GLOB '*[^0-9a-f]*' UNION SELECT DISTINCT to_project FROM messages WHERE LENGTH(to_project) != 6 OR to_project GLOB '*[^0-9a-f]*';")
  if [ -z "$old_names" ]; then
    echo "No messages need migration."
    return 0
  fi
  local count=0
  while IFS= read -r old_name; do
    [ -z "$old_name" ] && continue
    # Try to find the project path - check common locations
    local found_path=""
    for base_dir in "$HOME/projects" "$HOME/Projects" "$HOME/code" "$HOME/Code" "$HOME/dev" "$HOME/repos"; do
      if [ -d "${base_dir}/${old_name}" ]; then
        found_path=$(cd "${base_dir}/${old_name}" && pwd -P)
        break
      fi
    done

    local new_hash
    if [ -n "$found_path" ]; then
      new_hash=$(printf '%s' "$found_path" | shasum -a 256 | cut -c1-6)
      local safe_name safe_path
      safe_name=$(sql_escape "$old_name")
      safe_path=$(sql_escape "$found_path")
      sqlite3 "$MAIL_DB" \
        "INSERT OR IGNORE INTO projects (hash, name, path) VALUES ('${new_hash}', '${safe_name}', '${safe_path}');"
    else
      # Can't find directory - hash the name itself
      new_hash=$(printf '%s' "$old_name" | shasum -a 256 | cut -c1-6)
      local safe_name
      safe_name=$(sql_escape "$old_name")
      sqlite3 "$MAIL_DB" \
        "INSERT OR IGNORE INTO projects (hash, name, path) VALUES ('${new_hash}', '${safe_name}', '${safe_name}');"
    fi

    local safe_old
    safe_old=$(sql_escape "$old_name")
    sqlite3 "$MAIL_DB" "UPDATE messages SET from_project='${new_hash}' WHERE from_project='${safe_old}';"
    sqlite3 "$MAIL_DB" "UPDATE messages SET to_project='${new_hash}' WHERE to_project='${safe_old}';"
    echo "  ${old_name} -> ${new_hash}$([ -n "$found_path" ] && echo " (${found_path})" || echo " (name only)")"
    count=$((count + 1))
  done <<< "$old_names"
  echo "Migrated ${count} project name(s)."
}

# ============================================================================
# Dispatch
# ============================================================================

case "${1:-help}" in
  init)       init_db && echo "Mail database initialized at $MAIL_DB" ;;
  count)      count_unread ;;
  unread)     list_unread ;;
  read)       if [ -n "${2:-}" ]; then read_one "$2"; else read_mail; fi ;;
  send)       shift; send "$@" ;;
  reply)      shift; reply "$@" ;;
  sent)       sent "${2:-20}" ;;
  thread)     thread "${2:?message_id required}" ;;
  list)       list_all "${2:-20}" ;;
  clear)      clear_old "${2:-7}" ;;
  broadcast)  broadcast "${2:-no subject}" "${3:?body required}" ;;
  search)     search "${2:?keyword required}" ;;
  status)     status ;;
  purge)      purge "${2:-}" ;;
  alias)      alias_project "${2:?old name required}" "${3:?new name required}" ;;
  projects)   list_projects ;;
  migrate)    migrate ;;
  id)         init_db; register_project; echo "$(project_name) $(get_project_id)" ;;
  help)
    echo "Usage: mail-db.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init                    Initialize database"
    echo "  id                      Show this project's name and hash"
    echo "  count                   Count unread messages"
    echo "  unread                  List unread messages (brief)"
    echo "  read [id]               Read messages and mark as read"
    echo "  send [--urgent] [--attach <path>]... <to> <subj> <body|->  Send with optional attachments"
    echo "  reply [--attach <path>]... <id> <body|->  Reply with optional attachments"
    echo "  sent [limit]            Show sent messages (outbox)"
    echo "  thread <id>             View full conversation thread"
    echo "  list [limit]            List recent messages (default 20)"
    echo "  clear [days]            Clear read messages older than N days"
    echo "  broadcast <subj> <body> Send to all known projects"
    echo "  search <keyword>        Search messages by keyword"
    echo "  status                  Inbox summary"
    echo "  purge [--all]           Delete all messages for this project"
    echo "  alias <old> <new>       Rename project display name"
    echo "  projects                List known projects with identicons"
    echo "  migrate                 Convert old basename messages to hash IDs"
    ;;
  *)          echo "Unknown command: $1. Run with 'help' for usage." >&2; exit 1 ;;
esac
