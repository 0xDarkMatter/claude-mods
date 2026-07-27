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
echo "TODO_SCRUB leftover" >> "$wt/b.txt"
git -C "$wt" -c user.email=w@t -c user.name=w commit -aqm "oops debug marker"
bash "$FLEET" scrub-check feat/foo >/dev/null 2>&1; ee "scrub-check flags forbidden pattern" 1 $?

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

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
