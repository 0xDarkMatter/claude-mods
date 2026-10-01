#!/usr/bin/env bash
# fleet-ops e2e — the full lane lifecycle in a throwaway repo, driven the way a
# real fleet is: init/track -> work -> signal.sh READY -> the daemon lands
# through an ARMED test gate -> revert -> daemon lifecycle -> status views.
#
# skills/fleet-ops/tests/run.sh tests each mechanism on its own; this file
# asserts they COMPOSE — daemon, gate, signal.sh and rebase-after-land working
# together over real worktrees. Gated by tests/run-skill-tests.sh since
# 2026-09-28; before that nothing ran it, and it had drifted to 7 FAILs, every
# one a fleet-ops contract change it never saw.
#
# Contract it relies on:
#   - `fleet land` / `fleet start` REFUSE while test_cmd is unset, so the
#     fixture arms .claude/fleet/config — with a gate that can genuinely fail,
#     never a bare `true`, so a red gate is exercised too (lane delta).
#   - `signal.sh READY <log> <exit-code>`: the exit code is the verdict; the log
#     is never word-grepped for "failed"/"error".
#
# Hermetic: its own TMPDIR (sessions.sh caches its index under TMPDIR, one file
# per set of stores scanned, so each run's fresh fixture store would otherwise
# leave a file in the developer's TMPDIR; older sessions.sh keyed the cache by
# UID alone, and a fixture scan overwrote the real index), an empty session
# store, no transcript roots, and it kills only the daemons it started — never
# `pkill -f "fleet.sh start"`, which hit every daemon on the machine.
#
# Usage: bash tests/skills/functional/fleet-ops/e2e.sh   (any cwd; ~1 min on Windows)
# Exit:  0 all pass, 1 one or more failures
set -uo pipefail   # no -e: a failed step records FAIL and the run continues

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/skills/fleet-ops"
FLEET="$SKILL_DIR/scripts/fleet.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fleet-ops-e2e.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
REPO="$SCRATCH/repo"
PASS=0
FAIL=0

# === HERMETIC ENV ===
# The caller's fleet knobs must never reach the logic under test (same list and
# reasoning as skills/fleet-ops/tests/run.sh).
unset FLEET_SKIP_SESSION_CHECK FLEET_SESSION_STORE FLEET_SESSION_NOCACHE \
      FLEET_SESSION_LIVE_SECS FLEET_SESSION_CACHE_TTL FLEET_SESSION_MAX_AGE_DAYS \
      FLEET_SELF_SESSION_ID FLEET_NO_PRUNE_HINT FLEET_PRUNE_ROOTS \
      FLEET_PRUNE_MAX_REPOS FLEET_ASCII icons
mkdir -p "$SCRATCH/tmp" "$SCRATCH/no-sessions"
export TMPDIR="$SCRATCH/tmp"
# Set-but-empty FLEET_TRANSCRIPT_ROOTS means "no transcript signal" to the
# sessions.sh that reads it; unset, it would walk the real ~/.claude/projects.
export FLEET_SESSION_STORE="$SCRATCH/no-sessions" FLEET_TRANSCRIPT_ROOTS=""

# colors (fall back if no terminal)
if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  GREEN=""; RED=""; CYAN=""; DIM=""; OFF=""
fi

step() { echo ""; echo "${CYAN}── $* ──${OFF}"; }
ok()   { echo "${GREEN}PASS${OFF}: $*"; PASS=$((PASS+1)); }
fail() { echo "${RED}FAIL${OFF}: $*"; FAIL=$((FAIL+1)); }
note() { echo "${DIM}  $*${OFF}"; }

