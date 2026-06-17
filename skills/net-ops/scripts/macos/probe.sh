#!/usr/bin/env bash
# net-ops :: macos/probe.sh
# Full layered diagnostic ladder for macOS network troubleshooting.
# Outputs structured [PASS]/[FAIL] lines so a human or LLM can scan for
# the first FAIL and drill in.

set -u

TEST_HOST="${TEST_HOST:-google.com}"
TEST_IPS=("1.1.1.1" "8.8.8.8")
TIMEOUT="${TIMEOUT:-5}"

VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--redact] [--verbose] [--json] [--quick]

  --redact   Mask private IPs, MAC addresses, and *.ts.net tailnet names
  --verbose  Full scutil --dns dump (default: condensed one-line-per-resolver)
  --json     Newline-delimited JSON output (for piping to jq, dashboards)
  --quick    Skip rungs 1-4 and 7 if the last full run cached as healthy
             (cache: \${TMPDIR}/net-ops/last-state.json, TTL 10min)

Compose freely: --json + --redact emits sanitized NDJSON.
EOF
            exit 0 ;;
    esac
done

# shellcheck source=../_lib/redact.sh
source "$(dirname "$0")/../_lib/redact.sh"
# shellcheck source=../_lib/output.sh
source "$(dirname "$0")/../_lib/output.sh"
# shellcheck source=../_lib/cache.sh
source "$(dirname "$0")/../_lib/cache.sh"
PANEL_TITLE="macos probe"
parse_redact_flag "$@"
parse_output_flags "$@"
parse_quick_flag "$@"
maybe_redact_self "$@"

if cache_indicates_healthy; then
    info "  [--quick: last full run was healthy, skipping rungs 1-4 and 7]"
fi

# ---------------------------------------------------------------------------
if should_run_rung 1; then
section "1. LINK LAYER"
# ---------------------------------------------------------------------------
ACTIVE_IFS=$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port/{port=$3} /Device/{print port" "$2}' || true)
echo "$ACTIVE_IFS" | while read -r line; do
    [[ -z "$line" ]] && continue
    name="${line% *}"; dev="${line##* }"
    status=$(ifconfig "$dev" 2>/dev/null | awk '/status:/{print $2; exit}')
    if [[ "$status" == "active" ]]; then
        ip=$(ifconfig "$dev" 2>/dev/null | awk '/inet /{print $2; exit}')
        pass "Interface $name ($dev) active" "$ip"
    fi
done

GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
DEFAULT_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[[ -n "$GATEWAY" ]] && pass "Default gateway" "$GATEWAY via $DEFAULT_IF" || fail "Default gateway" "none configured"

fi  # end rung 1

# ---------------------------------------------------------------------------
if should_run_rung 2; then
section "2. IP / ICMP REACHABILITY"
# ---------------------------------------------------------------------------
[[ -n "${GATEWAY:-}" ]] && {
    if ping -c 2 -W "${TIMEOUT}000" "$GATEWAY" >/dev/null 2>&1; then pass "Ping gateway $GATEWAY"; else fail "Ping gateway $GATEWAY"; fi
}
for ip in "${TEST_IPS[@]}"; do
    if ping -c 2 -W "${TIMEOUT}000" "$ip" >/dev/null 2>&1; then pass "Ping $ip"; else fail "Ping $ip"; fi
done

fi  # end rung 2

# ---------------------------------------------------------------------------
if should_run_rung 3; then
section "3. TCP/UDP SOCKET REACHABILITY"
# ---------------------------------------------------------------------------
for ip in "${TEST_IPS[@]}"; do
    if nc -zv -G "$TIMEOUT" "$ip" 443 >/dev/null 2>&1; then pass "TCP/443 -> $ip"; else fail "TCP/443 -> $ip"; fi
    if nc -zv -G "$TIMEOUT" "$ip" 53 >/dev/null 2>&1; then pass "TCP/53  -> $ip"; else fail "TCP/53  -> $ip"; fi
done

# Raw UDP/53 — uses dig with explicit server, bypasses /etc/resolv.conf
for ip in "${TEST_IPS[@]}"; do
    if dig +short +time="$TIMEOUT" +tries=1 @"$ip" "$TEST_HOST" >/dev/null 2>&1; then
        result=$(dig +short +time="$TIMEOUT" +tries=1 @"$ip" "$TEST_HOST" | head -1)
        pass "UDP/53 -> $ip (dig)" "$result"
    else
        fail "UDP/53 -> $ip (dig)"
    fi
done

fi  # end rung 3

# ---------------------------------------------------------------------------
if should_run_rung 4; then
section "4. DNS INFRASTRUCTURE (bypass tools)"
# ---------------------------------------------------------------------------
# dig uses its own resolver — does NOT touch macOS DNS resolution chain
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

