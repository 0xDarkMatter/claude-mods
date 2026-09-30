#!/usr/bin/env bash
# Self-test for windows-ops — terminal-design adoption + (where pwsh exists)
# runtime ASCII purity of the shared framing.
#
# Three tiers, each gated on what it actually needs:
#   static   grep-level structural checks            — run everywhere
#   framing  common.ps1 output under TERM_ASCII etc.  — any PowerShell
#   runtime  executing the scripts themselves         — Windows PowerShell only
# The runtime tier drives robocopy, CIM and Windows process ancestry, so it is
# gated on the PowerShell host reporting Win32NT, NOT on `pwsh` being on PATH:
# GitHub's Linux runners ship pwsh, and there those scripts fail for reasons
# unrelated to the code under test (wrong exit codes, no parent-PID chain).
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or a tier skipped), 1 a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
COMMON="$SCRIPTS/_lib/common.ps1"
TERMPS1="$SKILL/../_lib/term.ps1"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "=== windows-ops self-test ==="

# ── static: term.ps1 adoption (the lever for every script via common.ps1) ──
echo "-- terminal design system --"
grep -q 'term\.ps1' "$COMMON" && ok "common.ps1 sources shared term.ps1" || no "common.ps1 does not source term.ps1"
[ -f "$TERMPS1" ] && ok "term.ps1 present" || no "term.ps1 missing at $TERMPS1"
# Framing routes through term.ps1's Get-TermColor, not hand-rolled host coloring.
grep -q 'Get-TermColor' "$COMMON" && ok "common.ps1 framing uses Get-TermColor" || no "common.ps1 does not use Get-TermColor"

# ── dynamic: needs PowerShell; skip cleanly where absent ───────────────────
PWSH=""
for c in pwsh powershell; do command -v "$c" >/dev/null 2>&1 && { PWSH="$c"; break; }; done
if [ -z "$PWSH" ]; then
  echo "  (pwsh not found — skipping dynamic PowerShell checks)"
  echo "=== $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# Ask the interpreter that will run the scripts, not uname: [Environment]::
# OSVersion.Platform exists in both Windows PowerShell 5.1 and pwsh 7 ($IsWindows
# does not exist in 5.1). It prints "Unix" on Linux/macOS. The CR strip matters
# because Windows pwsh ends its output with CRLF.
ONWIN=""
[ "$("$PWSH" -NoProfile -Command '[Environment]::OSVersion.Platform' 2>/dev/null | tr -d '\r')" = "Win32NT" ] && ONWIN=1
[ -n "$ONWIN" ] || echo "  (PowerShell is not on Windows — skipping script runtime checks)"
# Never skip blind: on a Windows bash (Git Bash / MSYS / Cygwin) a probe that did
# not answer Win32NT is a broken probe, and silently skipping would let the whole
# runtime tier pass without running.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) [ -n "$ONWIN" ] && ok "platform probe reports Win32NT on a Windows host" \
                          || no "Windows host, but the PowerShell platform probe did not report Win32NT" ;;
esac

# Resolve a path PowerShell can open (convert MSYS -> Windows when needed).
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
WCOMMON="$(winpath "$COMMON")"

# common.ps1 framing is ASCII-pure under TERM_ASCII=1 FORCE_COLOR=1 (principle #3).
out="$(TERM_ASCII=1 FORCE_COLOR=1 "$PWSH" -NoProfile -Command ". '$WCOMMON'; Write-Section 'DISK'; Write-Log PASS 'ok'; Write-Log FAIL 'bad'; Write-Log WARN 'hot'" 2>&1)"
if printf '%s' "$out" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "common.ps1 framing emits non-ASCII under TERM_ASCII=1"
else ok "common.ps1 framing pure ASCII under TERM_ASCII=1"; fi
# Color is applied under FORCE_COLOR (ESC present).
cout="$(FORCE_COLOR=1 "$PWSH" -NoProfile -Command ". '$WCOMMON'; Write-Log PASS 'ok'" 2>&1)"
case "$cout" in *$'\033'*) ok "common.ps1 colorizes under FORCE_COLOR";; *) no "common.ps1 did not colorize under FORCE_COLOR";; esac
# The [TAG] text stays literal/greppable (color is amplification, not the signal).
case "$cout" in *'[PASS]'*) ok "common.ps1 keeps the [PASS] tag literal";; *) no "common.ps1 lost the [PASS] tag";; esac