# Poll until "$@" succeeds or $1 seconds pass. Never a fixed sleep: the daemon
# is fast on Linux and slow on Windows, and a fixed sleep is wrong on both.
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
}
lane()        { head -n1 "$REPO/.claude/fleet/lanes/$1" 2>/dev/null || echo MISSING; }
on_main()     { git -C "$REPO" cat-file -e "main:$1" 2>/dev/null; }   # is path $1 in main's tree?
main_log()    { git -C "$REPO" log --oneline main; }                  # captured, never piped to grep -q (SIGPIPE under pipefail)
pid_file()    { cat "$REPO/.claude/fleet/daemon.pid" 2>/dev/null; }
gone()        { ! kill -0 "$1" 2>/dev/null; }
daemon_live() { local p; p=$(pid_file) && [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# Every daemon this run starts, so cleanup can reap exactly those and no others.
DAEMONS=()
cleanup() {
  local p
  for p in $(pid_file) ${DAEMONS[@]+"${DAEMONS[@]}"}; do
    kill -TERM "$p" 2>/dev/null || true
  done
  for p in ${DAEMONS[@]+"${DAEMONS[@]}"}; do
    wait_for 5 gone "$p" || kill -KILL "$p" 2>/dev/null || true
  done
  cd / && rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "fleet-ops e2e test"
echo "  skill: $SKILL_DIR"
echo "  scratch: $SCRATCH"

# ── setup ──
step "setup mock repo"
git init -b main -q "$REPO"
git -C "$REPO" config user.email e2e@test
git -C "$REPO" config user.name e2e          # fleet's own merges/reverts need an identity
git -C "$REPO" config core.autocrlf false
cd "$REPO" || exit 1
echo "init" > README.md
git add README.md && git commit -q -m init
note "repo at $REPO"

# ── init ──
step "fleet init alpha beta"
bash "$FLEET" init alpha beta >/dev/null 2>&1
[[ -d .claude/fleet/lanes ]] && ok "lanes/ created" || fail "lanes/ missing"
[[ -d .fleet-worktrees/alpha ]] && ok "alpha worktree created" || fail "alpha worktree missing"
[[ -d .fleet-worktrees/beta ]] && ok "beta worktree created" || fail "beta worktree missing"
[[ -f .claude/fleet/signal.sh ]] && ok "signal.sh deployed" || fail "signal.sh not deployed"
grep -qxF '.claude/fleet/' .gitignore && ok ".claude/fleet/ in .gitignore" || fail ".gitignore not updated"
grep -qxF '.fleet-worktrees/' .gitignore && ok ".fleet-worktrees/ in .gitignore" || fail ".fleet-worktrees/ not in .gitignore"
[[ "$(lane alpha)" == "RUNNING" ]] && ok "alpha state = RUNNING" || fail "alpha state wrong"
[[ "$(lane beta)" == "RUNNING" ]] && ok "beta state = RUNNING" || fail "beta state wrong"

# ── arm the gate ──
step "arm the test gate (fleet refuses to land without one)"
bash "$FLEET" start >/dev/null 2>&1 && fail "daemon started with the gate unarmed" || ok "daemon refuses to start with the gate unarmed"
# Lane delta below commits gate-breaker.txt: its own tests pass, the gate fails.
cat > .claude/fleet/config <<'EOF'
test_cmd=test ! -e gate-breaker.txt
poll_interval=1
EOF
cfg=$(bash "$FLEET" config 2>/dev/null)
case "$cfg" in
  *"test_cmd=test ! -e gate-breaker.txt"*) ok "fleet config reports the gate armed" ;;
  *) fail "fleet config does not show the armed gate"; note "$cfg" ;;
esac

# ── track (native-spawn path) ──
step "fleet track registers an existing branch as a lane"
git branch gamma main
bash "$FLEET" track gamma >/dev/null 2>&1
[[ -f .claude/fleet/lanes/gamma ]] && ok "gamma lane file created" || fail "gamma lane missing"
[[ "$(lane gamma)" == "RUNNING" ]] && ok "gamma state = RUNNING" || fail "gamma state wrong"
[[ -d .fleet-worktrees/gamma ]] && fail "track created a worktree (it must not)" || ok "track created no worktree"
bash "$FLEET" track no-such-branch >/dev/null 2>&1 && fail "track accepted missing branch" || ok "track refused missing branch"
# untrack gamma so it doesn't block daemon self-exit later
git branch -D gamma >/dev/null 2>&1
rm -f .claude/fleet/lanes/gamma

# ── work in alpha lane ──
step "do work in alpha worktree, signal READY"
(
  cd .fleet-worktrees/alpha
  echo "alpha feature" > a.txt
  git add a.txt && git commit -q -m "feat: alpha"
)
echo "0 failed, 1 passed" > "$SCRATCH/alpha-test.log"
( cd .fleet-worktrees/alpha && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/alpha-test.log" 0 >/dev/null 2>&1 )
[[ "$(lane alpha)" == "READY" ]] && ok "alpha state = READY after signal" || fail "alpha not READY"

step "signal.sh refuses dirty tree"
echo "uncommitted change" >> .fleet-worktrees/alpha/a.txt
( cd .fleet-worktrees/alpha && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/alpha-test.log" 0 >/dev/null 2>&1 ) \
  && fail "signal.sh accepted dirty tree" || ok "signal.sh refused dirty tree"
( cd .fleet-worktrees/alpha && git checkout -- a.txt )  # clean back up

step "signal.sh refuses a failing test run"
# The exit code is the verdict, passed as the third arg (the test command's own
# $?), or — when the lane only has a log — as a trailing "exit code: N" line.
echo "ERROR: 3 tests failed" > "$SCRATCH/bad-test.log"
( cd .fleet-worktrees/alpha && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/bad-test.log" 1 >/dev/null 2>&1 ) \
  && fail "signal.sh accepted a failing exit code" || ok "signal.sh refused a failing exit code"
printf 'ERROR: 3 tests failed\nexit code: 1\n' > "$SCRATCH/bad-test-rc.log"
( cd .fleet-worktrees/alpha && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/bad-test-rc.log" >/dev/null 2>&1 ) \
  && fail "signal.sh accepted a log ending 'exit code: 1'" || ok "signal.sh refused a log ending 'exit code: 1'"
[[ "$(lane alpha)" == "READY" ]] && ok "refused signals left alpha's state alone" || fail "a refused signal changed alpha to $(lane alpha)"

# ── work in beta lane ──
step "do work in beta worktree, signal READY"
(
  cd .fleet-worktrees/beta
  echo "beta feature" > b.txt
  git add b.txt && git commit -q -m "feat: beta"
)
echo "0 failed, 2 passed" > "$SCRATCH/beta-test.log"
( cd .fleet-worktrees/beta && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/beta-test.log" 0 >/dev/null 2>&1 )
[[ "$(lane beta)" == "READY" ]] && ok "beta state = READY after signal" || fail "beta not READY"

# ── a lane the gate must catch ──
step "delta: green on its own tests, red at the landing gate"
bash "$FLEET" init delta >/dev/null 2>&1
(
  cd .fleet-worktrees/delta
  echo "boom" > gate-breaker.txt
  git add gate-breaker.txt && git commit -q -m "feat: delta"
)
echo "0 failed, 4 passed" > "$SCRATCH/delta-test.log"
( cd .fleet-worktrees/delta && bash "$REPO/.claude/fleet/signal.sh" READY "$SCRATCH/delta-test.log" 0 >/dev/null 2>&1 )
[[ "$(lane delta)" == "READY" ]] && ok "delta state = READY after signal" || fail "delta not READY"

# ── daemon ──
step "start daemon (background) and watch it land the queue"
bash "$FLEET" start >>"$SCRATCH/daemon1.out" 2>&1 &
D1=$!; DAEMONS+=("$D1")
note "daemon PID: $D1"
wait_for 30 grep -q "daemon start (pid " .claude/fleet/activity.log \
  && ok "daemon logged its start" || fail "daemon never logged a start"

settled() { [[ "$(lane alpha)" == LANDED && "$(lane beta)" == LANDED && "$(lane delta)" == FAILED ]]; }
wait_for 120 settled || note "timed out waiting for the queue to settle"

[[ "$(lane alpha)" == "LANDED" ]] && ok "alpha LANDED" || fail "alpha = $(lane alpha)"
[[ "$(lane beta)" == "LANDED" ]]  && ok "beta LANDED"  || fail "beta = $(lane beta)"
log_main=$(main_log)
case "$log_main" in *"merge: alpha"*) ok "merge: alpha commit on main" ;; *) fail "no merge: alpha commit" ;; esac
case "$log_main" in *"merge: beta"*)  ok "merge: beta commit on main"  ;; *) fail "no merge: beta commit" ;; esac
on_main a.txt && on_main b.txt && ok "main carries alpha's and beta's work" || fail "main is missing a landed lane's files"

grep -qF "running test_cmd: test ! -e gate-breaker.txt" .claude/fleet/activity.log \
  && ok "activity log shows the gate ran" || fail "no 'running test_cmd' line — the gate never ran"
[[ "$(lane delta)" == "FAILED" ]] && ok "delta FAILED at the post-merge gate" || fail "delta = $(lane delta)"
on_main gate-breaker.txt && fail "delta's gate-breaking merge is still on main" || ok "red gate rewound main (no gate-breaker.txt)"
case "$log_main" in *"merge: delta"*) fail "merge: delta survived the red gate" ;; *) ok "no merge: delta on main" ;; esac

