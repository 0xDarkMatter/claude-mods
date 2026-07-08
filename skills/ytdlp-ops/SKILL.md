---
name: ytdlp-ops
description: "yt-dlp media acquisition layer feeding ffmpeg-ops: format selection avoiding post-download transcodes, clip-at-download, cookies/auth, channel archive sync, SponsorBlock, subtitles, failure triage (403s, nsig). Triggers on: yt-dlp, download video/playlist/channel, youtube to mp3."
license: MIT
compatibility: "yt-dlp 2025.x+ (releases near-monthly; run the verifier FIRST when anything fails). ffmpeg on PATH required for merge/remux/extract-audio. A JS runtime (deno auto-enabled; node via --js-runtimes node) required for full YouTube format extraction. Scripts: bash."
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: ffmpeg-ops, debug-ops
---

# yt-dlp Operations

Operational expertise for yt-dlp as the **acquisition layer**: get the right bytes
onto disk in the right codec, politely, resumably — then hand off. Anything that
re-encodes, cuts precisely, grades, or packages after download is
[ffmpeg-ops](../ffmpeg-ops/SKILL.md) territory; AI-driven editing of what you
acquired (transcript → EDL → final cut) is [cutcraft](../cutcraft/SKILL.md) —
the full chain is acquire → process → edit.

## Doctrine: version first, formats second

**yt-dlp vs the platforms is an arms race.** Releases land near-monthly and
extractors break between them — the majority of "yt-dlp is broken" reports are a
stale binary. Before debugging *anything*, check staleness:

```bash
bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --live          # vs latest GitHub release
bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --live --json | jq '.data.days_behind'
```

Exit `10` = installed build is >60 days behind latest (or a smoke extraction
failed) → update before any other triage:

```bash
uv tool upgrade yt-dlp        # pip/uv-managed install (preferred)
yt-dlp -U                     # standalone binary self-update only
```

**Second rule: pick codecs at download time.** The default "best" on YouTube is
VP9/AV1 + Opus in WebM/MKV. If the destination needs H.264 MP4, stating that in
`-S` costs nothing — discovering it after download costs a full transcode.

## Cookbook

### Format selection (`-S` over `-f`)

```bash
# Declarative sort (-S) — PREFER this. States preferences in priority order and
# always degrades gracefully to the nearest available. h264 + m4a merges
# natively into mp4: zero post-download transcode.
yt-dlp -S "res:1080,vcodec:h264,acodec:m4a" --merge-output-format mp4 URL

# Hard filter (-f) — exact control, but FAILS ("Requested format is not
# available") when nothing matches. Use only for genuine hard requirements,
# always with a / fallback chain:
yt-dlp -f "bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/b[height<=1080]/b" URL

# Survey what the extractor actually offers before arguing with selectors:
yt-dlp -F URL

# Smallest acceptable file (bandwidth/storage constrained; + prefix = ascending):
yt-dlp -S "res:480,+size,+br" URL

# Best quality regardless of codec (archival source for later ffmpeg-ops work):
yt-dlp -S "res,fps,hdr:12,vcodec,acodec" --merge-output-format mkv URL
```

Sort-field reference, filter grammar, per-destination presets:
[references/format-selection.md](references/format-selection.md) +
[assets/format-presets.json](assets/format-presets.json).

### Clip at download (`--download-sections`)

```bash
# Download ONLY 10:00-12:30 — ranged requests, not a full download + trim:
yt-dlp --download-sections "*10:00-12:30" -S "res:1080,vcodec:h264" URL

# Frame-accurate cut points (re-encodes around the cuts only):
yt-dlp --download-sections "*10:00-12:30" --force-keyframes-at-cuts URL

# Last 5 minutes / by chapter-title regex / multiple sections:
yt-dlp --download-sections "*-5:00-inf" URL
yt-dlp --download-sections "Intro" --download-sections "Outro" URL
```

Same physics as ffmpeg copy-cuts: without `--force-keyframes-at-cuts` the section
boundaries **snap to keyframes** (can be seconds off). Need many precise cuts from
one source? Download once, then use the ffmpeg-ops EDL workflow.

### Audio-only extraction (STT pipelines)

