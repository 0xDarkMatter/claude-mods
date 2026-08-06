#!/usr/bin/env bash
# fleet-ops/sessions.sh — resolve which Claude session owns which lane.
#
# WHY THIS READS DISK AND NOT THE MCP TOOLS: the `ccd_session_mgmt` tools
# (list_sessions/send_message/...) exist ONLY inside Claude Desktop. They are
# absent from the terminal CLI binary entirely — verified 2026-08-03: the CLI
# contains zero occurrences of `ccd_session_mgmt`, `list_sessions`, or
# `spawn_task`, and its single `ccd_session` reference is a consumer-side
# notification handler for a server the *host* injects. A script therefore
# cannot call them. The underlying wrapper STORE, however, is plain JSON on
# local disk and is readable from any shell on the machine — so this script
# gets the same facts a Desktop tool would, and works in a terminal too.
#
# INVARIANTS
#   - stdout is DATA ONLY (TSV, one row per branch). Notes go to stderr.
#   - Never fails a caller: an absent store, absent jq, or a non-Desktop
#     machine exits 3 with empty stdout. Callers treat non-zero as "no info"
#     and carry on — this is an ENRICHMENT layer, never a hard dependency.
#   - Paths are normalised to forward slashes so they survive @tsv (which
#     escapes backslashes) and compare cleanly against git's output.
#
# Exit: 0 ok · 2 usage · 3 unavailable (no store / no jq) — advisory, not error.
set -uo pipefail

SELF=$(basename "$0")

# Liveness threshold: a session touched within this many seconds counts as a
# live writer. Desktop refreshes lastActivityAt per turn, so a session that is
# open-but-thinking still reads live. 10 min matches summon's picker.
LIVE_SECS=${FLEET_SESSION_LIVE_SECS:-600}

usage() {
    cat <<EOF
$SELF — map fleet lane branches to the Claude sessions that own them

USAGE
  $SELF index                     All branch->session rows (TSV)
  $SELF owner [--fresh] <branch>  The one session owning <branch> (newest wins).
                                  --fresh re-reads that session's liveness
                                  directly, bypassing the cache — use it for
                                  any gate that must not act on stale data.
  $SELF main                      The MAIN/coordinator session for this repo
  $SELF live <sessionId>          1 if that session is live, else 0
  $SELF self                      The CALLING session's own store id, if it can
                                  be resolved and verified against the store.
                                  Exit 3 (silent) when it cannot.
  $SELF --help

OUTPUT (TSV columns)
  branch  sessionId  title  lastActivityMs  cwd  archived(0|1)  live(0|1)

ENVIRONMENT
  FLEET_SESSION_STORE       override the session-store directory
  FLEET_SESSION_LIVE_SECS   liveness window in seconds (default 600)
  FLEET_SESSION_CACHE_TTL   index cache lifetime in seconds (default 900).
                            Long by design — no gate reads cached liveness;
                            they all use `owner --fresh`.
  FLEET_SESSION_NOCACHE     set to any value to force a fresh scan

EXAMPLES
  # who owns this lane, and are they still writing?
  $SELF owner lane/projection-control

  # the coordinator session for this repo
  $SELF main

  # every lane branch with a live owner
  $SELF index | awk -F'\\t' '\$7==1 {print \$1, \$3}'

EXIT
  0 ok (zero rows is still ok)   2 usage   3 store or jq unavailable
EOF
}

