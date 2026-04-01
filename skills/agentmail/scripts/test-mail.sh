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
echo "=== Results ==="
echo "Passed: $PASS / $TOTAL"
echo "Failed: $FAIL / $TOTAL"
echo ""
echo "$PASS"
