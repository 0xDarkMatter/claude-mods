#!/usr/bin/env bash
# Offline resource checks — runs in PR CI, may block.
#
# Exercises the skill verifier/scanner scripts in their OFFLINE/structural mode
# (no network) and asserts basic protocol compliance (SKILL-RESOURCE-PROTOCOL.md):
# every shipped verifier responds to --help with exit 0 and passes its own
# offline self-check against the skill's current content.
#
# The network-dependent --live drift checks run in the scheduled freshness
# workflow, never here — a rate-limit must never block an unrelated PR (§7).
#
# Exit: 0 all checks pass, 1 a check failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Pick a working python (Windows Store python3 stub exits 49 on --version).
PY="python3"
if ! "$PY" --version >/dev/null 2>&1; then PY="python"; fi

fail=0
pass() { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }

run() { # description, expected-exit, command...
    local desc="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" -eq "$want" ]; then pass "$desc (exit $got)"; else bad "$desc (want $want, got $got)"; fi
}

echo "== claude-api-ops: model-table verifier"
run "model-table --offline consistent" 0 "$PY" skills/claude-api-ops/scripts/check-model-table.py --offline
run "model-table --help"               0 "$PY" skills/claude-api-ops/scripts/check-model-table.py --help

echo "== claude-api-ops: context-budget calculator"
# The verdict IS the contract: exit 0 = append wins, exit 10 = compaction
# indicated. Assert both directions - a calculator that can only reach one
# verdict would pass a single-sided check while being useless.
run "context-budget --help"           0 "$PY" skills/claude-api-ops/scripts/context-budget.py --help
run "context-budget short->append"    0 "$PY" skills/claude-api-ops/scripts/context-budget.py --history-tokens 25000 --turns-remaining 5 --base-rate 0.30 -q
run "context-budget deep->compact"   10 "$PY" skills/claude-api-ops/scripts/context-budget.py --history-tokens 120000 --turns-remaining 40 --base-rate 2.00 -q

echo "== terraform-ops: action-ref verifier"
run "action-refs --offline well-formed" 0 bash skills/terraform-ops/scripts/check-action-refs.sh --offline
run "action-refs --help"                0 bash skills/terraform-ops/scripts/check-action-refs.sh --help

echo "== figma-ops: router freshness + pipeline scripts"
# --offline exits 0 both when the router matches the local Figma plugin cache AND
# when no cache exists (CI) — the skip is deliberate; --live runs in freshness.yml.
if command -v node >/dev/null 2>&1; then
  run "figma freshness --offline (fresh or skipped)" 0  node skills/figma-ops/scripts/verify-freshness.mjs --offline
  run "figma freshness --help"                       0  node skills/figma-ops/scripts/verify-freshness.mjs --help
  run "figma plan-layout fixture 1 (loose)"          0  node skills/figma-ops/scripts/plan-layout.mjs --input skills/figma-ops/assets/plus-layout.example.json --mode loose --json
  run "figma plan-layout fixture 2 (loose)"          0  node skills/figma-ops/scripts/plan-layout.mjs --input skills/figma-ops/assets/light-board.example.json --mode loose --json
  run "figma plan-layout bad args"                   2  node skills/figma-ops/scripts/plan-layout.mjs
  run "figma emit-placement --help"                  0  node skills/figma-ops/scripts/emit-placement.mjs --help
  run "figma verify-board --help"                    0  node skills/figma-ops/scripts/verify-board.mjs --help
  run "figma stage-assets --help"                    0  node skills/figma-ops/scripts/stage-assets.mjs --help
else
  pass "figma-ops checks skipped (no node)"
fi

echo "== claude-code-ops: hooks.json validator"
run "hooks-lint clean on repo hooks.json" 0 "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
run "hooks-lint --help"                   0 "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py --help

echo "== evals-ops: judge calibration + golden-set audit"
run "judge-calibration --help"     0 "$PY" skills/evals-ops/scripts/judge-calibration.py --help
run "goldenset-audit --help"       0 "$PY" skills/evals-ops/scripts/goldenset-audit.py --help
run "judge-calibration bad args"   2 "$PY" skills/evals-ops/scripts/judge-calibration.py
run "goldenset-audit bad args"     2 "$PY" skills/evals-ops/scripts/goldenset-audit.py
run "eval-baseline --help"         0 "$PY" skills/evals-ops/scripts/eval-baseline.py --help
run "eval-baseline bad args"       2 "$PY" skills/evals-ops/scripts/eval-baseline.py
# --accept inverts the meaning of exit 10 on purpose; pin it so a refactor
# cannot quietly restore "noise is fine" to the hillclimb keep gate.
run "eval-baseline --accept help" 0 "$PY" skills/evals-ops/scripts/eval-baseline.py --accept --help
# The shipped starter set must survive the skill's own auditor - an asset its
# tools reject is worse than no asset at all.
run "example golden set audits clean" 0 "$PY" skills/evals-ops/scripts/goldenset-audit.py  skills/evals-ops/assets/golden-set.example.jsonl
run "eval-runner template compiles"   0 "$PY" -m py_compile  skills/evals-ops/assets/eval-runner.template.py

echo "== playwright-ops: flake-triage"
run "flake-triage --help" 0 "$PY" skills/playwright-ops/scripts/triage-flakes.py --help

echo "== ffmpeg-ops: command/resource verifier"
run "ffmpeg-ops --offline consistent" 0 bash skills/ffmpeg-ops/scripts/verify-commands.sh --offline
run "ffmpeg-ops --help"               0 bash skills/ffmpeg-ops/scripts/verify-commands.sh --help


echo "== ytdlp-ops: version/staleness verifier"
run "ytdlp-ops --offline consistent" 0 bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --offline
run "ytdlp-ops --help"               0 bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --help

echo "== mapbox-ops: fact/staleness verifier"
run "mapbox-ops --offline consistent" 0 "$PY" skills/mapbox-ops/scripts/check-mapbox-facts.py --offline
run "mapbox-ops --help"               0 "$PY" skills/mapbox-ops/scripts/check-mapbox-facts.py --help

echo "== typescript-ops: fact/staleness verifier"
run "typescript-ops --offline consistent" 0 "$PY" skills/typescript-ops/scripts/check-typescript-facts.py --offline
run "typescript-ops --help"               0 "$PY" skills/typescript-ops/scripts/check-typescript-facts.py --help

echo "== fleet-worker: doctor (preflight + staleness) verifier"
run "fleet-doctor --offline consistent" 0 bash skills/fleet-worker/scripts/fleet-doctor.sh --offline
run "fleet-doctor --help"               0 bash skills/fleet-worker/scripts/fleet-doctor.sh --help

echo "== loop-ops: pricing-sync verifier"
run "pricing-sync --offline in sync" 0 "$PY" skills/loop-ops/scripts/check-pricing-sync.py --offline
run "pricing-sync --help"            0 "$PY" skills/loop-ops/scripts/check-pricing-sync.py --help

