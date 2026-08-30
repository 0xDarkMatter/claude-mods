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
for r in references/icon-sources.md references/inline-delivery.md; do
  [ -f "$SKILL/$r" ] && ok "$r present" || no "$r missing"
  # An uncited resource is dead weight the router never finds (resource protocol §1).
  grep -q "$(basename "$r")" "$SKILL/SKILL.md" && ok "$r cited from SKILL.md" || no "$r not cited from SKILL.md"
done
grep -q 'normalize-icon.py' "$SKILL/SKILL.md" && ok "script cited from SKILL.md" || no "script not cited from SKILL.md"
grep -q 'sprite-template.svg' "$SKILL/SKILL.md" && ok "asset cited from SKILL.md" || no "asset not cited from SKILL.md"

# ── dynamic: needs python; skip cleanly where absent ─────────────────────────
# Probe by EXECUTING python, not with `command -v`: on Windows the python3 name
# resolves to the Microsoft Store app-execution-alias stub, which is present on
# PATH and exits 49 with an install advert instead of running anything. A
# `command -v` probe selects that stub and every downstream assertion then fails
# for the wrong reason. Same trap tests/validate.sh documents.
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A realistically messy vendor export: editor namespaces, metadata, a namedview,
# hardcoded hex in both attribute and style form, and fixed width/height.
cat > "$TMP/dirty.svg" <<'FIXTURE'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="24" height="24" viewBox="0 0 24 24" inkscape:version="1.1">
  <metadata id="m7">junk</metadata>
  <circle cx="11" cy="11" r="7" fill="#1a1a1a" stroke="#ff0000"/>
  <path d="M21 21l-4.3-4.3" style="fill:#000000;stroke:#333;stroke-width:2"/>
</svg>
FIXTURE

out="$("$PY" "$NORM" "$TMP/dirty.svg" 2>/dev/null)"
rc=$?
[ "$rc" = "0" ] && ok "normalizes a vendor SVG (exit 0)" || no "normalize exited $rc"
# The whole point of the skill: no literal colour may survive.
printf '%s' "$out" | grep -qE '#[0-9a-fA-F]{3,6}' && no "literal hex colour survived normalization" \
                                                  || ok "no literal hex colours remain"
printf '%s' "$out" | grep -q 'currentColor'   && ok "paints rebound to currentColor" || no "no currentColor in output"
printf '%s' "$out" | grep -q 'metadata'       && no "metadata element survived"      || ok "metadata dropped"
printf '%s' "$out" | grep -q 'inkscape'       && no "editor namespace survived"      || ok "editor cruft dropped"
printf '%s' "$out" | grep -qE 'width="24"'    && no "fixed width survived"           || ok "fixed width/height stripped"
printf '%s' "$out" | grep -q 'viewBox'        && ok "viewBox preserved"              || no "viewBox lost (breaks scaling)"
printf '%s' "$out" | grep -q 'aria-hidden'    && ok "decorative a11y applied"        || no "no a11y attributes applied"

# --check is the CI gate: 10 on a file that would change, 0 once it would not.
"$PY" "$NORM" --check "$TMP/dirty.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "10" ] && ok "--check on dirty -> exit 10" || no "--check dirty -> exit $rc, expected 10"
printf '%s' "$out" > "$TMP/clean.svg"
"$PY" "$NORM" --check "$TMP/clean.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "--check on normalized -> exit 0 (idempotent)" || no "--check clean -> exit $rc, expected 0"

# Stroke family must force fill=none or the glyph floods solid.
sout="$("$PY" "$NORM" --stroke "$TMP/dirty.svg" 2>/dev/null)"
printf '%s' "$sout" | grep -q 'fill="none"' && ok "--stroke forces fill=none" || no "--stroke did not force fill=none"

# Labelled form emits role=img + <title>; that pair is what names a standalone graphic.
tout="$("$PY" "$NORM" --title 'Search' "$TMP/dirty.svg" 2>/dev/null)"
printf '%s' "$tout" | grep -q '<title>Search</title>' && ok "--title injects <title>" || no "--title did not inject <title>"
printf '%s' "$tout" | grep -q 'role="img"'            && ok "--title sets role=img"   || no "--title did not set role=img"

# Sprite form.
yout="$("$PY" "$NORM" --symbol --id i-x "$TMP/dirty.svg" 2>/dev/null)"
printf '%s' "$yout" | grep -q '<symbol'      && ok "--symbol emits a <symbol>"     || no "--symbol did not emit <symbol>"
printf '%s' "$yout" | grep -q 'id="i-x"'     && ok "--symbol carries the given id" || no "--symbol lost the id"
printf '%s' "$yout" | grep -q 'aria-hidden'  && no "symbol carries a11y attrs (they belong on the consuming <svg>)" \
                                             || ok "symbol leaves a11y to the consumer"

# JSON envelope must match the resource-protocol §4 shape.
jout="$("$PY" "$NORM" --json "$TMP/dirty.svg" 2>/dev/null)"
# Match the value, not "key":"value" — json.dumps puts a space after the colon.
printf '%s' "$jout" | grep -q 'claude-mods.icon-ops.normalize-icon/v1' \
  && ok "JSON envelope declares the schema" || no "JSON envelope schema missing"
printf '%s' "$jout" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert "data" in d and "meta" in d' 2>/dev/null \
  && ok "JSON envelope parses with data+meta" || no "JSON envelope malformed"

echo "-- guard rails --"
"$PY" "$NORM" --symbol "$TMP/dirty.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "--symbol without --id -> exit 2" || no "--symbol without --id -> exit $rc, expected 2"
"$PY" "$NORM" "$TMP/__absent__.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "3" ] && ok "missing file -> exit 3" || no "missing file -> exit $rc, expected 3"
printf '<html><body>no</body></html>' > "$TMP/bad.svg"
"$PY" "$NORM" "$TMP/bad.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "4" ] && ok "non-SVG input -> exit 4" || no "non-SVG -> exit $rc, expected 4"
"$PY" "$NORM" --check "$TMP/dirty.svg" -o "$TMP/x.svg" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "--check with -o -> exit 2" || no "--check with -o -> exit $rc, expected 2"

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
