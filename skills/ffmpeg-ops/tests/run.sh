#!/usr/bin/env bash
# Self-test for ffmpeg-ops scripts.
#
# Structural assertions always run (no ffmpeg needed): --help contracts,
# py_compile/bash -n, documented exit codes on bad input, pure-python LUT
# generation, EDL validation + dry-run, offline staleness verifier, asset JSON.
# Media round-trips run ONLY when ffmpeg is on PATH — fixtures are synthesized
# with lavfi (testsrc2/sine), so no binary fixtures live in the repo. Without
# ffmpeg the media section is a LOUD skip, never a silent false-clean.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
S="$SKILL/scripts"

# Pick a python that actually executes (Windows Store python3 stub exits non-zero).
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

echo "=== ffmpeg-ops self-test ==="

# ── structural: every script honors the contract ────────────────────────────
echo "-- contracts --"
for py in probe-media.py loudnorm-scan.py detect-segments.py quality-compare.py \
          cut-from-edl.py gen-luts.py make-chapters.py smart-compress.py \
          make-sprites.py; do
  "$PYTHON" -m py_compile "$S/$py" 2>/dev/null && ok "py_compile $py" || no "py_compile $py"
  "$PYTHON" "$S/$py" --help >/dev/null 2>&1; expect_exit "$py --help" 0 $?
  out="$("$PYTHON" "$S/$py" --help 2>/dev/null)"; expect_has "$py --help has Examples" "xamples" "$out"
done
for sh in capability-scan.sh verify-commands.sh; do
  bash -n "$S/$sh" 2>/dev/null && ok "bash -n $sh" || no "bash -n $sh"
  bash "$S/$sh" --help >/dev/null 2>&1; expect_exit "$sh --help" 0 $?
done
bash "$S/capability-scan.sh" --bogus-flag >/dev/null 2>&1; expect_exit "capability-scan unknown flag -> 2" 2 $?
bash "$S/verify-commands.sh" --bogus >/dev/null 2>&1;      expect_exit "verify-commands unknown flag -> 2" 2 $?

# ── structural: documented failure exits ────────────────────────────────────
echo "-- exit codes --"
"$PYTHON" "$S/probe-media.py" "$SB/nope.mp4" >/dev/null 2>&1
rc=$?; [[ "$rc" == 3 || "$rc" == 5 ]] && ok "probe missing file -> 3 (or 5 sans ffprobe; got $rc)" \
  || no "probe missing file (want 3/5 got $rc)"
"$PYTHON" "$S/cut-from-edl.py" "$SB/nope.json" >/dev/null 2>&1; expect_exit "edl missing -> 3" 3 $?
printf 'not json' > "$SB/bad.json"
"$PYTHON" "$S/cut-from-edl.py" "$SB/bad.json" >/dev/null 2>&1; expect_exit "edl not json -> 4" 4 $?
printf '{"scenes":[]}' > "$SB/empty.json"
"$PYTHON" "$S/cut-from-edl.py" "$SB/empty.json" >/dev/null 2>&1; expect_exit "edl empty scenes -> 4" 4 $?
printf '{"scenes":[{"clips":[{"file":"a.mp4","start":5,"end":2}]}]}' > "$SB/inv.json"
"$PYTHON" "$S/cut-from-edl.py" "$SB/inv.json" >/dev/null 2>&1; expect_exit "edl end<=start -> 4" 4 $?
"$PYTHON" "$S/gen-luts.py" --variants not_a_look >/dev/null 2>&1; expect_exit "gen-luts unknown look -> 2" 2 $?
"$PYTHON" "$S/quality-compare.py" --metrics bogus a b >/dev/null 2>&1; expect_exit "quality bad metric -> 2" 2 $?
"$PYTHON" "$S/make-chapters.py" --from-scenes >/dev/null 2>&1; expect_exit "chapters detection w/o --media -> 2" 2 $?
"$PYTHON" "$S/smart-compress.py" --target not_a_size x.mp4 >/dev/null 2>&1; expect_exit "smart-compress bad size -> 2" 2 $?
"$PYTHON" "$S/make-sprites.py" --interval 0 x.mp4 >/dev/null 2>&1; expect_exit "make-sprites bad interval -> 2" 2 $?
"$PYTHON" "$S/make-chapters.py" --chapters "$SB/nope.json" --duration 60 >/dev/null 2>&1; expect_exit "chapters file missing -> 3" 3 $?
printf 'not json' > "$SB/badch.json"
"$PYTHON" "$S/make-chapters.py" --chapters "$SB/badch.json" --duration 60 >/dev/null 2>&1; expect_exit "chapters bad json -> 4" 4 $?

