# claude-mods

Custom commands, skills, and agents for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Structure

```
claude-mods/
├── commands/           # Slash commands
├── skills/             # Custom skills
├── agents/             # Custom subagents
├── install.sh          # Linux/macOS installer
└── install.ps1         # Windows installer
```

## Installation

### Quick Install

**Linux/macOS:**
```bash
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
./install.sh
```

**Windows (PowerShell):**
```powershell
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
.\install.ps1
```

### Manual Install

Clone with submodules:
```bash
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
```

Then symlink or copy to your Claude directories:
- Commands → `~/.claude/commands/`
- Skills → `~/.claude/skills/`
- Agents → `~/.claude/agents/`

## What's Included

### Commands

| Command | Description |
|---------|-------------|
| [g-slave](commands/g-slave/) | Dispatch Gemini CLI to analyze large codebases. Gemini does the grunt work, Claude gets the summary. |
| [agent-genesis](commands/agent-genesis.md) | Generate Claude Code expert agent prompts for any technology platform. |
| [save](commands/save.md) | Save session state before ending. Creates claude-state.json and claude-progress.md for session continuity. |
| [load](commands/load.md) | Load session context from saved state. Shows what changed, suggests next action. |
| [plan](commands/plan.md) | Create and persist project plans. Captures Plan Mode state and writes to git-trackable PLAN.md. |
| [review](commands/review.md) | Code review staged changes or specific files. Analyzes bugs, security, performance, style. |
| [test](commands/test.md) | Generate tests with automatic framework detection (Jest, Vitest, pytest, etc.). |
| [explain](commands/explain.md) | Deep explanation of complex code, files, or concepts. Architecture, data flow, design decisions. |

### Skills

| Skill | Description |
|-------|-------------|
| [agent-discovery](skills/agent-discovery/) | Analyze tasks and recommend specialized agents |
| [code-stats](skills/code-stats/) | Analyze codebase with tokei and difft |
| [data-processing](skills/data-processing/) | Process JSON with jq, YAML/TOML with yq |
| [git-workflow](skills/git-workflow/) | Enhanced git operations with lazygit, gh, delta |
| [project-docs](skills/project-docs/) | Scan and synthesize project documentation |
| [python-env](skills/python-env/) | Fast Python environment management with uv |
| [safe-file-reader](skills/safe-file-reader/) | Read files without permission prompts |
| [structural-search](skills/structural-search/) | Search code by AST structure with ast-grep |
| [task-runner](skills/task-runner/) | Run project commands with just |

### Agents

| Agent | Description |
|-------|-------------|
| [astro-expert](agents/astro-expert.md) | Astro projects, SSR/SSG, Cloudflare deployment |
| [asus-router-expert](agents/asus-router-expert.md) | Asus routers, network hardening, Asuswrt-Merlin |
| [aws-fargate-ecs-expert](agents/aws-fargate-ecs-expert.md) | Amazon ECS on Fargate, container deployment |
| [bash-expert](agents/bash-expert.md) | Defensive Bash scripting, CI/CD pipelines |
| [cloudflare-expert](agents/cloudflare-expert.md) | Cloudflare Workers, Pages, DNS, security |
| [craftcms-expert](agents/craftcms-expert.md) | Craft CMS content modeling, Twig, plugins, GraphQL |
| [cypress-expert](agents/cypress-expert.md) | Cypress E2E and component testing, custom commands, CI/CD |
| [fetch-expert](agents/fetch-expert.md) | Parallel web fetching with retry logic |
| [firecrawl-expert](agents/firecrawl-expert.md) | Web scraping, crawling, structured extraction |
| [javascript-expert](agents/javascript-expert.md) | Modern JavaScript, async patterns, optimization |
| [laravel-expert](agents/laravel-expert.md) | Laravel framework, Eloquent, testing |
| [react-expert](agents/react-expert.md) | React hooks, state management, Server Components, performance |
| [typescript-expert](agents/typescript-expert.md) | TypeScript type system, generics, utility types, strict mode |
| [vue-expert](agents/vue-expert.md) | Vue 3, Composition API, Pinia state management, performance |
| [payloadcms-expert](agents/payloadcms-expert.md) | Payload CMS architecture and configuration |
| [playwright-roulette-expert](agents/playwright-roulette-expert.md) | Playwright automation for casino testing |
| [postgres-expert](agents/postgres-expert.md) | PostgreSQL management and optimization |
| [project-organizer](agents/project-organizer.md) | Reorganize directory structures, cleanup |
| [python-expert](agents/python-expert.md) | Advanced Python, testing, optimization |
| [rest-expert](agents/rest-expert.md) | RESTful API design, HTTP methods, status codes |
| [sql-expert](agents/sql-expert.md) | Complex SQL queries, optimization, indexing |
| [tailwind-expert](agents/tailwind-expert.md) | Tailwind CSS, responsive design |
| [wrangler-expert](agents/wrangler-expert.md) | Cloudflare Workers deployment, wrangler.toml |
| [claude-code-meta-expert](agents/claude-code-meta-expert.md) | Claude Code architecture, extension development, quality review |

## Testing & Validation

Validate all extensions before committing:

```bash
# Run full validation (requires just)
just test

# Or run directly
bash tests/validate.sh

# Windows
powershell tests/validate.ps1
```

### What's Validated
- YAML frontmatter syntax
- Required fields (name, description)
- Naming conventions (kebab-case)
- File structure (agents/*.md, skills/*/SKILL.md)

### Available Tasks

```bash
just              # List all tasks
just test         # Run full validation
just validate-yaml # YAML only
just validate-names # Naming only
just stats        # Count extensions
just list-agents  # List all agents
```

## Session Continuity: `/save` + `/load`

These commands fill a gap in Claude Code's native session management.

**The problem:** Claude Code's `--resume` flag restores conversation history, but **TodoWrite task state does not persist between sessions—by design**. Claude Code treats each session as isolated; the philosophy is that persistent state belongs in files you control.

TodoWrite tasks are stored at `~/.claude/todos/[session-id].json` and deleted when the session ends. This is intentional.

**The solution:** `/save` and `/load` implement the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

### What Persists vs What Doesn't

| Claude Code Feature | Persists? | Location |
|---------------------|-----------|----------|
| Conversation history | Yes | Internal (use `--resume`) |
| CLAUDE.md context | Yes | `./CLAUDE.md` |
| TodoWrite tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

### How `/save` + `/load` Works

```
Session 1:
  [work on tasks]
  /save "Stopped at auth module"    # Writes .claude/claude-state.json + claude-progress.md

Session 2:
  /load                              # Restores TodoWrite, shows git diff, suggests next action
  → "In progress: Auth module refactor"
  → "Notes: Stopped at auth module"
```

### Why Not Just Use `--resume`?

| Feature | `--resume` | `/save` + `/load` |
|---------|------------|-------------------|
| Conversation history | Yes | No |
| TodoWrite tasks | **No** | Yes |
| Git context | No | Yes |
| Human-readable summary | No | Yes |
| Git-trackable | No | Yes |
| Works across machines | No | Yes (if committed) |
| Team sharing | No | Yes |

**Use both together:** `claude --resume` for conversation context, `/load` for task state.

## Updating

Pull updates including submodules:
```bash
git pull --recurse-submodules
git submodule update --remote
```

Then re-run the install script.

## License

MIT

---

*Extend Claude Code. Your way.*