echo "== loop-ops: native-scheduling facts verifier"
run "native-facts --offline in sync" 0 "$PY" skills/loop-ops/scripts/check-native-facts.py --offline
run "native-facts --help"            0 "$PY" skills/loop-ops/scripts/check-native-facts.py --help

echo "== loop-ops: worked example is gate-clean (dogfood)"
LOOP_EX="skills/loop-ops/assets/examples/pr-watch/loop.config.yaml"
run "example audits clean"          0 bash skills/loop-ops/scripts/loop-check.sh "$LOOP_EX"
run "example doctors clean (offline)" 0 bash skills/loop-ops/scripts/loop-doctor.sh --offline "$LOOP_EX"

echo "== r-ops: R-stack staleness verifier"
run "r-facts --offline consistent" 0 "$PY" skills/r-ops/scripts/check-r-facts.py --offline
run "r-facts --help"               0 "$PY" skills/r-ops/scripts/check-r-facts.py --help

echo "== threejs-ops: three.js fact/staleness verifier"
run "three-facts --offline consistent" 0 "$PY" skills/threejs-ops/scripts/check-three-facts.py --offline
run "three-facts --help"               0 "$PY" skills/threejs-ops/scripts/check-three-facts.py --help

echo "== isometric-ops: projection-constant/staleness verifier"
run "iso-facts --offline consistent" 0 "$PY" skills/isometric-ops/scripts/check-iso-facts.py --offline
run "iso-facts --help"               0 "$PY" skills/isometric-ops/scripts/check-iso-facts.py --help

echo "== hono-ops: Hono fact/staleness verifier + route-inventory contract"
run "hono-facts --offline consistent" 0 "$PY" skills/hono-ops/scripts/check-hono-facts.py --offline
run "hono-facts --help"               0 "$PY" skills/hono-ops/scripts/check-hono-facts.py --help
run "route-inventory --help"          0 "$PY" skills/hono-ops/scripts/route-inventory.py --help
run "route-inventory fixture scan"    0 "$PY" skills/hono-ops/scripts/route-inventory.py skills/hono-ops/tests/fixtures/sample-app.ts

echo "== nextjs-ops: Next.js fact/staleness verifier + app-router audit contract"
run "nextjs-facts --offline consistent" 0 "$PY" skills/nextjs-ops/scripts/check-nextjs-facts.py --offline
run "nextjs-facts --help"               0 "$PY" skills/nextjs-ops/scripts/check-nextjs-facts.py --help
run "app-router-audit --help"           0 "$PY" skills/nextjs-ops/scripts/audit-app-router.py --help
# The fixture is a deliberate minefield: exit 10 (findings) is the pass condition.
run "app-router-audit fixture scan"    10 "$PY" skills/nextjs-ops/scripts/audit-app-router.py skills/nextjs-ops/tests/fixtures/app-sample
run "app-router-audit clean control"    0 "$PY" skills/nextjs-ops/scripts/audit-app-router.py skills/nextjs-ops/tests/fixtures/app-sample/app/clean/page.tsx

echo "== craftcms-ops: Craft + plugin major-version staleness verifier"
run "craft-facts --offline consistent" 0 "$PY" skills/craftcms-ops/scripts/check-craft-facts.py --offline
run "craft-facts --help"               0 "$PY" skills/craftcms-ops/scripts/check-craft-facts.py --help

echo "== web-perf-ops: Core Web Vitals threshold verifier + report triage contract"
run "web-perf-facts --offline consistent" 0 "$PY" skills/web-perf-ops/scripts/check-web-perf-facts.py --offline
run "web-perf-facts --help"               0 "$PY" skills/web-perf-ops/scripts/check-web-perf-facts.py --help
run "triage-vitals --help"                0 "$PY" skills/web-perf-ops/scripts/triage-vitals.py --help
# The poor PSI fixture is the minefield (exit 10 = findings); the CrUX fixture is the clean control.
run "triage-vitals poor PSI fixture"     10 "$PY" skills/web-perf-ops/scripts/triage-vitals.py skills/web-perf-ops/tests/fixtures/psi-poor.json
run "triage-vitals good CrUX control"     0 "$PY" skills/web-perf-ops/scripts/triage-vitals.py skills/web-perf-ops/tests/fixtures/crux-good.json

echo "== frontend-upgrade-ops: Vite/Vue/craft-vite fact/staleness verifier"
run "frontend-upgrade-facts --offline consistent" 0 "$PY" skills/frontend-upgrade-ops/scripts/check-frontend-upgrade-facts.py --offline
run "frontend-upgrade-facts --help"               0 "$PY" skills/frontend-upgrade-ops/scripts/check-frontend-upgrade-facts.py --help

echo "== ddev-ops: DDEV facts staleness verifier + .ddev/ config auditor contract"
run "ddev-facts --offline consistent" 0 "$PY" skills/ddev-ops/scripts/check-ddev-facts.py --offline
run "ddev-facts --help"               0 "$PY" skills/ddev-ops/scripts/check-ddev-facts.py --help
# Live comparisons exercised offline against recorded sources (no network in PR CI).
run "ddev-facts --live vs fixtures"   0 "$PY" skills/ddev-ops/scripts/check-ddev-facts.py --live --today 2026-10-05 --fixtures skills/ddev-ops/tests/fixtures/live
run "audit-ddev-config --help"        0 "$PY" skills/ddev-ops/scripts/audit-ddev-config.py --help
# The minefield fixture is the landmine set (exit 10 = findings); the clean fixture is the control.
# --ignore local-file-committed: audited in place, the clean fixture's config.local.yaml is
# tracked in THIS repository on purpose, which that check rightly reports.
run "audit-ddev-config minefield"    10 "$PY" skills/ddev-ops/scripts/audit-ddev-config.py skills/ddev-ops/tests/fixtures/minefield
run "audit-ddev-config clean control" 0 "$PY" skills/ddev-ops/scripts/audit-ddev-config.py skills/ddev-ops/tests/fixtures/clean --ignore local-file-committed

