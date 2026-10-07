#!/usr/bin/env bash
# mac-ops :: wake-reasons.sh
# Why does this Mac wake up? Breakdown of pmset -g log wake events by cause.
#
# Common wake reason classes:
#   UserActivity / EHCx       — user touched the keyboard / trackpad / a peripheral
#   BT.HID                    — Bluetooth keyboard/mouse activity
#   RTC / SMC                 — scheduled wake (Power Nap, Time Machine, calendar)
#   PWRB                      — power button pressed
#   USB.lid / Notifier        — lid open or wake-via-USB device
#   Maintenance               — system maintenance wake (dark wake)
#   Network                   — Wake-on-LAN / Bluetooth proximity

set -u

SINCE_DAYS=7
TOP_N=15

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)
            # Accept '7d' or '24h' or just N (days)
            v="$2"; shift 2
            case "$v" in
                *d) SINCE_DAYS="${v%d}" ;;
                *h) SINCE_DAYS=$(( ${v%h} / 24 )); [[ "$SINCE_DAYS" -lt 1 ]] && SINCE_DAYS=1 ;;
                *)  SINCE_DAYS="$v" ;;
            esac
            ;;
        --top) TOP_N="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --since 7d|24h|N         Lookback window (default: 7d)
  --top N                  Show top N wake reasons (default: 15)
  --json, --redact, --quiet, --verbose

Wake reason quick reference:
  UserActivity    Display/keyboard/trackpad — user-driven, expected
  BT.HID          Bluetooth keyboard/mouse activity (often phantom at night)
  RTC             Real-time clock — scheduled wake (Power Nap, calendar)
  PWRB            Power button — manual wake
  USB.lid         Lid open
  Maintenance     Background maintenance (dark wake)
  Network         WoL or Bluetooth proximity peer

Heavy BT.HID wakes overnight usually mean a Bluetooth keyboard is "tapping" the
display awake — easy fix is to disable "Wake for Bluetooth" or unpair the device.

Heavy RTC wakes can mean Power Nap is enabled with too much background work.
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
section "1. WAKE PATTERN OVERVIEW"
# ----------------------------------------------------------------------------
note "  Lookback: ${SINCE_DAYS}d (pmset log retains roughly 7-14 days)"

# pmset -g log format on modern macOS:
#   "2026-05-10 02:40:55 +1000 DarkWake  DarkWake from Deep Idle [CDNPB] : due to NUB.SPMI0Sw3IRQ nub-spmi-a0.0x59 ... rtc/Maintenance ..."
# Wake reasons appear after "due to" and end at "Using" or end-of-line.
# Categories: rtc/Maintenance, rtc/SleepService, SMC.OutboxNotEmpty, NUB.SPMI*, etc.
since_epoch=$(($(date +%s) - SINCE_DAYS * 86400))
since_str=$(date -r "$since_epoch" "+%Y-%m-%d")

raw=$(pmset -g log 2>/dev/null | awk -v since="$since_str" '
    $1 >= since && ($0 ~ /DarkWake/ || $0 ~ /[[:space:]]Wake[[:space:]]/) {print}
')

wake_count=$(echo "$raw" | grep -c . || echo 0)
if [[ "$wake_count" -eq 0 ]]; then
    log_info "Wakes (since $since_str)" "0 — Mac hasn't slept, or pmset log was cleared"
    emit_summary
    exit 0
fi

log_info "Total wake events (since $since_str)" "$wake_count"

# ----------------------------------------------------------------------------
section "2. WAKE REASONS BY CLASS"
# ----------------------------------------------------------------------------
note "  Wake-cause class | count | pct"
note "  -----------------|-------|----"

# Extract the bit after "due to" up to "Using" — these are the cause tokens.
# Then classify by first significant token.
reasons_raw=$(echo "$raw" | sed -nE 's/.*due to (.*) Using.*/\1/p; s/.*due to (.*)/\1/p' \
    | awk '
        {
            # Each line is a series of tokens. The most informative is usually the last
            # one before category-style "rtc/X" or "wifi/" or similar slash-form.
            for (i=1; i<=NF; i++) {
                if ($i ~ /\//) { print $i; next }
            }
            print $1  # fallback to first token
        }
    ')

echo "$reasons_raw" | sort | uniq -c | sort -rn | head -"$TOP_N" | \
while read -r count reason; do
    pct=$(( count * 100 / (wake_count > 0 ? wake_count : 1) ))
    class="?"
    case "$reason" in
        rtc/Maintenance*|rtc/Power*)  class="rtc scheduled" ;;
        rtc/SleepService*)            class="push-svc wake" ;;
        rtc/*)                        class="rtc" ;;
        SMC.OutboxNotEmpty*|smc/*)    class="hardware (SMC)" ;;
        NUB.SPMI*|nub-spmi*)          class="USB/peripheral" ;;
        wifibt/*|wlan/*)              class="wifi/bluetooth" ;;
        EHC*|HID*|UserActivity)       class="user input" ;;
        BT*)                          class="bluetooth peer" ;;
        PWRB*|PowerButton*)           class="power button" ;;
        Maintenance*)                 class="maintenance" ;;
        Network*|WoL*)                class="network" ;;
        *)                            class="other" ;;
    esac
    printf "  %-18s | %5d | %3d%%  (%s)\n" "$class" "$count" "$pct" "$reason"
done

# ----------------------------------------------------------------------------
section "3. DARK WAKES (background maintenance)"
# ----------------------------------------------------------------------------
# pmset log line format: "DATE TIME TZ DarkWake \tDarkWake from ..."
# The literal "DarkWake" appears in column 4 (after date/time/tz) AND in the message
dark_wakes=$(echo "$raw" | awk '$4=="DarkWake"' | wc -l | tr -d ' ')
log_info "Dark wakes" "$dark_wakes"

if [[ "$dark_wakes" -gt 50 ]]; then
    log_warn "Dark wake count" "$dark_wakes — frequent background wakes drain battery"
    note "  Common causes:"
    note "    • Power Nap enabled (System Settings → Battery → Options)"
    note "    • Backup destinations (Time Machine, Backblaze) running"
    note "    • Calendar / Contacts / iCloud sync"
fi

# ----------------------------------------------------------------------------
section "4. WAKE TIMING (last 24h)"
# ----------------------------------------------------------------------------
yesterday=$(date -v-1d "+%Y-%m-%d")
note "  Wakes since $yesterday:"
echo "$raw" | awk -v y="$yesterday" '$1 >= y {print "    "$1, $2, $0}' | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ .* Wake reason: [A-Za-z0-9_.]+" | tail -20

# ----------------------------------------------------------------------------
section "5. ASSERTIONS HOLDING SYSTEM AWAKE"
# ----------------------------------------------------------------------------
note "  Current pmset assertions (who's preventing sleep right now):"
pmset -g assertions 2>/dev/null | grep -E "(IDLE|PreventUserIdleSystemSleep|PreventSystemSleep|PreventDisplay)" | head -10 | sed 's/^/    /'

# ----------------------------------------------------------------------------
section "6. SLEEP/WAKE PREFERENCES"
# ----------------------------------------------------------------------------
note "  pmset -g (custom settings):"
pmset -g custom 2>/dev/null | head -25 | sed 's/^/    /'

# ----------------------------------------------------------------------------
emit_summary