```bash
# THE STT acquisition command. YouTube's best audio IS Opus — asking for opus
# means -x COPIES the stream out (no transcode, no quality loss):
yt-dlp -x --audio-format opus -o "%(id)s.%(ext)s" URL

# Zero-processing alternative — native container, no ffmpeg step at all:
yt-dlp -f "ba" -o "%(id)s.%(ext)s" URL

# Whole channel's audio for a transcription pipeline (archive = resumable):
yt-dlp -x --audio-format opus --download-archive stt-archive.txt \
  -o "%(channel)s/%(id)s.%(ext)s" CHANNEL_URL
```

Do NOT `--audio-format mp3` for STT — that's a lossy→lossy transcode that helps
nothing. Whisper-prep (16 kHz mono PCM) is the next stage:
ffmpeg-ops [stt-whisper](../ffmpeg-ops/references/stt-whisper.md).

### Playlists, channels, incremental sync

```bash
# Playlist with ID-correlated filenames + archive file (resumable, dedup-safe):
yt-dlp --download-archive archive.txt \
  -o "%(playlist)s/%(playlist_index)03d - %(title).100B [%(id)s].%(ext)s" PLAYLIST_URL

# Incremental channel sync (cron-friendly): stop at the first already-archived
# video instead of re-walking the entire channel every run:
yt-dlp --download-archive archive.txt --break-on-existing --lazy-playlist \
  -S "res:1080,vcodec:h264,acodec:m4a" CHANNEL_URL

# Subset selection / list without downloading:
yt-dlp -I 1:10 PLAYLIST_URL
yt-dlp --flat-playlist --print "%(id)s %(title)s" PLAYLIST_URL

# DRY-RUN any batch before committing to it — preview every output filename
# (--print implies --simulate; nothing downloads):
yt-dlp --print filename -o "%(playlist_index)03d - %(title).100B [%(id)s].%(ext)s" PLAYLIST_URL
```

Archive format, sync-job patterns, when `--break-on-existing` misfires
(non-chronological playlists):
[references/playlists-archives.md](references/playlists-archives.md).

### Livestreams and premieres

```bash
# Capture a livestream from its BEGINNING, not from "now" (YouTube keeps a
# rolling live buffer; without this you get the moment you pressed enter):
yt-dlp --live-from-start URL

# Scheduled premiere/stream: poll (1-10 min between retries) and start when live:
yt-dlp --wait-for-video 60-600 URL
```

Live capture caveats: a crashed live download is **not resumable** like a VOD
(fragments expire) — write to fast local disk (`-P temp:`), not a network share.
For archival quality, prefer re-downloading the VOD after the stream ends; the
live manifest often caps below the post-processed VOD.

### Subtitles

```bash
# Manual subs, English variants, skip live-chat pseudo-subs, as SRT:
yt-dlp --write-subs --sub-langs "en.*,-live_chat" --convert-subs srt --skip-download URL

# Auto-generated (ASR) captions — exist for most videos when manual subs don't:
yt-dlp --write-auto-subs --sub-langs en --convert-subs srt --skip-download URL

# Embed into the media file instead of a sidecar:
yt-dlp --embed-subs --sub-langs en URL
```

Sub formats, language matching, transcript-only workflows (subs as cheap STT):
[references/subtitles-metadata.md](references/subtitles-metadata.md).

### SponsorBlock

```bash
# Mark segments as chapters — LOSSLESS and reversible. Prefer this:
yt-dlp --sponsorblock-mark all URL

# Cut segments out of the media — modifies the file, re-encodes at boundaries:
yt-dlp --sponsorblock-remove sponsor,selfpromo URL
```

Category list, mark-vs-remove trade-offs, interaction with `--download-sections`:
[references/sponsorblock.md](references/sponsorblock.md).

### Cookies and auth

```bash
# Pull cookies from a browser profile (private/members/age-gated content):
yt-dlp --cookies-from-browser firefox URL

# Chrome 127+ on Windows uses app-bound cookie encryption — extraction usually
# FAILS. Use Firefox, or export a Netscape cookies.txt and pass it directly:
yt-dlp --cookies cookies.txt URL
```

**Account-ban warning:** authenticated bulk downloading is the fastest way to get
an account flagged. Use a throwaway account, always pair cookies with the
politeness flags below. Details + browser matrix:
[references/auth-cookies.md](references/auth-cookies.md).

### Rate limiting and politeness

