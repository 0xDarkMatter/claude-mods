# Agent Instructions

## Project Overview

This is **claude-mods** - a collection of custom extensions for Claude Code. Human install
and usage live in [README.md](README.md); this file is for agents working on the repo.
- **3 expert agents** for pure context-isolation/worker roles (git-agent, firecrawl-expert, project-organizer) - every domain-knowledge agent became an `-ops` skill (v3.0, skills-first)
- **3 commands** for session management and git orchestration (/sync, /save, /git-ops)
- **112 skills** for CLI tools, patterns, workflows and development tasks. Two routers come
  first when a family is ambiguous: `parallel-ops` (fleet-ops, fleet-worker, fleetflow,
  loop-ops, iterate, spawn) and `figma-ops` (the Figma MCP skills). README.md lists them all
- **13 output styles** for response personality (Vesper, Spartan, Mentor, Executive, Pair, Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage, Scout)
- **13 hooks**: linting, formatting, dangerous-command warnings, uv enforcement,
  supply-chain advisories, hidden-Unicode scans, config and worktree guards, a peer-writer
  guard and touched-files ledger, pmail notifications. Plugin hooks.json wires the security set
- **Pigeon** inter-session messaging (`pigeon send/read/reply`) - SQLite-backed pmail at `~/.claude/pmail.db`

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
| `docs/` | Design docs and protocols, indexed one line each in `docs/00_INDEX.md`; to build a skill start at SKILL-CREATION-PROTOCOL.md |

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
| `skills/supply-chain-defense/` | Behavioural-first dependency security: Socket.dev depscore MCP, IOC exposure checks (npm and its kin, PyPI, Composer, Cargo, Go, RubyGems, editor extensions), persistence audit. Paired with `rules/supply-chain.md` |
| `skills/repo-doctor/` | Agentic-quality scorer (`--json`, `--strict` CI gate) and the AGENTS.md toolchain: `repo-scan.py`, `agents-md.py` scaffold / `audit --diff` / `survey --org`. Paired with `rules/agentic-quality.md` |
| `skills/parallel-ops/` | Router for the parallel/recurring-agent-work family (fleet-ops, fleet-worker, fleetflow — own repo — loop-ops, iterate, spawn) - read first when it's unclear which one owns a fan-out/schedule/delegation ask, or the cleanup after a wave (`fleet sweep`) |
| [`fleetflow`](https://github.com/0xDarkMatter/fleetflow) (own repo) | Heterogeneous GLM/Codex/Grok/Pi/Anthropic worker fleets from one session; extracted 2026-08-01, mounted as `/fleetflow` via junction at `~/.claude/skills/fleetflow` |
| `tests/validate.sh` | Frontmatter + naming gate; enforces the description-budget cap (combined description+when_to_use, hard-fails over budget) |
| `tests/spec.sh` | Agent Skills spec gate: the spec's own validator (`skills-ref`, pinned, via `uv`) on every skill, allowing Claude Code's documented fields top-level; fixture self-test first. Size is not checked here (that is `tests/skill-size.sh`). Policy: `docs/SKILL-SUBAGENT-REFERENCE.md` |
| `tests/doc-drift.sh` | Counts-on-disk vs docs gate; also checks section-map markers and skill-frontmatter ghost references (related-skills/depends-on naming a skill not on disk) |
| `tests/agnostic.sh` | Public-repo gate: fails on user-profile paths with real names, plus anything in the author's PRIVATE deny list; legit look-alikes go in `tests/agnostic-allow.txt` |
| `tests/skill-size.sh` | Warns when a SKILL.md body passes ~5,000 tokens (chars / 3.6): after compaction only the first 5,000 tokens of a skill survive, so hard rules go first. `--report`, `--strict` |
| `tests/reference-contents.sh` | Warns when a `references/*.md` over 100 lines lacks a complete `## Contents` list. Its parser is `skills/security-ops/tests/reference-contents.awk`, shared with that skill: don't move it |
| `tests/hooks.sh` | Hook contract tests: feeds the opt-in hooks the stdin JSON Claude Code sends, asserts exit 2 + stderr to block and no false positives; `HOOKS_DIR=<dir>` runs it against another copy (e.g. to prove it fails on a regression) |

## Repo Tools

- **Session state:** `/save` captures tasks, plan and git context (cache schema v3.1:
  full task objects, session ID for `--resume`, PR linkage for `--from-pr`, a summary in
  native MEMORY.md); `/sync` restores it.
- **Pigeon (pmail):** `pigeon send <project> "subject" "body"` | `pigeon read` | `pigeon reply <id> "body"` | `pigeon status` | `pigeon broadcast "subject" "body"`. Attach files with `--attach <path>`. Disable per-project: `touch .claude/pigeon.disable`. DB at `~/.claude/pmail.db`, scripts at `~/.claude/pigeon/`.

## Conventions

- Names, layout and frontmatter: `rules/naming-conventions.md`. Commits: Conventional
  Commits (`rules/commit-style.md`).
- A new skill starts at `docs/SKILL-CREATION-PROTOCOL.md`; its scripts follow
  `docs/SKILL-RESOURCE-PROTOCOL.md` (stdout is data only, semantic exit codes, `--help`
  with EXAMPLES).
- Counts in README.md, AGENTS.md and docs/PLAN.md move with the files on disk in the same
  commit (`tests/doc-drift.sh` fails otherwise).

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
- **Skill frontmatter: two parsers disagree.** Claude Code reads its own fields
  (`when_to_use`, `argument-hint`, `effort`, ...) ONLY at the top level, so moving them
  under `metadata` to "satisfy the spec" silently disables them. The spec's validator
  parses with strictyaml, which rejects flow-style YAML (`[a, b]`) that Claude Code
  accepts. `tests/spec.sh` encodes both. `claude plugin validate` checks neither,
  because it never reads SKILL.md.
- **"Keep both sides" conflict resolutions drop shared lines.** Git hoists lines both
  sides added identically (a trailing `exit 0`, a blank separator) out of the conflict
  block and keeps one copy, so a union of the two blocks loses the copy one side needed
  (a lost blank line between two new CHANGELOG entries, 2026-10-05). Check the result as
  ours + theirs - base: in a merge, `git diff HEAD -- <file>` must add and remove the
  same lines as `git diff $(git merge-base HEAD MERGE_HEAD) MERGE_HEAD -- <file>`, and
  likewise with `HEAD` and `MERGE_HEAD` swapped.
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
- **Portable skills must run copied alone.** `supply-chain-defense`,
  `prompt-injection-defense`, `ddev-ops` and `package-manager-ops` are copied standalone into other plugins: no `../../`
  dependency, `_lib/term.sh` only behind a guard, and `scripts/run-python.sh` is
  duplicated in each **on purpose** - don't DRY it into `_lib`
  (`tests/check-resources.sh` fails if the copies drift). Each suite's "standalone"
  block copies the folder alone and proves it.

## Testing

```bash
just check        # THE gate: validate + spec + doc-drift + agnostic + hook contracts + resource contracts + skill size + reference contents (both warn-only) + skill suites + e2e suites
just check-fast   # same minus the behavioural suites (per-skill and e2e)
```

CI (`.github/workflows/validate.yml`) also runs three gates `just check` does not:
`tests/plugin-validate.sh --self-test`, `tests/check-exec-bits.sh`, and
`tests/install-guard.sh` (Windows runner only). Run them by hand before landing a change
to the manifests, a script's mode, or `scripts/install.ps1`.
