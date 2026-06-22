#!/usr/bin/env bash
# Staleness verifier for ytdlp-ops — offline structural + live version/extractor drift.
#
# --offline (default): structural integrity, NO network and no yt-dlp needed.
#   Assets parse as JSON, every shipped reference/script/asset is cited from
#   SKILL.md, and every relative resource link in SKILL.md resolves.
#   Runs in PR CI; may block.
# --live: is the INSTALLED yt-dlp still trustworthy, and do our docs still
#   match it? Three checks: (1) version age — fetches the latest release tag
#   from the GitHub API (yt-dlp versions are dates); >60 days behind = drift
#   (exit 10). (2) flag drift — every core flag the skill documents must still
#   exist in `yt-dlp --help`; renamed/removed = drift. (3) a metadata-only
#   smoke extraction (--simulate; nothing downloaded); failure while the API
#   was demonstrably reachable = drift, EXCEPT an IP bot-challenge/429 which is
#   classified "blocked" and only warns (datacenter IPs hit this). Network/API/
#   yt-dlp unavailable = exit 7 (advisory — the scheduled workflow skips,
#   never blocks a PR).
#
# Usage:   check-ytdlp-version.sh [--offline | --live] [--no-smoke] [--json] [-q]
# Input:   none (inspects the skill's own files; --live also yt-dlp + GitHub API).
#          Test seams: CM_YTDLP_INSTALLED / CM_YTDLP_LATEST (version strings,
#          e.g. 2026.05.31) bypass yt-dlp/network and imply --no-smoke.
# Output:  stdout = findings ("DRIFT:"/"STRUCT:" lines), or with --json one
#          envelope (schema claude-mods.ytdlp-ops.version-check/v1)
# Stderr:  progress, warnings
# Exit:    0 clean, 2 usage, 7 network/API/yt-dlp unavailable (--live; advisory),
#          10 drift (>60 days behind latest, smoke failed, or structural finding)
#
# Examples:
#   check-ytdlp-version.sh --offline
#   check-ytdlp-version.sh --live
#   check-ytdlp-version.sh --live --json | jq '.data.days_behind'
set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_UNAVAILABLE=7; EXIT_DRIFT=10
MAX_AGE_DAYS=60
RELEASES_API="https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
# "Me at the zoo" — the first video ever uploaded to YouTube; the most
# deletion-proof target that exists (metadata-only probe, nothing downloaded).
SMOKE_URL="https://www.youtube.com/watch?v=jNQXAC9IVRw"

MODE="offline"; QUIET=0; JSON=0; SMOKE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)  MODE="offline" ;;
    --live)     MODE="live" ;;
    --no-smoke) SMOKE=0 ;;
    --json)     JSON=1 ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help)  awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit "$EXIT_OK" ;;
    *) echo "ERROR: unknown argument: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
done

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"

