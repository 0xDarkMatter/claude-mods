#!/usr/bin/env bash
# net-ops :: linux/dns-audit.sh
# Deep DNS forensics for Linux. Use when probe.sh shows rung 4 (dig) PASS
# but rung 5 (getent / resolvectl) FAIL.

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

term_header "/etc/nsswitch.conf (hosts line)"
grep "^hosts:" /etc/nsswitch.conf 2>/dev/null || echo "  (no hosts entry)"

echo
term_header "/etc/resolv.conf"
if [[ -L /etc/resolv.conf ]]; then
    echo "  Type: symlink -> $(readlink /etc/resolv.conf)"
else
    echo "  Type: regular file"
fi
echo "  Modified: $(stat -c '%y' /etc/resolv.conf 2>/dev/null || stat -f '%Sm' /etc/resolv.conf 2>/dev/null)"
echo "  --- contents ---"
cat /etc/resolv.conf 2>/dev/null | sed 's/^/  /'

echo
term_header "systemd-resolved"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "  Service: active"
    echo "  --- resolvectl status ---"
    resolvectl status 2>/dev/null | sed 's/^/  /'
else
    echo "  Service: inactive or not installed"
fi

echo
term_header "NetworkManager DNS config"
if command -v nmcli >/dev/null 2>&1; then
    echo "  --- nmcli dev show (DNS lines) ---"
    nmcli dev show 2>/dev/null | grep -E 'DEVICE|IP4.DNS|IP6.DNS|DOMAIN' | sed 's/^/  /'
    echo
    echo "  --- NetworkManager dns mode ---"
    awk '/\[main\]/,/\[/{if(/^dns/) print}' /etc/NetworkManager/NetworkManager.conf 2>/dev/null | sed 's/^/  /' || true
    ls -la /etc/NetworkManager/conf.d/ 2>/dev/null | sed 's/^/  /' || true
else
    echo "  nmcli not installed"
fi

echo
term_header "dnsmasq"
if pgrep -x dnsmasq >/dev/null; then
    pid=$(pgrep -x dnsmasq | head -1)
    echo "  Running, PID $pid"
    ps -o command -p "$pid" 2>/dev/null | sed 's/^/  /'
else
    echo "  not running"
fi
for d in /etc/dnsmasq.d /etc/NetworkManager/dnsmasq.d; do
    [[ -d "$d" ]] && { echo "  $d contents:"; ls "$d" 2>/dev/null | sed 's/^/    /'; }
done

echo
term_header "Local DNS listeners"
ss -tulnp 2>/dev/null | awk 'NR==1 || $5 ~ /:53$/' | sed 's/^/  /'

echo
term_header "/etc/hosts (non-comment)"
grep -vE '^\s*(#|$)' /etc/hosts 2>/dev/null | sed 's/^/  /' || echo "  (no custom entries)"

echo
term_header "VPN / WireGuard interfaces"
ip -br link 2>/dev/null | awk '/^(wg|tun|tap|nordlynx|proton|mullvad|nextdns)/' | sed 's/^/  /' || true
if command -v wg >/dev/null 2>&1; then
    echo "  --- wg show ---"
    wg show 2>/dev/null | sed 's/^/  /' | head -30 || true
fi

echo
term_header "ATTRIBUTION HINTS"
# Inspect nameservers visible across the stack for known patterns
ns_list=$( {
    awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null
    resolvectl status 2>/dev/null | awk '/Current DNS Server:|DNS Servers:/{for(i=4;i<=NF;i++)print $i}'
    nmcli -t -f IP4.DNS,IP6.DNS dev show 2>/dev/null | awk -F: '{print $2}'
} | sort -u | grep -v '^$' )

while read -r n; do
    [[ -z "$n" ]] && continue
    case "$n" in
        10.2.0.*)              echo "  $n :: likely Proton VPN gateway" ;;
        10.64.0.*)             echo "  $n :: likely Mullvad gateway" ;;
        10.211.*|10.212.*)     echo "  $n :: likely Cisco AnyConnect" ;;
        100.100.100.100)       echo "  $n :: Tailscale MagicDNS (expected)" ;;
        127.0.0.53)            echo "  $n :: systemd-resolved stub (expected on most systems)" ;;
        127.0.0.1|127.0.0.2)   echo "  $n :: local DNS proxy (dnsmasq, NextDNS, AdGuard, etc.)" ;;
    esac
done <<< "$ns_list"
