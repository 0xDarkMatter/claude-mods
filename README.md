# claude-mods

A comprehensive extension toolkit for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that transforms your AI coding assistant into a powerhouse development environment.

**23 expert agents. 10 slash commands. 30 skills. 4 rules. Custom output styles. One plugin install.**

## Why claude-mods?

Claude Code is powerful out of the box, but it has gaps. This toolkit fills them:

- **Session continuity** — TodoWrite tasks vanish when sessions end. We fix that with `/save` and `/sync`, implementing Anthropic's [recommended pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) for long-running agents.

- **Expert-level knowledge on demand** — 23 specialized agents covering React, TypeScript, Python, Go, Rust, AWS, PostgreSQL, and more. Each agent is deeply researched with real-world patterns, not generic advice.

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
├── agents/             # Expert subagents (23)
├── commands/           # Slash commands (11)
├── skills/             # Custom skills (30)
├── output-styles/      # Response personalities
├── hooks/              # Hook examples & docs
├── rules/              # Claude Code rules
├── tools/              # Modern CLI toolkit docs
├── tests/              # Test suites + justfile
├── scripts/            # Install scripts
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
./tools/install-unix.sh
```

**Windows (PowerShell):**
```powershell
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
.\tools\install-windows.ps1
```

### Manual Install

```bash
git clone https://github.com/0xDarkMatter/claude-mods.git
```

Then symlink or copy to your Claude directories:
- Commands → `~/.claude/commands/`
- Skills → `~/.claude/skills/`
- Agents → `~/.claude/agents/`
- Rules → `~/.claude/rules/`

## What's Included

### Commands

| Command | Description |
|---------|-------------|
| [sync](commands/sync.md) | Session bootstrap - read project context, restore saved state, show status. Quick orientation with optional deep dive. |
| [save](commands/save.md) | Save session state - persist TodoWrite tasks, plan content, and git context. |
| [review](commands/review.md) | Code review staged changes or specific files. Analyzes bugs, security, performance, style. |
| [testgen](commands/testgen.md) | Generate tests with expert routing, framework detection, focus/depth modes. |
| [explain](commands/explain.md) | Deep explanation of complex code, files, or concepts. Architecture, data flow, design decisions. |
| [spawn](commands/spawn.md) | Generate expert agents with PhD-level patterns and code examples. |
| [conclave](commands/conclave.md) | **[DEPRECATED]** Use [Conclave CLI](https://github.com/0xDarkMatter/conclave) instead. |
| [atomise](commands/atomise.md) | Atom of Thoughts reasoning - decompose problems into atomic units with confidence tracking and backtracking. |
| [pulse](commands/pulse.md) | Generate Claude Code ecosystem news digest from blogs, repos, and community sources. |
| [setperms](commands/setperms.md) | Set tool permissions and CLI preferences. |
| [archive](commands/archive.md) | Archive completed plans and session state. |

### Experimental Commands

> ⚠️ These features are under active development. APIs may change.

| Command | Description |
|---------|-------------|
| [canvas](commands/canvas.md) | Terminal canvas for content drafting with live markdown preview. Requires Warp terminal. |

### Skills

#### Pattern Reference Skills
| Skill | Description |
|-------|-------------|
| [rest-patterns](skills/rest-patterns/) | HTTP methods, status codes, REST design patterns |
| [tailwind-patterns](skills/tailwind-patterns/) | Tailwind utilities, responsive breakpoints, config |
| [sql-patterns](skills/sql-patterns/) | CTEs, window functions, JOIN patterns, indexing |
| [sqlite-ops](skills/sqlite-ops/) | SQLite schemas, Python sqlite3/aiosqlite patterns |
| [mcp-patterns](skills/mcp-patterns/) | MCP server structure, tool handlers, resources |

#### CLI Tool Skills
| Skill | Description |
|-------|-------------|
| [file-search](skills/file-search/) | Find files with fd, search code with rg, select with fzf |
| [find-replace](skills/find-replace/) | Modern find-and-replace with sd |
| [code-stats](skills/code-stats/) | Analyze codebase with tokei and difft |
| [data-processing](skills/data-processing/) | Process JSON with jq, YAML/TOML with yq |
| [structural-search](skills/structural-search/) | Search code by AST structure with ast-grep |

#### Workflow Skills
| Skill | Description |
|-------|-------------|
| [tool-discovery](skills/tool-discovery/) | Recommend agents and skills for any task |
| [git-workflow](skills/git-workflow/) | Enhanced git operations with lazygit, gh, delta |
| [doc-scanner](skills/doc-scanner/) | Scan and synthesize project documentation |
| [project-planner](skills/project-planner/) | Track stale plans, suggest session commands |
| [python-env](skills/python-env/) | Fast Python environment management with uv |
| [task-runner](skills/task-runner/) | Run project commands with just |

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
| [playwright-roulette-expert](agents/playwright-roulette-expert.md) | Playwright automation for casino testing |
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

### Tools & Hooks

| Resource | Description |
|----------|-------------|
| [tools/](tools/) | Modern CLI toolkit - token-efficient replacements for legacy commands |
| [hooks/](hooks/) | Hook examples for pre/post execution automation |

### Output Styles

Output styles customize Claude's response personality. Use `/output-style` to switch between them.

| Style | Description |
|-------|-------------|
| [vesper](output-styles/vesper.md) | Sophisticated engineering companion with British wit, intellectual depth, and pattern recognition |

**Creating custom styles:** Add a markdown file to `output-styles/` with YAML frontmatter:

```yaml
---
name: StyleName
description: Brief description of the personality
keep-coding-instructions: true  # Preserve Claude Code's core behavior
---

# Style content here...
```

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

**The problem:** Claude Code's `--resume` flag restores conversation history, but **TodoWrite task state does not persist between sessions—by design**. Claude Code treats each session as isolated; the philosophy is that persistent state belongs in files you control.

TodoWrite tasks are stored at `~/.claude/todos/[session-id].json` and deleted when the session ends. This is intentional.

**The solution:** `/save` and `/sync` implement the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

### What Persists vs What Doesn't

| Claude Code Feature | Persists? | Location |
|---------------------|-----------|----------|
| Conversation history | Yes | Internal (use `--resume`) |
| CLAUDE.md context | Yes | `./CLAUDE.md` |
| TodoWrite tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

### Session Workflow

```
Session 1:
  /sync                              # Bootstrap + restore saved state
  [work on tasks]
  /save "Stopped at auth module"     # Writes .claude/session-cache.json

Session 2:
  /sync                              # Restore TodoWrite, show status
  → "In progress: Auth module refactor"
  → "Notes: Stopped at auth module"
  /sync --status                     # Quick status check anytime
```

### Why Not Just Use `--resume`?

| Feature | `--resume` | `/save` + `/sync` |
|---------|------------|-------------------|
| Conversation history | Yes | No |
| TodoWrite tasks | **No** | Yes |
| Git context | No | Yes |
| Human-readable summary | No | Yes |
| Git-trackable | No | Yes |
| Works across machines | No | Yes (if committed) |
| Team sharing | No | Yes |

**Use both together:** `claude --resume` for conversation context, `/sync` for task state.

## Updating

```bash
git pull
```

Then re-run the install script to update your global Claude configuration.

## Resources

- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Official Anthropic guide
- [Claude Code Plugins](https://claude.com/blog/claude-code-plugins) — Plugin system documentation
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — The pattern behind `/save`

---

*Extend Claude Code. Your way.*
