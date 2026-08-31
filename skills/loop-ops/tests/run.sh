#!/usr/bin/env bash
# Self-test for loop-ops scripts (loop-scaffold.sh, loop-check.sh, loop-estimate.py).
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
INIT="$SCRIPTS/loop-scaffold.sh"
AUDIT="$SCRIPTS/loop-check.sh"
COST="$SCRIPTS/loop-estimate.py"
SYNC="$SCRIPTS/check-pricing-sync.py"
DOCTOR="$SCRIPTS/loop-doctor.sh"

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
pattern: pr-watch
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
name: dep-bump
pattern: dep-bump
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
kill_switch: ".loops/dep-bump/PAUSED"
EOF
}

echo "=== loop-ops self-test (python: $PYTHON) ==="

# ── --help contracts (exit 0) ──────────────────────────────────────────────
echo "-- --help --"
bash "$INIT"  --help >/dev/null 2>&1; expect_exit "loop-scaffold --help" 0 $?
bash "$AUDIT" --help >/dev/null 2>&1; expect_exit "loop-check --help" 0 $?
"$PYTHON" "$COST" --help >/dev/null 2>&1; expect_exit "loop-estimate --help" 0 $?

# ── loop-scaffold: scaffolds dir + 3 files, substitutes fields ─────────────────
echo "-- loop-scaffold --"
out="$(bash "$INIT" --name pr-watch --pattern pr-watch --tier L1 --cadence 5m --dir "$SB/loops" 2>/dev/null)"; rc=$?
expect_exit "loop-scaffold -> 0" 0 "$rc"
expect_has  "prints the config path" "pr-watch/loop.config.yaml" "$out"
[[ -f "$SB/loops/pr-watch/loop.config.yaml" ]] && ok "wrote loop.config.yaml" || no "no loop.config.yaml"
[[ -f "$SB/loops/pr-watch/STATE.md" ]] && ok "wrote STATE.md" || no "no STATE.md"
[[ -f "$SB/loops/pr-watch/run-log.md" ]] && ok "wrote run-log.md" || no "no run-log.md"
[[ -f "$SB/loops/pr-watch/run.md" ]] && ok "wrote run.md" || no "no run.md"
runmd="$(cat "$SB/loops/pr-watch/run.md")"
expect_has "run.md substitutes loop name" "Run: pr-watch" "$runmd"
expect_has "run.md substitutes tier" "tier L1)" "$runmd"
# runner-agnostic wrapper: emitted, executable, fully substituted, no GH Actions dep
[[ -f "$SB/loops/pr-watch/loop-run.sh" ]] && ok "wrote loop-run.sh" || no "no loop-run.sh"
runsh="$(cat "$SB/loops/pr-watch/loop-run.sh")"
case "$runsh" in *"<loop-name>"*|*"<permission-mode>"*) no "loop-run.sh left a placeholder";; *) ok "loop-run.sh fully substituted";; esac
expect_has "loop-run.sh wires the gated mode" "--permission-mode dontAsk" "$runsh"
cfg="$(cat "$SB/loops/pr-watch/loop.config.yaml")"
expect_has "substituted name" "name: pr-watch" "$cfg"
expect_has "substituted tier" "tier: L1" "$cfg"
expect_has "substituted cadence" "cadence: 5m" "$cfg"
expect_has "L1 default permission_mode" "permission_mode: dontAsk" "$cfg"
# L3 default permission_mode is bypassPermissions
bash "$INIT" --name big-job --tier L3 --dir "$SB/loops" >/dev/null 2>&1
expect_has "L3 default permission_mode" "permission_mode: bypassPermissions" "$(cat "$SB/loops/big-job/loop.config.yaml")"

# ── loop-scaffold: refuses a populated dir -> 5, --force overwrites ─────────────
bash "$INIT" --name pr-watch --dir "$SB/loops" >/dev/null 2>&1; expect_exit "refuse populated dir -> 5" 5 $?
bash "$INIT" --name pr-watch --dir "$SB/loops" --force >/dev/null 2>&1; expect_exit "--force overwrites -> 0" 0 $?

# ── loop-scaffold: --dry-run writes nothing ────────────────────────────────────
out="$(bash "$INIT" --name ghost --dir "$SB/dryloops" --dry-run 2>/dev/null)"; rc=$?
expect_exit "dry-run -> 0" 0 "$rc"
[[ -e "$SB/dryloops" ]] && no "dry-run created files" || ok "dry-run wrote nothing"
expect_has "dry-run prints config path" "ghost/loop.config.yaml" "$out"

