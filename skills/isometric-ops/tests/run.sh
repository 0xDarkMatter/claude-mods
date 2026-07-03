#!/usr/bin/env bash
# Self-test for isometric-ops scripts + iso-studio app.
#
# Offline-deterministic (no network, no live registry calls — check-iso-facts
# is exercised only in --offline mode). Builds throwaway tile fixtures via
# `uv run` + Pillow, asserts documented exit codes and key output of each
# script, greps iso-studio's index.html/server.mjs for the load-bearing
# contract points, then cleans up. Resolves paths relative to itself so it
# works both in the repo and once installed to ~/.claude/skills/isometric-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (including graceful skips), 1 one or more failures
#
# Skips gracefully (with a message, not a failure) when uv or node are
# unavailable on this machine — see the tile-validate/sheet-pack and
# iso-studio sections below.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
STUDIO="$SKILL/assets/iso-studio"

# Pick a python that actually executes — skips the Windows Store `python3`
# stub (an app-execution alias that exits non-zero non-interactively).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== isometric-ops self-test ==="

# ── --help + EXAMPLES for every script ─────────────────────────────────────
echo "-- --help / EXAMPLES contract --"
for s in iso-math tile-validate sheet-pack check-iso-facts; do
  out="$("$PYTHON" "$SCRIPTS/$s.py" --help 2>&1)"; rc=$?
  expect_exit "$s.py --help" 0 "$rc"
  case "$out" in
    *EXAMPLES*|*Examples*) ok "$s.py --help mentions EXAMPLES" ;;
    *) no "$s.py --help missing EXAMPLES section" ;;
  esac
done

# ── iso-math.py: constants ──────────────────────────────────────────────────
echo "-- iso-math.py constants --"
true_out="$("$PYTHON" "$SCRIPTS/iso-math.py" constants --projection true 2>&1)"; rc=$?
expect_exit "constants --projection true" 0 "$rc"
# grep-tolerant of formatting: the script prints decimal fractions (0.8165,
# 0.86603, 0.57735) rather than the brief's percent notation (81.65%,
# 86.602%, 57.735%) -- match on the digit runs common to both forms.
for v in 35.264 8165 86603 57735 1.22474 54.7356 30.0 120.0; do
  expect_has "true-iso constants contain $v" "$v" "$true_out"
done

dim_out="$("$PYTHON" "$SCRIPTS/iso-math.py" constants --projection dimetric21 2>&1)"; rc=$?
expect_exit "constants --projection dimetric21" 0 "$rc"
expect_has "dimetric constants contain 26.565" "26.565" "$dim_out"
expect_has "dimetric constants mention 2:1 tile aspect" "2:1" "$dim_out"

pix_out="$("$PYTHON" "$SCRIPTS/iso-math.py" constants --projection pixel 2>&1)"; rc=$?
expect_exit "constants --projection pixel" 0 "$rc"
expect_has "pixel constants contain 22.6 (obelisk stated)" "22.6" "$pix_out"
expect_has "pixel constants contain 26.565 (geometric arctan)" "26.565" "$pix_out"

json_out="$("$PYTHON" "$SCRIPTS/iso-math.py" constants --projection true --json 2>&1)"; rc=$?
expect_exit "constants --json" 0 "$rc"
expect_has "constants --json parses" '"data"' "$json_out"

# ── iso-math.py: to-screen / to-tile round-trips at 3 distinct points ──────
echo "-- iso-math.py to-screen/to-tile round-trips --"
roundtrip() { # tx ty tile_w tile_h
  local tx="$1" ty="$2" tw="$3" th="$4"
  local sxy sx sy tjson rtx rty
  sxy="$("$PYTHON" "$SCRIPTS/iso-math.py" to-screen "$tx" "$ty" --tile-w "$tw" --tile-h "$th" 2>&1)"
  read -r sx sy <<<"$sxy"
  tjson="$("$PYTHON" "$SCRIPTS/iso-math.py" to-tile "$sx" "$sy" --tile-w "$tw" --tile-h "$th" --json 2>&1)"
  rtx="$("$PYTHON" -c "import json,sys; d=json.loads(sys.argv[1]); print(d['data']['tileRounded']['x'])" "$tjson" 2>/dev/null)"
  rty="$("$PYTHON" -c "import json,sys; d=json.loads(sys.argv[1]); print(d['data']['tileRounded']['y'])" "$tjson" 2>/dev/null)"
  if [[ "$rtx" == "$tx" && "$rty" == "$ty" ]]; then
    ok "round-trip ($tx,$ty) tileW=$tw tileH=$th -> screen($sx,$sy) -> tile($rtx,$rty)"
  else
    no "round-trip ($tx,$ty) tileW=$tw tileH=$th -> got tile($rtx,$rty) via screen($sx,$sy)"
  fi
}
roundtrip 3 5 64 32
roundtrip -4 7 128 64
roundtrip 0 0 32 16

