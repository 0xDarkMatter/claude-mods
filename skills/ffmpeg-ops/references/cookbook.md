# ffmpeg Cookbook

The copy-paste recipes behind SKILL.md, grouped by job. Each recipe's comments name the trap it avoids; the Footguns table in SKILL.md is the rule set, these are the worked commands. Probe the input first (`probe-media.py --doctor`).

## Contents

- [Cookbook](#cookbook)
  - [Convert and compress](#convert-and-compress)
  - [Cut and join](#cut-and-join)
  - [Resize, transform, retime](#resize-transform-retime)
  - [Overlay, text, subtitles](#overlay-text-subtitles)
  - [Audio](#audio)
  - [Speech-to-text prep (Whisper-family)](#speech-to-text-prep-whisper-family)
  - [Images, GIFs, frames](#images-gifs-frames)
  - [Diagnostics and validation](#diagnostics-and-validation)
  - [yt-dlp interop](#yt-dlp-interop)
  - [Generative/test sources](#generativetest-sources)

## Cookbook

Commands are bash-form; they run unchanged in PowerShell except where the
[Windows notes](../SKILL.md#windows-notes) say otherwise. Replace `-y`/`-n` (overwrite/never)
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
targets: [references/encoding.md](encoding.md) +
[assets/encoding-presets.json](../assets/encoding-presets.json).

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
edit-decision-list editing: [references/trim-concat.md](trim-concat.md)
and [references/edit-as-code.md](edit-as-code.md).

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
[references/filtergraph.md](filtergraph.md).

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
[references/subtitles.md](subtitles.md).

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
[references/audio.md](audio.md).

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
[references/stt-whisper.md](stt-whisper.md).

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
[references/images-gif.md](images-gif.md).

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
[references/analysis-validation.md](analysis-validation.md).

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
[references/visualization.md](visualization.md).
