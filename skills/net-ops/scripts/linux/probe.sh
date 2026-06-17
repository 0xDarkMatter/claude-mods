#!/usr/bin/env bash
# net-ops :: linux/probe.sh
# Full layered diagnostic ladder for Linux network troubleshooting.
# Outputs structured [PASS]/[FAIL] lines so a human or LLM can scan for
# the first FAIL and drill in.

set -u

TEST_HOST="${TEST_HOST:-google.com}"
TEST_IPS=("1.1.1.1" "8.8.8.8")
TIMEOUT="${TIMEOUT:-5}"

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            cat <<EOF
Usage: $0 [--redact] [--json] [--quick]

  --redact   Mask private IPs, MAC addresses, and *.ts.net tailnet names
  --json     Newline-delimited JSON output (for piping to jq, dashboards)
  --quick    Skip rungs 1-4 and 7 if the last full run cached as healthy
             (cache: \${TMPDIR:-/tmp}/net-ops/last-state.json, TTL 10min)

Compose freely: --json + --redact emits sanitized NDJSON.
Env: TEST_HOST (default google.com), TIMEOUT (default 5s).
EOF
            exit 0 ;;
    esac
done

# shellcheck source=../_lib/redact.sh
source "$(dirname "$0")/../_lib/redact.sh"
# shellcheck source=../_lib/output.sh
source "$(dirname "$0")/../_lib/output.sh"
PANEL_TITLE="linux probe"
parse_redact_flag "$@"
parse_output_flags "$@"
maybe_redact_self "$@"

# ---------------------------------------------------------------------------
section "1. LINK LAYER"
# ---------------------------------------------------------------------------
ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | while read -r dev; do
    [[ "$dev" == "lo" ]] && continue
    addr=$(ip -br -4 addr show "$dev" 2>/dev/null | awk '{print $3}')
    pass "Interface $dev UP" "${addr:-no IPv4}"
done

GATEWAY=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
[[ -n "$GATEWAY" ]] && pass "Default gateway" "$GATEWAY via $DEFAULT_IF" || fail "Default gateway" "none configured"

# ---------------------------------------------------------------------------
section "2. IP / ICMP REACHABILITY"
# ---------------------------------------------------------------------------
[[ -n "${GATEWAY:-}" ]] && {
    if ping -c 2 -W "$TIMEOUT" "$GATEWAY" >/dev/null 2>&1; then pass "Ping gateway $GATEWAY"; else fail "Ping gateway $GATEWAY"; fi
}
for ip in "${TEST_IPS[@]}"; do
    if ping -c 2 -W "$TIMEOUT" "$ip" >/dev/null 2>&1; then pass "Ping $ip"; else fail "Ping $ip"; fi
done

# ---------------------------------------------------------------------------
section "3. TCP/UDP SOCKET REACHABILITY"
# ---------------------------------------------------------------------------
for ip in "${TEST_IPS[@]}"; do
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$ip/443" 2>/dev/null; then pass "TCP/443 -> $ip"; else fail "TCP/443 -> $ip"; fi
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$ip/53"  2>/dev/null; then pass "TCP/53  -> $ip"; else fail "TCP/53  -> $ip"; fi
done

# Raw UDP/53 via dig with explicit server — bypasses /etc/resolv.conf
for ip in "${TEST_IPS[@]}"; do
    if result=$(dig +short +time="$TIMEOUT" +tries=1 @"$ip" "$TEST_HOST" 2>&1) && [[ -n "$result" ]] && [[ ! "$result" =~ "timed out"|"connection refused" ]]; then
        pass "UDP/53 -> $ip (dig)" "$(echo "$result" | head -1)"
    else
        fail "UDP/53 -> $ip (dig)" "$result"
    fi
done

# ---------------------------------------------------------------------------
section "4. DNS INFRASTRUCTURE (bypass tools)"
# ---------------------------------------------------------------------------
# dig uses its own resolver — does NOT touch glibc NSS chain
for srv in "" "${TEST_IPS[@]}"; do
    if [[ -z "$srv" ]]; then
        out=$(dig +short +time="$TIMEOUT" +tries=1 "$TEST_HOST" 2>&1)
        label="default"
    else
        out=$(dig +short +time="$TIMEOUT" +tries=1 @"$srv" "$TEST_HOST" 2>&1)
        label="$srv"
    fi
    if [[ -n "$out" && ! "$out" =~ "timed out"|"connection refused" ]]; then
        pass "dig via $label" "$(echo "$out" | head -1)"
    else
        fail "dig via $label" "$out"
    fi