# elevation-aware to-screen (z / --elev-step) sanity: higher z should move screenY up (smaller)
z0="$("$PYTHON" "$SCRIPTS/iso-math.py" to-screen 3 5 0 --tile-w 64 --tile-h 32 --elev-step 16 2>&1)"
z2="$("$PYTHON" "$SCRIPTS/iso-math.py" to-screen 3 5 2 --tile-w 64 --tile-h 32 --elev-step 16 2>&1)"
z0y="$(awk '{print $2}' <<<"$z0")"; z2y="$(awk '{print $2}' <<<"$z2")"
if "$PYTHON" -c "import sys; sys.exit(0 if float('$z2y') < float('$z0y') else 1)" 2>/dev/null; then
  ok "elevation raises screen position (z=2 screenY < z=0 screenY)"
else
  no "elevation did not raise screen position ($z0y vs $z2y)"
fi

# ── iso-math.py: grid-svg emits parseable SVG with expected line count ─────
echo "-- iso-math.py grid-svg --"
svg="$("$PYTHON" "$SCRIPTS/iso-math.py" grid-svg --projection dimetric21 --tile-w 64 --extent 4 2>/dev/null)"
case "$svg" in "<svg"*|*"<svg "*) ok "grid-svg starts with <svg" ;; *) no "grid-svg did not start with <svg" ;; esac
case "$svg" in *"</svg>") ok "grid-svg ends with </svg>" ;; *) no "grid-svg did not end with </svg>" ;; esac
line_count="$(grep -o '<line ' <<<"$svg" | wc -l | tr -d ' ')"
# extent N dimetric grid: N+1 lines per axis direction, two axis directions -> 2*(N+1)
expected=$(( (4 + 1) * 2 ))
if [[ "$line_count" == "$expected" ]]; then
  ok "grid-svg line count == $expected for extent=4"
else
  no "grid-svg line count $line_count != expected $expected"
fi
"$PYTHON" -c "
import sys, xml.etree.ElementTree as ET
try:
    ET.fromstring(sys.stdin.read())
    sys.exit(0)
except Exception as e:
    print(e, file=sys.stderr); sys.exit(1)
" <<<"$svg" >/dev/null 2>&1
expect_exit "grid-svg is well-formed XML" 0 $?

svg_true="$("$PYTHON" "$SCRIPTS/iso-math.py" grid-svg --projection true --tile-w 128 --extent 3 2>/dev/null)"
expect_has "true-iso grid-svg is an <svg>" "<svg" "$svg_true"

# ── iso-math.py: transforms --target recipes ────────────────────────────────
echo "-- iso-math.py transforms --"
css3d="$("$PYTHON" "$SCRIPTS/iso-math.py" transforms --target css-3d 2>&1)"; rc=$?
expect_exit "transforms --target css-3d" 0 "$rc"
expect_has "css-3d contains rotateX(54.7356deg)" "54.7356" "$css3d"
expect_has "css-3d contains rotateZ(-45deg)" "rotateZ(-45deg)" "$css3d"
expect_has "css-3d contains scale3d(1.22474" "1.22474" "$css3d"

illus="$("$PYTHON" "$SCRIPTS/iso-math.py" transforms --target illustrator 2>&1)"; rc=$?
expect_exit "transforms --target illustrator" 0 "$rc"
expect_has "illustrator recipe contains 0.86603 (SSR)" "0.86603" "$illus"
expect_has "illustrator recipe notes the SRC-B 86.062 typo" "86.062" "$illus"
expect_has "illustrator recipe has +30/-30 shear-rotate figures" "30" "$illus"

for tgt in css-top css-left css-right svg-top svg-left svg-right figma; do
  out="$("$PYTHON" "$SCRIPTS/iso-math.py" transforms --target "$tgt" 2>&1)"; rc=$?
  expect_exit "transforms --target $tgt" 0 "$rc"
done

figma_out="$("$PYTHON" "$SCRIPTS/iso-math.py" transforms --target figma --json 2>&1)"; rc=$?
expect_exit "transforms --target figma --json" 0 "$rc"
expect_has "figma recipe json parses" '"data"' "$figma_out"

