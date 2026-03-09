# Session Analysis Recipes

Deep-dive jq patterns for Claude Code session log analysis. For general JSONL processing patterns, see the `log-ops` skill.

## Session Overview

```bash
SESSION="417ce03a-6fc7-4906-b767-6428338f34c3"
PROJECT="X--Dev-claude-mods"

# Entry type distribution
jq -r '.type' ~/.claude/projects/$PROJECT/$SESSION.jsonl | sort | uniq -c

# Session duration (first to last timestamp)
jq -s '[.[].timestamp // .[].message.timestamp | select(.)] | [min, max] | map(. / 1000 | strftime("%Y-%m-%d %H:%M"))' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl

# Conversation summaries (quick overview)
jq -r 'select(.type == "summary") | .summary' ~/.claude/projects/$PROJECT/$SESSION.jsonl
```

## Tool Usage Statistics

```bash
PROJECT="X--Dev-claude-mods"

# Tool frequency across all sessions
cat ~/.claude/projects/$PROJECT/*.jsonl | \
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' | \
  sort | uniq -c | sort -rn

# Tool frequency for specific session
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl | sort | uniq -c | sort -rn

# Tools with their inputs (sampled)
jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {tool: .name, input: .input}' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl | head -20
```

## Extract Thinking Blocks

```bash
SESSION="417ce03a-6fc7-4906-b767-6428338f34c3"
PROJECT="X--Dev-claude-mods"

# All thinking blocks (reasoning trace)
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "thinking") | .thinking' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl

# Thinking blocks with context (which turn)
jq -r 'select(.type == "assistant") |
  .message.content as $content |
  ($content | map(select(.type == "thinking")) | .[0].thinking) as $thinking |
  ($content | map(select(.type == "text")) | .[0].text | .[0:100]) as $response |
  select($thinking) | "---\nThinking: \($thinking[0:500])...\nResponse: \($response)..."' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl
```

## Error Analysis

```bash
PROJECT="X--Dev-claude-mods"

# Find tool errors across sessions
cat ~/.claude/projects/$PROJECT/*.jsonl | \
  jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") |
    select(.content | test("error|Error|ERROR|failed|Failed|FAILED"; "i")) |
    {tool_id: .tool_use_id, error: .content[0:200]}' 2>/dev/null | head -50

# Count errors by pattern
cat ~/.claude/projects/$PROJECT/*.jsonl | \
  jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | .content' 2>/dev/null | \
  grep -i "error\|failed\|exception" | \
  sed 's/[0-9]\+//g' | sort | uniq -c | sort -rn | head -20
```

## Search Across Sessions

```bash
PROJECT="X--Dev-claude-mods"

# Search user messages
cat ~/.claude/projects/$PROJECT/*.jsonl | \
  jq -r 'select(.type == "user") | .message.content[]? | select(.type == "text") | .text' | \
  grep -i "pattern"

# Search assistant responses
cat ~/.claude/projects/$PROJECT/*.jsonl | \
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' | \
  grep -i "pattern"

# Find sessions mentioning a file
for f in ~/.claude/projects/$PROJECT/*.jsonl; do
  if grep -q "specific-file.ts" "$f"; then
    echo "Found in: $(basename $f)"
  fi
done
```

## Conversation Flow Reconstruction

```bash
SESSION="417ce03a-6fc7-4906-b767-6428338f34c3"
PROJECT="X--Dev-claude-mods"

# Reconstruct conversation (user/assistant turns)
jq -r '
  if .type == "user" then
    .message.content[]? | select(.type == "text") | "USER: \(.text[0:200])"
  elif .type == "assistant" then
    .message.content[]? | select(.type == "text") | "CLAUDE: \(.text[0:200])"
  else empty end
' ~/.claude/projects/$PROJECT/$SESSION.jsonl
```

## Subagent Analysis

```bash
PROJECT="X--Dev-claude-mods"

# List subagent sessions
ls ~/.claude/projects/$PROJECT/agent-*.jsonl 2>/dev/null

# Subagent tool usage
for f in ~/.claude/projects/$PROJECT/agent-*.jsonl; do
  echo "=== $(basename $f) ==="
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$f" | \
    sort | uniq -c | sort -rn | head -5
done
```

