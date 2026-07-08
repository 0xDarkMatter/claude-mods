#!/usr/bin/env bash
# Self-test for process-compose-ops — fully offline: no network, no download.
#
# Wraps the skill's binary-integrity verifier (scripts/verify-binary.ps1), which
# re-checks the committed process-compose.exe SHA-256 against the recorded
# EXE_HASH. Unlike the three §7 staleness scripts this verifier is PowerShell and
# platform-locked to a Windows binary, so the suite has two layers:
#   * contract / structural (run anywhere, no PowerShell host required): the .ps1
#     exists and encodes the Get-FileHash/EXE_HASH compare plus the mismatch
#     throw — proving it is a real check, not a vacuous rubber stamp;
#   * behavioural happy + negative against a temp bin/ — exercised only when a
#     PowerShell host (pwsh | powershell) is present. A dummy .exe and a
#     hand-written EXE_HASH stand in for the real binary, so no download and no
#     network ever occur. SKIP'd (suite stays green) on a PowerShell-less Linux
#     runner — the structural layer still runs.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/verify-binary.ps1"

# A PowerShell host, if any (pwsh = PowerShell 7 cross-platform; powershell =
# Windows PowerShell 5.1). Absent on most Linux CI runners.
PSHOST=""
for c in pwsh powershell; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -NoProfile -Command 'exit 0' >/dev/null 2>&1; then PSHOST="$c"; break; fi
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== process-compose-ops self-test ==="

# ── contract / structural (runs anywhere, no PowerShell host needed) ──────────
echo "-- contract --"
[[ -f "$V" ]] && ok "verify-binary.ps1 present" || no "verify-binary.ps1 present"
[[ -s "$V" ]] && ok "verify-binary.ps1 non-empty" || no "verify-binary.ps1 non-empty"
# The verifier must encode the integrity check it claims to run: a SHA-256
# compare of the binary against EXE_HASH that throws on mismatch. If these
# markers were gutted the verifier would be a vacuous rubber stamp.
vtxt="$(cat "$V")"
expect_has "computes SHA-256 of the binary" "Get-FileHash" "$vtxt"
expect_has "reads recorded EXE_HASH" "EXE_HASH" "$vtxt"
expect_has "fails loud on mismatch" "MISMATCH" "$vtxt"

# ── behavioural (happy + negative) under a PowerShell host, if present ─────────
echo "-- behavioural (${PSHOST:-no powershell host}) --"
if [[ -z "$PSHOST" ]]; then
  echo "  SKIP  happy/negative (no pwsh/powershell on this runner — structural layer above still ran)"
else
  # happy: a dummy .exe whose recorded EXE_HASH matches its actual SHA-256.
  mkdir -p "$SB/ok/bin"
  printf 'process-compose-fake-bytes' > "$SB/ok/bin/process-compose.exe"
  # sha256sum and Get-FileHash compute the identical digest; the verifier
  # compares lowercased + trimmed, so this matches what it recomputes.
  sha256sum "$SB/ok/bin/process-compose.exe" | awk '{print $1}' > "$SB/ok/bin/EXE_HASH"
  "$PSHOST" -NoProfile -File "$V" -BinDir "$SB/ok/bin" >/dev/null 2>&1
  expect_exit "matching EXE_HASH -> 0" 0 $?

  # negative: a recorded EXE_HASH that disagrees with the actual SHA-256.
  mkdir -p "$SB/bad/bin"
  printf 'process-compose-fake-bytes' > "$SB/bad/bin/process-compose.exe"
  printf '0000000000000000000000000000000000000000000000000000000000000000' > "$SB/bad/bin/EXE_HASH"
  "$PSHOST" -NoProfile -File "$V" -BinDir "$SB/bad/bin" >"$SB/neg.out" 2>&1
  rc=$?
  [[ "$rc" -ne 0 ]] && ok "mismatched EXE_HASH -> nonzero (exit $rc)" || no "mismatched EXE_HASH -> nonzero (got 0)"
  expect_has "verifier reports MISMATCH" "MISMATCH" "$(cat "$SB/neg.out")"
fi

# ── SKILL.md sanity ───────────────────────────────────────────────────────────
echo "-- SKILL.md --"
grep -q '^name: process-compose-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q 'verify-binary.ps1' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
