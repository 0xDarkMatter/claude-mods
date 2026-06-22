#!/usr/bin/env bash
# Self-test for loop-ops scripts (loop-init.sh, loop-audit.sh, loop-cost.py).
#
# Offline-deterministic (no network). Scaffolds throwaway loop fixtures, asserts the
# documented exit codes + key output of each script, then cleans up. Resolves paths
# relative to itself so it works both in the repo and installed to ~/.claude/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
INIT="$SCRIPTS/loop-init.sh"
AUDIT="$SCRIPTS/loop-audit.sh"
COST="$SCRIPTS/loop-cost.py"

# Pick a python that actually executes — skips the Windows Store python3 stub.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found — skipping" >&2; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

# Write a filled, READY L1 report-only config.
good_l1() { cat > "$1" <<'EOF'
name: test-l1
pattern: pr-babysitter
tier: L1
permission_mode: dontAsk
cadence: 10m
goal: "Watch open PRs and report; never merge."
scope:
  - "src/**"
escalation: "comment on the PR; never merge to main"
budget_tokens: 200000
kill_switch: ".loops/test-l1/PAUSED exists or loop-pause label"
EOF
}

# Write a filled, READY L2 assisted config.
good_l2() { cat > "$1" <<'EOF'
name: dep-sweeper
pattern: dependency-sweeper
tier: L2
permission_mode: dontAsk
cadence: 1d
goal: "Patch-only dependency bumps behind cooldown; open a PR."
scope:
  - "package.json"
  - "package-lock.json"
verify: "npm test"
guard: "npm run typecheck"
worktree: true
land_via: fleet-ops
escalation: "minor/major bumps escalate; never merge to main"
budget_tokens: 300000
kill_switch: ".loops/dep-sweeper/PAUSED"
EOF
}

echo "=== loop-ops self-test (python: $PYTHON) ==="

# ── --help contracts (exit 0) ──────────────────────────────────────────────
echo "-- --help --"
bash "$INIT"  --help >/dev/null 2>&1; expect_exit "loop-init --help" 0 $?
bash "$AUDIT" --help >/dev/null 2>&1; expect_exit "loop-audit --help" 0 $?
"$PYTHON" "$COST" --help >/dev/null 2>&1; expect_exit "loop-cost --help" 0 $?

# ── loop-init: scaffolds dir + 3 files, substitutes fields ─────────────────
echo "-- loop-init --"
out="$(bash "$INIT" --name pr-watch --pattern pr-babysitter --tier L1 --cadence 5m --dir "$SB/loops" 2>/dev/null)"; rc=$?
expect_exit "loop-init -> 0" 0 "$rc"
expect_has  "prints the config path" "pr-watch/loop.config.yaml" "$out"
[[ -f "$SB/loops/pr-watch/loop.config.yaml" ]] && ok "wrote loop.config.yaml" || no "no loop.config.yaml"
[[ -f "$SB/loops/pr-watch/STATE.md" ]] && ok "wrote STATE.md" || no "no STATE.md"
[[ -f "$SB/loops/pr-watch/run-log.md" ]] && ok "wrote run-log.md" || no "no run-log.md"
cfg="$(cat "$SB/loops/pr-watch/loop.config.yaml")"
expect_has "substituted name" "name: pr-watch" "$cfg"
expect_has "substituted tier" "tier: L1" "$cfg"
expect_has "substituted cadence" "cadence: 5m" "$cfg"
expect_has "L1 default permission_mode" "permission_mode: dontAsk" "$cfg"
# L3 default permission_mode is bypassPermissions
bash "$INIT" --name big-job --tier L3 --dir "$SB/loops" >/dev/null 2>&1
expect_has "L3 default permission_mode" "permission_mode: bypassPermissions" "$(cat "$SB/loops/big-job/loop.config.yaml")"

# ── loop-init: refuses a populated dir -> 5, --force overwrites ─────────────
bash "$INIT" --name pr-watch --dir "$SB/loops" >/dev/null 2>&1; expect_exit "refuse populated dir -> 5" 5 $?
bash "$INIT" --name pr-watch --dir "$SB/loops" --force >/dev/null 2>&1; expect_exit "--force overwrites -> 0" 0 $?

