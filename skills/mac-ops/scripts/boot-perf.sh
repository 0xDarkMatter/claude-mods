#!/usr/bin/env bash
# mac-ops :: boot-perf.sh
# Measure boot duration and identify slow startup components.
# macOS records boot events in the unified log; we extract the markers.

set -u

DAYS=7
SHOW_N=10
# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --show) SHOW_N="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --days N       How many days of boot history to scan (default: 7)
  --show N       How many recent boots to show (default: 10)
  --json, --redact, --quiet, --verbose

Healthy:
  Apple Silicon Mac to login:   10-20s
  Intel Mac (SSD):              20-35s
  Intel Mac (HDD, vintage):     45-90s
  Failing storage:              60s+ with stalls
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
section "1. RECENT BOOT TIMES"
# ----------------------------------------------------------------------------
# Approach: find each "kernel boot" marker, then compute time until loginwindow
# completes its initial setup. The unified log has BOOT_TIME / "kernel boot"
# markers as well as loginwindow setup messages.
note "  Scanning unified log for last ${DAYS}d of boot events..."

# macOS marks the kernel boot start with "boot complete" + "boot session" + "first user event"
# We grep for kernel-version + UUID lines that mark a fresh boot.
boots_raw=$(log show --last "${DAYS}d" --style compact --predicate \
    'process == "kernel" AND (eventMessage CONTAINS "Darwin Kernel Version" OR eventMessage CONTAINS "boot args")' \
    2>/dev/null | head -100)

if [[ -z "$boots_raw" ]]; then
    log_info "Boot events" "no boot markers found in window — try a wider --days N"
else
    # Each fresh boot logs "Darwin Kernel Version" once; count them
    boot_count=$(echo "$boots_raw" | grep -c "Darwin Kernel Version" || echo 0)
    log_info "Boots in last ${DAYS}d" "${boot_count:-0}"
    note "  Recent boot markers (most recent ${SHOW_N}):"
    echo "$boots_raw" | grep "Darwin Kernel Version" | tail -"$SHOW_N" | awk '{print $1, $2}' | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "2. CURRENT BOOT DURATION ESTIMATE"
# ----------------------------------------------------------------------------
# Find the most recent boot marker (Darwin Kernel Version line)
boot_start_line=$(log show --last "${DAYS}d" --style compact --predicate \
    'process == "kernel" AND eventMessage CONTAINS "Darwin Kernel Version"' \
    2>/dev/null | tail -1)
boot_start_ts=$(echo "$boot_start_line" | awk '{print $1, $2}')

if [[ -z "$boot_start_ts" ]]; then
    log_warn "Boot start timestamp" "could not extract"
else
    note "  Boot start:  $boot_start_ts"
    # Find first WindowServer / loginwindow ready event AFTER boot
    if loginwindow_evt=$(log show --start "$boot_start_ts" --style compact 2>/dev/null \
            | grep -E "(loginwindow.*started|WindowServer.*started|opendirectoryd started)" \
            | head -3); then
        note "  Earliest user-space events after boot:"
        echo "$loginwindow_evt" | sed 's/^/    /'
    fi

    # Attempt to compute seconds from boot to loginwindow
    first_user_event=$(echo "$loginwindow_evt" | head -1 | awk '{print $1, $2}')
    if [[ -n "$first_user_event" ]] && command -v gdate >/dev/null 2>&1; then
        b=$(gdate -d "$boot_start_ts" +%s 2>/dev/null)
        f=$(gdate -d "$first_user_event" +%s 2>/dev/null)
        if [[ -n "$b" ]] && [[ -n "$f" ]]; then
            diff=$((f - b))
            log_info "Boot duration (boot → user-space)" "${diff}s"
        fi
    else
        log_info "Boot duration calc" "install coreutils (brew install coreutils) for gdate-based timing"
    fi
fi

# ----------------------------------------------------------------------------
section "3. SLOW LAUNCH AGENTS"
# ----------------------------------------------------------------------------
# Find agents that took long to start. Narrow to launchd messages specifically;
# avoid matching Wi-Fi/airportd "throttled=0" noise.
slow_events=$(log show --last "${DAYS}d" --style compact --predicate \
    'process == "launchd" AND (eventMessage CONTAINS "took longer than" OR eventMessage CONTAINS "throttled by" OR eventMessage CONTAINS "exited with abnormal code")' \
    2>/dev/null | head -20)

if [[ -z "$slow_events" ]]; then
    log_pass "Slow launchd events" "none found"
else
    n=$(echo "$slow_events" | wc -l | tr -d ' ')
    log_warn "Slow launchd events" "$n events — see below"
    echo "$slow_events" | head -10 | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "4. LOGINWINDOW DELAYS"
# ----------------------------------------------------------------------------
# loginwindow logs assertions about slow login items
loginwindow_delays=$(log show --last "${DAYS}d" --style compact \
    --predicate 'process == "loginwindow"' 2>/dev/null \
    | grep -iE "(delay|slow|timed out|waited)" \
    | head -10)

if [[ -n "$loginwindow_delays" ]]; then
    log_warn "loginwindow delay messages" "see below"
    echo "$loginwindow_delays" | sed 's/^/    /'
else
    log_pass "loginwindow delays" "none reported"
fi

# ----------------------------------------------------------------------------
section "5. SAFE-BOOT / VERBOSE-BOOT INDICATORS"
# ----------------------------------------------------------------------------
# nvram for boot args
boot_args=$(nvram boot-args 2>/dev/null | awk '{print $2}')
if [[ "$boot_args" == *"-v"* ]] || [[ "$boot_args" == *"-x"* ]]; then
    log_warn "NVRAM boot-args" "$boot_args — non-default boot mode"
else
    log_pass "NVRAM boot-args" "default (${boot_args:-empty})"
fi

# ----------------------------------------------------------------------------
emit_summary