# --- store discovery ---------------------------------------------------------
# Desktop keeps one wrapper JSON per session under
# <store>/<accountUuid>/<workspaceUuid>/local_<uuid>.json
store_dir() {
    if [[ -n "${FLEET_SESSION_STORE:-}" ]]; then
        # Must still exist — an override pointing nowhere is "unavailable" (3),
        # not a hard error, so callers degrade rather than break.
        [[ -d "$FLEET_SESSION_STORE" ]] || return 1
        printf '%s' "$FLEET_SESSION_STORE"; return
    fi
    local candidates=()
    # Windows: APPDATA is a native path in Git Bash; cygpath makes it POSIX.
    if [[ -n "${APPDATA:-}" ]]; then
        if command -v cygpath >/dev/null 2>&1; then
            candidates+=("$(cygpath -u "$APPDATA")/Claude/claude-code-sessions")
        else
            candidates+=("$APPDATA/Claude/claude-code-sessions")
        fi
    fi
    candidates+=(
        "$HOME/AppData/Roaming/Claude/claude-code-sessions"
        "$HOME/Library/Application Support/Claude/claude-code-sessions"
        "$HOME/.config/Claude/claude-code-sessions"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -d "$c" ]] && { printf '%s' "$c"; return; }
    done
    return 1
}