# ── structural: chapter formatting (no ffmpeg required via --duration) ───────
echo "-- make-chapters formats --"
printf '[{"start":0,"title":"Intro"},{"start":65,"title":"Topic = One"},{"start":130,"title":"Wrap"}]' > "$SB/ch.json"
out="$("$PYTHON" "$S/make-chapters.py" --chapters "$SB/ch.json" --duration 200 2>/dev/null)"; rc=$?
expect_exit "ffmetadata from explicit JSON -> 0" 0 "$rc"
expect_has  "ffmetadata header" ";FFMETADATA1" "$out"
expect_has  "ffmetadata escapes '=' in title" 'Topic \= One' "$out"
out="$("$PYTHON" "$S/make-chapters.py" --chapters "$SB/ch.json" --duration 200 --format youtube 2>/dev/null)"
expect_has  "youtube format starts at 0:00" "0:00 Intro" "$out"
out="$("$PYTHON" "$S/make-chapters.py" --chapters "$SB/ch.json" --duration 200 --format vtt 2>/dev/null)"
expect_has  "vtt format header" "WEBVTT" "$out"

# ── structural: EDL dry-run (no ffmpeg required) ─────────────────────────────
echo "-- cut-from-edl dry-run --"
printf '{"scenes":[{"scene":1,"selection_rationale":"test","clips":[{"file":"takes/a.mp4","start":1.5,"end":4.0}]}]}' > "$SB/edit.json"
out="$("$PYTHON" "$S/cut-from-edl.py" "$SB/edit.json" 2>/dev/null)"; rc=$?
expect_exit "dry-run with absent sources -> 0" 0 "$rc"
expect_has  "dry-run prints ffmpeg commands" "ffmpeg" "$out"
expect_has  "dry-run includes concat step" "concat" "$out"

# ── structural: pure-python LUT generation ───────────────────────────────────
echo "-- gen-luts --"
out="$("$PYTHON" "$S/gen-luts.py" --variants warm_filmic --size 17 --out-dir "$SB/luts" 2>/dev/null)"; rc=$?
expect_exit "gen-luts size 17 -> 0" 0 "$rc"
[[ -f "$SB/luts/warm_filmic.cube" ]] && ok "cube file written" || no "cube file written"
# Captured, not `head | grep -q`: under `set -o pipefail` grep -q's early exit
# SIGPIPEs the producer (141) and flakes the assert even on a match.
cube_hdr="$(head -5 "$SB/luts/warm_filmic.cube")"
expect_has "cube header size" "LUT_3D_SIZE 17" "$cube_hdr"
rows="$(grep -cE '^[0-9]' "$SB/luts/warm_filmic.cube")"
[[ "$rows" == "4913" ]] && ok "cube row count 17^3" || no "cube row count (want 4913 got $rows)"
out="$("$PYTHON" "$S/gen-luts.py" --variants neutral709 --size 17 --out-dir "$SB/luts" --json 2>/dev/null)"
expect_has "gen-luts --json envelope" '"schema": "claude-mods.ffmpeg-ops.luts/v1"' "$out"
"$PYTHON" "$S/gen-luts.py" --variants noir_bw,pastel,golden_hour,sepia,technicolor2,matrix_green --size 17 --out-dir "$SB/luts" >/dev/null 2>&1
expect_exit "gen-luts look-recipe variants -> 0" 0 $?
# noir_bw is sat=0: every lattice row must be greyscale (R==G==B)
nongrey="$(grep -E '^[0-9]' "$SB/luts/noir_bw.cube" | awk '{if ($1!=$2 || $2!=$3) c++} END{print c+0}')"
[[ "$nongrey" == "0" ]] && ok "noir_bw LUT is true greyscale" || no "noir_bw LUT greyscale ($nongrey colored rows)"
# sepia channel-mix: mid-grey input (grid 8,8,8 of 17^3 = data row 2457) maps warm (R>G>B)
grep -E '^[0-9]' "$SB/luts/sepia.cube" | awk 'NR==2457{ok=($1>$2 && $2>$3)} END{exit !ok}' \
  && ok "sepia LUT maps mid-grey warm (R>G>B)" || no "sepia LUT mid-grey warmth"