# ── loop-scaffold: usage errors ────────────────────────────────────────────────
bash "$INIT" --dir "$SB/loops" >/dev/null 2>&1; expect_exit "missing --name -> 2" 2 $?
bash "$INIT" --name BadName --dir "$SB/loops" >/dev/null 2>&1; expect_exit "non-kebab name -> 2" 2 $?
bash "$INIT" --name x --tier L9 --dir "$SB/loops" >/dev/null 2>&1; expect_exit "bad tier -> 2" 2 $?

# pattern-seeding: a known pattern seeds a near-ready, audit-clean config
bash "$INIT" --name seed-l1 --pattern ci-watch --tier L1 --cadence 15m --dir "$SB/seed" >/dev/null 2>&1
seedcfg="$(cat "$SB/seed/seed-l1/loop.config.yaml")"
expect_has "seeded config carries the pattern goal" "Detect red CI" "$seedcfg"
expect_has "seeded L1 leaves a graduation block" "graduate to L2" "$seedcfg"
bash "$AUDIT" "$SB/seed/seed-l1/loop.config.yaml" >/dev/null 2>&1; expect_exit "seeded L1 audits clean -> 0" 0 $?
# at L2 the pattern's gate is filled (not commented) and audits clean
bash "$INIT" --name seed-l2 --pattern ci-watch --tier L2 --cadence 15m --dir "$SB/seed" >/dev/null 2>&1
l2cfg="$(cat "$SB/seed/seed-l2/loop.config.yaml")"
case "$l2cfg" in *$'\nverify: "npm test"'*) ok "seeded L2 fills the gate";; *) no "seeded L2 did not fill the gate";; esac
bash "$AUDIT" "$SB/seed/seed-l2/loop.config.yaml" >/dev/null 2>&1; expect_exit "seeded L2 audits clean -> 0" 0 $?
# an unknown pattern falls back to the generic placeholder template (not ready)
bash "$INIT" --name seed-x --pattern custom --tier L1 --dir "$SB/seed" >/dev/null 2>&1
case "$(cat "$SB/seed/seed-x/loop.config.yaml")" in *"<one sentence"*) ok "unknown pattern uses generic template";; *) no "unknown pattern did not use template";; esac
# v2 archetypes: scaffold must be audit-clean AND doctor-clean at L1 + known to the cost model
# (doctor-clean catches budget < tokens/run — the metric-chase trap: it seeds a bigger budget)
for p in metric-chase regression-watch digest backfill monitor freshness; do
  bash "$INIT" --name "a-$p" --pattern "$p" --tier L1 --dir "$SB/arch" >/dev/null 2>&1
  bash "$AUDIT" "$SB/arch/a-$p/loop.config.yaml" >/dev/null 2>&1; expect_exit "archetype $p seeds audit-clean (L1)" 0 $?
  bash "$DOCTOR" --offline "$SB/arch/a-$p/loop.config.yaml" >/dev/null 2>&1; expect_exit "archetype $p doctors clean (L1)" 0 $?
  "$PYTHON" "$COST" --pattern "$p" --cadence 1h --model claude-haiku-4-5 >/dev/null 2>&1; expect_exit "cost model knows $p" 0 $?
done
# the most expensive archetype at L2: gate filled, budget fits the tick (audit + doctor clean)
bash "$INIT" --name a-mc --pattern metric-chase --tier L2 --cadence 1h --dir "$SB/arch" >/dev/null 2>&1
bash "$AUDIT" "$SB/arch/a-mc/loop.config.yaml" >/dev/null 2>&1; expect_exit "metric-chase L2 audits clean -> 0" 0 $?
bash "$DOCTOR" --offline "$SB/arch/a-mc/loop.config.yaml" >/dev/null 2>&1; expect_exit "metric-chase L2 doctors clean (budget fits) -> 0" 0 $?

# ── loop-scaffold: --host records the execution surface ────────────────────────
# `host:` selects which constraints loop-doctor enforces (references/native-scheduling.md).
echo "-- loop-scaffold --host --"
bash "$INIT" --name h-default --dir "$SB/hosts" >/dev/null 2>&1
expect_has "host defaults to local" "host: local" "$(cat "$SB/hosts/h-default/loop.config.yaml")"
bash "$INIT" --name h-cloud --host cloud-routine --dir "$SB/hosts" >/dev/null 2>&1
expect_has "template render carries --host" "host: cloud-routine" "$(cat "$SB/hosts/h-cloud/loop.config.yaml")"
# the seeded (known --pattern) path is a separate renderer - it must carry host too
bash "$INIT" --name h-seed --pattern digest --host desktop-task --dir "$SB/hosts" >/dev/null 2>&1
expect_has "seeded render carries --host" "host: desktop-task" "$(cat "$SB/hosts/h-seed/loop.config.yaml")"
bash "$INIT" --name h-bad --host nonsense --dir "$SB/hosts" >/dev/null 2>&1; expect_exit "unknown --host -> 2" 2 $?

