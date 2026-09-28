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
# THERE IS MORE THAN ONE STORE. Desktop keeps claude-code-sessions/ inside its
# Electron userData dir, and a machine can run several Desktop instances side
# by side, each with its own --user-data-dir (the ~/.claude-desktop-profiles/
# <name> launcher convention) and therefore its own store. This script used to
# take the FIRST store it found. On 2026-09-28 that was %APPDATA%\Claude —
# readable, 1,725 wrappers, and wrong: the sessions actually running lived in a
# profile store it never opened, so `fleet prune` read "nobody owns this" and
# classified the cwd of two RUNNING sessions SAFE. A readable store is not THE
# store, so every lookup now reads the union of all stores it can find.
#
# WHY TRANSCRIPTS TOO. A wrapper's lastActivityAt is rewritten at turn
# boundaries, not during a turn: a session 20 minutes into one autonomous turn
# still shows the timestamp it started with, so wrapper-only liveness calls a
# running session idle. The CLI transcript
#   <config>/projects/<encoded-cwd>/<cliSessionId>.jsonl
# is appended on every message, so its mtime is the live signal — and its
# DIRECTORY says where the session is working now. EnterWorktree re-roots the
# transcript; the wrapper's cwd never changes, so a session created in worktree
# A that moved into lane B still claims only A in its wrapper (measured
# 2026-09-28: 27 entries in the spawn worktree, 258 in the lane it moved to).
#
# SECTION MAP (grep the `# --- name ---` banners to jump):
#   paths       norm_path / path_key — the two forms paths are compared in
#   discovery   which session stores and transcript roots exist (fork-free)
#   scan        one pass over both -> wide rows; the cache; index/paths views
#   liveness    live_many — the fresh read every gate decision rests on
#   self        which session is calling (the land gate's self-exemption)
#   owner       branch -> newest owning session
#   main        the repo's coordinator session
#   at          directory -> claims; --fresh is the land gate's read
#
# INVARIANTS
#   - stdout is DATA ONLY (TSV). Notes go to stderr.
#   - Never fails a caller: an absent store, absent jq, or a non-Desktop
#     machine exits 3 with empty stdout. Callers treat non-zero as "no info"
#     and carry on — this is an ENRICHMENT layer, never a hard dependency.
#   - Paths are normalised to forward slashes so they survive @tsv (which
#     escapes backslashes) and compare cleanly against git's output.
#   - Attribution only ever ADDS claims. Nothing here can turn "someone owns
#     this" into "nobody does" — prune's SAFE bucket depends on that direction.
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
  $SELF paths                     All path->session claims (TSV, see below)
  $SELF views                     index + paths from one scan, tagged I / P
  $SELF at [--fresh] <path>       The claims on one directory (a worktree).
                                  --fresh re-reads every claimant's liveness
                                  and adds sessions whose transcript is being
                                  written in <path> right now, which the cache
                                  cannot know yet — the land gate's read.
  $SELF live <sessionId>          1 if that session is live, else 0
  $SELF self                      The CALLING session's own store id, if it can
                                  be resolved and verified against the store.
                                  Exit 3 (silent) when it cannot.
  $SELF stores                    The session stores and transcript roots read
  $SELF --help

OUTPUT (TSV columns)
  index/owner/main:
    branch  sessionId  title  lastActivityMs  cwd  archived(0|1)  live(0|1)
  paths/at:
    key  path  sessionId  title  lastActivityMs  archived(0|1)  live(0|1)  via
    key   the path in Claude Code's project-dir encoding, lowercased
    path  the normalised path, or empty when only the encoded key is known
    via   cwd | worktree | transcript | live-cwd
  lastActivityMs is the newer of the wrapper's lastActivityAt and the
  transcript's mtime; live is computed from it.

