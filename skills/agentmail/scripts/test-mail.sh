#!/bin/bash
# test-mail.sh - Test harness for mail-ops
# Outputs: number of passing test cases
# Each test prints PASS/FAIL and we count PASSes at the end

set -uo pipefail

MAIL_DB="$HOME/.claude/mail.db"
MAIL_SCRIPT="$(dirname "$0")/mail-db.sh"
HOOK_SCRIPT="$(dirname "$0")/../../hooks/check-mail.sh"
# Resolve relative to repo root if needed
if [ ! -f "$HOOK_SCRIPT" ]; then
  HOOK_SCRIPT="$(cd "$(dirname "$0")/../../.." && pwd)/hooks/check-mail.sh"
fi

PASS=0
FAIL=0
TOTAL=0

assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_empty() {
  local name="$1"
  local value="$2"
  TOTAL=$((TOTAL + 1))
  if [ -n "$value" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (was empty)"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local name="$1"
  local value="$2"
  TOTAL=$((TOTAL + 1))
  if [ -z "$value" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected empty, got '$value')"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (exit code expected=$expected, actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup: clean slate ---
rm -f "$MAIL_DB"

echo "=== Basic Operations ==="

# T1: Init creates database
bash "$MAIL_SCRIPT" init >/dev/null 2>&1
assert "init creates database" "true" "$([ -f "$MAIL_DB" ] && echo true || echo false)"

# T2: Count on empty inbox
result=$(bash "$MAIL_SCRIPT" count)
assert "empty inbox count is 0" "0" "$result"

# T3: Send a message
result=$(bash "$MAIL_SCRIPT" send "test-project" "Hello" "World" 2>&1)
assert_contains "send succeeds" "Sent to test-project" "$result"

# T4: Count after send (we're in claude-mods, sent to test-project)
result=$(bash "$MAIL_SCRIPT" count)
assert "count still 0 for sender project" "0" "$result"

# T5: Send to self
result=$(bash "$MAIL_SCRIPT" send "claude-mods" "Self mail" "Testing self-send" 2>&1)
assert_contains "self-send succeeds" "Sent to claude-mods" "$result"

# T6: Count after self-send
result=$(bash "$MAIL_SCRIPT" count)
assert "count is 1 after self-send" "1" "$result"

# T7: Unread shows message
result=$(bash "$MAIL_SCRIPT" unread)
assert_contains "unread shows subject" "Self mail" "$result"

# T8: Read marks as read
bash "$MAIL_SCRIPT" read >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
assert "count is 0 after read" "0" "$result"

# T9: List shows read messages
result=$(bash "$MAIL_SCRIPT" list)
assert_contains "list shows read status" "read" "$result"

# T10: Projects lists known projects
result=$(bash "$MAIL_SCRIPT" projects)
assert_contains "projects lists claude-mods" "claude-mods" "$result"
assert_contains "projects lists test-project" "test-project" "$result"

echo ""
echo "=== Edge Cases ==="

# T11: Empty body - should fail gracefully
result=$(bash "$MAIL_SCRIPT" send "target" "subject" "" 2>&1)
exit_code=$?
# Empty body should either fail or send empty - document the behavior
TOTAL=$((TOTAL + 1))
if [ $exit_code -ne 0 ] || echo "$result" | grep -qiE "error|required|empty"; then
  echo "PASS: empty body rejected or warned"
  PASS=$((PASS + 1))
else
  echo "FAIL: empty body accepted silently"
  FAIL=$((FAIL + 1))
fi

# T12: Missing arguments to send
result=$(bash "$MAIL_SCRIPT" send 2>&1)
exit_code=$?
assert_exit_code "send with no args fails" "1" "$exit_code"

# T13: SQL injection in subject
bash "$MAIL_SCRIPT" send "claude-mods" "'; DROP TABLE messages; --" "injection test" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
# If table still exists and count works, injection failed (good)
TOTAL=$((TOTAL + 1))
if [ -n "$result" ] && [ "$result" -ge 0 ] 2>/dev/null; then
  echo "PASS: SQL injection in subject blocked"
  PASS=$((PASS + 1))
else
  echo "FAIL: SQL injection may have succeeded"
  FAIL=$((FAIL + 1))
fi

# T14: SQL injection in body
bash "$MAIL_SCRIPT" send "claude-mods" "test" "'); DELETE FROM messages; --" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
TOTAL=$((TOTAL + 1))
if [ -n "$result" ] && [ "$result" -ge 0 ] 2>/dev/null; then
  echo "PASS: SQL injection in body blocked"
  PASS=$((PASS + 1))
else
  echo "FAIL: SQL injection in body may have succeeded"
  FAIL=$((FAIL + 1))
fi

# T15: SQL injection in project name
bash "$MAIL_SCRIPT" send "'; DROP TABLE messages; --" "test" "injection via project" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
TOTAL=$((TOTAL + 1))
if [ -n "$result" ] && [ "$result" -ge 0 ] 2>/dev/null; then
  echo "PASS: SQL injection in project name blocked"
  PASS=$((PASS + 1))
else
  echo "FAIL: SQL injection in project name may have succeeded"
  FAIL=$((FAIL + 1))
fi

# T16: Special characters in body (newlines, quotes, backslashes)
bash "$MAIL_SCRIPT" send "claude-mods" "special chars" 'Line1\nLine2 "quoted" and back\\slash' >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" read 2>&1)
assert_contains "special chars preserved" "special chars" "$result"

# T17: Very long message body (1000+ chars)
long_body=$(python3 -c "print('x' * 2000)" 2>/dev/null || printf '%0.s.' $(seq 1 2000))
bash "$MAIL_SCRIPT" send "claude-mods" "long msg" "$long_body" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
assert "long message accepted" "1" "$result"
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

# T18: Unicode in subject and body
bash "$MAIL_SCRIPT" send "claude-mods" "Unicode test" "Hello from Tokyo" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" read 2>&1)
assert_contains "unicode in body" "Tokyo" "$result"

# T19: Read by specific ID
bash "$MAIL_SCRIPT" send "claude-mods" "ID test" "Read me by ID" >/dev/null 2>&1
msg_id=$(sqlite3 "$MAIL_DB" "SELECT id FROM messages WHERE subject='ID test' AND read=0 LIMIT 1;")
result=$(bash "$MAIL_SCRIPT" read "$msg_id" 2>&1)
assert_contains "read by ID works" "Read me by ID" "$result"

# T20: Read by invalid ID
result=$(bash "$MAIL_SCRIPT" read 99999 2>&1)
assert_empty "read invalid ID returns nothing" "$result"

echo ""
echo "=== Hook Tests ==="

# T21: Hook silent on empty inbox
bash "$MAIL_SCRIPT" read >/dev/null 2>&1  # clear any unread
result=$(bash "$HOOK_SCRIPT" 2>&1)
assert_empty "hook silent when no mail" "$result"

# T22: Hook shows notification
bash "$MAIL_SCRIPT" send "claude-mods" "Hook test" "Should trigger hook" >/dev/null 2>&1
result=$(bash "$HOOK_SCRIPT" 2>&1)
assert_contains "hook shows MAIL notification" "MAIL" "$result"
assert_contains "hook shows message count" "1 unread" "$result"

# T23: Hook with missing database
backup_db="${MAIL_DB}.testbak"
mv "$MAIL_DB" "$backup_db"
result=$(bash "$HOOK_SCRIPT" 2>&1)
exit_code=$?
assert_exit_code "hook exits 0 with missing db" "0" "$exit_code"
assert_empty "hook silent with missing db" "$result"
mv "$backup_db" "$MAIL_DB"

echo ""
echo "=== Cleanup ==="

# T24: Clear old messages
bash "$MAIL_SCRIPT" read >/dev/null 2>&1  # mark all as read
result=$(bash "$MAIL_SCRIPT" clear 0 2>&1)
assert_contains "clear reports deleted count" "Cleared" "$result"

# T25: Count after clear
result=$(bash "$MAIL_SCRIPT" count)
assert "count 0 after clear" "0" "$result"

# T26: Help command
result=$(bash "$MAIL_SCRIPT" help 2>&1)
assert_contains "help shows usage" "Usage" "$result"

# T27: Unknown command
result=$(bash "$MAIL_SCRIPT" nonexistent 2>&1)
exit_code=$?
assert_exit_code "unknown command fails" "1" "$exit_code"

echo ""
echo "=== Input Validation ==="

# T28: Non-numeric message ID rejected
result=$(bash "$MAIL_SCRIPT" read "abc" 2>&1)
exit_code=$?
assert_exit_code "non-numeric ID rejected" "1" "$exit_code"

# T29: SQL injection via message ID
bash "$MAIL_SCRIPT" send "claude-mods" "id-inject-test" "before injection" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" read "1 OR 1=1" 2>&1)
exit_code=$?
assert_exit_code "SQL injection via ID rejected" "1" "$exit_code"

# T30: Non-numeric limit in list
result=$(bash "$MAIL_SCRIPT" list "abc" 2>&1)
exit_code=$?
assert_exit_code "non-numeric limit handled" "0" "$exit_code"

# T31: Non-numeric days in clear
result=$(bash "$MAIL_SCRIPT" clear "abc" 2>&1)
assert_contains "non-numeric days handled" "Cleared" "$result"

# T32: Single quotes in subject preserved
bash "$MAIL_SCRIPT" read >/dev/null 2>&1  # clear unread
bash "$MAIL_SCRIPT" send "claude-mods" "it's working" "body with 'quotes'" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" read 2>&1)
assert_contains "single quotes in subject" "it's working" "$result"

# T33: Double quotes in body preserved
bash "$MAIL_SCRIPT" send "claude-mods" "quotes" 'She said "hello"' >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" read 2>&1)
assert_contains "double quotes in body" "hello" "$result"

# T34: Project name with spaces (edge case)
bash "$MAIL_SCRIPT" send "my project" "spaces" "project name has spaces" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" projects)
assert_contains "project with spaces stored" "my project" "$result"

# T35: Multiple rapid sends
for i in 1 2 3 4 5; do
  bash "$MAIL_SCRIPT" send "claude-mods" "rapid-$i" "rapid fire test $i" >/dev/null 2>&1
done
result=$(bash "$MAIL_SCRIPT" count)
assert "5 rapid sends all counted" "5" "$result"
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

# T36: Init is idempotent
bash "$MAIL_SCRIPT" init >/dev/null 2>&1
bash "$MAIL_SCRIPT" init >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" count)
assert "init idempotent" "0" "$result"

# T37: Empty subject defaults
result=$(bash "$MAIL_SCRIPT" send "claude-mods" "" "empty subject body" 2>&1)
assert_contains "empty subject accepted" "Sent to claude-mods" "$result"
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Reply ==="

# T38: Reply to a message
bash "$MAIL_SCRIPT" send "claude-mods" "Original msg" "Please reply" >/dev/null 2>&1
msg_id=$(sqlite3 "$MAIL_DB" "SELECT id FROM messages WHERE subject='Original msg' AND read=0 LIMIT 1;")
bash "$MAIL_SCRIPT" read "$msg_id" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" reply "$msg_id" "Here is my reply" 2>&1)
assert_contains "reply succeeds" "Replied to claude-mods" "$result"
assert_contains "reply has Re: prefix" "Re: Original msg" "$result"

# T39: Reply to nonexistent message
result=$(bash "$MAIL_SCRIPT" reply 99999 "reply to nothing" 2>&1)
exit_code=$?
assert_exit_code "reply to nonexistent fails" "1" "$exit_code"

# T40: Reply with empty body
result=$(bash "$MAIL_SCRIPT" reply "$msg_id" "" 2>&1)
exit_code=$?
assert_exit_code "reply with empty body fails" "1" "$exit_code"

# T41: Reply with non-numeric ID
result=$(bash "$MAIL_SCRIPT" reply "abc" "body" 2>&1)
exit_code=$?
assert_exit_code "reply with non-numeric ID fails" "1" "$exit_code"

# Clean up
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Priority & Search ==="

# T38: Send urgent message
result=$(bash "$MAIL_SCRIPT" send --urgent "claude-mods" "Server down" "Production is on fire" 2>&1)
assert_contains "urgent send succeeds" "URGENT" "$result"

# T39: Hook highlights urgent
rm -f /tmp/agentmail_check_* 2>/dev/null
result=$(bash "$HOOK_SCRIPT" 2>&1)
assert_contains "hook shows URGENT" "URGENT" "$result"
assert_contains "hook shows [!] prefix" "[!]" "$result"
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

# T40: Normal send still works after priority feature
result=$(bash "$MAIL_SCRIPT" send "claude-mods" "Normal msg" "not urgent" 2>&1)
TOTAL=$((TOTAL + 1))
if echo "$result" | grep -qvF "URGENT"; then
  echo "PASS: normal send has no URGENT tag"
  PASS=$((PASS + 1))
else
  echo "FAIL: normal send incorrectly tagged URGENT"
  FAIL=$((FAIL + 1))
fi
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

# T41: Search by keyword in subject
bash "$MAIL_SCRIPT" send "claude-mods" "API endpoint changed" "details here" >/dev/null 2>&1
bash "$MAIL_SCRIPT" send "claude-mods" "unrelated" "nothing relevant" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" search "API" 2>&1)
assert_contains "search finds by subject" "API endpoint" "$result"

# T42: Search by keyword in body
result=$(bash "$MAIL_SCRIPT" search "relevant" 2>&1)
assert_contains "search finds by body" "unrelated" "$result"

# T43: Search with no results
result=$(bash "$MAIL_SCRIPT" search "xyznonexistent" 2>&1)
assert_empty "search no results is empty" "$result"

# T44: Search with no keyword fails
result=$(bash "$MAIL_SCRIPT" search 2>&1)
exit_code=$?
assert_exit_code "search no keyword fails" "1" "$exit_code"

bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Broadcast & Status ==="

# Setup: ensure multiple projects exist
bash "$MAIL_SCRIPT" send "project-a" "setup" "creating project-a" >/dev/null 2>&1
bash "$MAIL_SCRIPT" send "project-b" "setup" "creating project-b" >/dev/null 2>&1

# T42: Broadcast sends to all known projects except self
result=$(bash "$MAIL_SCRIPT" broadcast "Announcement" "Main is frozen" 2>&1)
assert_contains "broadcast reports count" "Broadcast to" "$result"

# T43: Broadcast doesn't send to self
self_count=$(sqlite3 "$MAIL_DB" "SELECT COUNT(*) FROM messages WHERE to_project='claude-mods' AND subject='Announcement';")
assert "broadcast skips self" "0" "$self_count"

# T44: Broadcast with empty body fails
result=$(bash "$MAIL_SCRIPT" broadcast "test" "" 2>&1)
exit_code=$?
assert_exit_code "broadcast empty body fails" "1" "$exit_code"

# T45: Status shows inbox summary
bash "$MAIL_SCRIPT" send "claude-mods" "Status test 1" "msg1" >/dev/null 2>&1
bash "$MAIL_SCRIPT" send "claude-mods" "Status test 2" "msg2" >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" status 2>&1)
assert_contains "status shows unread count" "unread" "$result"
assert_contains "status shows Inbox" "Inbox" "$result"

# T46: Status on empty inbox
bash "$MAIL_SCRIPT" read >/dev/null 2>&1
result=$(bash "$MAIL_SCRIPT" status 2>&1)
assert_contains "status shows 0 unread" "0 unread" "$result"

echo ""
echo "=== Alias (Rename) ==="

# Setup: send messages with old project name
bash "$MAIL_SCRIPT" send "old-project" "before rename" "testing alias" >/dev/null 2>&1
bash "$MAIL_SCRIPT" send "claude-mods" "from old" "message from old name" >/dev/null 2>&1

# T47: Alias renames in all messages
result=$(bash "$MAIL_SCRIPT" alias "old-project" "new-project" 2>&1)
assert_contains "alias reports rename" "Renamed" "$result"
assert_contains "alias shows old name" "old-project" "$result"
assert_contains "alias shows new name" "new-project" "$result"

# T48: Old project name no longer appears
result=$(bash "$MAIL_SCRIPT" projects)
TOTAL=$((TOTAL + 1))
if echo "$result" | grep -qF "old-project"; then
  echo "FAIL: old project name still present after alias"
  FAIL=$((FAIL + 1))
else
  echo "PASS: old project name removed after alias"
  PASS=$((PASS + 1))
fi

# T49: New project name appears
assert_contains "new project name present" "new-project" "$result"

# T50: Alias with missing args fails
result=$(bash "$MAIL_SCRIPT" alias "only-one" 2>&1)
exit_code=$?
assert_exit_code "alias with missing arg fails" "1" "$exit_code"

# Clean up
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Performance ==="

# T38: Hook cooldown - second call within cooldown is silent even with mail
bash "$MAIL_SCRIPT" send "claude-mods" "cooldown test" "testing cooldown" >/dev/null 2>&1
# Clear any cooldown files for current PID
rm -f /tmp/agentmail_check_* 2>/dev/null
# First call should show mail
result1=$(bash "$HOOK_SCRIPT" 2>&1)
assert_contains "hook fires on first call" "MAIL" "$result1"
# Note: can't easily test cooldown across separate bash invocations since PID changes
# But we can verify the cooldown file was created
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Per-Project Disable ==="

# T52: Hook respects .claude/agentmail.disable
bash "$MAIL_SCRIPT" send "claude-mods" "disable test" "should not appear" >/dev/null 2>&1
rm -f /tmp/agentmail_check_* 2>/dev/null
mkdir -p .claude
touch .claude/agentmail.disable
result=$(bash "$HOOK_SCRIPT" 2>&1)
assert_empty "hook silent when disabled" "$result"

# T53: Hook works again after removing disable file
rm -f .claude/agentmail.disable
rm -f /tmp/agentmail_check_* 2>/dev/null
result=$(bash "$HOOK_SCRIPT" 2>&1)
assert_contains "hook works after re-enable" "MAIL" "$result"
bash "$MAIL_SCRIPT" read >/dev/null 2>&1

echo ""
echo "=== Results ==="
echo "Passed: $PASS / $TOTAL"
echo "Failed: $FAIL / $TOTAL"
echo ""
echo "$PASS"
