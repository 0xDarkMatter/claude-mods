#!/usr/bin/env bash
# mac-ops :: safe-disable-startup.sh
# Disable a startup item by name pattern. Reversible.
#
# Mechanisms handled (no sudo for user-scope):
#   - Login Items                (via osascript / System Events)
#   - User LaunchAgents          (launchctl disable gui/$UID/<label>)
#   - System LaunchAgents        (launchctl disable gui/$UID/<label>)
#
# Mechanisms handled (sudo required):
#   - System LaunchDaemons       (sudo launchctl disable system/<label>)
#
# Default mode is DRY RUN. Pass --apply to actually disable.
# Use --enable to reverse a prior disable.

set -u

NAME_PATTERN=""
APPLY=0
ENABLE=0
LIST_ONLY=0

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name) NAME_PATTERN="$2"; shift 2 ;;
        --list)    LIST_ONLY=1; shift ;;
        --apply)   APPLY=1; shift ;;
        --enable)  ENABLE=1; APPLY=1; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  -n, --name PATTERN     Glob pattern matching the entry label / name
  --list                 List all currently-disabled launchd entries
  --apply                Actually perform the disable (default: dry-run)
  --enable               Re-enable a previously disabled item (implies --apply)

  --json, --redact, --quiet, --verbose   Standard flags

Examples:
  $0 --list                              # show current disable state
  $0 -n 'com.adobe.*'                    # dry-run: what would be disabled?
  $0 -n 'com.adobe.*' --apply            # disable Adobe agents
  $0 -n 'com.adobe.*' --enable           # re-enable
  $0 -n 'Adobe Updater' --apply          # also matches Login Item by name

Note: System LaunchDaemons (/Library/LaunchDaemons) require sudo and operate
on system/<label> instead of gui/\$UID/<label>. The script asks for sudo only
when needed.
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
# --list mode: show all disabled launchctl entries
# ----------------------------------------------------------------------------
if [[ "$LIST_ONLY" -eq 1 ]]; then
    section "DISABLED LAUNCHD ENTRIES (user domain)"
    if launchctl print-disabled "gui/$UID" 2>/dev/null | grep -E "=> (true|disabled)$" | sed 's/^/  /'; then
        :
    else
        note "  (no user-domain disables, or print-disabled requires newer macOS)"
    fi
    section "DISABLED LAUNCHD ENTRIES (system domain — sudo)"
    if sudo -n launchctl print-disabled system 2>/dev/null | grep -E "=> (true|disabled)$" | sed 's/^/  /'; then
        :
    else
        note "  (system domain requires sudo, or no entries disabled)"
    fi
    emit_summary
    exit 0
fi

if [[ -z "$NAME_PATTERN" ]]; then
    echo "Error: -n PATTERN required (or --list)" >&2
    exit "$EXIT_USAGE"
fi

# ----------------------------------------------------------------------------
section "1. SEARCH MATCHES"
# ----------------------------------------------------------------------------

# Find matching LaunchAgent plists (user + system)
user_matches=()
sys_agent_matches=()
sys_daemon_matches=()

