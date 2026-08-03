#!/usr/bin/env bash
# mac-ops :: quickrun.sh
# One-shot "what's wrong with my Mac?" runner. Sequences the 5 highest-yield
# audits and emits a single consolidated report.
#
# This is the script to run if you have 60 seconds and want to know whether
# something needs attention. For deep dives, drill into individual scripts.

set -u

SHORT_DAYS=7
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) SHORT_DAYS="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --days N           Lookback for log-based audits (default: 7)
  --json             Emit consolidated NDJSON
  --redact           Mask private addrs / hostnames / serials

Runs (in order):
  1. health-audit         — orchestrator across 8 rungs
  2. startup-audit        — login items + launchd inventory
  3. storage-pressure     — APFS snapshots + caches breakdown
  4. wake-reasons         — pmset log analysis (last week)
  5. tcc-audit (denied)   — what privacy permissions were denied

Output: one consolidated SUMMARY at end with all PASS/FAIL counts and the
top 3 issues to address.

Time: 60-90 seconds typical (log show queries dominate).
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"
source "$(dirname "$0")/_lib/panel.sh"
panel_init

SCRIPTS_DIR="$(dirname "$0")"

# Aggregate counters across all sub-scripts
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_WARN=0
TOTAL_INFO=0
ALL_FAILS=()
ALL_WARNS=()

run_subscript() {
    local label="$1"
    local script="$2"
    shift 2
    note ""
    note "════════════════════════════════════════════════════════════════"
    note "  $label"
    note "════════════════════════════════════════════════════════════════"

    # Capture sub-script output (suppress its own SUMMARY since we'll do our own).
    # Force NO_PANEL so children emit parseable plain text — we render our own panel.
    local out
    out=$(NO_PANEL=1 bash "$SCRIPTS_DIR/$script" --quiet "$@" 2>&1 || true)

    # Echo the sub-script's findings (everything before its SUMMARY)
    echo "$out" | sed -n '/^=== /,/^=== SUMMARY ===/p' | sed '/^=== SUMMARY ===/q' | sed '$d'

    # Extract sub-script's pass/fail/warn counts from its SUMMARY line
    local summary_line
    summary_line=$(echo "$out" | grep -E "^  PASS: [0-9]+" | head -1)
    if [[ -n "$summary_line" ]]; then
        local pass fail warn info
        pass=$(echo "$summary_line" | grep -oE "PASS: [0-9]+" | awk '{print $2}')
        fail=$(echo "$summary_line" | grep -oE "FAIL: [0-9]+" | awk '{print $2}')
        warn=$(echo "$summary_line" | grep -oE "WARN: [0-9]+" | awk '{print $2}')
        info=$(echo "$summary_line" | grep -oE "INFO: [0-9]+" | awk '{print $2}')
        TOTAL_PASS=$((TOTAL_PASS + ${pass:-0}))
        TOTAL_FAIL=$((TOTAL_FAIL + ${fail:-0}))
        TOTAL_WARN=$((TOTAL_WARN + ${warn:-0}))
        TOTAL_INFO=$((TOTAL_INFO + ${info:-0}))
    fi

    # Collect FAIL and WARN lines for the consolidated summary
    while IFS= read -r line; do
        [[ -n "$line" ]] && ALL_FAILS+=("[$label] $line")
    done < <(echo "$out" | grep -E "^\[FAIL\]" | sed 's/^\[FAIL\] //')
    while IFS= read -r line; do
        [[ -n "$line" ]] && ALL_WARNS+=("[$label] $line")
    done < <(echo "$out" | grep -E "^\[WARN\]" | sed 's/^\[WARN\] //')
}

note "  Starting mac-ops quickrun (this takes ~60-90s due to log show queries)..."

run_subscript "1. HEALTH AUDIT" "health-audit.sh" --days "$SHORT_DAYS"
run_subscript "2. STARTUP INVENTORY" "startup-audit.sh"
run_subscript "3. STORAGE PRESSURE" "storage-pressure.sh"
run_subscript "4. WAKE REASONS (last ${SHORT_DAYS}d)" "wake-reasons.sh" --since "${SHORT_DAYS}d"
run_subscript "5. TCC DENIALS" "tcc-audit.sh" --denied

# ----------------------------------------------------------------------------
note ""
note "════════════════════════════════════════════════════════════════"
note "  CONSOLIDATED VERDICT"
note "════════════════════════════════════════════════════════════════"

if [[ "$JSON_MODE" -eq 1 ]]; then
    printf '{"type":"quickrun_summary","pass":%d,"fail":%d,"warn":%d,"info":%d,"fail_count":%d,"warn_count":%d}\n' \
        "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_WARN" "$TOTAL_INFO" \
        "${#ALL_FAILS[@]}" "${#ALL_WARNS[@]}"
