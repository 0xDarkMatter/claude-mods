#!/usr/bin/env bash
# mac-ops :: bluetooth-audit.sh
# Bluetooth state: paired devices, currently connected, recent connection
# issues, the Bluetooth daemon state.
#
# Common Bluetooth pains on Mac: keyboard/mouse disconnects, AirPods audio
# quality drops, Magic Mouse cursor stutter, HomePod handoff failures. The
# log usually has the smoking gun.

set -u

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

Reports:
  1. Bluetooth power state + daemon health (bluetoothd)
  2. Paired devices + connection state
  3. Recent connection/disconnection events (24h)
  4. Recent Bluetooth errors / faults
  5. Wake-on-Bluetooth setting

Common fixes:
  - sudo pkill bluetoothd               # daemon restart
  - sudo defaults delete ~/Library/Preferences/com.apple.Bluetooth.plist  # reset (drastic)
  - Remove + re-pair the misbehaving device
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# ----------------------------------------------------------------------------
section "1. BLUETOOTH POWER + DAEMON"
# ----------------------------------------------------------------------------
# Use system_profiler — slow but reliable
bt_summary=$(system_profiler SPBluetoothDataType 2>/dev/null)
state=$(echo "$bt_summary" | awk -F': *' '/State:/{print $2; exit}')
addr=$(echo "$bt_summary" | awk -F': *' '/Address:/{print $2; exit}')

case "$state" in
    *On*) log_pass "Bluetooth state" "On" ;;
    *Off*) log_info "Bluetooth state" "Off" ;;
    *) log_info "Bluetooth state" "${state:-unknown}" ;;
esac
[[ -n "$addr" ]] && note "  Adapter address: $addr"

# bluetoothd process
if pgrep -x bluetoothd >/dev/null; then
    pid=$(pgrep -x bluetoothd | head -1)
    cpu=$(ps -p "$pid" -o pcpu= 2>/dev/null | tr -d ' ')
    log_pass "bluetoothd" "PID $pid (CPU ${cpu:-0}%)"
else
    log_fail "bluetoothd" "not running"
fi

# ----------------------------------------------------------------------------
section "2. PAIRED DEVICES"
# ----------------------------------------------------------------------------
# Extract device blocks from system_profiler output
note "  Paired devices (name | connected | type):"
echo "$bt_summary" | awk '
    /Address:/ && /[0-9A-F][0-9A-F]-/{
        # We are inside the device list (not the adapter section)
        device_name=prev_line
    }
    /Connected:/ && device_name {
        connected=$0; sub(/^[[:space:]]+Connected:[[:space:]]+/, "", connected)
    }
    /Minor Type:|Major Type:/ && device_name {
        type=$0; sub(/^[[:space:]]+[^:]+:[[:space:]]+/, "", type)
    }
    /^$/ && device_name && connected {
        printf "    %-35s %-10s %s\n", device_name, connected, (type ? type : "?")
        device_name=""; connected=""; type=""
    }
    {prev_line=$0}
' | head -20

# ----------------------------------------------------------------------------
section "3. RECENT CONNECTION EVENTS (24h)"
# ----------------------------------------------------------------------------
conn_events=$(log show --last 24h --style compact \
    --predicate '(subsystem == "com.apple.bluetooth" OR process == "bluetoothd") AND (eventMessage CONTAINS[c] "connect" OR eventMessage CONTAINS[c] "disconnect")' \
    2>/dev/null | grep -iE "(connect|disconnect)" | tail -15)

if [[ -n "$conn_events" ]]; then
    n=$(echo "$conn_events" | wc -l | tr -d ' \n')
    log_info "Bluetooth connect/disconnect events (24h)" "$n"
    note "  Recent (last 10):"
    echo "$conn_events" | tail -10 | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "4. RECENT BLUETOOTH ERRORS"
# ----------------------------------------------------------------------------
bt_errors=$(log show --last 24h --style compact \
    --predicate '(subsystem == "com.apple.bluetooth" OR process == "bluetoothd") AND (messageType == "Error" OR messageType == "Fault")' \
    2>/dev/null | head -10)

if [[ -n "$bt_errors" ]]; then
    n=$(echo "$bt_errors" | wc -l | tr -d ' \n')
    log_warn "Bluetooth error/fault events (24h)" "$n"
    echo "$bt_errors" | head -5 | sed 's/^/    /'
else
    log_pass "Bluetooth error/fault events (24h)" "0"
fi

# ----------------------------------------------------------------------------
section "5. WAKE FOR BLUETOOTH"
# ----------------------------------------------------------------------------
# "Wake for Bluetooth devices" — often the culprit for 3am wakes
wake_setting=$(pmset -g | awk '/ttyskeepawake/{print $2; exit}')
note "  pmset settings (lookout for wake-for-bluetooth):"
pmset -g 2>/dev/null | grep -iE "bluetooth|womp|hidwake" | sed 's/^/    /'

# ----------------------------------------------------------------------------
section "6. BLUETOOTH PROCESS NAMES TO KNOW"
# ----------------------------------------------------------------------------
note "  Active BT-related processes:"
ps -Ao pid,comm 2>/dev/null | grep -iE "bluetoothd|BTSupport|BTLE|AirPort|AirDrop" | head -10 | sed 's/^/    /'

# ----------------------------------------------------------------------------
emit_summary
