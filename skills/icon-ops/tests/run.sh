#!/usr/bin/env bash
# Self-test for icon-ops — normalize-icon.py behaviour plus a structural check
# of the shipped sprite asset.
#
# Fully offline and self-contained: fixtures are written to a temp dir, nothing
# is fetched. Needs python3 (or python); skips cleanly with exit 0 where absent,
# like the windows-ops / mac-ops suites gate on their platform.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or skipped), 1 a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
NORM="$SKILL/scripts/normalize-icon.py"
SPRITE="$SKILL/assets/sprite-template.svg"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "=== icon-ops self-test ==="

# ── static: resources exist and are cited ────────────────────────────────────
echo "-- resources --"
[ -f "$NORM" ]   && ok "normalize-icon.py present"   || no "normalize-icon.py missing"
[ -f "$SPRITE" ] && ok "sprite-template.svg present" || no "sprite-template.svg missing"
for r in references/icon-sources.md references/inline-delivery.md \
         references/brand-variants.md references/favicons-and-app-icons.md; do
  [ -f "$SKILL/$r" ] && ok "$r present" || no "$r missing"
  # An uncited resource is dead weight the router never finds (resource protocol §1).
  grep -q "$(basename "$r")" "$SKILL/SKILL.md" && ok "$r cited from SKILL.md" || no "$r not cited from SKILL.md"
done
grep -q 'normalize-icon.py' "$SKILL/SKILL.md" && ok "script cited from SKILL.md" || no "script not cited from SKILL.md"
grep -q 'sprite-template.svg' "$SKILL/SKILL.md" && ok "asset cited from SKILL.md" || no "asset not cited from SKILL.md"

# ── dynamic: needs python; skip cleanly where absent ─────────────────────────
# Probe by EXECUTING python, not with `command -v`: on Windows the python3 name
# resolves to a Microsoft Store app-execution-alias stub that is present on PATH
# and exits 49 with an install advert instead of running anything.
PY=""
for c in python3 python py; do
  if "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "  (python not found — skipping dynamic checks)"
  echo "=== $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

echo "-- normalize-icon --"
"$PY" -m py_compile "$NORM" 2>/dev/null && ok "py_compile clean" || no "py_compile failed"
"$PY" "$NORM" --help >/dev/null 2>&1 && ok "--help exits 0" || no "--help nonzero"
"$PY" "$NORM" --help 2>/dev/null | grep -q 'EXAMPLES' && ok "--help lists EXAMPLES" || no "--help has no EXAMPLES"
"$PY" "$NORM" --help 2>/dev/null | grep -q 'COLOUR MODES' && ok "--help documents colour modes" || no "--help omits colour modes"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A messy but genuinely MONO vendor export: editor namespaces, metadata, one
# colour expressed two ways, fixed width/height.
cat > "$TMP/mono.svg" <<'FIXTURE'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="24" height="24" viewBox="0 0 24 24" inkscape:version="1.1">
  <metadata id="m7">junk</metadata>
  <circle cx="11" cy="11" r="7" fill="#000000"/>
  <path d="M21 21l-4.3-4.3" style="fill:#000000;stroke-width:2"/>
</svg>
FIXTURE

# A three-colour brand mark. Flattening this is the bug the guard exists to stop.
cat > "$TMP/mark.svg" <<'FIXTURE'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M12 2 L22 12 L12 22 Z" fill="#4285F4"/>
  <path d="M2 12 L12 2 L12 22 Z" fill="#EA4335"/>
  <circle cx="12" cy="12" r="3" fill="#FBBC05"/>
</svg>
FIXTURE

# A gradient mark: the id-collision case. Two of these inlined into one page
# both declaring id="a" means the LAST wins document-wide and the first renders
# with the wrong gradient.
cat > "$TMP/grad.svg" <<'FIXTURE'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs><linearGradient id="a"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient></defs>
  <circle cx="12" cy="12" r="10" fill="url(#a)"/>
</svg>
FIXTURE

out="$("$PY" "$NORM" "$TMP/mono.svg" 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] && ok "mono source normalizes (exit 0)" || no "mono normalize exited $rc"
printf '%s' "$out" | grep -qE '#[0-9a-fA-F]{3,6}' && no "literal hex survived on a mono icon" \
                                                  || ok "no literal hex remains"
printf '%s' "$out" | grep -q 'currentColor' && ok "paints rebound to currentColor" || no "no currentColor in output"
printf '%s' "$out" | grep -q 'metadata'     && no "metadata element survived"      || ok "metadata dropped"
printf '%s' "$out" | grep -q 'inkscape'     && no "editor namespace survived"      || ok "editor cruft dropped"
printf '%s' "$out" | grep -qE 'width="24"'  && no "fixed width survived"           || ok "fixed width/height stripped"
printf '%s' "$out" | grep -q 'viewBox'      && ok "viewBox preserved"              || no "viewBox lost (breaks scaling)"
printf '%s' "$out" | grep -q 'aria-hidden'  && ok "decorative a11y applied"        || no "no a11y attributes applied"

