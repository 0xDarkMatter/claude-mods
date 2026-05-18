#!/usr/bin/env bash
# mac-ops :: disk-health.sh
# Per-disk / per-volume deep dive. Maps APFS containers, surfaces IO errors
# from the unified log, reports SMART status (where macOS exposes it), and
# checks snapshot bloat.
#
# Usage:
#   scripts/disk-health.sh                            # all disks
#   scripts/disk-health.sh -d disk2                   # by /dev/diskN
#   scripts/disk-health.sh -v /Volumes/Foo            # by mount point
#   scripts/disk-health.sh -v /                       # boot volume

set -u

TARGET_DEV=""
TARGET_VOL=""
DAYS=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--disk) TARGET_DEV="$2"; shift 2 ;;
        -v|--volume) TARGET_VOL="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  -d, --disk diskN          Inspect specific device (e.g. disk2)
  -v, --volume PATH         Inspect by mount point (e.g. / or /Volumes/X)
  --days N                  Log lookback window (default: 30)
  --json, --redact, --quiet, --verbose   Standard flags

Output sections:
  1. Device summary (model, size, bus, SMART status)
  2. APFS container + volume layout (if APFS)
  3. IO errors via unified log (last --days)
  4. Snapshot bloat (Time Machine local snapshots)
  5. Free space / purgeable space breakdown
  6. Mount + fsck verification status
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# Resolve target → /dev/diskN
resolve_target() {
    if [[ -n "$TARGET_DEV" ]]; then
        echo "${TARGET_DEV#/dev/}"
        return
    fi
    if [[ -n "$TARGET_VOL" ]]; then
        diskutil info "$TARGET_VOL" 2>/dev/null | awk -F': *' '/Device Identifier/{print $2; exit}'
        return
    fi
    # No target — return empty (we'll iterate all)
    echo ""
}

disk_id=$(resolve_target)

# ----------------------------------------------------------------------------
section "1. DEVICE SUMMARY"
# ----------------------------------------------------------------------------
if [[ -n "$disk_id" ]]; then
    targets=("$disk_id")
else
    # All physical disks (not partitions / synthesized)
    mapfile -t targets < <(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+ /{gsub("/dev/",""); print $1}' | sort -u | head -20)
fi

for d in "${targets[@]}"; do
    [[ -z "$d" ]] && continue
    info=$(diskutil info "$d" 2>/dev/null)
    [[ -z "$info" ]] && { log_warn "diskutil info $d" "no data"; continue; }

    model=$(echo "$info" | awk -F': *' '/Device \/ Media Name/{print $2; exit}')
    bus=$(echo "$info" | awk -F': *' '/Protocol/{print $2; exit}')
    size=$(echo "$info" | awk -F': *' '/Disk Size/{print $2; exit}')
    smart=$(echo "$info" | awk -F': *' '/SMART Status/{print $2; exit}')
    internal=$(echo "$info" | awk -F': *' '/Device Location/{print $2; exit}')

    note "  /dev/$d"
    note "    Model:     ${model:-(unknown)}"
    note "    Bus:       ${bus:-?}    Location: ${internal:-?}"
    note "    Size:      ${size:-?}"

    case "$smart" in
        Verified)
            log_pass "/dev/$d SMART status" "Verified" ;;
        Failing|Failed)
            log_fail "/dev/$d SMART status" "$smart — back up immediately, do not write to drive" ;;
        "Not Supported"|"")
            log_info "/dev/$d SMART status" "${smart:-(not exposed; macOS limitation for many NVMe drives)}" ;;
        *)
            log_warn "/dev/$d SMART status" "$smart" ;;
    esac
done

# ----------------------------------------------------------------------------
section "2. APFS CONTAINERS + VOLUMES"
# ----------------------------------------------------------------------------
if [[ -n "$disk_id" ]]; then
    diskutil apfs list "$disk_id" 2>/dev/null | sed 's/^/  /' | head -60
else
    diskutil apfs list 2>/dev/null | sed 's/^/  /' | head -80
fi

# Volumes per target (with free space)
note ""
note "  Mounted APFS volumes:"
df -h | awk 'NR==1 || /\/dev\/disk.* apfs|\/dev\/disk.*\/Volumes/{print "    " $0}' | head -12

# ----------------------------------------------------------------------------
section "3. IO ERRORS (unified log, last ${DAYS}d)"
# ----------------------------------------------------------------------------
io_lines=$(log show --last "${DAYS}d" --style compact \
    --predicate '(subsystem == "com.apple.iokit" OR subsystem == "com.apple.kernel") AND (eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "media error" OR eventMessage CONTAINS[c] "MEDIA_ERROR" OR eventMessage CONTAINS[c] "device timeout")' \
    2>/dev/null)