FINDINGS=()
INSTALLED=""; LATEST=""; DAYS_BEHIND=""; SMOKE_RESULT="skipped"; JS_RUNTIME="unknown"
emit()    { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$1" >&2; }
finding() { FINDINGS+=("$1"); }

# Pick a working python for JSON/date work (Windows Store stub exits non-zero).
PYTHON=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

# 2026.5.31 or 2026.05.31.232914 (nightly) -> 2026-05-31; empty on parse failure.
norm_date() {
  local v y m d
  v="$(printf '%s' "$1" | cut -d. -f1-3)"
  IFS=. read -r y m d <<<"$v"
  [[ "${y:-}" =~ ^[0-9]{4}$ && "${m:-}" =~ ^[0-9]{1,2}$ && "${d:-}" =~ ^[0-9]{1,2}$ ]] || return 1
  printf '%04d-%02d-%02d' "$((10#$y))" "$((10#$m))" "$((10#$d))"
}

# days from $1 (older, ISO) to $2 (newer, ISO); empty if no date backend exists.
days_between() {
  if date -d "2020-01-01" +%s >/dev/null 2>&1; then
    echo $(( ( $(date -d "$2" +%s) - $(date -d "$1" +%s) ) / 86400 ))
  elif [[ -n "$PYTHON" ]]; then
    "$PYTHON" -c "import sys,datetime as dt; a,b=sys.argv[1:3]; print((dt.date.fromisoformat(b)-dt.date.fromisoformat(a)).days)" "$1" "$2" 2>/dev/null
  fi
}

# ── offline: structural ──────────────────────────────────────────────────────
offline_checks() {
  emit "== check-ytdlp-version --offline (structural)"
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

  # 2. every shipped resource is cited from SKILL.md (dead-weight check)
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
  while IFS= read -r path; do
    [[ -e "$SKILL_DIR/$path" ]] \
      || finding "STRUCT: SKILL.md links to missing file: $path"
  done < <(grep -oE '\]\((references|assets|scripts|tests)/[^)#]+\)' "$SKILL_MD" \
           | sed -E 's/^\]\(//; s/\)$//' | sort -u)
}

# ── live: installed yt-dlp vs latest release + smoke extraction ─────────────
unavailable() { # $1 = human reason
  echo "$1" >&2
  if [[ "$JSON" -eq 1 ]]; then
    printf '{ "error": { "code": "UNAVAILABLE", "message": "%s", "details": {} } }\n' "$1"
  fi
  exit "$EXIT_UNAVAILABLE"
}

live_checks() {
  emit "== check-ytdlp-version --live (version age + extractor smoke)"
  local seamed=0
  [[ -n "${CM_YTDLP_INSTALLED:-}" && -n "${CM_YTDLP_LATEST:-}" ]] && { seamed=1; SMOKE=0; }
  # Test seam: CM_YTDLP_SMOKE_ERR injects a smoke failure (empty = success)
  # without yt-dlp/network, so the classifier below is exercised in CI.
  [[ -n "${CM_YTDLP_SMOKE_ERR+x}" ]] && SMOKE=1

  # installed version
  if [[ "$seamed" -eq 1 ]]; then
    INSTALLED="$CM_YTDLP_INSTALLED"
  elif command -v yt-dlp >/dev/null 2>&1; then
    INSTALLED="$(yt-dlp --version 2>/dev/null | head -1)"
  fi
  [[ -n "$INSTALLED" ]] \
    || unavailable "yt-dlp not on PATH — install: uv tool install yt-dlp (advisory, not a failure)"

  # latest release tag from the GitHub API
  if [[ "$seamed" -eq 1 ]]; then
    LATEST="$CM_YTDLP_LATEST"
  else
    command -v curl >/dev/null 2>&1 \
      || unavailable "curl not available — cannot query the GitHub releases API"
    local body
    body="$(curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" \
              ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
              "$RELEASES_API" 2>/dev/null)" \
      || unavailable "GitHub releases API unreachable/rate-limited (advisory, not a failure)"
    if command -v jq >/dev/null 2>&1; then
      LATEST="$(jq -r '.tag_name // empty' <<<"$body" 2>/dev/null)"
    else
      LATEST="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$body" \
                | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
    fi
    [[ -n "$LATEST" ]] || unavailable "could not parse tag_name from the GitHub API response"
  fi
  emit "   installed: $INSTALLED   latest: $LATEST"

  # version age (yt-dlp versions ARE dates)
  local inst_d latest_d
  if inst_d="$(norm_date "$INSTALLED")" && latest_d="$(norm_date "$LATEST")"; then
    DAYS_BEHIND="$(days_between "$inst_d" "$latest_d")"
    if [[ -z "$DAYS_BEHIND" ]]; then
      emit "   warn: no GNU date or python available — age check skipped"
    elif [[ "$DAYS_BEHIND" -gt "$MAX_AGE_DAYS" ]]; then
      finding "DRIFT: installed yt-dlp $INSTALLED is $DAYS_BEHIND days behind latest $LATEST (>$MAX_AGE_DAYS) — extractors likely broken; update"
    fi
  else
    emit "   warn: unparseable version string(s) — age check skipped"
  fi

  # flag drift: every core flag the skill documents must still exist in this
  # yt-dlp's --help — a rename/removal upstream means our docs rotted.
  # (Skipped in seamed mode: no real yt-dlp to interrogate.)
  if [[ "$seamed" -eq 0 ]]; then
    local help_text
    help_text="$(yt-dlp --help 2>/dev/null)"
    local core_flags=(--download-sections --force-keyframes-at-cuts
      --download-archive --break-on-existing --lazy-playlist
      --cookies-from-browser --sponsorblock-mark --sponsorblock-remove
      --remux-video --recode-video --write-subs --write-auto-subs --sub-langs
      --convert-subs --embed-subs --embed-metadata --embed-thumbnail
      --embed-chapters --restrict-filenames --concurrent-fragments
      --limit-rate --sleep-requests --sleep-interval --merge-output-format
      --extract-audio --audio-format --flat-playlist --playlist-items
      --match-filters --simulate --impersonate --live-from-start
      --wait-for-video --print --paths)
    local fl
    for fl in "${core_flags[@]}"; do
      grep -q -- "$fl" <<<"$help_text" \
        || finding "DRIFT: documented flag '$fl' unknown to installed yt-dlp (renamed/removed upstream?)"
    done
  fi

  # metadata-only smoke extraction (only when the API was reachable, so a
  # failure here is the extractor, not the network)
  if [[ "$SMOKE" -eq 1 ]]; then
    # NOTE: no --no-warnings here — the JS-runtime detection below greps the
    # "No supported JavaScript runtime" WARNING from captured stderr.
    local smoke_err smoke_rc
    if [[ -n "${CM_YTDLP_SMOKE_ERR+x}" ]]; then
      smoke_err="$CM_YTDLP_SMOKE_ERR"
      [[ -z "$smoke_err" ]] && smoke_rc=0 || smoke_rc=1
    else
      local smoke_cmd=(yt-dlp --simulate --no-playlist --socket-timeout 15 "$SMOKE_URL")
      command -v timeout >/dev/null 2>&1 && smoke_cmd=(timeout 90 "${smoke_cmd[@]}")
      smoke_err="$("${smoke_cmd[@]}" 2>&1 >/dev/null)"; smoke_rc=$?
    fi
    if [[ "$smoke_rc" -eq 0 ]]; then
      SMOKE_RESULT="pass"
      JS_RUNTIME="present"
    elif grep -qiE "confirm you'?re not a bot|HTTP Error 429|too many requests" <<<"$smoke_err"; then
      # IP-reputation challenge (datacenter IPs hit this), NOT extractor drift —
      # treating it as drift would make the scheduled job flaky-red (§7).
      SMOKE_RESULT="blocked"
      emit "   warn: smoke extraction blocked by an IP challenge (bot-check/429) — not drift; skipped"
    elif grep -q "No supported JavaScript runtime" <<<"$smoke_err"; then
      # YouTube now requires a JS runtime (deno/node) to extract formats. On a
      # runner without one the extraction fails for an ENVIRONMENT reason, not
      # extractor drift — treat it like the IP challenge: advisory skip, never
      # exit-10 (§7). Install deno on the runner (or pass --js-runtimes node) to
      # give the smoke test teeth. This was the false-positive that red-failed
      # the weekly freshness job.
      SMOKE_RESULT="skipped-no-jsruntime"
      JS_RUNTIME="missing"
      emit "   warn: no JS runtime (deno/node) — smoke extraction skipped, not drift; install deno or pass --js-runtimes node"
    else
      SMOKE_RESULT="fail"
      finding "DRIFT: smoke extraction failed ($SMOKE_URL) with the network reachable — extractor broken; update yt-dlp"
    fi
    # Smoke PASSED but yt-dlp still warned about a missing JS runtime: formats
    # were thinned. Record the environment state without treating it as drift.
    if [[ "$SMOKE_RESULT" == "pass" ]] && grep -q "No supported JavaScript runtime" <<<"$smoke_err"; then
      JS_RUNTIME="missing"
      emit "   warn: no JS runtime (deno/node) — YouTube formats reduced; install deno or use --js-runtimes node"
    fi
  fi
}

