#!/usr/bin/env bash
# mac-ops :: tcc-audit.sh
# Read the TCC (Transparency, Consent, Control) databases to surface which
# apps have which permissions, what's been denied, and where to fix it.
#
# TCC databases:
#   ~/Library/Application Support/com.apple.TCC/TCC.db    (user-scope)
#   /Library/Application Support/com.apple.TCC/TCC.db     (system-scope, requires sudo)
#
# The user DB is readable in some macOS releases under SIP/FDA assumptions;
# this script gracefully degrades when access is denied.

set -u

APP_FILTER=""
SERVICE_FILTER=""
SHOW_DENIED_ONLY=0

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--app) APP_FILTER="$2"; shift 2 ;;
        -s|--service) SERVICE_FILTER="$2"; shift 2 ;;
        --denied) SHOW_DENIED_ONLY=1; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  -a, --app PATTERN          Filter by bundle ID or name (e.g. -a slack, -a com.slack.*)
  -s, --service PATTERN      Filter by TCC service (e.g. -s ScreenCapture, -s Camera)
  --denied                   Show only denied grants (the most common "broken" cause)

  --json, --redact, --quiet, --verbose

Examples:
  $0                                    # all grants on this user
  $0 --denied                           # what apps were denied something
  $0 -a Slack                           # Slack's permission state
  $0 -s ScreenCapture                   # who has Screen Recording

Service catalog (most common):
  kTCCServiceScreenCapture       Screen Recording
  kTCCServiceMicrophone          Microphone
  kTCCServiceCamera              Camera
  kTCCServiceAccessibility       Accessibility (control your Mac)
  kTCCServiceSystemPolicyAllFiles Full Disk Access
  kTCCServicePostEvent           Synthetic input events
  kTCCServiceListenEvent         Input event listening
  kTCCServiceAppleEvents         Automation (controlling other apps)
  kTCCServicePhotos              Photos library
  kTCCServiceContactsFull        Contacts
  kTCCServiceCalendar            Calendars
  kTCCServiceReminders           Reminders

If a script-controlled app has lost permission, the typical fix is:
  System Settings → Privacy & Security → <Service> → toggle the app off, then on
or:
  tccutil reset <Service> <bundle-id>     (resets to "Ask again" — re-prompts user)

Read references/tcc-mechanics.md for the deep dive.
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

user_tcc="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
sys_tcc="/Library/Application Support/com.apple.TCC/TCC.db"

# ----------------------------------------------------------------------------
section "1. TCC.db ACCESSIBILITY CHECK"
# ----------------------------------------------------------------------------
if [[ -r "$user_tcc" ]]; then
    log_pass "User TCC.db readable" "$user_tcc"
    user_readable=1
else
    log_warn "User TCC.db readable" "no (this terminal needs Full Disk Access)"
    user_readable=0
fi

if [[ -r "$sys_tcc" ]]; then
    log_pass "System TCC.db readable" "$sys_tcc"
    sys_readable=1
elif sudo -n true 2>/dev/null; then
    if sudo -n test -r "$sys_tcc"; then
        log_info "System TCC.db" "readable via sudo (cached credential)"
        sys_readable=1
    else
        log_info "System TCC.db" "would need sudo"
        sys_readable=0
    fi
else
    log_info "System TCC.db" "requires sudo (skipped)"
    sys_readable=0
fi

if [[ "$user_readable" -eq 0 ]] && [[ "$sys_readable" -eq 0 ]]; then
    note ""
    note "  Neither TCC.db is readable from this terminal."
    note "  To grant Full Disk Access to your terminal:"
    note "    System Settings → Privacy & Security → Full Disk Access → +"
    note "    Add: /Applications/Utilities/Terminal.app (or your terminal app)"
    note "    Then restart the terminal session."
    emit_summary
    exit 0
fi

# ----------------------------------------------------------------------------
section "2. PERMISSION GRANTS"
# ----------------------------------------------------------------------------
# auth_value semantics:
#   0 = Denied
#   1 = Unknown
#   2 = Allowed
#   3 = Limited (e.g. partial Photos access)
# The 'service' column is kTCC* string; 'client' is bundle ID; 'client_type' is 0=bundle, 1=path
# Modern TCC.db schemas have additional columns; we select defensively.

