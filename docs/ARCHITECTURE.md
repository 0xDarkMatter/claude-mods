# Claude Code Extension Architecture

A comprehensive guide to Claude Code's extension system - how components work together, their authority levels, and when to use each.

---

## Overview

Claude Code provides a layered extension system that allows customization at multiple levels:

| Component | Purpose | Scope | Loaded When |
|-----------|---------|-------|-------------|
| **CLAUDE.md** | Memory & instructions | Global/Project | Always (system prompt) |
| **AGENTS.md** | Cross-platform agent instructions | Project | Only when no CLAUDE.md shadows it, or through an `@AGENTS.md` import |
| **Rules** | Modular, topic-specific instructions | Project/User | Always or path-conditional |
| **Skills** | Dynamic capability packages | Project/User | On-demand when relevant |
| **Agents** | Specialized subagent prompts | Project/User | When spawned via the Agent tool |
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

### Authority

**Level: HIGH (System Prompt)**

CLAUDE.md content is injected into the system prompt, giving it high authority over Claude's behavior. Instructions here are treated as foundational rules that should be followed.

| Location | Authority | Compliance |
|----------|-----------|------------|
| Enterprise policy | Highest | Mandatory - cannot be overridden |
| User global (`~/.claude/CLAUDE.md`) | High | Should follow unless project overrides |
| Project (`.claude/CLAUDE.md`) | High | Primary project instructions |
| Project local (`CLAUDE.local.md`) | High | Personal, uncommitted additions |

Claude reads memories **recursively** from cwd up to root and concatenates them: root to
working directory, `CLAUDE.local.md` after `CLAUDE.md` at each level. The docs give the
load order but no precedence rule, and say Claude "may pick one arbitrarily" when two
instructions conflict, so remove a contradiction rather than rely on order. Any
`CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` here or above also stops Claude Code
reading AGENTS.md (section 2).

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