# Normalise a path for comparison: forward slashes, no trailing slash,
# lowercased (Windows paths are case-insensitive and Desktop's casing of the
# drive letter does not always match git's).
norm_path() {
    local p=${1:-}
    p=${p//\\//}
    p=${p%/}
    printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}

# --- index -------------------------------------------------------------------
# One row per (branch, session). A session contributes its checked-out `branch`
# AND every entry in `writtenBranches` — the latter is what actually matches a
# fleet lane, because a session working in worktree `claude/foo-bar` may commit
# its real work to `lane/thing`.
#
# CACHED, AND THE CACHE IS NOT OPTIONAL. A cold scan walks every wrapper in the
# store (~900 branch rows here) and takes tens of seconds on Windows. `fleet
# status` and the land gate call this repeatedly; uncached, five calls blew a
# 2-minute timeout during development. TTL is short because the only field that
# decays is liveness.
# TTL is long ON PURPOSE. Nothing that DECIDES anything reads a cached liveness
# value: `session_land_gate` and `prune_remove_safe` both call `owner --fresh`,
# which re-reads the single owning wrapper and bypasses this cache entirely.
# Cached rows feed display only (status annotations, `fleet main`, prune
# classification — and the SAFE bucket is re-verified fresh before deletion).
# A short TTL therefore bought no correctness and cost ~41s: a cold scan walks
# the whole store, so at TTL=30 nearly every `fleet status` paid for one
# (measured 2026-08-03: 47.1s cold vs 6.0s warm on an 11-worktree repo).
CACHE_TTL=${FLEET_SESSION_CACHE_TTL:-900}
cache_file() {
    local base="${TMPDIR:-/tmp}"
    printf '%s/fleet-sessions-%s.tsv' "${base%/}" "${UID:-$(id -u 2>/dev/null || echo 0)}"
}

build_index() {
    local cf; cf=$(cache_file)
    if [[ -z "${FLEET_SESSION_NOCACHE:-}" && -f "$cf" ]]; then
        local age=$(( $(date +%s) - $(file_mtime_s "$cf") ))
        if (( age >= 0 && age < CACHE_TTL )); then
            cat "$cf"; return 0
        fi
    fi
    local out
    out=$(scan_store) || return $?
    printf '%s\n' "$out" > "$cf" 2>/dev/null || true
    printf '%s\n' "$out"
}

# Portable mtime-in-seconds (GNU stat -c, BSD/macOS stat -f).
file_mtime_s() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

scan_store() {
    local sd
    sd=$(store_dir) || { echo "$SELF: no Claude session store on this machine" >&2; return 3; }
    command -v jq >/dev/null 2>&1 || { echo "$SELF: jq not found — session enrichment off" >&2; return 3; }

    local now_ms=$(( $(date +%s) * 1000 ))
    local live_ms=$(( LIVE_SECS * 1000 ))

    # Concatenated JSON objects are a valid jq input stream, so one cat + one jq
    # handles the whole store (hundreds of files) in two processes rather than
    # 2N. Piping also sidesteps the POSIX-vs-Windows path problem: a Windows jq
    # cannot open "/c/Users/..." but reads stdin fine.
    # Bounded by age: a lane older than the window is not a lane anyone is
    # about to land, and scanning the full historical store costs ~50s here vs
    # a few seconds for the recent slice. Unresolvable = "no info" = the gate
    # allows, so the window can only cost enrichment, never correctness.
    local age_days=${FLEET_SESSION_MAX_AGE_DAYS:-60}
    find "$sd" -name 'local_*.json' -type f -mtime "-${age_days}" -exec cat {} + 2>/dev/null | jq -r --argjson now "$now_ms" --argjson win "$live_ms" '
        (.sessionId // "")                             as $id
      | (.title // "")                                 as $t
      | ((.cwd // "") | gsub("\\\\"; "/"))             as $cwd
      | (.lastActivityAt // 0)                         as $la
      | (if .isArchived == true then 1 else 0 end)     as $arch
      | (if ($now - $la) <= $win then 1 else 0 end)    as $live
      | ([ (.branch // empty) ] + (.writtenBranches // []))
      | unique[]
      | select(type == "string" and . != "")
      | [ ., $id, $t, ($la|tostring), $cwd, ($arch|tostring), ($live|tostring) ]
      | @tsv
    ' 2>/dev/null
    # pipefail would surface find's exit on a vanished dir; the empty result is
    # the answer we want, so swallow it deliberately.
    return 0
}

# Authoritative liveness for ONE session, bypassing the cache.
# The cache trades staleness for speed, and stale-idle-but-actually-live is the
# one direction that would let the land gate through when it should refuse. So
# the gate re-reads just the owning wrapper — O(1), no store walk.
# Echoes "1" (live) or "0". Unknown session → "0".
session_live_now() {
    local id=$1 sd
    sd=$(store_dir) || { printf '0'; return; }
    command -v jq >/dev/null 2>&1 || { printf '0'; return; }
    local f
    f=$(find "$sd" -name "${id}.json" -type f 2>/dev/null | head -n1)
    [[ -n "$f" ]] || { printf '0'; return; }
    local la
    la=$(jq -r '.lastActivityAt // 0' <"$f" 2>/dev/null || echo 0)
    local now_ms=$(( $(date +%s) * 1000 ))
    if (( la > 0 && (now_ms - la) <= LIVE_SECS * 1000 )); then printf '1'; else printf '0'; fi
}

# --- self --------------------------------------------------------------------
# Which session is CALLING this script.
#
# WHY THIS EXISTS: the live-owner gate protects against landing a lane while a
# session is still committing to it. When the session running `fleet land` is
# itself that owner, the hazard is absent — it is blocked inside the land call
# and cannot be mid-commit — but the gate could not tell the two apart, so a
# lane session landing its own work always tripped it. Self-identity is what
# separates "a PEER is writing" (refuse) from "I am the writer" (proceed).
#
# DELIBERATELY NOT OVERRIDABLE. There is no FLEET_SELF_SESSION_ID or equivalent:
# a settable self-id would be a universal gate bypass wearing a different name
# (export it to the owner's id and every refusal disappears). The id comes from
# the harness, and is only believed once a wrapper file bearing it is found in
# the store — so an unset, stale, or invented value resolves to nothing and the
# gate keeps its full strength. Unresolvable self is the SAFE direction.
self_session_id() {
    local sd; sd=$(store_dir) || return 3
    # EVERY candidate is tried, not just the first one that is set. Inside
    # Desktop both CLAUDE_CODE_SESSION_ID and CLAUDE_CODE_HOST_SESSION_ID are
    # populated with DIFFERENT ids — the former is the CLI session, the latter
    # the host session the store is keyed by — so a first-set-wins chain
    # resolves nothing on exactly the surface this matters most on.
    local raw cand f
    for raw in "${CLAUDE_CODE_HOST_SESSION_ID:-}" "${CLAUDE_CODE_SESSION_ID:-}" \
               "${CLAUDE_SESSION_ID:-}"; do
        [[ -n "$raw" ]] || continue
        # The harness may hand us the bare uuid or the store's `local_<uuid>`
        # form; the filename is always the latter. Try as-given first so a
        # future id shape that isn't uuid-based still resolves.
        for cand in "$raw" "local_$raw"; do
            f=$(find "$sd" -name "${cand}.json" -type f 2>/dev/null | head -n1)
            [[ -n "$f" ]] || continue
            basename "$f" .json
            return 0
        done
    done
    return 3
}

# --- owner -------------------------------------------------------------------
# Newest activity wins; a non-archived session outranks an archived one, since a
# branch reused after its original session was archived belongs to the new one.
cmd_owner() {
    local fresh=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fresh) fresh=1; shift ;;
            -*) echo "$SELF: unknown flag '$1'" >&2; return 2 ;;
            *) break ;;
        esac
    done
    local branch=${1:-}
    [[ -z "$branch" ]] && { echo "usage: $SELF owner [--fresh] <branch>" >&2; return 2; }
    local idx
    idx=$(build_index) || return 3
    local row
    row=$(printf '%s\n' "$idx" \
      | awk -F'\t' -v want="$branch" '$1 == want' \
      | sort -t"$(printf '\t')" -k6,6n -k4,4nr \
      | head -n1)
    [[ -z "$row" ]] && return 0
    if (( fresh )); then
        # Overwrite the cached liveness column with a direct read.
        local id; id=$(printf '%s' "$row" | cut -f2)
        local now; now=$(session_live_now "$id")
        row=$(printf '%s' "$row" | awk -F'\t' -v OFS='\t' -v L="$now" '{$7=L; print}')
    fi
    printf '%s\n' "$row"
}

# --- main --------------------------------------------------------------------
# MAIN = the coordinator session for this repo. Resolution order:
#   1. explicit pin in .claude/fleet/main (a sessionId) — survives restarts and
#      lets a human override the heuristic
#   2. the session whose cwd IS the repo root (not a worktree under it), newest
#      first, non-archived. This is the natural definition: worktree-boundaries
#      doctrine already says the base checkout is the landing tree, so whoever
#      sits in it is the integrator.
cmd_main() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "$SELF: not in a git repo" >&2; return 2; }
    if command -v cygpath >/dev/null 2>&1; then
        root=$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")
    fi
    local want; want=$(norm_path "$root")

    local idx; idx=$(build_index) || return 3

    # 1. explicit pin
    local pin_file="$root/.claude/fleet/main" pinned=""
    [[ -f "$pin_file" ]] && pinned=$(grep -v '^[[:space:]]*#' "$pin_file" 2>/dev/null | tr -d '[:space:]' | head -n1)
    if [[ -n "$pinned" ]]; then
        local hit
        hit=$(printf '%s\n' "$idx" | awk -F'\t' -v id="$pinned" '$2 == id' | sort -t"$(printf '\t')" -k4,4nr | head -n1)
        if [[ -n "$hit" ]]; then printf '%s\n' "$hit"; return 0; fi
        echo "$SELF: pinned MAIN $pinned not found in session store (stale pin?)" >&2
    fi

    # 2. heuristic — cwd is exactly the repo root
    printf '%s\n' "$idx" \
      | awk -F'\t' -v want="$want" '
          { c=tolower($5); sub(/\/$/,"",c); if (c == want) print }
        ' \
      | sort -t"$(printf '\t')" -k6,6n -k4,4nr \
      | head -n1
}

case "${1:---help}" in
    -h|--help|help) usage; exit 0 ;;
    index)          build_index; exit $? ;;
    owner)          shift; cmd_owner "$@"; exit $? ;;
    main)           cmd_main; exit $? ;;
    live)           shift; [[ -z "${1:-}" ]] && { echo "usage: $SELF live <sessionId>" >&2; exit 2; }
                    session_live_now "$1"; echo; exit 0 ;;
    self)           self_session_id || exit 3; exit 0 ;;
    *)              echo "$SELF: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
