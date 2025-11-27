---
name: agent-discovery
description: "Analyze current task or codebase and recommend specialized agents. Triggers on: which agent, what tool should I use, help me choose, recommend agent, find the right agent, what agents are available."
---

# Agent Discovery

Analyze the current context and recommend the best specialized agents for the task.

## How to Use

1. **Analyze context** - Check file types, project structure, user's request
2. **Match to agents** - Use patterns below to identify relevant agents
3. **Run `/agents`** - Get the full current list of available agents
4. **Recommend** - Suggest 1-2 primary agents with rationale

## Quick Matching Guide

### By File Extension

| Files | Suggested Agent |
|-------|-----------------|
| `.py` | python-expert |
| `.js`, `.ts`, `.jsx`, `.tsx` | javascript-expert |
| `.php`, Laravel | laravel-expert |
| `.sql` | sql-expert, postgres-expert |
| `.sh`, `.bash` | bash-expert |
| `.astro` | astro-expert |
| Tailwind classes | tailwind-expert |

### By Project Type

| Indicators | Suggested Agent |
|------------|-----------------|
| `pyproject.toml`, `setup.py` | python-expert |
| `package.json` | javascript-expert |
| `composer.json` | laravel-expert |
| `wrangler.toml` | wrangler-expert |
| `payload.config.ts` | payloadcms-expert |
| K8s/Docker/AWS | aws-fargate-ecs-expert |
| REST API code | rest-expert |

### By Task Type

| Task | Suggested Agent |
|------|-----------------|
| Explore codebase | Explore |
| Reorganize files | project-organizer |
| Web scraping | firecrawl-expert |
| Fetch multiple URLs | fetch-expert |
| Database optimization | postgres-expert |
| CI/CD scripts | bash-expert |

## Workflow

```
1. User: "Which agent should I use for X?"

2. Claude:
   - Analyze current directory (glob for file types)
   - Check for config files (package.json, pyproject.toml, etc.)
   - Consider user's stated task
   - Run /agents to see full list

3. Output:
   PRIMARY: [agent-name] - [why]
   SECONDARY: [agent-name] - [optional, if relevant]

   To launch: Use Task tool with subagent_type="[agent-name]"
```

## Tips

- Prefer specialized experts over general-purpose for focused tasks
- Suggest parallel execution when agents work on independent concerns
- Maximum 2-3 agents per task - don't over-recommend
- Always run `/agents` first to see what's currently available
