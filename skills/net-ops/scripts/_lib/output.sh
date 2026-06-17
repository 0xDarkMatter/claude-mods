# net-ops :: _lib/output.sh
# Output mode handling for probe scripts. Three renderings of the same stream:
#   - panel (default at a TTY): the term.sh enclosing panel — section sub-headers
#     on the │ rail, colored term_mark check rows, a footer health indicator.
#   - text (piped / non-TTY): legacy [PASS]/[FAIL] lines + a SUMMARY block. Kept
#     byte-stable because humans AND LLMs scan it for the first [FAIL]; tests and
#     pipes depend on it.
#   - json (--json): newline-delimited JSON, one record per check + a summary.
#
# The panel is the human default (per docs/TERMINAL-DESIGN.md); it never touches
# the piped/--json data product, so stream behaviour is unchanged for consumers.
#
# Usage in a probe script:
#   source "$(dirname "$0")/../_lib/output.sh"
#   PANEL_TITLE="net · linux probe"     # optional; titles the panel header
#   parse_output_flags "$@"
#   # then use section / pass / fail / info / emit_summary as before

JSON_MODE="${JSON_MODE:-0}"

# Shared terminal toolkit (skills/_lib/term.sh) for the panel rendering. Absent ->
# the legacy text path is used, so this degrades cleanly with no behaviour change.
__net_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__net_lib:-}" ] && [ -f "$__net_lib/term.sh" ]; then
    . "$__net_lib/term.sh"
    __NET_HAVE_TERM=1
else
    __NET_HAVE_TERM=0
fi

# Panel header title — a probe script may override before the first section().
PANEL_TITLE="${PANEL_TITLE:-net-ops}"
__PANEL_OPEN=0

parse_output_flags() {
    for a in "$@"; do
        [[ "$a" == "--json" ]] && JSON_MODE=1
    done
}

# Panel applies in text mode only, when stdout is a TTY (or FORCE_COLOR forces a
# render for verification). Piped/non-TTY text consumers get the legacy format.
_panel_active() {
    [[ "$JSON_MODE" -eq 1 || "$__NET_HAVE_TERM" -eq 0 ]] && return 1
    [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]
}

# Lazily open the panel frame (term_init + header + a breath row) on first use.
_panel_open() {
    [[ "$__PANEL_OPEN" -eq 1 ]] && return 0
    term_init
    term_panel_open net-ops "$PANEL_TITLE"
    term_panel_vert
    __PANEL_OPEN=1
}

# JSON-safe string escaper. Handles backslash, double-quote, and control chars.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# These are the public API. They route to panel / text / JSON per mode.
PASS_COUNT=0
FAIL_COUNT=0
FIRST_FAIL=""
CURRENT_SECTION=""

section() {
    CURRENT_SECTION="$1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"section","name":"%s"}\n' "$(_json_escape "$1")"
    elif _panel_active; then
        _panel_open
        term_panel_vert
        term_panel_line "$(term_color cyan "$1")"
    else
        echo
        echo "=== $1 ==="
    fi
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"pass","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    elif _panel_active; then
        _panel_open
        term_status_row ok "$1" "${2:-}"
    else
        echo "[PASS] $1${2:+ :: $2}"
    fi
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="[$CURRENT_SECTION] $1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"fail","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    elif _panel_active; then
        _panel_open
        term_status_row bad "$1" "${2:-}"
    else
        echo "[FAIL] $1${2:+ :: $2}"
    fi
}

# Call from end of probe to emit summary record / block / panel footer.
emit_summary() {
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"summary","pass":%d,"fail":%d,"first_fail":"%s"}\n' \
            "$PASS_COUNT" "$FAIL_COUNT" "$(_json_escape "$FIRST_FAIL")"
    elif _panel_active; then
        _panel_open
        [[ -n "$FIRST_FAIL" ]] && { term_panel_vert; term_panel_line "$(term_color dim "first fail: $FIRST_FAIL")"; }
        term_panel_vert
        local state="healthy" health="$PASS_COUNT ok"
        if [[ "$FAIL_COUNT" -gt 0 ]]; then
            state="critical"; health="$FAIL_COUNT fail ${TERM_DOT} $PASS_COUNT ok"
        fi
        term_panel_close "--json for data ${TERM_DOT} --redact to mask" "$(term_health "$state" "$health")"
    else
        echo
        echo "=== SUMMARY ==="
        echo "  PASS: $PASS_COUNT    FAIL: $FAIL_COUNT"
        if [[ -n "$FIRST_FAIL" ]]; then
            echo "  First failure: $FIRST_FAIL"
        else
            echo "  No failures."
        fi
    fi
}

# Helper for scripts that want to suppress informational/diagnostic output
# (the non-PASS/FAIL annotations like scutil dumps) in JSON mode.
info() {
    if [[ "$JSON_MODE" -eq 1 ]]; then
        # Optional: emit info records. Keep silent for cleaner JSON parsing.
        return 0
    elif _panel_active; then
        term_panel_line "$(term_color dim "$*")"
    else
        echo "$@"
    fi
}
