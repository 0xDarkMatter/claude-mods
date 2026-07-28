#!/usr/bin/env bash
# Self-test for fleet-ops. Offline + deterministic (git only, no network).
# Primary focus: the lane-file encoding regression — branch names containing
# '/' (feat/x, fleet/x, the convention fleet-worker emits) must track, signal,
# land, display, and revert correctly, not nest into a nonexistent subdir.
# Resolves paths relative to itself so it runs in the repo and once installed.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures (SKIP+exit 0 if git is unavailable)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
FLEET="$SKILL/scripts/fleet.sh"
export TERM_ASCII=1

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
ee(){ [ "$2" = "$3" ] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }

echo "=== fleet-ops self-test ==="

REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
echo base > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm init

# Create branch $1 with one commit touching unique file $2, in its own worktree.
mk_lane(){
  local br=$1 file=$2 wt="$SB/wt-$(printf '%s' "$1" | tr / _)"
  git -C "$REPO" branch "$br" main
  git -C "$REPO" worktree add -q "$wt" "$br"
  echo "$br" > "$wt/$file"
  git -C "$wt" add -A
  git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $br"
}
mk_lane "fleet/task-a" a.txt
mk_lane "feat/foo"     b.txt
mk_lane "plain"        c.txt

cd "$REPO"

echo "-- track (the regression: slashed names must not fail) --"
bash "$FLEET" track fleet/task-a feat/foo plain >/dev/null 2>&1; ee "track slashed + plain" 0 $?
[ -f "$REPO/.claude/fleet/lanes/fleet%2Ftask-a" ] && ok "slashed lane stored flat-encoded" || no "encoded lane file missing"
[ -f "$REPO/.claude/fleet/lanes/feat%2Ffoo" ]     && ok "feat/foo lane flat-encoded"        || no "feat/foo lane missing"
[ -f "$REPO/.claude/fleet/lanes/plain" ]          && ok "plain lane stored as-is"            || no "plain lane missing"
# No stray nested subdir was created.
[ -d "$REPO/.claude/fleet/lanes/fleet" ] && no "stray nested lanes/fleet/ subdir exists" || ok "no nested subdir leaked"

echo "-- status decodes filenames back to branch names --"
st="$(bash "$FLEET" status 2>&1)"
case "$st" in *"fleet/task-a"*) ok "status shows decoded fleet/task-a";; *) no "status missing fleet/task-a";; esac
case "$st" in *"feat/foo"*)     ok "status shows decoded feat/foo";;     *) no "status missing feat/foo";; esac

echo "-- signal.sh on a slashed branch (deployed copy) --"
( cd "$SB/wt-fleet_task-a" && bash "$REPO/.claude/fleet/signal.sh" READY ) >/dev/null 2>&1
ee "signal READY on slashed branch" 0 $?
case "$(head -n1 "$REPO/.claude/fleet/lanes/fleet%2Ftask-a" 2>/dev/null)" in
  READY) ok "signal recorded READY";; *) no "READY not recorded";; esac

echo "-- land records state and merges --"
bash "$FLEET" land fleet/task-a >/dev/null 2>&1; ee "land slashed branch" 0 $?
case "$(head -n1 "$REPO/.claude/fleet/lanes/fleet%2Ftask-a" 2>/dev/null)" in
  LANDED) ok "lane state LANDED recorded";; *) no "LANDED not recorded";; esac
# Never assert via `git log | grep -q` here: under `set -o pipefail`, grep -q
# exits at the first match and git log dies with SIGPIPE (141), flaking the
# pipeline non-zero even when the merge commit exists. Capture, then match.
main_log="$(git -C "$REPO" log --oneline main)"
case "$main_log" in *"merge: fleet/task-a"*) ok "merge commit on main";; *) no "no merge commit";; esac

echo "-- one-shot revert --"
bash "$FLEET" revert fleet/task-a >/dev/null 2>&1; ee "revert slashed branch" 0 $?

echo "-- land --all batch-lands READY lanes oldest-first --"
# 'plain' is still tracked (RUNNING from the initial track). Add a second lane,
# mark both READY, and batch-land in one pass.
mk_lane "feat/batch-b" d.txt
bash "$FLEET" track feat/batch-b >/dev/null 2>&1
( cd "$SB/wt-plain"        && bash "$REPO/.claude/fleet/signal.sh" READY ) >/dev/null 2>&1
( cd "$SB/wt-feat_batch-b" && bash "$REPO/.claude/fleet/signal.sh" READY ) >/dev/null 2>&1
bash "$FLEET" land --all >/dev/null 2>&1; ee "land --all exits 0 (all READY landed)" 0 $?
case "$(head -n1 "$REPO/.claude/fleet/lanes/plain" 2>/dev/null)" in
  LANDED) ok "land --all landed 'plain'";; *) no "'plain' not LANDED after land --all";; esac
