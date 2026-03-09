---
name: introspect
description: "Analyze Claude Code session logs - extract thinking blocks, tool usage stats, error patterns, debug trajectories. Triggers on: introspect, session logs, trajectory, analyze sessions, what went wrong, tool usage, thinking blocks, session history, my reasoning, past sessions, what did I do."
allowed-tools: "Bash Read Grep Glob"
related-skills: [log-ops, data-processing]
---

# Introspect

Extract actionable intelligence from Claude Code session logs. For general JSONL analysis patterns (filtering, aggregation, cross-file joins), see the `log-ops` skill.

## Analysis Decision Tree

```
What do you want to know?
│
├─ "What happened in a session?"
│  ├─ Quick overview ── session summaries (jq select .type == "summary")
│  ├─ Full conversation ── flow reconstruction (user/assistant turns)
│  └─ Timeline ── entry type distribution + timestamps
│
├─ "How was I using tools?"
│  ├─ One session ── tool frequency (jq select tool_use | sort | uniq -c)
│  ├─ All sessions ── cat *.jsonl | same pipeline
│  └─ Which files touched ── filter by Edit/Write tool names
│
├─ "What was I thinking?"
│  ├─ Full reasoning trace ── extract thinking blocks
│  ├─ Reasoning about topic X ── thinking + grep filter
│  └─ Decision points ── thinking blocks with response preview
│
├─ "What went wrong?"
│  ├─ Tool errors ── filter tool_result for error/failed patterns
│  ├─ Error frequency ── group by error pattern, count
│  └─ Debug trajectory ── reconstruct steps leading to failure
│
├─ "Compare sessions"
│  ├─ Tool usage diff ── side-by-side uniq -c
│  └─ Token estimation ── character count / 4
│
└─ "Search across sessions"
   ├─ By keyword ── grep across *.jsonl
   ├─ By file touched ── grep for filename
   └─ By date ── find -mtime filter
```

## Log File Structure

```
~/.claude/
├── history.jsonl                              # Global: all user inputs across projects
├── projects/
│   └── {project-path}/                        # e.g., X--Dev-claude-mods/
│       ├── sessions-index.json                # Session metadata index
│       ├── {session-uuid}.jsonl               # Full session transcript
│       └── agent-{short-id}.jsonl             # Subagent transcripts
```

### Project Path Encoding

Project paths use double-dash encoding: `X:\Dev\claude-mods` -> `X--Dev-claude-mods`

```bash
# Find project directory for current path
project_dir=$(pwd | sed 's/[:\\\/]/-/g' | sed 's/--*/-/g')
ls ~/.claude/projects/ | grep -i "${project_dir##*-}"
```

## Entry Types

| Type | Contains | Key Fields |
|------|----------|------------|
| `user` | User messages | `message.content`, `uuid`, `timestamp` |
| `assistant` | Claude responses | `message.content[]`, `cwd`, `gitBranch` |
| `thinking` | Reasoning blocks | `thinking`, `signature` (in content array) |
| `tool_use` | Tool invocations | `name`, `input`, `id` (in content array) |
| `tool_result` | Tool outputs | `tool_use_id`, `content` |
| `summary` | Conversation summaries | `summary`, `leafUuid` |
| `file-history-snapshot` | File state checkpoints | File contents at point in time |
| `system` | System context | Initial context, rules |

## Quick Reference

| Task | Command Pattern |
|------|-----------------|
| List sessions | `ls -lah ~/.claude/projects/$PROJECT/*.jsonl \| grep -v agent` |
| Entry types | `jq -r '.type' $SESSION.jsonl \| sort \| uniq -c` |
| Tool stats | `jq -r '... \| select(.type == "tool_use") \| .name' \| sort \| uniq -c` |
| Extract thinking | `jq -r '... \| select(.type == "thinking") \| .thinking'` |
| Find errors | `rg -i "error\|failed" $SESSION.jsonl` |
| Session summaries | `jq -r 'select(.type == "summary") \| .summary'` |
| User messages | `jq -r 'select(.type == "user") \| .message.content[]?.text'` |
| Files edited | `jq -r '... \| select(.name == "Edit") \| .input.file_path'` |

## Using lnav for Interactive Exploration

If `lnav` is installed (see `log-ops` prerequisites), it provides SQL-based interactive exploration of session logs:

```bash
# Open a session in lnav (treats JSONL as structured log)
lnav ~/.claude/projects/$PROJECT/$SESSION.jsonl

# SQL query inside lnav: count tool usage
;SELECT json_extract(log_body, '$.message.content[0].name') as tool,
        count(*) as n
 FROM all_logs
 WHERE json_extract(log_body, '$.type') = 'assistant'
 GROUP BY tool ORDER BY n DESC
```

> For large session files (>50MB), use the two-stage rg+jq pipeline from `log-ops` rather than loading everything into jq with `-s`.

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/session-analysis.md` | Full jq recipes: session overview, tool stats, thinking extraction, error analysis, search, flow reconstruction, subagent analysis, exports | ~230 |

## See Also

- **log-ops** - General JSONL processing, two-stage pipelines, cross-file correlation, large file strategies
- **data-processing** - JSON/YAML/TOML processing with jq and yq
