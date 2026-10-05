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

# Hermetic env: the CALLER's fleet knobs must never reach the logic under test.
# The canonical failure (2026-09-01): `FLEET_SKIP_SESSION_CHECK=1 fleet land`
# ran this suite as its post-merge test_cmd, the exported override inherited,
# and the live-owner gate this suite asserts REFUSES was disarmed inside every
# sandbox — 6 false FAILs hard-reset a green merge. fleet.sh now strips these
# before test_cmd, but the suite must not depend on its callers being fixed.
# Cases that WANT an override set it explicitly on their own command line.
unset FLEET_SKIP_SESSION_CHECK FLEET_SESSION_STORE FLEET_SESSION_NOCACHE \
      FLEET_TRANSCRIPT_ROOTS \
      FLEET_SESSION_LIVE_SECS FLEET_SESSION_CACHE_TTL FLEET_SESSION_MAX_AGE_DAYS \
      FLEET_SELF_SESSION_ID FLEET_NO_PRUNE_HINT FLEET_PRUNE_ROOTS \
      FLEET_PRUNE_MAX_REPOS FLEET_ASCII FLEET_RM_RETRY_SECS

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
# sessions.sh caches its index under $TMPDIR. Keep every cache this suite writes
# inside the sandbox: a fixture index left in the real TMPDIR is exactly what
# once let test data answer a real `fleet prune` (2026-09-28).
mkdir -p "$SB/tmp"; export TMPDIR="$SB/tmp"
# Every block that is not ABOUT sessions runs against an empty fixture store
# (readable, nobody in it) and no transcript roots. Left unset, each fleet call
# in the landing blocks read the developer's real Desktop stores: not hermetic,
# and a cold scan of a busy machine costs ~50s. Blocks that fake a store set
# their own and restore this default when they end.
hermetic_sessions(){
  mkdir -p "$SB/no-sessions"
  export FLEET_SESSION_STORE="$SB/no-sessions" FLEET_TRANSCRIPT_ROOTS=""
}
hermetic_sessions
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
ee(){ [ "$2" = "$3" ] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }

# Every land needs an ARMED test gate: fleet.sh REFUSES to land when no
# test_cmd resolves, because an unarmed gate used to merge without running
# anything. Fixtures that are not themselves about the gate arm it with a
# trivially-passing command, so they exercise the path they actually mean to
# test rather than tripping the refusal. The refusal itself is asserted
# explicitly further down ("absent test_cmd").
arm_gate(){ mkdir -p "$1/.claude/fleet"; printf 'test_cmd=true\n' > "$1/.claude/fleet/config"; }

echo "=== fleet-ops self-test ==="

REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
echo base > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm init
arm_gate "$REPO"

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

echo "-- TERM_ASCII=1 renders the WHOLE panel in ASCII, not just the tree rail --"
# Regression: `fleet status` leaked a literal U+00B7 (0xC2 0xB7) from the summary
# line and the footer hotkeys under TERM_ASCII=1 — those separators were authored
# inline instead of coming from term.sh's $TERM_DOT, so the ASCII registry never
# saw them and non-UTF-8 Windows consoles mojibaked. Assert the ENTIRE emission,
# every view: a single-glyph check (the old "no │" test) cannot catch a sibling.
# FORCE_COLOR=1 keeps the ANSI path live so color codes can't hide a glyph.
# Lanes here span RUNNING + LANDED, so sections, rails, leaf rows, the summary
# line and the footer are all exercised in one shot.
ascii_pure() { # label, output
  local dirty
  dirty="$(printf '%s' "$2" | LC_ALL=C grep -o '[^[:print:][:cntrl:]]' | LC_ALL=C sort -u | tr -d '\n')"
  if [ -n "$dirty" ]; then
    no "$1 emits non-ASCII under TERM_ASCII=1 ($(printf '%s' "$dirty" | od -An -c | tr -s ' '))"
  else ok "$1 is pure ASCII under TERM_ASCII=1"; fi
}
ascii_pure "status panel"   "$(TERM_ASCII=1 FORCE_COLOR=1 bash "$FLEET" status 2>&1)"
ascii_pure "verbose panel"  "$(TERM_ASCII=1 FORCE_COLOR=1 bash "$FLEET" status --verbose 2>&1)"
# FLEET_ASCII is the legacy alias SKILL.md advertises as the mojibake fix — it
# must reach exactly the same registry, or the documented remedy is a lie.
ascii_pure "status (FLEET_ASCII=1)" "$(env -u TERM_ASCII FLEET_ASCII=1 FORCE_COLOR=1 bash "$FLEET" status 2>&1)"
# Empty state renders a different branch of the panel (tip glyph, no sections).
EREPO="$SB/empty"; mkdir -p "$EREPO"
git -C "$EREPO" init -q -b main
git -C "$EREPO" config user.email t@t; git -C "$EREPO" config user.name t
git -C "$EREPO" config core.autocrlf false
echo e > "$EREPO/f"; git -C "$EREPO" add -A
git -C "$EREPO" -c user.email=t@t -c user.name=t commit -qm init
ascii_pure "empty-state panel" "$(cd "$EREPO" && TERM_ASCII=1 FORCE_COLOR=1 bash "$FLEET" status 2>&1)"
# Guard the other direction too: without TERM_ASCII the panel must still use the
# Unicode glyphs, or "pure ASCII" would pass trivially by rendering nothing.
uni_out="$(cd "$REPO" && env -u TERM_ASCII -u FLEET_ASCII LC_ALL=en_US.UTF-8 bash "$FLEET" status 2>&1)"
case "$uni_out" in *"$(printf '\xc2\xb7')"*) ok "unicode mode still renders the U+00B7 separator";;
  *) no "unicode mode lost its separator (ASCII fallback leaked into UTF-8 output)";; esac

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

echo "-- scrub gate: mktemp X-templates pass, lone triple-X markers refuse --"
# Regression (2026-09-01): the old default's X-term matched the 4th X of a
# mktemp template (uppercase X is not [a-z]), refusing any branch that added
#   TMP="$(mktemp -t push-gate-paths.<six X's>)"
# even though identical templates already lived on main. Runs of 4+ X's are
# templates; only a lone triple-X followed by a non-letter is a marker. Both
# tokens are BUILT at runtime — a contiguous triple-X (or marker) in this
# source would trip the gate on run.sh itself (see the marker note above).
XR='XX'
mk_lane "chore/mktempl" tmpl.sh
printf 'TMP="$(mktemp -t push-gate-paths.%s)"\n' "$XR$XR$XR" >> "$SB/wt-chore_mktempl/tmpl.sh"
git -C "$SB/wt-chore_mktempl" -c user.email=w@t -c user.name=w commit -qam "add mktemp template"
bash "$FLEET" scrub-check chore/mktempl >/dev/null 2>&1; ee "mktemp X-template passes scrub" 0 $?

mk_lane "chore/xmark" mark.txt
printf '%sX fix this later\n' "$XR" >> "$SB/wt-chore_xmark/mark.txt"
git -C "$SB/wt-chore_xmark" -c user.email=w@t -c user.name=w commit -qam "add a marker"
bash "$FLEET" scrub-check chore/xmark >/dev/null 2>&1; ee "lone triple-X marker still refused" 1 $?

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
# Asserts the whole panel, not just the tree rail: `icons=ascii` is the config
# route into term_init, so it must deliver the same ASCII purity TERM_ASCII=1 does.
ascii_pure "icons=ascii panel" "$(env -u TERM_ASCII -u FLEET_ASCII FORCE_COLOR=1 bash "$FLEET" status 2>&1)"
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

# Absent test_cmd REFUSES the land. It used to fall through to signal.sh's log
# gate, which verifies nothing when a lane signalled READY without a test log —
# so the branch merged having run zero tests, reported only as a log line. The
# config is gitignored in most repos, so "absent" is the fresh-clone/git-clean
# case, not an exotic one. Assert the refusal AND that nothing moved.
rm -f "$CFG"
mk_cfg_lane nogate-lane n.txt
bash "$FLEET" track nogate-lane >/dev/null 2>&1
before_nogate="$(git -C "$CREPO" rev-parse main)"
land_out="$(bash "$FLEET" land nogate-lane 2>&1)"; rc=$?
ee "absent test_cmd refuses the land" 1 $rc
case "$land_out" in *"UNARMED"*) ok "refusal says the gate is unarmed";; *) no "refusal message unclear";; esac
case "$land_out" in *".claude/fleet/config"*) ok "refusal names the config path";; *) no "refusal omits the config path";; esac
eq "refused land leaves the base branch untouched" "$before_nogate" "$(git -C "$CREPO" rev-parse main)"
case "$(git -C "$CREPO" log --oneline main)" in
  *"merge: nogate-lane"*) no "unarmed gate merged anyway";; *) ok "no merge commit from an unarmed gate";; esac
# The lane is NOT marked CONFLICT: an unarmed gate is a repo-level fault, not
# the lane's, so a human isn't left undoing state that was never wrong.
case "$(head -n1 "$CREPO/.claude/fleet/lanes/nogate-lane" 2>/dev/null)" in
  CONFLICT) no "refusal wrongly marked the lane CONFLICT";; *) ok "refusal leaves lane state alone";; esac
# The daemon must refuse to start too, rather than spin refusing every poll.
bash "$FLEET" start >/dev/null 2>&1; ee "daemon refuses to start unarmed" 1 $?

# -- daemon lifecycle: a signal STOPS it, between lands (the SIGHUP ghost) -----
# Regression, reproduced 2026-09-28. cmd_start trapped INT/TERM/HUP with a
# handler that removed the PID file but never exited, and a trapped signal
# RESUMES the script. SIGHUP (what the daemon gets when its Claude session
# ends) left a ghost: "daemon stopping" logged, no PID file, `fleet stop`
# answering "no daemon running", and 3s later the ghost landed a lane.
# `fleet stop`'s SIGTERM was swallowed the same way, so every stop was really
# its SIGKILL escalation. poll_interval=5 (the default) is deliberate: an idle
# daemon must answer DURING its poll sleep, not after it, or SIGTERM races the
# 5s SIGKILL. session_check=off: the live-owner gate is not under test here,
# and switching it off keeps sessions.sh lookups out of the timing.
echo "-- daemon lifecycle: signals stop it, between lands (the SIGHUP ghost) --"
DREPO="$SB/drepo"; mkdir -p "$DREPO"
git -C "$DREPO" init -q -b main
git -C "$DREPO" config user.email t@t; git -C "$DREPO" config user.name t
git -C "$DREPO" config core.autocrlf false
echo base > "$DREPO/f"; git -C "$DREPO" add -A; git -C "$DREPO" commit -qm init
cd "$DREPO"
bash "$FLEET" init d-one d-two >/dev/null 2>&1   # RUNNING lanes keep the daemon polling
DCFG="$DREPO/.claude/fleet/config"; DPIDF="$DREPO/.claude/fleet/daemon.pid"
DLOG="$DREPO/.claude/fleet/activity.log"
printf 'test_cmd=true\npoll_interval=5\nsession_check=off\n' > "$DCFG"