done

# ---------------------------------------------------------------------------
section "5. LINUX RESOLVER PATH (the hook layer)"
# ---------------------------------------------------------------------------
# getent uses glibc NSS — goes through the whole system resolver chain
if out=$(getent hosts "$TEST_HOST" 2>&1) && [[ -n "$out" ]]; then
    addr=$(echo "$out" | awk '{print $1; exit}')
    pass "getent hosts (NSS path)" "$addr"
else
    fail "getent hosts (NSS path)" "$out"
fi

# resolvectl query if systemd-resolved present
if command -v resolvectl >/dev/null 2>&1; then
    if out=$(resolvectl query "$TEST_HOST" 2>&1) && echo "$out" | grep -q "^$TEST_HOST:"; then
        addr=$(echo "$out" | awk '/^[^:]+:.+[0-9]+\./{print $2; exit}')
        pass "resolvectl query" "$addr"
    else
        fail "resolvectl query" "$(echo "$out" | head -2)"
    fi
fi

# nsswitch.conf — name resolution order
echo "  /etc/nsswitch.conf hosts line:"
grep "^hosts:" /etc/nsswitch.conf 2>/dev/null | sed 's/^/    /'

# /etc/resolv.conf — is it the systemd-resolved stub, NetworkManager's, or static?
echo "  /etc/resolv.conf:"
if [[ -L /etc/resolv.conf ]]; then
    target=$(readlink /etc/resolv.conf)
    echo "    symlink -> $target"
fi
head -5 /etc/resolv.conf 2>/dev/null | sed 's/^/    /'

# Active resolver listeners on 127.x:53
echo "  Local DNS listeners on 127.0.0.x:53:"
ss -tulnp 2>/dev/null | awk '$5 ~ /^127\./ && $5 ~ /:53$/' | sed 's/^/    /' || true

# systemd-resolved status (if present)
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "  systemd-resolved active. Per-link DNS:"
    resolvectl status 2>/dev/null | awk '
        /^Link [0-9]+/{link=$0; show=0; printed=0}
        /Current DNS Server:|DNS Servers:|DNS Domain:/{
            if(!printed){print "    "link; printed=1}
            print "      "$0
        }
    ' | head -40
fi

