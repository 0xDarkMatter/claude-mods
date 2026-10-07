#!/usr/bin/env bash
# mac-ops :: media-libraries.sh
# Audit Photos, Music, TV, and other media libraries: sizes, locations,
# integrity status, and the sync daemons that manage them.

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
  1. Photos library locations + size
  2. Music / TV library
  3. Pro app libraries (Final Cut, Logic, iMovie)
  4. iCloud Drive / Mobile Documents size
  5. Photos / Music sync daemons (photolibraryd, cloudphotod, photoanalysisd,
     amsondemandinstalld, cloudd, bird) — CPU + memory
  6. Suspended sync state (frequent silent cause of "Photos won't sync")

These libraries can be 10s-100s of GB and show as "Other" in About This Mac.
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
section "1. PHOTOS LIBRARIES"
# ----------------------------------------------------------------------------
# Default location:
default_photos="$HOME/Pictures/Photos Library.photoslibrary"
# Find any .photoslibrary anywhere reasonable
photo_libs=$(find "$HOME/Pictures" /Users/Shared "$HOME/Documents" -maxdepth 2 -name "*.photoslibrary" -type d 2>/dev/null | head -5)
# Also check external volumes if mounted
ext_photo_libs=$(find /Volumes -maxdepth 3 -name "*.photoslibrary" -type d 2>/dev/null | head -5)
photo_libs="$photo_libs"$'\n'"$ext_photo_libs"
photo_libs=$(echo "$photo_libs" | grep -v '^$')

if [[ -z "$photo_libs" ]]; then
    log_info "Photos libraries" "none found"
else
    n=$(echo "$photo_libs" | wc -l | tr -d ' ')
    log_info "Photos libraries" "$n found"
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        size=$(du -sh "$lib" 2>/dev/null | awk '{print $1}')
        printf "    %s  =  %s\n" "$lib" "${size:-?}"
    done <<< "$photo_libs"
fi

# Current Photos system library
sys_photos=$(defaults read com.apple.Photos UserLibrarySelectionMethod 2>/dev/null || echo "")
if [[ -n "$sys_photos" ]]; then
    note ""
    note "  System Photos library: per Photos.app preferences"
fi

# ----------------------------------------------------------------------------
section "2. MUSIC / TV LIBRARIES"
# ----------------------------------------------------------------------------
music_lib="$HOME/Music/Music"
if [[ -d "$music_lib" ]]; then
    size=$(du -sh "$music_lib" 2>/dev/null | awk '{print $1}')
    log_info "Music library" "${size:-?} ($music_lib)"
fi

# .musiclibrary
musiclibs=$(find "$HOME/Music" -maxdepth 2 -name "*.musiclibrary" -type d 2>/dev/null | head -3)
if [[ -n "$musiclibs" ]]; then
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        size=$(du -sh "$lib" 2>/dev/null | awk '{print $1}')
        note "    $lib = ${size:-?}"
    done <<< "$musiclibs"
fi

# TV
tv_dir="$HOME/Movies/TV"
if [[ -d "$tv_dir" ]]; then
    size=$(du -sh "$tv_dir" 2>/dev/null | awk '{print $1}')
    log_info "TV library" "${size:-?} ($tv_dir)"
fi

# ----------------------------------------------------------------------------
section "3. PRO APP LIBRARIES"
# ----------------------------------------------------------------------------
note "  Scanning for FCP / Logic / iMovie libraries..."
pro_libs=$(find "$HOME/Movies" "$HOME/Documents" "$HOME/Logic" /Volumes -maxdepth 3 \
    \( -name "*.fcpbundle" -o -name "*.logicx" -o -name "*.imovielibrary" -o -name "*.band" \) -type d 2>/dev/null | head -10)
if [[ -z "$pro_libs" ]]; then
    log_info "Pro app libraries" "none found in standard locations"
else
    n=$(echo "$pro_libs" | wc -l | tr -d ' ')
    log_info "Pro app libraries" "$n found"
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        size=$(du -sh "$lib" 2>/dev/null | awk '{print $1}')
        printf "    %s = %s\n" "$lib" "${size:-?}"
    done <<< "$pro_libs"
fi

# ----------------------------------------------------------------------------
section "4. iCLOUD DRIVE / MOBILE DOCUMENTS"
# ----------------------------------------------------------------------------
icloud="$HOME/Library/Mobile Documents"
if [[ -d "$icloud" ]]; then
    size=$(du -sh "$icloud" 2>/dev/null | awk '{print $1}')
    log_info "iCloud Drive cache" "${size:-?}"
    note "  (Subset is downloaded; rest is placeholders. macOS evicts under pressure.)"
fi

# Top iCloud Drive consumers
note ""
note "  Top consumers under iCloud Drive (du -sh, may be slow):"
find "$icloud" -maxdepth 2 -type d 2>/dev/null | head -10 | while read -r d; do
    [[ "$d" == "$icloud" ]] && continue
    size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    printf "    %s = %s\n" "$d" "${size:-?}"
done | sort -k3 -h -r | head -5

# ----------------------------------------------------------------------------
section "5. SYNC DAEMONS — CPU SNAPSHOT"
# ----------------------------------------------------------------------------
note "  Process CPU%:"
for proc in photolibraryd cloudphotod photoanalysisd amsondemandinstalld cloudd bird fileproviderd; do
    cpu=$(ps -ArcS -o pcpu,comm 2>/dev/null | awk -v p="$proc" '$2==p{print $1; exit}')
    cpu="${cpu:-0}"
    cpu_int=${cpu%.*}
    if [[ "${cpu_int:-0}" -gt 50 ]]; then
        log_warn "$proc" "${cpu}% — sustained sync activity"
    elif [[ "${cpu_int:-0}" -gt 0 ]]; then
        log_info "$proc" "${cpu}%"
    fi
done

# ----------------------------------------------------------------------------
section "6. SYNC HEALTH"
# ----------------------------------------------------------------------------
# Check for suspended sync / iCloud sign-out / etc.
icloud_status=$(brctl status 2>/dev/null || true)
if [[ -n "$icloud_status" ]] && echo "$icloud_status" | grep -q "iCloud Drive Disabled"; then
    log_warn "iCloud Drive" "disabled"
fi

# Photos cloud status
note ""
note "  Recent photolibraryd / cloudphotod errors (24h):"
photo_errs=$(log show --last 24h --style compact \
    --predicate 'process == "photolibraryd" OR process == "cloudphotod"' \
    2>/dev/null | grep -iE "(error|fail|fault)" | tail -5)
if [[ -n "$photo_errs" ]]; then
    echo "$photo_errs" | sed 's/^/    /'
else
    note "    (none)"
fi

# ----------------------------------------------------------------------------
emit_summary