# ── tile-validate.py: fixtures generated at test time via uv run + Pillow ─
echo "-- tile-validate.py (fixture-driven) --"
if command -v uv >/dev/null 2>&1; then
  cat > "$SB/gen_tiles.py" <<'PYEOF'
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10.0"]
# ///
import sys
from PIL import Image

outdir = sys.argv[1]

# GOOD: correct 2:1 tile (64x32), clean alpha diamond, transparent margin, no
# halo/bleed, feet centered.
w, h = 64, 32
img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
px = img.load()
cx, cy = w / 2, h / 2
for y in range(h):
    for x in range(w):
        nx = abs(x - cx) / (w / 2 - 4)
        ny = abs(y - cy) / (h / 2 - 4)
        if nx + ny <= 1.0:
            px[x, y] = (120, 140, 160, 255)
img.save(outdir + "/good_tile.png")

# BAD: wrong ratio (48x48, not a 64x32 multiple) + alpha-halo fringe + edge bleed.
w2, h2 = 48, 48
img2 = Image.new("RGBA", (w2, h2), (0, 0, 0, 0))
px2 = img2.load()
for y in range(h2):
    for x in range(w2):
        px2[x, y] = (200, 80, 80, 255)  # opaque all the way to the border -> bleed
for y in range(h2):
    for x in range(w2):
        d = ((x - w2 / 2) ** 2 + (y - h2 / 2) ** 2) ** 0.5
        if d > w2 / 2 - 6:
            px2[x, y] = (200, 80, 80, 80)  # semi-transparent ring -> halo
img2.save(outdir + "/bad_tile.png")
PYEOF
  uv run "$SB/gen_tiles.py" "$SB" >/dev/null 2>"$SB/gen.err"
  if [[ -f "$SB/good_tile.png" && -f "$SB/bad_tile.png" ]]; then
    out="$(uv run "$SCRIPTS/tile-validate.py" --tile-w 64 --tile-h 32 "$SB/good_tile.png" 2>&1)"; rc=$?
    expect_exit "good fixture -> 0" 0 "$rc"
    out="$(uv run "$SCRIPTS/tile-validate.py" --tile-w 64 --tile-h 32 "$SB/bad_tile.png" 2>&1)"; rc=$?
    expect_exit "bad fixture -> 10" 10 "$rc"
    expect_has "bad fixture flags dimension" "dimension" "$out"
    expect_has "bad fixture flags halo" "halo" "$out"
    expect_has "bad fixture flags bleed" "bleed" "$out"
    jout="$(uv run "$SCRIPTS/tile-validate.py" --tile-w 64 --tile-h 32 --json "$SB/good_tile.png" "$SB/bad_tile.png" 2>/dev/null)"
    expect_has "tile-validate --json parses" '"data"' "$jout"
  else
    no "tile fixture generation did not produce expected files (see $SB/gen.err)"
  fi
else
  echo "  SKIP  uv not found — tile-validate.py fixture tests skipped"
fi

# ── sheet-pack.py: pack fixtures, assert atlas JSON schema ─────────────────
echo "-- sheet-pack.py (fixture-driven) --"
if command -v uv >/dev/null 2>&1 && [[ -f "$SB/good_tile.png" && -f "$SB/bad_tile.png" ]]; then
  mkdir -p "$SB/packdir"
  cp "$SB/good_tile.png" "$SB/packdir/"
  cp "$SB/bad_tile.png" "$SB/packdir/"
  out="$(uv run "$SCRIPTS/sheet-pack.py" "$SB/packdir" --out "$SB/atlas" --force --json 2>&1)"; rc=$?
  expect_exit "sheet-pack on fixtures -> 0" 0 "$rc"
  if [[ -f "$SB/atlas.json" && -f "$SB/atlas.png" ]]; then
    ok "sheet-pack wrote atlas.png + atlas.json"
    "$PYTHON" - "$SB/atlas.json" <<'PYEOF' >"$SB/atlas_check.out" 2>&1
import json, sys
with open(sys.argv[1]) as f:
    atlas = json.load(f)
assert atlas["meta"]["schema"] == "claude-mods.isometric-ops.sheet-pack/v1", "bad schema"
frames = atlas["frames"]
assert "good_tile" in frames and "bad_tile" in frames, "missing frame names"
for name, fr in frames.items():
    for k in ("frame", "sourceSize"):
        assert k in fr, f"{name} missing {k}"
    for k in ("x", "y", "w", "h"):
        assert k in fr["frame"], f"{name} frame missing {k}"
    for k in ("w", "h"):
        assert k in fr["sourceSize"], f"{name} sourceSize missing {k}"
    assert "sourceW" in fr and "sourceH" in fr, f"{name} missing flat sourceW/sourceH"
