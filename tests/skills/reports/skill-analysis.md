# Skill Activation Analysis

Generated: 2025-12-20

## How Skills Actually Work

**Important:** Skills are NOT automatically triggered by keywords. They work like this:

1. All skill descriptions are loaded into Claude's system prompt at startup
2. Claude reads user messages and decides whether to invoke a skill
3. Claude uses the `Skill` tool to explicitly activate: `skill: "data-processing"`
4. The skill's SKILL.md content is then loaded into context

**The "Triggers on:" keywords are hints for Claude**, not automatic activation rules.

---

## Skill-by-Skill Analysis

### data-processing
**Triggers:** parse JSON, extract from YAML, query config, Docker Compose, K8s manifests, GitHub Actions workflows, package.json, filter data

| Issue | Severity | Details |
|-------|----------|---------|
| Generic triggers | Medium | "package.json" triggers on ANY package.json mention |
| Overlap with built-in | High | Claude already knows jq/yq - may not invoke skill |
| No visibility | High | User won't know skill was used |

**Will it fire?** Maybe. Claude might just use jq directly without invoking the skill.

---

### git-workflow
**Triggers:** stage changes, create PR, review PR, check issues, git diff, commit interactively, GitHub operations, rebase, stash, bisect

| Issue | Severity | Details |
|-------|----------|---------|
| Competes with built-in git | High | Claude has built-in git commit flow |
| Too many triggers | Medium | 10 different trigger phrases |
| lazygit is TUI | Low | Can't actually use lazygit in non-interactive mode |

**Will it fire?** Unlikely for common git operations. Built-in behavior takes precedence.

---

### structural-search
**Triggers:** find all calls to X, search for pattern, refactor usages, find where function is used, structural search

| Issue | Severity | Details |
|-------|----------|---------|
| Competes with Grep tool | High | Claude defaults to ripgrep for code search |
| Specific tool (ast-grep) | Low | Clear use case distinction |

**Will it fire?** Only if user specifically asks for AST/structural search.

---

### code-stats
**Triggers:** how big is codebase, count lines of code, what languages, show semantic diff, compare files, code statistics

| Issue | Severity | Details |
|-------|----------|---------|
| Unique triggers | Low | "code statistics" is fairly specific |
| tokei vs wc -l | Medium | Claude might use simpler approach |

**Will it fire?** Probably yes for "count lines of code" type requests.

---

### file-search
**Triggers:** fd, ripgrep, rg, find files, search code, fzf, fuzzy find, search codebase

| Issue | Severity | Details |
|-------|----------|---------|
| Redundant with built-in | Critical | Claude has Glob/Grep tools built-in |
| Tool names as triggers | Low | If user says "use fd", skill helps |

**Will it fire?** Only if user explicitly mentions fd/fzf. Otherwise Claude uses built-in tools.

---

### find-replace
**Triggers:** sd, find replace, batch replace, sed replacement, string replacement, rename

| Issue | Severity | Details |
|-------|----------|---------|
| Competes with Edit tool | High | Claude prefers Edit tool for replacements |
| Unique for batch ops | Medium | "batch replace across files" is specific |

**Will it fire?** Only for batch/multi-file operations.

---

### doc-scanner
**Triggers:** review codebase, understand project, explore codebase, conventions, agents

| Issue | Severity | Details |
|-------|----------|---------|
| Very generic | High | Many requests "understand codebase" |
| Good use case | Low | Finding AGENTS.md, CLAUDE.md is useful |

**Will it fire?** Yes, for "explore codebase" type requests. May over-fire.

---

### task-runner
**Triggers:** run tests, build project, list tasks, check available commands, run script, project commands

| Issue | Severity | Details |
|-------|----------|---------|
| Very generic | Critical | "run tests" is extremely common |
| just-specific | Medium | Only useful if project has justfile |

**Will it fire?** Too often for "run tests" - even when no justfile exists.

---

### project-planner
**Triggers:** sync plan, update plan, check status, plan is stale, track progress, project planning

| Issue | Severity | Details |
|-------|----------|---------|
| Specific triggers | Low | "sync plan" is specific enough |
| Depends on /plan usage | Medium | Only useful if user uses /plan |

**Will it fire?** Appropriately - triggers are specific.

---

### python-env
**Triggers:** uv, venv, pip, pyproject, python environment, install package, dependencies

| Issue | Severity | Details |
|-------|----------|---------|
| Tool-specific | Low | "uv" is specific |
| Generic overlap | Medium | "install package" could be npm too |

**Will it fire?** Yes for Python-specific requests.

---

### rest-patterns
**Triggers:** rest api, http methods, status codes, api design, endpoint design, api versioning, rate limiting, caching

| Issue | Severity | Details |
|-------|----------|---------|
| Reference-only | Low | No executable commands |
| Good specificity | Low | "api design" is clear |

**Will it fire?** Appropriately for API design questions.

---

### sql-patterns
**Triggers:** sql patterns, cte example, window functions, sql join, index strategy, pagination sql

| Issue | Severity | Details |
|-------|----------|---------|
| Reference-only | Low | No executable commands |
| Specific | Low | "window functions" is clear |

**Will it fire?** Appropriately for SQL questions.

---

### sqlite-ops
**Triggers:** sqlite, sqlite3, aiosqlite, local database, database schema, migration, wal mode

| Issue | Severity | Details |
|-------|----------|---------|
| Clear scope | Low | sqlite-specific |
| Overlaps with sql-patterns | Medium | Both cover SQL |

**Will it fire?** Yes for SQLite-specific questions.

---

### tailwind-patterns
**Triggers:** tailwind, utility classes, responsive design, tailwind config, dark mode css, tw classes

| Issue | Severity | Details |
|-------|----------|---------|
| Framework-specific | Low | "tailwind" is clear |
| Reference-only | Low | No executable commands |

**Will it fire?** Yes for Tailwind questions.

---

### mcp-patterns
**Triggers:** mcp server, model context protocol, tool handler, mcp resource, mcp tool

| Issue | Severity | Details |
|-------|----------|---------|
| Very specific | Low | MCP is niche topic |
| Reference-only | Low | Patterns and examples |

**Will it fire?** Appropriately for MCP development.

---

### tool-discovery
**Triggers:** which agent, which skill, what tool should I use, help me choose, recommend agent, find the right tool

| Issue | Severity | Details |
|-------|----------|---------|
| Meta-skill | Low | Helps find other skills |
| May not be needed | Medium | Claude already has tool descriptions |

**Will it fire?** When user asks for help choosing tools.

---

## Summary: Problem Skills

| Skill | Issue | Recommendation |
|-------|-------|----------------|
| **file-search** | Redundant with built-in Glob/Grep | Remove or rename to "fd-fzf-patterns" |
| **task-runner** | Too generic, just-specific | Add "justfile" to triggers, remove generic ones |
| **git-workflow** | Competes with built-in git flow | Focus on lazygit/delta only |
| **find-replace** | Competes with Edit tool | Focus on batch/multi-file only |
| **doc-scanner** | Too generic | Already works well |

## How to Know If a Skill Was Used

Currently: **You can't easily tell.**

Options to add visibility:
1. **Log skill invocations** - Add a hook that logs when Skill tool is called
2. **Skill announces itself** - First line of skill output says "[data-processing skill]"
3. **Status line** - Configure Claude Code to show active skill
