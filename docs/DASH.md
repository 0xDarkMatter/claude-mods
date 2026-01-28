# 🎛️ Claude Mods Dashboard
**Updated:** 2025-12-14 | **Extensions:** 50 | **Lines:** 15,300

---

## 📊 Quick Stats

| Category | Count | Lines |
|----------|-------|-------|
| 🤖 **Agents** | 21 | 7,552 |
| ⚡ **Skills** | 16 | 3,850 |
| 🔧 **Commands** | 9 | 3,720 |
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
| ⚡ **git-workflow** | lazygit, gh, delta | Stage, PR, review, rebase, stash, bisect |
| ⚡ **doc-scanner** | — | AGENTS.md, conventions, consolidate docs |
| ⚡ **project-planner** | — | Stale plans, session commands |
| ⚡ **python-env** | uv | Fast venv, pyproject.toml |
| ⚡ **task-runner** | just | Run tests, build |

---

## 🔧 Commands

| Command | Purpose |
|---------|---------|
| 🔧 `/sync` | Session bootstrap, restore state, show status |
| 🔧 `/save` | Save session state (tasks, plan, git context) |
| 🔧 `/review` | Code review staged changes |
| 🔧 `/testgen` | Generate tests with expert routing |
| 🔧 `/explain` | Deep code/concept explanation |
| 🔧 `/spawn` | Generate expert agents |
| 🔧 `/atomise` | Atom of Thoughts reasoning with confidence tracking |
| 🔧 `/setperms` | Set tool permissions |
| 🔧 `/introspect` | Analyze previous session logs |

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
