#!/usr/bin/env bash
# net-ops :: linux/resolved-reset.sh
# Reset systemd-resolved state when per-link DNS gets stuck (typical after
# VPN disconnect leaves stale per-link DNS / domain settings).
#
# Defaults to DRY RUN — pass --apply to actually act.
# Requires sudo for the apply path.

set -eu
# Shared terminal toolkit (skills/_lib/term.sh) — colorized, ASCII-aware section
# headers. Dump/fixer output isn't a checklist, so it uses the bare-header style
# (a deliberate exception per docs/TERMINAL-DESIGN.md), not the enclosing panel.
__nlib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__nlib:-}" ] && [ -f "$__nlib/term.sh" ]; then . "$__nlib/term.sh"; term_init
else term_header() { printf '== %s ==\n' "${1:-}"; }; fi

APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--apply]

Diagnoses and (with --apply) resets systemd-resolved per-link DNS state.

  --apply    Flush caches and revert each link's DNS to NetworkManager/networkd defaults
             (default: dry-run, prints what would happen)
EOF
            exit 0 ;;
    esac
done

if ! systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "systemd-resolved is not active. This script only applies when it is."
    echo "On non-systemd-resolved systems, edit /etc/resolv.conf or NetworkManager config directly."
    exit 0
fi

term_header "BEFORE"
resolvectl status 2>/dev/null | head -60

# Find links with non-empty per-link DNS (potential stale state)
LINKS_WITH_DNS=$(resolvectl status 2>/dev/null | awk '
    /^Link [0-9]+ \(/{ split($0,a," \\("); split(a[2],b,")"); link=b[1]; ifn=a[1]; sub("Link ","",ifn); has=0 }
    /Current DNS Server:|DNS Servers:/{ if(NF>3){print ifn"|"link} }
' | sort -u)

if [[ -z "$LINKS_WITH_DNS" ]]; then
    echo
    echo "No links have explicit DNS set. Nothing to reset."
    exit 0
fi

echo
term_header "LINKS WITH EXPLICIT DNS"
echo "$LINKS_WITH_DNS" | while IFS='|' read -r idx name; do
    echo "  Link $idx ($name)"
done

if [[ "$APPLY" -eq 0 ]]; then
    echo
    echo "DRY RUN — pass --apply to actually reset these links and flush caches."
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Need root. Re-running with sudo..."
    exec sudo "$0" --apply
fi

echo
term_header "RESETTING"
echo "$LINKS_WITH_DNS" | while IFS='|' read -r idx name; do
    if resolvectl revert "$name" 2>/dev/null; then
        echo "[OK]   reverted $name"
    else
        echo "[WARN] revert failed for $name (may be a VPN tunnel — manual cleanup may be needed)"
    fi
done

echo
term_header "FLUSHING CACHE"
resolvectl flush-caches && echo "  cache flushed"

# Restart for good measure if user really wanted a reset
systemctl restart systemd-resolved
echo "  systemd-resolved restarted"

echo
term_header "VERIFICATION"
if out=$(getent hosts google.com 2>&1) && [[ -n "$out" ]]; then
    echo "[PASS] getent hosts google.com -> $(echo "$out" | awk '{print $1}')"
else
    echo "[FAIL] getent still failing. Check /etc/nsswitch.conf and /etc/resolv.conf."
fi

if curl -sS -o /dev/null -w "[PASS] HTTPS google.com -> HTTP %{http_code}\n" --max-time 8 https://www.google.com 2>&1; then
    :
else
    echo "[FAIL] HTTPS still broken."
fi

echo
term_header "AFTER"
resolvectl status 2>/dev/null | head -40
