# Claude Code Extension Architecture

A comprehensive guide to Claude Code's extension system - how components work together, their authority levels, and when to use each.

---

## Overview

Claude Code provides a layered extension system that allows customization at multiple levels:

| Component | Purpose | Scope | Loaded When |
|-----------|---------|-------|-------------|
| **CLAUDE.md** | Memory & instructions | Global/Project | Always (system prompt) |
| **AGENTS.md** | Cross-platform agent instructions | Project | Always (user message) |
| **Rules** | Modular, topic-specific instructions | Project/User | Always or path-conditional |
| **Skills** | Dynamic capability packages | Project/User | On-demand when relevant |
| **Agents** | Specialized subagent prompts | Project/User | When spawned via Task tool |
| **Commands** | Custom slash commands | Project/User | When invoked by user |
| **Output Styles** | Response personality | Project/User | When selected |
| **Hooks** | Lifecycle shell scripts | Project/User | At specific events |

---

## 1. CLAUDE.md (Memory)

### Overview

CLAUDE.md is Claude Code's primary memory system - a markdown file containing persistent instructions that Claude reads at the start of every conversation. It's the "constitution" for how Claude should behave in your project.

### Benefits

- **Persistent context**: Instructions survive across sessions
- **Team sharing**: Commit to git for consistent team behavior
- **Hierarchical**: Global, project, and local layers
- **Imports**: Reference other files with `@path/to/file` syntax

### Authority & Loading

| Location | Priority | Shared |
|----------|----------|--------|
| Enterprise policy (`/Library/Application Support/ClaudeCode/CLAUDE.md`) | Highest | All org users |
| User global (`~/.claude/CLAUDE.md`) | Medium | Just you |
| Project (`./.claude/CLAUDE.md` or `./CLAUDE.md`) | High | Team via git |
| Project local (`./CLAUDE.local.md`) | Highest | Just you |

Claude reads memories **recursively** from cwd up to root, merging all found files.

### Example

```markdown
# Project Instructions

## Build Commands
- `npm run dev` - Start development server
- `npm test` - Run test suite

## Code Style
- Use TypeScript strict mode
- Prefer functional components with hooks
- All API endpoints must validate input

## Architecture
See @docs/architecture.md for system overview.
```

### References

