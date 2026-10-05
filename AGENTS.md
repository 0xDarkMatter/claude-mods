# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code:
- **3 expert agents** for pure context-isolation/worker roles (git-agent, firecrawl-expert, project-organizer) - every domain-knowledge agent became an `-ops` skill (v3.0, skills-first)
- **3 commands** for session management and git orchestration (/sync, /save, /git-ops)
- **108 skills** for CLI tools, patterns, workflows, and development tasks (incl. `figma-ops` as the router for the Figma MCP skill family plus the capture→curate→compose workflows (moodboards, reference boards, loose-plus arrangements) none of the official or community Figma skills cover — read it first when a Figma request is ambiguous; `a11y-ops` for WCAG 2.2 conformance and the EAA/ADA deadlines that now make it a legal requirement; `evals-ops` for the eval-harness discipline every other agent-engineering change depends on; `nextjs-ops` for App Router caching, the server/client boundary and Server Actions; `icon-ops` for sourcing/normalising icons and brand marks without flattening a trademark; `rembg-ops` for transparent-PNG cutouts of flat illustration/sticker/avatar art with a deterministic fallback ladder past rembg's ML failure modes; `parallel-ops` as the router for the parallel/recurring-agent-work family — fleet-ops, fleet-worker, fleetflow (extracted to [its own repo](https://github.com/0xDarkMatter/fleetflow), mounted as a skill via junction), loop-ops, iterate, spawn — read it first when that family is ambiguous; `repo-doctor` for agentic-quality repo audits; `svg-brand-tint-ops` for zero-dep in-browser SVG brand-recolour + Potrace-stage raster vectorising; `r-ops` for tidyverse-first modern R / data analysis; `loop-ops` for outer-loop design discipline; `ffmpeg-ops` for probe-first media processing and EDL-driven editing; `supply-chain-defense` for behavioural-first dependency security; `prompt-injection-defense` for instruction-integrity scanning; `pypi-ops` for OIDC Trusted Publishing to PyPI; `net-ops` for network troubleshooting; `windows-ops` / `mac-ops` for workstation diagnostics; `fleet-worker` for cheap parallel worker delegation)
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
| `rules/` | Claude Code rules (15 files: agentic-quality, cli-tools, commit-style, deploy-gating, dev-servers, loop-engineering, modern-tools, naming-conventions, prompt-injection, public-posts, release-review, shell-preference, skill-agent-updates, supply-chain, worktree-boundaries) |
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
| `skills/parallel-ops/` | Router for the parallel/recurring-agent-work family (fleet-ops, fleet-worker, fleetflow — own repo — loop-ops, iterate, spawn) - read first when it's unclear which one owns a fan-out/schedule/delegation ask |
| [`fleetflow`](https://github.com/0xDarkMatter/fleetflow) (own repo) | Heterogeneous GLM/Codex/Grok/Pi/Anthropic worker fleets from one session; extracted 2026-08-01, mounted as `/fleetflow` via junction at `~/.claude/skills/fleetflow` |
| `tests/validate.sh` | Frontmatter + naming gate; enforces the description-budget cap (combined description+when_to_use, hard-fails over budget) |
| `tests/doc-drift.sh` | Counts-on-disk vs docs gate; also checks section-map markers and skill-frontmatter ghost references (related-skills/depends-on naming a skill not on disk) |
| `tests/agnostic.sh` | Public-repo gate: fails on user-profile paths with real names, plus anything in the author's PRIVATE deny list; legit look-alikes go in `tests/agnostic-allow.txt` |
| `tests/hooks.sh` | Hook contract tests: feeds the opt-in hooks the stdin JSON Claude Code sends, asserts exit 2 + stderr to block and no false positives; `HOOKS_DIR=<dir>` runs it against another copy (e.g. to prove it fails on a regression) |

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

## Landmines

- **A skill's own test suite can assert on its own frontmatter shape** (e.g.
  `r-ops/tests/run.sh` requires `when_to_use:` to exist). A trim/edit pass
  touching only the SKILL.md body can still break CI if it drops a field a
  sibling suite polices — read the skill's `tests/run.sh` before removing any
  frontmatter field, not just the SKILL.md itself.
- **The landing gate must run the FULL per-skill suite sweep** (`skills/*/tests/run.sh`,
  all of them), never just the touched lanes' — suites assert on shared/sibling
  files, so a change in one skill can silently break another's gate.
- **Line endings**: `.gitattributes` pins `*.sh` (and, via `* text=auto eol=lf`,
  every file git detects as text) to LF — bash dies on CRLF (`$'\r': command not
  found`, shebang exit 127). A checkout that predates the pin still carries CRLF
  until its files are re-smudged (delete + `git checkout -- .`), and
  `scripts/install.ps1` strips CRs from installed shell scripts as a backstop.
  Extension-less shebang scripts ride on git's text-detection heuristic — if one
  ever reads as binary (e.g. embedded NUL), pin it in `.gitattributes` explicitly.
- **`~/.claude` is shared, and installs are last-writer-wins**: `scripts/install.ps1`
  copies from whatever tree it is run in, so installing from a checkout that predates
  another lane's landed work silently reverts it (six skills, unnoticed, 2026-08-31).
  A staleness guard now refuses that install (`-Force` overrides) and
  `install.ps1 -Doctor` reports drift read-only. **Any comparison between the repo and
  `~/.claude` must ignore line endings** — SKILL.md files are often committed CRLF while
  the installed copies land LF, so a naive byte compare flags most of the skill tree as
  drifted and the check gets disabled. `tests/install-guard.sh` gates both.
- **The Windows CI runner's `%TEMP%` is an 8.3 short path** (`C:\Users\RUNNER~1`),
  and PowerShell hands paths back long-form. Path arithmetic against a
  caller-spelled root passes on a volume with 8.3 names disabled and fails only
  in CI. `install.ps1` cuts relative paths solely via `Get-FilesUnder`. To
  reproduce locally, point `TMPDIR` at the short name of a long-named directory
  on a volume that has 8.3 names.
- **Executable bit on commit**: scripts under `skills/*/scripts/` and `hooks/*.sh`
  must be tracked `100755`. Git on Windows won't set this for you — `tests/check-exec-bits.sh`
  gates it; a script that "works locally" but fails `bash foo.sh` for another
  contributor is almost always a missing exec bit, not a logic bug.
- **Coupled golden fixtures**: some skill tests compare output against a fixture
  file colocated in the same `tests/` dir — editing the skill's output format
  without regenerating the fixture is a silent, not loud, break (diff the fixture,
  don't just eyeball the code change).
- Never touch `.claude/worktrees/` or any repo's git worktree state (see
  `rules/worktree-boundaries.md`) — it looks orphaned and isn't.
- **This repo is public — keep it agnostic.** `tests/agnostic.sh` (in `just check` and
  CI) catches user-profile paths with real names; author-specific identifiers are
  caught by a PRIVATE deny list (`~/.claude/agnostic-deny.txt` or the gitignored
  `tests/agnostic-deny.local`). Never write personal names into the committed gate —
  that publishes what it protects. Machine-specific values belong in the user's
  private `CLAUDE.md`, not in a rule.
- **Git Bash rewrites arguments that start with `/`** into Windows paths
  (`rg --path-separator /` → the Git install dir; `sd '/Users/...'` silently matches
  nothing). Set `MSYS_NO_PATHCONV=1` for such calls, and never let a gate swallow a
  tool's exit-2 error — that combination once made the agnostic gate pass while
  scanning nothing.
- **`pwsh` on PATH does not mean Windows.** GitHub's Ubuntu runners ship `pwsh`, so
  a suite that runs Windows-only scripts whenever `command -v pwsh` succeeds goes
  red on Linux CI (windows-ops, supply-chain-defense). Gate runtime checks on the
  host: `[Environment]::OSVersion.Platform` = `Win32NT` (works in 5.1 and 7).
- **The plugin name `claude-mods` is reserved** by Claude Code 2.1.287+ (Claude Mods).
  `claude plugin validate` rejects it, so call the validator only through
  `tests/plugin-validate.sh`, which waives that one error until 2026-10-31 and fails on
  any other. Never widen the waiver; the fix is renaming the plugin. Scripts here run
  under `set -e`, so capture its exit 3 with `|| rc=$?`, never `; rc=$?`.

## Testing

```bash
just check        # THE gate: validate + doc-drift + agnostic + hook contracts + resource contracts + skill suites + e2e suites
just check-fast   # same minus the behavioural suites (per-skill and e2e)
```
