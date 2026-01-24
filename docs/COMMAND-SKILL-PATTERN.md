# Command-Skill Pattern

## Overview

Claude Code has two extension concepts:

| Concept | Structure | Invocation | Metadata |
|---------|-----------|------------|----------|
| Command | Single `.md` file | `/command` | Minimal (description) |
| Skill | Directory with `SKILL.md` | `/skillname` or keywords | Rich (allowed-tools, depends-on, triggers) |

Skills get slash-hint discovery via trigger keywords in their description and load on-demand, making them more efficient for complex functionality.

## Architecture: Skills First

Most functionality lives in **skills**, not commands. Only session management and experimental features remain as commands.

```
commands/           # Minimal (3 files)
  sync.md           # Session bootstrap
  save.md           # Session persistence
  canvas.md         # Experimental TUI

skills/             # Everything else (38 directories)
  explain/
    SKILL.md        # Core logic + expert routing
  testgen/
    SKILL.md        # Core logic
    frameworks.md   # Language-specific examples
  review/
    SKILL.md        # Core logic
  spawn/
    SKILL.md        # Agent generation
  atomise/
    SKILL.md        # AoT reasoning
  setperms/
    SKILL.md        # Tool permissions
  introspect/
    SKILL.md        # Session log analysis
  ...
```

## Skill Structure

### SKILL.md

```yaml
---
name: explain
description: "Deep explanation of complex code. Triggers on: explain, deep dive, how does X work, architecture."
allowed-tools: "Read Glob Grep Bash Task"
compatibility: "Uses ast-grep, tokei if available."
depends-on: []
related-skills: ["structural-search", "code-stats"]
---

# Skill Name

[Core logic, execution steps, patterns]
```

### Optional Reference Files

```
skills/testgen/
  SKILL.md              # Core logic
  frameworks.md         # Go, Rust, Python, TS examples (loaded on demand)
  visual-testing.md     # Chrome DevTools integration (loaded on demand)
```

## Benefits

1. **Context efficiency** - Skills load on-demand via trigger keywords
2. **Rich metadata** - `allowed-tools`, `depends-on`, `related-skills`
3. **Slash discovery** - Trigger keywords enable `/skillname` hints
4. **Scalability** - Add reference files without bloating core
5. **Maintainability** - Focused files, clear structure

## When to Use Commands

| Scenario | Use |
|----------|-----|
| Session management | Command (sync, save) |
| Experimental/WIP | Command (canvas) |
| Everything else | Skill |

## When to Use Skills

| Scenario | Use |
|----------|-----|
| Needs trigger-based discovery | Skill |
| Needs explicit tool permissions | Skill |
| Needs reference files | Skill |
| Needs dependency tracking | Skill |
| Complex multi-step workflow | Skill |

## Skill Invocation

Skills can be invoked multiple ways:

1. **Direct slash**: `/explain`, `/testgen`, `/review`
2. **Trigger keywords**: "explain this code", "generate tests", "review changes"
3. **Skill tool**: Explicit `Skill tool` invocation with args

## Current Skills (Converted from Commands)

| Skill | Purpose | Trigger Keywords |
|-------|---------|------------------|
| `explain` | Deep code explanation | explain, deep dive, how does X work |
| `spawn` | Agent generation | spawn agent, create agent, new expert |
| `atomise` | AoT reasoning | atomise, complex reasoning, decompose |
| `setperms` | Tool permissions | setperms, init tools, setup project |
| `introspect` | Session log analysis | introspect, session history, what did we do |
| `review` | Code review | code review, review changes, check code |
| `testgen` | Test generation | generate tests, write tests, add coverage |

## Creating New Skills

1. Create `skills/{name}/` directory
2. Create `SKILL.md` with proper frontmatter:
   - `name`: kebab-case, matches directory
   - `description`: Include trigger keywords
   - `allowed-tools`: Space-separated list
3. Add optional reference files as needed
4. Add to `plugin.json` under `components.skills`

## Migration from Commands

If you have a command that should be a skill:

1. Create `skills/{name}/SKILL.md`
2. Move content, add frontmatter with triggers
3. Delete `commands/{name}.md`
4. Update `plugin.json`:
   - Remove from `components.commands`
   - Add to `components.skills`