fi  # end rung 4

# ---------------------------------------------------------------------------
section "5. macOS RESOLVER PATH (the hook layer)"
# ---------------------------------------------------------------------------
# dscacheutil uses the macOS resolver chain — goes through everything
out=$(dscacheutil -q host -a name "$TEST_HOST" 2>&1)
if echo "$out" | grep -q "ip_address:"; then
    addr=$(echo "$out" | awk '/ip_address:/{print $2; exit}')
    pass "dscacheutil (system resolver)" "$addr"
else
    fail "dscacheutil (system resolver)" "$(echo "$out" | head -3)"
fi

# /etc/resolver/* — per-domain overrides, classic VPN residue
if [[ -d /etc/resolver ]]; then
    resolver_files=$(ls /etc/resolver/ 2>/dev/null)
    if [[ -n "$resolver_files" ]]; then
        echo "  /etc/resolver/ contents (per-domain DNS overrides):"
        for f in /etc/resolver/*; do
            [[ -f "$f" ]] || continue
            domain="${f##*/}"
            ns=$(awk '/^nameserver/{print $2}' "$f" | tr '\n' ' ')
            echo "    $domain -> $ns"
        done
    fi
fi

# scutil DNS state — the authoritative view of macOS resolver config
if [[ "$VERBOSE" -eq 1 ]]; then
    echo "  scutil --dns (full):"
    scutil --dns 2>/dev/null | sed 's/^/    /'
else
    # Condensed: one line per resolver — scope (via domain or search), nameservers, order
    echo "  scutil --dns (condensed, --verbose for full):"
    scutil --dns 2>/dev/null | awk '
        /^resolver #/{ if(num){flush()} num=$2; sub(/#/,"",num); scope=""; ns=""; ord="" }
        /search domain\[0\]/{ scope="search="$NF }
        /domain[[:space:]]*:/{ scope="domain="$NF }
        /options/{ if($NF~/mdns/) scope="mdns" }
        /nameserver\[[0-9]+\]/{ ns=ns?ns","$NF:$NF }
        /order[[:space:]]*:/{ ord=$NF }
        function flush() {
            if (!scope) scope="default"
            print "    #"num"  scope="scope"  via="ns"  order="ord
        }
        END{ if(num) flush() }
    '
fi

# Configuration profiles (MDM / VPN-installed). Without sudo we only see user-scope.
profile_count=$(profiles list -type configuration 2>/dev/null | grep -c "attribute:" 2>/dev/null)
profile_count="${profile_count:-0}"
if [[ "$profile_count" =~ ^[0-9]+$ ]] && (( profile_count > 0 )); then
    echo "  Configuration profiles installed (user scope): $profile_count"
    echo "    For full detail incl. system profiles: sudo profiles list -type configuration"
fi

# Local DNS proxy detection — derived from scutil (works unprivileged).
# Common with NextDNS, AdGuard, dnsmasq, Pi-hole client, Cloudflare WARP.
if scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | grep -qE '^(127\.|::1$)'; then
    echo "  !! Local DNS proxy detected in resolver chain (127.x or ::1 nameserver)"
    echo "     Apps using the system resolver may route DNS through it."
    echo "     For PID/process: sudo lsof -nP -iUDP:53"
fi

# mDNSResponder state
if pgrep -x mDNSResponder >/dev/null; then
    pid=$(pgrep -x mDNSResponder | head -1)
    pass "mDNSResponder running" "PID $pid"
else
    fail "mDNSResponder" "not running — system DNS will be broken"
fi

# ---------------------------------------------------------------------------
# Time-sync deep-dive: compare local clock to HTTP Date, AND check whether
# macOS network time sync itself is enabled + which server it's pointing at.
# Stratum-16 (unsynced) clocks are the silent killer of TLS validation.
ntp_enabled=$(systemsetup -getusingnetworktime 2>/dev/null | awk -F': ' '{print $2}')
ntp_server=$(systemsetup -getnetworktimeserver 2>/dev/null | awk -F': ' '{print $2}')

