#!/usr/bin/env bash
# mac-ops :: network-locations.sh
# Inventory macOS Network Locations (System Settings → Network → ... → Locations).
# Each location is a separate set of network preferences — useful for "home vs
# office vs cafe" profiles. A stale location may have wrong DNS or proxy.

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

Reports:
  1. Configured network locations + active location
  2. Per-location DNS / proxy / search-domain config
  3. Stale locations referencing missing network services
  4. Network service order (which interface "wins" for the default route)

Switch location:
  System Settings → Network → ... → Locations → choose
  Or CLI: networksetup -switchtolocation "Location Name"
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

# ----------------------------------------------------------------------------
section "1. CONFIGURED LOCATIONS"
# ----------------------------------------------------------------------------
current=$(networksetup -getcurrentlocation 2>/dev/null)
locations=$(networksetup -listlocations 2>/dev/null)
loc_count=$(echo "$locations" | grep -c . 2>/dev/null || echo 0)

log_info "Network locations configured" "$loc_count"
note "  Current location: $current"
note "  All locations:"
echo "$locations" | sed 's/^/    /'

# ----------------------------------------------------------------------------
section "2. NETWORK SERVICE ORDER"
# ----------------------------------------------------------------------------
note "  Priority order (highest first — first reachable wins default route):"
networksetup -listnetworkserviceorder 2>/dev/null | head -20 | sed 's/^/    /'

# ----------------------------------------------------------------------------
section "3. ACTIVE LOCATION DNS / PROXY STATE"
# ----------------------------------------------------------------------------
note "  Per-service DNS:"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
    [[ "$svc" == \** ]] && continue   # disabled
    dns=$(networksetup -getdnsservers "$svc" 2>/dev/null)
    [[ "$dns" == *"aren't any"* ]] && dns="(none)"
    printf "    %-35s %s\n" "$svc:" "$dns"
done

note ""
note "  Per-service search domains:"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
    [[ "$svc" == \** ]] && continue
    sd=$(networksetup -getsearchdomains "$svc" 2>/dev/null)
    [[ "$sd" == *"aren't any"* ]] && continue
    printf "    %-35s %s\n" "$svc:" "$sd"
done

# Web proxy state
note ""
note "  Web proxy state:"
scutil --proxy 2>/dev/null | grep -E "HTTPEnable|HTTPSEnable|ProxyAutoConfigEnable|ProxyAutoConfigURLString" | sed 's/^/    /'

# ----------------------------------------------------------------------------
section "4. NETWORK PREFERENCES PLIST INSPECTION"
# ----------------------------------------------------------------------------
# /Library/Preferences/SystemConfiguration/preferences.plist holds all locations
# We can extract the location list defensively
prefs_plist="/Library/Preferences/SystemConfiguration/preferences.plist"
if [[ -r "$prefs_plist" ]]; then
    # Extract just the Sets dict, which has one entry per location
    set_count=$(plutil -extract Sets raw -o - "$prefs_plist" 2>/dev/null | wc -l | tr -d ' ')
    log_info "preferences.plist Sets count" "$set_count"
fi

# ----------------------------------------------------------------------------
section "5. STALE / DISABLED SERVICES"
# ----------------------------------------------------------------------------
# Asterisked services in listallnetworkservices are disabled
disabled=$(networksetup -listallnetworkservices 2>/dev/null | grep '^\*' || true)
if [[ -n "$disabled" ]]; then
    n=$(echo "$disabled" | wc -l | tr -d ' ')
    log_info "Disabled network services" "$n"
    echo "$disabled" | sed 's/^/    /'
else
    log_pass "Disabled network services" "0"
fi

# Services referencing missing hardware
note ""
note "  Network services check:"
networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port|Device/{print}' | head -15 | sed 's/^/    /'

# ----------------------------------------------------------------------------
emit_summary