# Start a daemon in the background; DPID is its PID once daemon.pid names a
# live process. Background jobs are never piped or captured: $( ) would block
# until the daemon exits.
DPID=""
daemon_up(){
  DPID=""
  bash "$FLEET" start >/dev/null 2>&1 &
  local i p
  for ((i = 0; i < 150; i++)); do
    p="$(cat "$DPIDF" 2>/dev/null)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then DPID=$p; return 0; fi
    sleep 0.1
  done
  return 1
}
# True once PID $1 is gone, polling for up to $2 tenths of a second.
exits_within(){ local i; for ((i = 0; i < $2; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
# A daemon that ignored its signal must not outlive the suite: on Windows a
# live process inside $SB also blocks the EXIT trap's rm -rf.
reap_daemon(){ if [ -n "$DPID" ]; then kill -KILL "$DPID" 2>/dev/null; rm -f "$DPIDF"; fi; wait 2>/dev/null; }

daemon_up || no "daemon did not come up (SIGHUP case)"
kill -HUP "$DPID" 2>/dev/null
if exits_within "$DPID" 30; then ok "daemon exits on SIGHUP, within its poll sleep"
else no "daemon survived SIGHUP by 3s — a ghost that keeps landing"; reap_daemon; fi
[ -f "$DPIDF" ] && no "SIGHUP left daemon.pid behind" || ok "SIGHUP'd daemon removed daemon.pid"
wait 2>/dev/null

daemon_up || no "daemon did not come up (fleet stop case)"
stop_out="$(bash "$FLEET" stop 2>&1)"; ee "fleet stop" 0 $?
case "$stop_out" in
  *SIGKILL*)          no "fleet stop escalated to SIGKILL — the daemon ignored SIGTERM" ;;
  *"daemon stopped"*) ok "SIGTERM alone stops an idle daemon" ;;
  *)                  no "fleet stop output unrecognised: $stop_out" ;;
esac
exits_within "$DPID" 30 || { no "daemon still alive after fleet stop"; reap_daemon; }
wait 2>/dev/null

# Mid-land: the stop must neither cut the land short (a merge left without its
# gate) nor let another land start. The gate blocks on a sentinel, so the
# signal provably arrives while test_cmd runs; the in-flight lane must finish
# through the gate and the next READY lane must stay READY.
for l in d-one d-two; do
  ( cd "$DREPO/.fleet-worktrees/$l" && echo "$l" > "$l.txt" && git add "$l.txt" \
      && git commit -qm "work $l" && bash "$DREPO/.claude/fleet/signal.sh" READY ) >/dev/null 2>&1
done
cat > "$DCFG" <<'EOF'
test_cmd=n=0; until [ -f .claude/fleet/go ] || [ $n -ge 300 ]; do sleep 0.1; n=$((n+1)); done
poll_interval=5
session_check=off
EOF
daemon_up || no "daemon did not come up (mid-land case)"
for ((i = 0; i < 300; i++)); do grep -q "running test_cmd" "$DLOG" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$DPID" 2>/dev/null
sleep 0.5   # signal delivery is asynchronous under MSYS; let it register first
touch "$DREPO/.claude/fleet/go"
exits_within "$DPID" 300 && ok "daemon exits after a mid-land SIGTERM" \
  || { no "daemon still alive 30s after a mid-land SIGTERM"; reap_daemon; }
wait 2>/dev/null
case "$(head -n1 "$DREPO/.claude/fleet/lanes/d-one" 2>/dev/null)" in
  LANDED) ok "in-flight land finished through its gate" ;;
  *)      no "in-flight land did not finish: d-one = $(head -n1 "$DREPO/.claude/fleet/lanes/d-one" 2>/dev/null)" ;;
esac
dlog="$(git -C "$DREPO" log --oneline main)"   # captured, not piped — SIGPIPE note above
case "$dlog" in *"merge: d-one"*) ok "in-flight merge kept";; *) no "in-flight merge missing";; esac
case "$(head -n1 "$DREPO/.claude/fleet/lanes/d-two" 2>/dev/null)" in
  READY) ok "no new land started after the stop request" ;;
  *)     no "daemon kept landing after SIGTERM: d-two = $(head -n1 "$DREPO/.claude/fleet/lanes/d-two" 2>/dev/null)" ;;
esac
case "$dlog" in *"merge: d-two"*) no "d-two merged after the stop request";; *) ok "no merge of d-two after the stop";; esac
grep -q "SIGTERM received" "$DLOG" && ok "activity log records the stop request" || no "stop request not logged"
cd "$CREPO"

# -- already-merged branch: the two-sessions-one-branch case -------------------
# Regression, reproduced 2026-09-08 in a downstream repo (branch
# claude/charming-mendel-4ebf5d landed twice, 90 seconds apart). `git merge
# --no-ff` exits 0 with "Already up to date." when the branch is already an
# ancestor of the base, so land_one took the success path for a merge it never
# made:
#   (a) it logged `PASS: <branch> landed` and returned 0 for a no-op land, and
#   (b) when the gate then failed it ran `git reset --hard HEAD^`, discarding a
#       merge commit ANOTHER session had created — a peer's landed work, thrown
#       away on a branch fleet believed it owned. In the incident the gate
#       happened to pass; that was luck, not design.
# Case (b) is also the only case that can tell `reset --hard $before` apart from
# `reset --hard HEAD^`: after a genuine --no-ff merge those name the same commit.
echo "-- already-merged branch: no false land, no peer-destroying reset --"

MREPO="$SB/mrepo"; mkdir -p "$MREPO"
git -C "$MREPO" init -q -b main
git -C "$MREPO" config user.email t@t; git -C "$MREPO" config user.name t
git -C "$MREPO" config core.autocrlf false
echo base > "$MREPO/f"; git -C "$MREPO" add -A; git -C "$MREPO" commit -qm init
mkdir -p "$MREPO/.claude/fleet"
MCFG="$MREPO/.claude/fleet/config"
cd "$MREPO"

# Lane with one commit at a FIXED timestamp — `land --all` orders by commit
# time, and same-second ties would make the batch order (and so the tally
# assertion in (e)) nondeterministic. The worktree is dropped afterwards: while
# a branch is checked out anywhere, `git branch -d` cannot delete it, so "the
# lane branch survived" would prove nothing about whether fleet tried to.
mk_mlane(){ # repo, branch, file, epoch
  local wt="$SB/mwt-$2"
  git -C "$1" branch "$2" main
  git -C "$1" worktree add -q "$wt" "$2"
  echo "$2" > "$wt/$3"
  git -C "$wt" add -A
  GIT_AUTHOR_DATE="@$4 +0000" GIT_COMMITTER_DATE="@$4 +0000" \
    git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $2"
  git -C "$1" worktree remove --force "$wt" >/dev/null 2>&1 || true
}
# What the OTHER session does: a real --no-ff merge, made outside fleet.
peer_land(){ git -C "$1" merge "$2" --no-ff -m "merge: $2" -q; }

# (a) already merged, green gate -> reported as already landed, not as a land.
#     The gate is side-effecting, so "did it run?" is a file test rather than
#     prose-matching: there is no merge of ours to gate, so it must not run.
printf 'test_cmd=touch ./gate-ran\n' > "$MCFG"
mk_mlane "$MREPO" dup-green x.txt 1700000000
peer_land "$MREPO" dup-green
bash "$FLEET" track dup-green >/dev/null 2>&1
# AFTER the track, deliberately: ensure_fleet_dir appends .claude/fleet/ and
# .fleet-worktrees/ to .gitignore and auto-commits that on base_branch, so a tip
# captured before tracking is already stale. The invariant under test is "the
# LAND does not move the tip", so capture it immediately before the land.
peer_sha="$(git -C "$MREPO" rev-parse main)"
land_out="$(bash "$FLEET" land dup-green 2>&1)"; rc=$?
ee "already-merged branch lands cleanly" 0 $rc
eq "already-merged land leaves the base tip untouched" "$peer_sha" "$(git -C "$MREPO" rev-parse main)"
case "$land_out" in *"ALREADY LANDED: dup-green"*) ok "log uses a distinct ALREADY LANDED verb";;
  *) no "no ALREADY LANDED line - a no-op reads exactly like a real land";; esac
case "$land_out" in *"PASS: dup-green landed"*) no "claimed PASS for a merge it never made";;
  *) ok "does not claim PASS for a merge it never made";; esac
[ -f "$MREPO/gate-ran" ] && no "test_cmd ran for a merge that never happened" || ok "no merge, no gate run"
# Exactly one merge of this branch on main - the peer's. A second would mean
# fleet manufactured one. Captured, not piped - SIGPIPE note above.
m_log="$(git -C "$MREPO" log --oneline main)"
eq "exactly one merge commit for the branch" "1" \
   "$(printf '%s\n' "$m_log" | grep -c 'merge: dup-green' || true)"
case "$(head -n1 "$MREPO/.claude/fleet/lanes/dup-green" 2>/dev/null)" in
  LANDED) ok "lane recorded LANDED (the end state the caller wanted IS true)";;
  *) no "lane not LANDED after an already-merged land";; esac
case "$(sed -n '2p' "$MREPO/.claude/fleet/lanes/dup-green" 2>/dev/null)" in
  *"no merge performed"*) ok "lane note records the no-op";;
  *) no "lane note does not distinguish this from a real land";; esac
git -C "$MREPO" rev-parse --verify --quiet refs/heads/dup-green >/dev/null 2>&1 \
  && ok "lane branch left alone (this run did not land it)" \
  || no "deleted a lane branch it did not land"

# (b) already merged, RED gate -> must NOT hard-reset the peer's merge commit.
#     The destructive half, and the assertion that actually pins the fix.
printf 'test_cmd=false\n' > "$MCFG"
mk_mlane "$MREPO" dup-red y.txt 1700000100
peer_land "$MREPO" dup-red
bash "$FLEET" track dup-red >/dev/null 2>&1
peer_sha="$(git -C "$MREPO" rev-parse main)"
land_out="$(bash "$FLEET" land dup-red 2>&1)"; rc=$?
ee "already-merged branch is not failed by a gate it never ran" 0 $rc
eq "red gate does NOT reset away the peer's merge" "$peer_sha" "$(git -C "$MREPO" rev-parse main)"
m_log="$(git -C "$MREPO" log --oneline main)"
case "$m_log" in *"merge: dup-red"*) ok "peer's merge commit survives a red gate";;
  *) no "peer's merge commit was RESET AWAY";; esac

# (c) the load-bearing half: a genuinely unmerged branch behaves as before.
printf 'test_cmd=touch ./gate-ran-real\n' > "$MCFG"
mk_mlane "$MREPO" real-lane z.txt 1700000200
before_real="$(git -C "$MREPO" rev-parse main)"
bash "$FLEET" track real-lane >/dev/null 2>&1
land_out="$(bash "$FLEET" land real-lane 2>&1)"; rc=$?
ee "genuinely unmerged branch still lands" 0 $rc
case "$land_out" in *"PASS: real-lane landed"*) ok "real land still reports PASS";;
  *) no "real land lost its PASS line";; esac
case "$land_out" in *"ALREADY LANDED"*) no "real land misreported as already landed";;
  *) ok "real land is not confused with a no-op";; esac
[ -f "$MREPO/gate-ran-real" ] && ok "gate ran for a real merge" || no "gate did not run for a real merge"
[ "$before_real" != "$(git -C "$MREPO" rev-parse main)" ] && ok "base tip advanced on a real land" \
  || no "base tip did not move on a real land"