# ---------------------------------------------------------------------------
# Time-sync deep-dive: HTTP Date drift + check timedatectl/chrony/ntpd status
remote_date=$(curl -sIA 'net-ops-probe' --max-time 5 https://www.google.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2; exit}' | tr -d '\r')
drift_ok=1
drift_detail=""
if [[ -n "$remote_date" ]]; then
    remote_epoch=$(date -d "$remote_date" +%s 2>/dev/null)
    if [[ -n "$remote_epoch" ]]; then
        local_epoch=$(date +%s)
        drift=$(( local_epoch - remote_epoch ))
        abs_drift=${drift#-}
        if [[ "$abs_drift" -lt 300 ]]; then
            drift_detail="${drift}s vs HTTP Date (within ±5min)"
        else
            drift_ok=0
            drift_detail="${drift}s drift — will break TLS cert validation"
        fi
    fi
fi

# Detect which time daemon and its sync state
sync_detail=""
if command -v timedatectl >/dev/null 2>&1; then
    sync_state=$(timedatectl show 2>/dev/null | awk -F= '/^NTPSynchronized=/{print $2}')
    sync_detail="systemd-timesyncd NTPSynchronized=$sync_state"
elif command -v chronyc >/dev/null 2>&1; then
    stratum=$(chronyc tracking 2>/dev/null | awk -F': ' '/Stratum/{print $2}')
    sync_detail="chronyd stratum=$stratum"
    [[ "$stratum" == "16" ]] && drift_ok=0
elif command -v ntpq >/dev/null 2>&1; then
    sync_detail="ntpd present (run 'ntpq -p' for peer status)"
fi

combined="$drift_detail${sync_detail:+; $sync_detail}"
if [[ "$drift_ok" -eq 1 ]]; then
    pass "Time sync" "$combined"
else
    fail "Time sync" "$combined"
fi

# MTU / path-MTU discovery. Linux uses -M do (don't fragment).
if ping -M do -s 1472 -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    pass "Path MTU 1500 (1472-byte DF payload)" "to 1.1.1.1"
else
    if ping -M do -s 1400 -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        fail "Path MTU 1500 (1472-byte DF payload)" "1500 fails, 1428+ works — path MTU < 1500 (VPN/PPPoE?)"
    else
        pass "Path MTU test inconclusive" "ICMP DF blocked or destination unreachable"
    fi
fi

# IPv6 deep-dive — classifies v6 stack state across four meaningful tiers.
v6_state=""
v6_detail=""

v6_addrs=$(ip -6 -br addr show scope global 2>/dev/null | awk '{for(i=3;i<=NF;i++) print $1" "$i}' | grep -v '^lo ')
v6_global=$(printf '%s\n' "$v6_addrs" | awk '$2 !~ /^fd/ && $2 !~ /^fc/{print; exit}')
v6_default=$(ip -6 route show default 2>/dev/null | head -1)

if [[ -z "$v6_addrs" ]]; then
    v6_state="disabled"
    v6_detail="no global v6 addresses — IPv6 disabled or unconfigured (check sysctl net.ipv6.conf.all.disable_ipv6)"
elif [[ -z "$v6_global" ]]; then
    v6_state="ula_only"
    v6_detail="only ULA (fc00::/7) addresses present — router not delegating public v6 prefix"
elif [[ -z "$v6_default" ]]; then
    v6_state="no_route"
    v6_detail="global v6 address present but no default route — RA not received (check accept_ra sysctl)"
else
    aaaa=$(dig +short +time=2 +tries=1 AAAA "$TEST_HOST" 2>/dev/null | head -1)
    if [[ -n "$aaaa" ]] && curl -6 -sS -o /dev/null --max-time 4 "https://$TEST_HOST" 2>/dev/null; then
        v6_state="healthy"
        v6_detail="global addr + default route + curl -6 works"
    else
        v6_state="path_broken"
        v6_detail="addr present, default route present, but curl -6 fails — firewall or ISP black-holing"
    fi
fi

case "$v6_state" in
    disabled|healthy) pass "IPv6 stack ($v6_state)" "$v6_detail" ;;
    *) fail "IPv6 stack ($v6_state)" "$v6_detail" ;;
esac

# ---------------------------------------------------------------------------
section "6. APPLICATION LAYER (real HTTP request)"
# ---------------------------------------------------------------------------
for url in "https://www.google.com" "https://github.com"; do
    if out=$(curl -sS -o /dev/null -w "%{http_code} %{size_download}b" --max-time "$TIMEOUT" "$url" 2>&1); then
        pass "GET $url" "$out"
    else
        fail "GET $url" "$out"
    fi
done

# ---------------------------------------------------------------------------
section "7. KNOWN VPN / DNS CLIENT FOOTPRINT"
# ---------------------------------------------------------------------------
# Browser DoH state — Chrome / Brave / Edge / Firefox bypass system DNS when DoH set.
browser_findings=""
for label_prefs in \
    "Chrome:$HOME/.config/google-chrome/Default/Preferences" \
    "Chromium:$HOME/.config/chromium/Default/Preferences" \
    "Brave:$HOME/.config/BraveSoftware/Brave-Browser/Default/Preferences" \
    "Edge:$HOME/.config/microsoft-edge/Default/Preferences"; do
    label="${label_prefs%%:*}"
    prefs="${label_prefs#*:}"
    [[ -f "$prefs" ]] || continue
    mode=$(perl -ne 'if (/"dns_over_https"\s*:\s*\{[^}]*"mode"\s*:\s*"([^"]+)"/) { print "$1\n"; exit }' "$prefs" 2>/dev/null)
    templates=$(perl -ne 'if (/"dns_over_https"\s*:\s*\{[^}]*"templates"\s*:\s*"([^"]+)"/) { print "$1\n"; exit }' "$prefs" 2>/dev/null)
    if [[ -n "$mode" ]]; then
        browser_findings+="    $label DoH: mode=$mode${templates:+, server=$templates}\n"
    else
        browser_findings+="    $label installed, DoH: not configured (system DNS)\n"
    fi