# ── loop-check: a freshly-init'd config is NOT ready (placeholders) -> 10 ───
echo "-- loop-check --"
bash "$INIT" --name raw --pattern custom --tier L1 --dir "$SB/loops" >/dev/null 2>&1
out="$(bash "$AUDIT" "$SB/loops/raw/loop.config.yaml" 2>/dev/null)"; rc=$?
expect_exit "raw scaffold not ready -> 10" 10 "$rc"
expect_has  "flags the goal placeholder" "goal:" "$out"

# ── loop-check: filled L1 config is READY -> 0 ─────────────────────────────
good_l1 "$SB/l1.yaml"
out="$(bash "$AUDIT" "$SB/l1.yaml" 2>/dev/null)"; rc=$?
expect_exit "filled L1 ready -> 0" 0 "$rc"

# ── loop-check: filled L2 config is READY -> 0 ─────────────────────────────
good_l2 "$SB/l2.yaml"
bash "$AUDIT" "$SB/l2.yaml" >/dev/null 2>&1; expect_exit "filled L2 ready -> 0" 0 $?

# ── loop-check: L2 missing the gate -> 10, names verify ────────────────────
grep -v '^verify:' "$SB/l2.yaml" > "$SB/l2-nogate.yaml"
out="$(bash "$AUDIT" "$SB/l2-nogate.yaml" 2>/dev/null)"; rc=$?
expect_exit "L2 missing gate -> 10" 10 "$rc"
expect_has  "names the missing gate" "verify:" "$out"

# ── loop-check: unbounded scope -> 10 ──────────────────────────────────────
sed 's|  - "src/\*\*"|  - "*"|' "$SB/l1.yaml" > "$SB/l1-unbounded.yaml"
out="$(bash "$AUDIT" "$SB/l1-unbounded.yaml" 2>/dev/null)"; rc=$?
expect_exit "unbounded scope -> 10" 10 "$rc"
expect_has  "names unbounded scope" "unbounded" "$out"

# ── loop-check: missing escalation -> 10 ───────────────────────────────────
grep -v '^escalation:' "$SB/l1.yaml" > "$SB/l1-noescal.yaml"
out="$(bash "$AUDIT" "$SB/l1-noescal.yaml" 2>/dev/null)"; rc=$?
expect_exit "missing escalation -> 10" 10 "$rc"
expect_has  "names escalation" "escalation:" "$out"

# ── loop-check: missing file -> 3, unparseable -> 4, bad --min -> 2 ────────
bash "$AUDIT" "$SB/no-such.yaml" >/dev/null 2>&1; expect_exit "missing config -> 3" 3 $?
printf 'just some prose, no keys\n' > "$SB/garbage.yaml"
bash "$AUDIT" "$SB/garbage.yaml" >/dev/null 2>&1; expect_exit "unparseable -> 4" 4 $?
bash "$AUDIT" --min abc "$SB/l1.yaml" >/dev/null 2>&1; expect_exit "bad --min -> 2" 2 $?

# ── loop-check: --json envelope schema + ready flag ────────────────────────
out="$(bash "$AUDIT" --json "$SB/l1.yaml" 2>/dev/null)"
expect_has "audit json schema" "claude-mods.loop-ops.check/v1" "$out"
expect_has "audit json ready true" '"ready": true' "$out"
out="$(bash "$AUDIT" --json "$SB/l2-nogate.yaml" 2>/dev/null)"
expect_has "audit json ready false" '"ready": false' "$out"

# ── loop-check: --strict turns a warning into NOT ready ────────────────────
# An L1 with permission_mode: auto is consistent-enough to pass errors but warns
# (broad for L1). Normally ready; --strict flips it.
sed 's|permission_mode: dontAsk|permission_mode: auto|' "$SB/l1.yaml" > "$SB/l1-warn.yaml"
bash "$AUDIT" "$SB/l1-warn.yaml" >/dev/null 2>&1; expect_exit "warning, normally ready -> 0" 0 $?
bash "$AUDIT" --strict "$SB/l1-warn.yaml" >/dev/null 2>&1; expect_exit "warning, --strict not ready -> 10" 10 $?