```bash
# The polite-bulk baseline — cap bandwidth, space out requests, retry patiently:
yt-dlp --limit-rate 4M --sleep-requests 1 \
  --sleep-interval 5 --max-sleep-interval 15 \
  --retries 10 --fragment-retries 10 URL

# Speed (single video, host not throttling you): parallel fragment download:
yt-dlp --concurrent-fragments 4 URL
```

Politeness is self-interest: 429s and IP flags cost more time than sleeps do.

### Remux vs recode

```bash
# Remux: container change only — lossless, near-instant. yt-dlp's job:
yt-dlp -S "vcodec:h264,acodec:m4a" --remux-video mp4 URL

# Recode: a FULL TRANSCODE. Almost never yt-dlp's job — you give up ffmpeg-ops'
# CRF/preset/pix_fmt control for a blind default encode. If codecs must change:
yt-dlp -S "res,vcodec,acodec" URL        # 1. acquire best-native
# 2. then transcode with the ffmpeg-ops web-compatible H.264 recipe.
```

Rule: `--remux-video` whenever the codecs already fit the target container;
`--recode-video` only for throwaway one-offs where quality control doesn't matter.

### Output templates

```bash
# ID-in-brackets convention — survives renames, correlates with archive files:
yt-dlp -o "%(uploader)s/%(upload_date)s - %(title).100B [%(id)s].%(ext)s" URL

# Cross-filesystem safety (strips spaces/unicode to ASCII-safe names):
yt-dlp --restrict-filenames -o "%(title)s [%(id)s].%(ext)s" URL

# Split destination and scratch space (-P): fragments go to temp, final to home:
yt-dlp -P "D:/media" -P "temp:C:/tmp/ytdlp" URL
```

`%(title).100B` truncates at 100 **bytes** (UTF-8 safe — CJK titles break
char-based truncation). Full field catalog and per-type templates:
[references/output-templates.md](references/output-templates.md).

### Metadata embedding

```bash
# Self-describing files — metadata, thumbnail and chapters travel with the media:
yt-dlp --embed-metadata --embed-thumbnail --embed-chapters URL
```

## Beyond YouTube

yt-dlp ships ~1,800 extractors (`yt-dlp --list-extractors`); everything in this
skill except the YouTube-specific parts (nsig, player clients) applies unchanged
to Twitch, Vimeo, SoundCloud, TikTok, and the rest. `yt-dlp -v URL` names the
extractor in use. For sites with no dedicated extractor, the generic extractor
sniffs direct media/HLS URLs out of the page. When a non-YouTube site returns
403 to yt-dlp but plays fine in a browser, it's usually TLS-fingerprint
blocking — `--impersonate` fixes it (see
[failure-triage](references/failure-triage.md)).

## Footguns

| Footgun | The trap | The rule |
|---|---|---|
| Default format selection | YouTube "best" = VP9/AV1+Opus in WebM/MKV; downstream tooling expecting MP4 forces a transcode you could have avoided | State codecs at download: `-S "vcodec:h264,acodec:m4a" --merge-output-format mp4` |
| `-f best` | Selects best *single pre-merged file* — caps at ~720p on YouTube; modern high-res is always video+audio merged | Drop the `-f` entirely or use `-S`; `b` only as the tail of a `/` fallback chain |
| `-f` hard filters | "Requested format is not available" the moment an extractor stops offering that exact combo | Prefer `-S` (degrades gracefully); always end `-f` chains with `/b` |
| `--recode-video` casually | Full blind transcode — no CRF/preset/pix_fmt control, big quality/time cost | `--remux-video` when codecs fit; real transcodes via ffmpeg-ops |
| `--download-sections` w/o `--force-keyframes-at-cuts` | Clip boundaries snap to keyframes — seconds of slop | Add the flag when cuts must be exact (re-encodes at cuts only) |
| Channel sync w/o `--break-on-existing` | Every cron run re-walks the entire channel (thousands of metadata requests) | `--download-archive` + `--break-on-existing --lazy-playlist` |
| No `%(id)s` in filename | Title changes/dupes make files impossible to correlate with the archive | Always `[%(id)s]` in the template |
| `--cookies-from-browser chrome` on Windows | Chrome 127+ app-bound encryption — extraction fails | Use `firefox`, or export `cookies.txt` |
| Authenticated bulk runs, no sleeps | Account flagged/banned; IP rate-limited | Throwaway account + `--sleep-requests`/`--sleep-interval` always |
| Throttled to ~50-100 KB/s | Looks like a network problem; it's the nsig arms race | Update yt-dlp FIRST (`check-ytdlp-version.sh --live`) |
| "nsig extraction failed" / "unable to extract" | Debugging the command/network when the binary is stale | Same — update first; these errors mean *outdated*, not *broken usage* |
| Raw `%(title)s` filenames | Emoji/colons/slashes break on Windows and some CI filesystems | `--restrict-filenames` or `.100B`-truncated fields + `[%(id)s]` |
| Thin format list on a fresh machine | No JS runtime — YouTube player JS now needs one (EJS); runtime-less extraction is deprecated and may offer only low-res premuxed | Install deno, or `--js-runtimes node`; see [failure-triage](references/failure-triage.md) |
| git-bash (MSYS) path mangling | `/tmp/...`-style args convert per-arg — templates containing `%(...)s` skip conversion while plain paths convert, scattering outputs | Use Windows-style paths (`X:/dir/...`) for `-o`/`-P`/`--download-archive` under git-bash |
| pip-installed `yt-dlp -U` | Self-update doesn't work for pip/uv installs (silently a no-op with a warning) | `uv tool upgrade yt-dlp`; `-U` is for the standalone binary only |