case "$(head -n1 "$REPO/.claude/fleet/lanes/feat%2Fbatch-b" 2>/dev/null)" in
  LANDED) ok "land --all landed feat/batch-b";; *) no "feat/batch-b not LANDED after land --all";; esac
main_log="$(git -C "$REPO" log --oneline main)"   # captured, not piped — see SIGPIPE note above
case "$main_log" in *"merge: plain"*)        ok "merge: plain on main";;        *) no "no merge: plain on main";; esac
case "$main_log" in *"merge: feat/batch-b"*) ok "merge: feat/batch-b on main";; *) no "no merge: feat/batch-b on main";; esac
# A RUNNING lane (feat/foo, not signalled READY) must be left untouched by the default batch.
case "$(head -n1 "$REPO/.claude/fleet/lanes/feat%2Ffoo" 2>/dev/null)" in
  RUNNING) ok "land --all left RUNNING feat/foo untouched";; *) no "land --all wrongly touched RUNNING lane";; esac

echo "-- scrub gate still works on a slashed branch --"
wt="$SB/wt-feat_foo"
# Marker built via printf so this source file never contains the contiguous
# forbidden token — otherwise any later diff hunk near this line drags it into
# a hunk header / context line and scrub-check false-positives on run.sh itself.
printf 'TODO_%s leftover\n' 'SCRUB' >> "$wt/b.txt"
git -C "$wt" -c user.email=w@t -c user.name=w commit -aqm "oops debug marker"
bash "$FLEET" scrub-check feat/foo >/dev/null 2>&1; ee "scrub-check flags forbidden pattern" 1 $?

echo "-- scrub gate ignores deletions and context (added lines only) --"
# Regression (2026-07): scrub_diff grepped the raw diff, so a branch REMOVING a
# forbidden marker (a '-' line), or a marker landing in a hunk header / context
# line near an unrelated edit, false-refused. Only '+' lines are violations.
printf 'TODO_%s cleanup-me\n' 'SCRUB' >> "$REPO/f"
git -C "$REPO" commit -qam "main carries a marker"
mk_lane "chore/descrub" e.txt   # branches off main, so it inherits the marker
grep -v "cleanup-me" "$SB/wt-chore_descrub/f" > "$SB/wt-chore_descrub/f.tmp" && mv "$SB/wt-chore_descrub/f.tmp" "$SB/wt-chore_descrub/f"
git -C "$SB/wt-chore_descrub" -c user.email=w@t -c user.name=w commit -qam "remove stale marker"
bash "$FLEET" scrub-check chore/descrub >/dev/null 2>&1; ee "scrub-check passes marker REMOVAL" 0 $?

echo "-- signal.sh log gate: exit codes and summaries, not prose --"
# Regression (Ledger, 2026-07): a GREEN run whose stderr prints "failed"/"error"
# prose, or whose test NAMES contain "error", must not be refused. Verdict order
# under test: exit-code arg > "exit code: N" log line > runner summary > anchored
# count fallback. Uses feat/foo's worktree (clean tree, still a registered lane).
SIGWT="$SB/wt-feat_foo"
green_log="$SB/green-vitest.log"
cat > "$green_log" <<'EOF'
stderr | email to ledger@ev7.com.au failed: No such module "queue"
 v src/mail.test.ts > logs an error when sending fails
 v src/mail.test.ts > surfaces the failed delivery to the caller
 Test Files  3 passed (3)
      Tests  42 passed (42)
   Start at  10:00:00
EOF
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$green_log" ) >/dev/null 2>&1
ee "green vitest log with 'failed' prose passes" 0 $?

red_log="$SB/red-vitest.log"
cat > "$red_log" <<'EOF'
 x src/mail.test.ts > sends the digest
 Test Files  1 failed | 2 passed (3)
      Tests  2 failed | 40 passed (42)
EOF
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$red_log" ) >/dev/null 2>&1
ee "failing vitest summary refused" 1 $?

# Exit code is authoritative in BOTH directions: rc=0 overrules scary prose
# with no recognizable summary; rc=1 overrules a log that looks clean.
prose_log="$SB/prose.log"
printf 'connection error simulated: retry failed as expected\nall scenarios ok\n' > "$prose_log"
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$prose_log" 0 ) >/dev/null 2>&1
ee "rc=0 arg passes despite prose" 0 $?
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$prose_log" 1 ) >/dev/null 2>&1
ee "rc=1 arg refused despite clean-looking log" 1 $?