echo "== docker-ops: container-tooling facts verifier + Dockerfile/Compose auditor + image-tag checker"
run "docker-facts --offline consistent" 0 "$PY" skills/docker-ops/scripts/check-docker-facts.py --offline
run "docker-facts --help"               0 "$PY" skills/docker-ops/scripts/check-docker-facts.py --help
# Live comparisons exercised offline against recorded sources (no network in PR CI).
run "docker-facts --live vs fixtures"   0 "$PY" skills/docker-ops/scripts/check-docker-facts.py --live --today 2026-10-07 --fixtures skills/docker-ops/tests/fixtures/facts
run "docker-audit --help"               0 "$PY" skills/docker-ops/scripts/docker-audit.py --help
# The bad fixture is the landmine set (exit 10 = findings); the clean fixture is the control.
run "docker-audit bad fixture"         10 "$PY" skills/docker-ops/scripts/docker-audit.py skills/docker-ops/tests/fixtures/bad
run "docker-audit clean control"        0 "$PY" skills/docker-ops/scripts/docker-audit.py skills/docker-ops/tests/fixtures/clean
run "docker-doctor --help"              0 "$PY" skills/docker-ops/scripts/docker-doctor.py --help
run "check-image-tags --help"           0 "$PY" skills/docker-ops/scripts/check-image-tags.py --help
# Offline inventory of the image references both container skills recommend: exit 4 on a malformed one.
run "image refs in docker-ops + kubernetes-ops well formed" 0 "$PY" skills/docker-ops/scripts/check-image-tags.py skills/docker-ops/SKILL.md skills/docker-ops/references skills/docker-ops/assets skills/kubernetes-ops

echo "== repo-doctor: AGENTS.md toolchain + Claude Code memory-docs verifier"
# --offline: the protocol still states every encoded Claude Code fact and the two
# scripts agree on the 200-line and 16,000-character ceilings. --live runs in
# freshness.yml only.
run "memory-docs --offline consistent" 0 "$PY" skills/repo-doctor/scripts/check-memory-docs.py --offline
run "memory-docs --help"               0 "$PY" skills/repo-doctor/scripts/check-memory-docs.py --help
# Other agent tools' loading facts (tool-profiles.json): structure offline; --live in freshness.yml.
run "tool-profiles --offline valid"    0 "$PY" skills/repo-doctor/scripts/check-tool-profiles.py --offline
run "tool-profiles --help"             0 "$PY" skills/repo-doctor/scripts/check-tool-profiles.py --help
run "repo-scan --help"                 0 "$PY" skills/repo-doctor/scripts/repo-scan.py --help
run "repo-scan unknown section"        2 "$PY" skills/repo-doctor/scripts/repo-scan.py --only bogus
run "agents-md --help"                 0 "$PY" skills/repo-doctor/scripts/agents-md.py --help
run "agents-md no subcommand"          2 "$PY" skills/repo-doctor/scripts/agents-md.py

echo "== package-manager-ops: Node/PHP/manager facts verifier + pm-audit contract"
run "pm-facts --offline consistent" 0 "$PY" skills/package-manager-ops/scripts/check-pm-facts.py --offline
run "pm-facts --help"               0 "$PY" skills/package-manager-ops/scripts/check-pm-facts.py --help
run "pm-audit --help"               0 "$PY" skills/package-manager-ops/scripts/pm-audit.py --help
run "pm-audit bad args"             2 "$PY" skills/package-manager-ops/scripts/pm-audit.py
run "pm-rollup --help"              0 "$PY" skills/package-manager-ops/scripts/pm-rollup.py --help
run "pm-rollup bad args"            2 "$PY" skills/package-manager-ops/scripts/pm-rollup.py
run "lock-replay --help"            0 "$PY" skills/package-manager-ops/scripts/lock-replay.py --help
run "lock-replay bad args"          2 "$PY" skills/package-manager-ops/scripts/lock-replay.py
# The fixture matrix lives in the skill's own tests/run.sh: its fixtures carry a .fx
# suffix (so scanners never read them as real manifests) and must be materialised first.
# pm-rollup / lock-replay behaviour (grouped report, conflict replay) lives in tests/tools.sh.

echo "== sandbox-ops: provider facts staleness verifier + deletion confirmer contract"
run "sandbox-facts --offline consistent" 0 "$PY" skills/sandbox-ops/scripts/check-sandbox-facts.py --offline
run "sandbox-facts --help"               0 "$PY" skills/sandbox-ops/scripts/check-sandbox-facts.py --help
# Live comparisons exercised offline against recorded docs pages and `boat help` (no network in PR CI).
run "sandbox-facts --live vs fixtures"   0 "$PY" skills/sandbox-ops/scripts/check-sandbox-facts.py --live --fixtures skills/sandbox-ops/tests/fixtures/live
run "confirm-gone --help"                0 bash skills/sandbox-ops/scripts/confirm-gone.sh --help
run "confirm-gone no id"                 2 bash skills/sandbox-ops/scripts/confirm-gone.sh
# Its verdicts (gone / still listed / unreachable, per provider) run against fake CLIs in the skill's tests/run.sh.

echo "== protocol: every new verifier is executable + compiles"
for s in skills/claude-api-ops/scripts/check-model-table.py \
         skills/claude-api-ops/scripts/context-budget.py \
         skills/claude-code-ops/scripts/validate-hooks-json.py \
         skills/playwright-ops/scripts/triage-flakes.py \
         skills/mapbox-ops/scripts/check-mapbox-facts.py \
         skills/loop-ops/scripts/check-pricing-sync.py \
         skills/loop-ops/scripts/check-native-facts.py \
         skills/r-ops/scripts/check-r-facts.py \
         skills/threejs-ops/scripts/check-three-facts.py \
         skills/isometric-ops/scripts/check-iso-facts.py \
         skills/hono-ops/scripts/check-hono-facts.py \
         skills/hono-ops/scripts/route-inventory.py \
         skills/nextjs-ops/scripts/check-nextjs-facts.py \
         skills/nextjs-ops/scripts/audit-app-router.py \
         skills/craftcms-ops/scripts/check-craft-facts.py \
         skills/web-perf-ops/scripts/check-web-perf-facts.py \
         skills/web-perf-ops/scripts/triage-vitals.py \
         skills/frontend-upgrade-ops/scripts/check-frontend-upgrade-facts.py \
         skills/ddev-ops/scripts/check-ddev-facts.py \
         skills/ddev-ops/scripts/audit-ddev-config.py \
         skills/sandbox-ops/scripts/check-sandbox-facts.py \
         skills/repo-doctor/scripts/check-memory-docs.py \
         skills/repo-doctor/scripts/check-tool-profiles.py \
         skills/repo-doctor/scripts/repo-scan.py \
         skills/repo-doctor/scripts/agents-md.py \
         skills/package-manager-ops/scripts/check-pm-facts.py \
         skills/package-manager-ops/scripts/pm-audit.py          skills/package-manager-ops/scripts/pm-rollup.py          skills/package-manager-ops/scripts/lock-replay.py; do
    "$PY" -m py_compile "$s" 2>/dev/null && pass "py_compile $(basename "$s")" || bad "py_compile $(basename "$s")"
done
bash -n skills/terraform-ops/scripts/check-action-refs.sh 2>/dev/null \
    && pass "bash -n check-action-refs.sh" || bad "bash -n check-action-refs.sh"
bash -n skills/ffmpeg-ops/scripts/verify-commands.sh 2>/dev/null \
    && pass "bash -n verify-commands.sh" || bad "bash -n verify-commands.sh"
