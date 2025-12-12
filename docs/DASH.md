# 🎛️ Claude Mods Dashboard
**Updated:** 2025-12-12 | **Extensions:** 45 | **Lines:** 9,567

---

## 📊 Quick Stats

| Category | Count | Lines |
|----------|-------|-------|
| 🤖 **Agents** | 24 | 5,910 |
| ⚡ **Skills** | 10 | 836 |
| 🔧 **Commands** | 10 | 2,708 |
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
| 🤖 **fetch-expert** | Utility | Parallel web fetching |
| 🤖 **firecrawl-expert** | Scraping | Web crawling, extraction |
| 🤖 **javascript-expert** | Language | Modern JS, async |
| 🤖 **laravel-expert** | Backend | Laravel, Eloquent |
| 🤖 **payloadcms-expert** | CMS | Payload architecture |
| 🤖 **playwright-roulette-expert** | Testing | Casino automation |
| 🤖 **postgres-expert** | Database | PostgreSQL optimization |
| 🤖 **project-organizer** | Utility | Directory restructuring |
| 🤖 **python-expert** | Language | Advanced Python |
| 🤖 **react-expert** | Frontend | Hooks, Server Components |
| 🤖 **rest-expert** | API | RESTful design |
| 🤖 **sql-expert** | Database | Complex queries |
| 🤖 **tailwind-expert** | CSS | Utility-first styling |
| 🤖 **typescript-expert** | Language | Type system, generics |
| 🤖 **vue-expert** | Frontend | Vue 3, Composition API |
| 🤖 **wrangler-expert** | Cloud | Workers deployment |
| 🤖 **asus-router-expert** | Network | Router config, Merlin |

---

## ⚡ Skills

| Skill | Tool | Triggers |
|-------|------|----------|
| ⚡ **agent-discovery** | — | "Which agent?", recommend tools |
| ⚡ **code-stats** | tokei, difft | Line counts, semantic diffs |
| ⚡ **data-processing** | jq, yq | JSON, YAML, TOML |
| ⚡ **git-workflow** | lazygit, gh, delta | Stage, PR, review |
| ⚡ **project-docs** | — | AGENTS.md, conventions |
| ⚡ **project-planner** | — | Stale plans, `/plan` |
| ⚡ **python-env** | uv | Fast venv, pip |
| ⚡ **safe-file-reader** | bat, eza | View without prompts |
| ⚡ **structural-search** | ast-grep | AST patterns |
| ⚡ **task-runner** | just | Run tests, build |

---

## 🔧 Commands

| Command | Purpose |
|---------|---------|
| 🔧 `/agent-genesis` | Generate expert agent prompts |
| 🔧 `/explain` | Deep code/concept explanation |
| 🔧 `/g-slave` | Dispatch Gemini for large codebases |
| 🔧 `/init-tools` | Quick project permissions setup |
| 🔧 `/plan` | Create persistent project plans |
| 🔧 `/saveplan` | Save plan state |
| 🔧 `/loadplan` | Restore plan from saved state |
| 🔧 `/showplan` | Show plan progress |
| 🔧 `/review` | Code review staged changes |
| 🔧 `/test` | Generate tests |

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