m_log="$(git -C "$MREPO" log --oneline main)"
case "$m_log" in *"merge: real-lane"*) ok "merge commit created";; *) no "no merge commit";; esac
git -C "$MREPO" rev-parse --verify --quiet refs/heads/real-lane >/dev/null 2>&1 \
  && no "landed lane branch not cleaned up" || ok "landed lane branch still deleted"

# (d) red gate after a REAL merge rewinds to exactly the pre-merge tip, and no
#     further. `$before` and `HEAD^` coincide on a genuine --no-ff merge, so
#     this cannot separate them - (b) is what does. What it pins is that the
#     rewind does not overshoot: the whole history is identical to before.
printf 'test_cmd=false\n' > "$MCFG"
mk_mlane "$MREPO" redland-lane q.txt 1700000300
before_red="$(git -C "$MREPO" rev-parse main)"
log_before_red="$(git -C "$MREPO" log --oneline main)"
bash "$FLEET" track redland-lane >/dev/null 2>&1
bash "$FLEET" land redland-lane >/dev/null 2>&1; ee "red gate fails the land" 1 $?
eq "red gate rewinds to exactly the pre-merge tip" "$before_red" "$(git -C "$MREPO" rev-parse main)"
eq "and no further - history either side is unchanged" "$log_before_red" "$(git -C "$MREPO" log --oneline main)"
case "$(head -n1 "$MREPO/.claude/fleet/lanes/redland-lane" 2>/dev/null)" in
  FAILED) ok "lane marked FAILED after a real merge failed its gate";;
  *) no "lane not FAILED after a failed gate";; esac

# (d2) ...and the rewind itself is CHECKED. An unchecked `git reset --hard` is
#      the same lie in miniature: the lane reports FAILED while the failing
#      merge is still sitting on the base branch, and nothing anywhere says so.
#      There is no portable way to make a reset fail for real (a locked file
#      under Windows is the realistic cause), so it is fault-injected with a
#      `git` shim placed first on PATH for exactly one invocation. $SB comes
#      from mktemp -d, so it is a POSIX path: a Windows-style X:/... entry in
#      PATH is silently NOT resolved by Git Bash, and the shim would appear to
#      work while the real git ran.
#      Its own repo, because a successful injection strands a merge on main.
mkdir -p "$SB/shim"
printf '#!/usr/bin/env bash\nif [ "$1" = "reset" ]; then echo "simulated reset failure" >&2; exit 1; fi\nexec "%s" "$@"\n' \
  "$(command -v git)" > "$SB/shim/git"
chmod +x "$SB/shim/git"
RREPO="$SB/rrepo"; mkdir -p "$RREPO"
git -C "$RREPO" init -q -b main
git -C "$RREPO" config user.email t@t; git -C "$RREPO" config user.name t
git -C "$RREPO" config core.autocrlf false
echo base > "$RREPO/f"; git -C "$RREPO" add -A; git -C "$RREPO" commit -qm init
mkdir -p "$RREPO/.claude/fleet"; printf 'test_cmd=false\n' > "$RREPO/.claude/fleet/config"
cd "$RREPO"
git -C "$RREPO" checkout -q -b lane/rewind main
echo w > "$RREPO/w.txt"; git -C "$RREPO" add -- w.txt
git -C "$RREPO" -c user.email=w@t -c user.name=w commit -qm "work lane/rewind"
git -C "$RREPO" checkout -q main
bash "$FLEET" track lane/rewind >/dev/null 2>&1
before_rw="$(git -C "$RREPO" rev-parse main)"
if PATH="$SB/shim:$PATH" command -v git | grep -q "$SB/shim"; then
  rw_out="$(PATH="$SB/shim:$PATH" bash "$FLEET" land lane/rewind 2>&1)"; rc=$?
  ee "land still fails when the post-merge rewind cannot run" 1 $rc
  case "$rw_out" in *"could not reset main"*) ok "a failed rewind is reported, not swallowed";;
    *) no "failed rewind passed silently - lane says FAILED, merge stays on main";; esac
  case "$rw_out" in *"THE FAILING MERGE IS STILL ON main"*) ok "log states the base branch is now broken";;
    *) no "log does not warn that the merge is still on the base branch";; esac
  case "$rw_out" in *"git reset --hard $before_rw"*) ok "log hands over the exact recovery command";;
    *) no "no recovery command offered";; esac
  [ "$before_rw" != "$(git -C "$RREPO" rev-parse main)" ] \
    && ok "the injection really did strand the merge (the test tests something)" \
    || no "reset was not actually blocked - this case proves nothing"
  case "$(sed -n '2p' "$RREPO/.claude/fleet/lanes/lane%2Frewind" 2>/dev/null)" in
    *"rewind to"*"FAILED"*) ok "lane note records that the rewind failed";;
    *) no "lane note claims an ordinary post-merge failure";; esac
else
  echo "  SKIP  rewind-failure injection (PATH shim not resolvable here)"
fi
cd "$CREPO"

# (e) land --all counts a no-op apart from a real land. Two lanes: one already
#     merged by a peer, one genuinely unmerged, with fixed commit times so the
#     oldest-first batch order is deterministic.
echo "-- land --all counts an already-merged lane apart from a real land --"
BREPO="$SB/brepo"; mkdir -p "$BREPO"
git -C "$BREPO" init -q -b main
git -C "$BREPO" config user.email t@t; git -C "$BREPO" config user.name t
git -C "$BREPO" config core.autocrlf false
echo base > "$BREPO/f"; git -C "$BREPO" add -A; git -C "$BREPO" commit -qm init
arm_gate "$BREPO"
cd "$BREPO"
mk_mlane "$BREPO" batch-dup  bd.txt 1700000000
mk_mlane "$BREPO" batch-real br.txt 1700000400
peer_land "$BREPO" batch-dup
bash "$FLEET" track batch-dup batch-real >/dev/null 2>&1
batch_out="$(bash "$FLEET" land --all --running 2>&1)"; rc=$?
ee "land --all exits 0 when one lane was already merged" 0 $rc
case "$batch_out" in
  *"land --all: 1 landed, 1 already in main, 0 conflict, 0 failed"*)
    ok "summary counts 1 landed + 1 already, not 2 landed";;
  *) no "summary miscounts the no-op";; esac
b_log="$(git -C "$BREPO" log --oneline main)"
eq "no duplicate merge commit for the already-merged lane" "1" \
   "$(printf '%s\n' "$b_log" | grep -c 'merge: batch-dup' || true)"
case "$b_log" in *"merge: batch-real"*) ok "the genuinely unmerged lane still landed";;
  *) no "real lane did not land in the batch";; esac

cd "$CREPO"

# -- revert targets the branch you named, and only that branch ----------------
# Regression, reproduced 2026-09-08. cmd_revert located the commit to undo with
# `git log --merges --grep="merge: $branch" -n1`, which is wrong twice over:
#   * --grep matches a SUBSTRING, so `merge: lane/auth` also matched
#     `merge: lane/auth-refactor`; with -n1 taking the newest, reverting
#     lane/auth destroyed the REFACTOR lane's work and logged
#     `reverted: lane/auth`. Sibling lane names sharing a prefix are the norm.
#   * --grep is a REGEX with the branch interpolated raw, so `feat/a.b` matched
#     a landed `merge: feat/aXb` — a branch that was never landed at all.
# Both are the same failure the land audit found: a destructive operation whose
# report describes what was ASKED FOR rather than what was DONE.
echo "-- revert: exact-subject targeting, clean abort, honest lane state --"

VREPO="$SB/vrepo"; mkdir -p "$VREPO"
git -C "$VREPO" init -q -b main
git -C "$VREPO" config user.email t@t; git -C "$VREPO" config user.name t
git -C "$VREPO" config core.autocrlf false
echo base > "$VREPO/f"; git -C "$VREPO" add -A; git -C "$VREPO" commit -qm init
arm_gate "$VREPO"
cd "$VREPO"

# Branch with one commit touching $3, merged into main by fleet's own message
# convention. No worktree: these cases only care about main's history.
mk_landed(){ # repo, branch, file
  git -C "$1" checkout -q -b "$2" main
  echo "$2" > "$1/$3"
  # Explicit path, never `add -A`: fleet gitignores .claude/fleet/ via
  # ensure_fleet_dir, but arm_gate wrote the config before any fleet command
  # ran, so `-A` here would COMMIT fleet's own runtime state. activity.log then
  # counts as a tracked file that every fleet command dirties, and the
  # clean-base refusals in land_one/cmd_revert fire on the fixture rather than
  # on anything under test.
  git -C "$1" add -- "$3"
  git -C "$1" -c user.email=w@t -c user.name=w commit -qm "work $2"
  git -C "$1" checkout -q main
  git -C "$1" merge "$2" --no-ff -m "merge: $2" -q
}

# (a) A sibling branch whose name merely CONTAINS the one being reverted must
#     not be the one that gets undone.
mk_landed "$VREPO" lane/auth          auth.txt
mk_landed "$VREPO" lane/auth-refactor refactor.txt
bash "$FLEET" revert lane/auth >/dev/null 2>&1; ee "revert with a prefix-sharing sibling present" 0 $?
eq "reverts the branch it was asked for" 'Revert "merge: lane/auth"' \
   "$(git -C "$VREPO" log -1 --format=%s main)"
[ -f "$VREPO/refactor.txt" ] && ok "the sibling lane's work survives" \
  || no "reverted the WRONG branch - sibling lane's file destroyed"
[ -f "$VREPO/auth.txt" ] && no "named branch's file still present after revert" \
  || ok "the named branch's work is gone, as asked"

# (b) A branch name is data, not a pattern. `feat/a.b` was never landed; the
#     landed sibling is `feat/aXb`, which only a regex could confuse it with.
mk_landed "$VREPO" 'feat/aXb' regex.txt
rev_out="$(bash "$FLEET" revert 'feat/a.b' 2>&1)"; rc=$?
ee "an unlanded branch name is not regex-matched onto a landed one" 1 $rc
case "$rev_out" in *"no merge commit found for feat/a.b"*) ok "refusal names the branch asked for";;
  *) no "wrong refusal message for an unlanded branch";; esac
[ -f "$VREPO/regex.txt" ] && ok "the regex-adjacent branch's work survives" \
  || no "regex match reverted an unrelated branch"

# (c) A revert that conflicts must leave nothing behind. Before, it died inside
#     `git revert` with the sequencer running and a conflicted index, and the
#     operator's next `fleet land` blamed "uncommitted tracked changes" - the
#     symptom, not the cause.
# Its own repo, deliberately: a revert that fails to clean up strands the
# sequencer, and every later case sharing the fixture would then fail as a
# CONSEQUENCE rather than as an independent detection - the coupled-fixture
# trap this repo already lists as a landmine.
CVREPO="$SB/cvrepo"; mkdir -p "$CVREPO"
git -C "$CVREPO" init -q -b main
git -C "$CVREPO" config user.email t@t; git -C "$CVREPO" config user.name t
git -C "$CVREPO" config core.autocrlf false
echo base > "$CVREPO/f"; git -C "$CVREPO" add -A; git -C "$CVREPO" commit -qm init
arm_gate "$CVREPO"
cd "$CVREPO"
mk_landed "$CVREPO" lane/conflicty c.txt
echo "changed downstream" > "$CVREPO/c.txt"
git -C "$CVREPO" add -- c.txt; git -C "$CVREPO" commit -qm "later edit to the same file"
before_conf="$(git -C "$CVREPO" rev-parse main)"
rev_out="$(bash "$FLEET" revert lane/conflicty 2>&1)"; rc=$?
ee "a conflicting revert exits non-zero" 1 $rc
case "$rev_out" in *"REVERT FAILED"*) ok "conflict is reported as a failed revert";;
  *) no "conflicting revert did not say so";; esac
