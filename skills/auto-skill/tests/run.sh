#!/usr/bin/env bash
# Self-test for auto-skill — sandboxed, offline, never touches real state.
#
# evaluate.sh ships real side effects: it reads a per-session tracking file
# (/tmp/claude_autoskill_<8>), classifies the session, then `rm -f`s the tracking
# file and appends to ~/.claude/auto-skill/pending.log. track-tools.sh is the
# PostToolUse writer that populates that tracking file. Testing them must NEVER
# touch the real ~/.claude/auto-skill/ or the repo's skills/ tree.
#
# Isolation strategy:
#   - HOME is redirected to a throwaway sandbox for EVERY evaluate.sh call, so
#     pending.log + the disable-toggle check land in the sandbox, not real ~.
#   - Each scenario gets a UNIQUE 8-char session-id prefix (the first 8 chars of
#     the session id select the tracking file). The prefix starts with 'g', which
#     never appears in a real (hex-UUID) Claude session id, so our tracking files
#     can never collide with a real running session. gen_sid is called WITHOUT
#     command substitution so its counter survives (a `$(...)` subshell would
#     discard the increment).
#   - The trap removes our 'g'-prefixed tracking + suggested files (and only
#     those) on exit.
#
# Coverage:
#   - track-tools.sh records bare tool names and tags Skill:<name> (sanitised).
#   - evaluate.sh classification: fires on qualifying sessions and when only a
#     harness skill was loaded; stays silent on too-few-writes / too-few-types /
#     non-harness-skill / cooldown.
#   - evaluate.sh reset/safety: the reset path deletes ONLY the intended
#     tracking file (siblings survive); the happy path cleans the tracking file
#     and writes pending.log into the SANDBOX, not real HOME.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
EVAL="$SKILL/scripts/evaluate.sh"
TRACK_TOOL="$SKILL/scripts/track-tools.sh"

SB="$(mktemp -d)"; mkdir -p "$SB/home"
cleanup() {
    rm -rf "$SB" 2>/dev/null
    # 'g' prefix is never a real (hex-UUID) session id → only our files match.
    rm -f /tmp/claude_autoskill_g* /tmp/claude_autoskill_suggested_g* 2>/dev/null
}
trap cleanup EXIT

# Unique per-run, per-scenario 8-char session-id prefixes. SID_BASE from the PID
# keeps parallel runs apart; SEQ increments per call (in the parent shell, NOT a
# subshell). The leading 'g' avoids any real Claude session id (hex UUID).
SID_BASE=$(( $$ % 10000 ))
SEQ=0
GEN_SID=""
gen_sid() { SEQ=$((SEQ+1)); GEN_SID=$(printf 'g%04d%03d' "$SID_BASE" "$SEQ"); }
track_file()    { printf '/tmp/claude_autoskill_%s'            "$1"; }
suggested_file(){ printf '/tmp/claude_autoskill_suggested_%s'  "$1"; }

# Write tool names (one per line) into a tracking file.
write_track() { local f="$1"; shift; : > "$f"; for t in "$@"; do printf '%s\n' "$t" >> "$f"; done; }

# Run evaluate.sh with a session id: HOME=sandbox, CWD=sandbox (no project
# disable file). Captures stdout only (evaluate always exits 0, stderr muted).
run_eval() { ( cd "$SB" && printf '{"session_id":"%sxxxxxxxxxxxx"}' "$1" \
                    | HOME="$SB/home" bash "$EVAL" ); }