# ── loop-init: --dry-run writes nothing ────────────────────────────────────
out="$(bash "$INIT" --name ghost --dir "$SB/dryloops" --dry-run 2>/dev/null)"; rc=$?
expect_exit "dry-run -> 0" 0 "$rc"
[[ -e "$SB/dryloops" ]] && no "dry-run created files" || ok "dry-run wrote nothing"
expect_has "dry-run prints config path" "ghost/loop.config.yaml" "$out"

# ── loop-init: usage errors ────────────────────────────────────────────────
bash "$INIT" --dir "$SB/loops" >/dev/null 2>&1; expect_exit "missing --name -> 2" 2 $?
bash "$INIT" --name BadName --dir "$SB/loops" >/dev/null 2>&1; expect_exit "non-kebab name -> 2" 2 $?
bash "$INIT" --name x --tier L9 --dir "$SB/loops" >/dev/null 2>&1; expect_exit "bad tier -> 2" 2 $?

# ── loop-audit: a freshly-init'd config is NOT ready (placeholders) -> 10 ───
echo "-- loop-audit --"
bash "$INIT" --name raw --pattern custom --tier L1 --dir "$SB/loops" >/dev/null 2>&1
out="$(bash "$AUDIT" "$SB/loops/raw/loop.config.yaml" 2>/dev/null)"; rc=$?
expect_exit "raw scaffold not ready -> 10" 10 "$rc"
expect_has  "flags the goal placeholder" "goal:" "$out"

# ── loop-audit: filled L1 config is READY -> 0 ─────────────────────────────
good_l1 "$SB/l1.yaml"
out="$(bash "$AUDIT" "$SB/l1.yaml" 2>/dev/null)"; rc=$?
expect_exit "filled L1 ready -> 0" 0 "$rc"

# ── loop-audit: filled L2 config is READY -> 0 ─────────────────────────────
good_l2 "$SB/l2.yaml"
bash "$AUDIT" "$SB/l2.yaml" >/dev/null 2>&1; expect_exit "filled L2 ready -> 0" 0 $?

# ── loop-audit: L2 missing the gate -> 10, names verify ────────────────────
grep -v '^verify:' "$SB/l2.yaml" > "$SB/l2-nogate.yaml"
out="$(bash "$AUDIT" "$SB/l2-nogate.yaml" 2>/dev/null)"; rc=$?
expect_exit "L2 missing gate -> 10" 10 "$rc"
expect_has  "names the missing gate" "verify:" "$out"

# ── loop-audit: unbounded scope -> 10 ──────────────────────────────────────
sed 's|  - "src/\*\*"|  - "*"|' "$SB/l1.yaml" > "$SB/l1-unbounded.yaml"
out="$(bash "$AUDIT" "$SB/l1-unbounded.yaml" 2>/dev/null)"; rc=$?
expect_exit "unbounded scope -> 10" 10 "$rc"
expect_has  "names unbounded scope" "unbounded" "$out"

# ── loop-audit: missing escalation -> 10 ───────────────────────────────────
grep -v '^escalation:' "$SB/l1.yaml" > "$SB/l1-noescal.yaml"
out="$(bash "$AUDIT" "$SB/l1-noescal.yaml" 2>/dev/null)"; rc=$?
expect_exit "missing escalation -> 10" 10 "$rc"
expect_has  "names escalation" "escalation:" "$out"

# ── loop-audit: missing file -> 3, unparseable -> 4, bad --min -> 2 ────────
bash "$AUDIT" "$SB/no-such.yaml" >/dev/null 2>&1; expect_exit "missing config -> 3" 3 $?
printf 'just some prose, no keys\n' > "$SB/garbage.yaml"
bash "$AUDIT" "$SB/garbage.yaml" >/dev/null 2>&1; expect_exit "unparseable -> 4" 4 $?
bash "$AUDIT" --min abc "$SB/l1.yaml" >/dev/null 2>&1; expect_exit "bad --min -> 2" 2 $?

# ── loop-audit: --json envelope schema + ready flag ────────────────────────
out="$(bash "$AUDIT" --json "$SB/l1.yaml" 2>/dev/null)"
expect_has "audit json schema" "claude-mods.loop-ops.audit/v1" "$out"
expect_has "audit json ready true" '"ready": true' "$out"
out="$(bash "$AUDIT" --json "$SB/l2-nogate.yaml" 2>/dev/null)"
expect_has "audit json ready false" '"ready": false' "$out"

