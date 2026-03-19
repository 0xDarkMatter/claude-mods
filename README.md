```
 ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝
██║     ██║     ███████║██║   ██║██║  ██║█████╗      ██╔████╔██║██║   ██║██║  ██║███████╗
██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝      ██║╚██╔╝██║██║   ██║██║  ██║╚════██║
╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████║
 ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝
```

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet?logo=anthropic)](https://docs.anthropic.com/en/docs/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *A comprehensive extension toolkit that transforms Claude Code into a specialized development powerhouse.*

**claude-mods** is a production-ready plugin that extends Claude Code with 22 expert agents, 65 specialized skills, 4 output styles, 3 hooks, and modern CLI tools designed for real-world development workflows. Whether you're debugging React hooks, optimizing PostgreSQL queries, or building production CLI applications, this toolkit equips Claude with the domain expertise and procedural knowledge to work at expert level across multiple technology stacks.

Built on [Anthropic's Agent Skills standard](https://github.com/anthropics/skills), claude-mods fills critical gaps in Claude Code's capabilities: persistent session state that survives across machines, on-demand expert knowledge for specialized domains, token-efficient modern CLI tools (10-100x faster than traditional alternatives), and proven workflow patterns for TDD, code review, and feature development. The toolkit implements Anthropic's [recommended patterns for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), ensuring your development context never vanishes when sessions end.

From Python async patterns to Rust ownership models, from AWS Fargate deployments to Craft CMS development - claude-mods provides the specialized knowledge and tools that transform Claude from a general-purpose assistant into a domain expert who understands your stack, remembers your workflow, and ships production code.

**22 agents. 65 skills. 4 styles. 3 hooks. One install.**

## Recent Updates

**v2.2.0** (March 2026)
- 🔍 **`/introspect` enhanced** - Now generates Session Insights after every analysis: workflow improvements, skill suggestions, and ready-to-paste permission configs to reduce interruptions. Scales recommendations to session size.
- 🔧 **`/setperms` expanded** - Default template now includes 74 tool permissions (was 51): docker, cargo, go, pytest, npx, pnpm, yarn, bun, make, archive tools, data utilities.
- 🗑️ **`claude-code-templates` removed** - Redundant with Anthropic's first-party `skill-creator`. Install scripts auto-clean existing installs.

**v2.1.0** (March 2026)
- 🔁 **`/iterate` skill** - Autonomous improvement loop inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch). Define a goal, scope, and mechanical metric - the agent loops autonomously: modify, measure, keep or discard, repeat. Works for any domain (test coverage, bundle size, performance, ML training, code quality).

**v2.0.0** (March 2026)
- 🚀 **64 skills** - 22 new `-ops` skills covering React, Vue, JavaScript, Go, Rust, TypeScript, Docker, CI/CD, API design, PostgreSQL, Astro, Laravel, Nginx, Auth, Monitoring, Debug, MCP, Tailwind, Migrate, Refactor, Scaffold, Perf, Log analysis
- 🔄 **Renamed `-patterns` to `-ops`** - All 14 pattern skills renamed to signal comprehensive operational expertise
- 🛠️ **cc-session CLI** - Zero-dependency session log analyzer (15 commands, `--json` output, cross-project search)
- 📦 **Install scripts updated** - Automatic cleanup of renamed skills, preserves project-specific extras
- 🏷️ **3 hooks, 4 output styles** - Pre-commit lint, post-edit format, dangerous command warnings; Vesper, Spartan, Mentor, Executive

**v1.7.0** (February 2026)
- 🔄 **Schema v3.1** - `/save` and `/sync` upgraded for Claude Code 2.1.x and Opus 4.6
  - Session ID tracking with `--resume` suggestions (bridges task state + conversation history)
  - PR-linked sessions via `gh pr view` with `--from-pr` suggestions
  - Native memory integration - `/save` writes to MEMORY.md (auto-loaded safety net)
  - Dynamic plan path via `plansDirectory` setting (Claude Code v2.1.9+)
  - Dropped legacy v2.0 migration code

**v1.6.0** (February 2026)
- 🚀 **Tech Debt Scanner** - Automated detection using parallel subagents (1,520 lines)
  - Always-parallel architecture for fast analysis (2-15s depending on scope)
  - 4 categories: Duplication, Security, Complexity, Dead Code
  - Session-end workflow: catch issues while context is fresh
  - Language-smart: Python, JS/TS, Go, Rust, SQL with AST-based detection
  - [Boris Cherny's recommendation](https://x.com/bcherny/status/2017742741636321619): "Build a /techdebt slash command and run it at the end of every session"

**v1.5.2** (February 2026)
- 🆕 Added `cli-ops`, `screenshot`, `skill-creator` skills (+3 skills, now 42 total)
- 📚 Enhanced skill-creator with [official Anthropic docs](https://github.com/anthropics/skills) and best practices (+554 lines)
- 🐛 Fixed `/sync` filesystem scanning issue on Windows (Git Bash compatibility)

[View full changelog →](https://github.com/0xDarkMatter/claude-mods/commits/main)

## Why claude-mods?

Claude Code is powerful out of the box, but it has gaps. This toolkit fills them:

- **Session continuity** — Tasks vanish when sessions end. We fix that with `/save` and `/sync`, implementing Anthropic's [recommended pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) for long-running agents.

- **Expert-level knowledge on demand** — 22 specialized agents covering React, TypeScript, Python, Go, Rust, AWS, PostgreSQL, and more. Each agent is deeply researched with real-world patterns, not generic advice.

- **Modern CLI tools** — Stop using `grep`, `find`, and `cat`. Our rules automatically prefer `ripgrep`, `fd`, `eza`, and `bat` — 10-100x faster and token-efficient.

- **Smart web fetching** — A fallback hierarchy that actually works: WebFetch → Jina Reader → Firecrawl. No more "I can't access that URL."

- **Workflow patterns** — TDD cycles, code review, feature development, debugging — all documented with Anthropic's best practices.

## Key Benefits

- **Persistent task state** — Pick up exactly where you left off, even across machines
- **Domain expertise** — Agents trained on framework docs, not just general knowledge
- **Token efficiency** — Modern CLI tools produce cleaner output, saving context window
- **Team sharing** — Git-trackable state files work across your whole team
- **Production-ready** — Validated test suite, proper plugin format, comprehensive docs
- **Extended thinking** — Built-in guidance for "think hard" and "ultrathink" triggers
- **Zero lock-in** — Standard Claude Code plugin format, toggle on/off anytime

## Structure

```
claude-mods/
├── .claude-plugin/     # Plugin metadata
├── agents/             # Expert subagents (22)
├── commands/           # Slash commands (3)
├── skills/             # Custom skills (64)
├── output-styles/      # Response personalities
├── hooks/              # Hook examples & docs
├── rules/              # Claude Code rules
├── tools/              # Modern CLI toolkit installers
├── scripts/            # Plugin install scripts
├── tests/              # Test suites + justfile
├── docs/               # Project docs (PLAN.md, DASH.md)
└── templates/          # Extension templates
```

## Installation

### Plugin Install (Recommended)

```bash
# Step 1: Add the marketplace
/plugin marketplace add 0xDarkMatter/claude-mods

# Step 2: Install the plugin
/plugin install claude-mods@0xDarkMatter-claude-mods
```

This installs globally (available in all projects). Toggle on/off with `/plugin` menu.

### Script Install

**Linux/macOS:**
```bash
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
./scripts/install.sh
```

**Windows (PowerShell):**
```powershell
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
.\scripts\install.ps1
```

The install scripts:
- Copy commands, skills, agents, rules, output styles to `~/.claude/`
- Clean up deprecated items (e.g., old `/conclave` command)
- Remove renamed skills (e.g., `-patterns` -> `-ops`)
- Handle command→skill migrations (won't create duplicates)
- Preserve any extra skills installed separately (e.g., project-specific skills)

### CLI Tools (Optional)

Install modern CLI tools (fd, rg, bat, etc.) for better performance:

```bash
# Windows (Admin PowerShell)
.\tools\install-windows.ps1

# Linux/macOS
./tools/install-unix.sh
```

## Skill Architecture

All skills follow [Anthropic's official pattern](https://github.com/anthropics/skills) with consistent structure:

```
skill-name/
├── SKILL.md              # Core workflow (< 500 lines)
├── scripts/              # Executable code (optional)
├── references/           # Documentation loaded as needed (optional)
└── assets/               # Output templates/files (optional)
```

**Progressive Loading:**
1. Metadata (name + description) - Always in context (~100 words)
2. SKILL.md body - Loaded when skill triggers (<5k words)
3. Bundled resources - Loaded only when Claude needs them

All skills have the complete directory structure, even if `scripts/`, `references/`, or `assets/` are currently empty. This ensures consistency and makes it easy to add bundled resources later.

See [skill-creator](skills/skill-creator/) for the complete guide.

## What's Included

### Commands

| Command | Description |
|---------|-------------|
| [sync](commands/sync.md) | Session bootstrap - restore tasks, plan, git/PR context. Suggests `--resume` and `--from-pr`. |
| [save](commands/save.md) | Persist tasks, plan, git/PR context, and session summary to native memory. |
| [canvas](commands/canvas.md) | Terminal canvas for content drafting with live markdown preview. Requires Warp terminal. (Experimental) |

### Skills

#### Language & Framework Skills
| Skill | Description |
|-------|-------------|
| [go-ops](skills/go-ops/) | Go concurrency, error handling, testing, interfaces, generics, project structure |
| [rust-ops](skills/rust-ops/) | Rust ownership, async/tokio, error handling, traits, serde, ecosystem |
| [typescript-ops](skills/typescript-ops/) | TypeScript type system, generics, utility types, strict mode, Zod |
| [javascript-ops](skills/javascript-ops/) | JavaScript/Node.js async patterns, modules, ES2024+, runtime internals |
| [react-ops](skills/react-ops/) | React hooks, Server Components, state management, performance, testing |
| [vue-ops](skills/vue-ops/) | Vue 3 Composition API, Pinia, Vue Router, Nuxt 3 |
| [astro-ops](skills/astro-ops/) | Astro islands, content collections, rendering strategies, deployment |
| [laravel-ops](skills/laravel-ops/) | Laravel Eloquent, architecture, authentication, testing with Pest |
| [cli-ops](skills/cli-ops/) | Production CLI tool patterns - agentic workflows, stream separation, exit codes |
| [tailwind-ops](skills/tailwind-ops/) | Tailwind CSS patterns, v4 migration, components, configuration |

#### Data & API Skills
| Skill | Description |
|-------|-------------|
| [api-design-ops](skills/api-design-ops/) | REST, gRPC, GraphQL design patterns, versioning, auth, rate limiting |
| [rest-ops](skills/rest-ops/) | HTTP methods, status codes, REST quick reference |
| [sql-ops](skills/sql-ops/) | CTEs, window functions, JOIN patterns, indexing |
| [postgres-ops](skills/postgres-ops/) | PostgreSQL operations, optimization, schema design, replication, monitoring |
| [sqlite-ops](skills/sqlite-ops/) | SQLite schemas, Python sqlite3/aiosqlite patterns |
| [mcp-ops](skills/mcp-ops/) | MCP server development, FastMCP, transports, tool design, testing |

#### Infrastructure Skills
| Skill | Description |
|-------|-------------|
| [docker-ops](skills/docker-ops/) | Dockerfile best practices, multi-stage builds, Compose, optimization |
| [ci-cd-ops](skills/ci-cd-ops/) | GitHub Actions, release automation, testing pipelines |
| [container-orchestration](skills/container-orchestration/) | Kubernetes, Helm, pod patterns |
| [nginx-ops](skills/nginx-ops/) | Nginx reverse proxy, SSL/TLS, load balancing, performance tuning |
| [auth-ops](skills/auth-ops/) | JWT, OAuth2, sessions, RBAC/ABAC, passkeys, MFA |
| [monitoring-ops](skills/monitoring-ops/) | Prometheus, Grafana, OpenTelemetry, structured logging, alerting |
| [debug-ops](skills/debug-ops/) | Systematic debugging, language-specific debuggers, common scenarios |
| [perf-ops](skills/perf-ops/) | Performance profiling - CPU, memory, bundle analysis, load testing, flamegraphs |

#### CLI Tool Skills
| Skill | Description |
|-------|-------------|
| [file-search](skills/file-search/) | Find files with fd, search code with rg, select with fzf |
| [find-replace](skills/find-replace/) | Modern find-and-replace with sd |
| [code-stats](skills/code-stats/) | Analyze codebase with tokei and difft |
| [data-processing](skills/data-processing/) | Process JSON with jq, YAML/TOML with yq |
| [markitdown](skills/markitdown/) | Convert PDF, Word, Excel, PowerPoint, images to markdown |
| [structural-search](skills/structural-search/) | Search code by AST structure with ast-grep |
| [log-ops](skills/log-ops/) | Log analysis, JSONL processing, cross-log correlation, timeline reconstruction |

#### Workflow Skills
| Skill | Description |
|-------|-------------|
| [tool-discovery](skills/tool-discovery/) | Recommend agents and skills for any task |
| [git-workflow](skills/git-workflow/) | Enhanced git operations with lazygit, gh, delta |
| [doc-scanner](skills/doc-scanner/) | Scan and synthesize project documentation |
| [project-planner](skills/project-planner/) | Track stale plans, suggest session commands |
| [python-env](skills/python-env/) | Fast Python environment management with uv |
| [task-runner](skills/task-runner/) | Run project commands with just |
| [screenshot](skills/screenshot/) | Find and display recent screenshots from common screenshot directories |

#### Development Skills
| Skill | Description |
|-------|-------------|
| [skill-creator](skills/skill-creator/) | Guide for creating effective skills with specialized knowledge, workflows, and tool integrations. |
| [explain](skills/explain/) | Deep explanation of complex code, files, or concepts. Routes to expert agents. |
| [spawn](skills/spawn/) | Generate PhD-level expert agent prompts for Claude Code. |
| [atomise](skills/atomise/) | Atom of Thoughts reasoning - decompose problems into atomic units. |
| [setperms](skills/setperms/) | Set tool permissions and CLI preferences in .claude/ directory. |
| [introspect](skills/introspect/) | Analyze previous session logs without consuming current context. |
| [review](skills/review/) | Code review with semantic diffs, expert routing, and auto-TaskCreate. |
| [testgen](skills/testgen/) | Generate tests with expert routing and framework detection. |
| [techdebt](skills/techdebt/) | Technical debt detection using parallel subagents. |
| [migrate-ops](skills/migrate-ops/) | Framework/language migration patterns, version upgrades, codemods |
| [refactor-ops](skills/refactor-ops/) | Safe refactoring patterns, code smell detection, test-driven methodology |
| [scaffold](skills/scaffold/) | Project scaffolding - generate boilerplate for APIs, web apps, CLIs, monorepos |
| [iterate](skills/iterate/) | Autonomous improvement loop - modify, measure, keep or discard, repeat. Inspired by Karpathy's autoresearch. |

### Hooks

| Hook | Type | Description |
|------|------|-------------|
| [pre-commit-lint.sh](hooks/pre-commit-lint.sh) | PreToolUse | Auto-lint staged files before commit (JS/TS, Python, Go, Rust, PHP) |
| [post-edit-format.sh](hooks/post-edit-format.sh) | PostToolUse | Auto-format files after Write/Edit (Prettier, Ruff, gofmt, rustfmt) |
| [dangerous-cmd-warn.sh](hooks/dangerous-cmd-warn.sh) | PreToolUse | Block destructive commands (force push, rm -rf, DROP TABLE) |

### Output Styles

| Style | Personality | Best For |
|-------|-------------|----------|
| [Vesper](output-styles/vesper.md) | Sophisticated British wit, intellectual depth | General development work |
| [Spartan](output-styles/spartan.md) | Minimal, bullet-points only | Quick tasks, CI output |
| [Mentor](output-styles/mentor.md) | Patient, educational | Learning, onboarding |
| [Executive](output-styles/executive.md) | High-level summaries | Non-technical stakeholders |

### Agents

| Agent | Description |
|-------|-------------|
| [astro-expert](agents/astro-expert.md) | Astro projects, SSR/SSG, Cloudflare deployment |
| [asus-router-expert](agents/asus-router-expert.md) | Asus routers, network hardening, Asuswrt-Merlin |
| [aws-fargate-ecs-expert](agents/aws-fargate-ecs-expert.md) | Amazon ECS on Fargate, container deployment |
| [bash-expert](agents/bash-expert.md) | Defensive Bash scripting, CI/CD pipelines |
| [claude-architect](agents/claude-architect.md) | Claude Code architecture, extensions, MCP, plugins, debugging |
| [cloudflare-expert](agents/cloudflare-expert.md) | Cloudflare Workers, Pages, DNS, security |
| [craftcms-expert](agents/craftcms-expert.md) | Craft CMS content modeling, Twig, plugins, GraphQL |
| [cypress-expert](agents/cypress-expert.md) | Cypress E2E and component testing, custom commands, CI/CD |
| [firecrawl-expert](agents/firecrawl-expert.md) | Web scraping, crawling, parallel fetching, structured extraction |
| [go-expert](agents/go-expert.md) | Go idioms, concurrency, error handling, performance |
| [javascript-expert](agents/javascript-expert.md) | Modern JavaScript, async patterns, optimization |
| [laravel-expert](agents/laravel-expert.md) | Laravel framework, Eloquent, testing |
| [payloadcms-expert](agents/payloadcms-expert.md) | Payload CMS architecture and configuration |
| [postgres-expert](agents/postgres-expert.md) | PostgreSQL management and optimization |
| [project-organizer](agents/project-organizer.md) | Reorganize directory structures, cleanup |
| [python-expert](agents/python-expert.md) | Advanced Python, testing, optimization |
| [react-expert](agents/react-expert.md) | React hooks, state management, Server Components, performance |
| [rust-expert](agents/rust-expert.md) | Rust ownership, lifetimes, async, unsafe patterns |
| [sql-expert](agents/sql-expert.md) | Complex SQL queries, optimization, indexing |
| [typescript-expert](agents/typescript-expert.md) | TypeScript type system, generics, utility types, strict mode |
| [vue-expert](agents/vue-expert.md) | Vue 3, Composition API, Pinia state management, performance |
| [wrangler-expert](agents/wrangler-expert.md) | Cloudflare Workers deployment, wrangler.toml |

### Rules

| Rule | Description |
|------|-------------|
| [cli-tools.md](rules/cli-tools.md) | Modern CLI tool preferences (fd, rg, eza, bat, etc.) |
| [thinking.md](rules/thinking.md) | Extended thinking triggers (think → ultrathink) |
| [commit-style.md](rules/commit-style.md) | Conventional commits format and examples |
| [naming-conventions.md](rules/naming-conventions.md) | Component naming patterns for agents, skills, commands |
| [skill-agent-updates.md](rules/skill-agent-updates.md) | Mandatory docs check before creating/updating skills or agents |

### Tools & Hooks

| Resource | Description |
|----------|-------------|
| [tools/](tools/) | Modern CLI toolkit - token-efficient replacements for legacy commands |
| [hooks/](hooks/) | Hook examples for pre/post execution automation |

#### Web Fetching Hierarchy

When fetching web content, tools are used in this order:

| Priority | Tool | When to Use |
|----------|------|-------------|
| 1 | `WebFetch` | First attempt - fast, built-in |
| 2 | `r.jina.ai/URL` | JS-rendered pages, PDFs, cleaner extraction |
| 3 | `firecrawl <url>` | Anti-bot bypass, blocked sites (403, Cloudflare) |
| 4 | `firecrawl-expert` agent | Complex scraping, structured extraction |

See [tools/README.md](tools/README.md) for full documentation and install scripts.

## Testing & Validation

Validate all extensions before committing:

```bash
cd tests

# Run full validation (requires just)
just test

# Or run directly
bash validate.sh

# Windows
powershell validate.ps1
```

### What's Validated
- YAML frontmatter syntax
- Required fields (name, description)
- Naming conventions (kebab-case)
- File structure (agents/*.md, skills/*/SKILL.md)

### Available Tasks

```bash
cd tests
just              # List all tasks
just test         # Run full validation
just validate-yaml # YAML only
just validate-names # Naming only
just stats        # Count extensions
just list-agents  # List all agents
```

## Session Continuity

The `/save` and `/sync` commands fill a gap in Claude Code's native session management.

**The problem:** Claude Code's `--resume` flag restores conversation history, but **task state does not persist between sessions—by design**. Claude Code treats each session as isolated; the philosophy is that persistent state belongs in files you control.

Tasks (created via TaskCreate, managed via TaskList/TaskUpdate) are session-scoped and deleted when the session ends. This is intentional.

**The solution:** `/save` and `/sync` implement the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

### What Persists vs What Doesn't

| Claude Code Feature | Persists? | Location |
|---------------------|-----------|----------|
| Conversation history | Yes | Internal (use `--resume`) |
| CLAUDE.md context | Yes | `./CLAUDE.md` |
| Native memory (MEMORY.md) | Yes | `~/.claude/projects/.../memory/` |
| Tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

### Session Workflow

```
Session 1:
  /sync                              # Bootstrap + restore saved state
  [work on tasks]
  /save "Stopped at auth module"     # Writes session-cache.json + MEMORY.md

Session 2:
  [MEMORY.md auto-loaded: "Goal: Auth, Branch: feature/auth, PR: #42"]
  /sync                              # Full restore: tasks, plan, git, PR
  → "Previous session: abc123... (claude --resume abc123...)"
  → "In progress: Auth module refactor"
  → "PR: #42 (claude --from-pr 42)"
```

### Why Not Just Use `--resume`?

| Feature | `--resume` | `/save` + `/sync` |
|---------|------------|-------------------|
| Conversation history | Yes | No |
| Tasks | **No** | Yes |
| Git context | No | Yes |
| PR linkage | Yes (`--from-pr`) | Yes (detected via `gh`) |
| Session ID bridging | N/A | Yes (suggests `--resume <id>`) |
| Native memory safety net | No | Yes (MEMORY.md auto-loaded) |
| Human-readable summary | No | Yes |
| Git-trackable | No | Yes |
| Works across machines | No | Yes (if committed) |
| Team sharing | No | Yes |

**Use both together:** `claude --resume` for conversation context, `/sync` for task state. Since v3.1, `/save` stores your session ID so `/sync` can suggest the exact `--resume` command.

### Session Cache Schema (v3.1)

The `.claude/session-cache.json` file stores full task objects:

```json
{
  "version": "3.1",
  "session_id": "977c26c9-60fa-4afc-a628-a68f8043b1ab",
  "tasks": [
    {
      "subject": "Task title",
      "description": "Detailed description",
      "activeForm": "Working on task",
      "status": "completed|in_progress|pending",
      "blockedBy": [0, 1]
    }
  ],
  "plan": { "file": "docs/PLAN.md", "goal": "...", "current_step": "...", "progress_percent": 40 },
  "git": { "branch": "main", "last_commit": "abc123", "pr_number": 42, "pr_url": "https://..." },
  "memory": { "synced": true },
  "notes": "Session notes"
}
```

**Compatibility:** `/sync` handles both v3.0 and v3.1 files gracefully. Missing v3.1 fields are treated as absent.

## Updating

```bash
git pull
```

Then re-run the install script to update your global Claude configuration.

## Performance Tips

### MCP Tool Search

When using multiple MCP servers (Chrome DevTools, Vibe Kanban, etc.), their tool definitions consume context. Enable Tool Search to load tools on-demand:

```json
// .claude/settings.local.json
{
  "env": {
    "ENABLE_TOOL_SEARCH": "true"
  }
}
```

| Value | Behavior |
|-------|----------|
| `"auto"` | Enable when MCP tools > 10% of context (default) |
| `"auto:5"` | Custom threshold (5%) |
| `"true"` | Always enabled (recommended) |
| `"false"` | Disabled |

**Requirements:** Sonnet 4+ or Opus 4+ (Haiku not supported)

### Skills Over Commands

Most functionality lives in skills rather than commands. Skills get slash-hint discovery via trigger keywords and load on-demand, reducing context overhead. Only session management (`/sync`, `/save`) and experimental features (`/canvas`) remain as commands.

See `docs/COMMAND-SKILL-PATTERN.md` for details.

## Resources

- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Official Anthropic guide
- [Claude Code Plugins](https://claude.com/blog/claude-code-plugins) — Plugin system documentation
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — The pattern behind `/save`

---

*Extend Claude Code. Your way.*
