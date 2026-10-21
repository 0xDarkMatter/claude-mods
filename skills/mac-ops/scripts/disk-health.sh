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

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
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
# Without this restore every standard flag was silently ignored (--redact
# output meant for sharing went out unredacted). ${a[@]+...} is the bash
# 3.2-safe expansion of a possibly empty array under set -u.
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

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
# A check that could not run reports at the worst result it could have given,
# so a broken tool can never read better than an honest run: SMART and IO errors
# can FAIL, so an unread disk or log is a FAIL; APFS faults, snapshots and free
# space only WARN (sections 3-5).
if [[ -n "$disk_id" ]]; then
    targets=("$disk_id")
else
    # All physical disks (not partitions / synthesized).
    # procsub guard: diskutil's status is checked before any disk is walked. Fed
    # through `mapfile < <(diskutil list | awk ...)`, a failed listing left no
    # targets: no SMART check ran, the run reported no FAIL, and a Failing disk
    # went unreported. A failed or empty listing is now a FAIL of its own.
    targets=()
    rc=0
    listing=$(diskutil list 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        rows=$(printf '%s\n' "$listing" | awk '/^\/dev\/disk[0-9]+ /{gsub("/dev/",""); print $1}' | sort -u | head -20)
        while IFS= read -r d; do
            [[ -n "$d" ]] && targets+=("$d")
        done <<< "$rows"
    fi
    if [[ "${#targets[@]}" -eq 0 ]]; then
        why="named no disk"; [[ "$rc" -ne 0 ]] && why="failed (exit $rc)"
        log_fail "Disk listing" "diskutil list $why - SMART status NOT checked"
    fi
fi

for d in ${targets[@]+"${targets[@]}"}; do
    [[ -z "$d" ]] && continue
    irc=0
    info=$(diskutil info "$d" 2>/dev/null) || irc=$?
    if [[ "$irc" -ne 0 || -z "$info" ]]; then
        log_fail "/dev/$d SMART status" "NOT checked - diskutil info failed (exit $irc) or returned no data"
        continue
    fi

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
# log's status is checked for both queries: piped into a count, a failed or
# unavailable `log show` read "0 events", a PASS. The IO check can FAIL, so an
# unrun one is a FAIL; the APFS one only WARNs, so its unrun result is a WARN.
io_rc=0
io_lines=$(log show --last "${DAYS}d" --style compact \
    --predicate '(subsystem == "com.apple.iokit" OR subsystem == "com.apple.kernel") AND (eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "media error" OR eventMessage CONTAINS[c] "MEDIA_ERROR" OR eventMessage CONTAINS[c] "device timeout")' \
    2>/dev/null) || io_rc=$?
# grep -c prints its own 0 (and exits 1) on no match: an `|| echo 0` here made
# "0\n0", a [[ ]] syntax error on every clean run.
io_count=$(printf '%s\n' "$io_lines" | grep -c .)

if [[ "$io_rc" -ne 0 ]]; then
    log_fail "IO errors in log" "NOT checked - log show failed (exit $io_rc)"
elif [[ "$io_count" -gt 50 ]]; then
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
apfs_rc=0
apfs_lines=$(log show --last "${DAYS}d" --style compact \
    --predicate 'eventMessage CONTAINS "apfs" AND (messageType == "Error" OR messageType == "Fault")' \
    2>/dev/null) || apfs_rc=$?
apfs_errors=$(printf '%s\n' "$apfs_lines" | grep -c .)
if [[ "$apfs_rc" -ne 0 ]]; then
    log_warn "APFS error/fault events" "NOT checked - log show failed (exit $apfs_rc)"
elif [[ "$apfs_errors" -gt 10 ]]; then
    log_warn "APFS error/fault events" "$apfs_errors"
else
    log_pass "APFS error/fault events" "$apfs_errors"
fi

# procsub guard: mount's status is checked once, here, for sections 4 and 5.
# Fed into loops (`mount | awk | while`, `mapfile < <(mount | awk)`), a failed
# listing walked no volume, so the snapshot and free-space checks vanished and
# the run read clean. The piped `while` also ran in a subshell, which dropped
# every snapshot PASS/WARN it logged from the SUMMARY counts.
mount_rc=0
mount_out=$(mount 2>/dev/null) || mount_rc=$?
apfs_mounts=""
[[ "$mount_rc" -eq 0 ]] && apfs_mounts=$(printf '%s\n' "$mount_out" | awk '/apfs/{print $3}')
mounts_why=""   # empty = the APFS mount list is usable
if [[ "$mount_rc" -ne 0 ]]; then
    mounts_why="mount failed (exit $mount_rc)"
elif [[ -z "$apfs_mounts" ]]; then
    mounts_why="mount listed no APFS volume"
fi

# ----------------------------------------------------------------------------
section "4. APFS SNAPSHOT BLOAT"
# ----------------------------------------------------------------------------
# Per-volume snapshot count
if [[ -n "$mounts_why" ]]; then
    log_warn "Snapshots" "NOT checked - $mounts_why"
else
    while IFS= read -r mnt; do
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
    done <<< "$apfs_mounts"
fi

# ----------------------------------------------------------------------------
section "5. FREE SPACE / PURGEABLE BREAKDOWN"
# ----------------------------------------------------------------------------
volumes=()
if [[ -n "$TARGET_VOL" ]]; then
    volumes=("$TARGET_VOL")
elif [[ -n "$mounts_why" ]]; then
    log_warn "Free space" "NOT checked - $mounts_why"
else
    while IFS= read -r v; do
        [[ -n "$v" ]] && volumes+=("$v")
    done <<< "$(printf '%s\n' "$apfs_mounts" | head -6)"
fi

for v in ${volumes[@]+"${volumes[@]}"}; do
    [[ -d "$v" ]] || continue
    # df's status is checked: its empty output once parsed as 0% used, so a
    # failed df read "100% free", a PASS.
    drc=0
    df_out=$(df -h "$v" 2>/dev/null) || drc=$?
    df_line=$(printf '%s\n' "$df_out" | tail -1)
    used_pct=$(printf '%s\n' "$df_line" | awk '{gsub("%","",$5); print $5}')
    if [[ "$drc" -ne 0 || ! "$used_pct" =~ ^[0-9]+$ ]]; then
        why="df failed (exit $drc)"; [[ "$drc" -eq 0 ]] && why="df printed no capacity"
        log_warn "Free space on $v" "NOT checked - $why"
        continue
    fi
    free_pct=$((100 - used_pct))
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