bash -n skills/ytdlp-ops/scripts/check-ytdlp-version.sh 2>/dev/null \
    && pass "bash -n check-ytdlp-version.sh" || bad "bash -n check-ytdlp-version.sh"
bash -n skills/fleet-worker/scripts/fleet-doctor.sh 2>/dev/null \
    && pass "bash -n fleet-doctor.sh" || bad "bash -n fleet-doctor.sh"
bash -n skills/sandbox-ops/scripts/confirm-gone.sh 2>/dev/null \
    && pass "bash -n confirm-gone.sh" || bad "bash -n confirm-gone.sh"

echo "== terminal design: verifier framing adopts term.sh and is ASCII-pure"
# Each verifier renders its human framing on stderr; under TERM_ASCII=1 every
# glyph must fall back to its registered ASCII proxy (design principle #3).
purity() { # desc, cmd...
    local desc="$1"; shift
    local errout
    errout="$(TERM_ASCII=1 FORCE_COLOR=1 "$@" 2>&1 1>/dev/null)"
    if printf '%s' "$errout" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
        bad "$desc framing emits non-ASCII under TERM_ASCII=1"
    else pass "$desc framing pure ASCII under TERM_ASCII=1"; fi
}
purity "action-refs" bash skills/terraform-ops/scripts/check-action-refs.sh --offline
purity "model-table" "$PY" skills/claude-api-ops/scripts/check-model-table.py --offline
purity "context-budget" "$PY" skills/claude-api-ops/scripts/context-budget.py --history-tokens 25000 --turns-remaining 5 --base-rate 0.30
purity "hooks-lint"  "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
__tf="$(mktemp)"; printf '{"suites":[]}' > "$__tf"
purity "flake-triage" "$PY" skills/playwright-ops/scripts/triage-flakes.py "$__tf"
rm -f "$__tf"
purity "fleet-doctor"  bash skills/fleet-worker/scripts/fleet-doctor.sh --offline
purity "pricing-sync"  "$PY" skills/loop-ops/scripts/check-pricing-sync.py --offline
purity "native-facts"  "$PY" skills/loop-ops/scripts/check-native-facts.py --offline
purity "r-facts"       "$PY" skills/r-ops/scripts/check-r-facts.py --offline
purity "craft-facts"   "$PY" skills/craftcms-ops/scripts/check-craft-facts.py --offline
purity "frontend-upgrade-facts" "$PY" skills/frontend-upgrade-ops/scripts/check-frontend-upgrade-facts.py --offline
purity "ddev-facts"    "$PY" skills/ddev-ops/scripts/check-ddev-facts.py --offline
purity "ddev-audit"    "$PY" skills/ddev-ops/scripts/audit-ddev-config.py skills/ddev-ops/tests/fixtures/minefield
purity "pm-facts"      "$PY" skills/package-manager-ops/scripts/check-pm-facts.py --offline
purity "sandbox-facts" "$PY" skills/sandbox-ops/scripts/check-sandbox-facts.py --offline
__pr="$(mktemp -d)"
printf '{"packages":[{"name":"a/a","version":"1"}]}' > "$__pr/ours.lock"
printf '{"packages":[{"name":"a/a","version":"2"}]}' > "$__pr/theirs.lock"
purity "pm-rollup"     "$PY" skills/package-manager-ops/scripts/pm-rollup.py "$__pr"
purity "lock-replay"   "$PY" skills/package-manager-ops/scripts/lock-replay.py --ours "$__pr/ours.lock" --theirs "$__pr/theirs.lock"
rm -rf "$__pr"
grep -q '_lib/term.sh' skills/terraform-ops/scripts/check-action-refs.sh \
    && pass "check-action-refs sources term.sh" || bad "check-action-refs missing term.sh"
grep -q '_lib/term.sh' skills/fleet-worker/scripts/fleet-doctor.sh \
    && pass "fleet-doctor sources term.sh" || bad "fleet-doctor missing term.sh"
for s in skills/claude-api-ops/scripts/check-model-table.py \
         skills/claude-api-ops/scripts/context-budget.py \
         skills/claude-code-ops/scripts/validate-hooks-json.py \
         skills/playwright-ops/scripts/triage-flakes.py \
         skills/loop-ops/scripts/check-pricing-sync.py \
         skills/loop-ops/scripts/check-native-facts.py \
         skills/r-ops/scripts/check-r-facts.py; do
    grep -q 'class Term' "$s" && pass "$(basename "$s") carries inline Term" \
        || bad "$(basename "$s") missing inline Term"
done

echo "== terminal design: term.sh itself + its consumers are ASCII-pure"
# term.sh is shared infrastructure — a glyph that skips the ASCII registry leaks
# into every panel in the repo at once. Exercise EVERY public helper (and every
# registry key) under TERM_ASCII=1 and assert the whole emission is 7-bit.
__probe="$(mktemp)"
cat > "$__probe" <<'PROBE'
. skills/_lib/term.sh
TERM_ASCII=1 term_init
for v in TERM_TREE_BRANCH TERM_TREE_LAST TERM_TREE_VERT TERM_PANEL_TL TERM_PANEL_BL \
         TERM_PANEL_HRULE TERM_PANEL_TERM TERM_ICON_PENDING TERM_ICON_READY \
         TERM_ICON_DONE TERM_ICON_FAILED TERM_ICON_WARN TERM_ICON_HINT \
         TERM_GLYPH_BRANCH TERM_GLYPH_ALERT TERM_GLYPH_TIP TERM_ARROW TERM_DOT \
         TERM_ELLIPSIS; do
    printf '%s=%s\n' "$v" "${!v}"
done
printf '%s\n' "${TERM_SPIN_WORKING[@]}" "${TERM_SPIN_HEARTBEAT[@]}"
# Registry keys, plus one miss per registry to cover the not-found branch.
for k in fleet forge psql watch deploy git windows-ops mac-ops github-ops audit \
         supply-chain net-ops adr loop terraform claude play __miss__; do
    term_brand_glyph "$k"; echo
done
for k in healthy pending warning critical alarm busted unknown __miss__; do
    term_health_glyph "$k"; echo; term_health "$k" text; echo
done
for k in user web mobile auth database cache queue storage service api search \
         timer build hook log __miss__; do term_diagram_icon "$k"; echo; done
for k in ok bad gap warn skip na unknown __miss__; do term_mark "$k"; echo; done
for s in RUNNING PENDING READY LANDED DONE OK FAILED ERROR CONFLICT WARN HINT \
         INFO __miss__; do term_state_icon "$s"; echo; term_section "$s" label 1; done
