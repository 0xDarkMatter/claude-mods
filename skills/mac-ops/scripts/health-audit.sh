#!/usr/bin/env bash
# mac-ops :: health-audit.sh
# Comprehensive macOS workstation audit — the orchestrator.
# Walks the 8-rung diagnostic ladder and emits a verdict.
#
# Usage:
#   scripts/health-audit.sh [--json] [--redact] [--quiet] [--verbose] [--days N]
#
# Stdout = data (text by default, NDJSON when --json).
# Stderr = section banners (suppressed with --quiet).

set -u

DAYS=30

# Use a while loop instead of for-arg-in to correctly handle --days N (two tokens)
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="${2:-30}"; shift 2 ;;
        --days=*) DAYS="${1#--days=}"; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --days N         Days back to scan logs (default: 30)
  --json           Emit NDJSON for piping to jq
  --redact         Mask private IPs, MACs, UUIDs, hostnames
  --quiet|-q       Suppress section banners
  --verbose|-v     Include extra detail (e.g. per-volume APFS dump)

Exit codes (reflect whether the audit RAN, not what it found):
  0  audit completed (findings in output)
  1  general error
  2  usage error
  5  precondition missing
EOF
            exit 0 ;;
        *) shift ;;
    esac
done
# Restore $@ for downstream parse_common_flags / maybe_filter_self
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"
source "$(dirname "$0")/_lib/panel.sh"
panel_init

