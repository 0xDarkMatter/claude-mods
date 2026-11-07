#!/usr/bin/env bash
# Offline self-test for color-ops: script contracts and OKLCH maths regressions.
#
# Usage:   tests/run.sh
# Input:   none (no network); needs node, skips cleanly without it
# Output:  progress on stderr; final PASS/FAIL line
# Exit:    0 all pass (or skipped without node), 1 any failure
#
# Reference colours (not tied to any brand): #14283A is OKLCH 0.269 0.043 247.2 and
# #E0675F is 0.659 0.153 25.9, so the pair sits 138.7 degrees apart on the short arc -
# 1.2 off the golden angle. The values were cross-checked with an independent Python
# implementation of Ottosson's matrices.
#
# Examples:
#   tests/run.sh
#   bash skills/color-ops/tests/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$here/scripts"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not on PATH" >&2
  exit 0
fi

# jget <json> <js expression over d> - prints the value, empty on a parse failure.
jget() { node -e 'let d;try{d=JSON.parse(process.argv[1])}catch(e){process.exit(3)};const v=eval(process.argv[2]);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$1" "$2" 2>/dev/null; }

skill="$here/SKILL.md"

# 1. Contract: every script has --help with EXAMPLES on stdout, exit 0, and is cited.
for s in hue-harmony.js brand-analyse.js series-palette.js palette-check.js; do
  out="$(node "$S/$s" --help 2>/dev/null)"; rc=$?
  check "$s --help exits 0" test "$rc" -eq 0
  check "$s --help lists EXAMPLES" grep -q '^EXAMPLES' <<<"$out"
  hdr="$(head -25 "$S/$s")"
  check "$s header has Examples block" grep -q '^// Examples:' <<<"$hdr"
  check "$s cited from SKILL.md" grep -qF "scripts/$s" "$skill"
  node "$S/$s" '#123456' --bogus >/dev/null 2>&1; rc=$?
  check "$s unknown flag exits 2" test "$rc" -eq 2
done
for s in hue-harmony.js series-palette.js; do
  out="$(node "$S/$s" 'not-a-colour' --json 2>/dev/null)"; rc=$?
  check "$s bad colour exits 4" test "$rc" -eq 4
  check "$s bad colour prints a VALIDATION envelope" test "$(jget "$out" 'd.error.code')" = VALIDATION
done

# 2. harmony-gen.js regression: its sRGB->LMS row once read `* lb` for `* lg`, so
#    #14283A came out at hue 261.2.
out="$(node "$S/harmony-gen.js" '#14283A' complementary --json 2>/dev/null)"
check "harmony-gen reads #14283A at hue 247.2" test "$(jget "$out" 'd.colors[0].oklch')" = 'oklch(0.269 0.0426 247.2)'

# 3. hue-harmony.js
out="$(node "$S/hue-harmony.js" '#14283A' --rule complementary --json 2>/dev/null)"
check "hue-harmony anchor hue is 247.2" test "$(jget "$out" 'd.meta.anchor.oklch.h')" = 247.2
check "hue-harmony complement is +180" test "$(jget "$out" 'd.data[1].oklch.h')" = 67.2
out="$(node "$S/hue-harmony.js" '#E0675F' --rule golden --count 5 --l 0.45 --c 0.11 --json 2>/dev/null)"
check "golden rule holds L at 0.45 for every member" test "$(jget "$out" 'd.data.every(r=>r.oklch.l===0.45)')" = true
check "golden rule steps the hue by 137.5" test "$(jget "$out" 'd.data[2].offset')" = 275
check "gamut fit lowers chroma only and flags it" \
  test "$(jget "$out" 'd.data.filter(r=>r.clipped).every(r=>r.oklch.c<0.11&&r.requested_c===0.11)&&d.meta.clipped>0')" = true
out="$(node "$S/hue-harmony.js" '#E0675F' --rule monochrome --json 2>/dev/null)"
check "monochrome steps lightness by the golden ratio" \
  test "$(jget "$out" 'Math.abs(d.data[1].oklch.l-0.659/1.618)<0.002&&Math.abs(d.data[3].oklch.l-(1-0.341/1.618))<0.002')" = true
node "$S/hue-harmony.js" '#fff' --json --css >/dev/null 2>&1; rc=$?
check "--json and --css together exit 2" test "$rc" -eq 2
err="$(node "$S/hue-harmony.js" '#E0675F' --json 2>&1 >/dev/null)"
check "hue-harmony success writes nothing to stderr" test -z "$err"

# 4. brand-analyse.js
out="$(node "$S/brand-analyse.js" '#14283A' '#E0675F' '#808080' --json 2>/dev/null)"
check "navy/coral pair is 138.7 degrees on the short arc" test "$(jget "$out" 'd.data.pairs[0].hue_arc')" = 138.7
check "navy/coral pair is nearest the golden angle" test "$(jget "$out" 'd.data.pairs[0].nearest.rule')" = golden
check "navy/coral pair matches within tolerance" test "$(jget "$out" 'd.data.pairs[0].match')" = true
check "a grey pair is achromatic and never matches" test "$(jget "$out" 'd.data.pairs[1].achromatic&&!d.data.pairs[1].match')" = true
out="$(node "$S/brand-analyse.js" '#E0675F' '#14283A' --json 2>/dev/null)"
check "the long way round (221.3) still reads as a 138.7 arc" \
  test "$(jget "$out" 'd.data.pairs[0].hue_directed+"/"+d.data.pairs[0].hue_arc')" = '221.3/138.7'
node "$S/brand-analyse.js" '#14283A' >/dev/null 2>&1; rc=$?
check "brand-analyse with one colour exits 2" test "$rc" -eq 2

# 5. series-palette.js
out="$(node "$S/series-palette.js" '#17716F' --json 2>/dev/null)"
check "light pair is L 0.45 / 0.72" test "$(jget "$out" 'd.data.light.pair.map(p=>p.oklch.l).join()')" = '0.45,0.72'
check "dark pair is L 0.8 / 0.62" test "$(jget "$out" 'd.data.dark.pair.map(p=>p.oklch.l).join()')" = '0.8,0.62'
check "pair keeps the anchor hue" test "$(jget "$out" 'd.data.light.pair.every(p=>p.oklch.h===192.6)')" = true
check "categorical defaults to 6 members" test "$(jget "$out" 'd.data.dark.categorical.length')" = 6
css="$(node "$S/series-palette.js" '#17716F' --css 2>/dev/null)"
check "css has a prefers-color-scheme dark block" grep -q '@media (prefers-color-scheme: dark)' <<<"$css"
check "css has a data-theme dark block" grep -qF ':root[data-theme="dark"]' <<<"$css"
svg="$(node "$S/series-palette.js" '#17716F' --svg 2>/dev/null)"
check "svg preview starts with <svg" grep -q '^<svg ' <<<"$svg"
check "svg preview has no script" bash -c '! grep -qi "<script" <<<"$1"' _ "$svg"

# 6. palette-check.js
node "$S/palette-check.js" '#2CA02C' '#D62728' --min-contrast 1 >/dev/null 2>&1; rc=$?
check "red/green fails under deuteranopia (exit 10)" test "$rc" -eq 10
out="$(node "$S/palette-check.js" '#2CA02C' '#D62728' --min-contrast 1 --json 2>/dev/null)"
check "the failure names deutan as the worst vision" test "$(jget "$out" 'd.data.pairs[0].worst_vision')" = deutan
node "$S/palette-check.js" '#1F77B4' '#FF7F0E' --min-contrast 2 >/dev/null 2>&1; rc=$?
check "blue/orange passes (exit 0)" test "$rc" -eq 0
out="$(node "$S/palette-check.js" 'oklch(0.7 0.3 150)' --min-contrast 1 --json 2>/dev/null)"
check "out-of-gamut oklch input fails the gamut check" test "$(jget "$out" 'd.data.failures[0].check')" = gamut
out="$(node "$S/palette-check.js" '#FFFFFF' --json 2>/dev/null)"
check "white on white is 1:1 and fails contrast" test "$(jget "$out" 'd.data.colours[0].contrast')" = 1

echo "color-ops self-test: $pass passed, $fail failed" >&2
[ "$fail" -eq 0 ]
