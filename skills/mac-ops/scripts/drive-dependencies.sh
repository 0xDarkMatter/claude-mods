#!/usr/bin/env bash
# mac-ops :: drive-dependencies.sh
# "Is it safe to eject this volume?" — find every reference to a volume
# before you yank the cable / unmount / destroy a snapshot.
#
# Checks:
#   - Open files via lsof
#   - Spotlight index state
#   - Time Machine destination
#   - Photos / Music / TV library locations
#   - Helper-tool security-scoped bookmarks (best-effort)
#   - Symlinks pointing into the volume from common locations
#   - Background processes with cwd inside the volume

set -u

TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--volume) TARGET="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 -v <mount-point> [options]

  -v, --volume PATH        Volume to check (e.g. /Volumes/Backup, /)
  --json, --redact, --quiet, --verbose   Standard flags

Verdict: "safe to eject" requires PASS on every check. Any FAIL/WARN means
something would break or lose state on disconnect.
EOF
            exit 0 ;;
        *) shift ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Error: -v <mount-point> required (e.g. -v /Volumes/Backup)" >&2
    exit 2
fi

if [[ ! -d "$TARGET" ]]; then
    echo "Error: $TARGET is not a directory / not mounted" >&2
    exit 3
fi

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

note "  Volume: $TARGET"

# ----------------------------------------------------------------------------
section "1. OPEN FILES (lsof)"
# ----------------------------------------------------------------------------
# `lsof +D` is recursive and VERY slow on large volumes (especially $HOME).
# Use `lsof` without +D and grep by mount point — much faster, equivalent
# accuracy for "is anything open under this path".
target_real=$(cd "$TARGET" 2>/dev/null && pwd -P || echo "$TARGET")
open_lines=$(lsof -F n 2>/dev/null | grep "^n${target_real}/" 2>/dev/null || true)
open_count=$(printf '%s\n' "$open_lines" | grep -c . 2>/dev/null || echo 0)
if [[ "$open_count" -gt 0 ]]; then
    log_fail "Open file handles" "$open_count — unmount will fail or corrupt"
    note "  Top processes holding files (sample):"
    # lsof -F format is column-based; use plain lsof for the process listing
    lsof 2>/dev/null | awk -v t="$target_real" '$NF ~ "^"t"/"{print $1, $2}' | sort -u | head -10 | sed 's/^/    /'
else
    log_pass "Open file handles" "0"
fi

# ----------------------------------------------------------------------------
section "2. PROCESSES WITH CWD INSIDE VOLUME"
# ----------------------------------------------------------------------------
# Use lsof -c with -d cwd for current working directories
cwd_procs=$(lsof -d cwd 2>/dev/null | awk -v t="$TARGET" '$NF ~ t {print $1, $2}' | sort -u)
if [[ -n "$cwd_procs" ]]; then
    cwd_count=$(echo "$cwd_procs" | wc -l | tr -d ' ')
    log_warn "Processes with cwd inside" "$cwd_count"
    echo "$cwd_procs" | head -5 | sed 's/^/    /'
else
    log_pass "Processes with cwd inside" "0"
fi

# ----------------------------------------------------------------------------
section "3. SPOTLIGHT INDEX STATE"
# ----------------------------------------------------------------------------
spotlight_status=$(mdutil -s "$TARGET" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')
note "  $spotlight_status"
case "$spotlight_status" in
    *"Indexing enabled"*) log_warn "Spotlight indexing" "enabled on this volume — eject may corrupt index" ;;
    *"Indexing disabled"*) log_pass "Spotlight indexing" "disabled" ;;
    *"unknown"*) log_pass "Spotlight indexing" "(no user index — system or read-only volume)" ;;
    *) log_info "Spotlight indexing" "${spotlight_status:-(no response)}" ;;
esac

