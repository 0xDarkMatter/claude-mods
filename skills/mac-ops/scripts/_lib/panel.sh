# mac-ops :: _lib/panel.sh
# Panel-rendering helper that wraps the shared skills/_lib/term.sh API.
# Source AFTER common.sh. Provides:
#
#   panel_init           — detect TTY, source term.sh
#   panel_findings_open  — start collecting findings (called once at top)
#   panel_render <name> <indicator>
#                        — emit the state-grouped panel using collected
#                          findings + log_pass/log_fail/log_warn counts
#
# Collection happens transparently: the existing log_pass / log_fail /
# log_warn / log_info from common.sh ALSO push (state, section, label,
# detail) tuples into MAC_PANEL_FINDINGS when panel mode is on.

# Locate the project-level term.sh (4 levels up from script dir, then _lib)
__MACOPS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__MACOPS_TERM_LIB="$(cd "$__MACOPS_SCRIPT_DIR/../../../_lib" 2>/dev/null && pwd)/term.sh"

# Panel mode default: auto. Force on with FORCE_PANEL=1, off with NO_PANEL=1.
PANEL_MODE="${PANEL_MODE:-auto}"
MAC_PANEL_ENABLED=0
MAC_PANEL_FINDINGS=()    # each entry: "state|section|label|detail"

panel_init() {
    # If JSON output requested, never enable panels — JSON is the contract
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then return 0; fi

    # NO_PANEL forces off; FORCE_PANEL forces on; otherwise TTY-detect
    if [[ "${NO_PANEL:-0}" -eq 1 ]]; then return 0; fi

    # Source term.sh if available.
    if [[ -f "$__MACOPS_TERM_LIB" ]]; then
        # shellcheck source=/dev/null
        . "$__MACOPS_TERM_LIB"
        term_init
    else
        return 0
    fi

    # Use panel mode if stdout is a TTY or forced
    if [[ "${FORCE_PANEL:-0}" -eq 1 ]] || [[ "$TERM_TTY" -eq 1 ]]; then
        MAC_PANEL_ENABLED=1
    fi
}

