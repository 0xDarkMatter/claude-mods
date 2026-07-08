# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code:
- **3 expert agents** for pure context-isolation/worker roles (git-agent, firecrawl-expert, project-organizer) - every domain-knowledge agent became an `-ops` skill (v3.0, skills-first)
- **3 commands** for session management and git orchestration (/sync, /save, /git-ops)
- **102 skills** for CLI tools, patterns, workflows, and development tasks (incl. `parallel-ops` for routing across the parallel/recurring-agent-work skill family, `fleetflow` for heterogeneous GLM/Codex/Anthropic worker fleets, `repo-doctor` for agentic-quality repo audits, `svg-brand-tint-ops` for zero-dep in-browser SVG brand-recolour + Potrace-stage raster vectorising, `r-ops` for tidyverse-first modern R / data analysis, `loop-ops` for outer-loop design discipline, `ffmpeg-ops` for probe-first media processing and EDL-driven editing, `supply-chain-defense` for behavioural-first dependency security, `prompt-injection-defense` for instruction-integrity scanning, `pypi-ops` for OIDC Trusted Publishing to PyPI, `net-ops` for network troubleshooting, `windows-ops` / `mac-ops` for workstation diagnostics, `fleet-worker` for cheap parallel worker delegation)
- **13 output styles** for response personality (Vesper, Spartan, Mentor, Executive, Pair, Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage, Scout)
- **13 hooks** for pre-commit linting, post-edit formatting, dangerous command warnings, uv enforcement, dependency-install + manifest-edit supply-chain advisories, hidden-Unicode scanning (session-start + pre-commit), live config-change + worktree guards, mid-session peer-writer guard + touched-files ledger, and pmail notifications - security set auto-wired via plugin hooks.json
- **Pigeon** inter-session messaging (`pigeon send/read/reply`) - SQLite-backed pmail at `~/.claude/pmail.db`

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
| `output-styles/` | Response personalities (13 styles incl. vesper, atlas, noir, roast, scout) |
| `hooks/` | Working hook scripts (lint, format, safety, pmail) |
| `rules/` | Claude Code rules (14 files: agentic-quality, cli-tools, commit-style, dev-servers, loop-engineering, modern-tools, naming-conventions, prompt-injection, public-posts, release-review, shell-preference, skill-agent-updates, supply-chain, worktree-boundaries) |
| `tools/` | Modern CLI toolkit documentation |
| `tests/` | Validation scripts + justfile |
| `scripts/` | Install scripts |
| `docs/` | ARCHITECTURE.md, SKILL-CREATION-PROTOCOL.md (start here to build a skill), SKILL-SUBAGENT-REFERENCE.md, SKILL-RESOURCE-PROTOCOL.md, WORKFLOWS.md, PLAN.md, RESERVED-COMMANDS.md, TERMINAL-DESIGN.md; `archive/` (completed-migration records), `references/` (vendored guides) |

## Session Init

On "INIT:" message at session start:
1. Read the specified file (.claude/.context-init.md)
2. Proceed with user request - no summary needed

## Key Resources

| Resource | Description |
|----------|-------------|
| `rules/cli-tools.md` | Modern CLI tool preferences (rg, fd, eza, bat) |
| `rules/prompt-injection.md` | Instruction-integrity defense - scan-on-entry, sanitize-on-ingest |
| `skills/cli-ops/` | Production CLI patterns - agentic workflows, OS keyring auth, stream separation |
| `docs/WORKFLOWS.md` | 10 workflow patterns from Anthropic best practices |
| `skills/tool-discovery/` | Find the right library for any task |
| `hooks/README.md` | Pre/post execution hook examples |
| `skills/pigeon/` | Inter-session pmail - send, read, reply, broadcast, search across projects |
| `skills/auto-skill/` | Auto-detect skill-worthy workflows; Stop hook suggests after complex sessions. `/auto-skill on/off/status` to toggle |
| `skills/supply-chain-defense/` | Behavioural-first dependency security - Socket.dev depscore MCP, exposure-check (IOC match across npm/pnpm/yarn/bun/PyPI/Composer/Cargo/Go/RubyGems + extensions), integrity-audit (persistence), scan-extensions, install/manifest hooks. Paired with `rules/supply-chain.md` |
| `skills/repo-doctor/` | Agentic-quality auditor - scores any repo (entry docs, comments, structure, gates, doc-pairing) with --json + --strict CI gate; monorepo-structure + comment-doctrine references. Paired with `rules/agentic-quality.md` |

## Quick Reference

**CLI Tools:** Use `rg` over grep, `fd` over find, `eza` over ls, `bat` over cat, `markitdown` for documents

**Web Fetching:** WebFetch → Jina (`r.jina.ai/`) → `firecrawl` → firecrawl-expert agent

**Extended Thinking:** "think" < "think hard" < "think harder" < "ultrathink"

**Tasks API:** Use `TaskCreate`, `TaskList`, `TaskUpdate`, `TaskGet` for task management. Tasks are session-scoped (don't persist). Use `/save` to capture and `/sync` to restore.

**Session Cache:** v3.1 schema stores full task objects, session ID (for `--resume`), PR linkage (for `--from-pr`), and writes a summary to native MEMORY.md. Backwards compatible with v3.0.

**Pigeon (pmail):** `pigeon send <project> "subject" "body"` | `pigeon read` | `pigeon reply <id> "body"` | `pigeon status` | `pigeon broadcast "subject" "body"`. Attach files with `--attach <path>`. Disable per-project: `touch .claude/pigeon.disable`. DB at `~/.claude/pmail.db`, scripts at `~/.claude/pigeon/`.

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
just check        # THE gate: validate + doc-drift + resource contracts + skill suites
just check-fast   # same minus the per-skill behavioural suites
```