for p in "$HOME/Library/LaunchAgents"/*.plist /Library/LaunchAgents/*.plist; do
    [[ -f "$p" ]] || continue
    label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p" 2>/dev/null || basename "$p" .plist)
    # Match by label OR filename
    if [[ "$label" == $NAME_PATTERN ]] || [[ "$(basename "$p" .plist)" == $NAME_PATTERN ]]; then
        case "$p" in
            "$HOME"/*) user_matches+=("$label|$p") ;;
            *)         sys_agent_matches+=("$label|$p") ;;
        esac
    fi
done

for p in /Library/LaunchDaemons/*.plist; do
    [[ -f "$p" ]] || continue
    label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p" 2>/dev/null || basename "$p" .plist)
    if [[ "$label" == $NAME_PATTERN ]] || [[ "$(basename "$p" .plist)" == $NAME_PATTERN ]]; then
        sys_daemon_matches+=("$label|$p")
    fi
done

# Find matching Login Items (by name only; AppleScript glob match)
login_item_matches=()
if items=$(osascript <<APPLESCRIPT 2>/dev/null
tell application "System Events"
    set output to ""
    repeat with li in (every login item)
        set itemName to name of li
        if itemName is like "$NAME_PATTERN" then
            set output to output & itemName & linefeed
        end if
    end repeat
    return output
end tell
APPLESCRIPT
); then
    while IFS= read -r name; do
        [[ -n "$name" ]] && login_item_matches+=("$name")
    done <<< "$items"
fi

total_matches=$(( ${#user_matches[@]} + ${#sys_agent_matches[@]} + ${#sys_daemon_matches[@]} + ${#login_item_matches[@]} ))

if [[ "$total_matches" -eq 0 ]]; then
    log_warn "Matches for '$NAME_PATTERN'" "0 — nothing to do"
    emit_summary
    exit "$EXIT_NOT_FOUND"
fi

log_pass "Matches for '$NAME_PATTERN'" "$total_matches"
[[ ${#user_matches[@]} -gt 0 ]]       && note "  User LaunchAgents:"      && printf "    %s\n" "${user_matches[@]%|*}"
[[ ${#sys_agent_matches[@]} -gt 0 ]]  && note "  System LaunchAgents:"    && printf "    %s\n" "${sys_agent_matches[@]%|*}"
[[ ${#sys_daemon_matches[@]} -gt 0 ]] && note "  System LaunchDaemons:"   && printf "    %s\n" "${sys_daemon_matches[@]%|*}"
[[ ${#login_item_matches[@]} -gt 0 ]] && note "  Login Items:"            && printf "    %s\n" "${login_item_matches[@]}"

# ----------------------------------------------------------------------------
if [[ "$APPLY" -eq 0 ]]; then
    section "2. DRY RUN — would $([[ "$ENABLE" -eq 1 ]] && echo enable || echo disable)"
    note "  Pass --apply to perform the action."
    emit_summary
    exit 0
fi
# ----------------------------------------------------------------------------

verb=$([[ "$ENABLE" -eq 1 ]] && echo enable || echo disable)
section "2. APPLY — ${verb}"

# launchctl verb selection
lctl_verb=$([[ "$ENABLE" -eq 1 ]] && echo enable || echo disable)

# Disable user agents (no sudo)
for entry in ${user_matches[@]+"${user_matches[@]}"} ${sys_agent_matches[@]+"${sys_agent_matches[@]}"}; do
    label="${entry%|*}"
    if launchctl "$lctl_verb" "gui/$UID/$label" 2>/dev/null; then
        log_pass "launchctl $lctl_verb gui/$UID/$label"
    else
        log_warn "launchctl $lctl_verb gui/$UID/$label" "may already be in target state"
    fi
done

# Disable system daemons (sudo)
if [[ ${#sys_daemon_matches[@]} -gt 0 ]]; then
    note "  System daemons require sudo:"
    for entry in "${sys_daemon_matches[@]}"; do
        label="${entry%|*}"
        if sudo launchctl "$lctl_verb" "system/$label" 2>/dev/null; then
            log_pass "sudo launchctl $lctl_verb system/$label"
        else
            log_warn "sudo launchctl $lctl_verb system/$label" "may need sudo or already in state"
        fi
    done
fi

# Login Items (via osascript)
for name in ${login_item_matches[@]+"${login_item_matches[@]}"}; do
    if [[ "$ENABLE" -eq 1 ]]; then
        log_warn "Login Item '$name'" "re-enable requires manual re-add (System Settings → Login Items)"
    else
        if osascript -e "tell application \"System Events\" to delete login item \"$name\"" 2>/dev/null; then
            log_pass "Removed Login Item" "$name"
        else
            log_warn "Login Item '$name'" "removal failed (TCC may be blocking System Events)"
        fi
    fi
done

emit_summary
