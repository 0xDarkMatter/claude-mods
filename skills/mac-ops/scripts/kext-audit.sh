#!/usr/bin/env bash
# mac-ops :: kext-audit.sh
# Inventory loaded kernel extensions + system extensions.
#
# Why: kexts and system extensions run with kernel privileges. A misbehaving
# one can panic the system, leak memory, or hold a system-wide lock. They're
# the #1 cause of "Mac kernel panic" on machines that get them.

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
  1. Loaded kexts (kextstat) — third-party highlighted
  2. Installed system extensions (systemextensionsctl list)
  3. Kext load failures from log
  4. Pending kext approval (apps that requested kext but were denied)
  5. SIP and kernel security policy state

On Apple Silicon (M1+), kexts are deprecated in favor of system extensions
which run in userspace. This script reports both because some legacy products
still ship kexts even on Apple Silicon (via boot policy reduction).
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
section "1. LOADED KEXTS"
# ----------------------------------------------------------------------------
total_kexts=$(kextstat -l 2>/dev/null | wc -l | tr -d ' ')
log_info "Loaded kexts (total)" "$total_kexts"

# Third-party kexts — anything not com.apple.*
third_party=$(kextstat -l 2>/dev/null | awk '{print $6}' | grep -v "^com.apple\." | grep -v "^$" | sort -u)
third_party_count=$(echo "$third_party" | grep -c . 2>/dev/null || echo 0)

if [[ "$third_party_count" -gt 0 ]]; then
    log_warn "Third-party kexts" "$third_party_count — primary panic suspects"
    note "  Third-party kexts (loaded right now):"
    echo "$third_party" | sed 's/^/    /'
else
    log_pass "Third-party kexts" "0 — clean kernel"
fi

# ----------------------------------------------------------------------------
section "2. SYSTEM EXTENSIONS"
# ----------------------------------------------------------------------------
if command -v systemextensionsctl >/dev/null 2>&1; then
    sysext_out=$(systemextensionsctl list 2>/dev/null)
    if [[ -n "$sysext_out" ]]; then
        # The output has 0+ extensions per team. Skip the header line.
        ext_lines=$(echo "$sysext_out" | grep -E "^\s*\*?\s+[a-fA-F0-9]" || true)
        if [[ -n "$ext_lines" ]]; then
            ext_count=$(echo "$ext_lines" | wc -l | tr -d ' ')
            log_info "Installed system extensions" "$ext_count"
            note "  System extensions (team-id, bundle-id, name, state):"
            echo "$ext_lines" | head -20 | sed 's/^/    /'
        else
            log_pass "Installed system extensions" "0"
        fi
    fi
else
    log_info "systemextensionsctl" "not available (older macOS?)"
fi

# ----------------------------------------------------------------------------
section "3. RECENT KEXT LOAD FAILURES"
# ----------------------------------------------------------------------------
load_fails=$(log show --last 7d --style compact \
    --predicate '(process == "kextd" OR process == "kernel") AND (eventMessage CONTAINS[c] "kext" AND (messageType == "Error" OR messageType == "Fault"))' \
    2>/dev/null | head -20)

if [[ -n "$load_fails" ]]; then
    n=$(echo "$load_fails" | wc -l | tr -d ' ')
    log_warn "Kext load failures (7d)" "$n events"
    echo "$load_fails" | head -5 | sed 's/^/    /'
else
    log_pass "Kext load failures (7d)" "none"
fi

# ----------------------------------------------------------------------------
section "4. PENDING KEXT APPROVAL"
# ----------------------------------------------------------------------------
# Apps that have requested kext load but were denied — usually because user
# hasn't approved in System Settings → Privacy & Security
pending=$(log show --last 30d --style compact \
    --predicate 'eventMessage CONTAINS[c] "kext approval"' \
    2>/dev/null | tail -5)
if [[ -n "$pending" ]]; then
    log_warn "Pending kext approvals (30d)" "see below"
    echo "$pending" | sed 's/^/    /'
else
    log_pass "Pending kext approvals" "none"
fi

# ----------------------------------------------------------------------------
section "5. SECURITY POLICY"
# ----------------------------------------------------------------------------
# SIP status
sip_status=$(csrutil status 2>/dev/null | head -1 | awk -F': *' '{print $2}' | tr -d '.')
case "$sip_status" in
    *enabled*) log_pass "SIP" "$sip_status" ;;
    *disabled*) log_warn "SIP" "$sip_status — kernel security weakened" ;;
    *) log_info "SIP" "${sip_status:-unknown}" ;;
esac

# On Apple Silicon: bputil reports boot policy
if is_apple_silicon && command -v bputil >/dev/null 2>&1; then
    note "  Apple Silicon boot policy (requires sudo for detail):"
    sudo -n bputil -d 2>/dev/null | grep -E "Security Policy|Manage Kernel Extensions|Allow User Kernel Extensions" | head -5 | sed 's/^/    /' || \
        note "    (sudo required for full bputil read)"
fi

# Apple Silicon specific kext loading state
if is_apple_silicon; then
    kext_loading=$(kmutil showloaded 2>/dev/null | wc -l | tr -d ' ')
    log_info "kmutil showloaded count" "$kext_loading"
fi

# ----------------------------------------------------------------------------
section "6. VENDOR PATTERNS"
# ----------------------------------------------------------------------------
# Known panic-prone vendors
note "  Scanning for known-problematic kexts:"
for pattern in "eltima" "paragon" "eset" "kaspersky" "norton" "sophos" "bitdefender"; do
    matches=$(kextstat -l 2>/dev/null | awk '{print $6}' | grep -i "$pattern" || true)
    if [[ -n "$matches" ]]; then
        log_warn "Vendor kext: $pattern" "$(echo "$matches" | wc -l | tr -d ' ') loaded"
        echo "$matches" | head -3 | sed 's/^/    /'
    fi
done

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  To uninstall a system extension:"
    note "    systemextensionsctl uninstall <team-id> <bundle-id>"
    note "  To inspect a specific kext:"
    note "    kextstat -l | grep <name>"
    note "    kmutil showloaded | grep <name>   # Apple Silicon"
fi