# ── loop-audit: --strict turns a warning into NOT ready ────────────────────
# An L1 with permission_mode: auto is consistent-enough to pass errors but warns
# (broad for L1). Normally ready; --strict flips it.
sed 's|permission_mode: dontAsk|permission_mode: auto|' "$SB/l1.yaml" > "$SB/l1-warn.yaml"
bash "$AUDIT" "$SB/l1-warn.yaml" >/dev/null 2>&1; expect_exit "warning, normally ready -> 0" 0 $?
bash "$AUDIT" --strict "$SB/l1-warn.yaml" >/dev/null 2>&1; expect_exit "warning, --strict not ready -> 10" 10 $?

# ── loop-cost: basic run, --json, --list-models, cadence forms ─────────────
echo "-- loop-cost --"
out="$("$PYTHON" "$COST" --pattern pr-babysitter --cadence 10m --model claude-haiku-4-5 2>/dev/null)"; rc=$?
expect_exit "loop-cost -> 0" 0 "$rc"
expect_has  "prints a daily cost" "cost/day:" "$out"
expect_has  "derives runs/day from 10m" "144 runs/day" "$out"
out="$("$PYTHON" "$COST" --pattern ci-sweeper --cadence 15m --model claude-sonnet-4-6 --json 2>/dev/null)"
expect_has "cost json schema" "claude-mods.loop-ops.cost/v1" "$out"
expect_has "cost json carries runs_per_day" "runs_per_day" "$out"
out="$("$PYTHON" "$COST" --list-models 2>/dev/null)"; rc=$?
expect_exit "list-models -> 0" 0 "$rc"
expect_has  "list-models shows a model" "claude-opus-4-8" "$out"
# cron cadence parses
"$PYTHON" "$COST" --pattern daily-triage --cadence '*/10 * * * *' --model claude-haiku-4-5 >/dev/null 2>&1
expect_exit "cron cadence -> 0" 0 $?
# --runs-per-day override
out="$("$PYTHON" "$COST" --pattern custom --cadence weird --runs-per-day 5 --model claude-haiku-4-5 2>/dev/null)"; rc=$?
expect_exit "runs-per-day override -> 0" 0 "$rc"
expect_has  "uses the override" "5 runs/day" "$out"

# ── loop-cost: validation errors ───────────────────────────────────────────
"$PYTHON" "$COST" --pattern pr-babysitter --cadence 10m --model claude-nope >/dev/null 2>&1; expect_exit "unknown model -> 4" 4 $?
"$PYTHON" "$COST" --pattern not-a-pattern --cadence 10m --model claude-haiku-4-5 >/dev/null 2>&1; expect_exit "unknown pattern -> 4" 4 $?
"$PYTHON" "$COST" --pattern pr-babysitter --cadence "garbage cron" --model claude-haiku-4-5 >/dev/null 2>&1; expect_exit "bad cadence -> 4" 4 $?
"$PYTHON" "$COST" --pricing "$SB/no-pricing.json" --pattern custom --cadence 1h --input-tokens 1 --output-tokens 1 --model x >/dev/null 2>&1; expect_exit "missing pricing file -> 3" 3 $?

# ── terminal design system ─────────────────────────────────────────────────
echo "-- terminal design system --"
for s in "$INIT" "$AUDIT"; do
  b="$(basename "$s")"
  grep -q '_lib/term.sh' "$s" && ok "$b sources _lib/term.sh" || no "$b does not source _lib/term.sh"
done
grep -q 'class Term' "$COST" && ok "loop-cost carries inline Term helper" || no "loop-cost missing inline Term helper"
grep -q 'BRAND::loop' "$SKILL/../_lib/term.sh" && ok "term.sh registers the loop brand glyph" || no "term.sh missing loop brand glyph"
# Piped audit findings stay plain (no ANSI in the data stream).
po="$(bash "$AUDIT" "$SB/l2-nogate.yaml" 2>/dev/null)"
case "$po" in *$'\033'*) no "piped audit leaked ANSI into data";; *) ok "piped audit stays plain data";; esac

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
