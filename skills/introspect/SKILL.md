---
name: introspect
description: "Analyze Claude Code session logs - extract thinking blocks, tool usage stats, error patterns, debug trajectories. Triggers on: introspect, session logs, trajectory, analyze sessions, what went wrong, tool usage, thinking blocks, session history, my reasoning, past sessions, what did I do."
allowed-tools: "Bash Read Grep Glob"
related-skills: [log-ops, data-processing]
---

# Introspect

Extract actionable intelligence from Claude Code session logs. For general JSONL analysis patterns (filtering, aggregation, cross-file joins), see the `log-ops` skill.

## cc-session CLI

The `scripts/cc-session` script provides zero-dependency analysis (requires only jq + bash). Auto-resolves the current project and most recent session.

```bash
# Copy to PATH for global access
cp skills/introspect/scripts/cc-session ~/.local/bin/
# Or on Windows (Git Bash)
cp skills/introspect/scripts/cc-session ~/bin/
```

### Commands

| Command | What It Does |
|---------|-------------|
| `cc-session overview` | Entry counts, timing, tool/thinking totals |
| `cc-session tools` | Tool usage frequency (sorted) |
| `cc-session tool-chain` | Sequential tool call trace with input summaries |
| `cc-session thinking` | Full thinking/reasoning blocks |
| `cc-session thinking-summary` | First 200 chars of each thinking block |
| `cc-session errors` | Tool results containing error patterns |
| `cc-session conversation` | Reconstructed user/assistant turns |
| `cc-session files` | Files read, edited, written (with counts) |
| `cc-session turns` | Per-turn breakdown (duration, tools used) |
| `cc-session agents` | Subagent spawns with type and prompt preview |
| `cc-session cost` | Rough token/cost estimation |
| `cc-session timeline` | Event timeline with timestamps |
| `cc-session summary` | Session summaries (compaction boundaries) |
| `cc-session search <pattern>` | Search across sessions (text content) |

### Options

```
--project, -p <name>    Filter by project (partial match)
--dir, -d <pattern>     Filter by directory pattern in project path
--all                   Search all projects (with search command)
--recent <n>            Use nth most recent session (default: 1)
--json                  Output as JSON instead of text
```

### Examples

```bash
cc-session overview                              # Current project, latest session
cc-session tools --recent 2                      # Tools from second-latest session
cc-session tool-chain                            # Full tool call sequence
cc-session errors -p claude-mods                 # Errors in claude-mods project
cc-session thinking | grep -i "decision"         # Search reasoning
cc-session search "auth" --all                   # Search all projects
cc-session turns --json | jq '.[] | select(.tools > 5)'  # Complex turns
cc-session files --json | jq '.edited[:5]'       # Top 5 edited files
cc-session overview --json                       # Pipe to other tools
```

## Analysis Decision Tree

```
What do you want to know?
|
|- "What happened in a session?"
|  |- Quick overview ---- cc-session overview
|  |- Full conversation -- cc-session conversation
|  |- Timeline ---------- cc-session timeline
|  |- Summaries --------- cc-session summary
|
|- "How was I using tools?"
|  |- Frequency ---------- cc-session tools
|  |- Call sequence ------- cc-session tool-chain
|  |- Files touched ------- cc-session files
|
|- "What was I thinking?"
|  |- Full reasoning ------ cc-session thinking
|  |- Quick scan ---------- cc-session thinking-summary
|  |- Topic search -------- cc-session thinking | grep -i "topic"
|
|- "What went wrong?"
|  |- Tool errors --------- cc-session errors
|  |- Debug trajectory ---- cc-session tool-chain (trace the sequence)
|
|- "Compare sessions"
|  |- Tool usage diff ----- cc-session tools --recent 1 vs --recent 2
|  |- Token estimation ---- cc-session cost
|
|- "Search across sessions"
|  |- Current project ----- cc-session search "pattern"
|  |- All projects -------- cc-session search "pattern" --all
```

## Session Log Schema

### File Structure

```
~/.claude/
|- projects/
|   |- {project-path}/                        # e.g., X--Forge-claude-mods/
|       |- sessions-index.json                # Session metadata index
|       |- {session-uuid}.jsonl               # Full session transcript
|       |- agent-{short-id}.jsonl             # Subagent transcripts
```

Project paths use double-dash encoding: `C:\Projects\claude-mods` -> `X--Forge-claude-mods`

### Entry Types

| Type | Role | Key Fields |
|------|------|------------|
| `user` | User messages + tool results | `message.content[].type` = "text" or "tool_result" |
| `assistant` | Claude responses | `message.content[].type` = "text", "tool_use", or "thinking" |
| `system` | Turn duration, compaction | `subtype` = "turn_duration" (has `durationMs`) or "compact_boundary" |
| `progress` | Hook/tool progress events | `data.type`, `toolUseID`, `parentToolUseID` |
| `file-history-snapshot` | File state checkpoints | `snapshot`, `messageId`, `isSnapshotUpdate` |
| `queue-operation` | Message queue events | `operation`, `content` |
| `last-prompt` | Last user prompt cache | `lastPrompt` |
| `summary` | Compaction summaries | `summary`, `leafUuid` |

### Content Block Types (inside message.content[])

| Block Type | Found In | Fields |
|-----------|----------|--------|
| `text` | user, assistant | `.text` |
| `tool_use` | assistant | `.id`, `.name`, `.input` |
| `tool_result` | user | `.tool_use_id`, `.content` |
| `thinking` | assistant | `.thinking`, `.signature` |

### Common Fields (all entry types)

```
uuid, parentUuid, sessionId, timestamp, type,
cwd, gitBranch, version, isSidechain, userType
```

## Session Log Retention

By default, Claude Code deletes sessions inactive for 30 days (on startup). Increase to preserve history for analysis.

```json
// ~/.claude/settings.json
{
  "cleanupPeriodDays": 90
}
```

Currently set to 90 days. Adjust based on disk usage (`dust -d 1 ~/.claude/projects/`).

## Quick jq Reference

For one-off queries when cc-session doesn't cover your need:

```bash
# Pipe through cat on Windows (jq file args can fail)
cat session.jsonl | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name'

# Two-stage for large files
rg '"tool_use"' session.jsonl | jq -r '.message.content[]? | select(.type == "tool_use") | .name'
```

## Reference Files

| File | Contents |
|------|----------|
| `scripts/cc-session` | CLI tool - session analysis with 14 commands, JSON output, project filtering |
| `references/session-analysis.md` | Raw jq recipes for custom analysis beyond cc-session |

## See Also

- **log-ops** - General JSONL processing, two-stage pipelines, cross-file correlation
- **data-processing** - JSON/YAML/TOML processing with jq and yq
