# Skill and Subagent Reference

Quick reference for Claude Code skill and subagent APIs. **Always check official docs first** - this may be outdated.

## Skill Frontmatter Fields (January 2026)

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

## Subagent Options

| Field | Values | Purpose |
|-------|--------|---------|
| `permissionMode` | default, acceptEdits, bypassPermissions | Control autonomy |
| `skills` | [skill-names] | Preload skills in subagent |
| `model` | sonnet, opus, haiku | Override model |

## Decision Framework: Main Context vs Fork

| Question | If Yes → | If No → |
|----------|----------|---------|
| Needs current session state (tasks, conversation)? | Main context | Consider fork |
| Output verbose (>500 lines)? | Consider fork | Main context |
| Needs user interaction during execution? | Main context | Consider fork |
| One-shot research/analysis task? | Fork | Main context |

## Skills Using Subagent Isolation

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