# ── copy-tree: non-destructive default + guard rails ──────────────────────────
# The whole point of the Copy/Rescue/Mirror split is that the DEFAULT never
# deletes. A regression here silently turns a copy into a mass deletion, so it
# is asserted structurally rather than left to review.
echo "-- copy-tree --"
CT="$SCRIPTS/copy-tree.ps1"
[ -f "$CT" ] && ok "copy-tree.ps1 present" || no "copy-tree.ps1 missing"
grep -q "Mode = 'Copy'" "$CT" && ok "default mode is Copy (additive)" || no "default mode is not Copy"
# /MIR must be reachable ONLY through the Mirror preset.
mir_lines="$(grep -c "'/MIR'" "$CT" || true)"
[ "$mir_lines" = "1" ] && ok "/MIR appears once (Mirror preset only)" || no "/MIR appears $mir_lines times — expected 1"
grep -q "Mirror = \$true" "$CT" && ok "Mirror preset flags destructive mode" || no "Mirror preset missing"
# Every mode must pin /R and /W — robocopy's defaults (/R:1000000 /W:30) look
# like a hang on the first locked file.
grep -q '"/R:\$retries"' "$CT" && ok "retries pinned explicitly" || no "retries not pinned"
grep -q '"/W:\$wait"' "$CT" && ok "wait pinned explicitly" || no "wait not pinned"
# Partial (some files failed) must stay distinguishable from fatal.
grep -q 'exit 10' "$CT" && ok "partial failure exits 10, not 1" || no "partial failure does not exit 10"
# Failed-file extraction needs the reason line, which robocopy puts AFTER the
# ERROR line — -Context 0,1 is load-bearing, not cosmetic.
grep -q 'Context 0,1' "$CT" && ok "error extraction captures the reason line" || no "error extraction drops the reason line"
grep -q 'Group-Object path' "$CT" && ok "failures deduped per file (retries log twice)" || no "failures not deduped"

if [ -n "$ONWIN" ]; then
  WCT="$(winpath "$CT")"
  # Guard rails, exercised for real: usage and not-found must not be exit 0.
  "$PWSH" -NoProfile -File "$WCT" >/dev/null 2>&1; rc=$?
  [ "$rc" = "2" ] && ok "no args -> exit 2 (usage)" || no "no args -> exit $rc, expected 2"
  "$PWSH" -NoProfile -File "$WCT" "$(winpath "$HERE")/__nope__" "$(winpath "$HERE")/__out__" >/dev/null 2>&1; rc=$?
  [ "$rc" = "3" ] && ok "missing source -> exit 3" || no "missing source -> exit $rc, expected 3"
fi

# ── rescue-image / extract-image: Tier 2 tooling ──────────────────────────────
# These wrap external binaries that may be absent, so the structural assertions
# below carry most of the weight — they encode the two bugs that cost real hours.
echo "-- tier 2 imaging --"
RI="$SCRIPTS/rescue-image.ps1"
XI="$SCRIPTS/extract-image.ps1"
[ -f "$RI" ] && ok "rescue-image.ps1 present" || no "rescue-image.ps1 missing"
[ -f "$XI" ] && ok "extract-image.ps1 present" || no "extract-image.ps1 missing"

# Excludes MUST be -xr! with bare names. The '*\name\*' form matches nothing at
# the image root, which is exactly where the junk dirs live.
grep -q '\-xr!\$e' "$XI" && ok "extract excludes use -xr! (recursive)" || no "extract excludes not -xr!"
# Strip comments first — the LANDMINE note documents the bad form on purpose,
# and matching it there would fail the test for saying the right thing.
if grep -v '^\s*#' "$XI" | grep -q "'\*\\\\.*\\\\\*'"; then
  no "extract still has a '*\\name\\*' exclude pattern in code"
else ok "no wildcard-wrapped exclude patterns in code"; fi

# Progress must never be measured by walking the destination tree.
grep -q 'AvailableFreeSpace' "$XI" && ok "extract measures progress O(1) via free space" || no "extract lost the O(1) progress metric"
grep -q 'Get-ChildItem .*-Recurse' "$XI" && no "extract walks the destination tree (does not scale)" || ok "extract does not walk the destination tree"

# Supervisors must not capture a child's stream (blocks after the child exits).
for f in "$RI" "$XI"; do
  n="$(basename "$f")"
  grep -q 'Start-Process' "$f" && ok "$n launches children via Start-Process" || no "$n does not use Start-Process"
  grep -qi 'watchdog' "$f" && ok "$n has a stall watchdog" || no "$n has no watchdog"
done

# Agnostic: no machine-specific paths or identifiers may ship in the skill.
if grep -qiE 'X:\\\\Tools|OLDDATA|VeraCrypt|HGST|rescue-diag' "$RI" "$XI"; then
  no "tier-2 scripts contain machine-specific references"
