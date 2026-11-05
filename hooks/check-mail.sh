#!/bin/bash
# hooks/check-mail.sh
# PreToolUse hook - event-driven mail delivery with thread context.
# Checks a signal file (stat, nanoseconds) before touching SQLite.
# Silent when no signal. Delivers full thread context for each message.
#
# Output contract: the delivery text reaches the model ONLY as JSON on stdout -
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"<text>"}}
# Guard: do not "simplify" this back to plain echo. For PreToolUse, plain stdout
# on exit 0 goes to the debug log, never the model (it is added to context only
# for UserPromptSubmit/SessionStart and a few others - see "Exit code 0" in
# https://code.claude.com/docs/en/hooks). The echo-only original delivered
# nothing to the model (headless `claude -p` check, Claude Code 2.1.280,
# 2026-09-30). Nothing else may write to stdout, or the JSON stops parsing.
# Requires jq; without it the hook is a silent no-op and mail is still
# reachable via `pigeon read`.
#
# Delivery is PER SESSION (skills/pigeon/SKILL.md, "Passive Notification"):
#   - A project's inbox is shared by every session in it. Identity is the git
#     root commit, so a repo's main checkout and all of its worktrees are one
#     project: a lane's report to the coordinator lands in the lane's inbox too.
#   - /tmp/pigeon_signal_<hash> is a TIMESTAMP: every send touches it, and
#     nothing deletes it. Guard: don't go back to deleting it after rendering.
#     The file is shared by every session with the hash, so the first one to
#     render (usually the lane that sent the report) deleted the wake-up all
#     the others needed, and the coordinator was never told (2026-10-06).
#   - /tmp/pigeon_seen_<hash>_<session_id> belongs to one session. Content: the
#     highest message id it has been shown. Mtime: when that check STARTED. The
#     fast path is one stat comparison - a signal no newer than this session's
#     marker means nothing was sent since it last looked.
#   - A session is never shown mail it sent itself: mail-db.sh stores the
#     sender's CLAUDE_CODE_SESSION_ID in messages.from_session, which is the
#     same id Claude Code passes this hook as stdin .session_id.
#   - Without a session id (a manual run, another harness) the marker key is
#     "anon", shared by every such caller - the old one-notice-per-send behaviour.

PMAIL_DB="$HOME/.claude/pmail.db"

# Claude Code caps additionalContext at 10,000 chars; past that it spills the
# text to a file and shows the model only a 2,000-char preview. 9,000 leaves
# headroom because ${#var} counts bytes or code points, not UTF-16 units.
MAX_CONTEXT=9000

# Guard: this function deliberately SHADOWS the sqlite3 binary, same as the one
# in skills/pigeon/scripts/mail-db.sh. Windows' native sqlite3.exe writes "\r\n"
# in text mode. Command substitution strips only the final newline, so the
# attachment loop below kept a stray "\r" on every path but the last (reported
# "(missing)" although the file existed), and multi-line bodies reached the model
# with CRs. Don't bypass it with `command sqlite3` at a call site. It returns
# sqlite3's own status, not tr's: a failed query must not read as "no mail".
sqlite3() {
  command sqlite3 "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# Skip if disabled for this project
[ -f ".claude/pigeon.disable" ] && exit 0

# No jq, no way to build the envelope - stay silent (and leave the signal set)
command -v jq >/dev/null 2>&1 || exit 0

# Project identity: git root commit hash, fallback to path hash
ROOT_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
if [ -n "$ROOT_COMMIT" ]; then
  PROJECT_HASH="${ROOT_COMMIT:0:6}"
else
  CANONICAL=$(cd "$PWD" && pwd -P)
  PROJECT_HASH=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-6)
fi

SIGNAL="/tmp/pigeon_signal_${PROJECT_HASH}"

# No signal file = nothing was ever sent to this project. Stat check only.
[ -f "$SIGNAL" ] || exit 0

# This session's id, from the hook's stdin JSON. The regex is the fast path:
# Claude Code sends session_id as the FIRST key, and anchoring on that keeps a
# nested "session_id" inside tool_input (a send_message call has one) from
# matching. jq parses anything else, so a reordered payload still filters.
SID=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
  sid_re='^[[:space:]]*\{[[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $INPUT =~ $sid_re ]]; then
    SID="${BASH_REMATCH[1]}"
  elif [ -n "$INPUT" ]; then
    SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
  fi