term_truncate "$(printf 'x%.0s' $(seq 40))" 10; echo
term_panel_open fleet name indicator; term_panel_open fleet name
term_panel_close hotkeys healths; term_panel_close
term_panel_vert; term_panel_line body; term_summary_line meta
term_leaf_line "$TERM_TREE_BRANCH" name leaf meta age
term_toast fleet message
term_status_row ok label value; term_status_row warn label
term_alert warning msg; term_alert critical msg
for n in 0 1 2 3; do for h in HEAD CONFLICT EMPTY __miss__; do term_rail "$n" "$h"; echo; done; done
for k in progress score capacity; do
    for f in 0 30 70 100; do term_pip_bar "$k" "$f" 100; echo; done
    term_pip_bar "$k" 3 5; echo
done
term_hotkey R refresh; echo
for f in working heartbeat __miss__; do
    for t in 0 1 2 3 4 5 6 7 8 9; do term_spinner_frame "$f" "$t"; echo; done
done
term_header title meta; term_header title; term_divider 20
term_tree_item icon label meta; term_tree_item icon label
term_tree_connector 1 1; echo; term_tree_connector 1 2; echo
term_tree_indent 1; echo; term_tree_indent 2; echo
term_tree_node prefix conn label meta; term_tree_node prefix conn label
term_table_row a b c d; term_empty nothing; term_color green text; echo
term_strip "$(term_color green text)"; echo; term_vis_width "$(term_color red ab)"; echo
term_pad "$(term_color cyan ab)" 6; echo
PROBE
__probe_out="$(FORCE_COLOR=1 bash "$__probe" 2>&1)"
if printf '%s' "$__probe_out" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
    bad "term.sh emits non-ASCII under TERM_ASCII=1: $(printf '%s' "$__probe_out" \
        | LC_ALL=C grep -o '[^[:print:][:cntrl:]]' | LC_ALL=C sort -u | tr -d '\n' | od -An -c | tr -s ' ')"
else pass "term.sh: every helper + registry key ASCII-pure under TERM_ASCII=1"; fi
rm -f "$__probe"

echo "== terminal design: colour is zero-width in term.sh's layout maths"
# Callers pre-colour fragments (term_hotkey, term_health, term_pip_bar) and hand
# them to term.sh's layout helpers. Measuring them with ${#} or printf %-Ns
# counted every ESC[...m byte as a column: panel footers came out ~18 cells short
# whenever colour was on, and term_truncate cut an escape in half. Invariant:
# rendering with colour, then stripping the SGR codes, gives exactly the plain
# render. TERM_ASCII=1 keeps bytes == cells, so every comparison is exact.
__wprobe="$(mktemp)"
cat > "$__wprobe" <<'PROBE'
. skills/_lib/term.sh
export TERM_ASCII=1
esc=$(printf '\033')
strip() { printf '%s' "$1" | sed "s/${esc}\[[0-9;]*m//g"; }
chk() { if [ "$2" = "$3" ]; then echo "ok|$1"; else echo "FAIL|$1: want $(printf '%q' "$2") got $(printf '%q' "$3")"; fi; }
# Each fixture is a function, so its coloured arguments are built AFTER
# term_init has picked the mode (arguments expand before the callee runs).
footer() { term_panel_close "$(term_hotkey R refresh) $TERM_DOT $(term_hotkey '?' help)" \
                            "$(term_health busted daemon)  $(term_health pending '4 active')"; }
header() { term_panel_open fleet fleet main; }
verdict() { term_status_row bad "NOT READY  $(term_pip_bar score 43 100)" "score 43/100"; }
leaf() { term_leaf_line "$TERM_TREE_BRANCH" lane-a "$(term_rail 2 HEAD)" "M1 ?2" 3m; }
cut() { term_truncate "NOT READY  $(term_pip_bar score 43 100)" 15; }
same_geometry() { # desc fixture
  local c p
  FORCE_COLOR=1 term_init; c=$("$2")
  FORCE_COLOR= NO_COLOR=1 term_init; p=$("$2")
  chk "$1" "$p" "$(strip "$c")"
}
same_geometry "panel footer with coloured hotkeys + healths" footer
same_geometry "status row with a coloured pip-bar label" verdict
same_geometry "leaf row with a coloured rail + meta" leaf
same_geometry "truncation of a coloured label" cut
FORCE_COLOR=1 term_init
chk "footer spans the header's width" "$(strip "$(header)" | wc -c)" "$(strip "$(footer)" | wc -c)"
c=$(cut)
chk "a cut never leaves half an escape" "" "$(strip "$c" | tr -cd '\033')"
case "$c" in *"${esc}[0m.."*) echo "ok|a cut resets colour before the marker";;
  *) echo "FAIL|a cut resets colour before the marker: got $(printf '%q' "$c")";; esac
chk "plain text truncates as before" "abcd.." "$(term_truncate abcdefghijkl 6)"
chk "short text passes through untouched" "$(term_color red ab)" "$(term_truncate "$(term_color red ab)" 6)"
echo END
PROBE
__wout="$(bash "$__wprobe" 2>&1)"; __wrc=$?
__wn="$(printf '%s\n' "$__wout" | grep -c '^ok|')"
# Fail closed: a probe that dies part-way prints fewer rows, so END must be seen.
case "$__wrc|$__wout" in
    0\|*"FAIL|"*|[!0]*) bad "term.sh measures colour as width: $(printf '%s\n' "$__wout" | grep -v '^ok|' | tr '\n' ' ')" ;;
    *$'\nEND') pass "term.sh: colour is zero-width in its layout maths ($__wn checks)" ;;
    *) bad "term.sh width probe ended early: $(printf '%s' "$__wout" | tail -n3 | tr '\n' ' ')" ;;
esac
rm -f "$__wprobe"

echo "== terminal design: wide glyphs take two cells in term.sh's layout maths"
# Width is terminal cells, not characters. term.sh once counted characters, so
# the ⚡ brand (one character, two cells) made `fleet status`'s header 81 cells
# to its footer's 80; and what a character is depends on the bash: MSYS (16-bit
# wchar_t) counts the 🔁 brand as 2 and cut it between the halves of its
# surrogate pair, Linux and macOS count it 1. The oracle is independent of
# term.sh: python's unicodedata, East Asian Width W or F = 2 cells, SGR
# stripped, and invalid UTF-8 means a cut split a character. Each probe line is
# "<cells wanted, or = for the line above's>\t<what>\t<rendered>". The probe
# runs once in a UTF-8 locale and once in C, where bash counts bytes.
__uprobe="$(mktemp)"
cat > "$__uprobe" <<'PROBE'
. skills/_lib/term.sh
unset TERM_ASCII FLEET_ASCII
if [ "$1" = C ]; then LC_ALL=C
else # C.UTF-8 on Linux CI; macOS and MSYS have en_US.UTF-8
    for l in C.UTF-8 en_US.UTF-8; do LC_ALL=$l; s='⚡'; [ "${#s}" -eq 1 ] && break; done 2>/dev/null
