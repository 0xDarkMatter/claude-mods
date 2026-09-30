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

PMAIL_DB="$HOME/.claude/pmail.db"
PMAIL_SCRIPT="$HOME/.claude/pigeon/mail-db.sh"

# Claude Code caps additionalContext at 10,000 chars; past that it spills the
# text to a file and shows the model only a 2,000-char preview. 9,000 leaves
# headroom because ${#var} counts bytes or code points, not UTF-16 units.
MAX_CONTEXT=9000

# Guard: this function deliberately SHADOWS the sqlite3 binary, same as the one
# in skills/pigeon/scripts/mail-db.sh. Windows' native sqlite3.exe writes "\r\n"
# in text mode. Command substitution strips only the final newline, so the
# attachment loop below kept a stray "\r" on every path but the last (reported
# "(missing)" although the file existed), and multi-line bodies reached the model
# with CRs. Don't bypass it with `command sqlite3` at a call site.
sqlite3() {
  command sqlite3 "$@" | tr -d '\r'
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

# Fast path: no signal file = no mail. Stat check only, no SQLite.
[ -f "$SIGNAL" ] || exit 0

# Signal exists - check DB to confirm
[ -f "$PMAIL_DB" ] || exit 0

UNREAD=$(sqlite3 "$PMAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0;" 2>/dev/null)

if [ "${UNREAD:-0}" -eq 0 ]; then
  # Signal was stale, clean up
  rm -f "$SIGNAL"
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
  done < <(sqlite3 "$PMAIL_DB" \
    "SELECT id FROM messages WHERE to_project='${PROJECT_HASH}' AND read=0 ORDER BY priority DESC, timestamp ASC;" 2>/dev/null)
}

MESSAGES=$(render_messages)

# Rows vanished between the COUNT and the SELECT (read elsewhere) - nothing to say
if [ -z "$MESSAGES" ]; then
  rm -f "$SIGNAL"
  exit 0
fi

HEADER="=== INCOMING PMAIL (${UNREAD} message(s)) ==="
FOOTER='=== ACTION REQUIRED: Inform the user about these messages and ask if they want to reply. ===
=== Then run: pigeon read (to mark as read) ===
=== To reply: pigeon reply <id> "message" ==='

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

# Clear signal (new sends will re-create it)
rm -f "$SIGNAL"
exit 0