elif panel_enabled; then
    hostname_short=$(scutil --get LocalHostName 2>/dev/null | head -c 30 || hostname -s | head -c 30)
    echo ""
    term_panel_open mac-ops "mac-ops ${TERM_DOT} quickrun" "$hostname_short"
    term_panel_vert
    term_summary_line "$((TOTAL_PASS+TOTAL_FAIL+TOTAL_WARN+TOTAL_INFO)) checks across 5 audits ${TERM_DOT} $TOTAL_FAIL fail ${TERM_DOT} $TOTAL_WARN warn"
    term_panel_vert

    if [[ "${#ALL_FAILS[@]}" -gt 0 ]]; then
        term_section "FAILED" "failing" "${#ALL_FAILS[@]}"
        n=${#ALL_FAILS[@]}
        i=0
        for f in "${ALL_FAILS[@]}"; do
            i=$((i+1))
            if [[ "$i" -eq "$n" ]]; then connector="$TERM_TREE_LAST"; else connector="$TERM_TREE_BRANCH"; fi
            line="$f"
            (( ${#line} > 100 )) && line="${line:0:97}..."
            printf '%s   %s %s\n' \
                "$(term_color dim "$TERM_TREE_VERT")" \
                "$connector" \
                "$line"
            [[ "$i" -ge 10 ]] && { printf '%s   %s %s\n' "$(term_color dim "$TERM_TREE_VERT")" "$TERM_TREE_LAST" "$(term_color dim "... +$((n-10)) more")"; break; }
        done
        term_panel_vert
    fi

    if [[ "${#ALL_WARNS[@]}" -gt 0 ]]; then
        term_section "WARN" "warning" "${#ALL_WARNS[@]}"
        n=${#ALL_WARNS[@]}
        i=0
        for w in "${ALL_WARNS[@]}"; do
            i=$((i+1))
            if [[ "$i" -eq "$n" ]]; then connector="$TERM_TREE_LAST"; else connector="$TERM_TREE_BRANCH"; fi
            line="$w"
            (( ${#line} > 100 )) && line="${line:0:97}..."
            printf '%s   %s %s\n' \
                "$(term_color dim "$TERM_TREE_VERT")" \
                "$connector" \
                "$line"
            [[ "$i" -ge 10 ]] && { printf '%s   %s %s\n' "$(term_color dim "$TERM_TREE_VERT")" "$TERM_TREE_LAST" "$(term_color dim "... +$((n-10)) more")"; break; }
        done
        term_panel_vert
    fi

    term_section "OK" "pass" "$TOTAL_PASS"
    if [[ "$TOTAL_INFO" -gt 0 ]]; then
        term_section "info" "info" "$TOTAL_INFO"
    fi
    term_panel_vert

    health_state="healthy"
    [[ "$TOTAL_WARN" -gt 0 ]] && health_state="warning"
    [[ "$TOTAL_FAIL" -gt 0 ]] && health_state="critical"
    right_health="$(term_health "$health_state" "$TOTAL_FAIL fail ${TERM_DOT} $TOTAL_WARN warn")"
    term_panel_close "" "$right_health"
    echo ""

    if [[ "${#ALL_FAILS[@]}" -eq 0 ]] && [[ "${#ALL_WARNS[@]}" -eq 0 ]]; then
        echo "  ✓ System looks clean. No FAILs or WARNs across 5 audits."
    fi
    echo "  Next: drill any FAIL into its source script (--verbose for detail)"
else
    echo
    echo "  Aggregate: PASS $TOTAL_PASS    FAIL $TOTAL_FAIL    WARN $TOTAL_WARN    INFO $TOTAL_INFO"
    echo
    if [[ "${#ALL_FAILS[@]}" -gt 0 ]]; then
        echo "  ⚠ FAILURES (${#ALL_FAILS[@]}):"
        for f in ${ALL_FAILS[@]+"${ALL_FAILS[@]}"}; do
            echo "    • $f"
        done | head -10
    fi
    if [[ "${#ALL_WARNS[@]}" -gt 0 ]]; then
        echo
        echo "  ⚠ WARNINGS (${#ALL_WARNS[@]}):"
        for w in ${ALL_WARNS[@]+"${ALL_WARNS[@]}"}; do
            echo "    • $w"
        done | head -10
    fi
    if [[ "${#ALL_FAILS[@]}" -eq 0 ]] && [[ "${#ALL_WARNS[@]}" -eq 0 ]]; then
        echo "  ✓ System looks clean. No FAILs or WARNs across 5 audits."
    fi
    echo
    echo "  Next steps:"
    echo "    - Drill into any FAIL: see 'Next:' lines emitted by each sub-script"
    echo "    - Run individual scripts with --verbose for more detail"
    echo "    - See references/worked-examples.md for diagnostic patterns"
fi
