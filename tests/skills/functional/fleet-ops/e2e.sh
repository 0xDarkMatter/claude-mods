#!/usr/bin/env bash
# fleet-ops e2e test — full lifecycle in a throwaway repo
# Run from any cwd. Tears down its own scratch dir.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/skills/fleet-ops"
FLEET="$SKILL_DIR/scripts/fleet.sh"
SCRATCH="${TMPDIR:-/tmp}/fleet-ops-e2e-$$"
PASS=0
FAIL=0

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

cleanup() {
  # Kill any daemons we spawned
  if [[ -f "$SCRATCH/.claude/fleet/daemon.pid" ]]; then
    local pid
    pid=$(cat "$SCRATCH/.claude/fleet/daemon.pid" 2>/dev/null || echo "")
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  fi
  pkill -f "fleet.sh start" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "fleet-ops e2e test"
echo "  skill: $SKILL_DIR"
echo "  scratch: $SCRATCH"

# ── setup ──
step "setup mock repo"
mkdir -p "$SCRATCH"
cd "$SCRATCH"
git init -b main -q
echo "init" > README.md
git add . && git -c user.email=e2e@test -c user.name=e2e commit -q -m init
note "repo at $SCRATCH"

# ── init ──
step "fleet init alpha beta"
bash "$FLEET" init alpha beta >/dev/null 2>&1
[[ -d .claude/fleet/lanes ]] && ok "lanes/ created" || fail "lanes/ missing"
[[ -d .claude/fleet/worktrees/alpha ]] && ok "alpha worktree created" || fail "alpha worktree missing"
[[ -d .claude/fleet/worktrees/beta ]] && ok "beta worktree created" || fail "beta worktree missing"
[[ -f .claude/fleet/signal.sh ]] && ok "signal.sh deployed" || fail "signal.sh not deployed"
grep -qxF '.claude/fleet/' .gitignore && ok ".claude/fleet/ in .gitignore" || fail ".gitignore not updated"
[[ "$(cat .claude/fleet/lanes/alpha)" == "RUNNING" ]] && ok "alpha state = RUNNING" || fail "alpha state wrong"
[[ "$(cat .claude/fleet/lanes/beta)" == "RUNNING" ]] && ok "beta state = RUNNING" || fail "beta state wrong"

# ── work in alpha lane ──
step "do work in alpha worktree, signal READY"
(
  cd .claude/fleet/worktrees/alpha
  echo "alpha feature" > a.txt
  git add . && git -c user.email=e2e@test -c user.name=e2e commit -q -m "feat: alpha"
)
echo "0 failed, 1 passed" > "$SCRATCH/alpha-test.log"
( cd .claude/fleet/worktrees/alpha && bash "$SCRATCH/.claude/fleet/signal.sh" READY "$SCRATCH/alpha-test.log" >/dev/null )
[[ "$(head -n1 .claude/fleet/lanes/alpha)" == "READY" ]] && ok "alpha state = READY after signal" || fail "alpha not READY"

step "signal.sh refuses dirty tree"
(
  cd .claude/fleet/worktrees/alpha
  echo "uncommitted change" >> a.txt
)
( cd .claude/fleet/worktrees/alpha && bash "$SCRATCH/.claude/fleet/signal.sh" READY "$SCRATCH/alpha-test.log" 2>/dev/null ) \
  && fail "signal.sh accepted dirty tree" || ok "signal.sh refused dirty tree"
( cd .claude/fleet/worktrees/alpha && git checkout -- a.txt )  # clean back up

step "signal.sh refuses failing test log"
echo "ERROR: 3 tests failed" > "$SCRATCH/bad-test.log"
( cd .claude/fleet/worktrees/alpha && bash "$SCRATCH/.claude/fleet/signal.sh" READY "$SCRATCH/bad-test.log" 2>/dev/null ) \
  && fail "signal.sh accepted failing log" || ok "signal.sh refused failing log"
# Re-signal with good log to reset state for daemon test
( cd .claude/fleet/worktrees/alpha && bash "$SCRATCH/.claude/fleet/signal.sh" READY "$SCRATCH/alpha-test.log" >/dev/null )

# ── work in beta lane ──
step "do work in beta worktree, signal READY"
(
  cd .claude/fleet/worktrees/beta
  echo "beta feature" > b.txt
  git add . && git -c user.email=e2e@test -c user.name=e2e commit -q -m "feat: beta"
)
echo "0 failed, 2 passed" > "$SCRATCH/beta-test.log"
( cd .claude/fleet/worktrees/beta && bash "$SCRATCH/.claude/fleet/signal.sh" READY "$SCRATCH/beta-test.log" >/dev/null )

# ── daemon ──
step "start daemon (background) and watch it land both lanes"
( cd "$SCRATCH" && bash "$FLEET" start ) &
DAEMON_PID=$!
note "wrapper PID: $DAEMON_PID"
sleep 4

# The daemon may finish before we sleep — verify via log instead
if grep -q "daemon start (pid " .claude/fleet/activity.log; then
  ok "daemon.pid recorded in activity log"
else
  fail "daemon never logged a start"
fi

# Wait up to 15s for both lanes to land or daemon to exit
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  alpha_state=$(head -n1 .claude/fleet/lanes/alpha 2>/dev/null || echo "MISSING")
  beta_state=$(head -n1 .claude/fleet/lanes/beta 2>/dev/null || echo "MISSING")
  [[ "$alpha_state" == "LANDED" && "$beta_state" == "LANDED" ]] && break
  sleep 1
done

[[ "$(head -n1 .claude/fleet/lanes/alpha)" == "LANDED" ]] && ok "alpha LANDED" || fail "alpha = $(head -n1 .claude/fleet/lanes/alpha)"
[[ "$(head -n1 .claude/fleet/lanes/beta)" == "LANDED" ]]  && ok "beta LANDED"  || fail "beta = $(head -n1 .claude/fleet/lanes/beta)"

# Verify merge commits on main
git -C "$SCRATCH" log --oneline main | grep -q "merge: alpha" && ok "merge: alpha commit on main" || fail "no merge: alpha commit"
git -C "$SCRATCH" log --oneline main | grep -q "merge: beta"  && ok "merge: beta commit on main"  || fail "no merge: beta commit"

# Daemon should self-exit when all lanes terminal
sleep 2
if [[ -f .claude/fleet/daemon.pid ]]; then
  fail "daemon.pid still present after all lanes terminal"
else
  ok "daemon.pid removed after self-exit"
fi
wait "$DAEMON_PID" 2>/dev/null || true

# ── refuse double-start ──
step "refuse second daemon while one is running"
output=$( ( cd "$SCRATCH" && bash "$FLEET" start ) 2>&1 || true )
if echo "$output" | grep -qiE "(already running|all lanes terminal|daemon exiting)"; then
  ok "second start handled (refused or terminal)"
else
  fail "second start unexpected"
  note "actual output: $output"
fi
pkill -f "fleet.sh start" 2>/dev/null || true
sleep 1

# ── revert ──
step "fleet revert backs out a landed merge"
bash "$FLEET" revert alpha >/dev/null 2>&1
git -C "$SCRATCH" log --oneline main | head -1 | grep -qi "revert" && ok "revert commit created on main" || fail "no revert commit"

# ── scrub-check ──
step "scrub-check catches forbidden patterns"
git -C "$SCRATCH" checkout -b scrub-test main >/dev/null 2>&1
echo "// TODO_SCRUB: remove before landing" > scrub.txt
git -C "$SCRATCH" add scrub.txt
git -C "$SCRATCH" -c user.email=e2e@test -c user.name=e2e commit -q -m "test: scrub"
# scrub-check exits non-zero on hits (intended) — capture output before grep to avoid pipefail
scrub_out=$(bash "$FLEET" scrub-check scrub-test 2>&1 || true)
echo "$scrub_out" | grep -q "FORBIDDEN" && ok "scrub-check flagged TODO_SCRUB" || fail "scrub-check missed pattern"
git -C "$SCRATCH" checkout main >/dev/null 2>&1

# ── ASCII fallback ──
step "FLEET_ASCII=1 swaps glyphs to ASCII"
ascii_out=$(FLEET_ASCII=1 bash "$FLEET" fleet 2>&1 || true)
# Tree connectors carry the ASCII signal now (+- / `-); group headers
# no longer carry icons (they sat at the junction and broke the tree).
echo "$ascii_out" | grep -qE '\+-|`-' && ok "ASCII tree connectors rendered" || fail "ASCII connectors not used"
echo "$ascii_out" | grep -qE '├─|└─|│' && fail "Unicode connectors leaked in ASCII mode" || ok "no Unicode in ASCII mode"

# ── summary ──
echo ""
echo "═══════════════════════════════════════"
echo "  ${GREEN}PASS: $PASS${OFF}    ${RED}FAIL: $FAIL${OFF}"
echo "═══════════════════════════════════════"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