ENVIRONMENT
  FLEET_SESSION_STORE       session-store dirs, ';'-separated. Replaces
                            discovery entirely (the test suite uses this).
  FLEET_TRANSCRIPT_ROOTS    transcript roots (<config>/projects), ';'-separated.
                            Set-but-empty turns the transcript signal off.
  FLEET_SESSION_LIVE_SECS   liveness window in seconds (default 600)
  FLEET_SESSION_CACHE_TTL   index cache lifetime in seconds (default 900).
                            Long by design — no gate reads cached liveness;
                            they use \`owner --fresh\`, \`at --fresh\`, or a
                            fresh re-scan.
  FLEET_SESSION_NOCACHE     set to any value to force a fresh scan

EXAMPLES
  # who owns this lane, and are they still writing?
  $SELF owner lane/projection-control

  # the coordinator session for this repo
  $SELF main

  # every lane branch with a live owner
  $SELF index | awk -F'\\t' '\$7==1 {print \$1, \$3}'

  # which sessions claim this worktree, by any route?
  $SELF at 'X:\\repo\\.claude\\worktrees\\lane-a'

EXIT
  0 ok (zero rows is still ok)   2 usage   3 store or jq unavailable
EOF
}

# --- paths -------------------------------------------------------------------
# Normalise a path for comparison: forward slashes, no trailing slash,
# lowercased (Windows paths are case-insensitive and Desktop's casing of the
# drive letter does not always match git's). A Git Bash path (/d/code/...) and
# git's own (D:/code/...) name the same directory, so POSIX-rooted input is put
# in git's mixed form first — otherwise the two never compare equal.
norm_path() {
    local p=${1:-}
    if [[ "$p" == /* ]] && command -v cygpath >/dev/null 2>&1; then
        p=$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")
    fi
    p=${p//\\//}
    p=${p%/}
    printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}

# Claude Code's project-dir encoding: every character outside [A-Za-z0-9]
# becomes '-' (D:\Code\App\.claude -> D--Code-App--claude), which is
# how a transcript's DIRECTORY names the cwd it belongs to. Lowercased for the
# same reason as norm_path. LC_ALL=C so a non-ASCII byte maps to one '-'
# deterministically; Node replaces per UTF-16 unit, so a non-ASCII path may
# encode differently there. That can only LOSE a claim, never invent one — and
# fleet.sh prune never lets a missing claim make a .claude/worktrees/ tree SAFE.
# Keep in sync with enc() in project_paths below and path_key() in fleet.sh.
path_key() {
    printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

# --- discovery ---------------------------------------------------------------
# FORK-FREE ON PURPOSE. Everything here fills arrays in-process rather than
# printing into $(...) or < <(...): each of those forks, an MSYS fork costs
# 20-40ms on a busy Windows box, and this runs on every call (the cache key is
# built from it). The first multi-store version forked ~10 times per call and
# made every `fleet status` ~0.5s slower. Call load_dirs, then read STORES and
# TROOTS; the helpers return through _SPLIT / _DIRS for the same reason.

# Split a ';'-separated override into _SPLIT. ';' and not ':' because a Windows
# path carries a drive-letter colon, and Windows' own PATH uses ';'. `read -a`
# rather than an unquoted for-loop, so a '*' in a path never globs.
_SPLIT=()
split_list() {
    local IFS=';' parts=() p
    _SPLIT=()
    read -r -a parts <<< "${1:-}"
    for p in ${parts[@]+"${parts[@]}"}; do
        [[ -n "${p//[[:space:]]/}" ]] && _SPLIT+=("$p")
    done
    return 0
}

# The arguments that are existing directories, once each, into _DIRS. Dedupe
# is by exact string (trailing slash aside): every candidate derives from the
# same $HOME / $APPDATA strings, and a pair that slipped through would only be
# scanned twice — duplicate rows, same answer.
_DIRS=()
existing_dirs() {
    local d key seen=$'\n'
    _DIRS=()
    for d in "$@"; do
        [[ -d "$d" ]] || continue
        key=${d%/}
        case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
        seen+="$key"$'\n'
        _DIRS+=("$d")
    done
    return 0
}

# STORES — Desktop keeps one wrapper JSON per session under
#   <store>/<accountUuid>/<workspaceUuid>/local_<uuid>.json
# and there is one <store> PER DESKTOP INSTANCE (see the header). Every store
# that exists is read; none at all is "unavailable" (3) to callers.
# TROOTS — <config>/projects for each Claude Code config dir a session could be
# writing to. Desktop sessions write to ~/.claude/projects even when the
# Desktop INSTANCE runs from a profile dir (verified 2026-09-28), so that root
# is always included; $CLAUDE_CONFIG_DIR and roost-style ~/.claude-profiles/
# <name> cover headless and fleet-worker sessions. No roots just means no
# transcript signal.
STORES=(); TROOTS=(); DIRS_LOADED=0
load_dirs() {
    (( DIRS_LOADED )) && return 0
    DIRS_LOADED=1
    local list=() c cfg
    if [[ -n "${FLEET_SESSION_STORE:-}" ]]; then
        # An override pointing nowhere is "unavailable", not a hard error, so
        # callers degrade rather than break.
        split_list "$FLEET_SESSION_STORE"; list=(${_SPLIT[@]+"${_SPLIT[@]}"})
    else
        # Windows: %APPDATA% is normally $HOME/AppData/Roaming, which is listed
        # below anyway. Only a RELOCATED APPDATA needs cygpath (a fork), so
        # it is consulted only when the default location has no store.
        if [[ -n "${APPDATA:-}" && ! -d "$HOME/AppData/Roaming/Claude/claude-code-sessions" ]]; then
            if command -v cygpath >/dev/null 2>&1; then
                list+=("$(cygpath -u "$APPDATA")/Claude/claude-code-sessions")
            else
                list+=("$APPDATA/Claude/claude-code-sessions")
            fi
        fi
        list+=(
            "$HOME/AppData/Roaming/Claude/claude-code-sessions"
            "$HOME/Library/Application Support/Claude/claude-code-sessions"
            "$HOME/.config/Claude/claude-code-sessions"
        )
        # Every extra Desktop instance started with --user-data-dir under the
        # profiles dir. An unmatched glob stays literal and fails the -d test.
        for c in "$HOME"/.claude-desktop-profiles/*/claude-code-sessions; do list+=("$c"); done
    fi
    existing_dirs ${list[@]+"${list[@]}"}; STORES=(${_DIRS[@]+"${_DIRS[@]}"})

    list=()
    if [[ -n "${FLEET_TRANSCRIPT_ROOTS+x}" ]]; then
        split_list "$FLEET_TRANSCRIPT_ROOTS"; list=(${_SPLIT[@]+"${_SPLIT[@]}"})
    else
        cfg=${CLAUDE_CONFIG_DIR:-}
        if [[ -n "$cfg" ]]; then
            command -v cygpath >/dev/null 2>&1 && cfg=$(cygpath -u "$cfg" 2>/dev/null || printf '%s' "$cfg")
            list+=("$cfg/projects")
        fi
        list+=("$HOME/.claude/projects")
        for c in "$HOME"/.claude-profiles/*/projects; do list+=("$c"); done
    fi
    existing_dirs ${list[@]+"${list[@]}"}; TROOTS=(${_DIRS[@]+"${_DIRS[@]}"})
    return 0
}

# The wrapper file for session $1, from ANY store. Empty when not found.
find_wrapper() {
    load_dirs
    (( ${#STORES[@]} )) || return 0
    find "${STORES[@]}" -name "${1}.json" -type f 2>/dev/null | head -n1
}

# --- scan --------------------------------------------------------------------
# One pass over every store and transcript root yields WIDE rows, one per
# session; `index` (branch-keyed) and `paths` (directory-keyed) are both
# projections of them:
#   W  id  title  lastMs  cwd  worktreePath  archived  live  branches  txdir  livecwd
# branches  space-separated (git forbids spaces in ref names): the checked-out
#           `branch` AND every `writtenBranches` entry — the latter is what
#           matches a fleet lane, because a session in worktree `claude/foo`
#           may commit its real work to `lane/thing`.
# txdir     the transcript's encoded project dir, lowercased — where the
#           session is working NOW, which the wrapper's cwd does not track.
# livecwd   the last cwd the transcript recorded; read only while live.
# Transcripts with no wrapper in any store (CLI and headless sessions) are T
# rows, emitted only while live: with no archive flag, recency is the one
# thing they can prove.

# Portable mtime-in-seconds (GNU stat -c, BSD/macOS stat -f).
file_mtime_s() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# id  title  cwd  worktreePath  lastActivityAt  archived  cliSessionId  branches
# Concatenated JSON objects are a valid jq input stream, so one cat + one jq
# handles hundreds of wrappers in two processes rather than 2N. Piping also
# sidesteps the POSIX-vs-Windows path problem: a Windows jq cannot open
# "/c/Users/..." but reads stdin fine.
# Bounded by age: scanning the full history costs ~85s here against ~40s for
# the recent slice. A wrapper is rewritten on every turn boundary and on
# metadata changes, so an open session falls out of the window only after
# weeks of total silence — and prune treats a .claude/worktrees/ tree nobody
# claims as REVIEW, so what the window drops can never become SAFE.
# jq's status is CHECKED: a parse error stops jq mid-stream, and a silently
# truncated scan reads as "fewer owners" — the unsafe direction. A failed scan
# is therefore "unavailable" (3), and prune degrades to report-only.
# `tr -d '\r'`: a Windows-native jq (scoop/WinGet) ends lines CRLF, and the CR
# would ride on the LAST column — the branch list — so "lane/x" never equals
# "lane/x\r". Git Bash's $(...) happens to strip it; nothing else promises to.
scan_wrappers() {
    local age_days=${FLEET_SESSION_MAX_AGE_DAYS:-60} out rc
    out=$(find "$@" -name 'local_*.json' -type f -mtime "-${age_days}" -exec cat {} + 2>/dev/null | jq -r '
        def s: if type == "string" then . else "" end;
        [ (.sessionId | s),
          (.title | s),
          (.cwd | s | gsub("\\\\"; "/")),
          (.worktreePath | s | gsub("\\\\"; "/")),
          ((.lastActivityAt // 0) | if type == "number" then floor | tostring else "0" end),
          (if .isArchived == true then "1" else "0" end),
          (.cliSessionId | s),
          ( ([ .branch ] + (.writtenBranches | if type == "array" then . else [] end))
            | map(select(type == "string" and . != "")) | unique | join(" ") )
        ] | @tsv
    ' 2>/dev/null | tr -d '\r'; exit "${PIPESTATUS[1]}")
    rc=$?
    (( rc == 0 )) || { echo "$SELF: session store scan failed (jq exit $rc) — treating as unavailable" >&2; return 3; }
    printf '%s\n' "$out"
}

# cli  lastMs  txdir  livecwd — one row per CLI session with a transcript.
# Depth 2 only (<root>/<encoded-cwd>/<cliSessionId>.jsonl): subagent
# transcripts one level further down roughly double the walk (3.0s -> 6.8s
# measured 2026-09-28) and here they could only move a row between KEEP and
# REVIEW, neither of which prune removes. `live_many` — the gates' fresh read —
# does count them, for just the sessions it is asked about.
# stat is batched through -exec +: a handful of processes, not one per file.
# The flavour is PROBED, never tried-then-fallen-back: on GNU, `stat -f` means
# --file-system and would splice filesystem dumps into the listing.
scan_transcripts() {
    load_dirs
    (( ${#TROOTS[@]} )) || return 0
    local age_days=${FLEET_SESSION_MAX_AGE_DAYS:-60} now_s listing fmt=()
    now_s=$(date +%s)
    if stat -c '%Y' / >/dev/null 2>&1; then fmt=(-c '%Y %n'); else fmt=(-f '%m %N'); fi
    listing=$(find "${TROOTS[@]}" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mtime "-${age_days}" \
                -exec stat "${fmt[@]}" {} + 2>/dev/null)
    [[ -n "$listing" ]] || return 0
    local cli ms d p lc
    printf '%s\n' "$listing" | awk -v now="$now_s" -v win="$LIVE_SECS" '
        NF >= 2 {
            m = $1 + 0; p = $0; sub(/^[^ ]+ /, "", p)
            n = split(p, a, "/"); f = a[n]; sub(/\.jsonl$/, "", f)
            if (!(f in best) || m > best[f]) { best[f] = m; dir[f] = a[n-1]; path[f] = p }
        }
        END {
            for (f in best)
                printf "%s\t%.0f\t%s\t%s\n", f, best[f] * 1000, tolower(dir[f]),
                       (now - best[f] <= win) ? path[f] : ""
        }' \
    | while IFS=$'\t' read -r cli ms d p; do
        lc=""
        if [[ -n "$p" ]]; then
            # Last "cwd" the transcript recorded. JSON escapes each backslash
            # as a pair; turn the pair into '/' so it normalises like the rest.
            lc=$(tail -c 262144 "$p" 2>/dev/null | grep -o '"cwd":"[^"]*"' | tail -n1)
            lc=${lc#\"cwd\":\"}; lc=${lc%\"}
            lc=${lc//\\\\//}
        fi
        printf '%s\t%s\t%s\t%s\n' "$cli" "$ms" "$d" "$lc"
    done
}

# The join. Liveness = the NEWER of the wrapper's lastActivityAt and the
# transcript's mtime: the wrapper alone reads a mid-turn session as idle.
# Big epoch-ms values go through printf %.0f — mawk (Debian/Ubuntu's default
# awk) prints integers above 2^31 in exponent form under plain `print`.
scan_all() {
    load_dirs
    (( ${#STORES[@]} )) || { echo "$SELF: no Claude session store on this machine" >&2; return 3; }
    command -v jq >/dev/null 2>&1 || { echo "$SELF: jq not found — session enrichment off" >&2; return 3; }

    local wrappers tx
    wrappers=$(scan_wrappers "${STORES[@]}") || return 3
    tx=$(scan_transcripts)
    local now_ms=$(( $(date +%s) * 1000 )) win_ms=$(( LIVE_SECS * 1000 ))
    awk -F'\t' -v now="$now_ms" -v win="$win_ms" '
        FILENAME == ARGV[1] { if ($1 != "") { tm[$1] = $2 + 0; td[$1] = $3; tc[$1] = $4 }; next }
        $1 != "" {
            lm = $5 + 0; d = ""; lc = ""; cli = $7
            if (cli != "" && (cli in tm)) {
                seen[cli] = 1; d = td[cli]; lc = tc[cli]
                if (tm[cli] > lm) lm = tm[cli]
            }
            live = (lm > 0 && now - lm <= win) ? 1 : 0
            if (!live) lc = ""
            printf "W\t%s\t%s\t%.0f\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", $1, $2, lm, $3, $4, $6, live, $8, d, lc
        }
        END {
            for (c in tm)
                if (!(c in seen) && now - tm[c] <= win)
                    printf "T\tcli:%s\t%s\t%.0f\t\t\t0\t1\t\t%s\t%s\n", c,
                           "(no Desktop record - CLI or headless session)", tm[c], td[c], tc[c]
        }' <(printf '%s\n' "$tx") <(printf '%s\n' "$wrappers")
}

# CACHED, AND THE CACHE IS NOT OPTIONAL. A cold scan walks every wrapper in
# every store and takes tens of seconds on Windows; `fleet status` and the land
# gate call this repeatedly, and uncached, five calls blew a 2-minute timeout
# during development.
# TTL is long ON PURPOSE. Nothing that DECIDES anything reads a cached liveness
# value: `session_land_gate` calls `owner --fresh` and `at --fresh`, which
# re-read each claimant's liveness directly, and `prune --remove` re-classifies
# against a forced fresh scan before it deletes anything. Cached rows feed
# display and prune's first-pass classification only. A short TTL bought no
# correctness and cost ~41s per `fleet status` (47.1s cold vs 6.0s warm,
# measured 2026-08-03 on an 11-worktree repo).
CACHE_TTL=${FLEET_SESSION_CACHE_TTL:-900}

# Keyed by WHAT was scanned, not only by who scanned it. The old key was the
# uid alone, so any run with FLEET_SESSION_STORE pointed at a fixture — the
# test suite does exactly that — overwrote the real index, and a real `fleet
# prune` inside the TTL then read fixture rows: every real session invisible,
# every worktree "unowned". The key covers stores, transcript roots, and the
# liveness window (the live column is computed with it).
# The signature is a djb2 hash computed in bash: a `| cksum` would fork on
# every call (see "discovery"). It only has to separate store sets from each
# other, not resist anyone.
CACHE_FILE=""
set_cache_file() {
    load_dirs
    local s h=5381 i c d
    s="${STORES[*]:-}|${TROOTS[*]:-}|$LIVE_SECS|${FLEET_SESSION_MAX_AGE_DAYS:-60}"
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v c '%d' "'${s:i:1}"
        h=$(( (h * 33 + c) & 0x7fffffff ))
    done
    d=${TMPDIR:-/tmp}
    CACHE_FILE="${d%/}/fleet-sessions-v2-${UID:-0}-${h}.tsv"
}

