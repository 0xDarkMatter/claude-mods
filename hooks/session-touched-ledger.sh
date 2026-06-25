#!/bin/bash
# hooks/session-touched-ledger.sh
# PostToolUse(Edit|Write) — record the files THIS session has written, so the pre-write peer-guard
# (hooks/pre-write-peer-guard.sh) can tell my own edits apart from a peer session's. Silent, never
# blocks, exit 0 always. Companion: pre-write-peer-guard.sh. See rules/worktree-boundaries.md.
#
# Ledger: $HOME/.claude/.session-touched/<session_id>.list (one absolute file path per line).
# Pruned opportunistically (files >2 days old) on the first write of each new session.

set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$SID" ] && [ -n "$FP" ] || exit 0

DIR="$HOME/.claude/.session-touched"
LEDGER="$DIR/$SID.list"
mkdir -p "$DIR" 2>/dev/null || exit 0
# First write of this session → prune stale ledgers from old sessions.
[ -f "$LEDGER" ] || find "$DIR" -type f -mtime +2 -delete 2>/dev/null || true
printf '%s\n' "$FP" >> "$LEDGER" 2>/dev/null || true
exit 0
