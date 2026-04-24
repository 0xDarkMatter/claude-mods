#!/bin/bash
# evaluate.sh - Stop hook: evaluate session for skill-worthy workflows
#
# Suggests skill creation only when a session shows genuine workflow complexity:
#   - 8+ mutating tool calls (high threshold, reduces noise)
#   - 4+ distinct mutating tool types (diversity = workflow, not repetitive edits)
#   - No non-harness skill was loaded (novel work, not following a recipe).
#     Harness skills (sync, save, introspect, auto-skill, setperms, tool-discovery)
#     are whitelisted — they're meta/bootstrap, not domain-specific, so loading
#     them shouldn't disqualify an otherwise novel session.
#   - Per-session cooldown file prevents re-fire on resume
#
# Output channels (when a suggestion fires):
#   1. systemMessage JSON on stdout - visible to Claude on next turn
#   2. Appended line to ~/.claude/auto-skill/pending.log - visible to user
#      at next /sync (since Claude's systemMessage often dies silently if
#      the user's next prompt doesn't invite it to be mentioned).
#
# Toggle: touch ~/.claude/auto-skill.disable   (global off)
#         touch .claude/auto-skill.disable      (project off)
#         rm either file to re-enable
#
# CRITICAL: This hook must NEVER fail visibly. All errors suppressed.

{
  INPUT=$(cat)
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

  [ -z "$SESSION_ID" ] && exit 0

  SHORT_ID="${SESSION_ID:0:8}"
  TRACK_FILE="/tmp/claude_autoskill_${SHORT_ID}"

  # No tracking file = no tool calls recorded
  [ -f "$TRACK_FILE" ] || exit 0

  # --- Toggle: global or project disable ---
  if [ -f "$HOME/.claude/auto-skill.disable" ] || [ -f ".claude/auto-skill.disable" ]; then
    rm -f "$TRACK_FILE"
    exit 0
  fi

  # --- Per-session cooldown: only suggest once per session ---
  SUGGESTED_FILE="/tmp/claude_autoskill_suggested_${SHORT_ID}"
  if [ -f "$SUGGESTED_FILE" ]; then
    rm -f "$TRACK_FILE"
    exit 0
  fi

  # --- Classify tools ---
  READ_ONLY_LIST=" Read Glob Grep LS NotebookRead TaskList TaskGet TaskCreate TaskUpdate TaskOutput TaskStop "
  # Harness skills: loading these should NOT disqualify a session
  HARNESS_SKILLS=" sync save introspect auto-skill setperms tool-discovery "
  SKILL_LOADED=false
  TOTAL=0
  WRITES=0
  UNIQUE_TYPES=""

  while IFS= read -r tool; do
    [ -z "$tool" ] && continue
    TOTAL=$((TOTAL + 1))

    # Handle Skill tool (tagged as "Skill:<name>" by track-tools.sh, or bare
    # "Skill" from pre-whitelist versions)
    case "$tool" in
      Skill:*)
        skill_name="${tool#Skill:}"
        # Is it a harness skill? If so, ignore entirely.
        case "$HARNESS_SKILLS" in
          *" ${skill_name} "*) continue ;;
          *) SKILL_LOADED=true; continue ;;
        esac
        ;;
      Skill)
        # Legacy format (pre-whitelist): conservatively disqualify
        SKILL_LOADED=true
        continue
        ;;
    esac

    # Check if read-only (space-padded list for exact word match)
    case "$READ_ONLY_LIST" in
      *" ${tool} "*) continue ;;
    esac

    WRITES=$((WRITES + 1))

    # Track unique mutating tool types
    case " $UNIQUE_TYPES " in
      *" ${tool} "*) ;;  # already seen
      *) UNIQUE_TYPES="${UNIQUE_TYPES} ${tool}" ;;
    esac
  done < "$TRACK_FILE"

  # Count unique types (count words in UNIQUE_TYPES)
  UNIQUE_COUNT=0
  for _ in $UNIQUE_TYPES; do
    UNIQUE_COUNT=$((UNIQUE_COUNT + 1))
  done

  # Build tool summary before cleanup
  TOOL_SUMMARY=$(sort "$TRACK_FILE" | uniq -c | sort -rn | head -6 | awk '{printf "%s(%d) ", $2, $1}')

  # Clean up tracking file
  rm -f "$TRACK_FILE"

  # --- Gate 1: Non-harness skill was loaded = following a recipe, not novel ---
  [ "$SKILL_LOADED" = true ] && exit 0

  # --- Gate 2: Minimum 8 mutating operations ---
  [ "$WRITES" -lt 8 ] && exit 0

  # --- Gate 3: Minimum 4 distinct mutating tool types ---
  [ "$UNIQUE_COUNT" -lt 4 ] && exit 0

  # --- All gates passed: suggest ---

  # Mark this session as suggested (prevents repeat on resume)
  touch "$SUGGESTED_FILE" 2>/dev/null

  # Append to persistent log so the human can see suggestions at next /sync.
  # systemMessage goes to Claude; this log goes to the user.
  # Format: ISO8601 | session_id | cwd | writes | unique | total | summary
  LOG_DIR="$HOME/.claude/auto-skill"
  LOG_FILE="$LOG_DIR/pending.log"
  mkdir -p "$LOG_DIR" 2>/dev/null
  TS=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
  CWD=$(pwd 2>/dev/null || echo "unknown")
  CLEAN_SUMMARY=$(printf '%s' "$TOOL_SUMMARY" | tr '|' '/' | tr -s ' ')
  printf '%s|%s|%s|%d|%d|%d|%s\n' \
    "$TS" "$SHORT_ID" "$CWD" "$WRITES" "$UNIQUE_COUNT" "$TOTAL" "$CLEAN_SUMMARY" \
    >> "$LOG_FILE" 2>/dev/null

  MSG="Skill-worthy session: ${WRITES} mutating ops across ${UNIQUE_COUNT} tool types (${TOTAL} total): ${TOOL_SUMMARY}- run /auto-skill to capture this workflow."

  ESCAPED=$(printf '%s' "$MSG" | sed 's/"/\\"/g' | tr '\n' ' ')
  printf '{"systemMessage":"%s"}\n' "$ESCAPED"

} 2>/dev/null

exit 0
