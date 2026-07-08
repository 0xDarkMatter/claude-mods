# mac-ops common helpers
# Source from any script:  source "$(dirname "$0")/_lib/common.sh"
#
# Provides:
#   - Semantic exit codes
#   - log_pass / log_fail / log_warn / log_info — [TAG] message lines
#   - JSON-mode emitters (mac_emit_check, mac_emit_section, mac_emit_summary)
#   - Mode flags parsing: --json --redact --quiet
#   - Reuses net-ops _lib/redact.sh patterns via the shared term.sh

set -u

# Semantic exit codes
EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_NOT_FOUND=3
EXIT_VALIDATION=4
EXIT_PRECONDITION=5
EXIT_TIMEOUT=6
EXIT_UNAVAILABLE=7

# Mode flags (set by parse_common_flags)
JSON_MODE="${JSON_MODE:-0}"
REDACT="${REDACT:-0}"
QUIET="${QUIET:-0}"
VERBOSE="${VERBOSE:-0}"

# Running counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
INFO_COUNT=0
FIRST_FAIL=""
CURRENT_SECTION=""

parse_common_flags() {
    for a in "$@"; do
        case "$a" in
            --json)         JSON_MODE=1 ;;
            --redact)       REDACT=1 ;;
            --quiet|-q)     QUIET=1 ;;
            --verbose|-v)   VERBOSE=1 ;;
        esac
    done
}

# JSON-safe escaper for strings
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Section header — sets CURRENT_SECTION and prints a banner (or JSON record).
section() {
    CURRENT_SECTION="$1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"section","name":"%s"}\n' "$(_json_escape "$1")"
    else
        [[ "$QUIET" -eq 1 ]] || { echo; echo "=== $1 ==="; }
    fi
}

# Check result emitters
log_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"pass","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[PASS] $1${2:+ :: $2}"
    fi
}

log_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="[$CURRENT_SECTION] $1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"fail","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[FAIL] $1${2:+ :: $2}"
    fi
}

log_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"warn","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[WARN] $1${2:+ :: $2}"
    fi
}

log_info() {
    INFO_COUNT=$((INFO_COUNT + 1))
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"info","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[INFO] $1${2:+ :: $2}"
    fi
}

# Free-form info text — text in default mode, suppressed in JSON
note() {
    [[ "$JSON_MODE" -eq 1 ]] && return 0
    [[ "$QUIET" -eq 1 ]] && return 0
    echo "$@"
}

emit_summary() {
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"summary","pass":%d,"fail":%d,"warn":%d,"info":%d,"first_fail":"%s"}\n' \
            "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$INFO_COUNT" "$(_json_escape "$FIRST_FAIL")"
    else
        echo
        echo "=== SUMMARY ==="
        echo "  PASS: $PASS_COUNT    FAIL: $FAIL_COUNT    WARN: $WARN_COUNT    INFO: $INFO_COUNT"
        if [[ -n "$FIRST_FAIL" ]]; then
            echo "  First failure: $FIRST_FAIL"
        else
            echo "  No failures."
        fi
    fi
}

# Redact filter: same regex set as net-ops's, plus macOS-specific patterns.
# Preserves Tailscale's 100.100.100.100 and public DNS anchors.
redact_filter() {
    if [[ "$REDACT" -eq 0 ]]; then cat; return; fi
    perl -pe '
        s/100\.100\.100\.100/__TS_MAGIC__/g;
        s/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/10.X.X.X/g;
        s/\b172\.(1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3}\b/172.X.X.X/g;
        s/\b192\.168\.\d{1,3}\.\d{1,3}\b/192.168.X.X/g;
        s/\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/100.X.X.X/g;
        s/\b169\.254\.\d{1,3}\.\d{1,3}\b/169.254.X.X/g;
        s/\b[0-9a-fA-F]{2}([:-])[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\b/XX:XX:XX:XX:XX:XX/g;
        s/\b[a-z0-9-]+\.ts\.net\b/REDACTED.ts.net/g;
        # macOS specifics: hostnames matching <name>.local or <name>.lan
        s/\b([a-zA-Z0-9-]+)\.local\b/HOSTNAME.local/g;
        # macOS serial numbers (12-char base32-ish, only when prefixed by Serial)
        s/Serial(?:Number)?[:= ]+\K[A-Z0-9]{10,14}/REDACTED/g;
        # UUIDs (long volume / device identifiers)
        s/\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b/UUID-REDACTED/gi;
        s/__TS_MAGIC__/100.100.100.100/g;
    '
}

# Self-reinvoke filter — same pattern as net-ops to handle --redact + --json
# compose. Strips --redact from inner argv to prevent infinite recursion.
maybe_filter_self() {
    [[ "$REDACT" -eq 1 ]] || [[ "$JSON_MODE" -eq 1 ]] || return 0
    [[ "${_MACOPS_FILTERED:-0}" -eq 1 ]] && return 0
    export _MACOPS_FILTERED=1
    local cleaned_args=()
    for a in "$@"; do [[ "$a" != "--redact" ]] && cleaned_args+=("$a"); done
    if [[ "$JSON_MODE" -eq 1 ]] && [[ "$REDACT" -eq 1 ]]; then
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | grep '^{' | redact_filter
    elif [[ "$JSON_MODE" -eq 1 ]]; then
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | grep '^{'
    else
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | redact_filter
    fi
    exit "${PIPESTATUS[0]}"
}

# Convenience: macOS major version (12, 13, 14, 15, 26...)
macos_major() {
    sw_vers -productVersion 2>/dev/null | awk -F. '{print $1}'
}

# Convenience: am I on Apple Silicon?
is_apple_silicon() {
    [[ "$(uname -m)" == "arm64" ]]
}
