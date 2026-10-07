#!/usr/bin/env bash
# Staleness verifier for ffmpeg-ops docs — offline structural + live build-drift.
#
# --offline (default): structural integrity, NO ffmpeg needed. Assets parse as
#   JSON, every reference/script/asset on disk is cited from SKILL.md, and every
#   relative link in SKILL.md resolves. Runs in PR CI; may block.
# --live: does the documentation still match an actual ffmpeg? Extracts the
#   encoders/filters the docs rely on and checks them against the INSTALLED
#   build (`-encoders`/`-filters`/`-h full`). Core items missing = drift
#   (exit 10); build-optional items (libx265, libvmaf, ...) only warn.
#   Runs in the scheduled freshness workflow; never blocks a PR.
#
# Usage:   verify-commands.sh [--offline | --live] [-q]
# Input:   none (inspects the skill's own files; --live also the ffmpeg on PATH)
# Output:  stdout = findings (one per line, "DRIFT:" / "STRUCT:" prefixed)
# Stderr:  progress, warnings
# Exit:    0 clean, 1 crashed (a check could not read its input - nothing
#          verified), 2 usage, 7 ffmpeg unavailable (--live only; advisory),
#          10 drift/structural finding
#
# Examples:
#   verify-commands.sh --offline
#   verify-commands.sh --live
#   verify-commands.sh --live -q; echo "exit=$?"

set -uo pipefail

EXIT_OK=0; EXIT_ERROR=1; EXIT_USAGE=2; EXIT_UNAVAILABLE=7; EXIT_DRIFT=10

MODE="offline"; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)  MODE="offline" ;;
    --live)     MODE="live" ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    *) echo "ERROR: unknown argument: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
done

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
findings=0
emit()    { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$1" >&2; }
finding() { printf '%s\n' "$1"; findings=$((findings + 1)); }

# Pick a working python for JSON validation (Windows Store stub exits non-zero).
PYTHON=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

# ── offline: structural ──────────────────────────────────────────────────────
offline_checks() {
  emit "== verify-commands --offline (structural)"
  [[ -f "$SKILL_MD" ]] || { finding "STRUCT: SKILL.md missing"; return; }

  # 1. assets parse as JSON
  for a in "$SKILL_DIR"/assets/*.json; do
    [[ -e "$a" ]] || continue
    if [[ -n "$PYTHON" ]]; then
      "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$a" \
        >/dev/null 2>&1 || finding "STRUCT: asset not valid JSON: $(basename "$a")"
    elif command -v jq >/dev/null 2>&1; then
      jq empty "$a" >/dev/null 2>&1 || finding "STRUCT: asset not valid JSON: $(basename "$a")"
    fi
  done

  # 2. every shipped resource is cited from SKILL.md (dead weight check)
  for d in references scripts assets; do
    for f in "$SKILL_DIR/$d"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      [[ "$base" == ".gitkeep" ]] && continue
      grep -q "$base" "$SKILL_MD" \
        || finding "STRUCT: $d/$base exists on disk but is never cited from SKILL.md"
    done
  done

  # 3. every relative resource link in SKILL.md resolves
  # procsub guard: the pipeline's status (pipefail) is checked before its rows
  # are used. Fed straight into the loop via `< <(grep ...)`, a grep that could
  # not read SKILL.md checked no links and the verifier said clean. grep exit 1
  # is "no links", a legitimate empty result.
  local links rc=0
  links="$(grep -oE '\]\((references|assets|scripts|tests)/[^)#]+\)' "$SKILL_MD" \
           | sed -E 's/^\]\(//; s/\)$//' | sort -u)" || rc=$?
  if (( rc > 1 )); then
    echo "ERROR: could not read SKILL.md links (grep pipeline exit $rc) - nothing was verified" >&2
    exit "$EXIT_ERROR"
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -e "$SKILL_DIR/$path" ]] \
      || finding "STRUCT: SKILL.md links to missing file: $path"
  done <<< "$links"
}

# ── live: docs vs the installed build ────────────────────────────────────────
live_checks() {
  emit "== verify-commands --live (installed-build drift)"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not on PATH — live check unavailable (advisory, not a failure)" >&2
    exit "$EXIT_UNAVAILABLE"
  fi
  local encoders filters hfull docs
  encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
  filters="$(ffmpeg -hide_banner -filters 2>/dev/null)"
  hfull="$(ffmpeg -hide_banner -h full 2>/dev/null)"
  docs="$(cat "$SKILL_MD" "$SKILL_DIR"/references/*.md 2>/dev/null)"

  # Filters that exist in EVERY ffmpeg build — absence means the filter was
  # renamed/removed upstream, i.e. our docs drifted.
  local core_filters=(scale crop pad fps overlay concat setpts atempo amix
                      silencedetect silenceremove loudnorm palettegen paletteuse
                      select tile transpose trim atrim split format)
  # Build-optional (external libs / hw): warn only.
  local optional_tokens=(libx264 libx265 libsvtav1 libaom-av1 libvpx-vp9 libopus
                         libmp3lame drawtext subtitles lut3d zscale tonemap
                         libvmaf minterpolate vidstabdetect vidstabtransform
                         bwdif hqdn3d nlmeans xstack showwaves showspectrum
                         colorbalance colortemperature colorchannelmixer
                         colorhold vibrance haldclut chromashift)
  # CLI options the cookbook depends on; renamed/removed = drift (-vsync class).
  local core_options=(fps_mode movflags avoid_negative_ts map_metadata
                      filter_complex frames pix_fmt)

  # NOTE: the flags column width varies across ffmpeg majors (3 chars <=7.x,
  # 2 chars in 8.x) — match any flag run, then the exact filter name token.
  for f in "${core_filters[@]}"; do
    grep -qE "^ +[A-Z.|]+ +$f +" <<<"$filters" \
      || finding "DRIFT: core filter '$f' not in installed ffmpeg (renamed/removed upstream?)"
  done

  for opt in "${core_options[@]}"; do
    grep -q -- "-$opt" <<<"$hfull" \
      || finding "DRIFT: documented option '-$opt' unknown to installed ffmpeg"
  done

  # Every software encoder the docs name must at least be a known encoder name
  # in this build — missing here is a warning (build config), not drift, EXCEPT
  # the universal natives (aac, ffv1) which every build ships.
  for enc in aac ffv1; do
    grep -qE "^ [A-Z.]{6} +$enc " <<<"$encoders" \
      || finding "DRIFT: native encoder '$enc' not in installed ffmpeg"
  done
  for tok in "${optional_tokens[@]}"; do
    if grep -qF "$tok" <<<"$docs"; then
      grep -qE "(^ [A-Z.]{6} +$tok )|(^ +[A-Z.|]+ +$tok +)" <<<"$encoders"$'\n'"$filters" \
        || emit "   warn: '$tok' documented but absent from this build (build-optional — not drift)"
    fi
  done

  # Deprecated-flag tripwire: docs must not RECOMMEND -vsync (mentioning it as
  # deprecated in footgun tables is fine; a code fence using it is not).
  if grep -E '^\s*ffmpeg .*-vsync ' <<<"$docs" | grep -vq 'fps_mode'; then
    finding "DRIFT: a documented command still uses deprecated -vsync (use -fps_mode)"
  fi
}

case "$MODE" in
  offline) offline_checks ;;
  live)    live_checks ;;
esac

if [[ "$findings" -eq 0 ]]; then
  emit "verify-commands ($MODE): clean"
  exit "$EXIT_OK"
fi
emit "verify-commands ($MODE): $findings finding(s)"
exit "$EXIT_DRIFT"