# ----------------------------------------------------------------------------
section "1. HARDWARE HEALTH"
# ----------------------------------------------------------------------------
# Thermal events, low-battery shutdown, SMC errors
thermal_events=$(log show --last "${DAYS}d" --style compact \
    --predicate 'subsystem == "com.apple.thermalmonitord"' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$thermal_events" -gt 100 ]]; then
    log_warn "Thermal monitor events ($DAYS days)" "$thermal_events — possible sustained throttling"
else
    log_pass "Thermal monitor events ($DAYS days)" "$thermal_events"
fi

# Unclean shutdowns (power assertions + kernel)
unclean=$(log show --last "${DAYS}d" --style compact \
    --predicate 'eventMessage CONTAINS[c] "previous shutdown cause" AND eventMessage CONTAINS "-"' 2>/dev/null \
    | grep -cE "previous shutdown cause:\s*-[0-9]+" || true)
if [[ "$unclean" -gt 2 ]]; then
    log_warn "Unclean shutdowns ($DAYS days)" "$unclean recorded"
elif [[ "$unclean" -gt 0 ]]; then
    log_info "Unclean shutdowns ($DAYS days)" "$unclean"
else
    log_pass "Unclean shutdowns ($DAYS days)" "0"
fi

# Battery condition (laptops only)
if pmset -g batt 2>/dev/null | grep -q "InternalBattery"; then
    cycles=$(system_profiler SPPowerDataType 2>/dev/null | awk '/Cycle Count/{print $3; exit}')
    condition=$(system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Condition/{print $2; exit}')
    if [[ "$condition" == "Normal" ]]; then
        log_pass "Battery condition" "$condition (cycles=$cycles)"
    else
        log_warn "Battery condition" "$condition (cycles=$cycles)"
    fi
fi

# ----------------------------------------------------------------------------
section "2. STORAGE HEALTH"
# ----------------------------------------------------------------------------
# IO errors via unified log
io_errors=$(log show --last "${DAYS}d" --style compact \
    --predicate '(subsystem == "com.apple.iokit" OR subsystem == "com.apple.kernel") AND (eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "media error" OR eventMessage CONTAINS[c] "media is not present")' \
    2>/dev/null | wc -l | tr -d ' ')
if [[ "$io_errors" -gt 20 ]]; then
    log_fail "IO errors via log ($DAYS days)" "$io_errors — investigate per-volume with disk-health.sh"
elif [[ "$io_errors" -gt 0 ]]; then
    log_warn "IO errors via log ($DAYS days)" "$io_errors"
else
    log_pass "IO errors via log ($DAYS days)" "0"
fi

# APFS verify per mounted APFS volume (read-only — safe)
note "  APFS volumes:"
# procsub ok: each volume only ever logs PASS or INFO here, so a diskutil that fails
# lists none and cannot hide a FAIL.
while read -r line; do
    [[ -z "$line" ]] && continue
    disk=$(echo "$line" | awk '{print $1}')
    mount=$(echo "$line" | awk '{print $NF}')
    # diskutil apfs verifyVolume is read-only; skip noisy ones we can't auth for
    if diskutil apfs verifyVolume "$disk" 2>&1 | grep -q "successfully verified"; then
        log_pass "APFS volume $disk" "$mount — verified"
    else
        # Probably needs privileges or is in use; soft-pass with info
        log_info "APFS volume $disk" "$mount — verify skipped (may need sudo or volume in use)"
    fi
done < <(diskutil list 2>/dev/null | awk '/Apple_APFS_Container/{print $NF, $NF}' | sort -u)

# APFS snapshot bloat — local Time Machine snapshots
snap_count=$(tmutil listlocalsnapshots / 2>/dev/null | wc -l | tr -d ' ')
if [[ "$snap_count" -gt 10 ]]; then
    log_warn "Local Time Machine snapshots on /" "$snap_count — may eat purgeable space"
else
    log_pass "Local Time Machine snapshots on /" "$snap_count"
fi

# Free space on root volume
root_free_pct=$(df -h / | awk 'NR==2{gsub("%","",$5); print 100-$5}')
if [[ "$root_free_pct" -lt 5 ]]; then
    log_fail "Free space on /" "${root_free_pct}% — critical"
elif [[ "$root_free_pct" -lt 15 ]]; then
    log_warn "Free space on /" "${root_free_pct}%"
else
    log_pass "Free space on /" "${root_free_pct}%"
fi

# ----------------------------------------------------------------------------
section "3. PANIC RECORDS"
# ----------------------------------------------------------------------------
panic_dir="/Library/Logs/DiagnosticReports"
panics_recent=$(find "$panic_dir" -maxdepth 1 \( -name "*.panic" -o -name "Kernel*.ips" \) \
    -mtime "-${DAYS}" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$panics_recent" -gt 0 ]]; then
    log_fail "Kernel panics ($DAYS days)" "$panics_recent — drill with panic-triage.sh"
    note "  Most recent:"
    find "$panic_dir" -maxdepth 1 \( -name "*.panic" -o -name "Kernel*.ips" \) -mtime "-${DAYS}" 2>/dev/null \
        | head -3 | sed 's|.*/|    |'
else
    log_pass "Kernel panics ($DAYS days)" "0"
fi

# User app crashes (informational — they don't crash the system but indicate flaky software)
user_crashes=$(find ~/Library/Logs/DiagnosticReports -maxdepth 1 -name "*.ips" -mtime "-7" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$user_crashes" -gt 20 ]]; then
    log_warn "User-space app crashes (7 days)" "$user_crashes — frequent crashes"
else
    log_info "User-space app crashes (7 days)" "$user_crashes"
fi

# ----------------------------------------------------------------------------
section "4. STARTUP INVENTORY"
# ----------------------------------------------------------------------------
# Login Items (visible in System Settings)
login_items=$(osascript -e 'tell application "System Events" to count of login items' 2>/dev/null || echo 0)
log_info "Login Items (System Settings)" "$login_items"

# User LaunchAgents
user_agents=$(find "$HOME/Library/LaunchAgents" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
log_info "User LaunchAgents (~/Library/LaunchAgents)" "$user_agents"

# System LaunchAgents
sys_agents=$(find "/Library/LaunchAgents" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
log_info "System LaunchAgents (/Library/LaunchAgents)" "$sys_agents"

# System LaunchDaemons
sys_daemons=$(find "/Library/LaunchDaemons" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
log_info "System LaunchDaemons (/Library/LaunchDaemons)" "$sys_daemons"

# Privileged helper tools (often orphaned after app uninstall)
helpers=$(find "/Library/PrivilegedHelperTools" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$helpers" -gt 5 ]]; then
    log_warn "Privileged helper tools" "$helpers — some may be orphans from uninstalled apps"
else
    log_info "Privileged helper tools" "$helpers"
fi

total_startup=$((login_items + user_agents + sys_agents + sys_daemons))
note "  Total startup items: $total_startup (drill with startup-audit.sh)"

# ----------------------------------------------------------------------------
section "5. RESOURCE PRESSURE (snapshot)"
# ----------------------------------------------------------------------------
# Top 5 CPU consumers — `-o command` includes full path/args; we keep it short with cut
note "  Top 5 by CPU%:"
ps -ArcS -o pcpu,pid,command 2>/dev/null | head -6 | tail -5 | \
    awk '{pcpu=$1; pid=$2; $1=""; $2=""; sub(/^  /,""); printf "    %5s%% [%6s] %s\n", pcpu, pid, $0}' | \
    cut -c1-100

# Notable noisy processes
for proc in mds_stores mdworker_shared photoanalysisd cloudd bird WindowServer; do
    if cpu=$(ps -ArcS -o pcpu,comm 2>/dev/null | awk -v p="$proc" '$2==p{print $1; exit}'); then
        if [[ -n "$cpu" ]]; then
            cpu_int=${cpu%.*}
            if [[ "${cpu_int:-0}" -gt 50 ]]; then
                log_warn "$proc CPU" "${cpu}% — sustained spike?"
            else
                log_info "$proc CPU" "${cpu}%"
            fi
        fi
    fi
done

# ----------------------------------------------------------------------------
section "6. WAKE PATTERN (last 24h)"
# ----------------------------------------------------------------------------
wake_count=$(pmset -g log 2>/dev/null | grep -cE "Wake from" | head -1)
wake_count="${wake_count:-0}"
if [[ "$wake_count" -gt 50 ]]; then
    log_warn "Wakes in pmset log (full history)" "$wake_count — drill with wake-reasons.sh"
else
    log_info "Wakes in pmset log (full history)" "$wake_count"
fi

# ----------------------------------------------------------------------------
section "7. TCC (PERMISSIONS)"
# ----------------------------------------------------------------------------
# Read-only check — does the user TCC.db exist? How many entries?
user_tcc="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -r "$user_tcc" ]]; then
    grants=$(sqlite3 "$user_tcc" "SELECT COUNT(*) FROM access WHERE auth_value > 0" 2>/dev/null || echo "?")
    denied=$(sqlite3 "$user_tcc" "SELECT COUNT(*) FROM access WHERE auth_value = 0" 2>/dev/null || echo "?")
    log_info "User TCC grants (allowed)" "$grants"
    if [[ "$denied" != "?" ]] && [[ "$denied" -gt 0 ]]; then
        log_warn "User TCC grants (denied)" "$denied — drill with tcc-audit.sh"
    else
        log_pass "User TCC denials" "0"
    fi
else
    log_info "User TCC.db" "not readable (run tcc-audit.sh for details)"
fi

# ----------------------------------------------------------------------------
section "8. SYSTEM INFO"
# ----------------------------------------------------------------------------
note "  macOS:      $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
note "  Arch:       $(uname -m)"
note "  Uptime:     $(uptime | awk -F'up ' '{split($2,a,","); print a[1]}')"
note "  Hostname:   $(scutil --get LocalHostName 2>/dev/null || hostname)"

# ----------------------------------------------------------------------------
hostname_short=$(scutil --get LocalHostName 2>/dev/null | head -c 30 || hostname -s | head -c 30)
panel_render "health-audit" "$hostname_short"

if [[ "$JSON_MODE" -eq 0 ]] && [[ "$MAC_PANEL_ENABLED" -eq 0 ]] && [[ -n "$FIRST_FAIL" ]]; then
    case "$FIRST_FAIL" in
        *"PANIC"*|*"panic"*)
            echo "  Next: scripts/panic-triage.sh  # decode the most recent panic + pre-panic timeline" ;;
        *"STORAGE"*|*"IO errors"*|*"APFS"*)
            echo "  Next: scripts/disk-health.sh -v /  # APFS + IO errors + snapshot bloat" ;;
        *"snapshot"*|*"Free space"*|*"Local Time Machine"*)
            echo "  Next: scripts/storage-pressure.sh  # explain disk pressure / snapshot bloat" ;;
        *"STARTUP"*|*"LaunchAgent"*|*"LaunchDaemon"*|*"Login Items"*)
            echo "  Next: scripts/startup-audit.sh  # full inventory; safe-disable-startup.sh to cull" ;;
        *"TCC"*|*"denial"*)
            echo "  Next: scripts/tcc-audit.sh --denied  # see which app/service is being denied" ;;
        *"Wake"*|*"WAKE"*)
            echo "  Next: scripts/wake-reasons.sh --since 7d  # classify wakes by cause" ;;
        *"Thermal"*|*"Battery"*|*"shutdown"*)
            echo "  Next: open System Settings → Battery → Options; check pmset -g custom" ;;
        *"helper tool"*)
            echo "  Next: ls /Library/PrivilegedHelperTools/  # remove orphans manually with sudo rm" ;;
        *)
            echo "  Next: re-run with --verbose, then check references/" ;;
    esac
fi

# Friendly status if nothing failed
if [[ "$JSON_MODE" -eq 0 ]] && [[ -z "$FIRST_FAIL" ]] && [[ "$WARN_COUNT" -eq 0 ]]; then
    echo "  ✓ System looks clean across all 8 rungs."
elif [[ "$JSON_MODE" -eq 0 ]] && [[ -z "$FIRST_FAIL" ]] && [[ "$WARN_COUNT" -gt 0 ]]; then
    echo "  ✓ No FAILs. $WARN_COUNT WARN entries above worth scanning."
fi
