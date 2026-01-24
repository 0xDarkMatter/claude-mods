# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code:
- **22 expert agents** for specialized domains (React, Python, Go, Rust, AWS, etc.)
- **3 commands** for session management (/sync, /save) and experimental features (/canvas)
- **38 skills** for CLI tools, patterns, workflows, and development tasks
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
| `rules/` | Claude Code rules (5 files: cli-tools, thinking, commit-style, naming-conventions, skill-agent-updates) |
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

**CLI Tools:** Use `rg` over grep, `fd` over find, `eza` over ls, `bat` over cat, `markitdown` for documents

**Web Fetching:** WebFetch → Jina (`r.jina.ai/`) → `firecrawl` → firecrawl-expert agent

**Extended Thinking:** "think" < "think hard" < "think harder" < "ultrathink"

**Tasks API:** Use `TaskCreate`, `TaskList`, `TaskUpdate`, `TaskGet` for task management. Tasks are session-scoped (don't persist). Use `/save` to capture and `/sync` to restore.

**Session Cache:** v3.0 schema stores full task objects (subject, description, activeForm, status, blockedBy). Legacy v2.0 files auto-migrate on `/sync`.

## Performance

**MCP Tool Search:** When using multiple MCP servers, enable tool search to save context:

```json
// .claude/settings.local.json
{
  "env": {
    "ENABLE_TOOL_SEARCH": "true"
  }
}
```

| Value | Behavior |
|-------|----------|
| `"auto"` | Enable when MCP tools > 10% context (default) |
| `"true"` | Always enabled (recommended with many MCP servers) |
| `"false"` | Disabled, all tools loaded upfront |

Requires Sonnet 4+ or Opus 4+.

## Testing

```bash
cd tests && just test
```
