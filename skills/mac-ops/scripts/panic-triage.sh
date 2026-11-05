#!/usr/bin/env bash
# mac-ops :: panic-triage.sh
# Decode the most recent kernel panic (or one specified by path/time).
# Emits panic string, suspect kext, and the pre-panic timeline window.
#
# Usage:
#   scripts/panic-triage.sh                              # most recent panic
#   scripts/panic-triage.sh -f <path>                    # specific report file
#   scripts/panic-triage.sh -t '2026-05-14 03:14:22'     # by timestamp (UTC)
#   scripts/panic-triage.sh -m 15                        # widen pre-panic window to 15 min

set -u

PANIC_FILE=""
PANIC_TIME=""
WINDOW_MIN=10

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) PANIC_FILE="$2"; shift 2 ;;
        -t|--time) PANIC_TIME="$2"; shift 2 ;;
        -m|--minutes) WINDOW_MIN="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  -f, --file PATH        Specific .panic or Kernel*.ips file to decode
  -t, --time 'YYYY-MM-DD HH:MM:SS'   Timestamp anchor for pre-panic window
  -m, --minutes N        Pre-panic window in minutes (default: 10)
  --json, --redact, --quiet, --verbose   Standard flags

Exit codes:
  0 success
  3 no panic reports found
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

panic_dir="/Library/Logs/DiagnosticReports"

# ----------------------------------------------------------------------------
section "1. PANIC REPORT SELECTION"
# ----------------------------------------------------------------------------
if [[ -z "$PANIC_FILE" ]]; then
    # Find newest panic report
    PANIC_FILE=$(find "$panic_dir" -maxdepth 1 \( -name "*.panic" -o -name "Kernel*.ips" \) 2>/dev/null \
                | xargs ls -t 2>/dev/null | head -1)
fi

if [[ -z "$PANIC_FILE" ]] || [[ ! -f "$PANIC_FILE" ]]; then
    log_info "Panic reports" "none found in $panic_dir"
    emit_summary
    exit "$EXIT_NOT_FOUND"
fi

log_pass "Panic report selected" "$PANIC_FILE"
panic_mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$PANIC_FILE" 2>/dev/null)
note "  Last modified: $panic_mtime"

# ----------------------------------------------------------------------------
section "2. PANIC STRING + KEXT EXTRACTION"
# ----------------------------------------------------------------------------
if [[ "$PANIC_FILE" == *.ips ]]; then
    # .ips files are JSON-with-extras. The first line is a JSON header,
    # the rest of the file is structured but not strict JSON.
    panic_string=$(head -200 "$PANIC_FILE" | grep -m1 "panic(" | head -1)
    # Extract the bundleID of the panicking kext (best-effort)
    suspect_kext=$(grep -m1 -oE '"bundleID":"[^"]+"' "$PANIC_FILE" | head -1 | sed 's/.*"://; s/"//g')
else
    panic_string=$(grep -m1 "^panic(" "$PANIC_FILE")
    # In old .panic format the "Kernel Extensions in backtrace" line lists suspects
    suspect_kext=$(awk '/Kernel Extensions in backtrace:/{getline; print; exit}' "$PANIC_FILE" | awk -F'[()]' '{print $2}')
fi

if [[ -n "$panic_string" ]]; then
    log_pass "Panic string extracted"
    note "  $panic_string"
fi

if [[ -n "$suspect_kext" ]]; then
    case "$suspect_kext" in
        com.apple.*) log_warn "Suspect kext" "$suspect_kext (Apple — harder to fix; check macOS update)" ;;
        *)            log_fail "Suspect kext" "$suspect_kext (third-party — primary suspect)" ;;
    esac
else
    log_info "Suspect kext" "could not extract from report — check report manually"
fi

# Match panic string against the common-causes catalog
note "  Pattern match (quick lookup; see references/panic-codes.md for full catalog):"
case "$panic_string" in
    *"Sleep wake failure"*)
        note "    → Driver power-state bug. Often USB / Bluetooth / GPU. Check kext list around panic." ;;
    *"Unresponsive bootstrap subsystem"*)
        note "    → launchd deadlock. Usually a third-party LaunchDaemon. Audit /Library/LaunchDaemons/." ;;
    *"WindowServer"*)
        note "    → GPU driver / display kext fault. Try disabling external display, alternative GPU mode." ;;
    *"double_fault"*|*"page_fault"*)
        note "    → Kernel-mode memory corruption. Bad RAM or buggy kext. Run memtest from recoveryOS." ;;
    *"panic_kthread"*)
        note "    → Kernel watchdog timeout. A driver hung in infinite loop. Examine pre-panic kext activity." ;;
    *"Unable to find driver"*)
        note "    → Boot-time kext failed to load. Often after macOS update. Try safe-boot." ;;
    *)
        note "    → No quick-pattern match. See references/panic-codes.md." ;;
esac

# ----------------------------------------------------------------------------
section "3. PRE-PANIC TIMELINE"
# ----------------------------------------------------------------------------
if [[ -z "$PANIC_TIME" ]]; then
    PANIC_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$PANIC_FILE" 2>/dev/null)
fi
note "  Anchor: $PANIC_TIME  (window: ${WINDOW_MIN} min before)"

# Convert anchor to epoch, compute start
if anchor_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$PANIC_TIME" "+%s" 2>/dev/null); then
    start_epoch=$((anchor_epoch - WINDOW_MIN * 60))
    start_str=$(date -r "$start_epoch" "+%Y-%m-%d %H:%M:%S")
    note "  Searching unified log from $start_str to $PANIC_TIME ..."

    # Filter the noisy stuff out; surface kernel + kext + IO + power events
    log show --start "$start_str" --end "$PANIC_TIME" --style compact \
        --predicate '(subsystem == "com.apple.kernel" OR subsystem == "com.apple.iokit" OR processImagePath CONTAINS "kernel" OR senderImagePath CONTAINS ".kext") AND (messageType == "Default" OR messageType == "Error" OR messageType == "Fault")' \
        2>/dev/null | tail -50 | sed 's/^/    /'

    log_info "Pre-panic events captured" "${WINDOW_MIN} min window"
else
    log_warn "Pre-panic timeline" "could not parse panic timestamp; pass -t explicitly"
fi

# ----------------------------------------------------------------------------
section "4. CONTEXT: RECENT PANICS"
# ----------------------------------------------------------------------------
recent_panics=$(find "$panic_dir" -maxdepth 1 \( -name "*.panic" -o -name "Kernel*.ips" \) \
    -mtime -30 2>/dev/null | wc -l | tr -d ' ')
log_info "Panics in last 30 days" "$recent_panics"

if [[ "$recent_panics" -gt 1 ]]; then
    note "  Recent panic files:"
    find "$panic_dir" -maxdepth 1 \( -name "*.panic" -o -name "Kernel*.ips" \) -mtime -30 2>/dev/null \
        | xargs ls -lt 2>/dev/null | head -5 | awk '{print "    "$NF" — "$6" "$7" "$8}'
fi

# ----------------------------------------------------------------------------
emit_summary