fi
# The id lands in a file name and a SQL literal: anything not id-shaped is dropped.
[[ $SID =~ ^[A-Za-z0-9_-]{1,128}$ ]] || SID=""
SEEN="/tmp/pigeon_seen_${PROJECT_HASH}_${SID:-anon}"

# Fast path: this session looked after the last send. -nt is false for equal
# mtimes, so a send in the same clock tick as the last check still gets a look.
[ "$SEEN" -nt "$SIGNAL" ] && exit 0

[ -f "$PMAIL_DB" ] || exit 0

# Stamp the START of this check before querying. The marker written at the end
# takes this mtime, so a send that lands mid-query leaves the signal newer than
# the marker and the next call picks it up (the old delete-after-render lost it).
STAMP="${SEEN}.$$.t0"
: > "$STAMP" 2>/dev/null || exit 0

LAST=0
[ -f "$SEEN" ] && read -r LAST < "$SEEN" 2>/dev/null
[[ $LAST =~ ^[0-9]+$ ]] || LAST=0

# mark_seen <id>: record the highest id shown, stamped with the check's start.
mark_seen() {
  printf '%s\n' "$1" > "$STAMP.new" 2>/dev/null \
    && touch -r "$STAMP" "$STAMP.new" 2>/dev/null \
    && mv -f "$STAMP.new" "$SEEN" 2>/dev/null
  rm -f "$STAMP" "$STAMP.new"
}

# New for this session: unread, above its marker, and not sent by it. The
# from_session column arrives with mail-db.sh's migration; a database that
# predates it (an older mail-db.sh install) can hold no session ids, so the
# filter is skipped there rather than failing the query.
WHERE="to_project='${PROJECT_HASH}' AND read=0 AND id>${LAST}"
if [ -n "$SID" ]; then
  HAS_FROM_SESSION=$(sqlite3 "$PMAIL_DB" "SELECT COUNT(*) FROM pragma_table_info('messages') WHERE name='from_session';" 2>/dev/null)
  [ "${HAS_FROM_SESSION:-0}" -gt 0 ] && WHERE="${WHERE} AND COALESCE(from_session,'')<>'${SID}'"
fi

# A failed query (database busy, unreadable) leaves the marker untouched, so the
# signal stays newer and the next tool call retries instead of skipping the mail.
if ! IDS=$(sqlite3 -cmd ".timeout 2000" "$PMAIL_DB" \
    "SELECT id FROM messages WHERE ${WHERE} ORDER BY priority DESC, timestamp ASC;" 2>/dev/null); then
  rm -f "$STAMP"
  exit 0
fi

UNREAD=0
MAX_ID=$LAST
while read -r msg_id; do
  [ -z "$msg_id" ] && continue
  UNREAD=$((UNREAD + 1))
  [ "$msg_id" -gt "$MAX_ID" ] && MAX_ID=$msg_id
done <<< "$IDS"

# Nothing new for this session (its own send, or mail it was already shown)
if [ "$UNREAD" -eq 0 ]; then
  mark_seen "$LAST"
  exit 0
fi

# Resolve display name for a hash
show_from() {
  local hash="$1"
  local name
  name=$(sqlite3 "$PMAIL_DB" "SELECT name FROM projects WHERE hash='${hash}';" 2>/dev/null)
  [ -n "$name" ] && echo "$name" || echo "$hash"
}

