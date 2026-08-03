#!/usr/bin/env bash
# fleet-ops/signal.sh — called by Claude sessions to signal lane status
# Auto-detects the current branch. Refuses dirty trees.
# Resolves .fleet/ via git common dir, so it works from inside worktrees.
set -euo pipefail

GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
[[ -z "$GIT_COMMON_DIR" ]] && { echo "signal.sh ERROR: not in a git repo" >&2; exit 2; }
# git-common-dir is .git/ at main repo root → parent is the main worktree
MAIN_REPO_ROOT=$(cd "$GIT_COMMON_DIR/.." && pwd)
LANES_DIR="$MAIN_REPO_ROOT/.claude/fleet/lanes"
BRANCH=$(git branch --show-current 2>/dev/null || true)

if [[ -z "$BRANCH" ]]; then
  echo "signal.sh ERROR: not on a branch (detached HEAD?)" >&2
  exit 2
fi

# Lane files are flat: encode '/' in branch names (feat/x, fleet/x) so they don't
# nest into nonexistent subdirs. MUST match fleet.sh's encode_lane.
encode_lane() { local s=${1//\%/%25}; printf '%s' "${s//\//%2F}"; }
LANE_FILE="$LANES_DIR/$(encode_lane "$BRANCH")"

if [[ ! -f "$LANE_FILE" ]]; then
  echo "signal.sh ERROR: branch '$BRANCH' is not a registered lane (run: fleet track $BRANCH)" >&2
  exit 2
fi

# === LOG VERDICT ===
# Pass/fail from a test log, structured-signals-first. Grepping the whole log
# for "failed|error" false-positives on any suite that exercises failure paths
# (a PASSING run legitimately prints "email ... failed: No such module" to
# stderr, and a passing test NAMED "...error..." trips the word too — both hit
# on the Ledger repo, 2026-07). Order of trust:
#   1. exit code — authoritative (explicit arg, or a trailing "exit code: N"
#      line the lane appended to the log)
#   2. runner summary line (vitest/jest "Tests ...", pytest "=== N passed ===",
#      cargo "test result:", go "FAIL"/"ok")
#   3. anchored fallback: count-shaped failure mentions ("N failed") only —
#      never a bare word-grep over the full log
# Returns: 0 = pass, 1 = fail, 2 = no structured summary found.
log_summary_verdict() {
  local log=$1 line

  # vitest ("  Tests  2 failed | 10 passed (12)") / jest ("Tests: 2 failed, ...").
  # "Test Files" (vitest) deliberately not matched — the "Tests" line is the verdict.
  line=$(grep -E '^[[:space:]]*Tests(:|[[:space:]])' "$log" | tail -n1 || true)
  if [[ -n "$line" ]]; then
    grep -qE '[1-9][0-9]*[[:space:]]+fail' <<<"$line" && return 1 || return 0
  fi

  # pytest short summary: "==== 2 failed, 10 passed in 1.2s ===="
  line=$(grep -E '^=+ .*[0-9]+ (passed|failed|error).* =+$' "$log" | tail -n1 || true)
  if [[ -n "$line" ]]; then
    grep -qE '[1-9][0-9]*[[:space:]]+(failed|error)' <<<"$line" && return 1 || return 0
  fi

  # cargo: "test result: ok. ..." / "test result: FAILED. ..." (last suite wins)
  line=$(grep -E '^test result: ' "$log" | tail -n1 || true)
  if [[ -n "$line" ]]; then
    case "$line" in "test result: ok."*) return 0;; *) return 1;; esac
  fi

  # go test: per-package "FAIL"/"--- FAIL:" lines, "ok  <pkg>" on pass
  if grep -qE '^(FAIL|--- FAIL:)' "$log"; then return 1; fi
  if grep -qE '^ok[[:space:]]' "$log"; then return 0; fi

  return 2
}