## Advanced Analysis

### Token/Cost Estimation

```bash
SESSION="417ce03a-6fc7-4906-b767-6428338f34c3"
PROJECT="X--Dev-claude-mods"

# Rough character count (tokens ~ chars/4)
jq -r '[
  (select(.type == "user") | .message.content[]? | select(.type == "text") | .text | length),
  (select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text | length)
] | add' ~/.claude/projects/$PROJECT/$SESSION.jsonl | \
  awk '{sum+=$1} END {print "Total chars:", sum, "Est tokens:", int(sum/4)}'
```

### File Modification Tracking

```bash
SESSION="417ce03a-6fc7-4906-b767-6428338f34c3"
PROJECT="X--Dev-claude-mods"

# Files edited (Edit tool usage)
jq -r 'select(.type == "assistant") | .message.content[]? |
  select(.type == "tool_use" and .name == "Edit") | .input.file_path' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl | sort | uniq -c | sort -rn

# Files written
jq -r 'select(.type == "assistant") | .message.content[]? |
  select(.type == "tool_use" and .name == "Write") | .input.file_path' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl | sort | uniq
```

### Session Comparison

```bash
PROJECT="X--Dev-claude-mods"
SESSION1="session-id-1"
SESSION2="session-id-2"

# Compare tool usage between sessions
echo "=== Session 1 ===" && \
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
  ~/.claude/projects/$PROJECT/$SESSION1.jsonl | sort | uniq -c | sort -rn

echo "=== Session 2 ===" && \
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
  ~/.claude/projects/$PROJECT/$SESSION2.jsonl | sort | uniq -c | sort -rn
```

## Usage Scenarios

### "What tools did I use most in yesterday's session?"

```bash
# Find yesterday's sessions by modification time
find ~/.claude/projects/X--Dev-claude-mods -name "*.jsonl" -mtime -1 ! -name "agent-*" | \
  xargs -I{} jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' {} | \
  sort | uniq -c | sort -rn
```

### "Show me my reasoning when debugging the auth issue"

```bash
# Search for sessions mentioning auth, then extract thinking
for f in ~/.claude/projects/$PROJECT/*.jsonl; do
  if grep -qi "auth" "$f"; then
    echo "=== $(basename $f) ==="
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "thinking") | .thinking' "$f" | \
      grep -i -A5 -B5 "auth"
  fi
done
```

### "What errors occurred most frequently this week?"

```bash
find ~/.claude/projects/ -name "*.jsonl" -mtime -7 | \
  xargs cat 2>/dev/null | \
  jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | .content' 2>/dev/null | \
  grep -i "error\|failed" | \
  sed 's/[0-9]\+//g' | sed 's/\/[^ ]*//g' | \
  sort | uniq -c | sort -rn | head -10
```

## Export Formats

### Markdown Report

```bash
SESSION="session-id"
PROJECT="X--Dev-claude-mods"

echo "# Session Report: $SESSION"
echo ""
echo "## Summary"
jq -r 'select(.type == "summary") | "- \(.summary)"' ~/.claude/projects/$PROJECT/$SESSION.jsonl
echo ""
echo "## Tool Usage"
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
  ~/.claude/projects/$PROJECT/$SESSION.jsonl | sort | uniq -c | sort -rn | \
  awk '{print "| " $2 " | " $1 " |"}'
```

### JSON Export (for further processing)

```bash
jq -s '{
  session_id: "'$SESSION'",
  entries: length,
  tools: [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name] | group_by(.) | map({tool: .[0], count: length}),
  summaries: [.[] | select(.type == "summary") | .summary]
}' ~/.claude/projects/$PROJECT/$SESSION.jsonl
```

## Privacy Considerations

Session logs contain:
- Full conversation history including any sensitive data discussed
- File contents that were read or written
- Thinking/reasoning (internal deliberation)
- Tool inputs/outputs

**Before sharing session exports:**
1. Review for credentials, API keys, personal data
2. Consider redacting file paths if they reveal project structure
3. Thinking blocks may contain candid assessments
