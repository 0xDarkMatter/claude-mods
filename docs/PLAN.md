# Claude-Mods: Project Plan & Roadmap

**Goal**: A centralized repository of custom Claude Code commands, agents, and skills that enhance Claude Code's native capabilities with persistent session state, specialized expert agents, and streamlined workflows.

**Created**: 2025-11-27
**Last Updated**: 2025-12-22
**Status**: Active Development

---

## Current Inventory

| Component | Count | Notes |
|-----------|-------|-------|
| Agents | 23 | Domain experts (Python, Go, Rust, React, etc.) |
| Skills | 30 | Pattern libraries (Python deep, others emerging) |
| Commands | 11 | Workflow automation |
| Rules | 4 | CLI tools, thinking, commit style, naming |
| Output Styles | 1 | Vesper personality |
| Hooks | 0 | Config examples only |

---

## Completed Milestones

### Core Infrastructure
- [x] Session continuity (`/plan --save`, `/plan --load`)
- [x] Plan persistence to `docs/PLAN.md`
- [x] Agent genesis system (`/spawn`)
- [x] Installation scripts (Unix + Windows)

### Expert Agents (23)
- [x] Languages: Python, TypeScript, JavaScript, Go, Rust, SQL, Bash
- [x] Frontend: React, Vue, Astro
- [x] Backend: Laravel, PayloadCMS, CraftCMS
- [x] Infrastructure: AWS Fargate, Cloudflare, Wrangler
- [x] Testing: Cypress, Playwright
- [x] Databases: PostgreSQL, SQL patterns
- [x] Specialized: Claude-architect, Project-organizer

### Skills (30)
- [x] Python patterns (8): async, cli, database, env, fastapi, observability, pytest, typing
- [x] Claude Code internals: debug, headless, hooks, templates
- [x] Workflows: git, data-processing, structural-search, task-runner
- [x] Patterns: REST, SQL, security, testing, tailwind

### Commands (11)
- [x] Planning: `/plan`, `/sync`, `/atomise`
- [x] Development: `/review`, `/testgen`, `/explain`
- [x] Multi-model: `/conclave`, `/spawn`
- [x] Utilities: `/pulse`, `/setperms`, `/archive`

### Documentation
- [x] ARCHITECTURE.md - Extension system guide with authority levels
- [x] README.md - Project overview and usage
- [x] AGENTS.md - Quick reference

---

## Enhancement Roadmap

### Tier 1: High Impact, Low Effort

#### Output Style Variations

| Style | Personality | Best For |
|-------|-------------|----------|
| **Vesper** | Sophisticated British wit | General work (exists) |
| **Spartan** | Minimal, bullet-points only | Quick tasks |
| **Mentor** | Patient, educational | Learning, onboarding |
| **Executive** | High-level summaries | Non-technical stakeholders |

#### Rules Expansion

| Rule | Purpose | Status |
|------|---------|--------|
| `cli-tools.md` | Modern CLI preferences | Done |
| `thinking.md` | Extended thinking triggers | Done |
| `commit-style.md` | Conventional commits format | Done |
| `naming-conventions.md` | Component naming patterns | Done |
| `code-review.md` | Review checklist | Future |
| `testing-philosophy.md` | Coverage expectations | Future |

#### Hook Implementations

| Hook | Purpose |
|------|---------|
| `pre-commit-lint.sh` | Run linter before committing |
| `post-edit-format.sh` | Auto-format after edits |
| `dangerous-cmd-warn.sh` | Confirm destructive commands |

### Tier 2: High Impact, Medium Effort

#### Agent Gaps

| Agent | Why It Matters |
|-------|----------------|
| `docker-expert` | Containerisation is ubiquitous |
| `github-actions-expert` | CI/CD complexity |
| `nextjs-expert` | App Router specifics |
| `testing-architect` | Strategy decisions |
| `api-design-expert` | OpenAPI, versioning |

#### Command Gaps

| Command | Purpose |
|---------|---------|
| `/debug` | Systematic debugging workflow |
| `/migrate` | Framework/version upgrades |
| `/refactor` | Safe refactoring |
| `/secure` | Security audit checklist |

#### Skill Parity

Languages needing Python-level depth:
- `typescript-patterns/`
- `go-patterns/`
- `rust-patterns/`

### Tier 3: Strategic Expansions

- **Template System**: Project scaffolding via `/scaffold`
- **MCP Server Catalog**: Curated high-value servers
- **Feedback System**: Track tool effectiveness

---

## Priority Matrix

```
                    IMPACT
                    High         Low
            +-----------+-----------+
       Low  | Output    | Templates |
            | Styles    |           |
    EFFORT  | Rules     | MCP       |
            | Hooks     | Catalog   |
            +-----------+-----------+
       High | Agent     | Analytics |
            | Gaps      |           |
            | Commands  | Lang      |
            |           | Parity    |
            +-----------+-----------+
```

---

## Immediate Next Steps

- [x] Create `rules/commit-style.md`
- [x] Create `rules/naming-conventions.md`
- [ ] Create Spartan output style
- [ ] Add docker-expert agent
- [ ] Implement `/debug` command

---

## Open Questions

- Should agents auto-update from a central registry?
- How to handle agent versioning?
- Should there be a "recommended agents" list per project type?

---

## Guiding Principle

> The best enhancements solve problems you've already felt. Follow the pain.

---

*Plan managed by `/plan` command. Last updated: 2025-12-22*