fi
FORCE_COLOR=1 term_init; TERM_WIDTH=80
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
row 80 "fleet footer spans TERM_WIDTH" \
    "$(term_panel_close "$(term_hotkey R refresh) $TERM_DOT $(term_hotkey '?' help)" \
                        "$(term_health busted daemon)  $(term_health pending '4 active')")"
row 80 "fleet header and footer span the same cells (bolt brand is 2)" "$(term_panel_open fleet fleet main)"
row 80 "loop header spans the same cells (wide astral brand)" "$(term_panel_open loop loop main)"
row 80 "supply-chain header spans the same cells (narrow astral brand)" \
    "$(term_panel_open supply-chain supply-chain main)"
row "" "" ""   # resets '=' so each pair below is compared on its own
row - "leaf row with an ASCII name" "$(term_leaf_line "$TERM_TREE_BRANCH" lane-a "$(term_rail 2 HEAD)" "M1 ?2" 3m)"
row = "leaf row with a wide-glyph name keeps its columns" \
    "$(term_leaf_line "$TERM_TREE_BRANCH" "⚡bolt-lane" "$(term_rail 2 HEAD)" "M1 ?2" 3m)"
row = "leaf row whose emoji name is cut keeps its columns" \
    "$(term_leaf_line "$TERM_TREE_BRANCH" "🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁🔁" "$(term_rail 2 HEAD)" "M1 ?2" 3m)"
row - "status row with an ASCII label" "$(term_status_row ok "plain label" value)"
row = "status row with wide glyphs in its label keeps its value column" \
    "$(term_status_row ok "⏳ waiting on ✅ checks" value)"
row 5 "a cut beside astral emoji keeps whole glyphs (max 6)" "$(term_truncate "🔁🔁🔁🔁🔁" 6)"
row 6 "a cut through mixed text counts the bolt as 2 cells (max 6)" "$(term_truncate "ab⚡cd⚡ef" 6)"
row 3 "a cut of coloured emoji keeps escapes and glyphs whole (max 4)" \
    "$(term_truncate "$(term_color red "🔁🔁🔁")x🔁" 4)"
echo END
PROBE
__uoracle='import re, sys, unicodedata
sgr = re.compile(rb"\x1b\[[0-9;]*[^0-9;]?")
prev = None
for raw in sys.stdin.buffer.read().split(b"\n"):
    if raw == b"END":
        print("END"); break
    want, what, body = raw.split(b"\t", 2)
    what = what.decode("ascii")
    if not what:
        prev = None; continue
    try:
        text = sgr.sub(b"", body).decode("utf-8")
    except UnicodeDecodeError:
        print("FAIL|%s: split a character (invalid UTF-8)" % what); prev = None; continue
    got = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)
    want = got if want == b"-" else prev if want == b"=" else int(want)
    print("ok|%s" % what if got == want else "FAIL|%s: want %s cells, got %s" % (what, want, got))
    prev = got'
for __loc in UTF-8 C; do
    __wout="$(bash "$__uprobe" "$__loc" 2>/dev/null | "$PY" -c "$__uoracle" 2>&1)"; __wrc=$?
    __wn="$(printf '%s\n' "$__wout" | grep -c '^ok|')"
    # Fail closed: a probe or oracle that dies part-way never prints END.
    case "$__wrc|$__wout" in
        0\|*"FAIL|"*|[!0]*) bad "term.sh mis-measures wide glyphs ($__loc): $(printf '%s\n' "$__wout" | grep -v '^ok|' | tr '\n' ' ')" ;;
        *$'\nEND') pass "term.sh: wide glyphs take two cells, cuts keep glyphs whole ($__loc, $__wn checks)" ;;
        *) bad "term.sh wide-glyph probe ended early ($__loc): $(printf '%s' "$__wout" | tail -n3 | tr '\n' ' ')" ;;
    esac
done
rm -f "$__uprobe"

# The bash and PowerShell twins must draw the same panel geometry, so their
# wide-glyph tables are one list: __TERM_WIDE in term.sh, $Script:TermWide in
# term.ps1. Compare them bound for bound.
__tw_sh="$(sed -n '/^__TERM_WIDE=(/,/^)/p' skills/_lib/term.sh | grep -oE '0x[0-9A-F]+' | tr '\n' ' ')"
__tw_ps="$(sed -n '/^\$Script:TermWide = @(/,/^)/p' skills/_lib/term.ps1 | grep -oE '0x[0-9A-F]+' | tr '\n' ' ')"
__tw_n="$(printf '%s' "$__tw_sh" | wc -w | tr -d ' ')"
if [ "$__tw_n" -gt 0 ] && [ "$__tw_sh" = "$__tw_ps" ]; then
    pass "term.sh and term.ps1 share one wide-glyph table ($__tw_n bounds)"
else bad "term.sh and term.ps1 wide-glyph tables differ (sh: $__tw_n bounds, ps1: $(printf '%s' "$__tw_ps" | wc -w | tr -d ' '))"; fi

# Source-level guard for the consumers. A hardcoded DECORATION glyph in an
# authored string never reaches the registry, so TERM_ASCII=1 can't swap it —
# the exact defect that leaked U+00B7 out of `fleet status`. Scoped to the
# glyphs term.sh already registers a proxy for, so every hit has a named fix:
#   U+00B7 -> $TERM_DOT      U+2192 -> $TERM_ARROW    U+2026 -> term_truncate
#   tree/panel chrome        -> $TERM_TREE_* / $TERM_PANEL_*
#   rail + pip + mark glyphs -> term_rail / term_pip_bar / term_mark
# Prose punctuation (em dash etc.) is deliberately NOT matched — that is a
# separate, wider class and term.sh registers no proxy for it.
#
# Two kinds of line are stripped before matching, because neither reaches a
# terminal: shell comments (so a guard comment naming the character is fine),
# and heredoc bodies (adr-init.sh writes a markdown ADR template to disk, where
# a real arrow is correct and TERM_ASCII has no say).
#
# mac-ops is macOS-only and net-ops is per-platform, so output-level purity
# checks can't reach them on CI — this static check is their only gate.
__glyphs='·|→|…|│|├|└|─|╭|╰|●|◉|⊗|▰|▱|▲|✓|✗|⎇|⬤'
__strip_heredocs='
    /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/ && !inhd {
        line = $0
        sub(/.*<<-?[[:space:]]*/, "", line)
        gsub(/['"'"'"]/, "", line)
        sub(/[^A-Za-z0-9_].*/, "", line)
        if (line != "") { inhd = 1; tag = line; next }
    }
    inhd { t = $0; sub(/^[[:space:]]+/, "", t); if (t == tag) inhd = 0; next }
    { print }
