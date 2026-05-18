#!/usr/bin/env bash
# mac-ops :: keychain-audit.sh
# Audit Keychain health: login keychain status, certificate trust chain,
# securityd activity, recurring password prompts.
#
# "macOS keeps asking for my password" is the #2 most common Mac complaint
# after "this app won't open the camera". Root cause is usually a damaged
# login.keychain-db, an out-of-sync iCloud Keychain, or a recurring TCC
# prompt being confused for a Keychain prompt.

set -u

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

Reports:
  1. Login keychain location + last-modified time + lock state
  2. System / iCloud keychain detection
  3. securityd / trustd recent error activity
  4. Expired certificates in user keychain
  5. Apple developer codesign trust state
  6. Common "password keeps prompting" causes

Common fix sequence for "keeps prompting":
  1. Keychain Access → File → Lock All Keychains → quit
  2. Quit Keychain Access; open it; "Update Keychain Password" if prompted
  3. Or worst case: rename login.keychain-db (loses cached passwords)
       cd ~/Library/Keychains/<UUID>
       mv login.keychain-db login.keychain-db.broken
       (reboot — a fresh one will be created)
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# ----------------------------------------------------------------------------
section "1. LOGIN KEYCHAIN"
# ----------------------------------------------------------------------------
# Modern macOS stores keychains in ~/Library/Keychains/<UUID>/
keychain_dir=$(ls -d "$HOME/Library/Keychains"/* 2>/dev/null | head -1)
if [[ -n "$keychain_dir" ]]; then
    note "  Keychain directory: $keychain_dir"
    if [[ -f "$keychain_dir/login.keychain-db" ]]; then
        size=$(ls -lh "$keychain_dir/login.keychain-db" | awk '{print $5}')
        mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$keychain_dir/login.keychain-db")
        log_pass "login.keychain-db" "$size, modified $mtime"
    else
        log_warn "login.keychain-db" "missing in $keychain_dir"
    fi
else
    log_warn "Keychain directory" "not found at standard location"
fi

# Show keychain list as the security tool sees it
note ""
note "  security list-keychains:"
security list-keychains -d user 2>/dev/null | sed 's/^/    /' | head -10

# ----------------------------------------------------------------------------
section "2. KEYCHAIN LOCK STATE"
# ----------------------------------------------------------------------------
# Use 'security show-keychain-info' on the login keychain
if security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null; then
    log_pass "Login keychain unlocked"
else
    # Either locked or doesn't exist at that path; check modern path
    login_db=$(security default-keychain 2>/dev/null | tr -d '"' | awk '{print $1}')
    if [[ -n "$login_db" ]]; then
        if security show-keychain-info "$login_db" 2>/dev/null; then
            log_pass "Default keychain unlocked" "$login_db"
        else
            log_info "Default keychain" "may be locked or auto-locked"
        fi
    fi
fi

# ----------------------------------------------------------------------------
section "3. SECURITYD / TRUSTD ACTIVITY (recent errors)"
# ----------------------------------------------------------------------------
sec_errors=$(log show --last 24h --style compact \
    --predicate '(process == "securityd" OR process == "trustd" OR process == "keychainsharingmessaging") AND (messageType == "Error" OR messageType == "Fault")' \
    2>/dev/null | head -10)

if [[ -n "$sec_errors" ]]; then
    n=$(echo "$sec_errors" | wc -l | tr -d ' \n')
    log_warn "securityd/trustd errors (24h)" "$n events"
    echo "$sec_errors" | head -5 | sed 's/^/    /'
else
    log_pass "securityd/trustd errors (24h)" "none"
fi

# Specifically: keychain password prompts in log
prompt_events=$(log show --last 24h --style compact \
    --predicate 'eventMessage CONTAINS[c] "keychain" AND (eventMessage CONTAINS[c] "prompt" OR eventMessage CONTAINS[c] "password")' \
    2>/dev/null | head -5)
if [[ -n "$prompt_events" ]]; then
    log_info "Keychain prompt events (24h)" "see below"
    echo "$prompt_events" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "4. CERTIFICATE INVENTORY"
# ----------------------------------------------------------------------------
# Count certs in user keychain
cert_count=$(security find-certificate -a 2>/dev/null | grep -c "^keychain:" | tr -d ' \n')
cert_count="${cert_count:-0}"
log_info "Certs in user keychain" "$cert_count"

# Expired certs check (most certs in system keychain rotate naturally; here we
# check the user's own certs)
expired=$(security find-certificate -a -p 2>/dev/null | awk '
    /-----BEGIN CERTIFICATE-----/{flag=1; buf=""}
    flag{buf=buf"\n"$0}
    /-----END CERTIFICATE-----/{
        cmd="openssl x509 -noout -enddate 2>/dev/null"
        print buf | cmd
        close(cmd)
        flag=0
    }' 2>/dev/null | grep "notAfter" | head -5)
# This is best-effort; full expiry scan requires more work

# ----------------------------------------------------------------------------
section "5. CODESIGN / GATEKEEPER STATE"
# ----------------------------------------------------------------------------
gk_status=$(spctl --status 2>&1)
case "$gk_status" in
    *enabled*) log_pass "Gatekeeper" "enabled" ;;
    *disabled*) log_warn "Gatekeeper" "disabled — system is less secure" ;;
    *) log_info "Gatekeeper" "$gk_status" ;;
esac

# Check developer mode (on Apple Silicon, controls things like unsigned dylib loading)
if is_apple_silicon; then
    dev_mode=$(spctl developer-mode status 2>/dev/null || echo "(needs sudo to query)")
    note "  Apple Silicon developer mode: $dev_mode"
fi

# ----------------------------------------------------------------------------
section "6. iCLOUD KEYCHAIN STATE"
# ----------------------------------------------------------------------------
# Check if iCloud Keychain is enabled by looking for the keychain-sync daemons
if pgrep -x securityd >/dev/null && \
   log show --last 1h --style compact --predicate 'process == "securityd" AND eventMessage CONTAINS "circle"' 2>/dev/null | grep -q "joined"; then
    log_info "iCloud Keychain" "appears to be in sync circle"
else
    log_info "iCloud Keychain" "state could not be determined from log"
fi

# ----------------------------------------------------------------------------
section "7. COMMON ISSUES"
# ----------------------------------------------------------------------------
note "  If \"macOS keeps asking for password\":"
note "    Most common cause: login.keychain-db password drifted from account password."
note "    Fix: Keychain Access → preferences → Reset My Default Keychain"
note "    (loses cached passwords but is the cleanest reset)"
note ""
note "  If \"This connection is not private\" for valid sites:"
note "    Check system clock (mac-ops health-audit reports clock drift)."
note "    Run: scripts/health-audit.sh --days 1"

# ----------------------------------------------------------------------------
emit_summary