# === HANDOFF TO MAIN ==========================================================
# Writing a lane file tells the QUEUE. It does not tell the human, and it does
# not tell the coordinator session — which may be idle in another window with no
# reason to poll. This prints the address of the MAIN session plus the exact
# message to deliver, so the lane's agent can hand off explicitly.
#
# The script deliberately does NOT send anything. Delivery differs per surface:
#   - Desktop Claude  -> mcp__ccd_session_mgmt__send_message (an MCP tool; a
#                        shell script cannot invoke it, and it prompts the user
#                        by design). The AGENT sends it.
#   - anywhere else   -> pigeon, which is a real CLI and works in a terminal and
#                        for non-Claude harnesses.
# Resolving the address is the part a script can do well; sending is not.
announce_main() {
  local state=$1 detail=${2:-}
  local sessions="$MAIN_REPO_ROOT/.claude/fleet/sessions.sh"
  [[ -f "$sessions" ]] || return 0
  local row; row=$(bash "$sessions" main 2>/dev/null) || return 0
  [[ -z "$row" ]] && return 0

  local id title live
  id=$(printf '%s' "$row" | cut -f2)
  title=$(printf '%s' "$row" | cut -f3)
  live=$(printf '%s' "$row" | cut -f7)

  {
    echo
    echo "handoff -> MAIN: '$title' ($id)$([[ "$live" == "1" ]] && echo ' [live]' || echo ' [idle]')"
    echo "  If you are a Claude Desktop session, deliver this now with"
    echo "  mcp__ccd_session_mgmt__send_message to session_id $id:"
    echo
    echo "    lane $BRANCH is $state${detail:+ ($detail)}. Requesting land via fleet-ops."
    echo
    echo "  Not on Desktop (terminal, headless, or a non-Claude harness)?"
    echo "  Use the portable bus instead:"
    echo "    pigeon send $(basename "$MAIN_REPO_ROOT") \"lane $BRANCH $state\" \"Requesting land.\""
  } >&2
}
# === END HANDOFF ==============================================================

STATE=${1:-}
case "$STATE" in
  READY)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "signal.sh REFUSE: '$BRANCH' has uncommitted tracked changes — commit or stash before signaling READY" >&2
      git status --short >&2
      exit 1
    fi
    LOG=${2:-}
    RC=${3:-}
    if [[ -n "$RC" && ! "$RC" =~ ^[0-9]+$ ]]; then
      echo "signal.sh ERROR: exit-code arg '$RC' is not numeric" >&2; exit 1
    fi
    if [[ -n "$LOG" ]]; then
      [[ -f "$LOG" ]] || { echo "signal.sh ERROR: test log '$LOG' not found" >&2; exit 1; }
      # No explicit exit-code arg → accept an "exit code: N" line lanes append
      # to the log (the workaround two lanes independently invented; now contract).
      if [[ -z "$RC" ]]; then
        RC=$(grep -iE '^[[:space:]]*exit code:[[:space:]]*[0-9]+' "$LOG" | tail -n1 | grep -oE '[0-9]+' | tail -n1 || true)
      fi
      if [[ -n "$RC" ]]; then
        if (( RC != 0 )); then
          echo "signal.sh REFUSE: test command exited $RC (log '$LOG')" >&2
          tail -n 10 "$LOG" >&2
          exit 1
        fi
        # exit 0 is authoritative — no log grep can overrule it
      elif log_summary_verdict "$LOG"; then
        : # structured summary says pass
      else
        v=$?
        if (( v == 1 )); then
          echo "signal.sh REFUSE: test log '$LOG' summary shows failures" >&2
          grep -E '^[[:space:]]*Tests(:|[[:space:]])|^=+ .*=+$|^test result: |^(FAIL|--- FAIL:)' "$LOG" | tail -n 5 >&2
          exit 1
        fi
        # No exit code, no recognized summary → anchored fallback: refuse only
        # on count-shaped failure lines ("2 failed", "1 failing", "3 errors"),
        # never on prose containing the bare words.
        if grep -qiE '\b[1-9][0-9]*[[:space:]]+(failed|failing|errors?)\b' "$LOG"; then
          echo "signal.sh REFUSE: test log '$LOG' shows failures" >&2
          grep -iE '\b[1-9][0-9]*[[:space:]]+(failed|failing|errors?)\b' "$LOG" | head -5 >&2
          exit 1
        fi
      fi
    fi
    { echo "READY"; [[ -n "$LOG" ]] && echo "log=$LOG"; } > "$LANE_FILE"
    echo "signal: $BRANCH → READY"
    announce_main READY "tests green"
    ;;
  CONFLICT)
    REASON=${2:-"unspecified"}
    { echo "CONFLICT"; echo "reason=$REASON"; } > "$LANE_FILE"
    echo "signal: $BRANCH → CONFLICT ($REASON)"
    # A CONFLICT is exactly the case where silence costs most: the lane cannot
    # land itself and MAIN is the only session that can triage it.
    announce_main CONFLICT "$REASON"
    ;;
  RUNNING)
    echo "RUNNING" > "$LANE_FILE"
    echo "signal: $BRANCH → RUNNING"
    ;;
  *)
    echo "usage: signal.sh READY [test-log] [exit-code]   |   CONFLICT [reason]   |   RUNNING" >&2
    exit 1
    ;;
esac