eq "conflicting revert leaves the base tip untouched" "$before_conf" "$(git -C "$CVREPO" rev-parse main)"
[ -d "$CVREPO/.git/sequencer" ] || [ -f "$CVREPO/.git/REVERT_HEAD" ] \
  && no "left a revert in progress for the operator to discover" \
  || ok "no sequencer state left behind"
eq "working tree left clean (no conflicted index)" "" \
   "$(git -C "$CVREPO" status --porcelain | grep -v '^??' || true)"
# A stranded sequencer is not merely untidy: the operator's next land blamed
# "uncommitted tracked changes", describing the symptom and hiding the cause.
bash "$FLEET" track lane/conflicty >/dev/null 2>&1
case "$(bash "$FLEET" land lane/conflicty 2>&1)" in
  *"uncommitted tracked changes"*) no "next land still blames a dirty tree - the failed revert left state behind";;
  *) ok "the next land is not poisoned by the failed revert";; esac
cd "$VREPO"

# (d) The lane said LANDED; after a revert it is not. Leaving it LANDED is a
#     status panel that lies about where the work lives. RUNNING, not a new
#     REVERTED state: an unknown state falls through the panel's count map and
#     never satisfies the daemon's "not LANDED and not FAILED" terminal test.
mk_landed "$VREPO" lane/stateful s.txt
bash "$FLEET" track lane/stateful >/dev/null 2>&1
case "$(head -n1 "$VREPO/.claude/fleet/lanes/lane%2Fstateful" 2>/dev/null)" in
  RUNNING) ok "tracked lane starts RUNNING";; *) no "tracked lane not RUNNING";; esac
# Land is a no-op here (already merged by mk_landed) but still records LANDED.
bash "$FLEET" land lane/stateful >/dev/null 2>&1
case "$(head -n1 "$VREPO/.claude/fleet/lanes/lane%2Fstateful" 2>/dev/null)" in
  LANDED) ok "lane reads LANDED before the revert";; *) no "lane not LANDED before revert";; esac
bash "$FLEET" revert lane/stateful >/dev/null 2>&1; ee "revert of a tracked lane" 0 $?
case "$(head -n1 "$VREPO/.claude/fleet/lanes/lane%2Fstateful" 2>/dev/null)" in
  LANDED)  no "lane still claims LANDED after being reverted";;
  RUNNING) ok "reverted lane returns to RUNNING (non-terminal, and true)";;
  *)       no "reverted lane left in an unexpected state";; esac
case "$(sed -n '2p' "$VREPO/.claude/fleet/lanes/lane%2Fstateful" 2>/dev/null)" in
  *"reverted from main"*) ok "lane note records the revert";;
  *) no "lane note does not mention the revert";; esac

# (e) Reverting a branch fleet never tracked must not conjure a lane into the
#     status panel - set_lane_state creates the file it writes.
mk_landed "$VREPO" lane/untracked u.txt
bash "$FLEET" revert lane/untracked >/dev/null 2>&1; ee "revert of an untracked branch" 0 $?
[ -f "$VREPO/.claude/fleet/lanes/lane%2Funtracked" ] \
  && no "revert invented a lane for an untracked branch" \
  || ok "untracked branch stays untracked"

# (f) Landed, reverted, re-landed leaves two `merge: X` commits. Reverting the
#     newest is right; doing it silently is how the substring bug stayed
#     invisible, so the count and the chosen SHA are logged.
mk_landed "$VREPO" lane/twice t1.txt
git -C "$VREPO" checkout -q lane/twice
echo more > "$VREPO/t2.txt"; git -C "$VREPO" add -- t2.txt
git -C "$VREPO" -c user.email=w@t -c user.name=w commit -qm "second commit on lane/twice"
git -C "$VREPO" checkout -q main
git -C "$VREPO" merge lane/twice --no-ff -m "merge: lane/twice" -q
newest="$(git -C "$VREPO" rev-parse main)"
rev_out="$(bash "$FLEET" revert lane/twice 2>&1)"; rc=$?
ee "revert with two identically-named merges" 0 $rc
case "$rev_out" in *"2 merges of lane/twice"*) ok "ambiguity is reported, not hidden";;
  *) no "multiple candidate merges chosen silently";; esac
case "$rev_out" in *"$newest"*) ok "log names the exact SHA it reverted";;
  *) no "log does not identify which merge was reverted";; esac

cd "$CREPO"

# -- session awareness: the live-owner land gate -------------------------------
# Guards the hazard that motivated it: landing a lane while the session that
# owns it is still writing. The store is faked (FLEET_SESSION_STORE) so the
# suite stays offline and never depends on the developer's real Desktop state.
echo "-- session awareness (live-owner gate) --"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  session-awareness tests (jq not installed)"
else
SESSIONS="$SKILL/scripts/sessions.sh"
export FLEET_SESSION_NOCACHE=1     # the index cache would leak between cases
# Set-but-empty = no transcript signal. Unset, sessions.sh would walk the
# developer's real ~/.claude/projects on every call: slow, and not hermetic.
export FLEET_TRANSCRIPT_ROOTS=""

bash "$SESSIONS" --help >/dev/null 2>&1; ee "sessions.sh --help" 0 $?

# Unavailable store must be advisory (exit 3, empty stdout), never a hard error.
so="$(FLEET_SESSION_STORE=/nonexistent-store bash "$SESSIONS" index 2>/dev/null)"; sx=$?
ee "absent store exits 3" 3 $sx
[ -z "$so" ] && ok "absent store emits no stdout" || no "absent store wrote to stdout"

SREPO="$SB/srepo"; mkdir -p "$SREPO"
git -C "$SREPO" init -q -b main
git -C "$SREPO" config user.email t@t; git -C "$SREPO" config user.name t
git -C "$SREPO" config core.autocrlf false
echo base > "$SREPO/f"; git -C "$SREPO" add -A; git -C "$SREPO" commit -qm init
# These cases are about WHO owns a lane, not about the gate — arm it so the
# live-owner logic is what decides, rather than the unarmed-gate refusal
# (which fires first, by design, being the cheaper check).
arm_gate "$SREPO"

STORE="$SB/store/acct/ws"; mkdir -p "$STORE"
export FLEET_SESSION_STORE="$SB/store"
# Desktop records NATIVE paths (X:\repo), and cmd_main normalises git's toplevel
# the same way before comparing. The fixture must therefore store the path in
# that same native form, or the MAIN cwd match can never fire on Windows.
SREPO_NATIVE="$(cygpath -m "$SREPO" 2>/dev/null || printf '%s' "$SREPO")"
# Wrapper shape mirrors Desktop's: writtenBranches is what actually names a
# lane, and lastActivityAt (epoch ms) is what liveness is computed from.
mk_session(){ # id, title, cwd, ageSecs, branch, writtenBranch
  local ms=$(( ($(date +%s) - $4) * 1000 ))
  cat > "$STORE/$1.json" <<JSON
{"sessionId":"$1","title":"$2","cwd":"$3","lastActivityAt":$ms,
 "isArchived":false,"branch":"$5","writtenBranches":["$6"]}
JSON
}

mk_lane_in(){ # repo, branch, file
  local wt="$SB/swt-$2"
  git -C "$1" branch "$2" main
  git -C "$1" worktree add -q "$wt" "$2"
  echo "$2" > "$wt/$3"; git -C "$wt" add -A
  git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $2"
}

cd "$SREPO"

# A lane whose owner is LIVE (active 5s ago).
mk_lane_in "$SREPO" hot-lane h.txt
mk_session local_hot "Hot session" "$SREPO/wt" 5 claude/hot hot-lane
row="$(bash "$SESSIONS" owner hot-lane 2>/dev/null)"
case "$row" in *local_hot*) ok "owner resolves via writtenBranches";; *) no "owner did not resolve";; esac
[ "$(printf '%s' "$row" | cut -f7)" = "1" ] && ok "recent session reads live" || no "recent session not live"

bash "$FLEET" track hot-lane >/dev/null 2>&1
bash "$FLEET" land hot-lane >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "land REFUSED while owner is live (exit $lx)" || no "land proceeded despite live owner"
case "$(head -n1 "$SREPO/.claude/fleet/lanes/hot-lane" 2>/dev/null)" in
  CONFLICT) ok "refused lane marked CONFLICT";; *) no "refused lane not marked CONFLICT";; esac
case "$(git -C "$SREPO" log --oneline main)" in
  *"merge: hot-lane"*) no "live-owner lane was merged anyway";; *) ok "no merge commit created";; esac

# Explicit override lands it.
FLEET_SKIP_SESSION_CHECK=1 bash "$FLEET" land hot-lane >/dev/null 2>&1
ee "override lands despite live owner" 0 $?

# The override is ONE-RUN: fleet.sh must consume it and strip it from the env
# before eval'ing test_cmd, or any suite that itself exercises fleet (this one,
# when run as a repo's post-merge gate) inherits a disarmed live-owner gate —
# the 2026-09-01 false-FAIL incident. Probe with a test_cmd that fails when the
# variable is visible at test time: a leak reverts the merge and land exits 1.
mk_lane_in "$SREPO" leak-lane lk.txt
bash "$FLEET" track leak-lane >/dev/null 2>&1
printf 'test_cmd=test -z "${FLEET_SKIP_SESSION_CHECK:-}"\n' > "$SREPO/.claude/fleet/config"
FLEET_SKIP_SESSION_CHECK=1 bash "$FLEET" land leak-lane >/dev/null 2>&1
ee "override is stripped from test_cmd's env" 0 $?
case "$(git -C "$SREPO" log --oneline main)" in
  *"merge: leak-lane"*) ok "env-probe gate passed and the lane merged";; *) no "env-probe gate failed — override leaked into test_cmd";; esac
arm_gate "$SREPO"

# -- self-ownership exemption --------------------------------------------------
# The gate protects against a CONCURRENT writer, and the session doing the
# landing is not one. It must therefore land its own lane WITHOUT an override,
# or every lane session's only escape is disarming the gate wholesale — which
# also disarms it for the peers it genuinely protects.
mk_lane_in "$SREPO" self-lane s.txt
mk_session local_selfy "This very session" "$SREPO/wt3" 5 claude/selfy self-lane
bash "$FLEET" track self-lane >/dev/null 2>&1

# Self unresolvable → no exemption. The fail-safe direction: an unknown
# identity must never satisfy an exemption.
( unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  bash "$FLEET" land self-lane >/dev/null 2>&1 ); lx=$?
[ "$lx" -ne 0 ] && ok "unresolvable self does not exempt (exit $lx)" || no "unresolved self landed anyway"