# duotone gradient map: cyanotype black input -> shadow color (B dominant), white -> highlight (near-white)
"$PYTHON" "$S/gen-luts.py" --variants duo_cyanotype,duo_synthwave --size 17 --out-dir "$SB/luts" >/dev/null 2>&1
expect_exit "gen-luts duotone variants -> 0" 0 $?
grep -E '^[0-9]' "$SB/luts/duo_cyanotype.cube" | awk 'NR==1{ok=($3>$1)} END{exit !ok}' \
  && ok "cyanotype LUT black -> blue shadow" || no "cyanotype LUT black -> blue shadow"
grep -E '^[0-9]' "$SB/luts/duo_cyanotype.cube" | awk 'NR==4913{ok=($1>0.85 && $2>0.9 && $3>0.95)} END{exit !ok}' \
  && ok "cyanotype LUT white -> paper highlight" || no "cyanotype LUT white -> paper highlight"
# tritone split: cool shadows (B>R at black) AND warm highlights (R>B at white)
"$PYTHON" "$S/gen-luts.py" --variants tri_split_classic --size 17 --out-dir "$SB/luts" >/dev/null 2>&1
expect_exit "gen-luts tritone variant -> 0" 0 $?
grep -E '^[0-9]' "$SB/luts/tri_split_classic.cube" | awk 'NR==1{ok=($3>$1)} END{exit !ok}' \
  && ok "tritone split: cool shadows" || no "tritone split: cool shadows"
grep -E '^[0-9]' "$SB/luts/tri_split_classic.cube" | awk 'NR==4913{ok=($1>$3)} END{exit !ok}' \
  && ok "tritone split: warm highlights" || no "tritone split: warm highlights"

