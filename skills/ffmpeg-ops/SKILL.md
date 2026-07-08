---
name: ffmpeg-ops
description: "Comprehensive ffmpeg/ffprobe media processing: transcode, cut/trim/concat, color grading, loudness normalization, subtitles, GIFs, HLS packaging, hardware encoding, and quality gates (VMAF). Triggers on: ffmpeg, ffprobe, transcode, compress/convert video, extract audio, color grade, hls."
license: MIT
compatibility: "ffmpeg 5.0+ (6.0+ recommended). Scripts: bash + python3.10+. Optional per task: libvmaf, libass, libzimg, libvidstab."
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: color-ops, debug-ops
---

# ffmpeg Operations

Operational expertise for ffmpeg/ffprobe: the ~30 commands that cover most real work,
the footguns that silently ruin output, EDL-driven editing (edit-as-code), and eight
scripts that replace the logic an agent would otherwise re-derive every task.

## Doctrine: probe first

**Never transcode, cut, or filter blind.** Every media task starts by probing the
input — codec, duration, frame rate (constant or variable?), pixel format, rotation,
stream layout. Half of all "ffmpeg did something weird" reports are a property of the
*input* the command never checked.

```bash
python skills/ffmpeg-ops/scripts/probe-media.py input.mp4            # human summary
python skills/ffmpeg-ops/scripts/probe-media.py --doctor input.mp4   # TRIAGE: hazards + exact fixes
python skills/ffmpeg-ops/scripts/probe-media.py --json input.mp4 | jq '.data.streams'
python skills/ffmpeg-ops/scripts/probe-media.py --keyframes-near 92.5 input.mp4
```

`--doctor` makes the doctrine self-enforcing: VFR, HDR transfer, rotation
metadata, interlacing, non-yuv420p delivery, and moov-at-EOF each come back as a
finding **with the exact fix command**, and exit 10 means "fix before processing".
The `--keyframes-near` form answers "can I stream-copy a cut at 92.5s?" — it
reports the nearest keyframes so you know whether a copy cut will snap (see
Footguns). When a command fails with a cryptic message, decode it:
[references/error-decoder.md](references/error-decoder.md).

**Before recommending an encoder, verify the build has it.** Installed ffmpeg builds
vary wildly (especially hardware encoders — *listed* ≠ *working*):

```bash
bash skills/ffmpeg-ops/scripts/capability-scan.sh           # full: proof-encodes each hw encoder
bash skills/ffmpeg-ops/scripts/capability-scan.sh --quick   # list-only, no GPU touch
```

## Cookbook

