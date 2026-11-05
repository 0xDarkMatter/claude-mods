#!/usr/bin/env bash
# mac-ops :: update-state.sh
# macOS Software Update audit: auto-update settings, pending updates,
# update history, App Store update settings.

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
  1. macOS Software Update auto-policy
  2. Pending updates (softwareupdate -l)
  3. macOS version + build
  4. Update install history (last 10)
  5. App Store auto-update settings
  6. Pending app updates from Mac App Store

Skip the spinner: 'softwareupdate -l' contacts Apple's servers and can take
30-60 seconds. The script prints expected-delay markers.
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
section "1. AUTO-UPDATE POLICY"
# ----------------------------------------------------------------------------
# Read from com.apple.SoftwareUpdate
auto_check=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null)
auto_download=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null)
auto_install_macos=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)
auto_install_app=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdate 2>/dev/null)
auto_install_security=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall 2>/dev/null)

show_bool() {
    case "$1" in
        1) echo "ON" ;;
        0) echo "OFF" ;;
        *) echo "(unset)" ;;
    esac
}

note "  Software Update preferences:"
note "    Check for updates automatically: $(show_bool "$auto_check")"
note "    Download updates when available: $(show_bool "$auto_download")"
note "    Install macOS updates:           $(show_bool "$auto_install_macos")"
note "    Install app updates from App Store: $(show_bool "$auto_install_app")"
note "    Install system data + security:  $(show_bool "$auto_install_security")"

if [[ "$auto_check" == "1" ]] && [[ "$auto_install_security" == "1" ]]; then
    log_pass "Security updates" "auto-install ON"
else
    log_warn "Security updates" "auto-install OFF — patches won't apply without manual action"
fi

# ----------------------------------------------------------------------------
section "2. MACOS VERSION"
# ----------------------------------------------------------------------------
prod=$(sw_vers -productName 2>/dev/null)
ver=$(sw_vers -productVersion 2>/dev/null)
build=$(sw_vers -buildVersion 2>/dev/null)
note "  $prod $ver ($build)"
log_info "macOS version" "$ver build $build"

# ----------------------------------------------------------------------------
section "3. PENDING UPDATES"
# ----------------------------------------------------------------------------
note "  Checking with Apple's servers (this can take 30-60s)..."
pending=$(softwareupdate -l 2>&1 | tail -20)
if echo "$pending" | grep -q "No new software available"; then
    log_pass "Pending updates" "none — system is current"
elif echo "$pending" | grep -q "Software Update found"; then
    note "  Pending list:"
    echo "$pending" | grep -E "(\*|^Software|Title:|Action:|Recommended:)" | head -20 | sed 's/^/    /'
    update_count=$(echo "$pending" | grep -c "Title:" || echo 0)
    log_warn "Pending updates" "$update_count items pending"
else
    log_info "softwareupdate output" "$(echo "$pending" | head -3 | tr '\n' ' ')"
fi

# ----------------------------------------------------------------------------
section "4. RECENT UPDATE HISTORY"
# ----------------------------------------------------------------------------
history_plist="/Library/Updates/index.plist"
note "  Last 10 install events from /Library/Updates (best-effort):"
if [[ -r "$history_plist" ]]; then
    # Can't easily parse the plist without knowing the schema; show
    # mtime of the directory entries as a proxy
    ls -lt /Library/Updates 2>/dev/null | head -10 | sed 's/^/    /'
fi

# Also check installer logs
recent_installs=$(log show --last 30d --style compact \
    --predicate 'process == "softwareupdated" AND eventMessage CONTAINS[c] "installed"' \
    2>/dev/null | tail -5)
if [[ -n "$recent_installs" ]]; then
    note ""
    note "  Recent softwareupdated install entries (log, last 30d):"
    echo "$recent_installs" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "5. MAS / APP STORE"
# ----------------------------------------------------------------------------
mas_check=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdate 2>/dev/null)
note "  App Store auto-update: $(show_bool "$mas_check")"

# Is mas installed (third-party MAS CLI)?
if command -v mas >/dev/null 2>&1; then
    note ""
    note "  mas (Mac App Store CLI) is installed."
    mas_outdated=$(mas outdated 2>/dev/null)
    if [[ -n "$mas_outdated" ]]; then
        n=$(echo "$mas_outdated" | wc -l | tr -d ' ')
        log_info "Pending MAS updates" "$n (via mas outdated)"
        echo "$mas_outdated" | head -10 | sed 's/^/    /'
    else
        log_pass "MAS apps" "all up to date"
    fi
fi

# ----------------------------------------------------------------------------
section "6. RECOMMENDED UPDATES"
# ----------------------------------------------------------------------------
# Recommended security/system updates that Apple wants you to install
# (subset of softwareupdate -l output)
recommended=$(softwareupdate -l 2>&1 | awk '/Recommended: YES/{print prev} {prev=$0}' | head -5)
if [[ -n "$recommended" ]]; then
    log_warn "Recommended updates pending" "see list"
    echo "$recommended" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Install playbook:"
    note "    softwareupdate -l                # list pending"
    note "    sudo softwareupdate -i -a -R     # install all (recommended), reboot if needed"
    note "    softwareupdate --install <name>  # specific update"
fi
