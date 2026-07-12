#!/usr/bin/env bash
# Self-test for rembg-ops/scripts/cutout.py.
#
# Offline-deterministic: exercises ONLY the colour-key path + post-processors
# (pure Pillow/numpy), never the rembg ML path — so it needs no ~170 MB model
# download and no network. Synthesises a flat-bg fixture, asserts the documented
# exit codes and that the cut-out is RGBA with a transparent border + opaque
# centre. Skips (exit 0) if Pillow/numpy aren't importable on this platform.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or platform-skip), 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
CUT="$SKILL/scripts/cutout.py"

# Pick a python that actually runs (skip the Windows Store stub).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "SKIP: no working python found" >&2; exit 0; }
if ! "$PYTHON" -c "import PIL, numpy" >/dev/null 2>&1; then
  echo "SKIP: Pillow/numpy not installed — imaging tests skipped" >&2; exit 0
fi

SB="$("$PYTHON" -c 'import tempfile;print(tempfile.mkdtemp())')"
trap '"$PYTHON" -c "import shutil,sys;shutil.rmtree(sys.argv[1],ignore_errors=True)" "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== rembg-ops self-test ==="

# fixture: red square with black outline on a flat candy-yellow background
"$PYTHON" - "$SB" <<'PY'
import sys
from PIL import Image, ImageDraw
sb = sys.argv[1]
im = Image.new("RGB", (256, 256), (255, 219, 51))
d = ImageDraw.Draw(im)
d.rectangle([70, 70, 186, 186], fill=(230, 57, 70), outline=(0, 0, 0), width=6)
im.save(sb + "/fix.png")
PY

# ── CLI contract ────────────────────────────────────────────────────────────
"$PYTHON" "$CUT" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
"$PYTHON" "$CUT" >/dev/null 2>&1;         expect_exit "no args → usage" 2 $?
"$PYTHON" "$CUT" "$SB/nope.png" --out "$SB/o" >/dev/null 2>&1; expect_exit "missing input" 3 $?

hlp="$("$PYTHON" "$CUT" --help 2>/dev/null)"; expect_has "--help lists EXAMPLES" "Examples:" "$hlp"

# ── colour-key happy path (offline) ─────────────────────────────────────────
"$PYTHON" "$CUT" "$SB/fix.png" --method colorkey --out "$SB/o" >/dev/null 2>&1
expect_exit "colorkey exits 0" 0 $?

"$PYTHON" - "$SB/o/fix.png" <<'PY'; expect_exit "cutout is RGBA, transparent border, opaque centre" 0 $?
import sys
import numpy as np
from PIL import Image
im = Image.open(sys.argv[1])
a = np.array(im.convert("RGBA"))[:, :, 3]
ok = im.mode == "RGBA" and a[0, 0] == 0 and a[128, 128] == 255 and 0.12 < (a > 16).mean() < 0.30
sys.exit(0 if ok else 1)
PY

# ── --json envelope ─────────────────────────────────────────────────────────
js="$("$PYTHON" "$CUT" "$SB/fix.png" --method colorkey --out "$SB/o2" --json 2>/dev/null)"
expect_has "--json envelope ok:true" '"ok": true' "$js"
echo "$js" | "$PYTHON" -c "import json,sys;json.load(sys.stdin)" && ok "--json is valid JSON" || no "--json is valid JSON"

# ── post-processors run without error ───────────────────────────────────────
"$PYTHON" "$CUT" "$SB/fix.png" --method colorkey --flatten-alpha 170 --out "$SB/o3" >/dev/null 2>&1
expect_exit "--flatten-alpha runs" 0 $?
"$PYTHON" "$CUT" "$SB/fix.png" --method colorkey --strip-offset-shadow --out "$SB/o4" >/dev/null 2>&1
expect_exit "--strip-offset-shadow runs" 0 $?

echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