# Daemon should self-exit when all lanes terminal (LANDED or FAILED)
if wait_for 30 gone "$D1"; then
  wait "$D1"; rc=$?
  [[ $rc -eq 0 ]] && ok "daemon self-exited cleanly (rc 0)" || fail "daemon exited rc $rc"
else
  fail "daemon still running after all lanes terminal"
fi
[[ -f .claude/fleet/daemon.pid ]] && fail "daemon.pid still present after self-exit" || ok "daemon.pid removed after self-exit"

step "a fresh start with every lane terminal exits at once"
out=$(bash "$FLEET" start 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"all lanes terminal"* ]]; then
  ok "second start handled (all lanes terminal)"
else
  fail "second start unexpected (rc $rc)"
  note "actual output: $out"
fi
[[ -f .claude/fleet/daemon.pid ]] && fail "terminal-exit left daemon.pid behind" || ok "no daemon.pid after terminal exit"

# ── revert ──
step "fleet revert backs out a landed merge"
bash "$FLEET" revert alpha >/dev/null 2>&1 && ok "fleet revert alpha exited 0" || fail "fleet revert alpha failed"
case "$(git -C "$REPO" log -1 --format=%s main)" in
  Revert*) ok "revert commit created on main" ;;
  *)       fail "no revert commit" ;;
