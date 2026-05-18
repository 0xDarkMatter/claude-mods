#!/usr/bin/env bash
# mac-ops :: storage-pressure.sh
# "Disk is full but I deleted everything" — explain macOS's purgeable space
# accounting and surface the actual consumers (APFS snapshots, local Time
# Machine backups, Spotlight index, iCloud cached files, etc).

set -u

VOL="/"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--volume) VOL="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  -v, --volume PATH      Volume to analyze (default: /)
  --json, --redact, --quiet, --verbose

Why "About This Mac → Storage" doesn't match du:
  - APFS local Time Machine snapshots: data deleted but retained for TM
  - iCloud cached files: shown as "Purgeable" — frees automatically under pressure
  - Spotlight index: ~.Spotlight-V100 hidden dir
  - Cached files in ~/Library/Caches, /var/folders
  - Sleepimage, swap files (in dynamic_pager dirs)

Common reclaims:
  tmutil thinlocalsnapshots /             # remove eligible TM snapshots
  tmutil deletelocalsnapshots <name>      # specific snapshot
  diskutil apfs deleteSnapshot diskNsM <name>
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

if [[ ! -d "$VOL" ]]; then
    echo "Error: $VOL is not a directory" >&2
    exit 3
fi

note "  Volume: $VOL"

# ----------------------------------------------------------------------------
section "1. df vs APFS reality"
# ----------------------------------------------------------------------------
df -h "$VOL" 2>/dev/null | head -2 | sed 's/^/  /'

# diskutil info gives the APFS-aware view including snapshot space
note ""
note "  diskutil info (APFS-aware):"
disk_id=$(diskutil info "$VOL" 2>/dev/null | awk -F': *' '/Device Identifier/{print $2; exit}')
if [[ -n "$disk_id" ]]; then
    diskutil info "$disk_id" 2>/dev/null | grep -E "Allocation Block Size|Container Total Space|Container Free Space|Volume Used Space|Volume Free Space|APFS Snapshot|Capacity In Use" | sed 's/^/  /'
fi

# ----------------------------------------------------------------------------
section "2. APFS SNAPSHOTS"
# ----------------------------------------------------------------------------
snap_count=$(tmutil listlocalsnapshots "$VOL" 2>/dev/null | grep -c "com.apple" | tr -d ' \n')
snap_count="${snap_count:-0}"
if (( snap_count > 0 )); then
    log_info "Local Time Machine snapshots" "$snap_count"
    note "  Recent (last 10):"
    tmutil listlocalsnapshots "$VOL" 2>/dev/null | tail -10 | sed 's/^/    /'

    # Calculate approximate space held by snapshots
    if [[ -n "$disk_id" ]]; then
        snap_space=$(diskutil apfs list 2>/dev/null | awk -v d="$disk_id" '
            $0 ~ d {found=1}
            found && /Snapshot/ {print; if (++n >= 5) exit}
        ' | head -8)
        if [[ -n "$snap_space" ]]; then
            note ""
            note "  Snapshot space (from diskutil apfs list):"
            echo "$snap_space" | sed 's/^/    /'
        fi
    fi

    if (( snap_count > 20 )); then
        log_warn "Snapshot count" "$snap_count — consider 'tmutil thinlocalsnapshots $VOL'"
    fi
else
    log_pass "Local Time Machine snapshots" "0"
fi

# ----------------------------------------------------------------------------
section "3. iCLOUD CACHED FILES"
# ----------------------------------------------------------------------------
icloud_dir="$HOME/Library/Mobile Documents"
if [[ -d "$icloud_dir" ]]; then
    icloud_size=$(du -sh "$icloud_dir" 2>/dev/null | awk '{print $1}')
    log_info "iCloud Drive cache size" "${icloud_size:-?}"
    note "  These are typically marked 'Purgeable' — macOS evicts under pressure."
fi

# ----------------------------------------------------------------------------
section "4. CACHE / TEMPORARY DIRECTORIES"
# ----------------------------------------------------------------------------
note "  User caches:"
for d in "$HOME/Library/Caches" "$HOME/Library/Application Support/Caches"; do
    if [[ -d "$d" ]]; then
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        printf "    %s = %s\n" "$d" "${size:-?}"
    fi
done

note ""
note "  System caches:"
for d in /Library/Caches /var/folders /private/var/log; do
    if [[ -d "$d" ]]; then
        size=$(sudo -n du -sh "$d" 2>/dev/null | awk '{print $1}')
        if [[ -z "$size" ]]; then
            # No sudo — try without
            size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        fi
        printf "    %s = %s\n" "$d" "${size:-?}"
    fi
done

# ----------------------------------------------------------------------------
section "5. SLEEPIMAGE + SWAP"
# ----------------------------------------------------------------------------
if [[ -f /private/var/vm/sleepimage ]]; then
    size=$(ls -lh /private/var/vm/sleepimage 2>/dev/null | awk '{print $5}')
    log_info "Sleep image" "${size:-?} — equals RAM size; safe to ignore"
fi

swap_files=$(ls /private/var/vm/swapfile* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$swap_files" -gt 0 ]]; then
    swap_total=$(ls -lh /private/var/vm/swapfile* 2>/dev/null | awk '{sum+=$5}END{print sum/1024/1024" GB"}')
    log_info "Swap files" "$swap_files files (~$swap_total) — grows under memory pressure"
fi

# ----------------------------------------------------------------------------
section "6. SPOTLIGHT INDEX SIZE"
# ----------------------------------------------------------------------------
spot_dir="$VOL/.Spotlight-V100"
if [[ -d "$spot_dir" ]]; then
    spot_size=$(sudo -n du -sh "$spot_dir" 2>/dev/null | awk '{print $1}')
    [[ -z "$spot_size" ]] && spot_size="(needs sudo to size)"
    log_info "Spotlight index size" "$spot_size"
fi

# ----------------------------------------------------------------------------
section "7. TOP 10 LARGEST DIRECTORIES IN ~ (heuristic)"
# ----------------------------------------------------------------------------
note "  This walks ~ — may take a moment on large home dirs."
du -sh "$HOME"/* 2>/dev/null | sort -rh | head -10 | sed 's/^/    /'

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Reclaim playbook:"
    note "    tmutil thinlocalsnapshots $VOL              # trim eligible local TM snapshots"
    note "    rm -rf ~/Library/Caches/*                   # clear per-user caches"
    note "    docker system prune -a                       # Docker images/volumes"
    note "    brew cleanup -s                              # Homebrew cached downloads"
    note "    sudo periodic daily weekly monthly           # rotate system logs"
fi
