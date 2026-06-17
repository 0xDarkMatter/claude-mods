#!/usr/bin/env bash
# net-ops :: reverse-probe.sh
# Diagnose a TARGET host from OUTSIDE — useful when the local probe on the
# target says "all good" but external services / users still report problems.
# Runs from this machine against a target host you can reach (LAN, tailnet,
# public IP, etc).
#
# Usage:
#   scripts/reverse-probe.sh <host>           # use default ports/checks
#   scripts/reverse-probe.sh <host> [port...] # add custom TCP ports to probe
#
# Examples:
#   scripts/reverse-probe.sh example.local
#   scripts/reverse-probe.sh 100.84.X.X 8080 5432
#   scripts/reverse-probe.sh api.mycompany.com 443

set -u

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <host> [extra_tcp_port ...]" >&2
    exit 1
fi
shift
EXTRA_PORTS=("$@")
DEFAULT_PORTS=(22 80 443)
TIMEOUT=4

# shellcheck source=_lib/redact.sh
source "$(dirname "$0")/_lib/redact.sh"
# shellcheck source=_lib/output.sh
source "$(dirname "$0")/_lib/output.sh"
PANEL_TITLE="reverse probe"
parse_redact_flag "$@"
parse_output_flags "$@"
maybe_redact_self "$TARGET" "$@"

# Resolve target — separates DNS issues from reachability issues
section "1. NAME RESOLUTION FROM HERE"
if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "Target is literal IP" "$TARGET"
    TARGET_IP="$TARGET"
else
    resolved=$(dig +short +time=3 +tries=1 "$TARGET" 2>/dev/null | head -1)
    if [[ -n "$resolved" ]]; then
        pass "Resolved $TARGET (dig, bypass resolver)" "$resolved"
        TARGET_IP="$resolved"
    else
        fail "Resolved $TARGET" "no answer from local DNS — can't proceed past name layer"
        emit_summary
        exit 1
    fi
fi

section "2. ICMP REACHABILITY"
if ping -c 2 -W $((TIMEOUT * 1000)) "$TARGET_IP" >/dev/null 2>&1; then
    pass "Ping $TARGET_IP"
else
    fail "Ping $TARGET_IP" "no ICMP response (or ICMP filtered)"
fi

section "3. TCP PORT REACHABILITY"
# De-duplicate ports — extras may overlap defaults
all_ports=$(printf '%s\n' "${DEFAULT_PORTS[@]}" ${EXTRA_PORTS[@]+"${EXTRA_PORTS[@]}"} | awk '!seen[$0]++')
while read -r port; do
    [[ -z "$port" ]] && continue
    if nc -zv -G "$TIMEOUT" "$TARGET_IP" "$port" >/dev/null 2>&1; then
        pass "TCP/$port -> $TARGET_IP" "open"
    else
        fail "TCP/$port -> $TARGET_IP" "closed or filtered"
    fi
done <<< "$all_ports"

section "4. TLS / HTTPS HEALTH (if 443 open)"
if nc -zv -G "$TIMEOUT" "$TARGET_IP" 443 >/dev/null 2>&1; then
    if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Connect by IP; cert check will fail SNI but we can still probe
        out=$(curl -sS -o /dev/null -w "%{http_code}|%{time_total}" --max-time "$TIMEOUT" -k "https://$TARGET_IP" 2>&1)
        pass "HTTPS to IP (cert SNI may not match)" "$out"
    else
        out=$(curl -sS -o /dev/null -w "%{http_code}|%{time_total}" --max-time "$TIMEOUT" "https://$TARGET" 2>&1)
        if [[ "$out" =~ ^[0-9]+\|[0-9.]+$ ]]; then
            pass "HTTPS to $TARGET" "$out"
        else
            fail "HTTPS to $TARGET" "$out"
        fi
    fi
fi

section "5. PATH / ROUTING"
case "$(uname -s)" in
    Darwin)
        # macOS traceroute: -w timeout (sec), -m max hops, -q probes per hop
        info "  traceroute (first 8 hops):"
        traceroute -n -w 2 -q 1 -m 8 "$TARGET_IP" 2>/dev/null | head -10 | sed 's/^/    /' || true
        ;;
    Linux)
        if command -v traceroute >/dev/null 2>&1; then
            info "  traceroute (first 8 hops):"
            traceroute -n -w 2 -q 1 -m 8 "$TARGET_IP" 2>/dev/null | head -10 | sed 's/^/    /' || true
        elif command -v mtr >/dev/null 2>&1; then
            info "  mtr report (5 cycles):"
            mtr -nrc 5 "$TARGET_IP" 2>/dev/null | tail -10 | sed 's/^/    /' || true
        fi
        ;;
esac

emit_summary