print("ok")
PYEOF
    if [[ "$(cat "$SB/atlas_check.out")" == "ok" ]]; then
      ok "atlas.json parses and frame fields (frame.x/y/w/h, sourceSize, sourceW/sourceH) present"
    else
      no "atlas.json schema check failed: $(cat "$SB/atlas_check.out")"
    fi
  else
    no "sheet-pack did not write atlas.png/atlas.json"
  fi
else
  echo "  SKIP  uv (or tile fixtures) not available — sheet-pack.py fixture tests skipped"
fi

# ── check-iso-facts.py ───────────────────────────────────────────────────────
echo "-- check-iso-facts.py --"
"$PYTHON" "$SCRIPTS/check-iso-facts.py" --offline >/dev/null 2>&1
expect_exit "--offline -> 0" 0 $?
jout="$("$PYTHON" "$SCRIPTS/check-iso-facts.py" --offline --json 2>/dev/null)"
expect_has "--offline --json parses" '"data"' "$jout"

# ── iso-studio: node --check + index.html contract greps ──────────────────
echo "-- iso-studio --"
if command -v node >/dev/null 2>&1; then
  if [[ -f "$STUDIO/server.mjs" ]]; then
    node --check "$STUDIO/server.mjs" >/dev/null 2>&1
    expect_exit "node --check server.mjs" 0 $?
  else
    echo "  SKIP  $STUDIO/server.mjs not found"
  fi
else
  echo "  SKIP  node not found — server.mjs syntax check skipped"
fi

if [[ -f "$STUDIO/index.html" ]]; then
  HTML="$STUDIO/index.html"
  grep -q 'SCHEMA_VERSION *= *"1\.0"' "$HTML" && ok "index.html declares SCHEMA_VERSION \"1.0\"" \
    || no "index.html missing SCHEMA_VERSION \"1.0\""
  grep -q 'scene\.version' "$HTML" && ok "index.html checks scene.version on load" \
    || no "index.html does not reference scene.version"
  for mode in full half quarter free; do
    grep -q "$mode" "$HTML" && ok "index.html mentions snap mode '$mode'" \
      || no "index.html missing snap mode '$mode'"
  done
  for kind in box slab ramp cylinder; do
    grep -q "\"$kind\"" "$HTML" && ok "index.html mentions blockout primitive '$kind'" \
      || no "index.html missing blockout primitive '$kind'"
  done
  grep -q 'Manrope' "$HTML" && ok "index.html declares Manrope font stack" \
    || no "index.html missing Manrope font stack"
  grep -qE 'font-family *: *Manrope' "$HTML" && ok "index.html font-family starts with Manrope" \
    || no "index.html font-family does not lead with Manrope"

  # No external network requests. Pragmatic check: strip HTML/JS comments, then
  # look for a scheme-qualified URL that isn't the SVG/XML namespace declaration
  # or the localhost dev-server hint.
  "$PYTHON" - "$HTML" <<'PYEOF' >"$SB/ext_url_check.out" 2>&1
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    src = f.read()
# strip /* */ and // and <!-- --> comments (best-effort, line-based for //)
src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
src = re.sub(r"<!--.*?-->", "", src, flags=re.S)
lines = []
for line in src.splitlines():
    stripped = line.strip()
    if stripped.startswith("//"):
        continue
    lines.append(line)
src = "\n".join(lines)
urls = re.findall(r'https?://[^\s"\'<>]+', src)
# allow the XML/SVG namespace URIs only
allowed_prefixes = (
    "http://www.w3.org/2000/svg",
    "http://www.w3.org/1999/xlink",
)
bad = [u for u in urls if not u.startswith(allowed_prefixes)]
if bad:
    print("UNEXPECTED_URLS:" + ",".join(sorted(set(bad))))
    sys.exit(1)
print("clean")
PYEOF
  if [[ "$(cat "$SB/ext_url_check.out")" == "clean" ]]; then
    ok "index.html has no external network URLs outside XML namespaces"
  else
    no "index.html external URL check: $(cat "$SB/ext_url_check.out")"
  fi
else
  echo "  SKIP  $STUDIO/index.html not found"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
if [[ "$PASS" -eq 0 && "$FAIL" -eq 0 ]]; then
  echo "  SKIP  no assertions ran on this platform"
  exit 0
fi
[[ "$FAIL" -eq 0 ]] || exit 1
