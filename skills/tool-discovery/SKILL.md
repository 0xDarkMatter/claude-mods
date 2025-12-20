---
name: tool-discovery
description: "Recommend the right agents and skills for any task. Covers both heavyweight agents (Task tool) and lightweight skills (Skill tool). Triggers on: which agent, which skill, what tool should I use, help me choose, recommend agent, find the right tool."
allowed-tools: "Read Glob"
---

# Tool Discovery

Recommend the right agents and skills for any task. Covers both heavyweight agents (Task tool) and lightweight skills (Skill tool).

## Decision Flowchart

```
Is this a reference/lookup task?
├── YES → Use a SKILL (lightweight, auto-injects)
│         Examples: patterns, syntax, CLI commands
│
└── NO → Does it require reasoning/decisions?
         ├── YES → Use an AGENT (heavyweight, spawns subagent)
         │         Examples: architecture, optimization, debugging
         │
         └── MAYBE → Check both lists below
```

**Rule of thumb:**
- **Skills** = Quick reference, patterns, commands (50-200 lines)
- **Agents** = Deep expertise, autonomous decisions (200-1600 lines)

---

## Skills Reference

### Pattern Skills (Reference Tables)

| Skill | Triggers | Use When |
|-------|----------|----------|
| **rest-patterns** | rest api, http methods, status codes | HTTP method semantics, status code lookup |
| **tailwind-patterns** | tailwind, utility classes, tw | Tailwind classes, responsive breakpoints |
| **sql-patterns** | sql patterns, cte, window functions | CTE examples, JOIN reference, window functions |
| **sqlite-ops** | sqlite, aiosqlite, local database | SQLite schema patterns, Python sqlite3/aiosqlite |
| **mcp-patterns** | mcp server, model context protocol | MCP server structure, tool handlers |

### CLI Tool Skills

| Skill | Triggers | Use When |
|-------|----------|----------|
| **file-search** | fd, ripgrep, rg, fzf | Finding files, searching code, interactive selection |
| **find-replace** | sd, batch replace | Modern find-and-replace (sd over sed) |
| **code-stats** | tokei, difft, line counts | Codebase statistics, semantic diffs |
| **data-processing** | jq, yq, json, yaml | JSON/YAML processing and transformation |
| **structural-search** | ast-grep, sg, ast pattern | Search by AST structure, not text |

### Workflow Skills

| Skill | Triggers | Use When |
|-------|----------|----------|
| **git-workflow** | lazygit, gh, delta, pr, rebase, stash, bisect | Git operations, GitHub PRs, staging, rebase, bisect |
| **python-env** | uv, venv, pip, pyproject | Python environment setup with uv |
| **task-runner** | just, justfile, run tests | Running project tasks via justfile |
| **doc-scanner** | AGENTS.md, conventions, scan docs | Finding and reading project documentation |
| **project-planner** | plan, sync plan, track | Project planning with /plan command |

---

## Agents Reference

### Language Experts

| Agent | Use When |
|-------|----------|
| **python-expert** | Advanced Python, async, testing, optimization |
| **javascript-expert** | Modern JS, async patterns, V8 optimization |
| **typescript-expert** | Type system, generics, complex types |
| **bash-expert** | Shell scripting, defensive programming |

### Framework Experts

| Agent | Use When |
|-------|----------|
| **react-expert** | React hooks, Server Components, state management |
| **vue-expert** | Vue 3, Composition API, Pinia |
| **laravel-expert** | Laravel, Eloquent, PHP testing |
| **astro-expert** | Astro SSR/SSG, Cloudflare deployment |

### Infrastructure Experts

| Agent | Use When |
|-------|----------|
| **postgres-expert** | PostgreSQL optimization, execution plans |
| **sql-expert** | Complex queries, query optimization |
| **wrangler-expert** | Cloudflare Workers deployment |
| **aws-fargate-ecs-expert** | ECS/Fargate container orchestration |
| **cloudflare-expert** | Workers, Pages, DNS configuration |

### Specialized

| Agent | Use When |
|-------|----------|
| **firecrawl-expert** | Web scraping, crawling, anti-bot bypass |
| **payloadcms-expert** | Payload CMS architecture, configuration |
| **craftcms-expert** | Craft CMS, Twig templates |
| **cypress-expert** | E2E testing, component tests |
| **project-organizer** | Restructuring project directories |

### Built-in Agents (Task tool)

| Agent | Use When |
|-------|----------|
| **Explore** | Quick codebase exploration, "where is X" |
| **Plan** | Design implementation strategy |
| **general-purpose** | Multi-step tasks when unsure |
| **claude-code-guide** | Questions about Claude Code features |

---

## Matching By Context

### By File Extension

| Files | Skill | Agent |
|-------|-------|-------|
| `.py` | python-env | python-expert |
| `.ts`, `.js` | — | typescript-expert, javascript-expert |
| `.sql` | sql-patterns | postgres-expert, sql-expert |
| `.sh` | — | bash-expert |
| `.astro` | tailwind-patterns | astro-expert |
| `.json` | data-processing | — |
| `.yaml` | data-processing | — |

### By Task Type

| Task | Try Skill First | Then Agent |
|------|-----------------|------------|
| "How do I write a CTE?" | sql-patterns | sql-expert |
| "Optimize this query" | — | postgres-expert |
| "Find files named X" | file-search | Explore |
| "Restructure this project" | — | project-organizer |
| "Scrape this website" | — | firecrawl-expert |
| "What HTTP status for X?" | rest-patterns | — |
| "Set up Python project" | python-env | python-expert |
| "Build MCP server" | mcp-patterns | — |

### By Keywords

| Keywords | Likely Skill | Likely Agent |
|----------|--------------|--------------|
| "pattern", "example", "syntax" | Check skills first | — |
| "optimize", "debug", "fix" | — | Check agents |
| "reference", "lookup", "how to" | Check skills first | — |
| "architecture", "design", "plan" | — | Check agents or Plan |

---

## How to Launch

### Skills (via Skill tool)
```
Skill tool → skill: "file-search"
```
Skills auto-inject into current context. No subagent spawned.

### Agents (via Task tool)
```
Task tool → subagent_type: "python-expert"
         → prompt: "Your task description"
```
Agents spawn a subagent session with their full context.

---

## Recommendations Workflow

```
User: "Which tool should I use for X?"

1. Parse the request:
   - Is it reference/lookup? → Skill
   - Does it need reasoning? → Agent
   - Unclear? → Check both lists

2. Match to available tools:
   - Check file types in project
   - Check config files (package.json, pyproject.toml, etc.)
   - Consider task complexity

3. Output format:
   RECOMMENDED: [skill/agent-name]
   TYPE: Skill | Agent
   WHY: [1 sentence rationale]

   LAUNCH: Skill tool with "name" | Task tool with subagent_type="name"

4. If multiple apply:
   PRIMARY: [name] - [reason]
   SECONDARY: [name] - [reason]
```

---

## Tips

- **Skills are cheaper** - Use for reference lookups, patterns, CLI commands
- **Agents are powerful** - Use for decisions, optimization, debugging
- **Don't over-recommend** - Maximum 2-3 tools per task
- **Parallel execution** - Launch independent agents in parallel via Task tool
- **Check availability** - Run `/agents` or check this skill for current list
