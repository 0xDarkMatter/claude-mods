---
name: introspect
description: "Analyze Claude Code session logs and surface productivity improvements. Extracts thinking blocks, tool usage stats, error patterns, debug trajectories - then generates friendly, actionable recommendations. Triggers on: introspect, session logs, trajectory, analyze sessions, what went wrong, tool usage, thinking blocks, session history, my reasoning, past sessions, what did I do, how can I improve."
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

Project paths use double-dash encoding: `X:\Forge\claude-mods` -> `X--Forge-claude-mods`

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

## Session Insights

After running any analysis, **always** generate a "Session Insights" section with actionable recommendations. The tone should be friendly and mentoring - a helpful colleague who noticed some patterns, not a critic.

### What to Look For

Scan the session data for these patterns and generate recommendations where relevant:

**Tool usage improvements:**
- Using `Bash(grep ...)` or `Bash(cat ...)` instead of Grep/Read tools - suggest the dedicated tools
- Repeated failed tool calls with same input - suggest pivoting earlier
- Heavy Bash usage for tasks a skill handles - recommend the skill by name
- No use of parallel tool calls when independent reads/searches could overlap

**Workflow patterns:**
- Long sessions with no commits - suggest incremental commits
- No `/save` at session end - remind about session continuity
- Repeated context re-reading (same files read 3+ times) - suggest keeping notes or using `/save`
- Large blocks of manual work that `/iterate` could automate - mention the loop pattern
- Debugging spirals (5+ attempts at same approach) - suggest the 3-attempt pivot rule

**Skill and command awareness:**
- Manual code review without `/review` - mention the skill
- Test writing without `/testgen` - mention the skill
- Complex reasoning without `/atomise` - mention it for hard problems
- Agent spawning for tasks a skill already handles - suggest the lighter-weight option

**Session efficiency:**
- Very long sessions (100+ tool calls) - suggest breaking into focused sessions
- High error rate (>30% of tool calls return errors) - note the pattern and suggest investigation
- Excessive file reads vs edits ratio (>10:1) - might indicate uncertainty, suggest planning first

**Permission recommendations:**
This is high-value - permission prompts break flow and cost context. Scan the session for:
- Bash commands that were used successfully and repeatedly - these are candidates for `Bash(<command>:*)` allow rules
- Tool patterns that appeared frequently (WebFetch, WebSearch, specific MCP tools) - suggest adding to allow list
- Commands that failed with permission errors or were retried - likely blocked by missing permissions

Generate a ready-to-paste `permissions.allow` snippet for `.claude/settings.local.json`:

```
**Permissions**

Based on this session, these tools were used frequently and could be
pre-approved to reduce interruptions:

Add to `.claude/settings.local.json` under `permissions.allow`:
  "Bash(uv:*)",
  "Bash(pytest:*)",
  "Bash(docker:*)",
  "WebSearch",
  "mcp__my-server__*"

This would have saved roughly ~N permission prompts in this session.
```

Only recommend commands that were actually used successfully - never suggest blanket `Bash(*)`. But do encourage wildcard patterns where sensible - `Bash(git:*)` is better than listing `Bash(git status)`, `Bash(git add)`, `Bash(git commit)` separately. Common wildcard groups:

- `Bash(git:*)` - all git operations
- `Bash(npm:*)`, `Bash(pnpm:*)`, `Bash(uv:*)` - package managers
- `Bash(pytest:*)`, `Bash(jest:*)` - test runners
- `Bash(docker:*)`, `Bash(cargo:*)`, `Bash(go:*)` - build/runtime tools
- `mcp__server-name__*` - all tools from an MCP server

Group recommendations by category for clarity. Reference `/setperms` for a full permissions setup if the list is long.

### Output Format

```
## Session Insights

Here are a few things I noticed that might help next time:

**[Category]**
- [Observation]: [What was seen in the data]
- [Suggestion]: [Friendly, specific recommendation]

**[Category]**
- ...
```

Scale the number of recommendations to the session size. A quick 10-minute session might warrant 1-2 observations. A sprawling multi-hour session with 100+ tool calls could easily have 10-15 actionable insights. Match the depth of analysis to the depth of the session.

Only mention patterns that are clearly present in the data - don't guess or stretch. If the session was clean and efficient, say so: "This was a well-structured session - nothing jumps out as needing improvement."

## Reference Files

| File | Contents |
|------|----------|
| `scripts/cc-session` | CLI tool - session analysis with 14 commands, JSON output, project filtering |
| `references/session-analysis.md` | Raw jq recipes for custom analysis beyond cc-session |

## See Also

- **log-ops** - General JSONL processing, two-stage pipelines, cross-file correlation
- **data-processing** - JSON/YAML/TOML processing with jq and yq
