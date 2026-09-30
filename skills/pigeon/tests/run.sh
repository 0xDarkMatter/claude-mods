#!/usr/bin/env bash
# Behavioural tests for pigeon. HOME is isolated before any production script
# runs so ~/.claude/pmail.db always resolves inside the disposable sandbox.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
MAIL="$SKILL/scripts/mail-db.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"
mkdir -p "$HOME"
DB="$HOME/.claude/pmail.db"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_eq() { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (want '$2', got '$3')"; }

echo "=== pigeon behavioural self-test ==="

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required" >&2; exit 1; }
bash -n "$MAIL" && ok "bash -n mail-db.sh" || no "bash -n mail-db.sh"
# NOTE: scripts/test-mail.sh (the legacy harness) is deliberately NOT invoked
# here — it blocks indefinitely (rc=124) and would hang CI. The focused
# corruption guards below are the authoritative signal; see the spawned
# follow-up task for the test-mail.sh hang itself.

echo "-- migration idempotency and schema --"
rm -f "$DB"
bash "$MAIL" migrate >/dev/null
schema_first="$(sqlite3 "$DB" ".schema")"
bash "$MAIL" migrate >/dev/null
schema_second="$(sqlite3 "$DB" ".schema")"
expect_eq "second migration leaves schema identical" "$schema_first" "$schema_second"

tables="$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('messages','projects') ORDER BY name;" | tr -d '\r')"
expect_eq "expected tables exist" $'messages\nprojects' "$tables"

columns="$(sqlite3 "$DB" "SELECT name FROM pragma_table_info('messages') WHERE name IN ('priority','thread_id','attachments') ORDER BY name;" | tr -d '\r')"
expect_eq "migration columns exist once" $'attachments\npriority\nthread_id' "$columns"

echo "-- round trip --"
bash "$MAIL" send "$(pwd)" "round trip" "isolated body" >/dev/null
expect_eq "unread count after send" "1" "$(bash "$MAIL" count)"
read_out="$(bash "$MAIL" read)"
case "$read_out" in *"round trip"*"isolated body"*) ok "read returns sent message";; *) no "read omitted sent message";; esac
expect_eq "read marks message read" "0" "$(bash "$MAIL" count)"

echo "-- attachments --"
# Regression: Windows' sqlite3.exe emits "\r\n", which left a stray "\r" on every
# attachment path but the last, so existing files read back as "(missing)".
# Two or more attachments are needed: the LAST line always survived.
printf 'alpha' > "$SB/att-one.txt"
printf 'beta!' > "$SB/att-two.txt"
bash "$MAIL" send --attach "$SB/att-one.txt" --attach "$SB/att-two.txt" "$(pwd)" "attach trip" "two files" >/dev/null
att_out="$(bash "$MAIL" read)"
case "$att_out" in *"(missing)"*) no "every existing attachment resolves (got: (missing))";; *) ok "every existing attachment resolves";; esac
expect_eq "each attachment reports its size" "2" "$(printf '%s\n' "$att_out" | grep -c '(5 bytes)')"

echo "-- hook delivery (PreToolUse additionalContext envelope) --"
# Regression: check-mail.sh used to echo plain text, which Claude Code sends to
# the debug log for PreToolUse - the model never saw a single notification. The
# hook must print exactly one JSON envelope (contract at the top of the hook).
# It runs from a throwaway non-git dir so its /tmp/pigeon_signal_* name is
# unique to this run and a live pigeon session's hook can't clear it mid-test.
HOOK="$(cd "$SKILL/../.." && pwd)/hooks/check-mail.sh"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  hook envelope tests (jq not installed)"
else
  mkdir -p "$SB/hookproj"
  hook() { (cd "$SB/hookproj" && bash "$HOOK" </dev/null); }
  mail_hookproj() { (cd "$SB/hookproj" && bash "$MAIL" send "$(pwd)" "$1" "$2" </dev/null >/dev/null); }
  envelope_event() { printf '%s' "$1" | jq -rs 'if length == 1 then .[0].hookSpecificOutput.hookEventName else "not-one-json-value" end' 2>/dev/null; }
  # tr: Windows jq.exe writes -r output in text mode (every "\n" becomes "\r\n").
  # Test for CRs inside the string with envelope_has_cr, never on this output.
  envelope_ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | tr -d '\r'; }
  envelope_has_cr() { printf '%s' "$1" | jq '.hookSpecificOutput.additionalContext | test("\r")' 2>/dev/null | tr -d '\r'; }

  expect_eq "hook silent with no mail" "" "$(hook)"

  mail_hookproj "envelope trip" $'line one\nsays "quoted" \\ back'
  hook_out="$(hook)"
  expect_eq "hook prints exactly one PreToolUse envelope" "PreToolUse" "$(envelope_event "$hook_out")"
  ctx="$(envelope_ctx "$hook_out")"
  case "$ctx" in
    *"INCOMING PMAIL"*"envelope trip"*'says "quoted" \ back'*"ACTION REQUIRED"*) ok "additionalContext carries header, message and footer";;
    *) no "additionalContext missing delivery text (got: ${ctx:0:200})";;
  esac
  expect_eq "hook silent once its signal is cleared" "" "$(hook)"

  # Over the 10,000-char additionalContext cap Claude Code shows the model only a
  # 2,000-char preview, so the hook truncates bodies but keeps the footer.
  mail_hookproj "big one" "$(head -c 12000 /dev/zero | tr '\0' x)"
  ctx="$(envelope_ctx "$(hook)")"
  [[ -n "$ctx" && "${#ctx}" -lt 10000 ]] && ok "oversized mail stays under the 10k cap (${#ctx} chars)" || no "oversized mail is ${#ctx} chars"
  case "$ctx" in *"truncated"*"pigeon read"*) ok "truncation points at pigeon read";; *) no "truncation notice missing";; esac
  expect_eq "footer survives truncation" '=== To reply: pigeon reply <id> "message" ===' "$(printf '%s\n' "$ctx" | tail -n 1)"

  # Regression (Windows): the hook has its own attachment loop, so it carried the
  # same sqlite3.exe "\r\n" bug mail-db.sh had - every path but the last showed
  # "(missing)", and multi-line bodies reached the model with stray CRs.
  (cd "$SB/hookproj" && bash "$MAIL" read </dev/null >/dev/null)
  (cd "$SB/hookproj" && bash "$MAIL" send --attach "$SB/att-one.txt" --attach "$SB/att-two.txt" "$(pwd)" "hook attach" $'two\nlines' </dev/null >/dev/null)
  hook_out="$(hook)"
  ctx="$(envelope_ctx "$hook_out")"
  case "$ctx" in *"(missing)"*) no "hook resolves every existing attachment (got: (missing))";; *) ok "hook resolves every existing attachment";; esac
  expect_eq "hook reports each attachment's size" "2" "$(printf '%s\n' "$ctx" | grep -c '(5 bytes)')"
  expect_eq "hook context carries no CR" "false" "$(envelope_has_cr "$hook_out")"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