else ok "tier-2 scripts are environment-agnostic"; fi

if [ -n "$ONWIN" ]; then
  for f in "$RI" "$XI"; do
    n="$(basename "$f")"
    "$PWSH" -NoProfile -File "$(winpath "$f")" >/dev/null 2>&1; rc=$?
    [ "$rc" = "2" ] && ok "$n no args -> exit 2 (usage)" || no "$n no args -> exit $rc, expected 2"
  done
fi

# -- process-triage: steady-state runaway/orphan/stale triage --------------
# Two invariants carry real safety weight and are asserted structurally rather
# than left to review:
#   1. the script NEVER terminates anything (it reports; the caller kills), and
#   2. it resolves this session's own ancestry and marks it protected, so a
#      caller cannot be walked into killing the shell reading the output.
# Both were the difference between a clean cleanup and ending the session that
# was doing it (2026-08-30).
echo "-- process-triage --"
PT="$SCRIPTS/process-triage.ps1"
[ -f "$PT" ] && ok "process-triage.ps1 present" || no "process-triage.ps1 missing"

# Invariant 1: report-only. Any termination cmdlet here is a contract break.
if grep -nE '(^|[^-])\b(Stop-Process|taskkill|\.Kill\(\))' "$PT" >/dev/null 2>&1; then
  no "process-triage.ps1 can terminate processes (must be report-only)"
else ok "process-triage.ps1 never terminates (report-only contract)"; fi

# Invariant 2: self-ancestry guard exists and is wired to the output.
grep -q 'selfChain' "$PT" && ok "self-ancestry chain computed" || no "no self-ancestry chain"
grep -q 'protected' "$PT" && ok "rows carry a protected flag" || no "no protected flag on rows"
# The chain must be built BEFORE either reporting mode can run, or a mode could
# emit rows with no protection resolved.
awk '/selfChain = New-Object/{c=NR} /TREE MODE/{t=NR} END{exit !(c && t && c<t)}' "$PT" \
  && ok "self-ancestry resolved before any reporting path" \
  || no "self-ancestry resolved after a reporting path"

grep -q 'EXAMPLES' "$PT" && ok "help includes EXAMPLES section" || no "help has no EXAMPLES section"
grep -q 'claude-mods.windows-ops.process-triage/v1' "$PT" && ok "JSON envelope declares a schema" || no "no schema in JSON envelope"
grep -q 'exit 10' "$PT" && ok "findings exit 10 (domain signal)" || no "findings do not exit 10"

if [ -n "$ONWIN" ]; then
  WPT="$(winpath "$PT")"
  "$PWSH" -NoProfile -File "$WPT" -Help >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && ok "-Help exits 0" || no "-Help exits $rc, expected 0"
  "$PWSH" -NoProfile -File "$WPT" -Help 2>/dev/null | grep -q 'EXAMPLES' \
    && ok "-Help prints EXAMPLES to stdout" || no "-Help does not print EXAMPLES to stdout"
  "$PWSH" -NoProfile -File "$WPT" -Sample 1 >/dev/null 2>&1; rc=$?
  [ "$rc" = "2" ] && ok "-Sample below floor -> exit 2" || no "-Sample 1 -> exit $rc, expected 2"
  "$PWSH" -NoProfile -File "$WPT" -Threshold 99999 >/dev/null 2>&1; rc=$?
  [ "$rc" = "2" ] && ok "-Threshold out of range -> exit 2" || no "-Threshold 99999 -> exit $rc, expected 2"
  "$PWSH" -NoProfile -File "$WPT" -Tree 999999 >/dev/null 2>&1; rc=$?
  [ "$rc" = "3" ] && ok "-Tree on absent PID -> exit 3" || no "-Tree 999999 -> exit $rc, expected 3"

  # Happy path (test floor): -Tree on the CALLING process runs and emits valid
  # JSON. Invoking with & keeps $PID the same process, so the script's own
  # ancestry walk must mark that row protected — the guard, proven at runtime.
  jout="$("$PWSH" -NoProfile -Command "& '$WPT' -Tree \$PID -Json -Quiet" 2>/dev/null)"
  if printf '%s' "$jout" | grep -q '"schema":"claude-mods.windows-ops.process-triage/v1"'; then
    ok "-Tree emits a valid JSON envelope"
  else no "-Tree JSON envelope missing or malformed"; fi
  if printf '%s' "$jout" | grep -q '"protected":true'; then
    ok "self PID marked protected=true at runtime"
  else no "self PID NOT marked protected at runtime (safety guard broken)"; fi
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