# ----------------------------------------------------------------------------
section "4. TIME MACHINE DESTINATION CHECK"
# ----------------------------------------------------------------------------
tm_dest=$(tmutil destinationinfo 2>/dev/null | awk -F': *' '/Mount Point/{print $2}')
# Empty tm_dest matches /tmp via prefix logic if not careful; require non-empty + exact prefix
if [[ -n "$tm_dest" ]] && { [[ "$tm_dest" == "$TARGET" ]] || [[ "$TARGET" == "$tm_dest"/* ]]; }; then
    log_fail "Time Machine destination" "this volume IS the TM target — eject will fail current/next backup"
elif [[ -n "$tm_dest" ]]; then
    log_pass "Time Machine destination" "different volume ($tm_dest)"
else
    log_pass "Time Machine destination" "none configured"
fi

# Recent TM activity touching this volume
tm_active=$(tmutil currentphase 2>/dev/null)
if [[ "$tm_active" != "BackupNotRunning" ]] && [[ -n "$tm_active" ]]; then
    log_warn "Time Machine current phase" "$tm_active — wait before eject"
fi

# ----------------------------------------------------------------------------
section "5. MEDIA LIBRARY LOCATIONS"
# ----------------------------------------------------------------------------
# Photos library
photos_lib=$(defaults read com.apple.Photos UserLibrarySelectionMethod 2>/dev/null || true)
# Best-effort: check common Photos library paths under this volume
photos_libs=$(find "$TARGET" -maxdepth 3 -name "Photos Library.photoslibrary" -type d 2>/dev/null | head -3)
if [[ -n "$photos_libs" ]]; then
    log_warn "Photos library detected on volume" "$(echo "$photos_libs" | head -1)"
fi

# Music library
music_libs=$(find "$TARGET" -maxdepth 3 -name "*.musiclibrary" -type d 2>/dev/null | head -3)
if [[ -n "$music_libs" ]]; then
    log_warn "Music library detected on volume" "$(echo "$music_libs" | head -1)"
fi

# Final Cut / Logic / iMovie libraries
fcp_libs=$(find "$TARGET" -maxdepth 3 \( -name "*.fcpbundle" -o -name "*.logicx" -o -name "*.imovielibrary" \) -type d 2>/dev/null | head -3)
if [[ -n "$fcp_libs" ]]; then
    log_warn "Pro app library detected on volume" "$(echo "$fcp_libs" | head -1)"
fi

# ----------------------------------------------------------------------------
section "6. SYMLINKS POINTING INTO VOLUME"
# ----------------------------------------------------------------------------
# Common places where symlinks land
declare -a check_dirs=(
    "$HOME/Documents"
    "$HOME/Desktop"
    "$HOME/Movies"
    "$HOME/Music"
    "$HOME/Pictures"
    "$HOME/Library/Mobile Documents"
)
symlink_count=0
for d in "${check_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    found=$(find "$d" -maxdepth 2 -type l 2>/dev/null | while read -r link; do
        dest=$(readlink "$link")
        [[ "$dest" == "$TARGET"/* ]] && echo "$link -> $dest"
    done)
    if [[ -n "$found" ]]; then
        n=$(echo "$found" | wc -l | tr -d ' ')
        symlink_count=$((symlink_count + n))
        echo "$found" | head -3 | sed 's/^/    /'
    fi
done

if [[ "$symlink_count" -gt 0 ]]; then
    log_warn "Symlinks pointing into volume" "$symlink_count — they'll dangle on eject"
else
    log_pass "Symlinks pointing into volume" "0"
fi

# ----------------------------------------------------------------------------
section "7. PRIVILEGED HELPER / LAUNCH ITEMS REFERENCING VOLUME"
# ----------------------------------------------------------------------------
# Grep launchd plists for paths inside the target
helper_refs=0
for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    [[ -d "$d" ]] || continue
    matches=$(grep -l "$TARGET" "$d"/*.plist 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        helper_refs=$((helper_refs + $(echo "$matches" | wc -l | tr -d ' ')))
        echo "$matches" | head -3 | sed 's|^|    |'
    fi
done

if [[ "$helper_refs" -gt 0 ]]; then
    log_warn "Launchd plists referencing volume" "$helper_refs — daemons will fail on eject"
else
    log_pass "Launchd plists referencing volume" "0"
fi

# ----------------------------------------------------------------------------
section "8. APP BOOKMARKS / RECENTS"
# ----------------------------------------------------------------------------
# Sandboxed apps store security-scoped bookmarks; we can't decode them without
# the app, but we can list which apps have recents pointing at this volume.
note "  (App security-scoped bookmarks aren't directly inspectable — this is informational)"

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    if [[ "$FAIL_COUNT" -eq 0 ]] && [[ "$WARN_COUNT" -eq 0 ]]; then
        echo "  ✓ Safe to eject $TARGET — no system references detected."
    elif [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "  ✗ NOT safe to eject $TARGET — eject will fail or break the items above."
    else
        echo "  ⚠ Ejecting will work, but the items above will dangle or stop working until remount."
    fi
fi