## Failure triage

The ladder — run in order, stop at the first fix:

1. **Stale binary?** `check-ytdlp-version.sh --live` → exit 10 → update. This
   closes most "nsig extraction failed", missing-format, and throttling cases.
2. **Reproduce verbosely:** `yt-dlp -v URL` — read the actual extractor error,
   don't guess from the summary line.
3. **403 / "Sign in to confirm you're not a bot"** → identity problem:
   `--cookies-from-browser firefox`, or a different network/IP.
4. **429 / sudden slowdowns mid-run** → rate limited: add the politeness flags,
   reduce `--concurrent-fragments`, back off and resume later (archive files
   make every run resumable).
5. **Geo block** ("not available in your country") → `--proxy URL` through an
   allowed region; the old `--geo-bypass` header tricks rarely work anymore.

Full decision tree with error-message → cause mapping, `--extractor-args`
escape hatches, and when to file upstream:
[references/failure-triage.md](references/failure-triage.md).

## Scripts

Follows the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md):
`--help` with examples, stdout = data only, `--json` envelope
(`claude-mods.ytdlp-ops.version-check/v1`), semantic exit codes (`0` clean,
`2` usage, `7` network/yt-dlp unavailable — advisory, `10` drift finding).

| Script | Job | Worked invocation |
|---|---|---|
| `check-ytdlp-version.sh` | Staleness verifier: `--offline` structural (CI gate), `--live` = installed-version age vs latest GitHub release + documented-flag existence in `yt-dlp --help` + metadata-only smoke extraction | `check-ytdlp-version.sh --live --json \| jq '.data.days_behind'` — exit 10 = >60 days behind, a documented flag vanished, or smoke failed; 7 = network/API unreachable (advisory) |

## References

Load on demand — one concept per file:

| Reference | Load when |
|---|---|
| [format-selection.md](references/format-selection.md) | Any `-f`/`-S` decision, codec targeting, filter grammar, avoiding transcodes |
| [playlists-archives.md](references/playlists-archives.md) | Playlists, channels, `--download-archive`, incremental sync jobs |
| [auth-cookies.md](references/auth-cookies.md) | Private/members/age-gated content, browser cookie matrix, ban avoidance |
| [output-templates.md](references/output-templates.md) | `-o` field catalog, paths, sanitization, per-type routing |
| [subtitles-metadata.md](references/subtitles-metadata.md) | Sub download/convert/embed, transcript workflows, metadata/thumbnail embedding |
| [sponsorblock.md](references/sponsorblock.md) | SponsorBlock categories, mark vs remove, chapter workflows |
| [failure-triage.md](references/failure-triage.md) | Any download failure — 403/429/geo/nsig/throttling decision tree |

Assets: [format-presets.json](assets/format-presets.json) — canonical, date-stamped
`-S`/flag presets per destination (web MP4, STT audio, archival, clip, mobile-small).

## Self-test

```bash
bash skills/ytdlp-ops/tests/run.sh   # fully offline; no network, no yt-dlp needed
```

Structural assertions plus the verifier's 60-day age logic exercised through its
`CM_YTDLP_INSTALLED`/`CM_YTDLP_LATEST` test seams. Real `--live` runs happen only
in the scheduled freshness workflow — a network blip must never fail a PR.
