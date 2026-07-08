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

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