esac
on_main a.txt && fail "a.txt still on main after revert" || ok "alpha's work is gone from main"
on_main b.txt && ok "beta's work untouched by alpha's revert" || fail "reverting alpha took beta's work too"
[[ "$(lane alpha)" == "RUNNING" ]] && ok "reverted lane back to RUNNING" || fail "alpha = $(lane alpha) after revert"

# ── daemon lifecycle: double start, stop ──
step "refuse a second daemon while one is running; fleet stop ends it"
# alpha is RUNNING again after the revert, so this daemon has a live lane and
# idles instead of self-exiting.
bash "$FLEET" start >>"$SCRATCH/daemon2.out" 2>&1 &
D2=$!; DAEMONS+=("$D2")
wait_for 30 daemon_live && ok "daemon up with a RUNNING lane" || fail "daemon never came up"
out=$(bash "$FLEET" start 2>&1); rc=$?
if [[ $rc -ne 0 && "$out" == *"already running"* ]]; then
  ok "second daemon refused while one is running"
else
  fail "second start unexpected (rc $rc)"
  note "actual output: $out"
fi
out=$(bash "$FLEET" stop 2>&1); rc=$?
wait_for 10 gone "$D2" && ok "fleet stop ended the daemon" || fail "daemon survived fleet stop"
# SIGTERM alone must do it: a daemon that ignores it only dies to the SIGKILL
# escalation, and one that deletes its PID file without exiting is a ghost.
case "$out" in
  *SIGKILL*)         fail "fleet stop had to escalate to SIGKILL" ;;
  *"daemon stopped"*) ok "daemon exited on SIGTERM, no SIGKILL needed" ;;
  *)                 fail "fleet stop said neither"; note "actual output: $out" ;;
esac
[[ -f .claude/fleet/daemon.pid ]] && fail "daemon.pid left after fleet stop" || ok "daemon.pid removed after fleet stop"

true & dead=$!; wait "$dead"
echo "$dead" > .claude/fleet/daemon.pid
out=$(bash "$FLEET" stop 2>&1)
if [[ ! -f .claude/fleet/daemon.pid && "$out" == *"stale PID file"* ]]; then
  ok "fleet stop clears a stale daemon.pid"
else
  fail "stale daemon.pid not cleared"; note "actual output: $out"
fi

# ── scrub-check ──
step "scrub-check catches forbidden patterns"
git checkout -q -b scrub-test main
# Marker built by concatenation: the scrub greps every ADDED diff line, so a
# contiguous token in this file would refuse the branch that edits it.
echo "// TODO_""SCRUB: remove before landing" > scrub.txt
git add scrub.txt
git commit -q -m "test: scrub"
# scrub-check exits non-zero on hits (intended) — capture output before matching
scrub_out=$(bash "$FLEET" scrub-check scrub-test 2>&1 || true)
case "$scrub_out" in *FORBIDDEN*) ok "scrub-check flagged the scrub marker" ;; *) fail "scrub-check missed pattern" ;; esac
git checkout -q main

# ── ASCII fallback ──
step "FLEET_ASCII=1 swaps glyphs to ASCII"
ascii_out=$(FLEET_ASCII=1 bash "$FLEET" fleet 2>&1 || true)
# Tree connectors carry the ASCII signal now (+- / `-); group headers
# no longer carry icons (they sat at the junction and broke the tree).
echo "$ascii_out" | grep -qE '\+-|`-' && ok "ASCII tree connectors rendered" || fail "ASCII connectors not used"
echo "$ascii_out" | grep -qE '├─|└─|│' && fail "Unicode connectors leaked in ASCII mode" || ok "no Unicode in ASCII mode"

# ── verbose view ──
step "fleet fleet --verbose shows per-lane detail"
verbose_out=$(bash "$FLEET" fleet --verbose 2>&1 || true)
echo "$verbose_out" | grep -q "verbose" && ok "verbose header present" || fail "no verbose header"
echo "$verbose_out" | grep -q "worktree:" && ok "verbose shows worktree path" || fail "no worktree path in verbose"

# ── works from inside a worktree (cwd-bug regression test) ──
step "fleet fleet works from inside a worktree"
wt_out=$( cd "$REPO/.fleet-worktrees/alpha" 2>/dev/null && bash "$FLEET" fleet 2>&1 || true )
echo "$wt_out" | grep -q "alpha" && ok "fleet view from worktree finds lanes" || fail "fleet view from worktree empty"

# ── summary ──
echo ""
echo "═══════════════════════════════════════"
echo "  ${GREEN}PASS: $PASS${OFF}    ${RED}FAIL: $FAIL${OFF}"
echo "═══════════════════════════════════════"

[[ $FAIL -eq 0 ]]
