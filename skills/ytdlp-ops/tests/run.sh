#!/usr/bin/env bash
# Self-test for ytdlp-ops — fully offline: no network, no yt-dlp needed.
#
# Structural assertions (--help contract, bash -n, exit codes, offline verifier,
# asset JSON) plus the verifier's 60-day age logic exercised through its
# CM_YTDLP_INSTALLED / CM_YTDLP_LATEST test seams (which bypass yt-dlp and the
# GitHub API and disable the smoke extraction). Real --live runs belong to the
# scheduled freshness workflow only — a network blip must never fail a PR.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/check-ytdlp-version.sh"

# Pick a python that actually executes (Windows Store python3 stub exits non-zero).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== ytdlp-ops self-test ==="

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
bash -n "$V" 2>/dev/null && ok "bash -n check-ytdlp-version.sh" || no "bash -n check-ytdlp-version.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$(bash "$V" --help 2>/dev/null)"
expect_has "--help has Examples" "xamples" "$out"
expect_has "--help documents exit 7" "7" "$out"
expect_has "--help documents exit 10" "10" "$out"
bash "$V" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# ── offline structural mode ──────────────────────────────────────────────────
echo "-- offline structural --"
bash "$V" --offline >/dev/null 2>&1; expect_exit "--offline clean on shipped skill" 0 $?
out="$(bash "$V" --offline --json 2>/dev/null)"
expect_has "--offline --json envelope" '"schema": "claude-mods.ytdlp-ops.version-check/v1"' "$out"
expect_has "--offline --json zero findings" '"count": 0' "$out"

# an uncited resource must be flagged (run the verifier from a doctored copy)
cp -r "$SKILL" "$SB/copy"
printf '# orphan\n' > "$SB/copy/references/orphan.md"
bash "$SB/copy/scripts/check-ytdlp-version.sh" --offline >"$SB/orphan.out" 2>/dev/null
expect_exit "--offline flags uncited resource -> 10" 10 $?
expect_has "finding names the orphan" "orphan.md" "$(cat "$SB/orphan.out")"

# a ghost link must be flagged
cp -r "$SKILL" "$SB/ghost"
printf '\nsee [gone](references/does-not-exist.md)\n' >> "$SB/ghost/SKILL.md"
bash "$SB/ghost/scripts/check-ytdlp-version.sh" --offline >"$SB/ghost.out" 2>/dev/null
expect_exit "--offline flags ghost link -> 10" 10 $?
expect_has "finding names the missing file" "does-not-exist.md" "$(cat "$SB/ghost.out")"

# ── assets ───────────────────────────────────────────────────────────────────
echo "-- assets --"
for a in "$SKILL"/assets/*.json; do
  if [[ -n "$PYTHON" ]]; then
    "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$a" \
      >/dev/null 2>&1 && ok "asset parses: $(basename "$a")" || no "asset parses: $(basename "$a")"
  elif command -v jq >/dev/null 2>&1; then
    jq empty "$a" >/dev/null 2>&1 && ok "asset parses: $(basename "$a")" || no "asset parses: $(basename "$a")"
  else
    echo "  SKIP  asset JSON parse (no python or jq)"
  fi
done
grep -q '"schema": "claude-mods.ytdlp-ops.format-presets/v1"' "$SKILL/assets/format-presets.json" \
  && ok "format-presets schema id" || no "format-presets schema id"

# ── live mode via test seams (no network, no yt-dlp) ─────────────────────────
echo "-- live age logic (seamed) --"
CM_YTDLP_INSTALLED=2026.01.01 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live >/dev/null 2>&1
expect_exit "151 days behind -> 10" 10 $?
CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live >/dev/null 2>&1
expect_exit "in sync -> 0" 0 $?
CM_YTDLP_INSTALLED=2026.05.01 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live >/dev/null 2>&1
expect_exit "31 days behind (<=60) -> 0" 0 $?
CM_YTDLP_INSTALLED=2026.06.01.232900 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live >/dev/null 2>&1
expect_exit "nightly 4-part version parses -> 0" 0 $?

out="$(CM_YTDLP_INSTALLED=2026.01.01 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live --json 2>/dev/null)"
expect_has "seamed --json envelope" '"schema": "claude-mods.ytdlp-ops.version-check/v1"' "$out"
expect_has "seamed --json days_behind" '"days_behind": 151' "$out"
expect_has "seamed --json smoke skipped" '"smoke": "skipped"' "$out"
expect_has "seamed --json js_runtime unknown" '"js_runtime": "unknown"' "$out"
expect_has "seamed --json DRIFT finding" "DRIFT" "$out"
if [[ -n "$PYTHON" ]]; then
  printf '%s' "$out" | "$PYTHON" -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1 \
    && ok "seamed --json is valid JSON" || no "seamed --json is valid JSON"
fi

# stdout/stderr separation: data on stdout only
err="$(CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 bash "$V" --live --json 2>/dev/null >"$SB/stdout.txt"; cat "$SB/stdout.txt")"
case "$err" in
  "{ \"data\""*) ok "stdout carries only the JSON envelope";;
  *) no "stdout carries only the JSON envelope";;
esac

# ── smoke classification (seamed; fixes the freshness false-positive) ────────
echo "-- smoke classification (seamed) --"
# (a) no JS runtime on the runner = ENVIRONMENT gap, advisory skip — NEVER
#     exit 10. This is the exact false-positive that red-failed the weekly job.
out="$(CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 \
       CM_YTDLP_SMOKE_ERR='ERROR: [youtube] jNQXAC9IVRw: No supported JavaScript runtime found, please install deno' \
       bash "$V" --live --json 2>/dev/null)"; rc=$?
expect_exit "no-JS-runtime smoke -> 0 (advisory, not drift)" 0 "$rc"
expect_has "smoke marked skipped-no-jsruntime" '"smoke": "skipped-no-jsruntime"' "$out"
expect_has "js_runtime reported missing" '"js_runtime": "missing"' "$out"
case "$out" in *DRIFT*) no "no-JS-runtime must not record DRIFT";; *) ok "no-JS-runtime records no DRIFT";; esac

# (b) a genuine extractor break (JS runtime present) IS drift -> 10
CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 \
  CM_YTDLP_SMOKE_ERR='ERROR: unable to extract player response; please report this issue' \
  bash "$V" --live >/dev/null 2>&1
expect_exit "real extractor break -> 10 (drift)" 10 $?

# (c) IP bot-challenge / 429 = advisory skip, not drift
CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 \
  CM_YTDLP_SMOKE_ERR='ERROR: HTTP Error 429: Too Many Requests' \
  bash "$V" --live >/dev/null 2>&1
expect_exit "bot-challenge/429 -> 0 (advisory)" 0 $?

# (d) smoke success (empty seam) -> pass, exit 0
out="$(CM_YTDLP_INSTALLED=2026.06.01 CM_YTDLP_LATEST=2026.06.01 CM_YTDLP_SMOKE_ERR='' \
       bash "$V" --live --json 2>/dev/null)"; rc=$?
expect_exit "smoke success -> 0" 0 "$rc"
expect_has "smoke marked pass" '"smoke": "pass"' "$out"

# ── SKILL.md sanity ──────────────────────────────────────────────────────────
echo "-- SKILL.md --"
grep -q '^name: ytdlp-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q 'related-skills: ffmpeg-ops' "$SKILL/SKILL.md" && ok "ffmpeg-ops cross-link" || no "ffmpeg-ops cross-link"
grep -q 'check-ytdlp-version.sh' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
