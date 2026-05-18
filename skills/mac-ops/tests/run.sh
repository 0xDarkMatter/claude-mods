#!/usr/bin/env bash
# mac-ops :: tests/run.sh
# Lightweight self-tests. Run from repo root:
#   bash skills/mac-ops/tests/run.sh
#
# Validates structural and output invariants WITHOUT trying to simulate
# broken macOS state. Catches regressions in:
#  - bash syntax / unbound vars / set -u trips
#  - section headers + ordering
#  - --json producing parseable NDJSON
#  - --redact masking private addrs / tailnet names
#  - --help working for every script
#  - summary block format

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

assert() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS+1))
        printf "  [PASS] %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name")
        printf "  [FAIL] %s\n" "$name"
    fi
}

contains() { local hay="$1" needle="$2"; [[ "$hay" == *"$needle"* ]]; }
not_contains() { local hay="$1" needle="$2"; [[ "$hay" != *"$needle"* ]]; }

# Skip on non-macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Skipping: mac-ops tests only run on macOS (this is $(uname -s))"
    exit 0
fi

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

echo "=== mac-ops self-tests ==="
echo "Root: $root"

# ----------------------------------------------------------------------------
echo
echo "--- Script parse + permissions ---"
# ----------------------------------------------------------------------------

for f in "$root"/scripts/*.sh; do
    name=$(basename "$f")
    # bash -n parses without executing
    if bash -n "$f" 2>/dev/null; then
        assert "parse: $name" true
    else
        assert "parse: $name" false
    fi
    # executable bit set
    if [[ -x "$f" ]]; then
        assert "executable: $name" true
    else
        assert "executable: $name" false
    fi
done

# ----------------------------------------------------------------------------
echo
echo "--- --help works for every script ---"
# ----------------------------------------------------------------------------

for f in "$root"/scripts/*.sh; do
    name=$(basename "$f")
    out=$(bash "$f" --help 2>&1)
    assert "--help: $name returns usage" contains "$out" "Usage:"
done

# ----------------------------------------------------------------------------
echo
echo "--- health-audit structural ---"
# ----------------------------------------------------------------------------

audit_out=$(bash "$root/scripts/health-audit.sh" --days 1 --quiet 2>&1)
assert "health-audit emits SUMMARY block" contains "$audit_out" "=== SUMMARY ==="
assert "health-audit shows PASS counts" contains "$audit_out" "PASS:"
assert "health-audit runs without unbound vars" not_contains "$audit_out" "unbound variable"

# ----------------------------------------------------------------------------
echo
echo "--- --json produces pure NDJSON ---"
# ----------------------------------------------------------------------------

# Capture stdout only — JSON contract is "stdout = NDJSON, stderr may have noise"
json_out=$(bash "$root/scripts/health-audit.sh" --days 1 --json 2>/dev/null)
json_lines=$(echo "$json_out" | grep -c '^{' | tr -d '\n ')
non_json=$(echo "$json_out" | grep -v '^{' | grep -c . | tr -d '\n ')
assert "--json: at least one JSON record" bash -c "[[ \"$json_lines\" -ge 1 ]]"
assert "--json: stdout is pure NDJSON (no non-JSON)" bash -c "[[ \"$non_json\" -eq 0 ]]"
assert "--json: includes summary record" contains "$json_out" '"type":"summary"'

# ----------------------------------------------------------------------------
echo
echo "--- --redact masks private addrs ---"
# ----------------------------------------------------------------------------

# Use startup-audit since it lists Adobe-style paths under /Users/...
redact_out=$(bash "$root/scripts/startup-audit.sh" --redact --quiet 2>&1)
# Should NOT contain raw 192.168.x.x or .ts.net hostnames
leaks=$(echo "$redact_out" | grep -E '\b192\.168\.[0-9]+\.[0-9]+\b' | grep -v '192.168.X.X')
assert "--redact: no 192.168.* leak in startup-audit" bash -c "[[ -z \"$leaks\" ]]"

# ----------------------------------------------------------------------------
echo
echo "--- startup-audit produces clean output ---"
# ----------------------------------------------------------------------------

startup_out=$(bash "$root/scripts/startup-audit.sh" --quiet 2>&1)
# Plutil errors should be filtered (we use || val="" pattern)
assert "startup-audit: no plutil 'Could not extract'" not_contains "$startup_out" "Could not extract value"

# ----------------------------------------------------------------------------
echo
echo "--- safe-disable-startup --list works ---"
# ----------------------------------------------------------------------------

list_out=$(bash "$root/scripts/safe-disable-startup.sh" --list 2>&1)
assert "--list returns SUMMARY" contains "$list_out" "SUMMARY"

# ----------------------------------------------------------------------------
echo
echo "--- panic-triage handles 'no panics' gracefully ---"
# ----------------------------------------------------------------------------

# Most dev Macs have no recent panics. Verify the script doesn't error.
panic_out=$(bash "$root/scripts/panic-triage.sh" --quiet 2>&1 || true)
assert "panic-triage runs without crashing" contains "$panic_out" "PANIC REPORT"

# ----------------------------------------------------------------------------
echo
echo "--- tcc-audit gracefully handles permission denial ---"
# ----------------------------------------------------------------------------

tcc_out=$(bash "$root/scripts/tcc-audit.sh" --quiet 2>&1)
# Should exit cleanly even without TCC.db read access
assert "tcc-audit reaches SUMMARY (or handles no-access path)" bash -c "echo '$tcc_out' | grep -qE 'SUMMARY|TCC.db readable'"

# ----------------------------------------------------------------------------
echo
echo "--- wake-reasons parses real pmset log ---"
# ----------------------------------------------------------------------------

wake_out=$(bash "$root/scripts/wake-reasons.sh" --since 1d --quiet 2>&1)
assert "wake-reasons reaches SUMMARY" contains "$wake_out" "SUMMARY"

# ----------------------------------------------------------------------------
echo
echo "--- spotlight-status filters system volumes ---"
# ----------------------------------------------------------------------------

spot_out=$(bash "$root/scripts/spotlight-status.sh" --quiet 2>/dev/null)
# Should NOT have "Error: unknown indexing state" leak from system vols
err_leaks=$(echo "$spot_out" | grep -c "unknown indexing state" | tr -d '\n ')
assert "spotlight-status: system-vol error filtering" bash -c "[[ \"${err_leaks:-0}\" -le 0 ]]"

# ----------------------------------------------------------------------------
echo
echo "--- All 12 scripts present ---"
# ----------------------------------------------------------------------------

expected_scripts=(
    health-audit.sh panic-triage.sh startup-audit.sh safe-disable-startup.sh
    disk-health.sh drive-dependencies.sh boot-perf.sh recover-clone.sh
    tcc-audit.sh wake-reasons.sh spotlight-status.sh storage-pressure.sh
    kext-audit.sh firewall-audit.sh network-locations.sh
    sysdiagnose-helper.sh brew-health.sh update-state.sh media-libraries.sh
    keychain-audit.sh
)
for s in "${expected_scripts[@]}"; do
    assert "script exists: $s" test -f "$root/scripts/$s"
done

# ----------------------------------------------------------------------------
echo
echo "--- All 7 reference docs present ---"
# ----------------------------------------------------------------------------

expected_refs=(
    storage-events.md recovery-patterns.md tcc-mechanics.md
    launchd-deep-dive.md panic-codes.md startup-mechanisms.md
    remote-diagnostics.md apple-silicon-specifics.md
    mac-vs-windows-ops.md
)
for r in "${expected_refs[@]}"; do
    assert "reference exists: $r" test -f "$root/references/$r"
done

# ----------------------------------------------------------------------------
echo
echo "=== TOTAL: $PASS pass, $FAIL fail ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
exit 0
