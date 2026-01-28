# Reserved Command Names

**Source:** https://code.claude.com/docs/en/interactive-mode#built-in-commands

These are Claude Code's built-in slash commands. **Do not create skills or commands with these names** to avoid conflicts.

## Built-in Commands (Reserved)

| Command | Purpose |
|---------|---------|
| `/clear` | Clear conversation history |
| `/compact` | Compact conversation with optional focus instructions |
| `/config` | Open Settings interface (Config tab) |
| `/context` | Visualize current context usage |
| `/cost` | Show token usage statistics |
| `/doctor` | Check installation health |
| `/exit` | Exit the REPL |
| `/export` | Export conversation to file or clipboard |
| `/help` | Get usage help |
| `/init` | Initialize project with CLAUDE.md |
| `/mcp` | Manage MCP server connections |
| `/memory` | Edit CLAUDE.md memory files |
| `/model` | Select or change AI model |
| `/permissions` | View or update permissions |
| `/plan` | Enter plan mode |
| `/rename` | Rename current session |
| `/resume` | Resume a conversation |
| `/rewind` | Rewind conversation and/or code |
| `/stats` | Visualize daily usage and history |
| `/status` | Show version, model, account info |
| `/statusline` | Set up status line UI |
| `/tasks` | List and manage background tasks |
| `/teleport` | Resume remote session from claude.ai |
| `/theme` | Change color theme |
| `/todos` | List current TODO items |
| `/usage` | Show plan usage limits |
| `/vim` | Enable vim-style editing |

## Reserved Patterns

Also avoid:
- `/mcp__*` - Reserved for MCP server prompts
- Single-letter commands - May conflict with future shortcuts

## Our Safe Names

Current claude-mods skills/commands (verified no conflicts):

**Commands:**
- atomise, canvas, explain, introspect, save, setperms, spawn, sync

**Skills:**
- review, testgen, code-stats, doc-scanner, file-search, find-replace, git-workflow, tool-discovery, task-runner, python-env, structural-search, data-processing, markitdown, etc.

## Before Adding New Skills

1. Check this list
2. Check https://code.claude.com/docs/en/interactive-mode#built-in-commands for updates
3. Avoid generic names that Anthropic might add (e.g., `/test`, `/run`, `/build`, `/deploy`)

## Last Updated

2025-01-23
