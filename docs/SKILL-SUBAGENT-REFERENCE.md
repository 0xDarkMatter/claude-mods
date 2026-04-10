# Skill and Subagent Reference

Quick reference for Claude Code skill and subagent APIs. **Always check official docs first** - this may be outdated.

## Skill Frontmatter - Agent Skills Spec

All skills MUST comply with the [Agent Skills specification](https://agentskills.io/specification). This is an open standard backed by Anthropic, Vercel, Google, Microsoft, and 40+ agent platforms.

### Allowed Top-Level Fields

Only these fields are permitted at the top level of SKILL.md frontmatter:

```yaml
---
name: skill-name                    # Required: kebab-case, 1-64 chars, must match directory name
description: "Triggers on: ..."     # Required: 1-1024 chars, include trigger keywords
license: MIT                        # Required for claude-mods skills
compatibility: "Python 3.10+..."    # Optional: 1-500 chars, runtime requirements
allowed-tools: "Read Write Bash"    # Optional: space-delimited tool names
metadata:                           # Optional: arbitrary key-value map
  author: claude-mods               # Required for claude-mods skills
  related-skills: "skill-a, skill-b"  # Comma-separated string (NOT array)
  depends-on: "skill-c"             # Comma-separated string (NOT array)
---
```

**Everything else goes in `metadata:`**. No other top-level keys are permitted.

### Non-Standard Fields - Where They Go

| Field | Location | Format |
|-------|----------|--------|
| `related-skills` | `metadata.related-skills` | Comma-separated string |
| `depends-on` | `metadata.depends-on` | Comma-separated string |
| `version` | `metadata.version` | String |
| `category` | `metadata.category` | String |
| `requires` | `metadata.requires` | String |
| `cli-help` | `metadata.cli-help` | String |
| `author` | `metadata.author` | String |

### Rules for claude-mods Skills

1. **`license: MIT`** on every skill (exception: skill-creator has custom license)
2. **`metadata.author: claude-mods`** on every skill
3. **No empty arrays** - if `depends-on` or `related-skills` would be empty, omit them entirely
4. **No arrays in metadata** - use comma-separated strings instead
5. **Directory structure**: every skill must have `scripts/`, `references/`, `assets/` (use `.gitkeep` if empty)

### Validation

```bash
# Quick check: no non-standard top-level keys
for f in skills/*/SKILL.md; do
  awk '/^---$/{n++} n==1 && !/^(name|description|license|compatibility|allowed-tools|metadata|  |---):/' "$f"
done

# Full spec validation (if skills-ref CLI available)
npx skills-ref validate ./skills/<name>
```

### Reference

- Spec: https://agentskills.io/specification
- CLI: https://github.com/vercel-labs/skills
- Directory: https://skills.sh

## Claude Code Skill Fields (Beyond Spec)

These fields are specific to Claude Code's skill loader and are NOT part of the Agent Skills spec. Use only when needed:

```yaml
---
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

| Question | If Yes | If No |
|----------|--------|-------|
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
