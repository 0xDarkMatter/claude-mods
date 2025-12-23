# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code:
- **23 expert agents** for specialized domains (React, Python, Go, Rust, AWS, etc.)
- **11 slash commands** for workflows (/sync, /plan, /review, /atomise, etc.)
- **30 skills** for CLI tool integration, patterns, and workflows
- **Custom output styles** for response personality (e.g., Vesper)

## Installation

```bash
# Step 1: Add the marketplace
/plugin marketplace add 0xDarkMatter/claude-mods

# Step 2: Install the plugin (globally)
/plugin install claude-mods@0xDarkMatter-claude-mods

# Or clone and run install script
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods && ./scripts/install.sh  # or .\scripts\install.ps1 on Windows
```

## Key Directories

| Directory | Purpose |
|-----------|---------|
| `.claude-plugin/` | Plugin metadata (plugin.json) |
| `agents/` | Expert subagent prompts (.md files) |
| `commands/` | Slash command definitions |
| `skills/` | Skill definitions with SKILL.md |
| `output-styles/` | Response personalities (vesper.md) |
| `hooks/` | Hook examples (pre/post execution) |
| `rules/` | Claude Code rules (4 files: cli-tools, thinking, commit-style, naming-conventions) |
| `tools/` | Modern CLI toolkit documentation |
| `tests/` | Validation scripts + justfile |
| `scripts/` | Install scripts |
| `docs/` | PLAN.md, DASH.md, WORKFLOWS.md |

## Session Init

On "INIT:" message at session start:
1. Read the specified file (.claude/.context-init.md)
2. Proceed with user request - no summary needed

## Key Resources

| Resource | Description |
|----------|-------------|
| `rules/cli-tools.md` | Modern CLI tool preferences (rg, fd, eza, bat) |
| `rules/thinking.md` | Extended thinking triggers (think → ultrathink) |
| `docs/WORKFLOWS.md` | 10 workflow patterns from Anthropic best practices |
| `skills/tool-discovery/` | Find the right library for any task |
| `hooks/README.md` | Pre/post execution hook examples |

## Quick Reference

**CLI Tools:** Use `rg` over grep, `fd` over find, `eza` over ls, `bat` over cat

**Web Fetching:** WebFetch → Jina (`r.jina.ai/`) → `firecrawl` → firecrawl-expert agent

**Extended Thinking:** "think" < "think hard" < "think harder" < "ultrathink"

## Testing

```bash
cd tests && just test
```