# The lane-appended "exit code: N" line (the workaround that exposed the bug).
printf 'connection error simulated: retry failed as expected\nexit code: 0\n' > "$prose_log"
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$prose_log" ) >/dev/null 2>&1
ee "'exit code: 0' log line passes" 0 $?

# pytest failing summary still caught without any exit code.
py_red="$SB/red-pytest.log"
printf '=========== 2 failed, 10 passed in 1.24s ===========\n' > "$py_red"
( cd "$SIGWT" && bash "$REPO/.claude/fleet/signal.sh" READY "$py_red" ) >/dev/null 2>&1
ee "failing pytest summary refused" 1 $?

echo "-- config parsing: every documented form must actually reach the script --"
# Regression (2026-07-28): .claude/fleet/config was `source`d, so (a) documented
# lowercase keys set shell vars the UPPERCASE-reading script never looked at, and
# (b) an unquoted value with spaces isn't a bash assignment at all — the error was
# swallowed by 2>/dev/null. Net effect: `fleet land` never ran a test gate, ever.
# These assertions pin the parser to the grammar SKILL.md documents.

CREPO="$SB/cfgrepo"; mkdir -p "$CREPO"
git -C "$CREPO" init -q -b main
git -C "$CREPO" config user.email t@t; git -C "$CREPO" config user.name t
git -C "$CREPO" config core.autocrlf false
echo base > "$CREPO/f"; git -C "$CREPO" add -A; git -C "$CREPO" commit -qm init
mkdir -p "$CREPO/.claude/fleet"
CFG="$CREPO/.claude/fleet/config"
cd "$CREPO"

# Resolved value of one key, via the `fleet config` dump (stdout is data-only).
cfg_get(){ bash "$FLEET" config 2>/dev/null | sed -n "s/^$1=//p"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (want [$2] got [$3])"; }

rm -f "$CFG"
eq "absent config → test_cmd empty (defaults)" "" "$(cfg_get test_cmd)"
eq "absent config → base_branch default"       "main" "$(cfg_get base_branch)"

printf 'test_cmd=echo hi\n' > "$CFG"
eq "lowercase key reaches TEST_CMD" "echo hi" "$(cfg_get test_cmd)"

printf 'TEST_CMD=echo hi\n' > "$CFG"
eq "UPPERCASE key reaches TEST_CMD" "echo hi" "$(cfg_get test_cmd)"

# The exact form that used to parse as "run `-m` with test_cmd in its env".
printf 'test_cmd=uv run pytest -q --maxfail=1 tests/\n' > "$CFG"
eq "unquoted value WITH SPACES survives" "uv run pytest -q --maxfail=1 tests/" "$(cfg_get test_cmd)"

printf 'test_cmd="npm run check -- --fast"\n' > "$CFG"
eq "double-quoted value with spaces, quotes stripped" "npm run check -- --fast" "$(cfg_get test_cmd)"
printf "test_cmd='npm run check'\n" > "$CFG"
eq "single-quoted value with spaces, quotes stripped" "npm run check" "$(cfg_get test_cmd)"

# Comments, blanks, indentation, and the trailing-comment annotation used in the
# SKILL.md example block — a verbatim copy of the docs must work.
cat > "$CFG" <<'EOF'
# fleet-ops config

  mode=worktree                # auto | worktree | branch
test_cmd=make check

poll_interval=9
EOF
eq "comment + blank lines ignored, mode parsed" "worktree" "$(cfg_get mode)"
eq "trailing ' # comment' stripped from unquoted value" "make check" "$(cfg_get test_cmd)"
eq "indented key parsed"                        "9" "$(cfg_get poll_interval)"

# Quoting is how you keep a literal '#' — forbidden_pattern is the real case.
printf 'forbidden_pattern="TODO_MARK|#nolint"\n' > "$CFG"
eq "quoted value keeps literal #" 'TODO_MARK|#nolint' "$(cfg_get forbidden_pattern)"

# Failures must be LOUD. A config that yields nothing is not an absent config.
printf 'tets_cmd=echo hi\n' > "$CFG"
warn="$(bash "$FLEET" config 2>&1 >/dev/null)"
case "$warn" in *"unrecognised key 'tets_cmd'"*) ok "typo'd key warns by name";; *) no "typo'd key silently ignored";; esac
case "$warn" in *"set no recognised keys"*) ok "no-recognised-keys config warns";; *) no "no warning for inert config";; esac
# fleet.sh cds to the repo root, so $CONFIG (and every warning) is root-relative.
case "$warn" in *".claude/fleet/config"*) ok "warning names the config file";; *) no "warning omits file path";; esac
eq "inert config keeps defaults" "" "$(cfg_get test_cmd)"