# ── loop-estimate: basic run, --json, --list-models, cadence forms ─────────────
echo "-- loop-estimate --"
out="$("$PYTHON" "$COST" --pattern pr-watch --cadence 10m --model claude-haiku-4-5 2>/dev/null)"; rc=$?
expect_exit "loop-estimate -> 0" 0 "$rc"
expect_has  "prints a daily cost" "cost/day:" "$out"
expect_has  "derives runs/day from 10m" "144 runs/day" "$out"
out="$("$PYTHON" "$COST" --pattern ci-watch --cadence 15m --model claude-sonnet-5 --json 2>/dev/null)"
expect_has "cost json schema" "claude-mods.loop-ops.estimate/v1" "$out"
expect_has "cost json carries runs_per_day" "runs_per_day" "$out"
out="$("$PYTHON" "$COST" --list-models 2>/dev/null)"; rc=$?
expect_exit "list-models -> 0" 0 "$rc"
expect_has  "list-models shows a model" "claude-opus-5" "$out"
# cron cadence parses
"$PYTHON" "$COST" --pattern daily-scan --cadence '*/10 * * * *' --model claude-haiku-4-5 >/dev/null 2>&1
expect_exit "cron cadence -> 0" 0 $?
# --runs-per-day override
out="$("$PYTHON" "$COST" --pattern custom --cadence weird --runs-per-day 5 --model claude-haiku-4-5 2>/dev/null)"; rc=$?
expect_exit "runs-per-day override -> 0" 0 "$rc"
expect_has  "uses the override" "5 runs/day" "$out"
# caching: a fast loop (10m -> 1h TTL) projects a cached saving
out="$("$PYTHON" "$COST" --pattern ci-watch --cadence 10m --model claude-sonnet-5 2>&1)"
expect_has "fast loop shows a cached projection" "cached/" "$out"
# caching: a slow loop (6h > 1h TTL) is not cache-beneficial
out="$("$PYTHON" "$COST" --pattern daily-scan --cadence 6h --model claude-opus-5 2>&1)"
expect_has "slow loop: caching not beneficial" "not beneficial" "$out"
# --no-cache suppresses the cached projection
out="$("$PYTHON" "$COST" --pattern ci-watch --cadence 10m --model claude-sonnet-5 --no-cache 2>&1)"
case "$out" in *"cached/"*) no "--no-cache still showed caching";; *) ok "--no-cache suppresses caching";; esac
# json caching block present for a cacheable loop
out="$("$PYTHON" "$COST" --pattern ci-watch --cadence 5m --model claude-sonnet-5 --json 2>/dev/null)"
expect_has "cost json carries caching block" '"caching"' "$out"

# ── loop-doctor: preflight (offline budget, live binary), json ─────────────
echo "-- loop-doctor --"
bash "$DOCTOR" --help >/dev/null 2>&1; expect_exit "loop-doctor --help -> 0" 0 $?
bash "$DOCTOR" --offline "$SB/l1.yaml" >/dev/null 2>&1; expect_exit "doctor offline healthy L1 -> 0" 0 $?
bash "$DOCTOR" --live "$SB/l1.yaml" >/dev/null 2>&1; expect_exit "doctor live healthy L1 -> 0" 0 $?
# budget too small for the pattern -> bad -> 10
sed 's/^budget_tokens: 300000/budget_tokens: 100/' "$SB/l2.yaml" > "$SB/l2-poor.yaml"
out="$(bash "$DOCTOR" --offline "$SB/l2-poor.yaml" 2>/dev/null)"; rc=$?
expect_exit "doctor budget-too-small -> 10" 10 "$rc"
expect_has  "doctor names the budget gap" "tokens/run" "$out"
# live: a verify gate whose binary is missing -> bad -> 10
sed 's/^verify: "npm test"/verify: "totally-missing-binary-zzz run"/' "$SB/l2.yaml" > "$SB/l2-nobin.yaml"
bash "$DOCTOR" --live "$SB/l2-nobin.yaml" >/dev/null 2>&1; expect_exit "doctor missing gate binary -> 10" 10 $?
# missing config -> 3, json schema
bash "$DOCTOR" --offline "$SB/no-such.yaml" >/dev/null 2>&1; expect_exit "doctor missing config -> 3" 3 $?
out="$(bash "$DOCTOR" --offline --json "$SB/l1.yaml" 2>/dev/null)"
expect_has "doctor json schema" "claude-mods.loop-ops.doctor/v1" "$out"

# ── loop-doctor: host-aware checks (native scheduling) ─────────────────────────
# Each native host has different hard limits, so "will it run" depends on `host:`.
# Facts asserted here are verified against the live tool schemas + docs (2026-08-30)
# and written up in references/native-scheduling.md - if a limit changes upstream,
# these are the assertions that should fail first.
echo "-- loop-doctor (host-aware) --"

# A config with NO host: must behave exactly as before (host defaults to local).
grep -v '^host:' "$SB/l1.yaml" > "$SB/l1-nohost.yaml" 2>/dev/null || cp "$SB/l1.yaml" "$SB/l1-nohost.yaml"
bash "$DOCTOR" --offline "$SB/l1-nohost.yaml" >/dev/null 2>&1; expect_exit "no host: still healthy (defaults local) -> 0" 0 $?

