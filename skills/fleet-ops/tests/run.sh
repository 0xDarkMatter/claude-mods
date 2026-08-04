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
bash "$FLEET" main release >/dev/null 2>&1
case "$(bash "$FLEET" main show 2>/dev/null)" in
  *local_boss*) ok "release restores heuristic resolution";; *) no "release did not restore heuristic";; esac

# Status annotates lanes with their owner's liveness, in ASCII.
mk_lane_in "$SREPO" shown-lane s.txt
mk_session local_shown "Shown session" "$SREPO/wt3" 5 claude/shown shown-lane
bash "$FLEET" track shown-lane >/dev/null 2>&1
sv="$(bash "$FLEET" status 2>&1)"
case "$sv" in *"[live]"*) ok "status annotates a live owner";; *) no "status missing [live] annotation";; esac
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

unset FLEET_SESSION_STORE FLEET_SESSION_NOCACHE
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

unset FLEET_SESSION_STORE FLEET_SESSION_NOCACHE
cd "$REPO"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
