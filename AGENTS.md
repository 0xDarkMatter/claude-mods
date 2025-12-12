# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code:
- **24 expert agents** for specialized domains (React, Python, AWS, etc.)
- **11 slash commands** for workflows (/sync, /plan, /review, etc.)
- **10 skills** for CLI tool integration (git-workflow, code-stats, etc.)

## Key Directories

| Directory | Purpose |
|-----------|---------|
| `agents/` | Expert subagent prompts (.md files) |
| `commands/` | Slash command definitions |
| `skills/` | Skill definitions with SKILL.md |
| `rules/` | Claude Code rules (cli-tools.md) |
| `tools/` | Modern CLI toolkit documentation |
| `tests/` | Validation scripts + justfile |
| `scripts/` | Install scripts |
| `docs/` | PLAN.md, DASH.md |

## Session Init

On "INIT:" message at session start:
1. Read the specified file (.claude/.context-init.md)
2. Proceed with user request - no summary needed

## CLI Tool Preferences

See `rules/cli-tools.md` for modern CLI tool preferences:
- Use `rg` over grep, `fd` over find, `eza` over ls
- Use `bat` over cat, `dust` over du, `tldr` over man
- Web fetching: WebFetch → Jina → firecrawl → firecrawl-expert

## Testing

Run from `tests/` directory:
```bash
cd tests && just test
```