- [Manage Claude's memory](https://code.claude.com/docs/en/memory) - Official documentation
- [Writing a good CLAUDE.md](https://www.humanlayer.dev/blog/writing-a-good-claude-md) - Best practices guide

---

## 2. AGENTS.md

### Overview

AGENTS.md is a cross-platform standard for agent instructions, supported by Claude Code, Cursor, Codex, and other AI coding tools. While Claude Code uses CLAUDE.md natively, AGENTS.md provides compatibility when collaborating with developers using different tools.

### Benefits

- **Cross-platform**: Works with Claude Code, Cursor, Codex, Amp, and others
- **Team collaboration**: Developers with different AI tools can share context
- **Standardized format**: Community-driven specification at [agents.md](https://agents.md)
- **Fallback**: Claude Code reads AGENTS.md if CLAUDE.md is absent

### Authority & Loading

AGENTS.md is loaded as a user message (not system prompt), giving it slightly lower authority than CLAUDE.md but still high priority in context.

### Example

```markdown
# Agent Instructions

## Project Overview
This is a Next.js 14 application with App Router.

## Key Directories
- `src/app/` - Route handlers and pages
- `src/components/` - React components
- `src/lib/` - Utility functions

## Conventions
- Use server components by default
- Client components must be marked with 'use client'
- All database queries go through Prisma
```

### When to Use

| Scenario | Use |
|----------|-----|
| Claude Code only team | CLAUDE.md |
| Mixed AI tools team | AGENTS.md (or both) |
| Open source project | AGENTS.md for broader compatibility |

### References

- [AGENTS.md Specification](https://agents.md) - Official standard
- [GitHub Issue #6235](https://github.com/anthropics/claude-code/issues/6235) - Claude Code support discussion

---

## 3. Rules

### Overview

Rules are modular markdown files in `.claude/rules/` that provide topic-specific instructions. They allow you to organize instructions by concern rather than having one monolithic CLAUDE.md file.

### Benefits

- **Modular**: Separate files for different concerns (testing, security, API design)
- **Path-conditional**: Apply rules only to specific file patterns
- **Organized**: Subdirectories for grouping (frontend/, backend/)
- **Symlinks**: Share rules across projects

### Authority & Loading

All `.md` files in `.claude/rules/` are automatically loaded with the same priority as `.claude/CLAUDE.md`. User-level rules in `~/.claude/rules/` load before project rules (project takes precedence).

### Example

**`.claude/rules/testing.md`** - Unconditional rule:
```markdown
# Testing Conventions

- All new features require tests
- Use vitest for unit tests
- Use playwright for E2E tests
- Aim for 80% coverage on critical paths
```

**`.claude/rules/api-routes.md`** - Path-conditional rule:
```yaml
---
paths: src/app/api/**/*.ts
---

# API Route Rules

- All endpoints must validate request body with zod
- Return consistent error format: { error: string, code: number }
- Log all errors with request ID for tracing
```

### Directory Structure

```
.claude/rules/
├── frontend/
│   ├── react.md
│   └── styles.md
├── backend/
│   ├── api.md
│   └── database.md
├── testing.md
└── security.md
```

### References

- [Manage Claude's memory](https://code.claude.com/docs/en/memory) - Rules section
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)

---

## 4. Skills

### Overview

Skills are structured capability packages that Claude can discover and load dynamically. Unlike always-loaded rules, skills are loaded on-demand when relevant to the current task, providing unbounded extensibility without consuming context unnecessarily.

### Benefits

- **Progressive disclosure**: Metadata always loaded, full content on-demand
- **Unbounded size**: Can include extensive references, scripts, templates
- **Organized**: Each skill is a self-contained directory
- **Triggers**: Natural language descriptions help Claude recognize when to use them

### Authority & Loading

Skills use a three-tier loading system:

1. **Level 1**: Name and description in system prompt (always)
2. **Level 2**: Full SKILL.md loaded when task matches
3. **Level 3+**: Referenced files loaded as needed

### Structure

```
skills/
└── my-skill/
    ├── SKILL.md              # Required: main instructions
    ├── references/           # Optional: detailed docs
    │   ├── patterns.md
    │   └── examples.md
    ├── assets/               # Optional: templates, configs
    │   └── template.ts
    └── scripts/              # Optional: executable scripts
        └── scaffold.sh
```

### Example

**`skills/testing-patterns/SKILL.md`**:
```yaml
---
name: testing-patterns
description: Test architecture, mocking strategies, and coverage patterns. Triggers on: write tests, test strategy, mocking, fixtures, coverage.
---

# Testing Patterns

## When to Use
- User asks to write or improve tests
- Discussing test architecture
- Setting up test infrastructure

## Quick Reference
- Unit tests: `vitest` with `@testing-library/react`
- E2E tests: `playwright`
- Mocking: `vi.mock()` for modules, `msw` for API

## Detailed Patterns
See @references/mocking-strategies.md for advanced mocking.
See @references/fixtures.md for test data patterns.
```

### References

- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) - Anthropic blog
- [Claude Code Skills Documentation](https://code.claude.com/docs/en/skills)

---

## 5. Agents (Subagents)

### Overview

Agents are specialized system prompts that Claude can spawn as subagents via the Task tool. Each agent runs in its own context with specific expertise, tool permissions, and instructions - ideal for domain-specific tasks that benefit from focused context.

### Benefits

- **Specialized expertise**: Deep knowledge in specific domains
- **Isolated context**: Separate context window, doesn't pollute main conversation
- **Tool restrictions**: Can limit which tools the agent can use
- **Parallel execution**: Multiple agents can run simultaneously

### Authority & Loading

Agents are loaded when spawned via the Task tool with a specific `subagent_type`. They receive their own system prompt and run independently, returning results to the main conversation.

### Structure

Agents are markdown files in `agents/` or `.claude/agents/`:

```yaml
---
name: react-expert
description: Expert in React hooks, state management, and performance
model: sonnet
---

# React Expert

You are a React expert specializing in modern React patterns...

## Core Expertise
- Hooks and custom hooks
- State management (Context, Zustand, Jotai)
- Performance optimization
- Server Components

## Patterns
[Detailed patterns and examples...]
```

### Example Usage

When Claude encounters a React-specific question, it can spawn the react-expert:

```
User: "How should I optimize this component that re-renders too often?"

Claude: I'll consult the react-expert agent for specialized guidance.
[Uses Task tool with subagent_type="react-expert"]
```

### References

- [Claude Code Subagents](https://code.claude.com/docs/en/sub-agents)
- [Practical guide to mastering Claude Code's main agent and Sub-agents](https://jewelhuq.medium.com/practical-guide-to-mastering-claude-codes-main-agent-and-sub-agents-fd52952dcf00)

---

## 6. Commands (Slash Commands)

### Overview

Slash commands are user-invoked shortcuts that expand into prompts. They provide quick access to common workflows, complex multi-step operations, or standardized procedures.

### Benefits

- **Workflow shortcuts**: One command triggers complex sequences
- **Standardized procedures**: Ensure consistent execution of common tasks
- **Arguments**: Accept `$ARGUMENTS` for dynamic behavior
- **Natural language**: Written in plain markdown

### Authority & Loading

Commands are loaded from `.claude/commands/` (project) or `~/.claude/commands/` (user). They're invoked by the user with `/command-name` and expand into the full prompt.

### Structure

```
.claude/commands/
├── review.md      # /review - Code review workflow
├── testgen.md     # /testgen - Generate tests
└── deploy.md      # /deploy - Deployment checklist
```

### Example

**`.claude/commands/review.md`**:
```markdown
---
name: review
description: Review code for bugs, security, and style
---

# Code Review

Review the following code or staged changes for:

1. **Bugs**: Logic errors, edge cases, null checks
2. **Security**: Input validation, injection risks, auth issues
3. **Performance**: N+1 queries, unnecessary re-renders
4. **Style**: Naming, consistency with codebase conventions

$ARGUMENTS

Provide findings in order of severity (critical → minor).
```

**Usage**:
```
/review src/api/auth.ts
```

### References

- [Claude Code Slash Commands Reference](https://firstprinciplescg.com/resources/claude-code-slash-commands-the-complete-reference-guide/)
- [Production-ready slash commands](https://github.com/wshobson/commands)

---

## 7. Output Styles

### Overview

Output styles modify Claude Code's system prompt to change its "personality" while keeping all tools intact. The behavior depends on the `keep-coding-instructions` frontmatter setting.

### Benefits

- **Personality customization**: Change communication style and persona
- **Tools preserved**: File operations, search, MCP integrations all work
- **Flexible modes**: Full replacement OR additive personality layer
- **Persistent**: Selection saved per-project

### Authority & Loading

Output styles modify the system prompt in two modes:

| Mode | `keep-coding-instructions` | Behavior |
|------|---------------------------|----------|
| **Replacement** | `false` (default) | Removes coding instructions, custom style takes over completely. Use for non-coding personas. |
| **Additive** | `true` | Preserves coding instructions, adds personality layer on top. Use for coding with personality. |

In both modes, all tools remain available.

### Structure

```yaml
---
name: Vesper
description: Sophisticated engineering companion with British wit
keep-coding-instructions: true
---

# Vesper

You are Vesper - a polymath engineer with dry wit and intellectual depth...

## Personality
- Quietly confident
- Delightfully direct
- Warm underneath the wit

## Communication Style
- Answer first, then elaborate
- Show, don't pontificate
- Energy matches context
```

### Locations

| Location | Scope |
|----------|-------|
| `~/.claude/output-styles/` | All projects |
| `.claude/output-styles/` | Current project |
| `output-styles/` | Plugin distribution |

### Switching Styles

```
/output-style              # Open picker
/output-style vesper       # Switch directly
```

### References

- [Output Styles Documentation](https://code.claude.com/docs/en/output-styles)
- [Claude Code Output Styles Guide](https://williamcallahan.com/blog/claude-code-output-styles-learning-custom-options)

---

## 8. Hooks

### Overview

Hooks are shell scripts that execute at specific points in Claude Code's lifecycle. Unlike CLAUDE.md (suggestions), hooks provide **deterministic control** - ensuring actions always happen rather than relying on the LLM to choose them.

### Benefits

- **Deterministic**: Always executes, not probabilistic like prompts
- **Lifecycle integration**: Pre/post tool execution, notifications, stop events
- **Automation**: Auto-formatting, linting, logging, notifications
- **Guardrails**: Block dangerous operations, validate outputs

### Authority & Loading

Hooks are configured in `.claude/settings.json` or `.claude/settings.local.json`. They execute as shell commands with access to environment variables containing context about the event.

### Hook Types

| Hook | Trigger | Use Case |
|------|---------|----------|
| `PreToolUse` | Before tool execution | Validate inputs, security checks |
| `PostToolUse` | After tool execution | Format code, run tests, lint |
| `Notification` | On specific events | Alerts, logging, external notifications |
| `Stop` | When Claude stops | Cleanup, summaries, commit reminders |

### Configuration Example

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": ["bash .claude/hooks/validate-command.sh"]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": ["bash .claude/hooks/format-file.sh $FILE_PATH"]
      }
    ]
  }
}
```

### Example Hook Script

**`.claude/hooks/format-file.sh`**:
```bash
#!/bin/bash
FILE="$1"

case "$FILE" in
  *.ts|*.tsx)
    npx prettier --write "$FILE"
    ;;
  *.go)
    gofmt -w "$FILE"
    ;;
  *.py)
    ruff format "$FILE"
    ;;
esac
```

### Best Practices

- **Block at submit, not write**: Let Claude finish its plan, then validate the result
- **Keep hooks fast**: Long-running hooks slow down the workflow
- **Use for enforcement**: Hooks = "must do", CLAUDE.md = "should do"

### References

- [Get started with Claude Code hooks](https://code.claude.com/docs/en/hooks-guide)
- [Claude Code Plugins](https://www.anthropic.com/news/claude-code-plugins) - Hooks section

---

## 9. Plugins

### Overview

Plugins are packaged collections of commands, agents, skills, hooks, and MCP servers that can be installed with a single command. They provide a distribution mechanism for sharing Claude Code extensions.

### Benefits

- **One-command install**: `/plugin install owner/repo`
- **Bundled extensions**: Multiple components in one package
- **Marketplaces**: Discover community plugins
- **Version control**: Track and update plugins

### Structure

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json        # Manifest
├── commands/              # Slash commands
├── agents/                # Subagent definitions
├── skills/                # Skill packages
├── hooks/                 # Hook scripts
└── rules/                 # Rules files
```

### Manifest Example

**`.claude-plugin/plugin.json`**:
```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "My awesome Claude Code extensions",
  "components": {
    "commands": ["commands/review.md"],
    "agents": ["agents/expert.md"],
    "skills": ["skills/patterns"],
    "rules": ["rules/conventions.md"]
  }
}
```

### References

- [Claude Code Plugins](https://www.anthropic.com/news/claude-code-plugins) - Official announcement
- [Plugin Documentation](https://code.claude.com/docs/en/plugins)

---

## Component Hierarchy

Understanding how components interact and override each other:

```
┌─────────────────────────────────────────────────────────────┐
│                    SYSTEM PROMPT                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  Output Style                                       │   │
│   │  - keep-coding-instructions: false → replaces all   │   │
│   │  - keep-coding-instructions: true  → adds on top    │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  Enterprise Policy CLAUDE.md (highest authority)    │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  User ~/.claude/CLAUDE.md                           │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  User ~/.claude/rules/*.md                          │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  Skill metadata (names + descriptions)              │   │
│   └─────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    USER MESSAGES                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  Project .claude/CLAUDE.md                          │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  Project .claude/rules/*.md                         │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  Project AGENTS.md                                  │   │
│   ├─────────────────────────────────────────────────────┤   │
│   │  CLAUDE.local.md (highest project authority)        │   │
│   └─────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    DYNAMIC LOADING                           │
│   Skills (full content) → Agents (on spawn) → Commands      │
├─────────────────────────────────────────────────────────────┤
│                    LIFECYCLE HOOKS                           │
│   PreToolUse → [Tool Execution] → PostToolUse → Stop        │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Reference: When to Use What

| Need | Use | Why |
|------|-----|-----|
| Project-wide instructions | CLAUDE.md | Always loaded, team-shared |
| Cross-platform compatibility | AGENTS.md | Works with Cursor, Codex, etc. |
| Topic-specific rules | `.claude/rules/` | Modular, can be path-conditional |
| Extensive reference material | Skills | Progressive loading, unbounded size |
| Domain expert consultation | Agents | Isolated context, specialized prompts |
| Workflow shortcuts | Commands | User-invoked, argument support |
| Different personality | Output Styles | Complete system prompt replacement |
| Deterministic automation | Hooks | Always runs, not probabilistic |
| Share with community | Plugins | Bundled distribution |

---

## Further Reading

- [Claude Code Documentation](https://code.claude.com/docs)
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [Agent Skills Blog Post](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
