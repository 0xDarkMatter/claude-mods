#!/usr/bin/env bash
# mac-ops :: recover-clone.sh
# Safely image data off a failing drive using rsync with no retries.
#
# Cardinal rules (enforced):
#   1. NEVER write to the source. Read-only operations only.
#   2. NEVER use -y or --force on fsck against a failing drive.
#   3. Default mode is DRY RUN — show what would be copied.
#
# Strategies (in order of safety):
#   --strategy=rsync     Default. Resumable, skips errors, partial files OK.
#   --strategy=ditto     macOS native. Preserves resource forks & xattrs.
#   --strategy=ddrescue  Bit-level. Requires brew install gddrescue.

set -u

SOURCE=""
DEST=""
STRATEGY="rsync"
APPLY=0
EXCLUDES=()

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source) SOURCE="$2"; shift 2 ;;
        -d|--destination) DEST="$2"; shift 2 ;;
        --strategy) STRATEGY="$2"; shift 2 ;;
        --exclude) EXCLUDES+=("$2"); shift 2 ;;
        --apply) APPLY=1; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 -s <source> -d <destination> [options]

  -s, --source PATH        Source path (file or directory on failing drive)
  -d, --destination PATH   Destination path (healthy drive)
  --strategy NAME          rsync (default) | ditto | ddrescue
  --exclude PATTERN        Add exclusion (can repeat)
  --apply                  Actually perform the clone (default: dry-run)
  --json, --redact, --quiet, --verbose

Examples:
  $0 -s /Volumes/Failing/work -d /Volumes/Rescue/work
  $0 -s ~/Documents -d /Volumes/Backup/Documents --apply
  $0 -s /Volumes/Failing -d /Volumes/Rescue --strategy=ditto --apply

Strategy reference:
  rsync     Best general-purpose. --partial --inplace --no-whole-file
            --append-verify. Skips errors, resumable.
  ditto     macOS-native. Preserves metadata, xattrs, ACLs, resource forks.
            Use when source has Pro app libraries (Final Cut etc).
  ddrescue  For drives with many bad sectors. Bit-level, resumable via map
            file. Requires: brew install gddrescue.
EOF
            exit 0 ;;
        *) shift ;;
    esac
done
# Without this restore every standard flag was silently ignored (--redact
# output meant for sharing went out unredacted). ${a[@]+...} is the bash
# 3.2-safe expansion of a possibly empty array under set -u.
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

if [[ -z "$SOURCE" ]] || [[ -z "$DEST" ]]; then
    echo "Error: -s and -d required" >&2
    exit 2
fi

if [[ ! -e "$SOURCE" ]]; then
    echo "Error: source does not exist: $SOURCE" >&2
    exit 3
fi

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

note "  Source:      $SOURCE"
note "  Destination: $DEST"
note "  Strategy:    $STRATEGY"
note "  Mode:        $([[ "$APPLY" -eq 1 ]] && echo APPLY || echo DRY-RUN)"

# ----------------------------------------------------------------------------
section "1. PREFLIGHT"
# ----------------------------------------------------------------------------
# Source size (read-only)
src_size=$(du -sh "$SOURCE" 2>/dev/null | awk '{print $1}')
log_info "Source size (du)" "${src_size:-?}"

# Destination free space
dest_parent=$(dirname "$DEST")
[[ -d "$dest_parent" ]] || { log_fail "Destination parent dir" "$dest_parent does not exist"; exit 3; }
dest_free=$(df -h "$dest_parent" | awk 'NR==2{print $4}')
log_info "Destination free space" "$dest_free"

# Sanity: source and dest on different volumes?
src_vol=$(df "$SOURCE" 2>/dev/null | awk 'NR==2{print $1}')
dest_vol=$(df "$dest_parent" 2>/dev/null | awk 'NR==2{print $1}')
if [[ "$src_vol" == "$dest_vol" ]]; then
    log_warn "Source/dest volume" "same volume — defeats purpose of cloning off failing drive"
else
    log_pass "Source/dest volume" "different volumes"
fi

# Strategy availability check
case "$STRATEGY" in
    rsync)
        command -v rsync >/dev/null || { log_fail "rsync" "not installed"; exit 5; }
        log_pass "rsync available" "$(rsync --version | head -1)"
        ;;
    ditto)
        command -v ditto >/dev/null || { log_fail "ditto" "not installed (built-in on macOS — shouldn't happen)"; exit 5; }
        log_pass "ditto available"
        ;;
    ddrescue)
        if ! command -v ddrescue >/dev/null; then
            log_fail "ddrescue" "not installed — run: brew install gddrescue"
            exit 5
        fi
        log_pass "ddrescue available"
        ;;
    *)
        log_fail "Strategy" "unknown: $STRATEGY"; exit 2 ;;
esac

# ----------------------------------------------------------------------------
section "2. BUILD COMMAND"
# ----------------------------------------------------------------------------
case "$STRATEGY" in
    rsync)
        cmd=(rsync -avh
             --partial --inplace --no-whole-file --append-verify
             --no-perms --no-owner --no-group
             --human-readable --info=progress2,stats2
             --ignore-errors)
        for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do cmd+=("--exclude=$e"); done
        cmd+=("$SOURCE/" "$DEST/")
        ;;
    ditto)
        cmd=(ditto --rsrc --extattr "$SOURCE" "$DEST")
        ;;
    ddrescue)
        # ddrescue needs a map file for resumability
        mapfile="${DEST}.ddrescue.map"
        cmd=(ddrescue -n --idirect "$SOURCE" "$DEST" "$mapfile")
        note "  ddrescue map file: $mapfile"
        ;;
esac

note "  Command:"
note "    ${cmd[*]}"

# ----------------------------------------------------------------------------
section "3. EXECUTE"
# ----------------------------------------------------------------------------
if [[ "$APPLY" -eq 0 ]]; then
    note "  (dry-run — pass --apply to actually clone)"
    if [[ "$STRATEGY" == "rsync" ]]; then
        # rsync has its own --dry-run that previews actions
        rsync --dry-run -ah "$SOURCE/" "$DEST/" 2>&1 | tail -10 | sed 's/^/    /'
    fi
    emit_summary
    exit 0
fi

# Apply mode
mkdir -p "$DEST" || { log_fail "mkdir $DEST" "failed"; exit 1; }
log_info "Starting clone" "$STRATEGY"
"${cmd[@]}"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    log_pass "Clone finished" "exit 0"
elif [[ "$rc" -le 24 ]] && [[ "$STRATEGY" == "rsync" ]]; then
    # rsync 23-24 = partial transfer (some files failed); acceptable for failing drive
    log_warn "Clone finished with rsync exit $rc" "some files unreadable — expected on failing drive"
else
    log_fail "Clone exit code" "$rc"
fi

emit_summary