io_count=$(echo "$io_lines" | grep -c . || echo 0)

if [[ "$io_count" -gt 50 ]]; then
    log_fail "IO errors in log" "$io_count events — active failure"
    note "  Sample (first 5):"
    echo "$io_lines" | head -5 | sed 's/^/    /'
elif [[ "$io_count" -gt 5 ]]; then
    log_warn "IO errors in log" "$io_count events"
    note "  Sample (first 3):"
    echo "$io_lines" | head -3 | sed 's/^/    /'
elif [[ "$io_count" -gt 0 ]]; then
    log_info "IO errors in log" "$io_count events (occasional events normal)"
else
    log_pass "IO errors in log" "0"
fi

# APFS-specific corruption signal
apfs_errors=$(log show --last "${DAYS}d" --style compact \
    --predicate 'eventMessage CONTAINS "apfs" AND (messageType == "Error" OR messageType == "Fault")' \
    2>/dev/null | wc -l | tr -d ' ')
if [[ "$apfs_errors" -gt 10 ]]; then
    log_warn "APFS error/fault events" "$apfs_errors"
else
    log_pass "APFS error/fault events" "$apfs_errors"
fi

# ----------------------------------------------------------------------------
section "4. APFS SNAPSHOT BLOAT"
# ----------------------------------------------------------------------------
# Per-volume snapshot count
mount | awk '/apfs/{print $3}' | while read -r mnt; do
    [[ -z "$mnt" ]] && continue
    snap_count=$(tmutil listlocalsnapshots "$mnt" 2>/dev/null | grep -c "com.apple" | tr -d ' \n')
    snap_count="${snap_count:-0}"
    if (( snap_count > 20 )); then
        log_warn "Snapshots on $mnt" "$snap_count — purgeable space tied up"
    elif (( snap_count > 0 )); then
        log_info "Snapshots on $mnt" "$snap_count"
    else
        log_pass "Snapshots on $mnt" "0"
    fi
done

# ----------------------------------------------------------------------------
section "5. FREE SPACE / PURGEABLE BREAKDOWN"
# ----------------------------------------------------------------------------
if [[ -n "$TARGET_VOL" ]]; then
    volumes=("$TARGET_VOL")
else
    mapfile -t volumes < <(mount | awk '/apfs/{print $3}' | head -6)
fi

for v in "${volumes[@]}"; do
    [[ -d "$v" ]] || continue
    df_line=$(df -h "$v" 2>/dev/null | tail -1)
    free_pct=$(echo "$df_line" | awk '{gsub("%","",$5); print 100-$5}')
    free_gb=$(echo "$df_line" | awk '{print $4}')
    note "  $v: ${free_gb} free (${free_pct}%)"
    if [[ "$free_pct" -lt 10 ]]; then
        log_warn "Free space on $v" "${free_pct}% — low"
    else
        log_pass "Free space on $v" "${free_pct}%"
    fi
    # Purgeable space from APFS (requires diskutil apfs)
    purgeable=$(diskutil apfs list 2>/dev/null | awk -v vol="$v" '
        $0 ~ vol {found=1}
        found && /Capacity In Use/{print $NF; found=0; exit}
    ')
done

# ----------------------------------------------------------------------------
section "6. VOLUME VERIFICATION (read-only)"
# ----------------------------------------------------------------------------
# Only verify the target if we have one; iterating all volumes is slow + noisy.
if [[ -n "$TARGET_VOL" ]]; then
    verify_target="$TARGET_VOL"
elif [[ -n "$disk_id" ]]; then
    verify_target="$disk_id"
else
    verify_target=""
fi

if [[ -n "$verify_target" ]]; then
    note "  Running: diskutil verifyVolume $verify_target (read-only)"
    if diskutil verifyVolume "$verify_target" 2>&1 | grep -q "appears to be OK"; then
        log_pass "verifyVolume $verify_target" "OK"
    else
        log_warn "verifyVolume $verify_target" "did not return clean (may need sudo or already in use)"
    fi
else
    note "  (skipped — pass -v or -d to verify a specific target)"
fi

emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Drilldowns:"
    note "    drive-dependencies.sh -v <mount>   # check what references a volume"
    note "    storage-pressure.sh                # snapshot bloat detail"
    note "    recover-clone.sh                   # safely image data off a failing drive"
fi
