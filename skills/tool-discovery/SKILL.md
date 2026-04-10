---
name: tool-discovery
description: "Recommend the right agents and skills for any task. Covers both heavyweight agents (Task tool) and lightweight skills (Skill tool). Triggers on: which agent, which skill, what tool should I use, help me choose, recommend agent, find the right tool."
license: MIT
allowed-tools: "Read Glob"
metadata:
  author: claude-mods
  related-skills: claude-code-templates, claude-code-debug
---

# Tool Discovery

Recommend the right agents and skills for any task.

## Decision Flowchart

```
Is this a reference/lookup task?
├── YES → Use a SKILL (lightweight, auto-injects)
└── NO → Does it require reasoning/decisions?
         ├── YES → Use an AGENT (heavyweight, spawns subagent)
         └── MAYBE → Check catalogs below
```

**Rule:** Skills = patterns/reference. Agents = decisions/expertise.

## Quick Skill Reference

| Skill | Triggers |
|-------|----------|
| **file-search** | fd, rg, fzf, find files |
| **find-replace** | sd, batch replace |
| **code-stats** | tokei, difft, line counts |
| **data-processing** | jq, yq, json, yaml |
| **structural-search** | ast-grep, sg, ast pattern |
| **git-ops** | git, gh, lazygit, delta, commit, PR, release, rebase |
| **python-env** | uv, venv, pyproject |
| **go-ops** | golang, go, goroutine, channel, context, errgroup, go test |
| **rust-ops** | rust, cargo, ownership, tokio, serde, trait, Result, Option |
| **typescript-ops** | typescript, type system, generics, utility types, Zod |
| **docker-ops** | docker, Dockerfile, docker-compose, multi-stage build |
| **ci-cd-ops** | github actions, CI, CD, pipeline, release, workflow |
| **api-design-ops** | api design, gRPC, GraphQL, REST advanced, protobuf |
| **rest-ops** | http methods, status codes |
| **sql-ops** | cte, window functions |
| **postgres-ops** | postgresql, postgres, EXPLAIN ANALYZE, vacuum, pgbouncer, JSONB, RLS, replication |
| **sqlite-ops** | sqlite, aiosqlite |
| **tailwind-ops** | tailwind, tw classes, dark mode, responsive |
| **mcp-ops** | mcp server, fastmcp, tool handler, transport |
| **react-ops** | react, hooks, useState, next.js, RSC, zustand |
| **vue-ops** | vue, composition api, pinia, nuxt, script setup |
| **javascript-ops** | javascript, node, esm, async/await, event loop |
| **astro-ops** | astro, islands, content collections, partial hydration |
| **laravel-ops** | laravel, eloquent, artisan, sanctum, pest |
| **nginx-ops** | nginx, reverse proxy, ssl, load balancer, proxy_pass |
| **auth-ops** | jwt, oauth2, session, rbac, passkey, mfa, login |
| **monitoring-ops** | prometheus, grafana, opentelemetry, SLO, alerting |
| **debug-ops** | debug, crash, memory leak, race condition, bisect |
| **perf-ops** | performance, profiling, flamegraph, bundle size, load test, benchmark |
| **migrate-ops** | migrate, upgrade, breaking changes, codemod, version upgrade |
| **refactor-ops** | refactor, extract, code smell, dead code, rename, restructure |
| **scaffold** | scaffold, boilerplate, project template, init project, new project |
| **log-ops** | JSONL, log analysis, parse logs, lnav, log search, timeline |

## Quick Agent Reference

| Agent | Triggers |
|-------|----------|
| **python-expert** | Python, async, pytest |
| **typescript-expert** | TypeScript, types, generics |
| **react-expert** | React, hooks, state |
| **postgres-expert** | PostgreSQL, query optimization |
| **cloudflare-expert** | Workers, KV, D1, R2 |
| **Explore** | "where is", "find" |
| **Plan** | design, architect |

## How to Launch

**Skills:**
```
Skill tool → skill: "file-search"
```

**Agents:**
```
Task tool → subagent_type: "python-expert"
         → prompt: "Your task"
```

## Match by Task Type

| Task | Skill First | Agent If Needed |
|------|-------------|-----------------|
| "How to write a CTE?" | sql-ops | sql-expert |
| "Optimize this query" | — | postgres-expert |
| "Find files named X" | file-search | Explore |
| "Set up Python project" | python-env | python-expert |
| "What HTTP status for X?" | rest-ops | — |
| "React Server Components?" | react-ops | react-expert |
| "Vue 3 composable pattern" | vue-ops | vue-expert |
| "Configure nginx SSL" | nginx-ops | — |
| "JWT vs session auth" | auth-ops | — |
| "Set up Prometheus" | monitoring-ops | — |
| "Debug memory leak" | debug-ops | — |

## Tips

- **Skills are cheaper** - Use for lookups, patterns
- **Agents are powerful** - Use for decisions, optimization
- **Don't over-recommend** - Max 2-3 tools per task

## Additional Resources

For complete catalogs, load:
- `./references/agents-catalog.md` - All agents with capabilities
- `./references/skills-catalog.md` - All skills with details