AGENTS.md is the cross-tool standard for agent instructions ([agents.md](https://agents.md)),
read by Claude Code, Cursor, Codex and others. In this repo's doctrine it is the single
source of truth for a repo's entry doc (`rules/agentic-quality.md`), and CLAUDE.md holds
only Claude-specific deltas.

### Loading: fallback, not override

Claude Code (v2.1.277+) reads AGENTS.md **only as a fallback**: when no `CLAUDE.md`,
`.claude/CLAUDE.md` or `CLAUDE.local.md` sits in the working directory or above it. A
CLAUDE.md doesn't outrank AGENTS.md; it stops AGENTS.md loading at all, and a CLAUDE.md
that mentions AGENTS.md in prose loads nothing. A repo has two portable shapes:

| Shape | Use when |
|-------|----------|
| AGENTS.md and no CLAUDE.md | The default: nothing Claude-specific to say |
| A CLAUDE.md whose first line is `@AGENTS.md`, deltas below | Claude-only behaviour (a hook, plan mode for a path), or sessions too old to read AGENTS.md |

The user-level **Project instructions** setting can load both, but Claude Code ignores
it in project and local settings, so a repo can't rely on it.

### Size

Target 150 lines, ceiling 200 (Claude Code's documented target for instruction files).
`@` imports load at launch, so they don't shrink anything: split into a nested AGENTS.md,
path-scoped `.claude/rules/`, or linked `docs/`.

### References

- `skills/repo-doctor/references/agents-md-protocol.md` - the protocol: contents,
  exclusions, size and split, shadowing landmines, staleness. Its tools scaffold, audit
  and survey AGENTS.md files
- `skills/repo-doctor/assets/AGENTS-template.md` - hand-fill skeleton with the mandatory
  Landmines section
- [How Claude remembers your project](https://code.claude.com/docs/en/memory) - official
  docs, sections "AGENTS.md" and "Choose which instruction files load"

---

## 3. Rules

### Overview

Rules are modular markdown files in `.claude/rules/` that provide topic-specific instructions. They allow you to organize instructions by concern rather than having one monolithic CLAUDE.md file.

### Benefits

- **Modular**: Separate files for different concerns (testing, security, API design)
- **Path-conditional**: Apply rules only to specific file patterns
- **Organized**: Subdirectories for grouping (frontend/, backend/)
- **Symlinks**: Share rules across projects

### Authority

**Level: HIGH (Same as CLAUDE.md)**

All `.md` files in `.claude/rules/` are automatically loaded with the **same priority as `.claude/CLAUDE.md`**. They become part of the instruction set that Claude must follow.

| Location | Authority | Scope |
|----------|-----------|-------|
| `~/.claude/rules/` | High | All your projects |
| `.claude/rules/` | High | Current project |
| Path-conditional rules | High | Only matching files |

User-level rules load before project rules, so project rules can override user preferences.

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
- **Unbounded resources**: References, scripts and templates cost nothing until read. The SKILL.md body itself is bounded: under 500 lines and ~5,000 tokens (the size rule in [SKILL-SUBAGENT-REFERENCE.md](SKILL-SUBAGENT-REFERENCE.md#rules-for-claude-mods-skills))
- **Organized**: Each skill is a self-contained directory
- **Triggers**: Natural language descriptions help Claude recognize when to use them

### Authority

**Level: HIGH (When Loaded)**

Skills use a three-tier loading system with varying authority:

| Tier | Content | Authority | When Loaded |
|------|---------|-----------|-------------|
| **Tier 1** | Name + description | Medium | Always (system prompt metadata) |
| **Tier 2** | Full SKILL.md | High | When task matches triggers |
| **Tier 3** | Referenced files | High | When explicitly needed |

**Key insight**: When a skill is loaded, its content becomes part of the agent's instructions. Unlike agent outputs which are advisory, **skill content is treated as authoritative guidance that must be followed**.

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

**`skills/testing-ops/SKILL.md`**:
```yaml
---
name: testing-ops
description: Test architecture, mocking strategies, and coverage patterns. Use when writing or improving tests, designing test infrastructure, or choosing a mocking strategy.
---

# Testing Patterns

## Quick Reference
- Unit tests: `vitest` with `@testing-library/react`
- E2E tests: `playwright`
- Mocking: `vi.mock()` for modules, `msw` for API

## Detailed Patterns
- Advanced mocking: [references/mocking-strategies.md](references/mocking-strategies.md)
- Test data: [references/test-data-patterns.md](references/test-data-patterns.md)
```

"When to use" belongs in the `description`, which is all Claude sees before the skill
loads; a "When to Use" section in the body is read only after the decision is made.

### References

- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) - Anthropic blog
- [Claude Code Skills Documentation](https://code.claude.com/docs/en/skills)

---

## 5. Agents (Subagents)

### Overview

Agents are specialized system prompts that Claude can spawn as subagents via the Agent tool (named Task before Claude Code 2.1.63; `Task(...)` still works as an alias). Each agent runs in its own context with specific expertise, tool permissions, and instructions - ideal for domain-specific tasks that benefit from focused context.

### Benefits

- **Specialized expertise**: Deep knowledge in specific domains
- **Isolated context**: Separate context window, doesn't pollute main conversation
- **Tool restrictions**: Can limit which tools the agent can use
- **Parallel execution**: Multiple agents can run simultaneously
- **Model selection**: Can use cheaper models (Haiku) for simple tasks

### Authority

**Level: LOW (Advisory)**

Agent outputs are **advisory, not authoritative**. When you spawn an agent via the Agent tool, it runs independently and returns output. The parent agent can choose to ignore, modify, or override that output.

| Aspect | Authority Level | Notes |
|--------|-----------------|-------|
| Agent's own instructions | High (within its context) | Agent follows its own system prompt |
| Agent output to parent | Low | Parent can ignore or override |
| Tool access | Inherited | The main session's built-in and MCP tools, unless the agent's `tools` list narrows them |
| Context | Fresh | Doesn't see parent's conversation |

**Tool inheritance**: a subagent with no `tools` field gets the main conversation's tools, MCP servers included; a `tools` list narrows that. A background subagent keeps every MCP tool but only a subset of the built-ins. Subagents can spawn their own subagents, three layers deep by default. Source: [Claude Code Subagents](https://code.claude.com/docs/en/sub-agents).

### Structure

Agents are markdown files in `agents/` or `.claude/agents/`:

```yaml
---
name: firecrawl-expert
description: Expert in web scraping, crawling, anti-bot bypass, and structured data extraction
model: sonnet
---

# Firecrawl Expert

You are a web-scraping expert specializing in reliable data extraction...

## Core Expertise
- Crawl and scrape architecture
- Anti-bot and Cloudflare bypass
- Dynamic/JS-rendered content handling
- Structured data extraction pipelines

## Patterns
[Detailed patterns and examples...]
```

### Example Usage

When Claude encounters a scraping-specific question, it can spawn the firecrawl-expert:

```
User: "How do I extract structured data from this Cloudflare-protected site?"

Claude: I'll consult the firecrawl-expert agent for specialized guidance.
[Uses the Agent tool with subagent_type="firecrawl-expert"]
```

### References

- [Claude Code Subagents](https://code.claude.com/docs/en/sub-agents)
- [Practical guide to mastering Claude Code's main agent and Sub-agents](https://jewelhuq.medium.com/practical-guide-to-mastering-claude-codes-main-agent-and-sub-agents-fd52952dcf00)

---

## 6. Commands (Slash Commands)

### Overview

Slash commands are user-invoked shortcuts that expand into prompts. They provide quick access to common workflows, complex multi-step operations, or standardized procedures.

Claude Code has merged custom commands into skills: `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both create `/deploy`, and Anthropic's plugin docs say to prefer `skills/` for new work. claude-mods keeps only `/sync`, `/save` and `/git-ops` as commands.

### Benefits

- **Workflow shortcuts**: One command triggers complex sequences
- **Standardized procedures**: Ensure consistent execution of common tasks
- **Arguments**: Accept `$ARGUMENTS` for dynamic behavior
- **Natural language**: Written in plain markdown

### Authority

**Level: HIGH (User Intent)**

Commands execute with high authority because they represent explicit user intent. When a user invokes `/review`, they're explicitly requesting that workflow.

| Aspect | Authority |
|--------|-----------|
| Command invocation | Explicit user request - high priority |
| Command content | Treated as user instructions |
| Can spawn agents | Yes, with the Agent tool |
| Can invoke skills | Yes, via Skill tool |

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

### Authority

**Level: HIGHEST (System Prompt Modifier)**

Output styles operate at the highest level - they modify the system prompt itself.

| Mode | `keep-coding-instructions` | Authority |
|------|---------------------------|-----------|
| **Replacement** | `false` (default) | Replaces coding instructions entirely. Custom style has full authority over behavior. |
| **Additive** | `true` | Preserves coding instructions. Style adds personality layer but coding rules still apply. |

In both modes, all tools remain available. The style changes *how* Claude communicates, not *what* it can do.

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

### Authority

**Level: ABSOLUTE (Deterministic Execution)**

Hooks have the highest practical authority because they execute deterministically - Claude cannot choose to ignore them.

| Comparison | CLAUDE.md | Hooks |
|------------|-----------|-------|
| Execution | Probabilistic (LLM decides) | Deterministic (always runs) |
| Can be ignored | Yes (LLM might not follow) | No (shell script executes) |
| Can block actions | No (suggestions only) | Yes (PreToolUse can reject) |
| Timing | N/A | Precise lifecycle events |

**Key insight**: Hooks = "must do", CLAUDE.md = "should do".

### Common Hook Events

| Hook | Trigger | Use Case |
|------|---------|----------|
| `SessionStart` | Session begins, resumes, or restarts after `/clear` or compaction | Load context, run a one-shot scan |
| `UserPromptSubmit` | Before a prompt is processed | Validate or enrich the prompt, can block |
| `PreToolUse` | Before tool execution | Validate inputs, security checks, can block |
| `PostToolUse` | After tool execution | Format code, run tests, lint |
| `Notification` | On specific events | Alerts, logging, external notifications |
| `Stop` | When Claude stops | Cleanup, summaries, commit reminders |

These are the common ones, not the full list. The complete event catalog, with matchers,
stdin fields and blocking rules, is in
[`claude-code-ops/references/hooks-reference.md`](../skills/claude-code-ops/references/hooks-reference.md).

### Configuration Example

Each matcher entry holds a list of handler objects, not bare strings:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash .claude/hooks/validate-command.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "bash .claude/hooks/format-file.sh" }
        ]
      }
    ]
  }
}
```

### Example Hook Script

A hook receives its input as JSON on stdin (`tool_name`, `tool_input`, `cwd`, ...), not
as arguments or environment variables.

**`.claude/hooks/format-file.sh`**:
```bash
#!/bin/bash
FILE="$(jq -r '.tool_input.file_path // empty')"

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

- **One-command install**: `/plugin marketplace add owner/repo`, then `/plugin install <plugin>@<marketplace>`
- **Bundled extensions**: Multiple components in one package
- **Marketplaces**: Discover community plugins
- **Version control**: Track and update plugins

### Authority

**Level: INHERITED**

Plugins don't have their own authority level - each component within a plugin operates at its normal authority level (skills = high, agents = low, hooks = deterministic, etc.).

### Structure

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json        # Manifest (optional)
├── skills/                # Skill packages, one <name>/SKILL.md each
├── commands/              # Slash commands (prefer skills/ for new work)
├── agents/                # Subagent definitions
├── hooks/
│   └── hooks.json         # Hook configuration
├── output-styles/         # Output styles
└── .mcp.json              # MCP servers
```

Components are found by this layout; the manifest needs a path field only for a
component kept somewhere else. **Rules are not a plugin component** (nor is a
`CLAUDE.md` at the plugin root): claude-mods ships its `rules/` through
`scripts/install.sh` / `install.ps1` instead.

### Manifest Example

**`.claude-plugin/plugin.json`**:
```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "My awesome Claude Code extensions",
  "author": { "name": "Your Name" },
  "license": "MIT"
}
```

There is no `components` key: Claude Code strips unknown top-level fields, so a
component list there is silently ignored. `claude plugin validate` checks the manifest.

### References

- [Claude Code Plugins](https://www.anthropic.com/news/claude-code-plugins) - Official announcement
- [Plugin Documentation](https://code.claude.com/docs/en/plugins)
- [Plugin manifest reference](https://code.claude.com/docs/en/plugins-reference) - every `plugin.json` field and the standard layout

---

## Component Hierarchy

Understanding how components interact and their authority levels:

```
┌─────────────────────────────────────────────────────────────────┐
│  AUTHORITY: DETERMINISTIC (Cannot be ignored)                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Hooks (PreToolUse/PostToolUse/Stop)                      │  │
│  │  - Execute as shell scripts                               │  │
│  │  - Can block operations                                   │  │
│  └───────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  AUTHORITY: HIGHEST (System Prompt Level)                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Output Style                                             │  │
│  │  - keep-coding-instructions: false → replaces default     │  │
│  │  - keep-coding-instructions: true  → adds personality     │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Enterprise Policy CLAUDE.md (cannot override)            │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  User ~/.claude/CLAUDE.md                                 │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  User ~/.claude/rules/*.md                                │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Skill metadata (names + descriptions)                    │  │
│  └───────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  AUTHORITY: HIGH (User Message Level)                           │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Project .claude/CLAUDE.md                                │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Project .claude/rules/*.md                               │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Project AGENTS.md (read only if no CLAUDE.md here)       │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  CLAUDE.local.md (personal; also shadows AGENTS.md)       │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Skills (full content when loaded)                        │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  Commands (user-invoked workflows)                        │  │
│  └───────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  AUTHORITY: LOW (Advisory)                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Agent outputs (can be ignored by parent)                 │  │
│  │  - Run in a separate context window                       │  │
│  │  - Inherit the session's tools unless `tools` narrows     │  │
│  │  - Fresh context each invocation                          │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Skills vs Agents: Key Insights

Understanding when to use Skills versus Agents is one of the most important architectural decisions in Claude Code extensions. Here are the essential insights:

**Skills are for knowledge, Agents are for execution.** When you need Claude to *know* something - domain expertise, constraints, patterns, verification rules - use a Skill. The skill content becomes part of Claude's instructions with high authority. When you need Claude to *do* something in parallel, in the background, or with a different model for cost optimization - use an Agent. Agent outputs are advisory and can be ignored; they're workers, not authorities.

**The critical difference is authority and context.** Skills share context with the main conversation and have high authority - Claude treats skill content as rules to follow. Agents run in isolated contexts with fresh memory each time, and their outputs are merely suggestions the parent can override. Tool access rarely decides it: an agent inherits the main session's tools, MCP servers included, unless its `tools` list narrows them.

**The hybrid pattern is often optimal.** The most powerful architecture combines both: a Skill provides the authoritative knowledge and orchestration rules (what to do, when, and why), while Agents handle the actual execution (running tasks cheaply with Haiku, analyzing results in parallel with Sonnet). The skill tells Claude it *must* spawn certain agents; the agents do the work efficiently. Don't create agents with `model: inherit` - if you're not using a different model for cost savings or parallel execution, use a skill instead.

---

## Quick Reference: When to Use What

| Need | Use | Authority | Why |
|------|-----|-----------|-----|
| Project-wide instructions | AGENTS.md | High | One entry doc for every tool; loads unless a CLAUDE.md shadows it |
| Claude-only deltas | CLAUDE.md starting `@AGENTS.md` | High | A hook or plan mode for a path; without the import it hides AGENTS.md |
| Topic-specific rules | `.claude/rules/` | High | Modular, can be path-conditional |
| Domain expertise | Skills | High | Progressive loading, auto-routing |
| Parallel task execution | Agents | Low | Separate context, can use cheaper models |
| Workflow shortcuts | Commands | High | User-invoked, explicit intent |
| Different personality | Output Styles | Highest | System prompt modification |
| Deterministic automation | Hooks | Absolute | Always runs, can block |
| Share with community | Plugins | Inherited | Bundled distribution |

---

## Further Reading

- [Claude Code Documentation](https://code.claude.com/docs)
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [Agent Skills Blog Post](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