case "$MODE" in
  offline) offline_checks ;;
  live)    live_checks ;;
esac

if [[ "$JSON" -eq 1 ]]; then
  flist=""
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    esc="${f//\\/\\\\}"; esc="${esc//\"/\\\"}"
    flist="${flist:+$flist, }\"$esc\""
  done
  printf '{ "data": { "mode": "%s", "installed": %s, "latest": %s, "days_behind": %s, "smoke": "%s", "js_runtime": "%s", "findings": [%s] }, "meta": { "count": %d, "schema": "claude-mods.ytdlp-ops.version-check/v1" } }\n' \
    "$MODE" \
    "$([[ -n "$INSTALLED" ]] && printf '"%s"' "$INSTALLED" || printf 'null')" \
    "$([[ -n "$LATEST" ]] && printf '"%s"' "$LATEST" || printf 'null')" \
    "${DAYS_BEHIND:-null}" \
    "$SMOKE_RESULT" "$JS_RUNTIME" "$flist" "${#FINDINGS[@]}"
else
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do printf '%s\n' "$f"; done
fi

if [[ "${#FINDINGS[@]}" -eq 0 ]]; then
  emit "check-ytdlp-version ($MODE): clean"
  exit "$EXIT_OK"
fi
emit "check-ytdlp-version ($MODE): ${#FINDINGS[@]} finding(s)"
exit "$EXIT_DRIFT"
