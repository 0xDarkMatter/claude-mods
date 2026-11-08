#!/bin/bash
# hooks/tool-loop-guard.sh
# PreToolUse + PostToolUse + PostToolUseFailure - a repetition guard in the harness, not the model.
# Port of Factory Droid 1.0's loop rule: the 3rd identical tool call in a row gets a nudge, the 6th
# is denied. Claude Code has no built-in guard, so a model stuck re-running the same failing command
# or re-reading the same file burns turns until a human notices. Same rule for every model and lane.
#
# "Identical" = same tool name + same canonicalised input + same RESULT as the previous call.
#   - Input: tool_input with keys sorted (jq -S); `description` dropped (Bash/PowerShell prose).
#   - Result: tool_response (PostToolUse) or error (PostToolUseFailure, where a non-zero Bash exit
#     lands), keys sorted, timing keys (durationMs, duration_ms, ...) dropped so a Glob/WebFetch
#     repeat isn't "new" by its own clock.
#   WHY the result: a poll (`gh run view`, a log tail, TaskOutput) repeats its input by design, and
#   while its output changes it is making progress. A changed result restarts the count at 1, so
#   there is no list of polling tools to maintain. A poll unchanged 6 times running IS stuck.
#   LOOP_GUARD_EXEMPT (ERE on tool_name) is the escape hatch for a tool that must repeat unchanged.
#
# Events: Post* updates the count and nudges (additionalContext) from LOOP_GUARD_NUDGE (3) up.
#   Pre denies (permissionDecision deny) when the state already holds LOOP_GUARD_DENY-1 (5) identical
#   calls with this input: the result is unknown before the call runs, so call 6 is judged by the 5
#   before it. Pre never writes state. A denied call has no Post, so the count stays at 5 and every
#   retry of that same call is denied until the model does something else.
# State: ${LOOP_GUARD_DIR:-~/.claude/.loop-guard}/<session_id>[.<agent_id>].state, one line
#   "<input-sha1> <result-sha1> <count>". Subagents get their own file: their calls interleave with
#   the parent's under one session_id and would otherwise break each other's runs. Files untouched
#   for 2+ days are pruned when a new session (or subagent) writes its first state.
# Fail-open: any internal problem (no jq, no session_id, a failed hash) exits 0 silently - a broken
#   guard must never block real work. Env: LOOP_GUARD=0 off; LOOP_GUARD_DENY=0 nudge only.
# Docs: hooks/README.md "Tool loop guard". Tests: tests/hooks.sh "tool-loop-guard".

set -uo pipefail

