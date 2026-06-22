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

echo "== terraform-ops: action-ref verifier"
run "action-refs --offline well-formed" 0 bash skills/terraform-ops/scripts/check-action-refs.sh --offline
run "action-refs --help"                0 bash skills/terraform-ops/scripts/check-action-refs.sh --help

echo "== claude-code-ops: hooks.json validator"
run "hooks-lint clean on repo hooks.json" 0 "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
run "hooks-lint --help"                   0 "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py --help

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

echo "== fleet-worker: doctor (preflight + staleness) verifier"
run "fleet-doctor --offline consistent" 0 bash skills/fleet-worker/scripts/fleet-doctor.sh --offline
run "fleet-doctor --help"               0 bash skills/fleet-worker/scripts/fleet-doctor.sh --help

echo "== loop-ops: pricing-sync verifier"
run "pricing-sync --offline in sync" 0 "$PY" skills/loop-ops/scripts/check-pricing-sync.py --offline
run "pricing-sync --help"            0 "$PY" skills/loop-ops/scripts/check-pricing-sync.py --help

echo "== protocol: every new verifier is executable + compiles"
for s in skills/claude-api-ops/scripts/check-model-table.py \
         skills/claude-code-ops/scripts/validate-hooks-json.py \
         skills/playwright-ops/scripts/triage-flakes.py \
         skills/mapbox-ops/scripts/check-mapbox-facts.py \
         skills/loop-ops/scripts/check-pricing-sync.py; do
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
purity "hooks-lint"  "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
__tf="$(mktemp)"; printf '{"suites":[]}' > "$__tf"
purity "flake-triage" "$PY" skills/playwright-ops/scripts/triage-flakes.py "$__tf"
rm -f "$__tf"
purity "fleet-doctor"  bash skills/fleet-worker/scripts/fleet-doctor.sh --offline
purity "pricing-sync"  "$PY" skills/loop-ops/scripts/check-pricing-sync.py --offline
grep -q '_lib/term.sh' skills/terraform-ops/scripts/check-action-refs.sh \
    && pass "check-action-refs sources term.sh" || bad "check-action-refs missing term.sh"
grep -q '_lib/term.sh' skills/fleet-worker/scripts/fleet-doctor.sh \
    && pass "fleet-doctor sources term.sh" || bad "fleet-doctor missing term.sh"
for s in skills/claude-api-ops/scripts/check-model-table.py \
         skills/claude-code-ops/scripts/validate-hooks-json.py \
         skills/playwright-ops/scripts/triage-flakes.py \
         skills/loop-ops/scripts/check-pricing-sync.py; do
    grep -q 'class Term' "$s" && pass "$(basename "$s") carries inline Term" \
        || bad "$(basename "$s") missing inline Term"
done

echo
if [ "$fail" -eq 0 ]; then echo "resource checks: clean"; exit 0; fi
echo "resource checks: failures above"; exit 1
