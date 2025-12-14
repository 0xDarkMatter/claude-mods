# 🎛️ Claude Mods Dashboard
**Updated:** 2025-12-13 | **Extensions:** 51 | **Lines:** 13,553

---

## 📊 Quick Stats

| Category | Count | Lines |
|----------|-------|-------|
| 🤖 **Agents** | 21 | 7,552 |
| ⚡ **Skills** | 18 | 2,725 |
| 🔧 **Commands** | 9 | 3,276 |
| 📏 **Rules** | 1 | 113 |
| 🧩 **Templates** | 2 | — |

---

## 🤖 Agents

| Agent | Domain | Specialty |
|-------|--------|-----------|
| 🤖 **claude-architect** | Claude Code | Extensions, MCP, plugins, debugging |
| 🤖 **astro-expert** | Frontend | Astro, SSR/SSG, Cloudflare |
| 🤖 **aws-fargate-ecs-expert** | Cloud | ECS Fargate, containers |
| 🤖 **bash-expert** | DevOps | Shell scripting, CI/CD |
| 🤖 **cloudflare-expert** | Cloud | Workers, Pages, DNS |
| 🤖 **craftcms-expert** | CMS | Craft CMS, Twig, GraphQL |
| 🤖 **cypress-expert** | Testing | E2E, component tests |
| 🤖 **firecrawl-expert** | Scraping | Web crawling, parallel fetch, extraction |
| 🤖 **javascript-expert** | Language | Modern JS, async |
| 🤖 **laravel-expert** | Backend | Laravel, Eloquent |
| 🤖 **payloadcms-expert** | CMS | Payload architecture |
| 🤖 **playwright-roulette-expert** | Testing | Casino automation |
| 🤖 **postgres-expert** | Database | PostgreSQL optimization |
| 🤖 **project-organizer** | Utility | Directory restructuring |
| 🤖 **python-expert** | Language | Advanced Python |
| 🤖 **react-expert** | Frontend | Hooks, Server Components |
| 🤖 **sql-expert** | Database | Complex queries |
| 🤖 **typescript-expert** | Language | Type system, generics |
| 🤖 **vue-expert** | Frontend | Vue 3, Composition API |
| 🤖 **wrangler-expert** | Cloud | Workers deployment |
| 🤖 **asus-router-expert** | Network | Router config, Merlin |

---

## ⚡ Skills

### Pattern Reference Skills
| Skill | Triggers |
|-------|----------|
| ⚡ **rest-patterns** | REST API, HTTP methods, status codes |
| ⚡ **tailwind-patterns** | Tailwind, utility classes, breakpoints |
| ⚡ **sql-patterns** | CTEs, window functions, JOINs |
| ⚡ **sqlite-ops** | SQLite, aiosqlite, local database |
| ⚡ **mcp-patterns** | MCP server, Model Context Protocol |

### CLI Tool Skills
| Skill | Tool | Triggers |
|-------|------|----------|
| ⚡ **file-search** | fd, rg, fzf | Find files, search code, fuzzy select |
| ⚡ **find-replace** | sd | Batch replace, modern sed |
| ⚡ **code-stats** | tokei, difft | Line counts, semantic diffs |
| ⚡ **data-processing** | jq, yq | JSON, YAML, TOML |
| ⚡ **structural-search** | ast-grep | AST patterns |

### Workflow Skills
| Skill | Tool | Triggers |
|-------|------|----------|
| ⚡ **tool-discovery** | — | "Which agent/skill?", recommend tools |
| ⚡ **git-workflow** | lazygit, gh, delta | Stage, PR, review |
| ⚡ **project-docs** | — | AGENTS.md, conventions |
| ⚡ **project-planner** | — | Stale plans, `/plan` |
| ⚡ **python-env** | uv | Fast venv, pyproject.toml |
| ⚡ **safe-file-reader** | bat, eza | View without prompts |
| ⚡ **task-runner** | just | Run tests, build |

---

## 🔧 Commands

| Command | Purpose |
|---------|---------|
| 🔧 `/sync` | Session bootstrap with project context |
| 🔧 `/plan` | Unified planning: create plans, save/load state, show status |
| 🔧 `/review` | Code review staged changes |
| 🔧 `/testgen` | Generate tests with expert routing |
| 🔧 `/explain` | Deep code/concept explanation |
| 🔧 `/spawn` | Generate expert agents |
| 🔧 `/delegate` | Delegate to external LLMs (Gemini, OpenAI) |
| 🔧 `/pulse` | Claude Code ecosystem news digest |
| 🔧 `/setperms` | Set tool permissions |

---

## 📏 Rules

| Rule | Purpose |
|------|---------|
| 📏 **cli-tools** | Prefer modern CLI (fd, rg, eza, bat, uv, jq) |

---

## 🧩 Templates

| Template | Purpose |
|----------|---------|
| 🧩 `settings.local.json` | Permissions and hooks |
| 🧩 `hooks/README.md` | Hook documentation |

---

*✨ Extend Claude Code. Your way.*