build_filter() {
    local where="1=1"
    [[ -n "$APP_FILTER" ]] && where="$where AND (client LIKE '%${APP_FILTER//\'/}%' COLLATE NOCASE)"
    [[ -n "$SERVICE_FILTER" ]] && where="$where AND (service LIKE '%${SERVICE_FILTER//\'/}%' COLLATE NOCASE)"
    [[ "$SHOW_DENIED_ONLY" -eq 1 ]] && where="$where AND auth_value = 0"
    echo "$where"
}

query_tcc() {
    local db="$1"
    local where
    where=$(build_filter)
    sqlite3 -separator '|' "$db" \
        "SELECT service, client, auth_value, datetime(last_modified, 'unixepoch') FROM access WHERE $where ORDER BY auth_value, service, client" \
        2>/dev/null
}

if [[ "$user_readable" -eq 1 ]]; then
    note "  --- User-scope (per-user permission grants) ---"
    rows=$(query_tcc "$user_tcc")
    if [[ -z "$rows" ]]; then
        log_pass "User TCC grants matching filter" "0 rows"
    else
        count=$(echo "$rows" | wc -l | tr -d ' ')
        log_info "User TCC grants" "$count rows"
        note "  service                      | client                                              | auth | last modified"
        note "  -----------------------------|----------------------------------------------------|------|------------------------"
        echo "$rows" | head -50 | awk -F'|' '{
            svc = substr($1, 1, 28)
            cli = substr($2, 1, 50)
            auth = $3
            ts = $4
            label = (auth == 0 ? "DENY" : (auth == 2 ? "ALLOW" : (auth == 3 ? "LIM" : "?")))
            printf "  %-28s | %-50s | %-4s | %s\n", svc, cli, label, ts
        }'
        denied=$(echo "$rows" | awk -F'|' '$3 == 0' | wc -l | tr -d ' ')
        if [[ "$denied" -gt 0 ]]; then
            log_warn "User TCC denials" "$denied — see DENY rows above"
        fi
    fi
fi

if [[ "$sys_readable" -eq 1 ]]; then
    note ""
    note "  --- System-scope (machine-wide grants, e.g. Full Disk Access) ---"
    if [[ -r "$sys_tcc" ]]; then
        rows=$(query_tcc "$sys_tcc")
    else
        rows=$(sudo sqlite3 -separator '|' "$sys_tcc" \
            "SELECT service, client, auth_value, datetime(last_modified, 'unixepoch') FROM access WHERE $(build_filter) ORDER BY auth_value, service, client" 2>/dev/null)
    fi
    if [[ -z "$rows" ]]; then
        log_pass "System TCC grants matching filter" "0 rows"
    else
        count=$(echo "$rows" | wc -l | tr -d ' ')
        log_info "System TCC grants" "$count rows"
        echo "$rows" | head -30 | awk -F'|' '{
            svc = substr($1, 1, 28)
            cli = substr($2, 1, 50)
            auth = $3
            ts = $4
            label = (auth == 0 ? "DENY" : (auth == 2 ? "ALLOW" : (auth == 3 ? "LIM" : "?")))
            printf "  %-28s | %-50s | %-4s | %s\n", svc, cli, label, ts
        }'
    fi
fi

# ----------------------------------------------------------------------------
section "3. RECENT TCC PROMPTS"
# ----------------------------------------------------------------------------
# Look for tccd / system extension prompt activity in the last 7 days
prompts=$(log show --last 7d --style compact \
    --predicate 'process == "tccd"' 2>/dev/null \
    | grep -iE "(prompt|denied|auth)" | head -10)

if [[ -n "$prompts" ]]; then
    log_info "Recent tccd activity (7d)" "see below"
    echo "$prompts" | sed 's/^/    /'
else
    log_pass "Recent tccd activity" "quiet"
fi

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Fix a denied grant:"
    note "    1) System Settings → Privacy & Security → <Service> → toggle app off then on"
    note "    2) Or: tccutil reset <ServiceShortName> <bundle-id>"
    note "       e.g.  tccutil reset ScreenCapture com.tinyspeck.slackmacgap"
    note "  See references/tcc-mechanics.md for the full service catalog."
fi