# cloud-routine: minimum interval is 1 hour; faster expressions are rejected at creation.
sed 's|^kill_switch:.*|kill_switch: "pause the routine (Repeats toggle)"|' "$SB/l1.yaml" > "$SB/cloud.yaml"
cat >> "$SB/cloud.yaml" <<'EOF'
host: cloud-routine
EOF
sed -i 's|^cadence: 10m|cadence: 10m|' "$SB/cloud.yaml"
out="$(bash "$DOCTOR" --offline "$SB/cloud.yaml" 2>/dev/null)"; rc=$?
expect_exit "cloud-routine sub-hour cadence -> 10" 10 "$rc"
expect_has  "names the 1-hour floor" "1 hour" "$out"

# cloud-routine has NO permission mode, so the boundary must be named instead
# (repos + environment network policy + connectors). Absent -> a finding.
sed 's|^cadence: 10m|cadence: 1h|' "$SB/cloud.yaml" > "$SB/cloud-1h.yaml"
out="$(bash "$DOCTOR" --offline "$SB/cloud-1h.yaml" 2>/dev/null)"; rc=$?
expect_exit "cloud-routine without a named boundary -> 10" 10 "$rc"
expect_has  "names the missing boundary" "boundary" "$out"

# With the boundary named it passes, and permission_mode is reported as ignored, not required.
sed 's|^escalation:.*|escalation: "connectors pruned to GitHub read; environment network Trusted; never merge"|' \
  "$SB/cloud-1h.yaml" > "$SB/cloud-ok.yaml"
bash "$DOCTOR" --offline "$SB/cloud-ok.yaml" >/dev/null 2>&1; expect_exit "cloud-routine with boundary -> 0" 0 $?
out="$(bash "$DOCTOR" --offline "$SB/cloud-ok.yaml" 2>/dev/null)"
expect_has "permission_mode reported as ignored on cloud" "ignored by cloud routines" "$out"

# --live must be SKIPPED (not passed) for a cloud routine: the tick runs on a fresh
# cloud clone, so this machine's PATH proves nothing. A missing gate binary here must
# NOT fail, and must not be silently reported as ok either.
sed 's|^escalation:|verify: "totally-missing-binary-zzz run"\nescalation:|' "$SB/cloud-ok.yaml" > "$SB/cloud-live.yaml"
out="$(bash "$DOCTOR" --live "$SB/cloud-live.yaml" 2>/dev/null)"; rc=$?
expect_exit "cloud-routine --live does not fail on local PATH -> 0" 0 "$rc"
expect_has  "cloud-routine --live is explicitly skipped" "skipped" "$out"

# session-cron (/loop + CronCreate) is session-scoped with a 7-day expiry: L1 only.
sed 's|^host: cloud-routine|host: session-cron|' "$SB/cloud-ok.yaml" > "$SB/sess-l1.yaml"
bash "$DOCTOR" --offline "$SB/sess-l1.yaml" >/dev/null 2>&1; expect_exit "session-cron at L1 -> 0 (warns only)" 0 $?
out="$(bash "$DOCTOR" --offline "$SB/sess-l1.yaml" 2>/dev/null)"
expect_has "session-cron L1 warns about the 7-day expiry" "7-day expiry" "$out"
# same host at L2 = unattended, which it cannot do
{ sed 's|^tier: L1|tier: L2|' "$SB/sess-l1.yaml"; printf 'verify: "true"\nguard: "true"\nworktree: true\nland_via: fleet-ops\n'; } > "$SB/sess-l2.yaml"
out="$(bash "$DOCTOR" --offline "$SB/sess-l2.yaml" 2>/dev/null)"; rc=$?
expect_exit "session-cron at L2 (unattended) -> 10" 10 "$rc"
expect_has  "names the unattended mismatch" "can't run unattended" "$out"

# An unknown host is a finding, not a silent pass.
sed 's|^host: session-cron|host: made-up|' "$SB/sess-l1.yaml" > "$SB/host-bad.yaml"
bash "$DOCTOR" --offline "$SB/host-bad.yaml" >/dev/null 2>&1; expect_exit "unknown host -> 10" 10 $?

# ── loop-doctor: regressions found by adversarial review ───────────────────
# Each of these shipped broken once. They are cheap to re-break and silent when broken.
echo "-- loop-doctor (adversarial regressions) --"

