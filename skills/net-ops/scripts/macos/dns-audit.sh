#!/usr/bin/env bash
# net-ops :: macos/dns-audit.sh
# Deep DNS forensics for macOS. Use when probe.sh shows rung 4 (dig) PASS
# but rung 5 (dscacheutil) FAIL — that signature points at a hook in the
# macOS resolver chain.

set -u
# Shared terminal toolkit (skills/_lib/term.sh) — colorized, ASCII-aware section
# headers. Dump/fixer output isn't a checklist, so it uses the bare-header style
# (a deliberate exception per docs/TERMINAL-DESIGN.md), not the enclosing panel.
__nlib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__nlib:-}" ] && [ -f "$__nlib/term.sh" ]; then . "$__nlib/term.sh"; term_init
else term_header() { printf '== %s ==\n' "${1:-}"; }; fi

# shellcheck source=../_lib/redact.sh
source "$(dirname "$0")/../_lib/redact.sh"
parse_redact_flag "$@"
maybe_redact_self "$@"

term_header "scutil --dns (FULL)"
scutil --dns 2>/dev/null

echo
term_header "/etc/resolver/* (per-domain DNS overrides — VPN clients use these)"
if [[ -d /etc/resolver ]] && [[ -n "$(ls -A /etc/resolver 2>/dev/null)" ]]; then
    for f in /etc/resolver/*; do
        [[ -f "$f" ]] || continue
        echo "--- $f ---"
        echo "  modified: $(stat -f '%Sm' "$f" 2>/dev/null || stat -c '%y' "$f" 2>/dev/null)"
        cat "$f" | sed 's/^/  /'
    done
else
    echo "/etc/resolver/ empty or missing — no per-domain overrides."
fi

echo
term_header "Configuration profiles with DNS settings"
profiles list -type configuration 2>/dev/null | head -40
echo
echo "  (run 'sudo profiles show -type configuration' for full payloads)"

echo
term_header "/etc/hosts (non-comment lines)"
grep -vE '^\s*(#|$)' /etc/hosts 2>/dev/null || echo "  (no custom entries)"

echo
term_header "/etc/resolv.conf (legacy, usually a stub on macOS)"
if [[ -f /etc/resolv.conf ]]; then
    cat /etc/resolv.conf
else
    echo "  not present"
fi

echo
term_header "mDNSResponder state"
if pgrep -x mDNSResponder >/dev/null; then
    pid=$(pgrep -x mDNSResponder | head -1)
    echo "PID: $pid"
    ps -o pid,etime,command -p "$pid" 2>/dev/null
fi

echo
term_header "Network services priority order"
networksetup -listnetworkserviceorder 2>/dev/null | head -30

echo
term_header "DNS servers per active service"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
    [[ "$svc" == \** ]] && continue  # disabled
    dns=$(networksetup -getdnsservers "$svc" 2>/dev/null)
    echo "  $svc: $dns"
done

echo
term_header "Search domains per active service"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
    [[ "$svc" == \** ]] && continue
    sd=$(networksetup -getsearchdomains "$svc" 2>/dev/null)
    echo "  $svc: $sd"
done

echo
term_header "Third-party network kexts loaded"
kextstat 2>/dev/null | grep -iE 'cisco|anyconnect|proton|mullvad|nord|littlesnitch|lulu|nextdns|warp' || echo "  (none detected)"

echo
term_header "ATTRIBUTION HINTS"
# Aggregate every nameserver we can see across all resolver surfaces, then
# pattern-match each unique entry to a known VPN/DNS client signature.
ns_list=$( {
    [[ -d /etc/resolver ]] && grep -h '^nameserver' /etc/resolver/* 2>/dev/null | awk '{print $2}'
    scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}'
    networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
        [[ "$svc" == \** ]] && continue
        networksetup -getdnsservers "$svc" 2>/dev/null | grep -E '^[0-9a-f:.]+$' || true
    done
} | sort -u | grep -v '^$' )

if [[ -z "$ns_list" ]]; then
    echo "  (no nameservers found)"
fi

while read -r n; do
    [[ -z "$n" ]] && continue
    case "$n" in
        10.2.0.*)        echo "  $n :: likely Proton VPN gateway" ;;
        10.64.0.*)       echo "  $n :: likely Mullvad gateway" ;;
        10.211.*|10.212.*) echo "  $n :: likely Cisco AnyConnect" ;;
        10.5.0.*)        echo "  $n :: likely NordVPN gateway" ;;
        100.100.100.100) echo "  $n :: Tailscale MagicDNS (expected)" ;;
        127.0.0.1|127.0.0.2|::1) echo "  $n :: local DNS proxy (NextDNS, AdGuard, dnsmasq, etc.)" ;;
        1.1.1.1|1.0.0.1) echo "  $n :: Cloudflare public DNS" ;;
        8.8.8.8|8.8.4.4) echo "  $n :: Google public DNS" ;;
        9.9.9.9|149.112.112.112) echo "  $n :: Quad9 public DNS" ;;
    esac
done <<< "$ns_list"