Commands are bash-form; they run unchanged in PowerShell except where the
[Windows notes](#windows-notes) say otherwise. Replace `-y`/`-n` (overwrite/never)
consciously — never leave an agent-run command interactive.

### Convert and compress

```bash
# Web-compatible H.264 — THE default delivery encode. yuv420p + faststart are not
# optional: without them Safari/QuickTime/old devices show black video, and the
# moov atom sits at EOF so browsers can't start playback until fully downloaded.
ffmpeg -i in.mov -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart out.mp4

# H.265/HEVC — ~40% smaller at same quality, slower encode, less universal playback.
# -tag:v hvc1 is required for Apple players to recognize the stream.
ffmpeg -i in.mp4 -c:v libx265 -crf 24 -preset slow -tag:v hvc1 \
  -c:a copy -movflags +faststart out.mp4

# AV1 via SVT-AV1 (libaom is 10-50x slower; only use it for research-grade encodes).
# preset 0-13: lower = slower/better; 6 is the quality/speed sweet spot.
ffmpeg -i in.mp4 -c:v libsvtav1 -crf 32 -preset 6 -c:a libopus -b:a 128k out.webm

# Remux only — change container, zero quality loss, near-instant. Try this FIRST
# when the ask is "make this .mkv play in X": often the codecs are fine.
ffmpeg -i in.mkv -c copy -movflags +faststart out.mp4

# Normalize a problem source (HEVC/VFR phone footage, Zoom/Loom exports) before ANY
# downstream editing. VFR breaks cut math, concat sync, and Remotion/player seeking.
ffmpeg -i in.mov -c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p \
  -fps_mode cfr -r 30 -c:a aac -b:a 192k normalized.mp4

# Archival master — FFV1 lossless in MKV (the preservation standard).
ffmpeg -i in.mp4 -c:v ffv1 -level 3 -g 1 -slicecrc 1 -c:a flac archive.mkv

# "Make it fit in 25MB" — computed two-pass bitrate, auto audio/downscale, VERIFIED:
python skills/ffmpeg-ops/scripts/smart-compress.py --target 25MB video.mp4
```

Codec choice, CRF/preset matrices, two-pass bitrate targeting, per-platform social
targets: [references/encoding.md](references/encoding.md) +
[assets/encoding-presets.json](assets/encoding-presets.json).

### Cut and join

```bash
# Fast lossless trim (stream copy). -ss/-to BEFORE -i = input seek, absolute times.
# CAVEAT: with -c copy the start snaps to the previous keyframe — can be seconds
# early, or give frozen/black lead-in. Check first with probe-media.py --keyframes-near.
ffmpeg -ss 00:01:30 -to 00:02:00 -i in.mp4 -c copy -avoid_negative_ts make_zero cut.mp4

# Frame-accurate trim (re-encode). Input-side -ss IS frame-accurate when re-encoding
# (ffmpeg decodes from the prior keyframe and discards) — fast AND exact. The old
# "put -ss after -i for accuracy" advice costs a full decode from 0:00 for nothing.
ffmpeg -ss 00:01:30 -to 00:02:00 -i in.mp4 -c:v libx264 -crf 18 -c:a aac cut.mp4

# Join files with IDENTICAL codec/params — concat demuxer, no re-encode.
printf "file '%s'\n" seg1.mp4 seg2.mp4 seg3.mp4 > concat.txt
ffmpeg -f concat -safe 0 -i concat.txt -c copy joined.mp4

# Join files with DIFFERENT codecs/sizes — concat filter, re-encodes.
ffmpeg -i a.mp4 -i b.mov -filter_complex \
  "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" -c:v libx264 -crf 20 -c:a aac joined.mp4

# Remove a middle segment (keep 0-60s and 120s-end): cut both keeps, then concat.
# For multi-cut edits, write an EDL and use cut-from-edl.py instead (see EDL workflow).
```

`-ss` semantics in full, keyframe theory, concat ×3 (demuxer/filter/protocol),
edit-decision-list editing: [references/trim-concat.md](references/trim-concat.md)
and [references/edit-as-code.md](references/edit-as-code.md).

### Resize, transform, retime

```bash
# Resize to width, keep aspect. ALWAYS -2 (not -1): yuv420p needs even dimensions.
ffmpeg -i in.mp4 -vf "scale=1280:-2" -c:a copy out.mp4

# Crop (w:h:x:y from top-left); cropdetect finds black bars for you:
ffmpeg -i in.mp4 -vf cropdetect -frames:v 120 -f null - 2>&1 | rg crop=
ffmpeg -i in.mp4 -vf "crop=1920:800:0:140" -c:a copy out.mp4

# Vertical 9:16 from landscape — blurred-pad pattern (social standard):
ffmpeg -i in.mp4 -filter_complex \
  "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20[bg];
   [0:v]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2" -c:a copy vertical.mp4

# Rotate: fix metadata only (instant) vs bake pixels (re-encode).
ffmpeg -display_rotation 90 -i in.mp4 -c copy out.mp4        # metadata flip (ffmpeg 6+)
ffmpeg -i in.mp4 -vf "transpose=1" -c:a copy out.mp4         # transpose=1: 90° clockwise

# Frame-rate change (drops/dups frames; for smooth slow-mo see minterpolate below)
ffmpeg -i in.mp4 -vf "fps=30" -c:a copy out.mp4

# 2x speed-up: video PTS halved + audio atempo (atempo accepts 0.5-100; chain
# atempo=0.5,atempo=0.5 for 0.25x). -map ordering keeps streams paired.
ffmpeg -i in.mp4 -filter_complex \
  "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]" -map "[v]" -map "[a]" fast.mp4

# Interpolated slow-mo (synthesizes in-between frames — slow but smooth):
ffmpeg -i in.mp4 -vf "minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc,setpts=2*PTS" -an slow.mp4

# Timelapse from photos (and the reverse: video -> frames, under Images below)
ffmpeg -framerate 24 -pattern_type glob -i 'photos/*.jpg' \
  -c:v libx264 -crf 20 -pix_fmt yuv420p timelapse.mp4
```

Filtergraph syntax (labels, chains, split), speed ramps, full filter cookbook:
[references/filtergraph.md](references/filtergraph.md).

### Overlay, text, subtitles

```bash
# Watermark bottom-right with 24px margin (W/H = video, w/h = overlay dims):
ffmpeg -i in.mp4 -i logo.png -filter_complex \
  "overlay=W-w-24:H-h-24:format=auto" -c:a copy out.mp4

# Burn a running timecode (note %{pts\:hms} — the colon must be escaped INSIDE
# the drawtext argument; see Windows notes for fontfile paths):
ffmpeg -i in.mp4 -vf \
  "drawtext=text='%{pts\:hms}':fontsize=48:fontcolor=white:box=1:boxcolor=black@0.5:x=24:y=24" \
  -c:a copy out.mp4

# Burn-in subtitles (hard subs; needs libass). Pragmatic path rule: cd to the
# subtitle's directory and use a bare relative filename — the filter's path
# escaping is the single worst quoting trap in ffmpeg, especially on Windows.
ffmpeg -i in.mp4 -vf "subtitles=subs.srt" -c:a copy burned.mp4

# Soft subtitles (toggleable, instant — no re-encode):
ffmpeg -i in.mp4 -i subs.srt -map 0 -map 1 -c copy -c:s mov_text soft.mp4   # mp4
ffmpeg -i in.mkv -i subs.srt -map 0 -map 1 -c copy -c:s srt soft.mkv        # mkv
```

Styling (ASS force_style), extraction, format conversion, STT round-trip:
[references/subtitles.md](references/subtitles.md).

### Audio

```bash
# Extract audio without re-encoding (copy the stream as-is; pick the container
# matching the codec — probe first: aac->.m4a, opus->.opus/.ogg, mp3->.mp3):
ffmpeg -i in.mp4 -vn -c:a copy out.m4a

# Extract + transcode to Opus (best codec per bit: voice 24-32k mono, music 96-128k):
ffmpeg -i in.mp4 -vn -c:a libopus -b:a 128k out.opus

# Replace a video's audio track (keep video untouched):
ffmpeg -i video.mp4 -i music.m4a -map 0:v -map 1:a -c:v copy -c:a aac -shortest out.mp4

# Mix two audio inputs (normalize=0 stops amix halving the volume of each input):
ffmpeg -i voice.wav -i music.mp3 -filter_complex \
  "[1:a]volume=0.25[m];[0:a][m]amix=inputs=2:duration=first:normalize=0[a]" \
  -map "[a]" -c:a aac mixed.m4a

# Loudness-normalize, one-pass (quick; DYNAMIC mode — fine for drafts).
# Two-pass linear mode is measurably better: use loudnorm-scan.py (Scripts below).
# loudnorm internally upsamples to 192kHz — the -ar 48000 puts it back.
ffmpeg -i in.mp4 -af "loudnorm=I=-16:TP=-1.5:LRA=11" -ar 48000 -c:v copy out.mp4

# Trim leading/trailing silence:
ffmpeg -i in.wav -af \
  "silenceremove=start_periods=1:start_threshold=-40dB:detection=peak,areverse,silenceremove=start_periods=1:start_threshold=-40dB:detection=peak,areverse" \
  trimmed.wav
```

Targets: -14 LUFS streaming platforms, -16 podcasts, -23 EBU R128 broadcast.
Channel mapping, multi-track, restoration filters:
[references/audio.md](references/audio.md).

### Speech-to-text prep (Whisper-family)

```bash
# THE canonical STT extraction — 16 kHz mono 16-bit PCM (what whisper.cpp /
# faster-whisper actually resample to; doing it here is faster and deterministic):
ffmpeg -i in.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le stt.wav

# Pipe raw PCM straight to whisper.cpp — no temp file:
ffmpeg -v error -i in.mp4 -vn -ac 1 -ar 16000 -f s16le - | whisper-cli -m model.bin -f - 

# Chunk long audio ON SILENCE BOUNDARIES (never mid-word) for parallel transcription:
python skills/ffmpeg-ops/scripts/detect-segments.py --silence --json in.mp4 \
  | jq '.data.speech[]'
```

Pre-STT cleanup (when `afftdn`/`highpass` help vs hurt accuracy), WhisperX word-level
alignment (±50 ms), transcript JSON shape, the summarisation pipeline:
[references/stt-whisper.md](references/stt-whisper.md).

### Images, GIFs, frames

```bash
# Thumbnail at a timestamp (input-side -ss: instant even at 2h offsets):
ffmpeg -ss 00:00:05 -i in.mp4 -frames:v 1 -q:v 2 thumb.jpg

# Contact sheet: 1 frame every 10s, tiled 4x3 (visual summary / scrub preview):
ffmpeg -i in.mp4 -vf "fps=1/10,scale=320:-2,tile=4x3" -frames:v 1 sheet.png

# High-quality GIF — palettegen/paletteuse is THE difference between a 256-color
# dithered mess and a clean GIF. Single pass via split:
ffmpeg -ss 5 -to 8 -i in.mp4 -filter_complex \
  "fps=12,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4" \
  out.gif

# Embedded chapters from scene/silence detection (or YouTube description text):
python skills/ffmpeg-ops/scripts/make-chapters.py --from-scenes --media talk.mp4 \
  --min-gap 30 --write chaptered.mp4
python skills/ffmpeg-ops/scripts/make-chapters.py --from-silence --media lecture.mp4 \
  --format youtube

# Frames for ML datasets — fixed fps, model-square crop:
ffmpeg -i in.mp4 -vf "fps=1,scale=512:512:force_original_aspect_ratio=increase,crop=512:512" \
  frames/%06d.png

# Image sequence -> video:
ffmpeg -framerate 24 -i frames/%06d.png -c:v libx264 -crf 18 -pix_fmt yuv420p out.mp4

# Player scrub-preview sprites + the WebVTT thumbnail track that maps them:
python skills/ffmpeg-ops/scripts/make-sprites.py --interval 5 video.mp4
```

Sprite sheets for web players, AVIF/WebP stills, dataset prep patterns:
[references/images-gif.md](references/images-gif.md).

### Diagnostics and validation

```bash
# Corruption / decode-error check (exit code is NOT the signal — the log is):
ffmpeg -v error -i in.mp4 -f null - 2> errors.log && [ ! -s errors.log ] && echo CLEAN

# Per-frame hashes — prove two pipelines produce identical frames:
ffmpeg -i in.mp4 -map 0:v -f framemd5 - 

# Strip ALL metadata (GPS, device info — privacy before sharing phone video).
# -map_metadata -1 keeps rotation side-data; verify orientation after.
ffmpeg -i in.mp4 -map_metadata -1 -c copy clean.mp4

# Quick probes (machine-readable; prefer probe-media.py for the full picture):
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 in.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 in.mp4
```

Safe re-encode of untrusted uploads, scene-change detection, integrity in CI:
[references/analysis-validation.md](references/analysis-validation.md).

### yt-dlp interop

yt-dlp embeds ffmpeg for merge/remux; these are the post-download patterns:

```bash
# Prefer h264+m4a at download time (avoids a transcode entirely):
yt-dlp -S "res:1080,vcodec:h264,acodec:m4a" --remux-video mp4 URL

# Clip a section AT download (server-side range requests; much faster than full DL):
yt-dlp --download-sections "*10:00-12:30" -S "res:1080,vcodec:h264" URL

# Audio-only for STT/summarisation:
yt-dlp -x --audio-format opus URL

# Already downloaded a VP9/AV1 .webm that needs to be H.264 .mp4: that is a normal
# transcode — use the web-compatible H.264 recipe above, NOT --recode-video.
```

### Generative/test sources

```bash
# Synthetic video+audio — fixtures, pipeline tests, alignment checks (no real media
# needed; this is how tests/run.sh builds its fixtures):
ffmpeg -f lavfi -i testsrc2=duration=2:size=640x360:rate=30 \
       -f lavfi -i "sine=frequency=440:duration=2" \
       -c:v libx264 -pix_fmt yuv420p -c:a aac fixture.mp4
```

Audio-reactive visuals (showwaves/showspectrum), podcast audiograms:
[references/visualization.md](references/visualization.md).

## Footguns

The table that pays this skill's rent. Each row is a class of silent failure.

| Footgun | The trap | The rule |
|---|---|---|
| `-ss` + `-c copy` | Cut starts seconds early or with frozen/black lead-in (snapped to prior keyframe) | Copy cuts snap. Check `probe-media.py --keyframes-near`; re-encode when exact |
| Output-side `-to` after input-side `-ss` | Timestamps reset at the seek point, so `-to` silently becomes a *duration* | Keep `-ss`/`-to` on the same side of `-i` (both input-side is fast and absolute) |
| Missing `-pix_fmt yuv420p` | Encode "works" but Safari/QuickTime/TVs show black or refuse to play (defaulted to yuv444p/yuv422p from a high-quality source) | Always set it for delivery H.264/H.265 |
| Missing `-movflags +faststart` | Browser can't start playback until the whole file downloads (moov at EOF) | Always set it for web-served MP4 |
| Default stream selection | ffmpeg picks ONE stream per type (highest-res video, most-channels audio) — extra audio tracks and all subs are silently dropped | `-map 0` to keep everything, explicit `-map` otherwise |
| `-vf` + `-c:v copy` together | Hard error — filters require decoding | Filtering implies re-encode; pick one |
| VFR source (phone/Zoom/Loom/screen-rec) | Cut math drifts, concat desyncs, players stutter | Normalize first: `-fps_mode cfr -r 30` + re-encode (cookbook) |
| `-vsync` (deprecated) | Old flag, removed direction | Use `-fps_mode` (cfr/vfr/passthrough) |
| `scale=W:-1` | Odd height → encoder error with yuv420p | Always `-2` |
| concat demuxer on mismatched inputs | "Works" then glitches/desyncs at boundaries (codec/timebase mismatch) | Demuxer = identical params only; else concat *filter* with re-encode |
| amix default | Each input's volume halved (normalize defaults on) | `amix=...:normalize=0` + explicit `volume=` |
| One-pass loudnorm | Dynamic mode pumps quiet passages; output silently 192 kHz | Two-pass linear via `loudnorm-scan.py`; add `-ar 48000` |
| `-shortest` absent on audio-replace | Output runs as long as the LONGEST input (silence or frozen frame tail) | Add `-shortest` when muxing separate A/V |
| BT.601/709 colour shift | Slightly wrong colours after scaling SD↔HD (matrix guessed from resolution) | Tag explicitly when it matters: see [references/color-hdr.md](references/color-hdr.md) |
| drawtext/subtitles path escaping | Filter args re-parse `:` and `\` — Windows paths like `C:\x` explode inside filter strings | cd to the asset's dir and use bare relative names; or escape as `C\:/path` |
| Interactive overwrite prompt | Agent-run command hangs forever on "File exists. Overwrite? [y/N]" | Always pass `-y` or `-n` explicitly |
| `%` in cmd.exe | `%06d` patterns and `%{pts}` get mangled by cmd variable expansion | Use PowerShell or bash; in .bat double to `%%` |

### Windows notes

Platform-agnostic commands, but when running on Windows:

- **PowerShell quoting is friendlier than bash here**: single quotes are fully
  literal, so `-vf 'scale=1280:-2,fps=30'` needs no escaping. Double quotes only
  interpolate `$` and backtick — filtergraphs rarely contain either.
- **`NUL` not `/dev/null`** for two-pass logs: `-passlogfile` defaults are fine, but
  `ffmpeg ... -f null NUL` (PowerShell also accepts `-f null -`, which is portable —
  prefer it).
- **Font paths in drawtext**: `fontfile='C\:/Windows/Fonts/arial.ttf'` — forward
  slashes, escaped drive colon, inside the filter string.
- **Prefer `-f null -` and relative paths** to sidestep both quoting tables at once.

## Decision trees

**Codec** — `H.264 (libx264)`: default; universal playback, fast, good per-bit at
`-crf 18..23`. → `H.265 (libx265)`: same quality ~40% smaller; slower; needs
`-tag:v hvc1` for Apple; fine for storage/modern devices. → `AV1 (libsvtav1)`: best
compression, royalty-free, web-first (YouTube/Netflix path); encode cost highest;
playback on older hardware is software-only. → `VP9`: only when a pipeline demands
webm and AV1 is unavailable. → `FFV1`: archival masters only.

**Cut method** — Need exact frames OR applying any filter → re-encode (input-side
`-ss`, `-crf 18`). Cut points happen to sit on keyframes (verify with
`--keyframes-near`) OR a ±2s slop is acceptable → stream copy with
`-avoid_negative_ts make_zero`. Many cuts from one source → EDL workflow below.

**CPU vs hardware encode** — Hardware (NVENC/QSV/AMF/VideoToolbox) is 5-20× faster
but **worse quality per bit** than libx264/x265 at slow presets. Use hardware for:
speed-critical batch work, live/streaming, drafts, "good enough" deliveries (bump
bitrate ~30% to compensate). Use CPU for: final masters, size-constrained targets,
quality comparisons. Always `capability-scan.sh` first — listed encoders fail at
runtime on driver mismatches. Details: [references/hardware-accel.md](references/hardware-accel.md).

## EDL workflow (edit-as-code)

For any multi-cut edit, do not fire ad-hoc trim commands. Write an **edit decision
list** — a JSON file naming every clip, time range, and *why* — then cut from it.
The edit becomes reviewable (rationale is written down), rerunnable (regenerate the
output any time), and diffable (versions of the edit are git history).

```bash
# 1. Find candidate cut points (silence = clean speech boundaries):
python skills/ffmpeg-ops/scripts/detect-segments.py --silence --json take3.mp4

# 2. Author the EDL (schema: assets/edl-schema.json) with per-scene rationale.

# 3. Dry-run prints every ffmpeg command it would run (default — nothing executes):
python skills/ffmpeg-ops/scripts/cut-from-edl.py edit.json

# 4. Execute: cuts + concat -> final. Re-encodes by default for frame accuracy;
#    --copy for keyframe-aligned EDLs.
python skills/ffmpeg-ops/scripts/cut-from-edl.py edit.json --execute -o final.mp4
```

Rules that make this work (from the Fable launch-video pipeline): cuts must land in
**silence**; the model reasons over **transcripts, not frames**; after cutting,
**re-transcribe the output to verify** (no filler words survived, no words clipped).
Full architecture, EDL schema, verification loop:
[references/edit-as-code.md](references/edit-as-code.md).

## Color grading

```bash
# Apply a .cube LUT (tetrahedral = highest quality interpolation):
ffmpeg -i in.mp4 -vf "lut3d=file=grade.cube:interp=tetrahedral" \
  -c:v libx264 -crf 18 -c:a copy graded.mp4

# Generate a family of grade candidates + an HTML still-chooser:
python skills/ffmpeg-ops/scripts/gen-luts.py --variants all --out-dir work/luts \
  --previews in.mp4
```

**The human picks the grade.** Generate variants, render preview stills, present a
chooser — never auto-select a look. Grading is a taste call; the agent's job is the
lattice math and the apply command. LUT format, log-footage normalization
(S-Log3/V-Log → Rec.709), curves/eq safe ranges, checking work with ffmpeg's
built-in scopes (waveform/vectorscope):
[references/color-grading.md](references/color-grading.md). The 25-look recipe
catalog — film stocks (Kodachrome, CineStill halation, Technicolor, Eterna),
signature grades (Mad Max, Fincher, Matrix, BR2049, Amélie…), era/genre moods,
Sin City selective color — every chain build-validated, plus the Hald-CLUT
match-any-look workflow and scope-matching ladder:
[references/look-recipes.md](references/look-recipes.md). Pipeline correctness
(pix_fmt, HDR→SDR tonemapping, range/matrix tagging):
[references/color-hdr.md](references/color-hdr.md).

## Quality gates

```bash
# VMAF/SSIM/PSNR verdict on an encode (exit 10 = below threshold -> branch on it):
python skills/ffmpeg-ops/scripts/quality-compare.py reference.mp4 encoded.mp4 \
  --metrics ssim,psnr
python skills/ffmpeg-ops/scripts/quality-compare.py reference.mp4 encoded.mp4 \
  --metrics vmaf --min-vmaf 90 --json | jq '.data.vmaf'
```

VMAF ≥ 93 at 1080p ≈ visually transparent; 80-93 = noticeable on inspection.
Side-by-side visual A/B (`hstack`), metric interpretation, encode-ladder tuning:
[references/quality-metrics.md](references/quality-metrics.md).

## Scripts

All eleven follow the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md):
`--help` with examples, stdout = data only, `--json` envelopes
(`claude-mods.ffmpeg-ops.*/v1`), semantic exit codes (`0` ok, `2` usage, `3` input
missing, `4` invalid input, `5` missing dependency, `7` ffmpeg unavailable,
`10` domain finding).

| Script | Job | Worked invocation |
|---|---|---|
| `probe-media.py` | Normalized inspection, keyframe proximity, `--doctor` triage (hazard → fix command, exit 10) | `probe-media.py --doctor in.mp4` |
| `capability-scan.sh` | What can THIS ffmpeg build do (proof-encodes hw encoders; `--quick` skips) | `capability-scan.sh --json \| jq '.data.encoders'` — exit 10 = a listed encoder failed verification |
| `quality-compare.py` | VMAF/SSIM/PSNR gate | `quality-compare.py ref.mp4 enc.mp4 --min-vmaf 90` — exit 10 = below threshold |
| `loudnorm-scan.py` | Two-pass loudnorm: measures pass 1, emits exact pass-2 filter | `loudnorm-scan.py -I -16 in.mp4 --json \| jq -r '.data.pass2_filter'` |
| `detect-segments.py` | Silence/scene boundaries as JSON segments (STT chunking, dead-air cuts, shot splits) | `detect-segments.py --scenes --json in.mp4 \| jq '.data.segments'` |
| `cut-from-edl.py` | EDL JSON → validated cuts + concat (dry-run by default) | `cut-from-edl.py edit.json --execute -o final.mp4` |
| `make-chapters.py` | Scene/silence points (or explicit JSON) → embedded chapters / YouTube text / WebVTT | `make-chapters.py --from-scenes --media talk.mp4 --write chaptered.mp4` |
| `smart-compress.py` | Fit a size cap: computed two-pass bitrate, auto audio/downscale, size-verified (exit 10 = still over) | `smart-compress.py --target 25MB video.mp4` |
| `make-sprites.py` | Scrub-preview sprite sheets + WebVTT thumbnail track (#xywh) | `make-sprites.py --interval 5 video.mp4` |
| `gen-luts.py` | Emit .cube grade variants (+ `--previews` still chooser) | `gen-luts.py --variants warm_filmic,punchy --out-dir luts/` |
| `verify-commands.sh` | Staleness verifier: `--offline` structural (CI), `--live` checks docs against the installed build | `verify-commands.sh --live` — exit 10 = doc drift, 7 = no ffmpeg |

## References

Load on demand — one concept per file:

| Reference | Load when |
|---|---|
| [encoding.md](references/encoding.md) | Choosing codec/CRF/preset, two-pass, social platform targets, archival |
| [hardware-accel.md](references/hardware-accel.md) | NVENC/QSV/AMF/VideoToolbox/VAAPI flags, quality caveats, detection |
| [filtergraph.md](references/filtergraph.md) | Any `-filter_complex`, labels/chains/split, speed ramps, xstack |
| [trim-concat.md](references/trim-concat.md) | Cut accuracy, keyframes, concat selection, segment removal |
| [edit-as-code.md](references/edit-as-code.md) | Multi-cut edits, EDL schema, transcript-driven editing, verify loop |
| [audio.md](references/audio.md) | Loudness, mixing, channel layout, audio repair |
| [stt-whisper.md](references/stt-whisper.md) | Whisper/WhisperX prep, chunking, transcript JSON, summarisation pipeline |
| [subtitles.md](references/subtitles.md) | Burn vs soft, styling, extraction, format conversion |
| [color-grading.md](references/color-grading.md) | LUTs, .cube format, log normalization, scopes, grade workflow |
| [look-recipes.md](references/look-recipes.md) | 25-look catalog (film stocks, signature movie grades, era/genre moods), Hald-CLUT extraction, scope-matching |
| [color-hdr.md](references/color-hdr.md) | pix_fmt, HDR→SDR tonemap, BT.601/709 tagging, 10-bit |
| [quality-metrics.md](references/quality-metrics.md) | VMAF/SSIM interpretation, visual A/B, ladder tuning |
| [streaming-hls.md](references/streaming-hls.md) | HLS/DASH packaging, ABR ladders, live restream |
| [images-gif.md](references/images-gif.md) | GIF quality, sprite sheets, dataset frame extraction |
| [restoration.md](references/restoration.md) | Deinterlace, denoise, deband, stabilize, audio cleanup |
| [analysis-validation.md](references/analysis-validation.md) | Corruption checks, hashing, metadata stripping, untrusted uploads |
| [capture-devices.md](references/capture-devices.md) | Screen/webcam capture per OS (gdigrab/dshow, avfoundation, x11grab) |
| [error-decoder.md](references/error-decoder.md) | An ffmpeg command failed with a cryptic message — symptom → cause → fix |
| [visualization.md](references/visualization.md) | Waveform/spectrogram videos, audiograms, comparison grids |

Assets: [encoding-presets.json](assets/encoding-presets.json) (recipe data incl.
date-stamped social targets), [hls-ladder.json](assets/hls-ladder.json) (ABR ladder),
[edl-schema.json](assets/edl-schema.json) (the cut-from-edl.py contract).

## Self-test

```bash
bash skills/ffmpeg-ops/tests/run.sh   # offline suite; synthesizes fixtures via lavfi
```

Structural assertions always run; media round-trips run only when ffmpeg is on PATH
(loud skip otherwise — never a silent false-clean).