# Print each message with thread context. Captured into MESSAGES below, not
# sent to stdout directly (see the output contract at the top).
render_messages() {
  while read -r msg_id; do
    [ -z "$msg_id" ] && continue
    from_hash=$(sqlite3 "$PMAIL_DB" "SELECT from_project FROM messages WHERE id=${msg_id};" 2>/dev/null)
    priority=$(sqlite3 "$PMAIL_DB" "SELECT priority FROM messages WHERE id=${msg_id};" 2>/dev/null)
    subject=$(sqlite3 "$PMAIL_DB" "SELECT subject FROM messages WHERE id=${msg_id};" 2>/dev/null)
    body=$(sqlite3 "$PMAIL_DB" "SELECT body FROM messages WHERE id=${msg_id};" 2>/dev/null)
    timestamp=$(sqlite3 "$PMAIL_DB" "SELECT timestamp FROM messages WHERE id=${msg_id};" 2>/dev/null)
    thread_id=$(sqlite3 "$PMAIL_DB" "SELECT thread_id FROM messages WHERE id=${msg_id};" 2>/dev/null)
    from_name=$(show_from "$from_hash")
    urgent=""
    [ "$priority" = "urgent" ] && urgent=" [URGENT]"

    attachments=$(sqlite3 "$PMAIL_DB" "SELECT COALESCE(attachments,'') FROM messages WHERE id=${msg_id};" 2>/dev/null)

    echo ""
    echo "--- #${msg_id} from ${from_name} (${from_hash})${urgent} @ ${timestamp} ---"
    echo "Subject: ${subject}"
    echo "${body}"

    # Show attachments
    if [ -n "$attachments" ]; then
      echo ""
      while IFS= read -r apath; do
        [ -z "$apath" ] && continue
        if [ -e "$apath" ]; then
          echo "[Attached: ${apath} ($(wc -c < "$apath" | tr -d ' ') bytes)] <-- Use Read tool to view"
        else
          echo "[Attached: ${apath} (missing)]"
        fi
      done <<< "$attachments"
    fi

    # Show thread context if this is part of a conversation
    if [ -n "$thread_id" ]; then
      thread_root="$thread_id"
      thread_count=$(sqlite3 "$PMAIL_DB" "SELECT COUNT(*) FROM messages WHERE id=${thread_root} OR thread_id=${thread_root};" 2>/dev/null)
      if [ "${thread_count:-0}" -gt 1 ]; then
        echo ""
        echo "[Thread #${thread_root} - ${thread_count} messages. Run: pigeon thread ${thread_root}]"
      fi
    fi
  done <<< "$IDS"
}

MESSAGES=$(render_messages)

# Rows vanished between the id query and the render (read elsewhere) - nothing to say
if [ -z "$MESSAGES" ]; then
  mark_seen "$MAX_ID"
  exit 0
fi

# In a linked worktree the inbox is shared with the main checkout and every
# sibling worktree, so a bare `pigeon read` would mark their mail read too -
# including lane reports the coordinator has not seen yet. Point at per-id reads.
# Git before 2.31 echoes the unknown --path-format flag back as its first line
# instead of failing; that reads as "not a worktree" (the -* case).
READ_LINE='=== Then run: pigeon read (to mark as read) ==='
{ read -r WT_GIT_DIR; read -r WT_COMMON_DIR; } <<< \
  "$(git rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)"
if [ -n "$WT_COMMON_DIR" ] && [[ $WT_GIT_DIR != -* ]] && [ "$WT_GIT_DIR" != "$WT_COMMON_DIR" ]; then
  READ_LINE='=== This session is in a git worktree: it shares this inbox with the main checkout and every other worktree. ===
=== Mark read only mail meant for THIS session, one at a time: pigeon read <id>. A bare pigeon read takes theirs too. ==='
fi

HEADER="=== INCOMING PMAIL (${UNREAD} message(s)) ==="
FOOTER="=== ACTION REQUIRED: Inform the user about these messages and ask if they want to reply. ===
${READ_LINE}
=== To reply: pigeon reply <id> \"message\" ==="

# Truncate the message bodies, never the header or the ACTION REQUIRED footer.
# 200 covers the truncation notice and the joining newlines.
BUDGET=$(( MAX_CONTEXT - ${#HEADER} - ${#FOOTER} - 200 ))
if [ "${#MESSAGES}" -gt "$BUDGET" ]; then
  DROPPED=$(( ${#MESSAGES} - BUDGET ))
  MESSAGES="${MESSAGES:0:$BUDGET}

[... ${DROPPED} more chars truncated to fit the hook context limit. Run: pigeon read for the full text ...]"
fi

CONTEXT="${HEADER}
${MESSAGES}

${FOOTER}"

jq -n --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'

# Delivered: this session is told about each message once. The shared signal
# stays - other sessions with this project hash still need it.
mark_seen "$MAX_ID"
exit 0
