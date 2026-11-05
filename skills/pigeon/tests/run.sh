#!/usr/bin/env bash
# Behavioural tests for pigeon. HOME is isolated before any production script
# runs so ~/.claude/pmail.db always resolves inside the disposable sandbox.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
# PIGEON_MAIL / PIGEON_HOOK run the suite against other copies of the scripts -
# e.g. the pre-fix ones, to watch a new regression test fail before trusting it.
MAIL="${PIGEON_MAIL:-$SKILL/scripts/mail-db.sh}"
SB="$(mktemp -d)"
SBC="$(cd "$SB" && pwd -P)"
# Signal and seen-marker files live in the real /tmp, named by project hash.
# Only hashes of projects under the sandbox are swept, so a live session's
# files are never touched.
cleanup() {
  local db h
  for db in "$SB"/*/.claude/pmail.db; do
    [ -f "$db" ] || continue
    for h in $(sqlite3 "$db" "SELECT hash FROM projects WHERE path LIKE '${SBC}/%';" 2>/dev/null | tr -d '\r'); do
      rm -f "/tmp/pigeon_signal_${h}" /tmp/pigeon_seen_"${h}"_*
    done
  done
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home"
mkdir -p "$HOME"
DB="$HOME/.claude/pmail.db"
# Claude Code exports a session id that mail-db.sh uses to keep a session's own
# sent mail out of its inbox, so a run inside a session would differ from CI.
# Cases that need a session set it explicitly.
unset CLAUDE_CODE_SESSION_ID
# Run from a sandbox dir: the cases below address "$(pwd)", and inside the repo
# that is the live project's hash, whose /tmp signal real sessions watch.
mkdir -p "$SB/self"
cd "$SB/self" || exit 1

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

echo "-- bodies over the Windows command-line limit --"
# Regression (Windows): send, reply and broadcast handed the escaped body to
# sqlite3.exe as a command-line argument. Windows caps a command line at ~32K
# chars, so any bigger body died with "Argument list too long" (rc 126) and
# nothing was stored. Linux allows ~2 MB, so only a Windows run can fail these.
big="$(head -c 40000 /dev/zero | tr '\0' x)"$'\n'"it's the end"
bash "$MAIL" send "$(pwd)" "big send" "$big" >/dev/null 2>&1
case "$(bash "$MAIL" read)" in *" | ${big} | "*) ok "40 KB send body round-trips through read";; *) no "40 KB send body did not round-trip";; esac

bash "$MAIL" send "$(pwd)" "big parent" "short" >/dev/null
parent_id="$(sqlite3 "$DB" "SELECT MAX(id) FROM messages;" | tr -d '\r')"
bash "$MAIL" read >/dev/null
bash "$MAIL" reply "$parent_id" "$big" >/dev/null 2>&1
case "$(bash "$MAIL" read)" in *" | ${big} | "*) ok "40 KB reply body round-trips through read";; *) no "40 KB reply body did not round-trip";; esac

mkdir -p "$SB/bigpeer"
(cd "$SB/bigpeer" && bash "$MAIL" id >/dev/null)
bash "$MAIL" broadcast "big broadcast" "$big" >/dev/null 2>&1
case "$(cd "$SB/bigpeer" && bash "$MAIL" read)" in *" | ${big} | "*) ok "40 KB broadcast body round-trips through read";; *) no "40 KB broadcast body did not round-trip";; esac

# Regression (Windows): the fix above feeds SQL on stdin, which sqlite3.exe reads
# in text mode - a raw Ctrl-Z (0x1A) there is end-of-file, cutting the INSERT off
# mid-literal. sql_escape splices it back in as char(26).
ctrlz=$'before\x1aafter'
bash "$MAIL" send "$(pwd)" "ctrl-z" "$ctrlz" >/dev/null 2>&1
case "$(bash "$MAIL" read)" in *" | ${ctrlz} | "*) ok "Ctrl-Z byte in a body round-trips";; *) no "Ctrl-Z byte in a body did not round-trip";; esac

echo "-- hook delivery (PreToolUse additionalContext envelope) --"
# Regression: check-mail.sh used to echo plain text, which Claude Code sends to
# the debug log for PreToolUse - the model never saw a single notification. The
# hook must print exactly one JSON envelope (contract at the top of the hook).
# It runs from a throwaway non-git dir so its /tmp/pigeon_signal_* name is
# unique to this run and a live pigeon session's hook can't clear it mid-test.
HOOK="${PIGEON_HOOK:-$(cd "$SKILL/../.." && pwd)/hooks/check-mail.sh}"
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
  expect_eq "hook silent once it has delivered" "" "$(hook)"

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

  echo "-- shared inbox: a lane and its coordinator have one project hash --"
  # Regression (2026-10-06): a repo's worktrees resolve to the main checkout's
  # project hash, so a lane's "READY" report to the coordinator landed in the
  # lane's own inbox. The lane's hook showed it its own message, then deleted
  # the shared /tmp signal, so the coordinator's hook never fired, although the
  # rows stayed unread. Sessions differ only by the stdin session_id the hook
  # gets and the CLAUDE_CODE_SESSION_ID tools get; one plain dir stands in for
  # the repo, because the shared hash is the premise, not the thing under test.
  mkdir -p "$SB/shared" "$SB/outsider"
  as() { local sid="$1"; shift; (cd "$SB/shared" && CLAUDE_CODE_SESSION_ID="$sid" bash "$MAIL" "$@" </dev/null); }
  hook_as() {
    (cd "$SB/shared" && printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "$1" \
      | bash "$HOOK")
  }

  as lane-0001 send "$SB/shared" "READY lane/x abc123" "gate green" >/dev/null
  expect_eq "lane is not shown its own report" "" "$(hook_as lane-0001)"
  case "$(envelope_ctx "$(hook_as main-0002)")" in
    *"READY lane/x"*) ok "coordinator is still told after the lane's hook ran";;
    *) no "coordinator never told: the lane's hook took the shared signal";;
  esac
  expect_eq "coordinator is told about a message once, not on every tool call" "" "$(hook_as main-0002)"

  # The hook footer tells the model to run `pigeon read`. From a lane, that
  # marked the lane's own report read (the coordinator never saw it) and
  # deleted the shared signal, so sessions that had not looked yet never did.
  (cd "$SB/outsider" && bash "$MAIL" send "$SB/shared" "from outside" "for anyone" </dev/null >/dev/null)
  case "$(as lane-0001 read 2>/dev/null)" in
    *"READY lane/x"*) no "lane's pigeon read showed the lane its own report";;
    *"from outside"*) ok "lane's pigeon read shows others' mail, not its own report";;
    *) no "lane's pigeon read lost the outside mail";;
  esac
  expect_eq "lane's pigeon read leaves its report unread for the coordinator" "1" "$(as main-0002 count)"
  case "$(envelope_ctx "$(hook_as peer-0003)")" in
    *"READY lane/x"*) ok "a session that first looks after the lane's pigeon read is still told";;
    *) no "lane's pigeon read hid the report from a session that had not looked yet";;
  esac

  # Claude Code sends session_id as the first key, which the hook's fast regex
  # relies on. If that order ever changes, jq must still find the id - or the
  # filter silently drops and every lane sees its own reports again.
  as lane-0001 send "$SB/shared" "second report" "still the lane's" >/dev/null
  reordered='{"hook_event_name":"PreToolUse","tool_input":{"command":"ls"},"session_id":"lane-0001"}'
  expect_eq "own-mail filter holds when session_id is not the payload's first key" "" \
    "$(cd "$SB/shared" && printf '%s' "$reordered" | bash "$HOOK")"

  # check-mail.sh and mail-db.sh are installed as separate copies, so the hook
  # can meet a database that predates from_session. Filtering on the missing
  # column failed the query, which read as "no mail" - for every session.
  mkdir -p "$SB/oldhome" "$SB/oldproj"
  (cd "$SB/oldproj" && HOME="$SB/oldhome" bash "$MAIL" send "$SB/oldproj" "pre-migration" "old schema row" </dev/null >/dev/null)
  sqlite3 "$SB/oldhome/.claude/pmail.db" "ALTER TABLE messages DROP COLUMN from_session;" 2>/dev/null
  case "$(envelope_ctx "$(cd "$SB/oldproj" && printf '{"session_id":"sess-old"}' | HOME="$SB/oldhome" bash "$HOOK")")" in
    *"old schema row"*) ok "hook still delivers from a database that predates from_session";;
    *) no "hook dropped mail from a database without from_session";;
  esac

  # A lane that obeys the plain footer ("Then run: pigeon read") marks every
  # unread message in the shared inbox read - sibling lanes' reports included -
  # before the coordinator sees them. Inside a worktree the footer says so.
  repo="$SB/repo"
  git init -q "$repo"
  # Git before 2.31 echoes --path-format back instead of a path: the hook then
  # can't tell a worktree apart, so there is nothing to assert.
  case "$(git -C "$repo" rev-parse --path-format=absolute --git-dir 2>/dev/null)" in ''|-*) has_path_format=0;; *) has_path_format=1;; esac
  if [ "$has_path_format" -eq 1 ]; then
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$repo" worktree add -q "$SB/repo-lane" -b lane/y 2>/dev/null
    (cd "$repo" && CLAUDE_CODE_SESSION_ID=main-9 bash "$MAIL" send "$repo" "rebase please" "main moved" </dev/null >/dev/null)
    case "$(envelope_ctx "$(cd "$SB/repo-lane" && printf '{"session_id":"lane-9"}' | bash "$HOOK")")" in
      *"rebase please"*"git worktree"*"pigeon read <id>"*) ok "worktree footer warns that a bare pigeon read takes the others' mail";;
      *) no "worktree footer still says a bare pigeon read";;
    esac
    case "$(envelope_ctx "$(cd "$repo" && printf '{"session_id":"main-10"}' | bash "$HOOK")")" in
      *"git worktree"*) no "main checkout got the worktree footer";;
      *"Then run: pigeon read (to mark as read)"*) ok "main checkout keeps the plain pigeon read footer";;
      *) no "main checkout lost the mail or its footer";;
    esac
  else
    echo "  SKIP  worktree footer (git without --path-format, needs 2.31+)"
  fi
fi

echo "-- ambiguous project names --"
# Regression: a name is a directory basename, so two repos can share one (two
# checkouts named claude-mods). Name lookup silently took the most recently
# registered, so `pigeon send claude-mods` could land in the other inbox.
mkdir -p "$SB/a/twin" "$SB/b/twin"
id_a="$(cd "$SB/a/twin" && bash "$MAIL" id </dev/null)"; hash_a="${id_a##* }"
id_b="$(cd "$SB/b/twin" && bash "$MAIL" id </dev/null)"; hash_b="${id_b##* }"
# Recency alone would now pick a: only the own-project rule picks b.
sqlite3 "$DB" "UPDATE projects SET registered='2999-01-01 00:00:00' WHERE hash='${hash_a}';"
(cd "$SB/b/twin" && bash "$MAIL" send twin "to my twin" "which inbox?" </dev/null >/dev/null 2>"$SB/twin.err")
expect_eq "sender's own project wins an ambiguous name" "$hash_b" \
  "$(sqlite3 "$DB" "SELECT to_project FROM messages ORDER BY id DESC LIMIT 1;" | tr -d '\r')"
twin_err="$(cat "$SB/twin.err")"
[[ "$twin_err" == *"2 projects are named 'twin'"* && "$twin_err" == *"$hash_a"* && "$twin_err" == *"$hash_b"* ]] \
  && ok "ambiguous name warns and lists every candidate hash" \
  || no "ambiguous name sent without a warning (stderr: ${twin_err:-empty})"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