# HTTP Date drift (works without elevated privs, no NTP infra needed)
remote_date=$(curl -sIA 'net-ops-probe' --max-time 5 https://www.google.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2; exit}' | tr -d '\r')
drift_ok=1
drift_detail=""
if [[ -n "$remote_date" ]]; then
    remote_epoch=$(date -j -f '%a, %d %b %Y %H:%M:%S %Z' "$remote_date" +%s 2>/dev/null)
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

# Optional: query the configured NTP server for actual stratum / offset.
# sntp is built-in on macOS; suppress its noisy output.
ntp_offset=""
if [[ -n "$ntp_server" ]] && command -v sntp >/dev/null 2>&1; then
    ntp_offset=$(sntp -t 3 "$ntp_server" 2>/dev/null | awk '/[+-][0-9]+\.[0-9]+/{print $1; exit}')
fi

combined="$drift_detail"
[[ -n "$ntp_enabled" ]] && combined="$combined; NTP sync=$ntp_enabled"
[[ -n "$ntp_server" ]] && combined="$combined; server=$ntp_server"
[[ -n "$ntp_offset" ]] && combined="$combined; sntp offset=${ntp_offset}s"

if [[ "$drift_ok" -eq 1 ]] && { [[ "$ntp_enabled" == "On" ]] || [[ -z "$ntp_enabled" ]]; }; then
    pass "Time sync" "$combined"
else
    fail "Time sync" "$combined"
fi

# MTU / path-MTU discovery test. Standard Ethernet MTU is 1500.
# We send a 1472-byte payload (1472 + 20 IP + 8 ICMP = 1500) with DF set.
# If this fails but a smaller size works, there's a path-MTU issue
# (PPPoE, weird tunnel, broken ICMP "fragmentation needed" delivery).
if ping -D -s 1472 -c 1 -t 3 1.1.1.1 >/dev/null 2>&1; then
    pass "Path MTU 1500 (1472-byte DF payload)" "to 1.1.1.1"
else
    if ping -D -s 1400 -c 1 -t 3 1.1.1.1 >/dev/null 2>&1; then
        fail "Path MTU 1500 (1472-byte DF payload)" "1500 fails, 1428+ works — path MTU < 1500 (VPN/PPPoE?)"
    else
        # Both fail — DF blocking entirely; don't flag as MTU
        pass "Path MTU test inconclusive" "ICMP DF blocked or destination unreachable"
    fi
fi

# IPv6 deep-dive — classifies v6 stack state across four meaningful tiers
# instead of a binary works/broken. Each tier maps to a distinct fix path.
v6_state=""
v6_detail=""

# 1. Any v6 address on a non-loopback interface?
v6_addrs=$(ifconfig 2>/dev/null | awk '/^[a-z]/{ifn=$1} /inet6 /{print ifn" "$2}' | grep -v "::1\|fe80::" | grep -v "^utun\|^awdl\|^llw\|^bridge")
# 2. Any GLOBAL v6 address (not ULA fd00::/8)?
v6_global=$(printf '%s\n' "$v6_addrs" | awk '$2 !~ /^fd/ && $2 !~ /^fc/{print; exit}')
# 3. Is there an actual global default route?
v6_default=$(route -n get -inet6 default 2>&1 | awk '/gateway:/{print $2; exit}')
[[ "$v6_default" =~ ^fe80 ]] && v6_default=""  # link-local doesn't count

if [[ -z "$v6_addrs" ]]; then
    v6_state="disabled"
    v6_detail="no v6 addresses on physical interfaces — IPv6 disabled or unconfigured"
elif [[ -z "$v6_global" ]]; then
    v6_state="ula_only"
    v6_detail="only ULA (fd00::/8) addresses present — ISP/router not delegating public v6 prefix"
elif [[ -z "$v6_default" ]]; then
    v6_state="no_route"
    v6_detail="global v6 address present but no default route — RA not received or NDP broken"
else
    # We have a v6 address and a route — test actual connectivity
    aaaa=$(dig +short +time=2 +tries=1 AAAA "$TEST_HOST" 2>/dev/null | head -1)
    if [[ -n "$aaaa" ]] && curl -6 -sS -o /dev/null --max-time 4 "https://$TEST_HOST" 2>/dev/null; then
        v6_state="healthy"
        v6_detail="global addr + default route + curl -6 works"
    else
        v6_state="path_broken"
        v6_detail="addr=$v6_global, route via $v6_default, but curl -6 fails — upstream v6 path dead"
    fi
fi

case "$v6_state" in
    disabled|healthy)
        pass "IPv6 stack ($v6_state)" "$v6_detail" ;;
    ula_only)
        fail "IPv6 stack ($v6_state)" "$v6_detail — apps may try v6 first, hit 'no route', fall back to v4 (slow). Fix: sudo networksetup -setv6off <service>" ;;
    no_route)
        fail "IPv6 stack ($v6_state)" "$v6_detail — check ndp -an for RA receipt; restart interface or check router RA config" ;;
    path_broken)
        fail "IPv6 stack ($v6_state)" "$v6_detail — VPN/firewall blocking v6, or ISP black-holing v6 traffic" ;;
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
if should_run_rung 7; then
section "7. KNOWN VPN / DNS CLIENT FOOTPRINT"
# ---------------------------------------------------------------------------
KNOWN_PATHS=(
    "/Applications/Proton VPN.app"
    "/Applications/Mullvad VPN.app"
    "/Applications/Tailscale.app"
    "/Applications/Cisco/Cisco Secure Client.app"
    "/Applications/Cisco/Cisco AnyConnect Secure Mobility Client.app"
    "/Applications/NordVPN.app"
    "/Applications/NextDNS.app"
    "/Applications/Little Snitch.app"
    "/Applications/Lulu.app"
    "/Library/Application Support/NextDNS"
)
for p in "${KNOWN_PATHS[@]}"; do
    [[ -e "$p" ]] && echo "  Installed: $p"