# `sessions.sh self` believes an id only when the store has a wrapper for it.
sid="$(CLAUDE_CODE_HOST_SESSION_ID=local_selfy bash "$SESSIONS" self 2>/dev/null)"
[ "$sid" = "local_selfy" ] && ok "self resolves from local_<id> form" || no "self did not resolve ($sid)"
sid="$(CLAUDE_CODE_HOST_SESSION_ID=selfy bash "$SESSIONS" self 2>/dev/null)"
[ "$sid" = "local_selfy" ] && ok "self resolves from bare id form" || no "bare id did not resolve ($sid)"
sid="$(CLAUDE_CODE_HOST_SESSION_ID=local_nosuch bash "$SESSIONS" self 2>/dev/null)"; sx=$?
[ -z "$sid" ] && [ "$sx" -eq 3 ] && ok "unknown id resolves to nothing" || no "unknown id was believed ($sid)"
# Both vars set to DIFFERENT ids — the Desktop shape exactly. The chain must
# try each candidate, not stop at the first one that happens to be set.
sid="$(CLAUDE_CODE_SESSION_ID=cli-only CLAUDE_CODE_HOST_SESSION_ID=local_selfy \
  bash "$SESSIONS" self 2>/dev/null)"
[ "$sid" = "local_selfy" ] && ok "resolves when a non-matching id is also set" || no "first-set-wins regression ($sid)"

# The exemption itself: owner live, owner is self, no peers → lands clean.
CLAUDE_CODE_HOST_SESSION_ID=local_selfy bash "$FLEET" land self-lane >/dev/null 2>&1
ee "self-owned live lane lands without override" 0 $?
case "$(git -C "$SREPO" log --oneline main)" in
  *"merge: self-lane"*) ok "self-owned lane actually merged";; *) no "no merge commit for self-owned lane";; esac

# A LIVE PEER on the same branch is the real hazard — refuses even though self
# also owns it. This is the line between a narrow exemption and a blunt one.
mk_lane_in "$SREPO" shared-lane sh.txt
mk_session local_selfy2 "This very session" "$SREPO/wt4" 5 claude/selfy2 shared-lane
mk_session local_peer   "A peer session"    "$SREPO/wt5" 5 claude/peer   shared-lane
bash "$FLEET" track shared-lane >/dev/null 2>&1
CLAUDE_CODE_HOST_SESSION_ID=local_selfy2 bash "$FLEET" land shared-lane >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "live PEER still blocks a self-owned lane (exit $lx)" || no "peer-owned lane landed"
case "$(git -C "$SREPO" log --oneline main)" in
  *"merge: shared-lane"*) no "lane with live peer was merged";; *) ok "no merge while a peer is live";; esac

# A lane whose owner went idle (2h ago) lands normally.
mk_lane_in "$SREPO" cold-lane c2.txt
mk_session local_cold "Cold session" "$SREPO/wt2" 7200 claude/cold cold-lane
[ "$(bash "$SESSIONS" owner cold-lane 2>/dev/null | cut -f7)" = "0" ] \
  && ok "stale session reads idle" || no "stale session still reads live"
bash "$FLEET" track cold-lane >/dev/null 2>&1
bash "$FLEET" land cold-lane >/dev/null 2>&1; ee "idle owner does not block landing" 0 $?

# MAIN resolves to the session sitting in the repo ROOT, not a worktree.
mk_session local_boss "Coordinator" "$SREPO_NATIVE" 30 main main
mrow="$(bash "$FLEET" main show 2>/dev/null)"
case "$mrow" in *local_boss*) ok "fleet main resolves the repo-root session";; *) no "fleet main did not resolve ($mrow)";; esac
bash "$FLEET" main claim local_hot >/dev/null 2>&1
case "$(bash "$FLEET" main show 2>/dev/null)" in
  *local_hot*) ok "explicit pin overrides the cwd heuristic";; *) no "pin did not override";; esac
# Assert the release OUTCOME, not just the follow-up read. This used to discard
# release's exit code and stderr, so a delete that failed (2026-10-05, a held
# file on Windows) surfaced only as "release did not restore heuristic" and was
# indistinguishable from a resolution bug.
PIN="$SREPO/.claude/fleet/main"
rerr="$(bash "$FLEET" main release 2>&1 >/dev/null)"; rx=$?
[ "$rx" -eq 0 ] && [ ! -e "$PIN" ] && ok "release removes the pin (exit 0)" \
  || no "release left the pin behind (exit $rx): $rerr"
mrow="$(bash "$FLEET" main show 2>&1)"
case "$mrow" in
  *local_boss*) ok "release restores heuristic resolution";; *) no "release did not restore heuristic (show: $mrow)";; esac

# -- held-pin-release: a delete that fails must never read as a release -------
# The 2026-10-05 flake (237/238, green on rerun). On Windows, a process holding
# a file open WITHOUT delete-sharing (the Win32/.NET default; antivirus and
# indexers do it briefly after a write) makes `rm -f` fail with EBUSY. One
# attempt lost that race under load and left the pin in place. These cases hold
# the pin for real rather than mocking rm:
#   Windows  a PowerShell process opens it with FileShare.Read (no Delete)
#   POSIX    its directory goes read-only (unlink needs write on the directory)
# Read-only FILES do not work as a stand-in: Git Bash deletes them anyway
# (noacl mount), as it does files in a read-only directory.
# The hold is dropped only after release has REPORTED hitting it, so the order
# is forced rather than timed. A host that cannot hold a file SKIPs: the hold is
# the harness's precondition, not the behaviour under test.
HOLD_PID=""; HOLD_DIR=""; HOLD_GO=""
hold_file(){ # path → 0 once the hold is in place
  HOLD_PID=""; HOLD_DIR=""; HOLD_GO=""
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      command -v powershell.exe >/dev/null 2>&1 || return 1
      local ready="$SB/hold.ready" w r g i
      HOLD_GO="$SB/hold.go"; rm -f "$ready" "$HOLD_GO"
      w=$(cygpath -w "$1"); r=$(cygpath -w "$ready"); g=$(cygpath -w "$HOLD_GO")
      # Self-expires after 120s so a killed suite cannot strand a handle in $SB.
      powershell.exe -NoProfile -NonInteractive -Command "
        \$h = [IO.File]::Open('$w', 'Open', 'Read', 'Read')
        Set-Content -LiteralPath '$r' -Value ready
        \$t = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath '$g') -and \$t.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }
        \$h.Close()" >/dev/null 2>&1 &
      HOLD_PID=$!
      for i in $(seq 1 600); do
        [ -f "$ready" ] && return 0
        kill -0 "$HOLD_PID" 2>/dev/null || break
        sleep 0.1
      done
      unhold_file; return 1 ;;
    *)
      HOLD_DIR=$(dirname "$1"); chmod a-w "$HOLD_DIR"
      # root ignores directory permissions: no hold possible, so no test.
      if ( : > "$HOLD_DIR/.hold-probe" ) 2>/dev/null; then
        rm -f "$HOLD_DIR/.hold-probe"; unhold_file; return 1
      fi
      return 0 ;;
  esac
}
unhold_file(){
  if [ -n "$HOLD_PID" ]; then : > "$HOLD_GO"; wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""; fi
  if [ -n "$HOLD_DIR" ]; then chmod u+w "$HOLD_DIR"; HOLD_DIR=""; fi
}

bash "$FLEET" main claim local_hot >/dev/null 2>&1
if hold_file "$PIN"; then
  # Held past the retry window: release must fail out loud, not claim success.
  rerr="$(FLEET_RM_RETRY_SECS=0 bash "$FLEET" main release 2>&1 >/dev/null)"; rx=$?
  [ -f "$PIN" ]; pin_kept=$?
  unhold_file
  [ "$rx" -ne 0 ] && [ "$pin_kept" -eq 0 ] && ok "held pin: release exits non-zero (exit $rx)" \
    || no "held pin: release exit $rx, pin kept=$([ "$pin_kept" -eq 0 ] && echo yes || echo no)"
  case "$rerr" in
    *"MAIN pin cleared"*) no "held pin: release printed 'cleared' anyway: $rerr";;
    *"could not remove MAIN pin"*) ok "held pin: release names the failure on stderr";;
    *) no "held pin: no clear error on stderr: $rerr";; esac
else
  echo "  SKIP  held-pin release (cannot hold a file open on this host)"
fi

if hold_file "$PIN"; then
  # Held briefly: release must wait it out. The hold drops once release has said
  # it is retrying (or has exited, which is the unfixed failure), never on a timer.
  FLEET_RM_RETRY_SECS=120 bash "$FLEET" main release >/dev/null 2>"$SB/release.err" & RPID=$!
  for i in $(seq 1 600); do
    grep -q 'retrying' "$SB/release.err" 2>/dev/null && break
    kill -0 "$RPID" 2>/dev/null || break
    sleep 0.1
  done
  unhold_file
  wait "$RPID"; rx=$?
  [ "$rx" -eq 0 ] && [ ! -e "$PIN" ] && ok "briefly held pin: release waits out the hold (exit 0)" \
    || no "briefly held pin: release failed (exit $rx): $(cat "$SB/release.err")"
  case "$(bash "$FLEET" main show 2>/dev/null)" in
    *local_boss*) ok "briefly held pin: heuristic resolution restored";;
    *) no "briefly held pin: MAIN still pinned after release";; esac
else
  echo "  SKIP  briefly-held-pin release (cannot hold a file open on this host)"
fi

# Status annotates lanes with their owner's liveness, in ASCII.
mk_lane_in "$SREPO" shown-lane s.txt
mk_session local_shown "Shown session" "$SREPO/wt3" 5 claude/shown shown-lane
bash "$FLEET" track shown-lane >/dev/null 2>&1
sv="$(bash "$FLEET" status 2>&1)"
case "$sv" in *"[live]"*) ok "status annotates a live owner";; *) no "status missing [live] annotation"
  # Failed once inside a landing gate (2026-10-05, a good lane reverted) and
  # passed on rerun, with nothing recorded about why. Dump what status printed
  # and what a direct store read says now. A row that is present and live here
  # means the miss was transient in status's own read of the store.
  printf '%s\n' "$sv" | sed 's/^/        status | /'
  bash "$SESSIONS" views 2>&1 | grep -E 'shown-lane|jq|store|unavailable' | sed 's/^/        views  | /'
  echo "        views  | rc=${PIPESTATUS[0]}" ;; esac
# Whole panel, not just the annotated row. This was row-scoped because fleet's
# summary line and footer authored a literal U+00B7 that survived TERM_ASCII=1;
# those now interpolate $TERM_DOT, so the entire session-aware panel — chrome,
# summary, footer and owner annotations alike — must come out ASCII-pure.
ascii_pure "session-aware status panel" "$sv"

# Session awareness off = the pre-existing behaviour, exactly.
# test_cmd stays set: turning the SESSION check off must not also disarm the
# TEST gate — they are independent, and this case is only about the former.
printf 'session_check=off\ntest_cmd=true\n' > "$SREPO/.claude/fleet/config"
mk_lane_in "$SREPO" offcheck-lane o.txt
mk_session local_off "Off session" "$SREPO/wt4" 5 claude/off offcheck-lane
bash "$FLEET" track offcheck-lane >/dev/null 2>&1
bash "$FLEET" land offcheck-lane >/dev/null 2>&1; ee "session_check=off restores old behaviour" 0 $?
arm_gate "$SREPO"

