# Claude Mods Dashboard
**Updated:** 2025-12-12 | **Extensions:** 44 total | **Lines:** 9,454

---

## Quick Stats

| Category | Count | Lines |
|----------|-------|-------|
| **Agents** | 24 | 5,910 |
| **Skills** | 10 | 836 |
| **Commands** | 10 | 2,708 |
| **Templates** | 2 | — |

---

## Agents (24)

Expert subagents for specialized domains. Invoked via Task tool with `subagent_type`.

| Agent | Domain | Specialty |
|-------|--------|-----------|
| **claude-architect** | Claude Code | Extensions, MCP, plugins, debugging |
| **astro-expert** | Frontend | Astro, SSR/SSG, Cloudflare |
| **aws-fargate-ecs-expert** | Cloud | ECS Fargate, containers |
| **bash-expert** | DevOps | Shell scripting, CI/CD |
| **cloudflare-expert** | Cloud | Workers, Pages, DNS |
| **craftcms-expert** | CMS | Craft CMS, Twig, GraphQL |
| **cypress-expert** | Testing | E2E, component tests |
| **fetch-expert** | Utility | Parallel web fetching |
| **firecrawl-expert** | Scraping | Web crawling, extraction |
| **javascript-expert** | Language | Modern JS, async |
| **laravel-expert** | Backend | Laravel, Eloquent |
| **payloadcms-expert** | CMS | Payload architecture |
| **playwright-roulette-expert** | Testing | Casino automation |
| **postgres-expert** | Database | PostgreSQL optimization |
| **project-organizer** | Utility | Directory restructuring |
| **python-expert** | Language | Advanced Python |
| **react-expert** | Frontend | Hooks, Server Components |
| **rest-expert** | API | RESTful design |
| **sql-expert** | Database | Complex queries |
| **tailwind-expert** | CSS | Utility-first styling |
| **typescript-expert** | Language | Type system, generics |
| **vue-expert** | Frontend | Vue 3, Composition API |
| **wrangler-expert** | Cloud | Workers deployment |
| **asus-router-expert** | Network | Router config, Merlin |

---

## Skills (10)

Auto-triggered capabilities. Invoked via Skill tool.

| Skill | Tool | Triggers |
|-------|------|----------|
| **agent-discovery** | — | "Which agent?", recommend tools |
| **code-stats** | tokei, difft | Line counts, semantic diffs |
| **data-processing** | jq, yq | JSON, YAML, TOML |
| **git-workflow** | lazygit, gh, delta | Stage, PR, review |
| **project-docs** | — | AGENTS.md, conventions |
| **project-planner** | — | Stale plans, `/plan` |
| **python-env** | uv | Fast venv, pip |
| **safe-file-reader** | bat, eza | View without prompts |
| **structural-search** | ast-grep | AST patterns |
| **task-runner** | just | Run tests, build |

---

## Commands (10)

Slash commands for common workflows.

| Command | Purpose |
|---------|---------|
| `/agent-genesis` | Generate expert agent prompts |
| `/explain` | Deep code/concept explanation |
| `/g-slave` | Dispatch Gemini for large codebases |
| `/init-tools` | Quick project permissions setup |
| `/plan` | Create persistent project plans |
| `/review` | Code review staged changes |
| `/test` | Generate tests (auto-detect framework) |
| `/save` | Save session state (TodoWrite, progress) |
| `/load` | Restore session from saved state |
| `/dash` | Show session dashboard |

---

## Templates

Ready-to-use configurations in `templates/`.

| Template | Purpose |
|----------|---------|
| `settings.local.json` | Permissions and hooks config |
| `rules/cli-tools.md` | CLI tool usage rules |
| `hooks/README.md` | Hook script documentation |

---

## Session Continuity

The `/save` + `/load` commands solve Claude Code's ephemeral TodoWrite problem.

```
Session 1:
  [work on tasks]
  /save "Stopped at auth module"

Session 2:
  /load
  → Restores TodoWrite tasks
  → Shows git diff since save
  → Suggests next action
```

| Feature | `--resume` | `/save` + `/load` |
|---------|------------|-------------------|
| Conversation | Yes | No |
| TodoWrite | No | **Yes** |
| Git context | No | **Yes** |
| Human-readable | No | **Yes** |
| Git-trackable | No | **Yes** |

---

## Validation

```bash
just test          # Full validation
just validate-yaml # YAML only
just validate-names # Naming only
just stats         # Extension counts
```

### What's Checked
- YAML frontmatter syntax
- Required fields (name, description)
- Naming conventions (kebab-case)
- File structure compliance

---

## Installation

```bash
# Clone with submodules
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods

# Install (Windows)
.\install.ps1

# Install (Linux/macOS)
./install.sh
```

---

*Extend Claude Code. Your way.*