# Current epoch seconds without forking where bash can (4.2+); date otherwise.
NOW=0
now_s() { printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s); }

# Fills WIDE (the wide rows) from the cache when fresh, else from a scan.
# Returns through a global rather than stdout so callers need no $(...).
WIDE=""
load_wide() {
    set_cache_file
    local cf=$CACHE_FILE
    if [[ -z "${FLEET_SESSION_NOCACHE:-}" && -f "$cf" ]]; then
        now_s
        local age=$(( NOW - $(file_mtime_s "$cf") ))
        if (( age >= 0 && age < CACHE_TTL )); then
            WIDE=""
            IFS= read -r -d '' WIDE < "$cf" || true
            return 0
        fi
    fi
    WIDE=$(scan_all) || return $?
    # Write-then-rename. A reader that catches a half-written index sees fewer
    # owners than exist — the unsafe direction for every caller.
    local tmp="$cf.$$"
    if printf '%s\n' "$WIDE" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Projections of the wide rows (stdin). $1 is an optional row prefix, used by
# `views` to tag which projection a line belongs to.
#
# index: branch  sessionId  title  lastMs  cwd  archived  live
project_index() {
    awk -F'\t' -v OFS='\t' -v pre="${1:-}" '
        $1 == "W" && $9 != "" { n = split($9, b, " "); for (i = 1; i <= n; i++) print pre b[i], $2, $3, $4, $5, $7, $8 }'
}
# paths: key  path  sessionId  title  lastMs  archived  live  via
# A session claims a directory by its wrapper cwd, its wrapper worktreePath,
# its transcript's project dir (encoded — key only), and, while live, the last
# cwd its transcript recorded.
project_paths() {
    LC_ALL=C awk -F'\t' -v OFS='\t' -v pre="${1:-}" '
        function np(p) { gsub(/\\/, "/", p); sub(/\/+$/, "", p); return tolower(p) }
        function enc(p) { p = np(p); gsub(/[^a-z0-9]/, "-", p); return p }
        $1 == "W" || $1 == "T" {
            if ($5 != "")                     print pre enc($5),  np($5),  $2, $3, $4, $7, $8, "cwd"
            if ($6 != "" && np($6) != np($5)) print pre enc($6),  np($6),  $2, $3, $4, $7, $8, "worktree"
            if ($10 != "")                    print pre tolower($10), "",   $2, $3, $4, $7, $8, "transcript"
            if ($11 != "")                    print pre enc($11), np($11), $2, $3, $4, $7, $8, "live-cwd"
        }'
}

build_index() { load_wide || return $?; project_index <<< "$WIDE"; }
build_paths() { load_wide || return $?; project_paths <<< "$WIDE"; }
# Both projections from ONE process, lines tagged I<TAB> / P<TAB>. fleet.sh
# needs both on every `fleet status`, and a second sessions.sh process costs
# ~200ms on Windows each time.
build_views() {
    load_wide || return $?
    project_index 'I\t' <<< "$WIDE"
    project_paths 'P\t' <<< "$WIDE"
}

# --- liveness ----------------------------------------------------------------
# id  lastActivityAt  cliSessionId — one row per wrapper FILE given. jq's status
# is checked, as in scan_wrappers: one unparseable file (a wrapper caught
# mid-rewrite) stops jq mid-stream, and every wrapper after it would silently
# read as idle. On failure each file is therefore read on its own.
wrapper_live_meta() {
    local q='def s: if type == "string" then . else "" end;
        [ (.sessionId | s),
          ((.lastActivityAt // 0) | if type == "number" then floor | tostring else "0" end),
          (.cliSessionId | s) ] | @tsv'
    local out rc f
    out=$(cat "$@" 2>/dev/null | jq -r "$q" 2>/dev/null; exit "${PIPESTATUS[1]}"); rc=$?
    if (( rc != 0 )); then
        out=""
        for f in "$@"; do out+=$(jq -r "$q" < "$f" 2>/dev/null)$'\n'; done
    fi
    printf '%s\n' "$out" | tr -d '\r'    # CRLF from a Windows-native jq — see scan_wrappers
}

# Authoritative liveness, bypassing the cache: "id<TAB>1|0" for each session id
# given, in the order given. Accepts store ids (local_<uuid>) and T-row ids
# (cli:<uuid>); an unknown id is 0.
# The cache trades staleness for speed, and stale-idle-but-actually-live is the
# one direction that would let the land gate through when it should refuse — so
# every gate decision re-reads here. Live = the newer of the wrapper's
# lastActivityAt and the session's newest transcript write, its subagents'
# included (a session fanned out to subagents can go quiet in its own file while
# they work). A wrapper found in several stores takes its newest timestamp.
# BATCHED ON PURPOSE: one walk of the stores and one of the transcript roots, for
# any number of ids. The per-session read it replaced cost ~3s here (it globbed
# every root twice), so `at --fresh` on a checkout with a few dozen past
# claimants took ~48s one session at a time and ~9s batched (measured
# 2026-09-28). The walk finds exactly what those globs did:
# <root>/<dir>/<cli>.jsonl and <root>/<dir>/<cli>/subagents/*.jsonl.
live_many() {
    (( $# )) || return 0
    load_dirs
    local id la c f fmt=() files=() names=() stats=() clis=() wmeta="" tmeta=""
    for id in "$@"; do [[ -z "$id" || "$id" == cli:* ]] || names+=(-o -name "$id.json"); done
    if (( ${#names[@]} && ${#STORES[@]} )) && command -v jq >/dev/null 2>&1; then
        while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done \
            < <(find "${STORES[@]}" -type f \( "${names[@]:1}" \) 2>/dev/null)
        (( ${#files[@]} )) && wmeta=$(wrapper_live_meta "${files[@]}")
    fi

    while IFS=$'\t' read -r id la c; do [[ -n "$c" ]] && clis+=("$c"); done <<< "$wmeta"
    for id in "$@"; do [[ "$id" == cli:* ]] && clis+=("${id#cli:}"); done
    names=()
    for c in ${clis[@]+"${clis[@]}"}; do names+=(-o -name "$c.jsonl" -o -name "$c"); done
    if (( ${#names[@]} && ${#TROOTS[@]} )); then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if [[ -d "$f" ]]; then
                for c in "$f"/subagents/*.jsonl; do [[ -f "$c" ]] && stats+=("$c"); done
            elif [[ "$f" == *.jsonl ]]; then
                stats+=("$f")
            fi
        done < <(find "${TROOTS[@]}" -mindepth 2 -maxdepth 2 \( "${names[@]:1}" \) 2>/dev/null)
    fi
    if (( ${#stats[@]} )); then
        # Probed, never tried-then-fallen-back — see scan_transcripts.
        if stat -c '%Y' / >/dev/null 2>&1; then fmt=(-c '%Y %n'); else fmt=(-f '%m %N'); fi
        tmeta=$(printf '%s\0' "${stats[@]}" | xargs -0 stat "${fmt[@]}" 2>/dev/null | awk '
            NF >= 2 {
                m = $1 + 0; p = $0; sub(/^[^ ]+ /, "", p); n = split(p, a, "/")
                c = (n > 2 && a[n-1] == "subagents") ? a[n-2] : a[n]; sub(/\.jsonl$/, "", c)
                if (!(c in b) || m > b[c]) b[c] = m
            }
            END { for (c in b) printf "%s\t%.0f\n", c, b[c] * 1000 }')
    fi

    local now_s; now_s=$(date +%s)
    awk -F'\t' -v now="$(( now_s * 1000 ))" -v win="$(( LIVE_SECS * 1000 ))" '
        FILENAME == ARGV[1] { if ($1 != "") t[$1] = $2 + 0; next }
        FILENAME == ARGV[2] {
            if ($1 != "" && (!($1 in la) || $2 + 0 > la[$1])) { la[$1] = $2 + 0; cl[$1] = $3 }
            next
        }
        $0 != "" {
            last = 0; c = ""
            if (substr($0, 1, 4) == "cli:") c = substr($0, 5)
            else if ($0 in la) { last = la[$0]; c = cl[$0] }
            if (c != "" && (c in t) && t[c] > last) last = t[c]
            printf "%s\t%d\n", $0, (last > 0 && now - last <= win) ? 1 : 0
        }' <(printf '%s\n' "$tmeta") <(printf '%s\n' "$wmeta") <(printf '%s\n' "$@")
}

# One session's liveness: "1" or "0". A one-id call into live_many, so there is
# exactly one definition of "live" for every gate that asks.
session_live_now() {
    local r; r=$(live_many "${1:-}"); r=${r##*$'\t'}
    if [[ "$r" == 1 ]]; then printf '1'; else printf '0'; fi
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
    load_dirs
    (( ${#STORES[@]} )) || return 3
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
        # Searched across EVERY store: a session running in a --user-data-dir
        # instance has its wrapper in that instance's store, not the primary's.
        for cand in "$raw" "local_$raw"; do
            f=$(find_wrapper "$cand")
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

# --- at ----------------------------------------------------------------------
# Every claim on directory $1, by any route: an exact normalised-path match on
# a wrapper cwd / worktreePath / live transcript cwd, or an encoded-key match on
# a transcript's project dir. The key match is lossy by construction (every
# non-alphanumeric is '-'), so callers must treat a key-only claim as grounds
# to KEEP a tree, never as positive evidence that it is abandoned.
#
# --fresh is the land gate's read, held to the standard `owner --fresh` set:
# the cache may NOMINATE a claimant, it never DECIDES one is idle. Every
# nominated session's liveness is re-read directly, and the claim route the
# cache is blind to by construction — a session writing its transcript into
# this directory right now, because it started or EnterWorktree'd here after
# the index was built — is read straight off disk. Deliberately NOT a fresh
# full scan: that took 60s on a busy machine (measured 2026-09-28) and every
# `fleet land` would pay it; this costs a few seconds.
# What it still cannot see: a session whose Bash cwd moved here after the
# index was built while its transcript stays filed elsewhere (the live-cwd
# route) — the same class as a write by absolute path, which nothing records.
# The inverse staleness is the safe one: a session that has since LEFT still
# counts while it is live, because its cached claim is kept and only its
# liveness is refreshed.

# cli  lastMs — every session whose transcript, or one of its subagents',
# is filed under encoded key $1 and was written inside the live window. One
# directory lookup per transcript root, then only the matching directories'
# files. -mmin is only a coarse prefilter (platforms round minutes
# differently); the exact window is applied to the stat'd mtime. A nested
# file belongs to its first path component (<cli>/subagents/<agent>.jsonl):
# a session fanned out to subagents can go quiet in its own file meanwhile.
live_transcripts_under() {
    local key=${1:-} d dirs=() now_s fmt=()
    [[ -n "$key" ]] || return 0
    load_dirs
    (( ${#TROOTS[@]} )) || return 0
    while IFS= read -r d; do [[ -n "$d" ]] && dirs+=("$d"); done \
        < <(find "${TROOTS[@]}" -mindepth 1 -maxdepth 1 -type d -iname "$key" 2>/dev/null)
    (( ${#dirs[@]} )) || return 0
    now_s=$(date +%s)
    # Probed, never tried-then-fallen-back — see scan_transcripts.
    if stat -c '%Y' / >/dev/null 2>&1; then fmt=(-c '%Y %n'); else fmt=(-f '%m %N'); fi
    find "${dirs[@]}" -mindepth 1 -maxdepth 3 -type f -name '*.jsonl' \
            -mmin "-$(( LIVE_SECS / 60 + 2 ))" -exec stat "${fmt[@]}" {} + 2>/dev/null \
    | awk -v key="$key" -v now="$now_s" -v win="$LIVE_SECS" '
        NF >= 2 {
            m = $1 + 0; p = $0; sub(/^[^ ]+ /, "", p)
            if (now - m > win) next
            n = split(p, a, "/"); c = ""
            for (j = n - 1; j >= 1 && j >= n - 3; j--) if (tolower(a[j]) == key) { c = a[j + 1]; break }
            if (c == "") next
            sub(/\.jsonl$/, "", c)
            if (!(c in best) || m > best[c]) best[c] = m
        }
        END { for (c in best) printf "%s\t%.0f\n", c, best[c] * 1000 }'
    return 0
}

# cli  id  title  archived — the Desktop wrapper carrying each CLI session id
# given, found by content across EVERY store (~1.6s over ~2,000 wrappers), so
# attribution never waits on the cache either. This is what lets the land
# gate's self-exemption recognise the caller's own transcript: a transcript is
# named by the CLI session id, the store by the host's. grep narrows, jq then
# demands an exact cliSessionId match. An id no wrapper carries is a CLI or
# headless session and is reported as cli:<id>, like a T row.
# No mapfile: sessions.sh still runs on macOS's stock bash 3.2.
wrappers_for_clis() {
    (( $# )) || return 0
    command -v jq >/dev/null 2>&1 || return 0
    load_dirs
    (( ${#STORES[@]} )) || return 0
    local c f pats=() files=()
    for c in "$@"; do pats+=(-e "$c"); done
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done \
        < <(grep -rlF --include='local_*.json' "${pats[@]}" "${STORES[@]}" 2>/dev/null)
    (( ${#files[@]} )) || return 0
    cat "${files[@]}" 2>/dev/null | jq -r --arg want "$(printf '%s\n' "$@")" '
        def s: if type == "string" then . else "" end;
        ($want | split("\n")) as $w
        | (.cliSessionId | s) as $c
        | select($c != "" and any($w[]; . == $c))
        | [ $c, (.sessionId | s), (.title | s), (if .isArchived == true then "1" else "0" end) ]
        | @tsv
    ' 2>/dev/null | tr -d '\r'    # CRLF from a Windows-native jq — see scan_wrappers
    return 0
}

# The --fresh read of claim rows $2 (the `at` TSV) on the directory keyed $1.
freshen_claims() {
    local key=$1 rows=$2 tx probe="" id fresh_map=""
    tx=$(live_transcripts_under "$key")
    if [[ -n "$tx" ]]; then
        local clis=() cli ms
        while IFS=$'\t' read -r cli ms; do [[ -n "$cli" ]] && clis+=("$cli"); done <<< "$tx"
        # One row per (live transcript, wrapper carrying its id), else cli:<id>.
        probe=$(awk -F'\t' -v OFS='\t' -v k="$key" '
            FILENAME == ARGV[1] { if ($1 != "") { n[$1]++; w[$1, n[$1]] = $2 "\t" $3 "\t" $4 }; next }
            $1 != "" {
                if ($1 in n)
                    for (i = 1; i <= n[$1]; i++) { split(w[$1, i], a, "\t"); print k, "", a[1], a[2], $2, a[3], 1, "transcript" }
                else
                    print k, "", "cli:" $1, "(no Desktop record - CLI or headless session)", $2, 0, 1, "transcript"
            }' <(wrappers_for_clis ${clis[@]+"${clis[@]}"}) <(printf '%s\n' "$tx"))
    fi
    # Every cached claimant's liveness, re-read in one batch. A session the probe
    # just saw writing here is live by that direct observation, and the map
    # lists it last so nothing can read it back down to idle.
    local ids=()
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done \
        < <(printf '%s\n' "$rows" | awk -F'\t' 'NF && !s[$3]++ { print $3 }')
    fresh_map=$(live_many ${ids[@]+"${ids[@]}"}
                printf '%s\n' "$probe" | awk -F'\t' -v OFS='\t' 'NF { print $3, 1 }')
    # Cached rows first (live column overwritten), then the probe's; one row
    # per (session, route).
    {
        awk -F'\t' -v OFS='\t' '
            FILENAME == ARGV[1] { if ($1 != "") L[$1] = $2; next }
            NF { if ($3 in L) $7 = L[$3]; print }' <(printf '%s' "$fresh_map") <(printf '%s\n' "$rows")
        printf '%s\n' "$probe"
    } | awk -F'\t' 'NF && !seen[$3 FS $8]++'
}

cmd_at() {
    local fresh=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fresh) fresh=1; shift ;;
            -*) echo "$SELF: unknown flag '$1'" >&2; return 2 ;;
            *) break ;;
        esac
    done
    local p=${1:-}
    [[ -z "$p" ]] && { echo "usage: $SELF at [--fresh] <path>" >&2; return 2; }
    local n k rows
    n=$(norm_path "$p"); k=$(path_key "$n")
    rows=$(build_paths) || return $?
    rows=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$n" -v k="$k" 'NF && (($2 != "" && $2 == n) || $1 == k)')
    (( fresh )) && rows=$(freshen_claims "$k" "$rows")
    [[ -n "$rows" ]] && printf '%s\n' "$rows"
    return 0
}

# What was read. The 2026-09-28 misclassification was invisible precisely
# because nothing ever said WHICH store answered; this makes it one command.
cmd_stores() {
    local d
    load_dirs
    for d in ${STORES[@]+"${STORES[@]}"}; do printf 'store\t%s\n' "$d"; done
    for d in ${TROOTS[@]+"${TROOTS[@]}"}; do printf 'transcripts\t%s\n' "$d"; done
    (( ${#STORES[@]} )) || return 3
    return 0
}

case "${1:---help}" in
    -h|--help|help) usage; exit 0 ;;
    index)          build_index; exit $? ;;
    paths)          build_paths; exit $? ;;
    views)          build_views; exit $? ;;
    at)             shift; cmd_at "$@"; exit $? ;;
    stores)         cmd_stores; exit $? ;;
    owner)          shift; cmd_owner "$@"; exit $? ;;
    main)           cmd_main; exit $? ;;
    live)           shift; [[ -z "${1:-}" ]] && { echo "usage: $SELF live <sessionId>" >&2; exit 2; }
                    session_live_now "$1"; echo; exit 0 ;;
    self)           self_session_id || exit 3; exit 0 ;;
    *)              echo "$SELF: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
