#!/bin/bash
# hooks/pre-write-peer-guard.sh
# PreToolUse(Edit|Write) — mid-session peer-writer guard (the real fix: collisions happen *during* a
# session, not just at boot). Before I write a file, warn if that file was JUST modified by something
# that isn't me this session — the signature of a live peer Claude session sharing this checkout.
#
# Fires only when ALL hold for the target file:
#   • it exists and is inside a git repo
#   • git sees it as modified/untracked (dirty)
#   • it was written in the last $THRESHOLD seconds (fresh — stale WIP is ignored)
#   • it is NOT in this session's touched-ledger (companion hooks/session-touched-ledger.sh)
#
# Advisory by default (exit 0 + additionalContext → fed to the model, does NOT block the write).
# Set GUARD_BLOCK=1 to DENY the write instead. Never crashes the tool call. See worktree-boundaries.md.

set -uo pipefail

THRESHOLD=120   # seconds — "freshly modified" window

INPUT=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
FP=$(printf '%s'  "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FP" ] || exit 0
[ -f "$FP" ] || exit 0   # new file → nothing to collide with yet

DIR=$(dirname "$FP")
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0   # not a repo → skip
[ -n "$(git -C "$DIR" status --porcelain -- "$FP" 2>/dev/null)" ] || exit 0   # clean → no peer edit

NOW=$(date +%s)
M=$(stat -c %Y "$FP" 2>/dev/null || stat -f %m "$FP" 2>/dev/null)
[ -n "${M:-}" ] || exit 0
AGE=$(( NOW - M ))
[ "$AGE" -lt "$THRESHOLD" ] || exit 0   # stale dirty (likely my own old WIP) → don't nag

# Did I touch this file this session? Then it's mine → allow silently.
LEDGER="$HOME/.claude/.session-touched/${SID}.list"
if [ -n "$SID" ] && [ -f "$LEDGER" ] && grep -Fqx "$FP" "$LEDGER" 2>/dev/null; then
  exit 0
fi

# Dirty + fresh + not mine → a peer session likely just edited this file.
MSG="PEER-WRITE ADVISORY: ${FP} was modified ${AGE}s ago and is not in your edit history this session"
MSG="${MSG} — another Claude session may be editing this same checkout. RE-READ the file before writing"
MSG="${MSG} (your old_string may be stale and you could clobber its work). If a peer is live, move your"
MSG="${MSG} work to a separate worktree (git worktree add ../<dir> -b <branch>). See rules/worktree-boundaries.md."

if [ "${GUARD_BLOCK:-0}" = "1" ]; then
  jq -n --arg r "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -n --arg c "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi
exit 0
