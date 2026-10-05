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

Copy-paste recipes, each with the trap it avoids in its comments: [references/cookbook.md](references/cookbook.md). Commands are bash-form (see [Windows notes](#windows-notes)); always pass `-y` or `-n` so no agent-run command goes interactive.

| Need | Cookbook section |
|---|---|
| Web H.264, HEVC, AV1, remux, VFR normalize, FFV1 archive, fit-to-size | Convert and compress |
| Copy vs frame-accurate trim, concat demuxer vs filter | Cut and join |
| Scale, crop, 9:16 blurred pad, rotate, fps, speed, slow-mo, timelapse | Resize, transform, retime |
| Watermark, drawtext timecode, burned vs soft subtitles | Overlay, text, subtitles |
| Extract, replace, mix, loudness, trim silence | Audio |
| 16 kHz mono STT extraction, piping, silence chunking | Speech-to-text prep |
| Thumbnails, contact sheets, GIFs, chapters, dataset frames, sprites | Images, GIFs, frames |
| Corruption check, frame hashes, metadata strip, ffprobe one-liners | Diagnostics and validation |
| Post-download yt-dlp patterns | yt-dlp interop |
| Synthetic test fixtures | Generative/test sources |

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
| [cookbook.md](references/cookbook.md) | Any concrete command: the full recipe set by job (convert, cut, transform, overlay, audio, STT prep, images, diagnostics, yt-dlp, test sources) |

Assets: [encoding-presets.json](assets/encoding-presets.json) (recipe data incl.
date-stamped social targets), [hls-ladder.json](assets/hls-ladder.json) (ABR ladder),
[edl-schema.json](assets/edl-schema.json) (the cut-from-edl.py contract).

## Self-test

```bash
bash skills/ffmpeg-ops/tests/run.sh   # offline suite; synthesizes fixtures via lavfi
```

Structural assertions always run; media round-trips run only when ffmpeg is on PATH
(loud skip otherwise — never a silent false-clean).
