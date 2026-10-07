#!/usr/bin/env bash
# mac-ops :: tests/run.sh
# Lightweight self-tests. Run from repo root:
#   bash skills/mac-ops/tests/run.sh
#
# The fail-closed block runs on EVERY OS: PATH shims stand in for diskutil,
# mount, df, log and tmutil, and fake sub-scripts stand in for quickrun's
# audits, to prove a broken producer or a crashed audit never reads as a pass.
#
# The rest runs on macOS only and validates structural and output invariants
# WITHOUT trying to simulate broken macOS state. Catches regressions in:
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

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

echo "=== mac-ops self-tests ==="
echo "Root: $root"

# ----------------------------------------------------------------------------
echo
echo "--- fail-closed: shimmed tools + fake audits (every OS) ---"
# ----------------------------------------------------------------------------
# A producer that fails (diskutil, mount, df) or an audit that crashes must
# surface as FAIL/WARN, never as the silent pass it used to be. Shims first on
# PATH make the failure deterministic on any OS, macOS included.

FC="$(mktemp -d)"; trap 'rm -rf "$FC"' EXIT
mkdir -p "$FC/bin"
cat > "$FC/bin/diskutil" <<'EOF'
#!/bin/sh
case "$1" in
    list)
        [ -n "${FAKE_LIST_FAIL:-}" ] && { echo "diskutil: simulated failure" >&2; exit 1; }
        [ -n "${FAKE_LIST_EMPTY:-}" ] && exit 0
        printf '/dev/disk0 (internal, physical):\n   0:  GUID_partition_scheme  *500.3 GB  disk0\n' ;;
    info)
        [ -n "${FAKE_INFO_FAIL:-}" ] && exit 1
        printf '   Device / Media Name:  FAKE SSD\n   SMART Status:         %s\n' "${FAKE_SMART:-Verified}" ;;
esac
exit 0
EOF
cat > "$FC/bin/mount" <<'EOF'
#!/bin/sh
[ -n "${FAKE_MOUNT_FAIL:-}" ] && { echo "mount: simulated failure" >&2; exit 1; }
echo '/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)'
EOF
cat > "$FC/bin/df" <<'EOF'
#!/bin/sh
[ -n "${FAKE_DF_FAIL:-}" ] && { echo "df: simulated failure" >&2; exit 1; }
echo 'Filesystem      Size   Used  Avail Capacity  Mounted on'
echo '/dev/disk3s1s1  460Gi  400Gi 60Gi  87%       /'
EOF
cat > "$FC/bin/tmutil" <<'EOF'
#!/bin/sh
i=0; while [ "$i" -lt "${FAKE_SNAPS:-0}" ]; do echo "com.apple.TimeMachine.snap-$i.local"; i=$((i+1)); done
EOF
printf '#!/bin/sh\nexit 0\n' > "$FC/bin/log"
chmod +x "$FC/bin/"*

# dh [VAR=value...]: disk-health.sh under the shims; its output lands in $dh_out.
dh() { dh_out=$(env "$@" PATH="$FC/bin:$PATH" bash "$root/scripts/disk-health.sh" --quiet 2>&1); }

dh FAKE_SMART=Failing
assert "disk-health: harness reaches SMART (a Failing disk is reported)" contains "$dh_out" "[FAIL] /dev/disk0 SMART status"
dh FAKE_LIST_FAIL=1
assert "disk-health: a failed diskutil list is a FAIL, not a silent pass" contains "$dh_out" "[FAIL] Disk listing"
dh FAKE_LIST_EMPTY=1
assert "disk-health: a disk list naming no disk is a FAIL" contains "$dh_out" "[FAIL] Disk listing"
dh FAKE_INFO_FAIL=1
assert "disk-health: unreadable disk info is a SMART FAIL, not a WARN" contains "$dh_out" "[FAIL] /dev/disk0 SMART status"
dh FAKE_MOUNT_FAIL=1
assert "disk-health: a failed mount listing warns snapshots unchecked" contains "$dh_out" "[WARN] Snapshots :: NOT checked"
assert "disk-health: a failed mount listing warns free space unchecked" contains "$dh_out" "[WARN] Free space :: NOT checked"
dh FAKE_DF_FAIL=1
assert "disk-health: a failed df is not '100% free'" not_contains "$dh_out" "[PASS] Free space"
assert "disk-health: a failed df warns free space unchecked" contains "$dh_out" "[WARN] Free space on / :: NOT checked"
dh FAKE_SNAPS=25
assert "disk-health: a snapshot WARN reaches the SUMMARY count" contains "$dh_out" "WARN: 1    INFO:"

# quickrun runs its audits from its own directory, so a copy beside fake audits
# exercises the real run_subscript. Each fake prints one PASS and a SUMMARY;
# FAKE_CRASH dies before the SUMMARY, FAKE_LATE_EXIT exits 2 after it.
mkdir -p "$FC/qr"
cp "$root/scripts/quickrun.sh" "$FC/qr/"
cp -R "$root/scripts/_lib" "$FC/qr/"
for s in health-audit startup-audit storage-pressure wake-reasons tcc-audit; do
    cat > "$FC/qr/$s.sh" <<'EOF'
#!/usr/bin/env bash
me="$(basename "$0")"
echo "[PASS] $me fake check"
[[ "${FAKE_CRASH:-}" == "$me" ]] && { echo "$me: line 9: simulated crash" >&2; exit 1; }
echo
echo "=== SUMMARY ==="
echo "  PASS: 1    FAIL: 0    WARN: 0    INFO: 0"
echo "  No failures."
[[ "${FAKE_LATE_EXIT:-}" == "$me" ]] && exit 2
exit 0
EOF
done
qr() { qr_out=$(env "$@" NO_PANEL=1 bash "$FC/qr/quickrun.sh" 2>&1); }

qr
assert "quickrun: five clean audits read clean" contains "$qr_out" "Aggregate: PASS 5    FAIL 0"
qr FAKE_CRASH=storage-pressure.sh
assert "quickrun: an audit that crashed before its SUMMARY is a FAIL" contains "$qr_out" "FAIL 1"
assert "quickrun: the crash FAIL names the script" contains "$qr_out" "storage-pressure.sh failed (exit 1, no SUMMARY)"
qr FAKE_LATE_EXIT=wake-reasons.sh
assert "quickrun: an audit exiting non-zero after its SUMMARY is a FAIL" contains "$qr_out" "wake-reasons.sh failed (exit 2)"

# Everything below drives the real macOS tools.
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo
    echo "Skipping the rest: it needs macOS (this is $(uname -s))"
    echo "=== TOTAL: $PASS pass, $FAIL fail ==="
    [[ "$FAIL" -eq 0 ]] && exit 0
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi

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
    keychain-audit.sh bluetooth-audit.sh font-audit.sh quickrun.sh
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
    mac-vs-windows-ops.md worked-examples.md
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