# R1. A cron-string cadence must still hit the cloud floor - the Nm/Nh/Nd path is not
# the only way to express "every 10 minutes".
sed 's|^cadence: 1h|cadence: "*/10 * * * *"|' "$SB/cloud-ok.yaml" > "$SB/cloud-cron.yaml"
out="$(bash "$DOCTOR" --offline "$SB/cloud-cron.yaml" 2>/dev/null)"; rc=$?
expect_exit "cron-string cadence hits the cloud floor -> 10" 10 "$rc"
# ...and an hourly cron must NOT be flagged (1h is legal on cloud).
sed 's|^cadence: 1h|cadence: "0 * * * *"|' "$SB/cloud-ok.yaml" > "$SB/cloud-hourly.yaml"
bash "$DOCTOR" --offline "$SB/cloud-hourly.yaml" >/dev/null 2>&1; expect_exit "hourly cron is legal on cloud -> 0" 0 $?

# R2. A malformed cadence must not leak a bash arithmetic error. '1a2m' matches the
# *[0-9]m glob, so without a digits-only guard ${1%m} hands '1a2' to $(( )).
sed 's|^cadence: 1h|cadence: 1a2m|' "$SB/cloud-ok.yaml" > "$SB/cad-junk.yaml"
allout="$(bash "$DOCTOR" --offline "$SB/cad-junk.yaml" 2>&1)"
case "$allout" in
  *"value too great for base"*|*"syntax error"*) no "malformed cadence leaks an arithmetic error" ;;
  *) ok "malformed cadence degrades quietly (no arithmetic leak)" ;;
esac

# R3. L3 on a cloud routine must NOT demand a local container note - the cloud infra IS
# the isolation, and its permission_mode is ignored. A false finding here teaches people
# to write a bogus "container" note to satisfy the tool.
{ sed -e 's|^tier: L1|tier: L3|' -e 's|^permission_mode: dontAsk|permission_mode: bypassPermissions|' "$SB/cloud-ok.yaml"
  printf 'verify: "true"\nguard: "true"\nworktree: true\nland_via: fleet-ops\n'; } > "$SB/cloud-l3.yaml"
out="$(bash "$DOCTOR" --offline "$SB/cloud-l3.yaml" 2>/dev/null)"
case "$out" in
  *"bad"*"isolation"*) no "L3 cloud-routine wrongly demands a container note" ;;
  *) ok "L3 cloud-routine does not demand a local container" ;;
esac
# The same check must still bite for a LOCAL L3 bypass - the fix must not disarm it.
{ sed -e 's|^tier: L1|tier: L3|' -e 's|^host: cloud-routine|host: local|' \
      -e 's|^permission_mode: dontAsk|permission_mode: bypassPermissions|' "$SB/cloud-ok.yaml"
  printf 'verify: "true"\nguard: "true"\nworktree: true\nland_via: fleet-ops\n'; } > "$SB/local-l3.yaml"
out="$(bash "$DOCTOR" --offline "$SB/local-l3.yaml" 2>/dev/null)"
expect_has "local L3 bypass still demands isolation" "isolated VM/container" "$out"

# R4. `worktree: true` on a desktop-task is a declaration, not the switch: the real
# toggle is per-task and OFF by default, so the doctor must say it cannot enforce it.
{ sed -e 's|^host: cloud-routine|host: desktop-task|' -e 's|^tier: L1|tier: L2|' "$SB/cloud-ok.yaml"
  printf 'verify: "true"\nguard: "true"\nworktree: true\nland_via: fleet-ops\n'; } > "$SB/desk-l2.yaml"
out="$(bash "$DOCTOR" --offline "$SB/desk-l2.yaml" 2>/dev/null)"
expect_has "desktop-task flags the out-of-band worktree toggle" "toggle is on" "$out"

# ── loop-estimate: validation errors ───────────────────────────────────────────
"$PYTHON" "$COST" --pattern pr-watch --cadence 10m --model claude-nope >/dev/null 2>&1; expect_exit "unknown model -> 4" 4 $?
"$PYTHON" "$COST" --pattern not-a-pattern --cadence 10m --model claude-haiku-4-5 >/dev/null 2>&1; expect_exit "unknown pattern -> 4" 4 $?
"$PYTHON" "$COST" --pattern pr-watch --cadence "garbage cron" --model claude-haiku-4-5 >/dev/null 2>&1; expect_exit "bad cadence -> 4" 4 $?
"$PYTHON" "$COST" --pricing "$SB/no-pricing.json" --pattern custom --cadence 1h --input-tokens 1 --output-tokens 1 --model x >/dev/null 2>&1; expect_exit "missing pricing file -> 3" 3 $?

