# Claude-Mods: Project Plan & Roadmap

**Goal**: A centralized repository of custom Claude Code commands, agents, and skills that enhance Claude Code's native capabilities with persistent session state, specialized expert agents, and streamlined workflows.

**Created**: 2025-11-27
**Last Updated**: 2026-01-24
**Status**: Active Development

---

## Current Inventory

| Component | Count | Notes |
|-----------|-------|-------|
| Agents | 22 | Domain experts (Python, Go, Rust, React, etc.) |
| Skills | 38 | Pattern libraries, CLI tools, workflows, dev tasks |
| Commands | 3 | Session management (sync, save) + experimental (canvas) |
| Rules | 5 | CLI tools, thinking, commit style, naming, skill-agent-updates |
| Output Styles | 1 | Vesper personality |
| Hooks | 0 | Config examples only |

---

## Completed Milestones

### Core Infrastructure
- [x] Session continuity (`/save`, `/sync`)
- [x] Plan persistence to `docs/PLAN.md`
- [x] Agent genesis system (`/spawn`)
- [x] Installation scripts (Unix + Windows)

### Expert Agents (22)
- [x] Languages: Python, TypeScript, JavaScript, Go, Rust, SQL, Bash
- [x] Frontend: React, Vue, Astro
- [x] Backend: Laravel, PayloadCMS, CraftCMS
- [x] Infrastructure: AWS Fargate, Cloudflare, Wrangler
- [x] Testing: Cypress
- [x] Databases: PostgreSQL, SQL patterns
- [x] Specialized: Claude-architect, Project-organizer

### Skills (38)
- [x] Python patterns (8): async, cli, database, env, fastapi, observability, pytest, typing
- [x] Claude Code internals: debug, headless, hooks, templates
- [x] Workflows: git, data-processing, structural-search, task-runner
- [x] Patterns: REST, SQL, security, testing, tailwind
- [x] Development: explain, spawn, atomise, setperms, introspect, review, testgen

### Commands (3)
- [x] Session: `/save`, `/sync`
- [x] Experimental: `/canvas`

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

#### Skill Gaps

| Skill | Purpose |
|-------|---------|
| `debug` | Systematic debugging workflow |
| `migrate` | Framework/version upgrades |
| `refactor` | Safe refactoring |
| `secure` | Security audit checklist |

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
            | Skills    | Lang      |
            |           | Parity    |
            +-----------+-----------+
```

---

## Immediate Next Steps

### Command-to-Skill Consolidation (Complete)

Most commands have been converted to skills for better discovery and on-demand loading. See `docs/COMMAND-SKILL-PATTERN.md`.

**Completed conversions:**
- [x] `/testgen` → `skills/testgen/`
- [x] `/review` → `skills/review/`
- [x] `/explain` → `skills/explain/`
- [x] `/spawn` → `skills/spawn/`
- [x] `/atomise` → `skills/atomise/`
- [x] `/setperms` → `skills/setperms/`
- [x] `/introspect` → `skills/introspect/`

**Remaining as commands:**
- `/sync` - Session bootstrap (paired with /save)
- `/save` - Session persistence (paired with /sync)
- `/canvas` - Experimental (Warp-specific)

---

### Planned Work

- [x] Create `rules/commit-style.md`
- [x] Create `rules/naming-conventions.md`
- [ ] Create Spartan output style
- [ ] Add docker-expert agent
- [ ] Add `/debug` skill (systematic debugging workflow)

---

## Open Questions

- Should agents auto-update from a central registry?
- How to handle agent versioning?
- Should there be a "recommended agents" list per project type?

---

## Guiding Principle

> The best enhancements solve problems you've already felt. Follow the pain.

---

*Plan managed by `/save` command. Last updated: 2026-01-24*