[ "${LOOP_GUARD:-1}" = "0" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NUDGE=${LOOP_GUARD_NUDGE:-3}; DENY=${LOOP_GUARD_DENY:-6}
[[ "$NUDGE" =~ ^[0-9]+$ ]] && [ "$NUDGE" -ge 2 ] || NUDGE=3
[[ "$DENY" =~ ^[0-9]+$ ]] || DENY=6
[ "$DENY" -eq 0 ] || [ "$DENY" -gt "$NUDGE" ] || DENY=$((NUDGE + 1))

if command -v sha1sum >/dev/null 2>&1; then HASH=(sha1sum)
elif command -v shasum >/dev/null 2>&1; then HASH=(shasum -a 1)
else exit 0; fi
DIR="${LOOP_GUARD_DIR:-$HOME/.claude/.loop-guard}"
T="$DIR/.tmp.$$"

# GUARD: this runs on EVERY tool call, twice, and each spawn costs 40-70 ms on Windows. So jq reads
# stdin once and prints: line 1 a short meta string, line 2 the canonical input, line 3 (Post* only)
# the canonical result. Only line 1 is read by bash (`read` crawls on big lines, ~0.5 s per 400 KB);
# the blobs go straight to sha1sum, via `split` into temp files when there are two. Don't "simplify"
# this into $(cat) + several jq/sha1sum pipelines: that was 8 spawns (~400 ms) per Post.
# Meta is "event|session|agent|tool": none of those ids can hold `|` or `"`.
JQ='def strip: if type == "object" then
      del(.durationMs, .duration_ms, .durationSeconds, .elapsedMs, .elapsed_ms, .timestamp)
      | map_values(strip) elif type == "array" then map(strip) else . end;
  ([.hook_event_name, .session_id, .agent_id, .tool_name] | map(. // "") | join("|")),
  [.tool_name, (.tool_input | if type == "object" then del(.description) else . end)],
  (select(.hook_event_name // "" | startswith("PostToolUse")) | (.tool_response // .error // null) | strip)'

OUT=$(jq -cS "$JQ" 2>/dev/null | {
  IFS= read -r m || exit 1
  printf '%s\n' "$m"
  case "$m" in
    '"PostToolUse'*)   # covers PostToolUseFailure
      [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null || exit 1
      rc=0; split -l 1 - "$T." && "${HASH[@]}" "$T.aa" "$T.ab" || rc=1
      rm -f "$T.aa" "$T.ab" 2>/dev/null; exit $rc ;;
    *) "${HASH[@]}" ;;
  esac
}) || exit 0

{ IFS= read -r META; read -r FP _; read -r RP _; } <<< "$OUT"
META=${META%$'\r'}; META=${META#\"}; META=${META%\"}
IFS='|' read -r EVENT SID AGENT TOOL <<< "$META"
[ -n "${SID:-}" ] && [ -n "${TOOL:-}" ] && [ -n "${FP:-}" ] || exit 0
if [ -n "${LOOP_GUARD_EXEMPT:-}" ] && [[ "$TOOL" =~ $LOOP_GUARD_EXEMPT ]]; then exit 0; fi

KEY="$SID${AGENT:+.$AGENT}"; KEY=${KEY//[^A-Za-z0-9_.-]/_}
STATE="$DIR/$KEY.state"
S_FP=""; S_RP=""; S_N=0
[ -f "$STATE" ] && read -r S_FP S_RP S_N < "$STATE" 2>/dev/null
[[ "${S_N:-}" =~ ^[0-9]+$ ]] || S_N=0

case "$EVENT" in
  PreToolUse)
    if [ "$DENY" -gt 0 ] && [ "$FP" = "$S_FP" ] && [ "$S_N" -ge $((DENY - 1)) ]; then
      R="LOOP GUARD: denied. This exact $TOOL call already ran $S_N times in a row with the same"
      R="$R result, so call $DENY would not change anything. Change approach (different input, a"
      R="$R different tool, or read the error you keep getting), or stop and report what is blocking"
      R="$R you. Any different call, or a changed result, resets the count."
      jq -nc --arg r "$R" '{hookSpecificOutput:{hookEventName:"PreToolUse",
        permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
  PostToolUse|PostToolUseFailure)
    [ -n "${RP:-}" ] || exit 0
    if [ "$FP" = "$S_FP" ] && [ "$RP" = "$S_RP" ]; then N=$((S_N + 1)); else N=1; fi
    # First state of a new session/subagent: prune files from sessions long gone.
    [ -f "$STATE" ] || find "$DIR" -maxdepth 1 -type f -name '*.state' -mtime +2 -delete 2>/dev/null
    # One ~90-byte write: a single write(2), so a parallel reader never sees a torn line, and no
    # temp+mv (one spawn fewer). Last writer wins between parallel calls, which only resets a run.
    printf '%s %s %s\n' "$FP" "$RP" "$N" > "$STATE" 2>/dev/null || exit 0
    if [ "$N" -ge "$NUDGE" ]; then
      C="LOOP GUARD: this exact $TOOL call has now run $N times in a row with the same result."
      C="$C Repeating it will not change the outcome: change approach (different input, a different"
      C="$C tool, or read the error you keep getting), or stop and report what is blocking you."
      if [ "$DENY" -gt 0 ]; then
        if [ "$N" -ge $((DENY - 1)) ]; then C="$C The next identical call will be denied."
        else C="$C Identical call $DENY will be denied."; fi
      fi
      jq -nc --arg e "$EVENT" --arg c "$C" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
    fi
    ;;
esac
exit 0