unset FLEET_SESSION_NOCACHE; hermetic_sessions
cd "$REPO"
fi

# -- prune: worktree housekeeping ---------------------------------------------
# `prune` is the only fleet-ops command that DELETES, and the deletion is
# unrecoverable for uncommitted files. Every case below is a guard on that one
# direction: what must never be removed, and what must degrade to report-only
# when the evidence isn't there. Same offline discipline as the block above —
# the session store is faked via FLEET_SESSION_STORE, so the suite never reads
# or perturbs real Desktop state.
echo "-- prune (classification, dry-run default, removal safety) --"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  prune tests (jq not installed)"
else
export FLEET_SESSION_NOCACHE=1
export FLEET_TRANSCRIPT_ROOTS=""   # hermetic: see the session-awareness block

PREPO="$SB/prepo"; mkdir -p "$PREPO"
git -C "$PREPO" init -q -b main
git -C "$PREPO" config user.email t@t; git -C "$PREPO" config user.name t
git -C "$PREPO" config core.autocrlf false
echo base > "$PREPO/f"; git -C "$PREPO" add -A; git -C "$PREPO" commit -qm init

PSTORE="$SB/pstore/acct/ws"; mkdir -p "$PSTORE"
export FLEET_SESSION_STORE="$SB/pstore"

# isArchived is a JSON boolean, so $7 is the literal true/false — an archived
# owner is what separates "finished" from "idle but still open".
mk_psession(){ # id title cwd ageSecs branch writtenBranch archived
  local ms=$(( ($(date +%s) - $4) * 1000 ))
  cat > "$PSTORE/$1.json" <<JSON
{"sessionId":"$1","title":"$2","cwd":"$3","lastActivityAt":$ms,
 "isArchived":$7,"branch":"$5","writtenBranches":["$6"]}
JSON
}

# A lane worktree with one commit. Optionally merged into main; optionally left
# holding an UNTRACKED file, which is exactly the unrecoverable case.
mk_pwt(){ # shortname branch merged(y|n) dirty(y|n)
  local wt="$SB/pwt-$1"
  git -C "$PREPO" branch "$2" main
  git -C "$PREPO" worktree add -q "$wt" "$2"
  echo "$2" > "$wt/$1.txt"
  git -C "$wt" add -A
  git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $2"
  [ "$3" = y ] && git -C "$PREPO" merge -q --no-ff -m "merge: $2" "$2"
  [ "$4" = y ] && echo scratch > "$wt/UNSAVED.txt"
  return 0
}

# Bucket for a worktree, read from --porcelain. Asserting on TSV rather than on
# the rendered panel keeps these tests about classification, not layout.
pb(){ bash "$FLEET" prune --porcelain 2>/dev/null \
      | awk -F'\t' -v n="/pwt-$1	" 'index($1 "\t", n){print $3; exit}'; }

cd "$PREPO"

mk_pwt live     lane/p-live     y n
mk_pwt arch     lane/p-arch     y n
mk_pwt dirtyone lane/p-dirty    y y
mk_pwt unmerged lane/p-unmerged n n

mk_psession local_plive "Live lane"  "$SB/pwt-live"     5    claude/plive lane/p-live     false
mk_psession local_parch "Done lane"  "$SB/pwt-arch"     7200 claude/parch lane/p-arch     true
mk_psession local_pdirt "Dirty lane" "$SB/pwt-dirtyone" 7200 claude/pdirt lane/p-dirty    true

[ "$(pb live)"     = KEEP   ] && ok "live owner => KEEP"                       || no "live owner not KEEP"
[ "$(pb arch)"     = SAFE   ] && ok "archived owner + merged + clean => SAFE"  || no "archived+merged+clean not SAFE"
[ "$(pb dirtyone)" = REVIEW ] && ok "merged but dirty => REVIEW"               || no "dirty worktree not REVIEW"
[ "$(pb unmerged)" = REVIEW ] && ok "unmerged => REVIEW"                       || no "unmerged not REVIEW"

# Dry run is the DEFAULT, not a flag you have to remember.
bash "$FLEET" prune >/dev/null 2>&1; ee "bare 'prune' exits 0" 0 $?
[ -d "$SB/pwt-arch" ] && ok "bare 'prune' is a dry run - removed nothing" || no "bare 'prune' DELETED a worktree"
bash "$FLEET" prune --dry-run >/dev/null 2>&1; ee "--dry-run exits 0" 0 $?
[ -d "$SB/pwt-arch" ] && ok "--dry-run removed nothing" || no "--dry-run DELETED a worktree"

# Removal needs a confirmation that a pipe cannot supply.
bash "$FLEET" prune --remove </dev/null >/dev/null 2>&1; ee "--remove refuses without a tty" 2 $?
[ -d "$SB/pwt-arch" ] && ok "refused --remove removed nothing" || no "refused --remove still DELETED"
bash "$FLEET" prune --porcelain --remove >/dev/null 2>&1; ee "--porcelain --remove refused" 2 $?

# No session store = no evidence of abandonment = nothing is removable. This is
# the degradation path on any non-Desktop or jq-less host, so it has to be the
# safe direction, not a crash and not a free pass.
sout="$(FLEET_SESSION_STORE=/nonexistent-store bash "$FLEET" prune --porcelain 2>/dev/null)"
nsafe=$(printf '%s' "$sout" | awk -F'\t' 'NF && $3=="SAFE"' | wc -l)
nother=$(printf '%s' "$sout" | awk -F'\t' 'NF && $3!="REVIEW"' | wc -l)
[ "$nsafe" -eq 0 ]  && ok "store unavailable => nothing classified SAFE"   || no "store unavailable produced $nsafe SAFE rows"
[ "$nother" -eq 0 ] && ok "store unavailable => everything REVIEW"         || no "store unavailable left $nother non-REVIEW rows"
FLEET_SESSION_STORE=/nonexistent-store bash "$FLEET" prune --remove --yes >/dev/null 2>&1
ee "store unavailable + --remove --yes still exits 0" 0 $?
[ -d "$SB/pwt-arch" ] && ok "store unavailable => --remove --yes removed nothing" || no "removed a worktree with NO session info"

# session_check=off is the same story by a different route.
mkdir -p "$PREPO/.claude/fleet"
printf 'session_check=off\n' > "$PREPO/.claude/fleet/config"
offsafe=$(bash "$FLEET" prune --porcelain 2>/dev/null | awk -F'\t' 'NF && $3=="SAFE"' | wc -l)
[ "$offsafe" -eq 0 ] && ok "session_check=off => nothing SAFE" || no "session_check=off produced $offsafe SAFE rows"
rm -f "$PREPO/.claude/fleet/config"

# --all-repos is report-only by construction: one command must never be able to
# sweep worktrees across the machine.
bash "$FLEET" prune --all-repos --remove >/dev/null 2>&1; ee "--all-repos --remove refused" 2 $?
bash "$FLEET" prune --all-repos --root "$SB" >/dev/null 2>&1; ee "--all-repos reports" 0 $?
[ -d "$SB/pwt-arch" ] && ok "--all-repos removed nothing" || no "--all-repos DELETED a worktree"
arows="$(bash "$FLEET" prune --all-repos --porcelain --root "$SB" 2>/dev/null)"
case "$arows" in *"prepo"*) ok "--all-repos --porcelain reports per-repo counts";; *) no "--all-repos --porcelain missed prepo";; esac
# A worktree's .git is a FILE, so worktrees must never be discovered as repos
# in their own right (they would re-report the parent's worktrees).
case "$arows" in *"pwt-"*) no "--all-repos discovered a worktree as a repo";; *) ok "--all-repos skips worktrees, counts repos";; esac

# The tree you invoked from is never a candidate, even when every other signal
# says removable — otherwise prune deletes the shell it is running in.
mk_pwt stand lane/p-stand y n
mk_psession local_pstand "Gone lane" "$SB/pwt-stand" 7200 claude/pstand lane/p-stand true
[ "$(pb stand)" = SAFE ] && ok "control: p-stand is SAFE seen from the repo root" || no "p-stand control case is not SAFE"
standb="$(cd "$SB/pwt-stand" && bash "$FLEET" prune --porcelain 2>/dev/null \
          | awk -F'\t' -v n="/pwt-stand	" 'index($1 "\t", n){print $3}')"
[ "$standb" = KEEP ] && ok "the worktree you invoked from is KEEP, never SAFE" || no "invoking worktree classified '$standb'"

# Now actually remove, and check the blast radius was exactly the SAFE rows.
bash "$FLEET" prune --remove --yes >/dev/null 2>&1; ee "--remove --yes exits 0" 0 $?
[ -d "$SB/pwt-arch" ]     && no "SAFE worktree was not removed"        || ok "SAFE worktree removed"
[ -d "$SB/pwt-live" ]     && ok "live-owner worktree survived"         || no "live-owner worktree was REMOVED"
[ -d "$SB/pwt-dirtyone" ] && ok "dirty worktree survived"              || no "dirty worktree was REMOVED"
[ -d "$SB/pwt-unmerged" ] && ok "unmerged worktree survived"           || no "unmerged worktree was REMOVED"
[ -f "$SB/pwt-dirtyone/UNSAVED.txt" ] && ok "untracked file in a dirty lane untouched" || no "untracked lane file destroyed"

# The recovery claim printed in the output is real: committed lane work lives in
# the object store and the worktree comes back. If this ever fails, the message
# is lying to the operator about how safe removal is.
git -C "$PREPO" worktree add -q "$SB/pwt-arch" lane/p-arch >/dev/null 2>&1
[ -f "$SB/pwt-arch/arch.txt" ] && ok "removed lane recovers via 'git worktree add'" || no "removed lane did NOT recover"

# The backlog has to be visible from the panel, or it just grows silently.
bash "$FLEET" track lane/p-unmerged >/dev/null 2>&1
hint="$(bash "$FLEET" status 2>&1)"
case "$hint" in *prunable*) ok "status surfaces the prunable backlog";; *) no "status shows no prune hint";; esac
if printf '%s\n' "$hint" | grep -F 'prunable' | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "prune hint row emits non-ASCII under TERM_ASCII=1"
else ok "prune hint row is ASCII-pure under TERM_ASCII=1"; fi
printf 'prune_hint=off\n' > "$PREPO/.claude/fleet/config"
case "$(bash "$FLEET" status 2>&1)" in
  *prunable*) no "prune_hint=off did not suppress the hint";;
  *)          ok "prune_hint=off suppresses the hint";; esac
rm -f "$PREPO/.claude/fleet/config"

# -- prune: ownership attribution (the 2026-09-28 near-miss) --------------------
# A real `fleet prune --dry-run` classified 12 of 17 worktrees SAFE, including
# the cwd of two RUNNING sessions and three idle-but-open ones; `--remove`
# would have stranded the running two in a silent CPU spin. Each cause is one
# case below, and each case fails on the pre-fix code:
#   - only ONE Desktop session store was read, and the owners lived in another
#     Desktop instance's (--user-data-dir) store
#   - ownership was joined on branch alone, never on the session's cwd — which
#     Desktop records natively, BACKSLASHED
#   - liveness came from a wrapper timestamp that does not move mid-turn
#   - a .claude/worktrees/ tree that nobody claimed was SAFE by default
#   - the index cache was keyed by uid alone, so a fixture store poisoned it
# All worktrees here are merged + clean, so ownership is the only variable.
echo "-- prune ownership attribution (2026-09-28 regressions) --"
AREPO="$SB/arepo"; mkdir -p "$AREPO"
git -C "$AREPO" init -q -b main
git -C "$AREPO" config user.email t@t; git -C "$AREPO" config user.name t
git -C "$AREPO" config core.autocrlf false
echo base > "$AREPO/f"; git -C "$AREPO" add -A; git -C "$AREPO" commit -qm init
printf '.claude/\n' >> "$AREPO/.git/info/exclude"

