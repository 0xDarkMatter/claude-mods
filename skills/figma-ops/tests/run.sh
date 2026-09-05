#!/usr/bin/env bash
# Self-test for figma-ops.
#
# Offline-deterministic (no Figma, no network). Exercises scripts/plan-layout.mjs
# against the shipped fixture and asserts the documented exit codes, output shape,
# and the geometric invariants the SKILL.md promises (true aspect ratio preserved,
# every image inside the canvas margin, overlap budget honoured, grid has no
# overlaps at all). Resolves paths relative to itself so it works in the repo and
# once installed to ~/.claude/skills/figma-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or skipped: no node), 1 one or more failures
#
# Canvas behaviour (upload_assets, use_figma) cannot be tested offline; those rules
# are enforced by the SKILL.md gates, not by this suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
PLAN="$SKILL/scripts/plan-layout.mjs"
FIX="$SKILL/assets/plus-layout.example.json"

if ! command -v node >/dev/null 2>&1; then
  echo "figma-ops self-test: node not found — skipping (exit 0)"; exit 0
fi

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }

echo "=== figma-ops self-test ==="

# ── contract: --help, usage, bad input ───────────────────────────────────────
node "$PLAN" --help >/dev/null 2>&1;                       expect_exit "--help" 0 $?
node "$PLAN" >/dev/null 2>&1;                              expect_exit "no --input is usage error" 2 $?
node "$PLAN" --input "$FIX" --mode sideways >/dev/null 2>&1; expect_exit "unknown mode is usage error" 2 $?
node "$PLAN" --input /nonexistent.json >/dev/null 2>&1;    expect_exit "missing file is bad input" 3 $?
echo '{"images":[{"id":"x","w":100}]}' | node "$PLAN" --input - >/dev/null 2>&1; expect_exit "missing h is bad input" 3 $?
echo '{"images":[{"id":"x","w":100,"h":50,"arm":"Q"}]}' | node "$PLAN" --input - >/dev/null 2>&1; expect_exit "unknown arm is bad input" 3 $?

# stdout must be data-only: JSON parses even when stderr has diagnostics
OUT="$(node "$PLAN" --input "$FIX" --mode loose --json 2>/dev/null)"; RC=$?
expect_exit "loose plan on fixture" 0 $RC
node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' <<<"$OUT" >/dev/null 2>&1 && ok "stdout is valid JSON" || no "stdout is not valid JSON"

# ── invariants via a small node checker ──────────────────────────────────────
check() { # $1 = mode, $2 = expected exit
  local mode="$1" want="$2" json rc
  json="$(node "$PLAN" --input "$FIX" --mode "$mode" --json 2>/dev/null)"; rc=$?
  expect_exit "mode $mode exit code" "$want" "$rc"
  # Checker is a separate file: a `node -` heredoc cannot also take the plan on
  # stdin (the second redirection wins and node executes the JSON as a script).
  node "$HERE/check-invariants.mjs" "$mode" "$FIX" <<<"$json"
  [[ $? -eq 0 ]] && ok "mode $mode invariants" || no "mode $mode invariants"
}
check loose 0
check plus 0
check grid 0

# ── budget breach surfaces as exit 10 (still emits output) ───────────────────
node "$PLAN" --input "$FIX" --mode loose --tuck 400 --budget 10x10 --json >/dev/null 2>&1
expect_exit "over-budget overlap exits 10" 10 $?

echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