panel_enabled() { [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; }

# Override common.sh log_* functions to also collect findings.
# (These are sourced AFTER common.sh and will override its versions.)
__MAC_ORIGINAL_PASS=$(declare -f log_pass || true)
__MAC_ORIGINAL_FAIL=$(declare -f log_fail || true)
__MAC_ORIGINAL_WARN=$(declare -f log_warn || true)
__MAC_ORIGINAL_INFO=$(declare -f log_info || true)

# Wrap each log function so it both updates counters AND collects findings.
# When panel mode is on, ALSO suppress the inline echo — we'll render at end.

log_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    MAC_PANEL_FINDINGS+=("pass|${CURRENT_SECTION}|$1|${2:-}")
    if [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; then return 0; fi
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"pass","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[PASS] $1${2:+ :: $2}"
    fi
}

log_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="[$CURRENT_SECTION] $1"
    MAC_PANEL_FINDINGS+=("fail|${CURRENT_SECTION}|$1|${2:-}")
    if [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; then return 0; fi
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"fail","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[FAIL] $1${2:+ :: $2}"
    fi
}

log_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    MAC_PANEL_FINDINGS+=("warn|${CURRENT_SECTION}|$1|${2:-}")
    if [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; then return 0; fi
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"warn","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[WARN] $1${2:+ :: $2}"
    fi
}

log_info() {
    INFO_COUNT=$((INFO_COUNT + 1))
    MAC_PANEL_FINDINGS+=("info|${CURRENT_SECTION}|$1|${2:-}")
    if [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; then return 0; fi
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"info","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[INFO] $1${2:+ :: $2}"
    fi
}

# In panel mode, suppress `note` and `section` so the body stays clean —
# rendering happens at the end via panel_render.
__MAC_ORIGINAL_NOTE=$(declare -f note || true)
__MAC_ORIGINAL_SECTION=$(declare -f section || true)

note() {
    [[ "$MAC_PANEL_ENABLED" -eq 1 ]] && return 0
    [[ "${JSON_MODE:-0}" -eq 1 ]] && return 0
    [[ "${QUIET:-0}" -eq 1 ]] && return 0
    echo "$@"
}

section() {
    CURRENT_SECTION="$1"
    if [[ "$MAC_PANEL_ENABLED" -eq 1 ]]; then return 0; fi
    if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        printf '{"type":"section","name":"%s"}\n' "$(_json_escape "$1")"
    else
        [[ "${QUIET:-0}" -eq 1 ]] || { echo; echo "=== $1 ==="; }
    fi
}

# Render the collected findings as a state-grouped tree panel.
# Args:
#   $1 = script tag (e.g. "health-audit")
#   $2 = right indicator (e.g. hostname)
panel_render() {
    if [[ "$MAC_PANEL_ENABLED" -ne 1 ]]; then
        # Not panel mode — just emit the standard summary block
        emit_summary
        return
    fi

    local tag="${1:-mac-ops}"
    local indicator="${2:-}"

    echo ""
    term_panel_open mac-ops "mac-ops · $tag" "$indicator"
    term_panel_vert
    term_summary_line "$((PASS_COUNT+FAIL_COUNT+WARN_COUNT+INFO_COUNT)) checks · $FAIL_COUNT fail · $WARN_COUNT warn"
    term_panel_vert

    # Render in order: fail, warn, pass (count only), info (count only)
    local order=(fail warn)
    local labels=(failing warning)
    local i
    for i in 0 1; do
        local st="${order[$i]}"
        local label="${labels[$i]}"
        local count=0
        local entries=()
        local entry
        for entry in ${MAC_PANEL_FINDINGS[@]+"${MAC_PANEL_FINDINGS[@]}"}; do
            [[ "${entry%%|*}" == "$st" ]] && { entries+=("$entry"); count=$((count+1)); }
        done
        [[ "$count" -eq 0 ]] && continue
        term_section "$st" "$label" "$count"
        local n=${#entries[@]}
        local idx=0
        for entry in "${entries[@]}"; do
            local rest="${entry#*|}"
            local section_name="${rest%%|*}"; rest="${rest#*|}"
            local lbl="${rest%%|*}"; rest="${rest#*|}"
            local detail="$rest"
            local connector
            if [[ $((idx + 1)) -eq $n ]]; then connector="$TERM_TREE_LAST"; else connector="$TERM_TREE_BRANCH"; fi
            local sec_short="${section_name%% *}"
            sec_short="${sec_short%.}"
            local one_line
            if [[ -n "$detail" ]]; then
                one_line="$(printf '%-40s %s' "$lbl" "$detail")"
            else
                one_line="$lbl"
            fi
            # 100-char hard truncate
            (( ${#one_line} > 100 )) && one_line="${one_line:0:97}..."
            printf '%s   %s [%s] %s\n' \
                "$(term_color dim "$TERM_TREE_VERT")" \
                "$connector" \
                "$(term_color dim "$sec_short")" \
                "$one_line"
        done
        term_panel_vert
        idx=$((idx+1))
    done

    # Pass + info counts on a single line
    term_section "ok" "pass" "$PASS_COUNT"
    if [[ "$INFO_COUNT" -gt 0 ]]; then
        term_section "info" "info" "$INFO_COUNT"
    fi
    term_panel_vert

    # Determine overall health indicator
    local health_state="healthy"
    [[ "$WARN_COUNT" -gt 0 ]] && health_state="warning"
    [[ "$FAIL_COUNT" -gt 0 ]] && health_state="critical"
    local right_health
    right_health="$(term_health "$health_state" "$FAIL_COUNT fail · $WARN_COUNT warn")"
    term_panel_close "" "$right_health"
    echo ""

    # Also emit a plain SUMMARY line for parseability
    echo "  PASS: $PASS_COUNT    FAIL: $FAIL_COUNT    WARN: $WARN_COUNT    INFO: $INFO_COUNT"
    if [[ -n "$FIRST_FAIL" ]]; then
        echo "  First failure: $FIRST_FAIL"
    fi
}