# ── check-pricing-sync: offline clean -> 0, drift -> 10, --json ────────────
echo "-- check-pricing-sync --"
"$PYTHON" "$SYNC" --help >/dev/null 2>&1; expect_exit "pricing-sync --help -> 0" 0 $?
"$PYTHON" "$SYNC" --offline >/dev/null 2>&1; expect_exit "pricing-sync offline in sync -> 0" 0 $?
# Tamper a copy: opus input price 5.0 -> 999.0 (sed; argv path is MSYS-converted for python).
sed 's/"input_per_mtok": 5\.0/"input_per_mtok": 999.0/' "$SKILL/assets/model-pricing.json" > "$SB/badprice.json"
"$PYTHON" "$SYNC" --pricing "$SB/badprice.json" >/dev/null 2>&1; expect_exit "pricing-sync drift -> 10" 10 $?
"$PYTHON" "$SYNC" --pricing "$SB/no-such.json" >/dev/null 2>&1; expect_exit "pricing-sync missing file -> 3" 3 $?
out="$("$PYTHON" "$SYNC" --json 2>/dev/null)"
expect_has "pricing-sync json schema" "claude-mods.loop-ops.pricing-sync/v1" "$out"
expect_has "pricing-sync json in_sync" '"in_sync": true' "$out"

# ── Windows-authored configs: CRLF + UTF-8 BOM must parse like clean LF ─────
echo "-- windows-authored configs (CRLF / BOM) --"
good_l1 "$SB/win.yaml"
sed 's/$/\r/' "$SB/win.yaml" > "$SB/win-crlf.yaml"                       # LF -> CRLF
bash "$AUDIT"  "$SB/win-crlf.yaml" >/dev/null 2>&1; expect_exit "CRLF config audits clean -> 0" 0 $?
bash "$DOCTOR" --offline "$SB/win-crlf.yaml" >/dev/null 2>&1; expect_exit "CRLF config doctors clean -> 0" 0 $?
printf '\xEF\xBB\xBF' > "$SB/win-bom.yaml"; cat "$SB/win.yaml" >> "$SB/win-bom.yaml"  # prepend BOM
bash "$AUDIT"  "$SB/win-bom.yaml" >/dev/null 2>&1; expect_exit "BOM config audits clean -> 0" 0 $?
bash "$DOCTOR" --offline "$SB/win-bom.yaml" >/dev/null 2>&1; expect_exit "BOM config doctors clean -> 0" 0 $?

# ── worked example: the shipped example stays gate-clean ───────────────────
echo "-- worked example --"
EX="$SKILL/assets/examples/pr-watch/loop.config.yaml"
[[ -f "$EX" ]] && ok "worked example present" || no "worked example missing"
bash "$AUDIT" "$EX" >/dev/null 2>&1; expect_exit "shipped example audits clean -> 0" 0 $?
bash "$DOCTOR" --offline "$EX" >/dev/null 2>&1; expect_exit "shipped example doctors clean -> 0" 0 $?
[[ -f "$SKILL/assets/examples/pr-watch/loop-run.sh" ]] && ok "example ships loop-run.sh (runner-agnostic)" || no "example missing loop-run.sh"
[[ -f "$SKILL/assets/examples/pr-watch/github-actions.yml" ]] && ok "example ships an optional GH Actions scheduler" || no "example missing GH Actions option"
[[ -f "$SKILL/assets/examples/pr-watch/run.md" ]] && ok "example ships a run prompt" || no "example missing run.md"
# The flagship example is what people copy, so it must model the doctrine it teaches:
# a loop declares where it runs before it is scheduled.
expect_has "example declares a host" "host:" "$(cat "$EX")"

# ── terminal design system ─────────────────────────────────────────────────
echo "-- terminal design system --"
for s in "$INIT" "$AUDIT" "$DOCTOR"; do
  b="$(basename "$s")"
  grep -q '_lib/term.sh' "$s" && ok "$b sources _lib/term.sh" || no "$b does not source _lib/term.sh"
done
grep -q 'class Term' "$COST" && ok "loop-estimate carries inline Term helper" || no "loop-estimate missing inline Term helper"
grep -q 'class Term' "$SYNC" && ok "check-pricing-sync carries inline Term helper" || no "check-pricing-sync missing inline Term helper"
grep -q 'BRAND::loop' "$SKILL/../_lib/term.sh" && ok "term.sh registers the loop brand glyph" || no "term.sh missing loop brand glyph"
# Piped audit findings stay plain (no ANSI in the data stream).
po="$(bash "$AUDIT" "$SB/l2-nogate.yaml" 2>/dev/null)"
case "$po" in *$'\033'*) no "piped audit leaked ANSI into data";; *) ok "piped audit stays plain data";; esac

