# net-ops :: _lib/cache.sh
# Lightweight state cache for --quick mode.
# Stores the last probe's summary so we can decide whether to run the full
# ladder or just the most failure-prone layers (rungs 5+6).

CACHE_DIR="${NETOPS_CACHE_DIR:-${TMPDIR:-/tmp}/net-ops}"
CACHE_FILE="$CACHE_DIR/last-state.json"
CACHE_MAX_AGE_SECONDS="${NETOPS_CACHE_MAX_AGE:-600}"  # 10 minutes default

QUICK_MODE=0

parse_quick_flag() {
    for a in "$@"; do
        [[ "$a" == "--quick" ]] && QUICK_MODE=1
    done
}

# Returns 0 if the last cached state is "all healthy and recent" — caller
# should then skip rungs 1-4 and only run 5+6. Returns 1 otherwise.
cache_indicates_healthy() {
    [[ "$QUICK_MODE" -eq 1 ]] || return 1
    [[ -f "$CACHE_FILE" ]] || return 1
    # File age check (BSD vs GNU stat compat)
    local mtime now age
    mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null)
    [[ -n "$mtime" ]] || return 1
    now=$(date +%s)
    age=$(( now - mtime ))
    (( age > CACHE_MAX_AGE_SECONDS )) && return 1
    # Parse: only return healthy if fail count was zero
    grep -q '"fail":0' "$CACHE_FILE" 2>/dev/null
}

# Save current state at end of probe.
cache_save_state() {
    local pass="$1" fail="$2" first_fail="$3"
    mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
    printf '{"ts":%d,"pass":%d,"fail":%d,"first_fail":%q}\n' \
        "$(date +%s)" "$pass" "$fail" "$first_fail" > "$CACHE_FILE" 2>/dev/null || true
}

# Predicate the probe can call to decide whether to run a given rung.
# Args: rung_number (1..7). In quick mode, only 5 and 6 run.
should_run_rung() {
    local rung="$1"
    if cache_indicates_healthy; then
        case "$rung" in
            5|6) return 0 ;;
            *)   return 1 ;;
        esac
    fi
    return 0
}
