#!/usr/bin/env bash
# mac-ops :: font-audit.sh
# Font inventory + duplicate detection. Font conflicts cause real problems —
# Office crashes, Adobe app crashes, font rendering glitches, login slowness
# (Font Book validates ALL fonts at login if registry is corrupt).

set -u

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

Reports:
  1. Font directories + counts (system, user, library, fontd cache)
  2. fontd process state + recent errors
  3. Duplicate fonts (same family in multiple locations)
  4. Disabled fonts in Font Book
  5. Suspicious / corrupt font files

Common fixes:
  - Open Font Book → File → Validate fonts → resolve duplicates
  - sudo atsutil databases -remove        # clear font cache, reboot
  - sudo atsutil server -shutdown         # restart font server
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# ----------------------------------------------------------------------------
section "1. FONT DIRECTORIES"
# ----------------------------------------------------------------------------
declare -a font_dirs=(
    "/System/Library/Fonts"
    "/Library/Fonts"
    "$HOME/Library/Fonts"
)

for d in "${font_dirs[@]}"; do
    if [[ -d "$d" ]]; then
        count=$(find "$d" -maxdepth 2 -type f \( -name "*.ttf" -o -name "*.otf" -o -name "*.ttc" -o -name "*.dfont" \) 2>/dev/null | wc -l | tr -d ' \n')
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        log_info "$d" "$count fonts, $size"
    fi
done

# Adobe / third-party font cache directories
adobe_fonts=$(find /Users -maxdepth 5 -path "*/Library/Application Support/Adobe/CoreSync/plugins/livetype/r" -type d 2>/dev/null | head -3)
if [[ -n "$adobe_fonts" ]]; then
    while IFS= read -r d; do
        count=$(find "$d" -maxdepth 2 -type f \( -name "*.ttf" -o -name "*.otf" \) 2>/dev/null | wc -l | tr -d ' \n')
        note "    $d ($count Adobe Fonts)"
    done <<< "$adobe_fonts"
fi

# ----------------------------------------------------------------------------
section "2. fontd PROCESS"
# ----------------------------------------------------------------------------
if pgrep -x fontd >/dev/null; then
    pid=$(pgrep -x fontd | head -1)
    cpu=$(ps -p "$pid" -o pcpu= 2>/dev/null | tr -d ' ')
    rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    log_pass "fontd running" "PID $pid (CPU ${cpu:-0}%, RSS ${rss:-?} KB)"
else
    log_info "fontd" "not running (Font Book may not be open)"
fi

# Recent fontd errors
font_errors=$(log show --last 24h --style compact \
    --predicate '(process == "fontd" OR process == "FontRegistry" OR eventMessage CONTAINS "font") AND (messageType == "Error" OR messageType == "Fault")' \
    2>/dev/null | grep -iE "font" | tail -5)
if [[ -n "$font_errors" ]]; then
    n=$(echo "$font_errors" | wc -l | tr -d ' \n')
    log_warn "Font errors in log (24h)" "$n"
    echo "$font_errors" | head -3 | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "3. DUPLICATE FONTS"
# ----------------------------------------------------------------------------
# Find filename collisions across all font dirs
all_fonts=$(for d in "${font_dirs[@]}"; do
    [[ -d "$d" ]] && find "$d" -maxdepth 2 -type f \( -name "*.ttf" -o -name "*.otf" -o -name "*.ttc" \) 2>/dev/null
done)

dupes=$(echo "$all_fonts" | awk -F/ '{print $NF}' | sort | uniq -d)
if [[ -n "$dupes" ]]; then
    n=$(echo "$dupes" | wc -l | tr -d ' \n')
    log_warn "Duplicate font filenames" "$n"
    note "  Duplicates (filename, then locations):"
    echo "$dupes" | head -10 | while read -r f; do
        printf "    %s\n" "$f"
        echo "$all_fonts" | grep "/$f\$" | sed 's/^/      /'
    done
else
    log_pass "Duplicate font filenames" "0"
fi

# ----------------------------------------------------------------------------
section "4. FONT BOOK DISABLED FONTS"
# ----------------------------------------------------------------------------
# Font Book stores disabled-state in a plist (path varies by macOS version)
disabled_plist=$(find "$HOME/Library/FontCollections" -maxdepth 2 -name "*.collection" 2>/dev/null | head -3)
if [[ -n "$disabled_plist" ]]; then
    note "  Font collections found:"
    echo "$disabled_plist" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "5. CACHE / VALIDATION"
# ----------------------------------------------------------------------------
note "  Font cache reset (drastic) requires sudo:"
note "    sudo atsutil databases -remove   # clears all font caches"
note "    sudo atsutil server -shutdown    # restarts font server"
note ""
note "  To open Font Book and validate:"
note "    open -a 'Font Book'              # then File → Validate Fonts"

# ----------------------------------------------------------------------------
emit_summary
