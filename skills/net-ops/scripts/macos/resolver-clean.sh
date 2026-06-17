#!/usr/bin/env bash
# net-ops :: macos/resolver-clean.sh
# Safely remove orphaned /etc/resolver/* files left behind by disconnected VPNs.
# NEVER removes Tailscale or current-VPN-tunnel entries.
#
# Defaults to DRY RUN — pass --apply to actually delete.
# Requires sudo.

set -eu
# Shared terminal toolkit (skills/_lib/term.sh) — colorized, ASCII-aware section
# headers. Dump/fixer output isn't a checklist, so it uses the bare-header style
# (a deliberate exception per docs/TERMINAL-DESIGN.md), not the enclosing panel.
__nlib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__nlib:-}" ] && [ -f "$__nlib/term.sh" ]; then . "$__nlib/term.sh"; term_init
else term_header() { printf '== %s ==\n' "${1:-}"; }; fi

APPLY=0
PROTECT_PATTERNS="${PROTECT_PATTERNS:-100\.100\.100\.100}"

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --protect=*) PROTECT_PATTERNS="${arg#--protect=}" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--apply] [--protect=REGEX]

  --apply              Actually delete (default: dry-run only)
  --protect=REGEX      Nameserver pattern to protect (default: Tailscale's 100.100.100.100)

Examples:
  $0                                  # show what would be removed
  $0 --apply                          # remove orphan resolvers, protecting Tailscale
  $0 --apply --protect='100\\.\\.|192\\.168\\.1\\.'  # also protect 192.168.1.x
EOF
            exit 0 ;;
    esac
done

if [[ ! -d /etc/resolver ]] || [[ -z "$(ls -A /etc/resolver 2>/dev/null)" ]]; then
    echo "/etc/resolver/ is empty. Nothing to do."
    exit 0
fi

term_header "BEFORE"
for f in /etc/resolver/*; do
    [[ -f "$f" ]] || continue
    ns=$(awk '/^nameserver/{print $2}' "$f" | tr '\n' ',')
    echo "  $f -> ${ns%,}"
done

TARGETS=()
for f in /etc/resolver/*; do
    [[ -f "$f" ]] || continue
    if awk '/^nameserver/{print $2}' "$f" | grep -qE "$PROTECT_PATTERNS"; then
        continue
    fi
    TARGETS+=("$f")
done

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    echo
    echo "No orphan resolver files (all match protected nameserver pattern). Nothing to clean."
    exit 0
fi

echo
term_header "TARGETS FOR REMOVAL"
for f in "${TARGETS[@]}"; do
    echo "  $f"
done

if [[ "$APPLY" -eq 0 ]]; then
    echo
    echo "DRY RUN — pass --apply to actually remove the files above."
    exit 0
fi

# Apply
if [[ "$EUID" -ne 0 ]]; then
    echo "Need root. Re-running with sudo..."
    exec sudo "$0" --apply --protect="$PROTECT_PATTERNS"
fi

echo
term_header "REMOVING"
for f in "${TARGETS[@]}"; do
    if rm -f "$f"; then
        echo "[OK]   $f"
    else
        echo "[FAIL] $f"
    fi
done

echo
term_header "FLUSHING DNS CACHE"
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true
echo "  done."

echo
term_header "VERIFICATION"
if out=$(dscacheutil -q host -a name google.com 2>&1) && echo "$out" | grep -q "ip_address:"; then
    addr=$(echo "$out" | awk '/ip_address:/{print $2; exit}')
    echo "[PASS] dscacheutil google.com -> $addr"
else
    echo "[FAIL] dscacheutil still broken. Drill into scutil --dns and configuration profiles."
fi

if curl -sS -o /dev/null -w "[PASS] HTTPS google.com -> HTTP %{http_code}\n" --max-time 8 https://www.google.com 2>&1; then
    :
else
    echo "[FAIL] HTTPS still broken."
fi

echo
term_header "AFTER"
if [[ -n "$(ls -A /etc/resolver 2>/dev/null)" ]]; then
    for f in /etc/resolver/*; do
        [[ -f "$f" ]] || continue
        ns=$(awk '/^nameserver/{print $2}' "$f" | tr '\n' ',')
        echo "  $f -> ${ns%,}"
    done
else
    echo "  /etc/resolver/ is now empty."
fi