done

# Browser DoH state — Chrome / Brave / Edge / Firefox have their own resolvers
# that bypass system DNS entirely when DoH is configured. Useful for explaining
# "Chrome works but Safari doesn't" type asymmetries.
browser_findings=""
chrome_prefs="$HOME/Library/Application Support/Google/Chrome/Default/Preferences"
brave_prefs="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences"
edge_prefs="$HOME/Library/Application Support/Microsoft Edge/Default/Preferences"
for label_prefs in "Chrome:$chrome_prefs" "Brave:$brave_prefs" "Edge:$edge_prefs"; do
    label="${label_prefs%%:*}"
    prefs="${label_prefs#*:}"
    if [[ -f "$prefs" ]]; then
        # Chromium stores DoH mode under dns_over_https.mode: "off" | "automatic" | "secure"
        mode=$(perl -ne 'if (/"dns_over_https"\s*:\s*\{[^}]*"mode"\s*:\s*"([^"]+)"/) { print "$1\n"; exit }' "$prefs" 2>/dev/null)
        templates=$(perl -ne 'if (/"dns_over_https"\s*:\s*\{[^}]*"templates"\s*:\s*"([^"]+)"/) { print "$1\n"; exit }' "$prefs" 2>/dev/null)
        if [[ -n "$mode" ]]; then
            browser_findings+="    $label DoH: mode=$mode${templates:+, server=$templates}\n"
        else
            browser_findings+="    $label installed, DoH: not configured (system DNS)\n"
        fi
    fi
done
# Firefox: per-profile prefs.js, network.trr.mode (0=off, 2=enabled w/fallback, 3=enabled only, 5=disabled)
for fx_prefs in "$HOME/Library/Application Support/Firefox/Profiles"/*.default*/prefs.js; do
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
    break  # only check one profile
done
if [[ -n "$browser_findings" ]]; then
    info "  Browser DoH state (browsers may bypass system DNS):"
    printf '%b' "$browser_findings"
fi

# Network services often reveal VPN/DNS clients that don't install at /Applications
# (e.g. CLI-only NextDNS, kernel/system extensions, virtual interfaces)
ns_pattern='Proton|Mullvad|NextDNS|Cisco|NordVPN|Tailscale|WireGuard|OpenVPN|Cloudflare|WARP|AdGuard'
ns_found=$(networksetup -listallnetworkservices 2>/dev/null | grep -iE "$ns_pattern" || true)
if [[ -n "$ns_found" ]]; then
    echo "  Network services:"
    echo "$ns_found" | sed 's/^/    /'
fi

fi  # end rung 7

# Persist state for future --quick runs (only when we ran the FULL ladder).
if [[ "$QUICK_MODE" -eq 0 ]]; then
    cache_save_state "$PASS_COUNT" "$FAIL_COUNT" "$FIRST_FAIL"
fi

emit_summary
if [[ "$JSON_MODE" -eq 0 ]]; then
    if [[ -n "$FIRST_FAIL" ]]; then
        case "$FIRST_FAIL" in
            *"LINK LAYER"*)    echo "  Next: check ifconfig / networksetup, fix interface / DHCP" ;;
            *"SOCKET"*)        echo "  Next: check Little Snitch / Lulu / pfctl rules; AV protocol filtering; consumer router DoH IP blocking" ;;
            *"ICMP"*|*"IP /"*) echo "  Next: check route table, ISP/upstream connectivity" ;;
            *"DNS INFRASTRUCTURE"*) echo "  Next: check UDP/53 outbound, router DNS forwarder" ;;
            *"RESOLVER PATH"*) echo "  Next: bash scripts/macos/dns-audit.sh   # drill rung 5 (the hook layer)" ;;
            *"APPLICATION"*)   echo "  Next: check proxy (scutil --proxy), keychain certs, IPv6 preference" ;;
            *) echo "  Next: re-run with --verbose; check references/common-culprits.md" ;;
        esac
    else
        echo "  (No failures. If user still reports issues, see rung 7 footprint and time-based notes in references/diagnostic-ladder.md.)"
    fi
    echo
    echo "=== END PROBE ==="
fi