# Run track-tools.sh with a tool/session payload, HOME=sandbox.
run_track() { # $1=session_id  $2=tool_name  $3=skill_name(or '')
    local payload
    if [[ -n "$3" ]]; then
        payload=$(printf '{"tool_name":"%s","session_id":"%sxxxxxxxxxxxx","tool_input":{"skill":"%s"}}' "$2" "$1" "$3")
    else
        payload=$(printf '{"tool_name":"%s","session_id":"%sxxxxxxxxxxxx"}' "$2" "$1")
    fi
    ( cd "$SB" && printf '%s' "$payload" | HOME="$SB/home" bash "$TRACK_TOOL" )
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== auto-skill self-test (sandboxed) ==="

# ── syntax ───────────────────────────────────────────────────────────────────
echo "-- syntax --"
bash -n "$EVAL"      2>/dev/null && ok "bash -n evaluate.sh"      || no "bash -n evaluate.sh"
bash -n "$TRACK_TOOL" 2>/dev/null && ok "bash -n track-tools.sh"  || no "bash -n track-tools.sh"

# ── track-tools.sh: records bare names + tags Skill:<name> ───────────────────
echo "-- track-tools.sh writer --"
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
run_track "$SID" "Edit" ""
run_track "$SID" "Bash" ""
run_track "$SID" "Skill" "sync"
run_track "$SID" "Skill" "deep-research"
run_track "$SID" "Skill" "my:weird skill"
contents="$(cat "$TF" 2>/dev/null)"
expect_has "records bare tool name"  $'Edit'                "$contents"
expect_has "records bare Bash"       $'Bash'                "$contents"
expect_has "tags harness skill"      "Skill:sync"           "$contents"
expect_has "tags non-harness skill"  "Skill:deep-research"  "$contents"
expect_has "sanitises separators"    "Skill:my_weird_skill" "$contents"
# written to the per-session file derived from the first 8 chars of session_id
[[ -f "$TF" ]] && ok "track file path derives from session-id prefix" \
                || no "track file path derives from session-id prefix"

# ── evaluate.sh classification ───────────────────────────────────────────────
echo "-- evaluate.sh classification (fires) --"
# Qualifying session: 9 mutating ops, 5 distinct types, no skill -> fires.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
out="$(run_eval "$SID")"
expect_has "qualify -> systemMessage" "systemMessage"   "$out"
expect_has "qualify reports mutating count" "9 mutating ops" "$out"
expect_has "qualify reports type count"     "5 tool types"   "$out"
expect_has "qualify reports total"          "(9 total)"      "$out"

# Harness skill loaded (sync) must NOT disqualify -> still fires.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Skill:sync Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
out="$(run_eval "$SID")"
expect_has "harness skill does not disqualify" "systemMessage" "$out"
expect_has "harness-fire counts skill in total" "(10 total)"   "$out"

echo "-- evaluate.sh classification (silent) --"
# Too few mutating ops (7 < 8).
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Edit Edit Edit Write Write Write Bash
out="$(run_eval "$SID")"
[[ -z "$out" ]] && ok "too few writes (7) -> silent" || no "too few writes should be silent: [$out]"

# Enough writes but too few distinct types (3 < 4).
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Edit Edit Edit Edit Write Write Bash Bash
out="$(run_eval "$SID")"
[[ -z "$out" ]] && ok "too few distinct types (3) -> silent" || no "too few types should be silent: [$out]"

# Non-harness skill loaded -> Gate 1 disqualifies.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Skill:deep-research Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
out="$(run_eval "$SID")"
[[ -z "$out" ]] && ok "non-harness skill -> silent" || no "non-harness skill should be silent: [$out]"

# ── evaluate.sh reset / safety ───────────────────────────────────────────────
echo "-- evaluate.sh reset/safety --"
# Happy path cleans the tracking file and writes pending.log into the SANDBOX.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
run_eval "$SID" >/dev/null
[[ ! -f "$TF" ]]                       && ok "happy path removes tracking file" || no "happy path should remove tracking file"
[[ -f "$SB/home/.claude/auto-skill/pending.log" ]] \
    && ok "pending.log lands in sandbox HOME (not real ~)" \
    || no "pending.log should land in sandbox HOME"

# Reset path (cooldown) deletes ONLY the intended tracking file: the per-session
# SUGGESTED marker and an unrelated sibling tracking file must survive.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID"); SG=$(suggested_file "$SID")
gen_sid; OTHER="$GEN_SID"; DEC=$(track_file "$OTHER")
write_track "$TF" Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
printf 'cooldown-marker\n' > "$SG"
printf 'decoy\n'            > "$DEC"
out="$(run_eval "$SID")"
[[ -z "$out" ]]  && ok "cooldown -> silent"             || no "cooldown should be silent"
[[ ! -f "$TF" ]] && ok "cooldown removes tracking file" || no "cooldown should remove tracking file"
[[  -f "$SG" ]]  && ok "cooldown keeps SUGGESTED marker" || no "cooldown must not delete SUGGESTED marker"
[[  -f "$DEC" ]] && ok "cooldown keeps sibling file"     || no "cooldown must not delete sibling tracking file"

# Reset path (global disable): removes tracking file, no output, no pending.log.
gen_sid; SID="$GEN_SID"; TF=$(track_file "$SID")
write_track "$TF" Edit Edit Edit Write Write Bash Bash NotebookEdit MultiEdit
mkdir -p "$SB/home/.claude"; touch "$SB/home/.claude/auto-skill.disable"
LOG_BEFORE="$(wc -l < "$SB/home/.claude/auto-skill/pending.log" 2>/dev/null || echo 0)"
out="$(run_eval "$SID")"
[[ -z "$out" ]]  && ok "disabled -> silent"             || no "disabled should be silent"
[[ ! -f "$TF" ]] && ok "disabled removes tracking file" || no "disabled should remove tracking file"
LOG_AFTER="$(wc -l < "$SB/home/.claude/auto-skill/pending.log" 2>/dev/null || echo 0)"
[[ "$LOG_AFTER" == "$LOG_BEFORE" ]] && ok "disabled writes no pending.log line" \
                                    || no "disabled must not append pending.log"
rm -f "$SB/home/.claude/auto-skill.disable"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
