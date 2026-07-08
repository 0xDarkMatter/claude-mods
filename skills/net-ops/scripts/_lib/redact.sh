# net-ops :: _lib/redact.sh
# Shared opsec redaction for diagnostic output. Source from any bash script:
#
#   source "$(dirname "$0")/../_lib/redact.sh"
#   parse_redact_flag "$@"
#   maybe_redact_self "$@"    # re-invokes self without --redact if flag set
#
# Public IPs (1.1.1.1, 8.8.8.8, Tailscale 100.100.100.100 anchor) are
# preserved — they're diagnostic landmarks. Private/CGNAT/link-local
# ranges, MACs, and *.ts.net tailnet names are masked.

REDACT="${REDACT:-0}"

parse_redact_flag() {
    for a in "$@"; do
        [[ "$a" == "--redact" ]] && REDACT=1
    done
}

redact_filter() {
    if [[ "${REDACT:-0}" -eq 0 ]]; then cat; return; fi
    perl -pe '
        # Preserve well-known anchors first
        s/100\.100\.100\.100/__TS_MAGIC__/g;
        # Redact private / CGNAT / link-local IPv4
        s/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/10.X.X.X/g;
        s/\b172\.(1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3}\b/172.X.X.X/g;
        s/\b192\.168\.\d{1,3}\.\d{1,3}\b/192.168.X.X/g;
        s/\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/100.X.X.X/g;
        s/\b169\.254\.\d{1,3}\.\d{1,3}\b/169.254.X.X/g;
        # MAC addresses (both : and - separators)
        s/\b[0-9a-fA-F]{2}([:-])[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\b/XX:XX:XX:XX:XX:XX/g;
        # Tailscale tailnet names
        s/\b[a-z0-9-]+\.ts\.net\b/REDACTED.ts.net/g;
        # Restore anchors
        s/__TS_MAGIC__/100.100.100.100/g;
    '
}

# Helper: self-reinvoke and pipe through post-processing filters when needed.
# Handles both --redact (mask private addrs) and --json (drop non-JSON chatter).
# Avoids bash 3.2 exec-redirect quirks via single-level subprocess.
maybe_redact_self() {
    # Only reinvoke if at least one filter is active
    [[ "${REDACT:-0}" -eq 1 ]] || [[ "${JSON_MODE:-0}" -eq 1 ]] || return 0
    # Prevent infinite recursion
    [[ "${_NETOPS_POSTPROCESSED:-0}" -eq 1 ]] && return 0
    export _NETOPS_POSTPROCESSED=1

    # Strip --redact from args (child runs without it to avoid double-recursion).
    # --json is preserved so JSON_MODE stays set in the child for any code that
    # changes behavior in JSON mode (e.g. info() suppression in output.sh).
    local cleaned_args=()
    for a in "$@"; do [[ "$a" != "--redact" ]] && cleaned_args+=("$a"); done

    if [[ "${JSON_MODE:-0}" -eq 1 ]] && [[ "${REDACT:-0}" -eq 1 ]]; then
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | grep '^{' | redact_filter
    elif [[ "${JSON_MODE:-0}" -eq 1 ]]; then
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | grep '^{'
    else
        "$0" ${cleaned_args[@]+"${cleaned_args[@]}"} | redact_filter
    fi
    exit "${PIPESTATUS[0]}"
}