'
__dirty=""
for s in $(grep -rl '_lib/term\.sh\|__MACOPS_TERM_LIB' --include='*.sh' skills/ 2>/dev/null); do
    case "$s" in */tests/*) continue ;; esac
    if sed 's/#.*$//' "$s" | awk "$__strip_heredocs" | grep -qE "$__glyphs"; then
        __dirty="$__dirty $s"
    fi
done
if [ -n "$__dirty" ]; then
    bad "term.sh consumers hardcode registry glyphs (use \$TERM_DOT/\$TERM_ARROW/term_*):$__dirty"
else pass "term.sh consumers route every registry glyph through term.sh"; fi

echo "== installer: skill sync must be wildcard-safe"
# `[` and `]` are PowerShell wildcard metacharacters, so `Copy-Item -Path` on a
# path like `app/shop/[slug]/page.tsx` matches nothing, copies nothing, and
# raises no error - the file is silently absent from the installed skill. Any
# skill shipping a Next.js dynamic-route fixture hits this. Found 2026-08-31,
# when nextjs-ops installed two files short and its own suite passed vacuously.
# This is a grep because CI runs on Linux and cannot execute install.ps1.
__installer="scripts/install.ps1"
if [ -f "$__installer" ]; then
    if grep -qE 'Copy-Item\s+-Path\s+\$(f\.FullName|src)\b' "$__installer"; then
        bad "install.ps1 copies skill files with -Path (glob-expands; drops bracketed paths) - use -LiteralPath"
    else pass "install.ps1 skill copy uses -LiteralPath"; fi
    if grep -qE 'Get-ChildItem\s+-Path\s+\$(src|dest)\b' "$__installer"; then
        bad "install.ps1 enumerates skill files with -Path (glob-expands) - use -LiteralPath"
    else pass "install.ps1 skill enumeration uses -LiteralPath"; fi
    # Same metacharacter trap in -Doctor's enumeration. Worse there: a doctor
    # blind to bracketed paths reports CLEAN while the files it exists to notice
    # are invisible to it. tests/install-guard.sh proves it behaviourally on
    # Windows; this grep is the Linux-CI backstop.
    if grep -qE 'Get-ChildItem\s+-Path\s+\$dir\b|Test-Path\s+\$dir\b' "$__installer"; then
        bad "install.ps1 -Doctor enumerates with -Path (glob-expands) - use -LiteralPath"
    else pass "install.ps1 doctor enumeration uses -LiteralPath"; fi
    # And once more at the TOP-LEVEL install loops, whose roots come straight
    # from $projectRoot (the script's own location) and $claudeDir. A repo or
    # worktree at `.../lane[1]/` glob-expands every one of them to nothing, so
    # the installer prints its full banner and section headers and then installs
    # zero skills, agents, rules, commands, styles and hooks - a silent total
    # no-op, which is the worst failure this script has. `Test-Path $var` is
    # included because the styles/settings/pigeon branches gate on it: a false
    # negative there skips whole sections just as quietly.
    if grep -qE 'Get-ChildItem\s+-Path\s+\$(commandsDir|skillsDir|agentsDir|rulesDir|stylesDir|hooksDir|root)\b|Test-Path\s+\$[A-Za-z_]' "$__installer"; then
        bad "install.ps1 top-level install loops use -Path (glob-expands; a bracketed repo root installs NOTHING) - use -LiteralPath"
    else pass "install.ps1 top-level install loops use -LiteralPath"; fi
    # Relative paths cut from FullName against a root STRING. The provider
    # returns children under its canonical spelling of the root (8.3 short
    # names expanded, `..` collapsed), so `FullName.Substring($root.Length + 1)`
    # shifts silently whenever the caller spelled the root differently - on a
    # GitHub Windows runner, whose %TEMP% is C:\Users\RUNNER~1, every doctor run
    # reported phantom missing+orphan skill files. Get-FilesUnder, which cuts at
    # its own canonical $prefix, is the one sanctioned site. Comments are
    # stripped first because the guard comment quotes the forbidden form.
    if sed 's/#.*$//' "$__installer" | grep -E 'FullName\.Substring\(' | grep -vqE 'Substring\(\$prefix\.Length\)'; then
        bad "install.ps1 cuts a relative path with FullName.Substring against a root string (breaks on 8.3 short paths) - use Get-FilesUnder"
    else pass "install.ps1 relative paths all come from Get-FilesUnder"; fi
else
    pass "install.ps1 absent - installer check skipped"
fi

echo "== portable skills: duplicated python launcher stays identical"
# scripts/run-python.sh is copied into every skill that ships .py scripts on
# purpose: each skill folder must run when copied alone into another plugin, so
# it cannot reach one shared copy. The price is drift; this is the fence.
__rp_ref=""
for f in skills/*/scripts/run-python.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null && pass "bash -n $f" || bad "bash -n $f"
    if [ -z "$__rp_ref" ]; then __rp_ref="$f"; continue; fi
    cmp -s "$__rp_ref" "$f" && pass "$f identical to $__rp_ref" \
        || bad "$f drifted from $__rp_ref - keep every copy byte-identical"
done
[ -n "$__rp_ref" ] || bad "no skills/*/scripts/run-python.sh found (portable python launcher missing)"

echo "== freshness workflow: a verifier that crashes fails the weekly job"
# freshness.yml once mapped only 10 (fail) and 7 (warn) and ended every step in a
# bare `exit 0`, so a verifier that crashed (1), was misused (2) or could not read
# its facts (3/4) passed green every week while checking nothing. The mapping now
# lives in one helper: pin its contract here, and keep every --live step on it.
# FRESHNESS_YML / FRESHNESS_STEP point these checks at another copy (e.g. main's
# old workflow, or a helper with the catch-all removed) to watch them fail.
__fy="${FRESHNESS_YML:-.github/workflows/freshness.yml}"
__fs="${FRESHNESS_STEP:-.github/scripts/freshness-step.sh}"
__ft="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit "$1"\n' > "$__ft/stub.sh"
fstep() { # desc, want-exit, want-annotation (ERE; '' = none), helper args...
    local desc="$1" want="$2" pat="$3" out got ann; shift 3
    out="$(bash "$__fs" "$@" 2>/dev/null)"; got=$?
    ann="$(printf '%s\n' "$out" | grep -E '^::(error|warning)::')"
    if [ "$got" -ne "$want" ]; then bad "$desc (want exit $want, got $got)"
    elif [ -z "$pat" ] && [ -n "$ann" ]; then bad "$desc (want no annotation, got: $ann)"
    elif [ -n "$pat" ] && ! printf '%s\n' "$ann" | grep -qE "$pat"; then
        bad "$desc (annotation '${ann:-<none>}' does not match $pat)"
    else pass "$desc (exit $got)"; fi
}
__fa=(--name stub-ops --drift "stub drifted" --unavailable "stub unreachable")
fstep "verifier exit 0 passes quietly"  0 ''                              "${__fa[@]}" -- bash "$__ft/stub.sh" 0
fstep "verifier exit 7 warns and passes" 0 '^::warning::stub unreachable$' "${__fa[@]}" -- bash "$__ft/stub.sh" 7
fstep "verifier exit 10 fails as drift" 1 '^::error::stub drifted$'       "${__fa[@]}" -- bash "$__ft/stub.sh" 10
for __c in 1 2 3 4 5 6; do
    fstep "verifier exit $__c fails as a crash" 1 "^::error::stub-ops verifier crashed or was misused \\(exit $__c\\)" \
        "${__fa[@]}" -- bash "$__ft/stub.sh" "$__c"