printf 'this is not a key value line\ntest_cmd=echo hi\n' > "$CFG"
warn="$(bash "$FLEET" config 2>&1 >/dev/null)"
case "$warn" in *"not a key=value line"*) ok "malformed line warns";; *) no "malformed line silent";; esac
eq "malformed line doesn't stop later keys" "echo hi" "$(cfg_get test_cmd)"

printf 'poll_interval=soon\n' > "$CFG"
warn="$(bash "$FLEET" config 2>&1 >/dev/null)"
case "$warn" in *"poll_interval must be an integer"*) ok "non-numeric poll_interval warns";; *) no "non-numeric poll_interval silent";; esac
eq "non-numeric poll_interval keeps default" "5" "$(cfg_get poll_interval)"

# CRLF-authored config (Windows editors) must not leave \r glued to the value.
printf 'test_cmd=echo hi\r\nbase_branch=main\r\n' > "$CFG"
eq "CRLF config parsed without trailing CR" "echo hi" "$(cfg_get test_cmd)"

# `icons=` is read by term_init, which used to run BEFORE the config loaded.
# Only the ascii direction is asserted: term.sh also auto-selects ASCII on a
# non-UTF8 locale, so a "unicode" assertion would flake in CI.
printf 'icons=ascii\n' > "$CFG"
eq "icons key parsed" "ascii" "$(cfg_get icons)"
bash "$FLEET" track main >/dev/null 2>&1 || true
icon_out="$(env -u TERM_ASCII -u FLEET_ASCII bash "$FLEET" status 2>&1)"
case "$icon_out" in *"│"*) no "icons=ascii still emitted unicode tree glyphs";; *) ok "icons=ascii reaches term_init (no unicode glyphs)";; esac
rm -f "$CREPO/.claude/fleet/lanes/main"

echo "-- test gate: test_cmd actually runs and actually blocks the merge --"
# End-to-end proof of the whole point of the fix. The gate command is written
# UNQUOTED WITH SPACES — the exact form that silently no-op'd before.
printf 'test_cmd=grep -q ok ./gate.txt\n' > "$CFG"

mk_cfg_lane(){  # branch, file
  git -C "$CREPO" branch "$1" main
  git -C "$CREPO" worktree add -q "$SB/cwt-$1" "$1"
  echo "$1" > "$SB/cwt-$1/$2"
  git -C "$SB/cwt-$1" add -A
  git -C "$SB/cwt-$1" -c user.email=w@t -c user.name=w commit -qm "work $1"
}

# Red: gate fails → merge must be undone and the lane marked FAILED.
echo bad > "$CREPO/gate.txt"
mk_cfg_lane red-lane r.txt
before="$(git -C "$CREPO" rev-parse main)"
bash "$FLEET" track red-lane >/dev/null 2>&1
land_out="$(bash "$FLEET" land red-lane 2>&1)"; rc=$?
ee "land exits non-zero when test_cmd fails" 1 $rc
case "$land_out" in *"running test_cmd: grep -q ok ./gate.txt"*) ok "log shows the test_cmd being run";; *) no "no 'running test_cmd' log line — gate did not run";; esac
eq "failed gate hard-resets the merge" "$before" "$(git -C "$CREPO" rev-parse main)"
case "$(head -n1 "$CREPO/.claude/fleet/lanes/red-lane" 2>/dev/null)" in
  FAILED) ok "lane marked FAILED after gate failure";; *) no "lane not FAILED after gate failure";; esac

# Green: gate passes → normal land.
echo ok > "$CREPO/gate.txt"
mk_cfg_lane green-lane g.txt
bash "$FLEET" track green-lane >/dev/null 2>&1
bash "$FLEET" land green-lane >/dev/null 2>&1; ee "land succeeds when test_cmd passes" 0 $?
case "$(head -n1 "$CREPO/.claude/fleet/lanes/green-lane" 2>/dev/null)" in
  LANDED) ok "lane LANDED after gate passes";; *) no "lane not LANDED after passing gate";; esac
cfg_log="$(git -C "$CREPO" log --oneline main)"   # captured, not piped — SIGPIPE note above
case "$cfg_log" in *"merge: green-lane"*) ok "merge commit kept after passing gate";; *) no "merge commit missing";; esac

# Absent test_cmd still falls through to signal.sh's log gate, and says so.
rm -f "$CFG"
mk_cfg_lane nogate-lane n.txt
bash "$FLEET" track nogate-lane >/dev/null 2>&1
land_out="$(bash "$FLEET" land nogate-lane 2>&1)"
case "$land_out" in *"no test_cmd set in"*) ok "absent test_cmd names the config path";; *) no "absent test_cmd message unclear";; esac

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
