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
         skills/nextjs-ops/scripts/audit-app-router.py; do
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
purity "context-budget" "$PY" skills/claude-api-ops/scripts/context-budget.py --history-tokens 25000 --turns-remaining 5 --base-rate 0.30
purity "hooks-lint"  "$PY" skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
__tf="$(mktemp)"; printf '{"suites":[]}' > "$__tf"
purity "flake-triage" "$PY" skills/playwright-ops/scripts/triage-flakes.py "$__tf"
rm -f "$__tf"
purity "fleet-doctor"  bash skills/fleet-worker/scripts/fleet-doctor.sh --offline
purity "pricing-sync"  "$PY" skills/loop-ops/scripts/check-pricing-sync.py --offline
purity "native-facts"  "$PY" skills/loop-ops/scripts/check-native-facts.py --offline
purity "r-facts"       "$PY" skills/r-ops/scripts/check-r-facts.py --offline
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
PROBE
__probe_out="$(FORCE_COLOR=1 bash "$__probe" 2>&1)"
if printf '%s' "$__probe_out" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
    bad "term.sh emits non-ASCII under TERM_ASCII=1: $(printf '%s' "$__probe_out" \
        | LC_ALL=C grep -o '[^[:print:][:cntrl:]]' | LC_ALL=C sort -u | tr -d '\n' | od -An -c | tr -s ' ')"
else pass "term.sh: every helper + registry key ASCII-pure under TERM_ASCII=1"; fi
rm -f "$__probe"

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
else
    pass "install.ps1 absent - installer check skipped"
fi

echo
if [ "$fail" -eq 0 ]; then echo "resource checks: clean"; exit 0; fi
echo "resource checks: failures above"; exit 1