echo "-- multi-colour guard --"
# THE regression this guard exists for: a brand mark must never be silently
# flattened to a silhouette. That is lossy AND a trademark modification.
"$PY" "$NORM" "$TMP/mark.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "11" ] && ok "multi-colour mark refused -> exit 11" || no "multi-colour mark -> exit $rc, expected 11"
err="$("$PY" "$NORM" "$TMP/mark.svg" 2>&1 1>/dev/null)"
case "$err" in *--keep-colour*) ok "refusal names the safe option";; *) no "refusal does not name --keep-colour";; esac
# A gradient alone is enough to disqualify the mono default.
"$PY" "$NORM" "$TMP/grad.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "11" ] && ok "gradient source refused -> exit 11" || no "gradient source -> exit $rc, expected 11"
# Achromatic multi-value sources get different wording (mono icon, not a mark).
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#1a1a1a"/><path d="M6 6h12v12H6z" fill="#333333"/></svg>' > "$TMP/greys.svg"
err="$("$PY" "$NORM" "$TMP/greys.svg" 2>&1 1>/dev/null)"
case "$err" in *achromatic*) ok "all-grey source gets mono-icon wording";; *) no "all-grey source misreported as a brand mark";; esac

echo "-- colour modes --"
kc="$("$PY" "$NORM" --keep-colour "$TMP/mark.svg" 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] && ok "--keep-colour exits 0" || no "--keep-colour exited $rc"
for c in 4285F4 EA4335 FBBC05; do
  printf '%s' "$kc" | grep -qi "$c" && ok "--keep-colour preserves #$c" || no "--keep-colour lost #$c"
done
printf '%s' "$kc" | grep -q 'currentColor' && no "--keep-colour injected currentColor" || ok "--keep-colour adds no currentColor"

fl="$("$PY" "$NORM" --flatten "$TMP/mark.svg" 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] && ok "--flatten exits 0 (explicit opt-in)" || no "--flatten exited $rc"
printf '%s' "$fl" | grep -q 'currentColor' && ok "--flatten collapses to currentColor" || no "--flatten did not flatten"

# Rec.709 luminance, not an RGB average: #4285F4 -> 0.2126*66+0.7152*133+0.0722*244
# = 127 = #7f7f7f. An average would give #939393, collapsing tonal separation.
gs="$("$PY" "$NORM" --greyscale "$TMP/mark.svg" 2>/dev/null)"
printf '%s' "$gs" | grep -q '#7f7f7f' && ok "--greyscale uses Rec.709 luminance" || no "--greyscale luminance wrong"
printf '%s' "$gs" | grep -qiE '#(4285F4|EA4335|FBBC05)' && no "--greyscale left a source colour" || ok "--greyscale replaced every colour"

ko="$("$PY" "$NORM" --tint '#fff' "$TMP/mark.svg" 2>/dev/null)"
printf '%s' "$ko" | grep -q 'fill="#fff"' && ok "--tint produces a knockout" || no "--tint did not apply the colour"

"$PY" "$NORM" --greyscale --tint '#fff' "$TMP/mark.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "colour modes are mutually exclusive -> exit 2" || no "conflicting modes -> exit $rc, expected 2"
"$PY" "$NORM" --tint '' "$TMP/mark.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "empty --tint -> exit 2" || no "empty --tint -> exit $rc, expected 2"

echo "-- id namespacing --"
# Without this, two inlined gradient marks collide on id="a".
ns="$("$PY" "$NORM" --keep-colour "$TMP/grad.svg" 2>/dev/null)"
printf '%s' "$ns" | grep -q 'id="grad-a"'      && ok "internal id is namespaced"        || no "internal id not namespaced"
printf '%s' "$ns" | grep -q 'url(#grad-a)'     && ok "url(#id) reference rewritten"     || no "url(#id) reference not rewritten"
printf '%s' "$ns" | grep -q 'id="a"'           && no "bare id=\"a\" still present"      || ok "no un-namespaced id remains"
nsx="$("$PY" "$NORM" --keep-colour --no-namespace "$TMP/grad.svg" 2>/dev/null)"
printf '%s' "$nsx" | grep -q 'id="a"' && ok "--no-namespace opts out" || no "--no-namespace did not opt out"
# Determinism matters: a --check in CI must agree with the write that follows it.
a="$("$PY" "$NORM" --keep-colour "$TMP/grad.svg" 2>/dev/null)"
b="$("$PY" "$NORM" --keep-colour "$TMP/grad.svg" 2>/dev/null)"
[ "$a" = "$b" ] && ok "output is deterministic across runs" || no "output is non-deterministic"