done
fstep "missing verifier command fails" 1 '^::error::stub-ops verifier crashed or was misused \(exit 127\)' \
    "${__fa[@]}" -- "$__ft/no-such-verifier"
fstep "helper call without -- is a usage error"   2 '^::error::freshness-step\.sh:' "${__fa[@]}" bash "$__ft/stub.sh" 0
fstep "helper call without --drift is a usage error" 2 '^::error::freshness-step\.sh:' \
    --name stub-ops --unavailable u -- bash "$__ft/stub.sh" 0
rm -rf "$__ft"
bash -n "$__fs" 2>/dev/null && pass "bash -n freshness-step.sh" || bad "bash -n freshness-step.sh"
# Comment lines are stripped first: the workflow header names `$?` and --live on purpose.
__fy_code="$(grep -vE '^\s*#' "$__fy")"
if printf '%s\n' "$__fy_code" | grep -qE 'set \+e|\$\?'; then
    bad "$__fy reads exit codes itself (set +e / \$?) - hand the verifier to freshness-step.sh"
else pass "$__fy never reads \$? itself"; fi
__fy_stray="$(printf '%s\n' "$__fy_code" | grep -E -- '--live' | grep -vE '^\s*-- ')"
if [ -n "$__fy_stray" ]; then
    bad "$__fy runs a --live verifier outside freshness-step.sh: $(printf '%s\n' "$__fy_stray" | head -1 | sed 's/^ *//')"
else pass "$__fy hands every --live verifier to the helper after --"; fi
__fy_live="$(printf '%s\n' "$__fy_code" | grep -cE -- '--live')"
__fy_help="$(printf '%s\n' "$__fy_code" | grep -cE 'bash \.github/scripts/freshness-step\.sh ')"
if [ "$__fy_live" -gt 0 ] && [ "$__fy_live" -eq "$__fy_help" ]; then
    pass "$__fy: one helper call per live check ($__fy_live)"
else bad "$__fy: $__fy_help helper calls for $__fy_live live checks - want one each"; fi

echo "== freshness workflow: every live verifier is on the weekly schedule"
# A --live mode only catches drift if freshness.yml runs it. Eight skills once
# shipped a §7 verifier the workflow never called, so their drift could not turn
# a run red. A verifier is any skills/*/scripts/ file naming BOTH --offline and
# --live (the §7 split); one naming only --live in a comment is not. It counts as
# scheduled when its path is a whole token on a `-- <cmd> ... --live` line.
# Deliberate exclusions go in __fv_exempt: "<path> <reason>", one per line. An
# entry with no reason, a path not on disk or a path freshness.yml does run fails.
__fv_exempt='
skills/fleet-worker/scripts/fleet-doctor.sh needs a paid worker-endpoint key and spends one real model turn through the claude CLI: a per-machine preflight, not shipped-fact drift
skills/loop-ops/scripts/loop-doctor.sh --live is a runtime preflight of a local loop.config.yaml (claude/git/verify binary on PATH), not a shipped fact
'
# Every whole token on the `-- <cmd>` lines. A step's verifier path must sit on
# that line itself, not on a `\` continuation line below it.
__fy_tokens="$(printf '%s\n' "$__fy_code" | grep -E '^\s*-- ' | tr -s ' \t\\' '\n\n\n')"
__fv_rc=0
__fv_found="$(grep -rlI --exclude-dir=__pycache__ -e '--live' skills/*/scripts 2>/dev/null)" || __fv_rc=$?
[ "$__fv_rc" -le 1 ] || bad "verifier discovery: grep over skills/*/scripts failed (exit $__fv_rc)"
__fv_missing=""; __fv_n=0
for __f in $__fv_found; do   # paths under skills/ carry no spaces (naming-conventions.md)
    grep -q -e '--offline' "$__f" || continue
    __fv_n=$((__fv_n + 1))
    if printf '%s\n' "$__fv_exempt" | awk -v p="$__f" '$1 == p { m = 1 } END { exit !m }'; then continue; fi
    printf '%s\n' "$__fy_tokens" | grep -qxF -- "$__f" || __fv_missing="$__fv_missing $__f"
done
if [ "$__fv_n" -eq 0 ]; then bad "verifier discovery found no --offline/--live verifier under skills/*/scripts"
elif [ -n "$__fv_missing" ]; then
    bad "$__fy never runs --live for:$(printf ' %s' $__fv_missing | sed 's#skills/\([^/ ]*\)/scripts/#\1/#g') - add a freshness-step.sh step, or an __fv_exempt line with the reason"
else pass "$__fy schedules every --offline/--live verifier ($__fv_n found, exemptions included)"; fi
__fv_stale=""
for __f in $(printf '%s\n' "$__fv_exempt" | awk 'NF { print $1 }'); do
    __why="$(printf '%s\n' "$__fv_exempt" | awk -v p="$__f" '$1 == p { $1 = ""; sub(/^ +/, ""); print; exit }')"
    if [ -z "$__why" ]; then __fv_stale="$__fv_stale $__f(no-reason)"
    elif [ ! -f "$__f" ]; then __fv_stale="$__fv_stale $__f(not-on-disk)"
    elif printf '%s\n' "$__fy_tokens" | grep -qxF -- "$__f"; then __fv_stale="$__fv_stale $__f(scheduled-anyway)"
    fi
done
if [ -n "$__fv_stale" ]; then bad "stale __fv_exempt entries:$__fv_stale"
else pass "every __fv_exempt entry names an unscheduled verifier on disk and says why"; fi
# The reverse: a renamed or deleted verifier still named by a step would only
# surface on Monday, as a crash. Catch it in the PR instead.
__fy_gone=""
for __f in $(printf '%s\n' "$__fy_tokens" | grep -E '^skills/[^/]+/scripts/'); do
    [ -f "$__f" ] || __fy_gone="$__fy_gone $__f"
done
if [ -n "$__fy_gone" ]; then bad "$__fy runs verifiers that are not on disk:$__fy_gone"
else pass "$__fy names only verifiers that exist"; fi

echo
if [ "$fail" -eq 0 ]; then echo "resource checks: clean"; exit 0; fi
echo "resource checks: failures above"; exit 1