ASTORE="$SB/astore/acct/ws"; mkdir -p "$ASTORE"
ATX="$SB/atx"; mkdir -p "$ATX"
export FLEET_SESSION_STORE="$SB/astore" FLEET_TRANSCRIPT_ROOTS="$ATX"

# Desktop's own path form: native and BACKSLASHED, with the drive letter's case
# free to differ from git's (x:\ vs X:/). Linux has no native form, so the
# POSIX path is backslashed instead — normalisation must fold both to git's.
bs_path(){
  local p
  p=$(cygpath -w "$1" 2>/dev/null) || p=$(printf '%s' "$1" | tr / '\\')
  printf '%s%s' "$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')" "${p:1}"
}
# Claude Code's project-dir encoding, reimplemented here independently of the
# scripts from observed behaviour (D:\Code\App\.claude\worktrees\fix-login
# is filed under D--Code-App--claude-worktrees-fix-login). Case kept,
# as Claude Code keeps it — the scripts must match case-insensitively.
enc_cc(){ printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

mk_awt(){ # slug branch — a merged, clean worktree under .claude/worktrees/
  local wt="$AREPO/.claude/worktrees/$1"
  git -C "$AREPO" branch "$2" main
  git -C "$AREPO" worktree add -q "$wt" "$2"
  echo "$1" > "$wt/$1.txt"; git -C "$wt" add -A
  git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $1"
  git -C "$AREPO" merge -q --no-ff -m "merge: $2" "$2"
}
awt_path(){ git -C "$AREPO" worktree list --porcelain | sed -n "s|^worktree \(.*/worktrees/$1\)\$|\1|p"; }
# A wrapper in the real Desktop shape: writtenBranches null (as observed), and
# a cliSessionId linking it to its transcript. Built with jq so a backslashed
# cwd is escaped exactly as Desktop writes it.
mk_wrap(){ # id title cwd ageSecs branch archived(true|false) [cliId] [store]
  local ms=$(( ($(date +%s) - $4) * 1000 ))
  jq -n --arg id "$1" --arg t "$2" --arg c "$3" --argjson la "$ms" --arg b "$5" \
        --argjson ar "$6" --arg cli "${7:-}" \
    '{sessionId:$id, title:$t, cwd:$c, lastActivityAt:$la, isArchived:$ar,
      branch:$b, writtenBranches:null} + (if $cli != "" then {cliSessionId:$cli} else {} end)' \
    > "${8:-$ASTORE}/$1.json"
}
# A transcript filed under Claude Code's encoding of <nativeCwd>, last written
# <ageSecs> ago.
mk_tx(){ # cliId nativeCwd ageSecs
  local d; d="$ATX/$(enc_cc "$2")"; mkdir -p "$d"
  printf '{"type":"user","cwd":%s}\n' "$(jq -Rn --arg c "$2" '$c')" > "$d/$1.jsonl"
  local t=$(( $(date +%s) - $3 ))
  touch -d "@$t" "$d/$1.jsonl" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$d/$1.jsonl"
}
pa(){ bash "$FLEET" prune --porcelain 2>/dev/null \
      | awk -F'\t' -v n="/worktrees/$1" 'substr($1, length($1) - length(n) + 1) == n { print $3 }'; }

cd "$AREPO"
mk_awt live-bs   claude/live-bs
mk_awt idle-open claude/idle-open
mk_awt midturn   claude/midturn
mk_awt moved     lane/moved
mk_awt spawn     claude/spawn
mk_awt orphan    claude/orphan
mk_awt done      claude/done

# The cwd join, with the branch join deliberately defeated (the wrapper records
# a different branch — branch drift is common: one session ran `claude/keen-mccarthy`
# in worktree vigilant-grothendieck). Only a backslash-tolerant cwd match can
# find these owners.
mk_wrap local_livebs "Running here" "$(bs_path "$(awt_path live-bs)")"   5    claude/drift-a false
mk_wrap local_idleop "Open, idle"   "$(bs_path "$(awt_path idle-open)")" 7200 claude/drift-b false
[ "$(pa live-bs)"   = KEEP   ] && ok "live session's backslash-path cwd => KEEP"      || no "live session's backslash cwd not KEEP (got '$(pa live-bs)')"
[ "$(pa idle-open)" = REVIEW ] && ok "idle open session's worktree is never SAFE"      || no "idle open session's worktree classified '$(pa idle-open)'"

# Mid-turn: the wrapper still carries the timestamp the turn started with; the
# transcript was written seconds ago. The session is RUNNING.
mk_wrap local_midturn "Long turn" "$(bs_path "$(awt_path midturn)")" 7200 claude/midturn false cli-midturn
mk_tx cli-midturn "$(bs_path "$(awt_path midturn)")" 5
[ "$(pa midturn)" = KEEP ] && ok "running session with a stale wrapper timestamp => KEEP" || no "mid-turn session not KEEP (got '$(pa midturn)')"
[ "$(bash "$SESSIONS" owner --fresh claude/midturn 2>/dev/null | cut -f7)" = "1" ] \
  && ok "owner --fresh reads a mid-turn session live (land gate)" || no "owner --fresh called a mid-turn session idle"
[ "$(bash "$SESSIONS" live local_midturn 2>/dev/null)" = "1" ] \
  && ok "live <id> counts the transcript, not just the wrapper" || no "live <id> ignored the transcript"

# EnterWorktree: the session was created in `spawn` (its wrapper cwd, forever)
# and moved into `moved`; only its transcript's directory says so. An ARCHIVED
# session with an exact cwd on `moved` also exists — positive evidence that the
# open mover must still veto.
mk_wrap local_mover  "Moved into lane" "$(bs_path "$(awt_path spawn)")" 7200 claude/spawn false cli-mover
mk_tx cli-mover "$(bs_path "$(awt_path moved)")" 7200
mk_wrap local_oldown "Earlier owner"   "$(bs_path "$(awt_path moved)")" 9000 lane/moved   true
[ "$(pa moved)" = REVIEW ] && ok "an open session that moved into a lane keeps it out of SAFE" || no "moved-into lane classified '$(pa moved)'"
mk_tx cli-mover "$(bs_path "$(awt_path moved)")" 5
[ "$(pa moved)" = KEEP ] && ok "a live session working in a lane it moved into => KEEP" || no "live moved-into lane classified '$(pa moved)'"
case "$(bash "$SESSIONS" at "$(awt_path moved)" 2>/dev/null)" in
  *local_mover*transcript*) ok "sessions.sh at attributes by transcript directory";;
  *) no "sessions.sh at missed the transcript claim";; esac

# No claim at all on a Claude Code session worktree is the ABSENCE of a signal.
[ "$(pa orphan)" = REVIEW ] && ok "unclaimed .claude/worktrees/ tree is REVIEW, never SAFE" || no "unclaimed native tree classified '$(pa orphan)'"
# Control: positive evidence still works, or prune would be useless.
mk_wrap local_done "Finished" "$(bs_path "$(awt_path done)")" 9000 claude/drift-c true
[ "$(pa done)" = SAFE ] && ok "control: exact-cwd archived owner => SAFE" || no "archived exact-cwd owner not SAFE (got '$(pa done)')"

# A headless / CLI session has a transcript and no Desktop record. While it is
# live, it owns the directory it is working in — even a non-native lane.
HWT="$SB/aw-headless"
git -C "$AREPO" branch lane/headless main
git -C "$AREPO" worktree add -q "$HWT" lane/headless
echo h > "$HWT/h.txt"; git -C "$HWT" add -A; git -C "$HWT" -c user.email=w@t -c user.name=w commit -qm h
git -C "$AREPO" merge -q --no-ff -m "merge: lane/headless" lane/headless
hb(){ bash "$FLEET" prune --porcelain 2>/dev/null | awk -F'\t' '$1 ~ /\/aw-headless$/ { print $3 }'; }
[ "$(hb)" = SAFE ] && ok "control: unclaimed non-native lane is SAFE" || no "unclaimed non-native lane classified '$(hb)'"
mk_tx cli-headless "$(bs_path "$HWT")" 5
[ "$(hb)" = KEEP ] && ok "a live headless session with no Desktop record => KEEP" || no "live headless session's lane classified '$(hb)'"

# The incident's root cause, end to end through DISCOVERY (no store override):
# the first store found is readable and populated, and the owner is in a
# second Desktop instance's store under ~/.claude-desktop-profiles/.
mk_awt other-inst claude/other-inst
FHOME="$SB/fhome"
PRIM="$FHOME/AppData/Roaming/Claude/claude-code-sessions/acct/ws"
PROF="$FHOME/.claude-desktop-profiles/work/claude-code-sessions/acct/ws"
mkdir -p "$PRIM" "$PROF"
mk_wrap local_decoy "Unrelated"          "C:\\elsewhere"                         60 claude/decoy      false "" "$PRIM"
mk_wrap local_inst2 "Other instance run" "$(bs_path "$(awt_path other-inst)")" 5  claude/drift-d    false "" "$PROF"
disc(){ env -u FLEET_SESSION_STORE -u APPDATA HOME="$FHOME" "$@"; }
dstores="$(disc bash "$SESSIONS" stores 2>/dev/null)"
case "$dstores" in *".claude-desktop-profiles/work/"*) ok "discovery finds a second Desktop instance's store";;
  *) no "discovery missed the profile store";; esac
case "$dstores" in *"AppData/Roaming/Claude"*) ok "discovery keeps the primary store too";;
  *) no "discovery dropped the primary store";; esac
dib="$(disc bash "$FLEET" prune --porcelain 2>/dev/null | awk -F'\t' '$1 ~ /\/worktrees\/other-inst$/ { print $3 }')"
[ "$dib" = KEEP ] && ok "owner in another Desktop instance's store => KEEP" || no "other-instance owner missed (got '$dib')"

# Cache isolation: the index cache must be keyed by what was scanned. Before,
# a run against a fixture store overwrote the one cache a real run then read.
CSB="$SB/cache-a"; mkdir -p "$CSB/s1/a/w" "$CSB/s2/a/w" "$CSB/tmp"
mk_wrap local_c1 "Store one" "C:\\one" 60 lane/cache-one false "" "$CSB/s1/a/w"
mk_wrap local_c2 "Store two" "C:\\two" 60 lane/cache-two false "" "$CSB/s2/a/w"
( unset FLEET_SESSION_NOCACHE; export TMPDIR="$CSB/tmp"
  FLEET_SESSION_STORE="$CSB/s1" bash "$SESSIONS" index >/dev/null 2>&1
  FLEET_SESSION_STORE="$CSB/s2" bash "$SESSIONS" index 2>/dev/null ) > "$CSB/out"