# ── structural: offline staleness verifier + assets ─────────────────────────
echo "-- verify-commands --offline / assets --"
bash "$S/verify-commands.sh" --offline >/dev/null 2>&1; expect_exit "verifier --offline clean" 0 $?
for a in "$SKILL"/assets/*.json; do
  "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$a" \
    >/dev/null 2>&1 && ok "asset parses: $(basename "$a")" || no "asset parses: $(basename "$a")"
done

# ── media round-trips (only with ffmpeg on PATH) ─────────────────────────────
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo ""
  echo "  SKIP  ffmpeg/ffprobe not on PATH — media round-trip tests NOT run."
  echo "        (structural suite above still gates; install ffmpeg for full coverage)"
else
  echo "-- media round-trips (lavfi fixtures) --"
  FIX="$SB/fixture.mp4"
  ffmpeg -v error -y -f lavfi -i testsrc2=duration=2:size=320x180:rate=30 \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$FIX" 2>/dev/null
  [[ -f "$FIX" ]] && ok "fixture synthesized" || no "fixture synthesized"

  out="$("$PYTHON" "$S/probe-media.py" "$FIX" 2>/dev/null)"; rc=$?
  expect_exit "probe fixture -> 0" 0 "$rc"
  expect_has  "probe reports video" "h264 320x180" "$out"
  out="$("$PYTHON" "$S/probe-media.py" --json "$FIX" 2>/dev/null)"
  expect_has  "probe --json envelope" '"schema": "claude-mods.ffmpeg-ops.probe/v1"' "$out"
  "$PYTHON" "$S/probe-media.py" --keyframes-near 1.0 "$FIX" >/dev/null 2>&1
  expect_exit "probe --keyframes-near -> 0" 0 $?
  printf 'plain text' > "$SB/not-media.mp4"
  "$PYTHON" "$S/probe-media.py" "$SB/not-media.mp4" >/dev/null 2>&1
  expect_exit "probe non-media -> 4" 4 $?

  # tone (1s) + silence (1s): silence and speech segments both detectable
  WAV="$SB/tone-silence.wav"
  ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=1" \
    -af "apad=pad_dur=1" -c:a pcm_s16le "$WAV" 2>/dev/null
  out="$("$PYTHON" "$S/detect-segments.py" --silence --min-silence 0.4 "$WAV" 2>/dev/null)"; rc=$?
  expect_exit "detect-segments --silence -> 0" 0 "$rc"
  expect_has  "finds the silence" "silence" "$out"
  expect_has  "derives speech segment" "speech" "$out"
  "$PYTHON" "$S/detect-segments.py" --scenes "$FIX" >/dev/null 2>&1
  expect_exit "detect-segments --scenes -> 0" 0 $?

  out="$("$PYTHON" "$S/loudnorm-scan.py" "$FIX" --json 2>/dev/null)"; rc=$?
  expect_exit "loudnorm-scan -> 0" 0 "$rc"
  expect_has  "emits pass-2 filter" "measured_I" "$out"

  "$PYTHON" "$S/quality-compare.py" "$FIX" "$FIX" --metrics ssim >/dev/null 2>&1
  expect_exit "quality self-compare -> 0" 0 $?
  out="$("$PYTHON" "$S/quality-compare.py" "$FIX" "$FIX" --metrics ssim --json 2>/dev/null)"
  expect_has "ssim of identical ~1" '"all": 1' "$out"
  # Captured, not `-filters | grep -q`: under pipefail a SIGPIPE'd ffmpeg (141)
  # would silently take the no-vmaf branch even when libvmaf is present.
  filter_list="$(ffmpeg -hide_banner -filters 2>/dev/null)"
  if grep -q libvmaf <<<"$filter_list"; then
    "$PYTHON" "$S/quality-compare.py" "$FIX" "$FIX" --metrics vmaf --min-vmaf 95 >/dev/null 2>&1
    expect_exit "vmaf self-compare above threshold -> 0" 0 $?
  else
    echo "  SKIP  vmaf (libvmaf not in this build)"
  fi

  printf '{"scenes":[{"scene":1,"clips":[{"file":"%s","start":0.2,"end":1.0},{"file":"%s","start":1.2,"end":1.8}]}]}' \
    "$(basename "$FIX")" "$(basename "$FIX")" > "$SB/cutme.json"
  "$PYTHON" "$S/cut-from-edl.py" "$SB/cutme.json" --execute -o "$SB/final.mp4" >/dev/null 2>&1
  rc=$?
  expect_exit "cut-from-edl --execute -> 0" 0 "$rc"
  [[ -f "$SB/final.mp4" ]] && ok "EDL final output exists" || no "EDL final output exists"
  dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$SB/final.mp4" 2>/dev/null)"
  "$PYTHON" -c "import sys; d=float(sys.argv[1]); sys.exit(0 if 1.0 < d < 1.9 else 1)" "${dur:-0}" \
    && ok "EDL output duration ~1.4s (got ${dur}s)" || no "EDL output duration (got ${dur}s)"

  # regression (live E2E find): -o resolves against the CWD and the output dir
  # is created BEFORE ffmpeg opens the temp file (was: mkdir after concat ->
  # cryptic "Error opening output files" for any -o into a new directory)
  ( cd "$SB" && "$PYTHON" "$S/cut-from-edl.py" cutme.json --execute -o "newdir/out2.mp4" >/dev/null 2>&1 )
  expect_exit "cut-from-edl -o cwd-relative into new dir -> 0" 0 $?
  [[ -f "$SB/newdir/out2.mp4" ]] && ok "-o resolved vs CWD, dest dir auto-created" \
    || no "-o resolved vs CWD, dest dir auto-created"

  "$PYTHON" "$S/make-chapters.py" --from-silence --media "$FIX" --min-gap 0.2 \
    --write "$SB/chaptered.mp4" >/dev/null 2>&1
  expect_exit "make-chapters --write -> 0" 0 $?
  nch="$(ffprobe -v error -show_entries chapter=start_time -of csv=p=0 "$SB/chaptered.mp4" 2>/dev/null | grep -c .)"
  [[ "${nch:-0}" -ge 1 ]] && ok "muxed file has chapters ($nch)" || no "muxed file has chapters (got ${nch:-0})"

  out="$("$PYTHON" "$S/gen-luts.py" --variants neutral709 --size 17 --out-dir "$SB/lutsprev" \
    --previews "$FIX" --frame-at 0.5 2>/dev/null)"; rc=$?
  expect_exit "gen-luts --previews -> 0" 0 "$rc"
  [[ -f "$SB/lutsprev/preview_neutral709.png" ]] && ok "preview still rendered" || no "preview still rendered"
  [[ -f "$SB/lutsprev/index.html" ]] && ok "chooser index.html written" || no "chooser index.html written"

  # --doctor: synthesized fixture has moov AFTER mdat (no faststart) -> finding
  out="$("$PYTHON" "$S/probe-media.py" --doctor "$FIX" 2>/dev/null)"; rc=$?
  expect_exit "doctor flags non-faststart fixture -> 10" 10 "$rc"
  expect_has  "doctor names the moov issue" "faststart" "$out"
  ffmpeg -v error -y -i "$FIX" -c copy -movflags +faststart "$SB/fast.mp4" 2>/dev/null
  "$PYTHON" "$S/probe-media.py" --doctor "$SB/fast.mp4" >/dev/null 2>&1
  expect_exit "doctor clean after faststart remux -> 0" 0 $?
  "$PYTHON" "$S/probe-media.py" --doctor "$WAV" >/dev/null 2>&1
  expect_exit "doctor on audio-only -> 0 (info only)" 0 $?

  "$PYTHON" "$S/smart-compress.py" --target 150KB --preset fast \
    -o "$SB/small.mp4" "$SB/fast.mp4" >/dev/null 2>&1
  expect_exit "smart-compress -> 0" 0 $?
  sz="$(wc -c < "$SB/small.mp4" 2>/dev/null | tr -d ' ')"
  [[ "${sz:-999999}" -le 150000 ]] && ok "compressed under target ($sz <= 150000)" \
    || no "compressed under target (got ${sz:-missing})"

  "$PYTHON" "$S/make-sprites.py" --interval 0.5 --width 64 --cols 2 --rows 2 \
    --out-dir "$SB/sprites" "$FIX" >/dev/null 2>&1
  expect_exit "make-sprites -> 0" 0 $?
  [[ -f "$SB/sprites/sprite_01.jpg" ]] && ok "sprite sheet written" || no "sprite sheet written"
  grep -q "xywh=64,0,64" "$SB/sprites/thumbs.vtt" 2>/dev/null \
    && ok "vtt has correct xywh geometry" || no "vtt has correct xywh geometry"

  bash "$S/capability-scan.sh" --quick >/dev/null 2>&1
  expect_exit "capability-scan --quick -> 0" 0 $?
  bash "$S/verify-commands.sh" --live >/dev/null 2>&1
  rc=$?; [[ "$rc" == 0 ]] && ok "verifier --live clean against installed build" \
    || no "verifier --live (got $rc — investigate drift findings)"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
