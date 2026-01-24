# Skill and Agent Updates

## Mandatory Documentation Check

**BEFORE creating or updating any skill or agent**, always check the official Claude Code documentation:

| Resource | URL | Check For |
|----------|-----|-----------|
| Skills | https://code.claude.com/docs/en/skills | New frontmatter fields, context options |
| Sub-agents | https://code.claude.com/docs/en/sub-agents | Permission modes, built-in agents |

These docs change frequently. Features we should watch for:

## Current Skill Frontmatter Fields (January 2026)

```yaml
---
name: skill-name                    # Required: kebab-case
description: "Triggers on: ..."     # Required: include trigger keywords
allowed-tools: "Read Write Bash"    # Restrict available tools
disable-model-invocation: false     # true = manual /skill only
user-invocable: true                # false = hide from slash completion
context: main                       # main | fork (subagent isolation)
agent: custom-agent                 # Custom system prompt agent
hooks:
  preToolUse:
    - command: "echo pre"
  postToolUse:
    - command: "echo post"
---
```

## Current Subagent Options

| Field | Values | Purpose |
|-------|--------|---------|
| `permissionMode` | default, acceptEdits, bypassPermissions | Control autonomy |
| `skills` | [skill-names] | Preload skills in subagent |
| `model` | sonnet, opus, haiku | Override model |

## Decision Framework: Main Context vs Fork

| Question | If Yes → | If No → |
|----------|----------|---------|
| Does it need current session state (tasks, conversation)? | Main context | Consider fork |
| Is output verbose (>500 lines)? | Consider fork | Main context |
| Does it need user interaction during execution? | Main context | Consider fork |
| Is it a one-shot research/analysis task? | Fork | Main context |

## Skills Using Subagent Isolation

Skills that delegate to Task agents or use `context: fork`:

| Skill | Method | Why |
|-------|--------|-----|
| `introspect` | Task agent (background) | Session log analysis is verbose |

## Session Commands Analysis

| Command | Context | Rationale |
|---------|---------|-----------|
| `/sync` | Main | Must restore session state (tasks, context) |
| `/save` | Main | Must access current tasks via TaskList |
| `/canvas` | Main | Interactive TUI requires real-time feedback |

These MUST run in main context - subagent isolation would break their core functionality.