# ── check-native-facts: the native-scheduling staleness guard ──────────────
# Asserts the guard actually detects drift, not just that it exits 0 today: a
# verifier that can only pass is decoration.
echo "-- check-native-facts --"
NATIVE_CHK="$SCRIPTS/check-native-facts.py"
"$PYTHON" "$NATIVE_CHK" --help >/dev/null 2>&1; expect_exit "native-facts --help -> 0" 0 $?
"$PYTHON" "$NATIVE_CHK" --offline >/dev/null 2>&1; expect_exit "native-facts offline in sync -> 0" 0 $?
"$PYTHON" "$NATIVE_CHK" --offline --live >/dev/null 2>&1; expect_exit "mutually exclusive modes -> 2" 2 $?
"$PYTHON" "$NATIVE_CHK" --offline --skill "$SB/not-a-skill" >/dev/null 2>&1; expect_exit "missing skill dir -> 3" 3 $?
out="$("$PYTHON" "$NATIVE_CHK" --offline --json 2>/dev/null)"
expect_has "native-facts json schema" "claude-mods.loop-ops.native-facts/v1" "$out"
expect_has "native-facts json in_sync" '"in_sync": true' "$out"
# Drift detection: copy the skill, drop a host from the reference -> must be caught.
mkdir -p "$SB/drift"
cp -r "$SKILL/assets" "$SKILL/scripts" "$SKILL/references" "$SB/drift/" 2>/dev/null
"$PYTHON" "$NATIVE_CHK" --offline --skill "$SB/drift" >/dev/null 2>&1
expect_exit "unmodified copy still in sync -> 0" 0 $?
sed 's|`cloud-routine`|`clown-routine`|g' "$SKILL/references/native-scheduling.md" > "$SB/drift/references/native-scheduling.md"
out="$("$PYTHON" "$NATIVE_CHK" --offline --skill "$SB/drift" 2>/dev/null)"; rc=$?
expect_exit "host vocabulary drift -> 10" 10 "$rc"
expect_has  "names the drifted source" "native-scheduling.md" "$out"
# A reference that loses its date stamp is drift too - undated is how a doc rots.
sed 's|\*\*Verified 2026-08-30\*\*|Verified recently|' "$SKILL/references/native-scheduling.md" > "$SB/drift/references/native-scheduling.md"
"$PYTHON" "$NATIVE_CHK" --offline --skill "$SB/drift" >/dev/null 2>&1; expect_exit "missing date stamp -> 10" 10 $?

# ── docs: the native-scheduling reference must exist AND be cited ──────────
# A reference SKILL.md never links is dead weight the router can't find
# (docs/SKILL-CREATION-PROTOCOL.md step 4), so both halves are asserted.
echo "-- native-scheduling reference --"
NATIVE="$SKILL/references/native-scheduling.md"
[[ -f "$NATIVE" ]] && ok "native-scheduling.md present" || no "native-scheduling.md missing"
skillmd="$(cat "$SKILL/SKILL.md")"
expect_has "SKILL.md cites native-scheduling.md" "references/native-scheduling.md" "$skillmd"
expect_has "claude-code-loops.md cites native-scheduling.md" "native-scheduling.md" "$(cat "$SKILL/references/claude-code-loops.md")"
# The reference is a claim about a fast-moving external surface, so it must carry the
# date it was verified - an undated table is how a scheduling doc rots invisibly.
expect_has "native-scheduling.md is date-stamped" "Verified 2026-08-30" "$(cat "$NATIVE")"
# Each host named by the config template must be documented in the reference.
for h in session-cron desktop-task cloud-routine; do
  expect_has "reference documents host '$h'" "$h" "$(cat "$NATIVE")"
done
# The gate is an eval; loop-ops links the discipline rather than restating it.
expect_has "SKILL.md routes gate-judgement work to evals-ops" "evals-ops" "$skillmd"
# A skill that repositions itself against a native primitive must say when NOT to use
# itself, or it just re-sells ceremony for work the harness already does.
expect_has "SKILL.md says when the native primitive is enough" "native primitive is enough" "$skillmd"

# FRONTMATTER CONTRACT (stated here because a later description-trim lane edits
# frontmatter without reading this suite - see SKILL-CREATION-PROTOCOL.md step 5):
#   1. `description` must keep the repositioning clause "Native primitives schedule;
#      loop-ops governs" - it is what stops a reader reaching for this skill to build a
#      scheduler the harness already ships. Trimming it changes what the skill IS.
#   2. `description` must keep the native trigger words, or the router never fires on
#      "cron", "scheduled task" or "cloud routine".
#   3. Nothing here requires `when_to_use`; this skill does not use that field.
fm="$(grep -m1 '^description:' "$SKILL/SKILL.md")"
expect_has "description keeps the repositioning clause" "Native primitives schedule; loop-ops governs" "$fm"
expect_has "description keeps the native scheduling triggers" "cloud routine" "$fm"
# Progressive disclosure: the body stays under the 500-line cap (protocol step 3).
sk_lines="$(wc -l < "$SKILL/SKILL.md" | tr -d ' ')"
[[ "$sk_lines" -lt 500 ]] && ok "SKILL.md under the 500-line cap ($sk_lines)" || no "SKILL.md is $sk_lines lines (cap 500)"

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
