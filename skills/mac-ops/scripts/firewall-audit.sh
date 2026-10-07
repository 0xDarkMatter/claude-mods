#!/usr/bin/env bash
# mac-ops :: firewall-audit.sh
# Inventory macOS firewall state across all layers:
#   1. Application Layer Firewall (ALF) — System Settings → Network → Firewall
#   2. Packet Filter (pf) — BSD-level packet filtering
#   3. Network Extension content filters (Little Snitch, Lulu, Cisco AnyConnect, etc.)
#   4. Stealth mode + logging state

set -u

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

macOS firewall stack:
  ALF (socketfilterfw)        Application-layer firewall — blocks incoming
                              connections per-app. Visible in System Settings.
  pf (packet filter)          BSD-style packet filtering. Configured via
                              /etc/pf.conf and /etc/pf.anchors/. Usually
                              inactive on desktop Macs.
  Network Extension filters   Third-party (Little Snitch, Lulu, AnyConnect)
                              implement custom filtering as content filters.
                              Persist after app quit until disabled.
EOF
            exit 0 ;;
        *) shift ;;
    esac
done
# Without this restore every standard flag was silently ignored (--redact
# output meant for sharing went out unredacted). ${a[@]+...} is the bash
# 3.2-safe expansion of a possibly empty array under set -u.
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

ALF="/usr/libexec/ApplicationFirewall/socketfilterfw"

# ----------------------------------------------------------------------------
section "1. APPLICATION LAYER FIREWALL (ALF)"
# ----------------------------------------------------------------------------
if [[ ! -x "$ALF" ]]; then
    log_warn "socketfilterfw binary" "not found at $ALF"
else
    state=$("$ALF" --getglobalstate 2>/dev/null | tail -1)
    case "$state" in
        *"enabled"*) log_pass "ALF state" "$state" ;;
        *"disabled"*) log_warn "ALF state" "$state — incoming connections unblocked" ;;
        *) log_info "ALF state" "$state" ;;
    esac

    stealth=$("$ALF" --getstealthmode 2>/dev/null | tail -1)
    note "  $stealth"

    block_all=$("$ALF" --getblockall 2>/dev/null | tail -1)
    note "  $block_all"

    allow_signed=$("$ALF" --getallowsigned 2>/dev/null | tail -1)
    note "  $allow_signed"

    # Per-app rules (may require sudo)
    rules=$("$ALF" --listapps 2>/dev/null | grep -c "^[0-9]" || echo 0)
    log_info "ALF per-app rules" "$rules"
fi

# ----------------------------------------------------------------------------
section "2. PACKET FILTER (pf)"
# ----------------------------------------------------------------------------
if pf_info=$(pfctl -s info 2>&1); then
    if echo "$pf_info" | grep -q "Status: Enabled"; then
        log_warn "pf state" "Enabled — packet filter active"
        note "  $(echo "$pf_info" | head -3 | sed 's/^/  /')"
    else
        log_pass "pf state" "Disabled (default for desktop Macs)"
    fi
else
    log_info "pf state" "could not query (needs sudo)"
fi

# Anchors loaded
if pf_anchors=$(sudo -n pfctl -s Anchors 2>/dev/null); then
    if [[ -n "$pf_anchors" ]]; then
        log_info "pf anchors loaded" "$(echo "$pf_anchors" | wc -l | tr -d ' ')"
        echo "$pf_anchors" | head -10 | sed 's/^/    /'
    fi
fi

# ----------------------------------------------------------------------------
section "3. NETWORK EXTENSION CONTENT FILTERS"
# ----------------------------------------------------------------------------
# These are third-party filters that operate in their own NetworkExtension
# rather than via ALF. They persist after the parent app quits.
ne_filters=$(scutil --nc list 2>/dev/null | grep -iE "filter|firewall" || true)
if [[ -n "$ne_filters" ]]; then
    log_info "Network Extension content filters" "$(echo "$ne_filters" | wc -l | tr -d ' ')"
    echo "$ne_filters" | sed 's/^/    /'
else
    log_pass "Network Extension content filters" "none configured"
fi

# Check for common third-party firewall apps
note ""
note "  Installed firewall/network-monitoring apps:"
for app in "Little Snitch" "LuLu" "Murus" "Hands Off" "Radio Silence" "NetIQuette"; do
    if [[ -e "/Applications/$app.app" ]]; then
        note "    /Applications/$app.app"
    fi
done

# ----------------------------------------------------------------------------
section "4. FIREWALL LOG SAMPLE"
# ----------------------------------------------------------------------------
# Anything ALF dropped in last hour
recent_blocks=$(log show --last 1h --style compact \
    --predicate 'process == "socketfilterfw" OR eventMessage CONTAINS "Deny"' \
    2>/dev/null | grep -iE "(deny|block|drop)" | tail -5)
if [[ -n "$recent_blocks" ]]; then
    log_info "Recent firewall denials (1h)" "see below"
    echo "$recent_blocks" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "5. VPN / TUNNEL CONFIGURATION"
# ----------------------------------------------------------------------------
note "  Active network services (VPN/tunnel filter):"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | \
    grep -iE "vpn|tunnel|wireguard|openvpn|warp|nextdns|tailscale|cisco|anyconnect|proton|mullvad" | \
    sed 's/^/    /'

# Active tunnels right now
note ""
note "  Active utun interfaces:"
ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{ifn=$1; sub(":","",ifn)} /inet[6]? /{if(ifn!="" && $1!~/^fe80/){print "    "ifn": "$0; ifn=""}}'  | head -10

# ----------------------------------------------------------------------------
emit_summary