done
for fx_prefs in "$HOME/.mozilla/firefox"/*.default*/prefs.js; do
    [[ -f "$fx_prefs" ]] || continue
    trr_mode=$(awk -F'"' '/"network.trr.mode"/{print $4; exit}' "$fx_prefs" 2>/dev/null)
    trr_uri=$(awk -F'"' '/"network.trr.uri"/{print $4; exit}' "$fx_prefs" 2>/dev/null)
    case "${trr_mode:-0}" in
        2) state="enabled (with system fallback)" ;;
        3) state="enabled (no fallback)" ;;
        5) state="disabled by policy" ;;
        *) state="off (system DNS)" ;;
    esac
    browser_findings+="    Firefox DoH: $state${trr_uri:+, server=$trr_uri}\n"
    break
done
if [[ -n "$browser_findings" ]]; then
    info "  Browser DoH state (browsers may bypass system DNS):"
    printf '%b' "$browser_findings"
fi

KNOWN=(
    /etc/openvpn /etc/wireguard /opt/cisco /etc/proton-vpn /etc/mullvad-vpn
    /opt/nordvpn /etc/NetworkManager/dnsmasq.d /etc/dnsmasq.d
    /etc/cloudflared /etc/nextdns.conf
)
for p in "${KNOWN[@]}"; do
    [[ -e "$p" ]] && echo "  Found: $p"
done

# Running VPN / DNS proxy processes
echo "  VPN / DNS proxy processes:"
pgrep -af 'openvpn|wireguard|wg-quick|mullvad|proton|nordvpn|cloudflared|nextdns|dnsmasq|stubby|dnscrypt' 2>/dev/null | head -10 | sed 's/^/    /' || true

# ---------------------------------------------------------------------------
section "8. ENVIRONMENT (WSL / container detection)"
# ---------------------------------------------------------------------------
env_type=""
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    env_type="WSL2"
elif [[ -f /.dockerenv ]]; then
    env_type="Docker container"
elif grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
    env_type="container (cgroup signature)"
fi

if [[ -z "$env_type" ]]; then
    info "  Bare-metal / VM Linux (no WSL/container signature)"
else
    info "  Detected environment: $env_type"
    case "$env_type" in
        WSL2*)
            info "  WSL2 has bespoke DNS handling. Key files if DNS misbehaves:"
            info "    /etc/wsl.conf       — controls generateResolvConf"
            info "    /etc/resolv.conf    — auto-generated by WSL unless wsl.conf opts out"
            info "    Host Windows DNS    — affects WSL DNS via mirrored mode"
            info "  Fix pattern: edit /etc/wsl.conf, set [network] generateResolvConf=false, write static /etc/resolv.conf"
            [[ -f /etc/wsl.conf ]] && { info "    --- /etc/wsl.conf ---"; sed 's/^/      /' /etc/wsl.conf; }
            info "    --- /etc/resolv.conf head ---"
            head -5 /etc/resolv.conf 2>/dev/null | sed 's/^/      /'
            ;;
        Docker*|container*)
            info "  Container DNS inherits from host or --dns flag at run time."
            info "    /etc/resolv.conf here is set by runtime, not user."
            info "  If broken inside container but fine on host: check 'docker network inspect' / runtime config."
            ;;
    esac
fi

emit_summary
if [[ "$JSON_MODE" -eq 0 ]]; then
    if [[ -n "$FIRST_FAIL" ]]; then
        case "$FIRST_FAIL" in
            *"LINK LAYER"*)    echo "  Next: check ip link / ip addr, DHCP, NetworkManager state" ;;
            *"SOCKET"*)        echo "  Next: check iptables/nftables OUTPUT chain; AV protocol filtering; consumer router DoH IP blocking" ;;
            *"ICMP"*|*"IP /"*) echo "  Next: check ip route, ISP/upstream connectivity" ;;
            *"DNS INFRASTRUCTURE"*) echo "  Next: check UDP/53 outbound, /etc/resolv.conf upstream" ;;
            *"RESOLVER PATH"*) echo "  Next: bash scripts/linux/dns-audit.sh   # drill rung 5 (the hook layer)" ;;
            *"APPLICATION"*)   echo "  Next: check http_proxy/https_proxy env, CA bundle, IPv6 preference" ;;
            *) echo "  Next: re-run with --verbose; check references/common-culprits.md" ;;
        esac
    fi
    echo
    echo "=== END PROBE ==="
fi