if grep -q local_c2 "$CSB/out" && ! grep -q local_c1 "$CSB/out"; then
  ok "a fixture store cannot poison another store's cached index"
else no "cache served one store's rows for another"; fi

# Removal re-verifies against a FRESH scan: a claim that appears after a
# (cached) classification must stop the delete. `late` is SAFE when the cache
# is warmed; then an open session claims it; the cached table still says SAFE,
# and --remove must refuse it anyway.
mk_awt late claude/late
mk_wrap local_lateold "Old owner" "$(bs_path "$(awt_path late)")" 9000 claude/drift-e true
# Caching ON for this case (it is the point), in a cache dir of its own so no
# earlier case's index is what gets read.
unset FLEET_SESSION_NOCACHE; SUITE_TMPDIR=$TMPDIR
export TMPDIR="$SB/rcache"; mkdir -p "$TMPDIR"
[ "$(pa late)" = SAFE ] && ok "premise: 'late' is SAFE before the claim appears" || no "premise failed: 'late' is '$(pa late)'"
mk_wrap local_latenew "Opened later" "$(bs_path "$(awt_path late)")" 7200 claude/drift-f false
[ "$(pa late)" = SAFE ] && ok "premise: the cached classification is stale (still SAFE)" || no "premise failed: cache was not stale"
bash "$FLEET" prune --remove --yes >/dev/null 2>&1
export TMPDIR=$SUITE_TMPDIR FLEET_SESSION_NOCACHE=1
[ -d "$AREPO/.claude/worktrees/late" ] && ok "--remove re-verifies fresh: a late claim stops the delete" || no "--remove deleted a worktree an open session had claimed"
[ -d "$AREPO/.claude/worktrees/done" ] && no "--remove skipped a still-SAFE row" || ok "--remove still removes rows that stay SAFE"
[ -d "$AREPO/.claude/worktrees/idle-open" ] && ok "idle-open worktree survived --remove" || no "idle-open worktree was REMOVED"
[ -d "$AREPO/.claude/worktrees/orphan" ] && ok "unclaimed native worktree survived --remove" || no "unclaimed native worktree was REMOVED"

# -- land gate: directory claims (the 2026-09-28 follow-up) ---------------------
# The land gate joined owners on BRANCH alone, so it was blind in the same two
# ways prune was above: wrapper branch drift (a session in worktree
# vigilant-grothendieck recorded branch claude/keen-mccarthy) and a session that
# EnterWorktree'd into a lane, which only its transcript records. A live session
# working in the lane's worktree therefore did not block `fleet land`, which
# merged under it and rebased its tree. Every refusal below lands on the
# pre-fix gate. Same fixture helpers as the block above, pointed at a store and
# transcript root of their own (mk_wrap / mk_tx read ASTORE / ATX at call time).
echo "-- land gate: directory claims --"
LREPO="$SB/lrepo"; mkdir -p "$LREPO"
git -C "$LREPO" init -q -b main
git -C "$LREPO" config user.email t@t; git -C "$LREPO" config user.name t
git -C "$LREPO" config core.autocrlf false
echo base > "$LREPO/f"; git -C "$LREPO" add -A; git -C "$LREPO" commit -qm init
arm_gate "$LREPO"
ASTORE="$SB/lstore/acct/ws" ATX="$SB/ltx"; mkdir -p "$ASTORE" "$ATX"
export FLEET_SESSION_STORE="$SB/lstore" FLEET_TRANSCRIPT_ROOTS="$ATX"
cd "$LREPO"

mk_llane(){ # branch [worktree-dir] — one commit on its own file, tracked
  local wt=${2:-"$SB/lwt-$(printf '%s' "$1" | tr / _)"}
  git -C "$LREPO" branch "$1" main
  git -C "$LREPO" worktree add -q "$wt" "$1"
  echo "$1" > "$wt/$(printf '%s' "$1" | tr / _).txt"; git -C "$wt" add -A
  git -C "$wt" -c user.email=w@t -c user.name=w commit -qm "work $1"
  bash "$FLEET" track "$1" >/dev/null 2>&1
}
# The lane's worktree in git's own path form.
lwt(){ git -C "$LREPO" worktree list --porcelain | awk -v b="branch refs/heads/$1" '
         /^worktree / { p = substr($0, 10) } $0 == b { print p }'; }
landed(){ case "$(git -C "$LREPO" log --oneline main)" in *"merge: $1"*) return 0;; esac; return 1; }
LLOG="$LREPO/.claude/fleet/activity.log"

# Branch drift: the wrapper records a branch that is not the lane. Only the
# session's cwd — the lane's worktree, recorded natively and backslashed — ties
# it to the lane.
mk_llane lane/drift
mk_wrap local_drifter "Working here, drifted" "$(bs_path "$(lwt lane/drift)")" 5 claude/keen-drift false
bash "$FLEET" land lane/drift >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a live session in the lane's worktree under a drifted branch blocks the land (exit $lx)" \
  || no "a live session in the lane's worktree (drifted branch) did not block the land"
landed lane/drift && no "drifted-branch lane was merged under its live session" || ok "no merge under the drifted-branch session"
grep -q "local_drifter.*by cwd" "$LLOG" 2>/dev/null && ok "the refusal names the claimant and how it claims" \
  || no "refusal log does not name local_drifter by cwd"
# Control: only liveness changed, and the same lane now lands — the directory
# join refuses live claimants, not claimed directories.
mk_wrap local_drifter "Working here, drifted" "$(bs_path "$(lwt lane/drift)")" 7200 claude/keen-drift false
bash "$FLEET" land lane/drift >/dev/null 2>&1; ee "control: the same lane lands once that session is idle" 0 $?

# EnterWorktree: created elsewhere (its wrapper cwd, forever) and mid-turn (its
# wrapper timestamp is the turn's start). Only its transcript, filed under the
# lane's worktree and written seconds ago, says where it is working.
mk_llane lane/entered
mk_wrap local_enterer "Entered the lane" "$(bs_path "$SB/lwt-spawned-here")" 7200 claude/spawn-x false cli-enterer
mk_tx cli-enterer "$(bs_path "$(lwt lane/entered)")" 5
bash "$FLEET" land lane/entered >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a session that EnterWorktree'd into the lane blocks the land (exit $lx)" \
  || no "a session working in the lane via EnterWorktree did not block the land"
landed lane/entered && no "lane merged under a session that entered it" || ok "no merge under the entered session"

# A worktree path with a space in it. worktree_path_for used to take awk's $2,
# which cuts the path at the space — the join would then match nothing.
mk_llane lane/spaced "$SB/lwt dir/spaced"
mk_wrap local_spaced "In a spaced path" "$(bs_path "$(lwt lane/spaced)")" 5 claude/spaced-drift false
bash "$FLEET" land lane/spaced >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a live claim on a worktree path containing a space still blocks (exit $lx)" \
  || no "worktree path with a space: live claimant not seen"

# The gate must not act on the 15-minute index. Caching ON for these cases, in
# a cache dir of their own; each claim becomes live only AFTER the index is
# built, so the cached read is stale by construction.
unset FLEET_SESSION_NOCACHE; SUITE_TMPDIR=$TMPDIR
export TMPDIR="$SB/lcache"; mkdir -p "$TMPDIR"
mk_llane lane/woke
mk_wrap local_sleeper "Idle, then woke" "$(bs_path "$(lwt lane/woke)")" 7200 claude/sleeper-drift false
mk_llane lane/latecomer
bash "$SESSIONS" paths >/dev/null 2>&1          # the index is built now
mk_wrap local_sleeper "Idle, then woke" "$(bs_path "$(lwt lane/woke)")" 5 claude/sleeper-drift false
mk_tx cli-latecomer "$(bs_path "$(lwt lane/latecomer)")" 5   # headless: no wrapper at all
[ "$(bash "$SESSIONS" at "$(lwt lane/woke)" 2>/dev/null | cut -f7)" = "0" ] \
  && ok "premise: the cached index still calls the woken session idle" || no "premise failed: cache was not stale"
[ -z "$(bash "$SESSIONS" at "$(lwt lane/latecomer)" 2>/dev/null)" ] \
  && ok "premise: the cached index has no claim on the latecomer's worktree" || no "premise failed: cache already saw the latecomer"
[ "$(bash "$SESSIONS" at --fresh "$(lwt lane/woke)" 2>/dev/null | cut -f7)" = "1" ] \
  && ok "at --fresh re-reads liveness the cache still calls idle" || no "at --fresh trusted the cached liveness"
case "$(bash "$SESSIONS" at --fresh "$(lwt lane/latecomer)" 2>/dev/null)" in
  *cli:cli-latecomer*transcript*) ok "at --fresh sees a transcript newer than the index";;
  *) no "at --fresh missed a claim the index predates";; esac
bash "$FLEET" land lane/woke >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a claimant that woke after the index was built blocks the land (exit $lx)" \
  || no "the gate acted on the cached idle reading"
bash "$FLEET" land lane/latecomer >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a session that started in the lane after the index was built blocks the land (exit $lx)" \
  || no "the gate missed a claim newer than the index"
export TMPDIR=$SUITE_TMPDIR FLEET_SESSION_NOCACHE=1

# Self in its own worktree: its claims arrive by cwd, by transcript (named by
# the CLI session id, attributed back to its wrapper) and by live cwd, all on a
# drifted branch. It must land unaided — but only once self actually resolves.
mk_llane lane/mine
mk_wrap local_selfwt "This very session" "$(bs_path "$(lwt lane/mine)")" 5 claude/selfwt-drift false cli-selfwt
mk_tx cli-selfwt "$(bs_path "$(lwt lane/mine)")" 5
( unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  bash "$FLEET" land lane/mine >/dev/null 2>&1 ); lx=$?
[ "$lx" -ne 0 ] && ok "unresolvable self in the lane's worktree does not exempt (exit $lx)" \
  || no "an unresolved self landed on its directory claim"
CLAUDE_CODE_HOST_SESSION_ID=local_selfwt bash "$FLEET" land lane/mine >/dev/null 2>&1
ee "self in its own worktree still lands unaided" 0 $?
landed lane/mine && ok "self's own lane actually merged" || no "no merge commit for self's own lane"

# ...and self must be the ONLY live claimant: a headless peer writing in the
# same tree is the concurrent writer the gate exists for.
mk_llane lane/crowded
mk_wrap local_selfwt2 "This very session" "$(bs_path "$(lwt lane/crowded)")" 5 claude/selfwt2 false cli-selfwt2
mk_tx cli-peerwt "$(bs_path "$(lwt lane/crowded)")" 5
CLAUDE_CODE_HOST_SESSION_ID=local_selfwt2 bash "$FLEET" land lane/crowded >/dev/null 2>&1; lx=$?
[ "$lx" -ne 0 ] && ok "a live peer in self's worktree still blocks self's land (exit $lx)" \
  || no "self landed over a live peer in its own worktree"
landed lane/crowded && no "lane merged over a live peer in the worktree" || ok "no merge while a peer works in the tree"
grep -q "cli:cli-peerwt" "$LLOG" 2>/dev/null && ok "the refusal names the peer, not self" \
  || no "refusal log does not name the peer"

unset FLEET_SESSION_NOCACHE; hermetic_sessions
cd "$REPO"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