echo "-- forms and a11y --"
sout="$("$PY" "$NORM" --stroke "$TMP/mono.svg" 2>/dev/null)"
printf '%s' "$sout" | grep -q 'fill="none"' && ok "--stroke forces fill=none" || no "--stroke did not force fill=none"
tout="$("$PY" "$NORM" --title 'Search' "$TMP/mono.svg" 2>/dev/null)"
printf '%s' "$tout" | grep -q '<title>Search</title>' && ok "--title injects <title>" || no "--title did not inject <title>"
printf '%s' "$tout" | grep -q 'role="img"'            && ok "--title sets role=img"   || no "--title did not set role=img"
yout="$("$PY" "$NORM" --symbol --id i-x "$TMP/mono.svg" 2>/dev/null)"
printf '%s' "$yout" | grep -q '<symbol'     && ok "--symbol emits a <symbol>"     || no "--symbol did not emit <symbol>"
printf '%s' "$yout" | grep -q 'id="i-x"'    && ok "--symbol carries the given id" || no "--symbol lost the id"
printf '%s' "$yout" | grep -q 'aria-hidden' && no "symbol carries a11y attrs (they belong on the consuming <svg>)" \
                                            || ok "symbol leaves a11y to the consumer"

echo "-- envelope and guard rails --"
jout="$("$PY" "$NORM" --json "$TMP/mono.svg" 2>/dev/null)"
printf '%s' "$jout" | grep -q 'claude-mods.icon-ops.normalize-icon/v1' \
  && ok "JSON envelope declares the schema" || no "JSON envelope schema missing"
printf '%s' "$jout" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert "data" in d and "meta" in d' 2>/dev/null \
  && ok "JSON envelope parses with data+meta" || no "JSON envelope malformed"
# A refusal must still be machine-readable under --json.
jerr="$("$PY" "$NORM" --json "$TMP/mark.svg" 2>/dev/null)"
printf '%s' "$jerr" | grep -q 'MULTICOLOUR' && ok "refusal is structured under --json" || no "refusal not structured under --json"

"$PY" "$NORM" --check "$TMP/mono.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "10" ] && ok "--check on dirty -> exit 10" || no "--check dirty -> exit $rc, expected 10"
printf '%s' "$out" > "$TMP/clean.svg"
"$PY" "$NORM" --check "$TMP/clean.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "--check on normalized -> exit 0 (idempotent)" || no "--check clean -> exit $rc, expected 0"

"$PY" "$NORM" --symbol "$TMP/mono.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "--symbol without --id -> exit 2" || no "--symbol without --id -> exit $rc, expected 2"
"$PY" "$NORM" "$TMP/__absent__.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "3" ] && ok "missing file -> exit 3" || no "missing file -> exit $rc, expected 3"
printf '<html><body>no</body></html>' > "$TMP/bad.svg"
"$PY" "$NORM" "$TMP/bad.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "4" ] && ok "non-SVG input -> exit 4" || no "non-SVG -> exit $rc, expected 4"
"$PY" "$NORM" --check "$TMP/mono.svg" -o "$TMP/x.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "--check with -o -> exit 2" || no "--check with -o -> exit $rc, expected 2"

echo "-- sanitisation --"
# An INLINED svg runs script in the host page's origin; an <img src> does not.
# This skill tells people to inline third-party SVGs, which makes the normalizer
# a sanitiser whether it set out to be one or not.
cat > "$TMP/hostile.svg" <<'FIXTURE'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" onload="alert(1)">
  <script>alert(2)</script>
  <a href="javascript:alert(3)"><circle cx="12" cy="12" r="8" fill="#000" onclick="alert(4)"/></a>
</svg>
FIXTURE
hs="$("$PY" "$NORM" "$TMP/hostile.svg" 2>/dev/null)"
printf '%s' "$hs" | grep -qi 'onload'      && no "onload survived"            || ok "onload stripped"
printf '%s' "$hs" | grep -qi 'onclick'     && no "onclick survived"           || ok "onclick stripped"
printf '%s' "$hs" | grep -qi 'javascript:' && no "javascript: href survived"  || ok "javascript: href stripped"
printf '%s' "$hs" | grep -qi '<script'     && no "<script> survived"          || ok "<script> dropped"
printf '%s' "$hs" | grep -qi 'alert'       && no "script payload survived"    || ok "no payload remains"
hj="$("$PY" "$NORM" --json "$TMP/hostile.svg" 2>/dev/null)"
printf '%s' "$hj" | grep -q '"stripped_active": 3' && ok "sanitiser count reported in --json"                                                    || no "stripped_active count wrong or absent"

echo "-- shipped sprite asset --"
# Structural (offline) verification of the template we tell people to copy: it
# must parse, and every <symbol> must keep its OWN viewBox or mixed-grid icons
# crop instead of scaling.
"$PY" - "$SPRITE" <<'CHECK' && ok "sprite template parses and every symbol has a viewBox" || no "sprite template invalid or a symbol lacks viewBox"
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
syms = [e for e in root.iter() if e.tag.rsplit('}', 1)[-1] == 'symbol']
assert syms, 'no <symbol> elements in template'
assert all(s.get('viewBox') for s in syms), 'a symbol is missing viewBox'
assert all(s.get('id') for s in syms), 'a symbol is missing id'
CHECK
grep -q 'currentColor' "$SPRITE" && ok "sprite template defaults to currentColor" || no "sprite template hardcodes colour"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
