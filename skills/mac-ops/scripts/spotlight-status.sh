#!/usr/bin/env bash
# mac-ops :: spotlight-status.sh
# Spotlight (mds) health: indexing state per volume, daemon CPU/IO,
# common reindex/repair operations.

set -u

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

Common Spotlight fixes (in order of severity):
  1. Wait — initial indexing on a new volume can take hours
  2. mdutil -E /Volumes/X         Erase + rebuild index for a volume
  3. mdutil -i off /Volumes/X     Disable Spotlight on a volume entirely
  4. (Reboot — clears mds daemon state)
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

# ----------------------------------------------------------------------------
section "1. MDS / MDWORKER PROCESS HEALTH"
# ----------------------------------------------------------------------------
note "  Top mds-family processes by CPU:"
ps -ArcS -o pcpu,rss,pid,comm 2>/dev/null | awk '/mds|mdworker|mdsync/' | head -10 | \
    awk '{printf "    %5s%% RSS=%-8s PID=%s  %s\n", $1, $2, $3, $4}'

# Specifically check mds_stores — the kernel-side indexer doing the heavy lifting
mds_cpu=$(ps -ArcS -o pcpu,comm 2>/dev/null | awk '$2=="mds_stores"{print $1; exit}')
mds_cpu="${mds_cpu:-0}"
mds_int=${mds_cpu%.*}
if [[ "${mds_int:-0}" -gt 80 ]]; then
    log_warn "mds_stores CPU" "${mds_cpu}% — heavy indexing in progress"
elif [[ "${mds_int:-0}" -gt 30 ]]; then
    log_info "mds_stores CPU" "${mds_cpu}% — moderate indexing"
else
    log_pass "mds_stores CPU" "${mds_cpu}%"
fi

# ----------------------------------------------------------------------------
section "2. INDEX STATUS PER VOLUME"
# ----------------------------------------------------------------------------
mount | awk '/apfs/{print $3}' | while read -r vol; do
    [[ -z "$vol" ]] && continue
    # Skip system-managed read-only volumes — they never have indexes
    case "$vol" in
        /System/Volumes/VM|/System/Volumes/xarts|/System/Volumes/Hardware|/System/Volumes/iSCPreboot|/System/Volumes/Update*) continue ;;
    esac
    status=$(mdutil -s "$vol" 2>/dev/null | tail -1)
    case "$status" in
        *"Indexing enabled"*)
            log_pass "$vol indexing" "enabled"
            ;;
        *"Indexing disabled"*)
            log_info "$vol indexing" "disabled (Spotlight will not search this volume)"
            ;;
        *"No index"*|*"not registered"*)
            log_warn "$vol indexing" "no index store on disk — search empty until rebuild"
            ;;
        *"unknown"*)
            log_info "$vol indexing" "system volume (no user index)"
            ;;
        *)
            log_info "$vol indexing" "$status"
            ;;
    esac
done

# ----------------------------------------------------------------------------
section "3. INDEX STORE SIZES"
# ----------------------------------------------------------------------------
note "  On-disk Spotlight index size per volume:"
mount | awk '/apfs/{print $3}' | while read -r vol; do
    [[ -z "$vol" ]] && continue
    spot_dir="$vol/.Spotlight-V100"
    if [[ -d "$spot_dir" ]]; then
        size=$(du -sh "$spot_dir" 2>/dev/null | awk '{print $1}')
        printf "    %-30s %s\n" "$vol" "${size:-?}"
    fi
done

# ----------------------------------------------------------------------------
section "4. RECENT MDS LOG ACTIVITY"
# ----------------------------------------------------------------------------
mds_errors=$(log show --last 24h --style compact \
    --predicate 'process == "mds" OR process == "mds_stores" OR process == "mdworker_shared"' \
    2>/dev/null | grep -iE "(error|fault|crash)" | head -10)

if [[ -n "$mds_errors" ]]; then
    log_warn "mds errors (24h)" "see below"
    echo "$mds_errors" | sed 's/^/    /'
else
    log_pass "mds errors (24h)" "none"
fi

# ----------------------------------------------------------------------------
section "5. INDEX PERMANENT EXCLUSIONS"
# ----------------------------------------------------------------------------
exclusions="$HOME/Library/Preferences/com.apple.spotlight.plist"
if [[ -f "$exclusions" ]]; then
    note "  Per-user Spotlight preferences exist."
fi
sys_exclusions="/.Spotlight-V100"
if [[ -d "$sys_exclusions" ]]; then
    note "  Boot volume index dir present at /.Spotlight-V100"
fi

note ""
note "  To exclude a path from Spotlight (per-user):"
note "    System Settings → Spotlight → Search Privacy → +"

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Common operations:"
    note "    mdutil -s /Volumes/X       Status per volume"
    note "    sudo mdutil -E /Volumes/X  Erase + rebuild index (heavy operation)"
    note "    sudo mdutil -i off /       Disable Spotlight on boot volume (drastic)"
    note "    sudo mdutil -i on /        Re-enable"
fi
