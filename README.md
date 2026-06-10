```
 ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝
██║     ██║     ███████║██║   ██║██║  ██║█████╗      ██╔████╔██║██║   ██║██║  ██║███████╗
██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝      ██║╚██╔╝██║██║   ██║██║  ██║╚════██║
╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████║
 ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝
```

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet?logo=anthropic)](https://docs.anthropic.com/en/docs/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *A comprehensive extension toolkit that transforms Claude Code into a specialized development powerhouse.*

**claude-mods** is a production-ready plugin that extends Claude Code with 81 specialized skills, 12 expert agents, 13 output styles, 11 hooks, and modern CLI tools designed for real-world development workflows. Whether you're debugging React hooks, optimizing PostgreSQL queries, or building production CLI applications, this toolkit equips Claude with the domain expertise and procedural knowledge to work at expert level across multiple technology stacks.

Built on the [Agent Skills specification](https://agentskills.io/specification) (an open standard backed by Anthropic, Vercel, Google, Microsoft, and 40+ agent platforms), claude-mods fills critical gaps in Claude Code's capabilities: persistent session state that survives across machines, on-demand expert knowledge for specialized domains, token-efficient modern CLI tools (10-100x faster than traditional alternatives), and proven workflow patterns for TDD, code review, and feature development. The toolkit implements Anthropic's [recommended patterns for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), ensuring your development context never vanishes when sessions end.

From Python async patterns to Rust ownership models, from AWS Fargate deployments to Craft CMS development - claude-mods provides the specialized knowledge and tools that transform Claude from a general-purpose assistant into a domain expert who understands your stack, remembers your workflow, and ships production code.

**12 agents. 81 skills. 13 styles. 11 hooks. 7 rules. One install.**

## Recent Updates

**v2.10.0** (May 2026)
- 🕵️ **`prompt-injection-defense` skill** - Instruction-integrity sibling to `supply-chain-defense`: defends the agent's context surface against adversarial content where what a reviewer sees differs from what the model reads. `scan-hidden-unicode.py` detects bidi/Trojan-Source reordering, `U+E0000` tag-block ASCII smuggling, zero-width text, and (`--strict`) homoglyphs — emoji-whitelisted so it doesn't false-positive on every README; `sanitize-content.py` strips them from untrusted content before ingest (byte-faithful, idempotent). Deployed as silent guardians at the trust boundaries: a SessionStart hook scans project instruction files at boot, a git pre-commit gate blocks `critical` hidden Unicode from entering the repo, and `rules/prompt-injection.md` drives scan-on-entry / sanitize-on-ingest. Codepoint catalog + 2 references + 18-assertion offline suite.

**v2.9.0** (May 2026)
- 🛡️ **`supply-chain-defense` skill** - Behavioural-first defense against the 2026 npm/PyPI/Composer worm campaign (Shai-Hulud) that `npm audit` misses in the publish-to-advisory window — the proactive sibling to `security-ops`. Free-first Socket.dev integration (open-source CLI, zero-auth `depscore` MCP) plus advisory hooks on both install commands and manifest edits. `exposure-check.py` matches installed lockfiles (npm/pnpm/yarn/bun, PyPI, Composer, Cargo, Go, RubyGems + editor extensions) against a cited-IOC catalog; `integrity-audit.sh` hunts worm persistence in configs, shell rc, and `.npmrc`; `preinstall-check.sh` enforces a 7-day release-age cooldown. A global `rules/supply-chain.md` carries the doctrine everywhere; 42-assertion offline test suite, IOC format from Perplexity's [Bumblebee](https://github.com/perplexityai/bumblebee).

**v2.8.0** (May 2026)
- 🩺 **`mac-ops` skill** - Comprehensive macOS workstation diagnostics, peer to `windows-ops`. 23 scripts + 11 reference docs along an 8-rung ladder: `health-audit` orchestrates and `quickrun` gives a one-shot "what's wrong with my Mac?" verdict. Mac-unique probes cover TCC privacy permissions (the "can't screen-share" cause), wake reasons, Spotlight, and APFS storage pressure (the "disk full but `du` disagrees" mystery).

**v2.6.0** (May 2026)
- 🩺 **`windows-ops` skill** - Comprehensive Windows workstation diagnostics. Seven scripts + five reference catalogs: `health-audit` renders a state-grouped panel and maps `\Device\HarddiskN` → drive letter so a verdict names the actual failing drive; `crash-triage` decodes Event 41 BugCheck codes and walks the minutes before a crash for smoking guns; `recover-clone` wraps `robocopy /R:0` so retries don't hasten a dying drive's death.

**v2.5.0** (May 2026)
- 🌐 **`net-ops` skill** - Cross-platform network troubleshooting (Windows / macOS / Linux) via local or remote SSH with a layered diagnostic ladder: link → ICMP → socket → DNS infrastructure → OS resolver → app. NDP-aware IPv6 classifier (disabled / ULA-only / no-route / path-broken / healthy), MTU/PMTU test, time-skew check, browser DoH detection (Chrome / Brave / Firefox), WSL2/container awareness. Modes: `--watch`, `--json` (NDJSON), `--redact` for opsec-clean dumps, `--quick` for skip-if-healthy. Per-OS probe + dns-audit + repair scripts, reverse-mode probe, 24-test self-suite.
- 🌐 **`portless-ops` skill** - Local-dev HTTPS proxy operations for Vercel Labs' [portless](https://github.com/vercel-labs/portless). Wraps the canonical upstream `SKILL.md` and `oauth/SKILL.md` (vendored verbatim into `references/` since the npm package only ships `dist/`) and overlays operational patterns we've validated: the static-alias pattern for pairing portless with external supervisors (Process Compose, PM2, Docker), TLD selection decision tree (`.test`/`.dev`/`.localhost`/custom-owned), Windows-specific gotchas (`openssl` PATH from Git for Windows, `certutil` quirks, curl-vs-browser cert handling, PS 5.1 vs 7+ flag differences), the clean-reset procedure when changing TLDs (because `portless alias --remove` appends the active TLD), and three runnable scripts: `install-portless.ps1` (audits the npm tarball for known supply-chain IOCs *before* installing), `reset-state.ps1` (full state wipe + re-register), `sync-aliases-from-yaml.ps1` (derives portless aliases from a supervisor's YAML). Four `portless.json` asset templates cover single-app, monorepo, custom-TLD-documented, and `package.json`-inline patterns.
- 🎛️ **`process-compose-ops` skill** - Comprehensive operations for [Process Compose](https://github.com/F1bonacc1/process-compose), the Go-binary supervisor replacing PM2/supervisord/Foreman for non-containerised local services. Six reference files: `schema-reference.md` (full YAML schema with field semantics, defaults, and command-quoting gotchas including Windows-PATH backslash handling), `probe-patterns.md` (readiness probe recipes per stack — Python/Go/Node/TCP-only/daemons), `dependency-patterns.md` (`depends_on` patterns: companion daemons, DB-before-app, tunnel-after-service, one-shot init), `tui-shortcuts.md` (TUI keybindings cheatsheet, status legend, search/sort), `boot-persistence-windows.md` (Task Scheduler with `S4U` logon and PATH-aware wrapper script), `supply-chain-verification.md` (SHA-256 verification procedure for the binary). Four runnable scripts: `install-process-compose.ps1` (verified download + extract + writes `VERIFICATION.md`), `verify-binary.ps1` (re-verifies committed binary hash), plus boot wrapper and Task Scheduler installer templates. Five YAML assets: Python service, Django+companions, Go binary, Cloudflare tunnel pattern, cron job. Material derived from a 3-hour production migration from PM2+Caddy+Dagu to Process Compose+portless, anonymised for general use.
- 📦 **Plugin manifest catch-up** - `summon` (v2.4.11) and `fleet-ops` (post-v2.4.11) were committed and listed in README but never added to `.claude-plugin/plugin.json`'s `components.skills` array, so they weren't being indexed by the plugin system. Both registered correctly now alongside the new pair.
- 🗑️ **`/canvas` command and `canvas-tui` package removed** - The canvas command was experimental, Warp-terminal-specific, and unused. Deletion removes the only npm runtime-dep surface in claude-mods (2,096-line lockfile + 17 TypeScript/React source files + 117-line bundled README), leaving the repo as markdown + bash only. Minor bump rather than patch because it removes a documented public API (`/canvas`). Co-developed in branch `claude/sad-almeida-20699c` by a sibling Opus 4.7 session and integrated into this release.

**v2.4.11** (May 2026)
- ✨ **`summon` skill** - Push Claude Desktop Code-tab sessions across accounts so they appear in the next account you switch to. Best run *before* switching — while still on your current near-limit account, push mid-flight sessions to the destination, then Logout/Login as the natural switch. Default is copy (sessions visible from both accounts); `--move` for lean cleanup. Hierarchical Account → Project → Session picker with global numbering, `--peek <id>` for transcript preview, `--list-accounts` inventory, recency aliases (`--1d/--3d/--7d/--all`), 8-hint rotating tip system. Output follows `docs/TERMINAL-DESIGN.md` (Terminal Panel Design System).

**v2.4.10** (April 2026)
- 📌 **`github-ops` Recent Updates rule sharpened** - `references/readme-recent-updates.md` gains an explicit "Recent Updates is for *features*, not bugs" subsection with three inclusion criteria, four exclusion criteria, and a self-check ("are you writing this because *you* remembered the fix or because *the user* is waiting for it?"). Replaces a soft single-bullet rule that allowed pre-existing bug fixes to slip into feature-release entries silently.

**v2.4.9** (April 2026)
- 🔍 **`git-ops` hygiene checks** - `status.sh` now proactively flags bad git practices during every status read: main checkout sitting on a feature branch (feature work belongs in worktrees), and merged branches not yet deleted. `SKILL.md` documents all four anti-patterns (feature branch, stale merges, WIP commits, large uncommitted pile) with severity ratings and remediation steps.
- 📖 **`docs/references/claude-desktop-internals.md`** - Comprehensive map of Claude Desktop's file system layout and session architecture, validated by live probing. Key findings: cross-account session transfer works by copying only the metadata JSON; sidebar population is filesystem-driven on login (not server cache); `react-query-cache-ls` probe confirmed 7/8 transferred sessions were absent from server data but appeared in sidebar.

**v2.4.8** (April 2026)
- 📝 **`github-ops` README intros** - Stopped shipping single-line taglines as "descriptions". Skill now drafts a proper 2–3 paragraph intro on first publish (what it is / why it exists / who it's for), reading package metadata, CHANGELOG, and the primary entry point before writing — and surfaces the draft for approval rather than committing one-shot. New `references/readme-description.md` codifies voice (developer-to-developer, concrete, occasional dry wit), structure, anti-patterns ("blazing fast", emoji walls, marketing fluff, "this project aims to..."), and ships a worked before/after example. Mode `update` proposes expansion only if intro is < 80 words or scope has drifted (no churning good prose); mode `audit` flags thin intros. The `gh repo create --description` one-liner now derives from the README intro draft rather than blindly copying `pyproject.toml.description`.

**v2.4.7** (April 2026)
- 🛡️ **`push-gate` first-push fix** - Detected on first publish to a new remote: gitleaks scan failed because `origin/main` doesn't exist yet. Now branches on remote-ref existence — full-branch scan when new, diff-range scan when incremental.

**v2.4.6** (April 2026)
- 🐙 **`github-ops` skill** - GitHub remote operations companion to `git-ops` (local) and `push-gate` (pre-push safety). Owns `gh repo create`, repo metadata (description / homepage / topics / visibility), `gh release create`, and the README "Recent Updates" section convention. Three modes: `new` (first publish — audit, scaffold Recent Updates, create private-by-default repo, push, set topics, cut release), `update` (subsequent release — bump version per strategy, update Recent Updates + CHANGELOG, tag, push, release), `audit` (read-only checklist scoring LICENSE / README / package metadata / GitHub state). Bundles four reference docs codifying release strategy (default minor, never auto-major), Recent Updates style (claude-mods per-version blocks vs flarecrawl table), private-by-default visibility, and the full audit checklist with topic-derivation rules. Trims `git-ops` Release Workflow to stop at the local tag; remote half delegates here.

**v2.4.5** (April 2026)
- 🗄️ **`leveldb-ops` skill** - Read and decode Chromium/Electron LevelDB stores (Local Storage, IndexedDB, Session Storage). Pure-Python via `ccl_chromium_reader` (GitHub-only, not on PyPI) — `plyvel` skipped because Windows wheels don't exist and MSVC compile fails. Ships three reusable scripts (`dump_localstorage.py`, `dump_indexeddb.py`, `extract_keys.py`) and two reference docs: `chromium-format.md` (on-disk layout, append-only semantics, locking quirks per OS) and `claude-desktop-state.md` (full state map for Claude Desktop v1.3109.0 — origin keys, account-binding distinctions, sidebar mutation recipes, MCP iframe partitioning). Codifies the safety pattern (copy-then-delete-LOCK) and the append-only gotcha (last-write-wins per `script_key`). Triggers on Electron app forensics, IndexedDB decoding, "where does the desktop app cache X" questions.

**v2.4.4** (April 2026)
- 🔁 **`/iterate` enhancements** - Configurable throughput vs. atomicity tradeoff. New `Batch: N` argument applies N independent changes per iteration; on regression the loop bisects (cherry-pick replay) to identify the culprit, keeping good commits and dropping bad ones — preserves the "git as memory" guarantee while lifting the throughput ceiling. New stop conditions: `Until: <value>` (target metric) and `Stagnation: N` (consecutive no-improvement cap), OR'd with existing `Iterations` cap. New `Branch: auto|<name>|current` for branch isolation — `auto` derives `iterate/<slug-from-goal>` from the Goal text. New `iterate/best` git tag floats forward to the highest-metric commit, surviving any later regression. Always-summarize-on-exit rule — overnight runs interrupted in the morning now produce a final block before yielding control. Skill grew 243 → 356 lines.

**v2.4.3** (April 2026)
- 🌳 **Worktree-aware `git-ops`** - T1 inline `scripts/status.sh` (rich repo overview) and `scripts/worktree-survey.sh` (per-worktree triage). New "Worktree Operations" tier mapping; survey-first discipline before any prune.
- 🛡️ **`push-gate` skill** - Pre-push safety gate. Gitleaks + regex secret scan, forbidden-file check, divergence check, dirty-tree refusal, explicit confirm. Refuses on any hit — no bypass.
- 📌 **`rules/worktree-boundaries.md`** - Never `rm -rf .claude/worktrees/`, never `git add -A` when worktree gitlinks are untracked, never decide another session's worktree is orphaned.
- 📬 **`auto-skill` visibility fix** - Stop hook's `systemMessage` only reaches Claude — ~80 suggestions vanished silently in a week. Now also appended to `~/.claude/auto-skill/pending.log`, surfaced at next `/sync`.

**v2.4.1** (April 2026)
- 🎭 **13 output styles** - Added 8 daemon personalities from private-project: Atlas (strategic advisor), Coach (momentum builder), Harbour (calm stability), Meridian (chief of staff), Noir (hard-boiled detective), Roast (honest friend), Sage (measured precision), Scout (lateral thinker). Standardised all frontmatter to Title Case names and unquoted descriptions.

**v2.4.0** (April 2026)
- 🧠 **`auto-skill` skill** - Self-learning skill creation inspired by [Hermes Agent](https://github.com/nousresearch/hermes-agent) and private-project's auto-skill system. PostToolUse hook silently tracks tool calls; Stop hook evaluates session complexity via 5 gates (8+ mutating ops, 4+ distinct tool types, no existing skill loaded, per-session cooldown, toggle check). Suggests skill creation via `systemMessage` while context is fresh. Agent Skills spec compliant with quality gates and duplicate detection. Toggle with `/auto-skill on/off/status`.
- 📬 **`pigeon` skill** (renamed from `agentmail`) - Inter-session pmail between Claude Code sessions across projects. SQLite-backed at `~/.claude/pmail.db` with git-rooted project identity (survives renames/moves/clones), threading, file attachments, broadcast, search, and signal-file-driven hook notifications. Integrated into `/sync` for session-start mail check. Per-project disable via `.claude/pigeon.disable`. Renamed to avoid collision with [AgentMail](https://www.agentmail.to) (YC S25, $6M seed).

**v2.3.1** (April 2026)
- 🎨 **`genart-ops` skill** - Comprehensive generative art skill (1,843 lines) covering three.js scene scaffolding, p5.js sketch structure, SVG generation, GLSL shaders (noise, SDF, ray marching, IQ palettes), procedural algorithms (flow fields, Poisson disk, L-systems, WFC, Voronoi), and OKLAB/OKLCH colour theory
- 📐 **Agent Skills spec compliance** - All 67 skills migrated to the [Agent Skills specification](https://agentskills.io/specification). Non-standard frontmatter fields moved into `metadata:` block, `license: MIT` and `metadata.author: claude-mods` on every skill. Verified 67/67 pass.
- 📚 **Docs updated** - `SKILL-SUBAGENT-REFERENCE.md` rewritten with spec as standard, `naming-conventions.md` updated with spec-compliant frontmatter examples, `AGENT-SKILLS-COMPLIANCE-BRIEF.md` added to docs/

**v2.3.0** (March 2026)
- 🎯 **Orchestrator-dispatch pattern** - Three skills upgraded from static reference dumps to active orchestrators that classify intent, dispatch to agents, and manage safety tiers:
  - **`git-ops`** + **`git-agent`** - First skill+agent pair. Orchestrator routes T1 reads inline, dispatches T2 writes and T3 destructive ops to a dedicated Sonnet background agent with preflight confirmation. Replaces `git-workflow`.
  - **`perf-ops`** - Routes profiling to language experts (python-expert for py-spy, go-expert for pprof, etc.). Parallel CPU+memory profiling, before/after benchmarking protocol.
  - **`security-ops`** - 3 parallel audit agents (dependency scan, SAST patterns, auth/config review) consolidate into OWASP-mapped severity report. Modelled on techdebt's parallel scanner architecture.
- 📚 **Skill preloading** - Dispatching skills now instruct agents to read relevant skill references before starting work. Review and testgen agents load security-ops + testing-ops context. Perf-ops agents load profiling references. Git-agent loads CI/CD context for releases.
- 🔧 **`model: sonnet`** specified for all expert dispatch - Cheaper, faster analysis without sacrificing quality for read-only review, test generation, and profiling tasks.

**v2.2.0** (March 2026)
- 🔍 **`/introspect` enhanced** - Now generates Session Insights after every analysis: workflow improvements, skill suggestions, and ready-to-paste permission configs to reduce interruptions. Scales recommendations to session size.
- 🔧 **`/setperms` expanded** - Default template now includes 74 tool permissions (was 51): docker, cargo, go, pytest, npx, pnpm, yarn, bun, make, archive tools, data utilities.
- 🗑️ **`claude-code-templates` removed** - Redundant with Anthropic's first-party `skill-creator`. Install scripts auto-clean existing installs.

**v2.1.0** (March 2026)
- 🔁 **`/iterate` skill** - Autonomous improvement loop inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch). Define a goal, scope, and mechanical metric - the agent loops autonomously: modify, measure, keep or discard, repeat. Works for any domain (test coverage, bundle size, performance, ML training, code quality).

**v2.0.0** (March 2026)
- 🚀 **64 skills** - 22 new `-ops` skills covering React, Vue, JavaScript, Go, Rust, TypeScript, Docker, CI/CD, API design, PostgreSQL, Astro, Laravel, Nginx, Auth, Monitoring, Debug, MCP, Tailwind, Migrate, Refactor, Scaffold, Perf, Log analysis
- 🔄 **Renamed `-patterns` to `-ops`** - All 14 pattern skills renamed to signal comprehensive operational expertise
- 🛠️ **cc-session CLI** - Zero-dependency session log analyzer (15 commands, `--json` output, cross-project search)
- 📦 **Install scripts updated** - Automatic cleanup of renamed skills, preserves project-specific extras
- 🏷️ **3 hooks, 5 output styles** - Pre-commit lint, post-edit format, dangerous command warnings; Vesper, Spartan, Mentor, Executive, Pair

**v1.7.0** (February 2026)
- 🔄 **Schema v3.1** - `/save` and `/sync` upgraded for Claude Code 2.1.x and Opus 4.6
  - Session ID tracking with `--resume` suggestions (bridges task state + conversation history)
  - PR-linked sessions via `gh pr view` with `--from-pr` suggestions
  - Native memory integration - `/save` writes to MEMORY.md (auto-loaded safety net)
  - Dynamic plan path via `plansDirectory` setting (Claude Code v2.1.9+)
  - Dropped legacy v2.0 migration code

**v1.6.0** (February 2026)
- 🚀 **Tech Debt Scanner** - Automated detection using parallel subagents (1,520 lines)
  - Always-parallel architecture for fast analysis (2-15s depending on scope)
  - 4 categories: Duplication, Security, Complexity, Dead Code
  - Session-end workflow: catch issues while context is fresh
  - Language-smart: Python, JS/TS, Go, Rust, SQL with AST-based detection
  - [Boris Cherny's recommendation](https://x.com/bcherny/status/2017742741636321619): "Build a /techdebt slash command and run it at the end of every session"

**v1.5.2** (February 2026)
- 🆕 Added `cli-ops`, `screenshot`, `skill-creator` skills (+3 skills, now 42 total)
- 📚 Enhanced skill-creator with [official Anthropic docs](https://github.com/anthropics/skills) and best practices (+554 lines)
- 🐛 Fixed `/sync` filesystem scanning issue on Windows (Git Bash compatibility)

[View full changelog →](CHANGELOG.md)

## Why claude-mods?

Claude Code is powerful out of the box, but it has gaps. This toolkit fills them:

- **Session continuity** — Tasks vanish when sessions end. We fix that with `/save` and `/sync`, implementing Anthropic's [recommended pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) for long-running agents.

- **Expert-level knowledge on demand** — 80 on-demand skills covering React, TypeScript, Python, Go, Rust, PostgreSQL, and more, plus 12 specialized agents for domains that need a dedicated worker (Cloudflare, Cypress, git operations, web scraping). Skills-first: knowledge loads when relevant instead of living in heavyweight agent prompts.

- **Modern CLI tools** — Stop using `grep`, `find`, and `cat`. Our rules automatically prefer `ripgrep`, `fd`, `eza`, and `bat` — 10-100x faster and token-efficient.

- **Smart web fetching** — A fallback hierarchy that actually works: WebFetch → Jina Reader → Firecrawl. No more "I can't access that URL."

- **Workflow patterns** — TDD cycles, code review, feature development, debugging — all documented with Anthropic's best practices.

## Key Benefits

- **Persistent task state** — Pick up exactly where you left off, even across machines
- **Domain expertise** — Agents trained on framework docs, not just general knowledge
- **Token efficiency** — Modern CLI tools produce cleaner output, saving context window
- **Team sharing** — Git-trackable state files work across your whole team
- **Production-ready** — Validated test suite, proper plugin format, comprehensive docs
- **Extended thinking** — Built-in guidance for "think hard" and "ultrathink" triggers
- **Zero lock-in** — Standard Claude Code plugin format, toggle on/off anytime

## Structure

```
claude-mods/
├── .claude-plugin/     # Plugin metadata
├── agents/             # Expert subagents (12)
├── commands/           # Slash commands (2)
├── skills/             # Custom skills (81)
├── output-styles/      # Response personalities
├── hooks/              # Hook examples & docs
├── rules/              # Claude Code rules
├── tools/              # Modern CLI toolkit installers
├── scripts/            # Plugin install scripts
├── tests/              # Test suites + justfile
├── docs/               # Project docs
└── templates/          # Extension templates
```

## Installation

### Plugin Install (Recommended)

```bash
# Step 1: Add the marketplace
/plugin marketplace add 0xDarkMatter/claude-mods

# Step 2: Install the plugin
/plugin install claude-mods@0xDarkMatter-claude-mods
```

This installs globally (available in all projects). Toggle on/off with `/plugin` menu.

### Script Install

```bash
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
bash scripts/install.sh
```

Works on Linux, macOS, and Windows (Git Bash). A PowerShell alternative is also available at `scripts/install.ps1`.

The install scripts:
- Copy commands, skills, agents, rules, output styles to `~/.claude/`
- Clean up deprecated items (e.g., old `/conclave` command)
- Remove renamed skills (e.g., `-patterns` -> `-ops`)
- Handle command→skill migrations (won't create duplicates)
- Preserve any extra skills installed separately (e.g., project-specific skills)

### CLI Tools (Optional)

Install modern CLI tools (fd, rg, bat, etc.) for better performance:

```bash
# Windows (Admin PowerShell)
.\tools\install-windows.ps1

# Linux/macOS
./tools/install-unix.sh
```

## Skill Architecture

All skills comply with the [Agent Skills specification](https://agentskills.io/specification) and follow a consistent structure:

```
skill-name/
├── SKILL.md              # Core workflow (< 500 lines)
├── scripts/              # Executable code (optional)
├── references/           # Documentation loaded as needed (optional)
└── assets/               # Output templates/files (optional)
```

**Progressive Loading:**
1. Metadata (name + description) - Always in context (~100 words)
2. SKILL.md body - Loaded when skill triggers (<5k words)
3. Bundled resources - Loaded only when Claude needs them

All skills have the complete directory structure, even if `scripts/`, `references/`, or `assets/` are currently empty. This ensures consistency and makes it easy to add bundled resources later.

See [skill-creator](skills/skill-creator/) for the complete guide.

## What's Included

### Commands

| Command | Description |
|---------|-------------|
| [sync](commands/sync.md) | Session bootstrap - restore tasks, plan, git/PR context. Suggests `--resume` and `--from-pr`. |
| [save](commands/save.md) | Persist tasks, plan, git/PR context, and session summary to native memory. |

### Skills

#### Language & Framework Skills
| Skill | Description |
|-------|-------------|
| [go-ops](skills/go-ops/) | Go concurrency, error handling, testing, interfaces, generics, project structure |
| [rust-ops](skills/rust-ops/) | Rust ownership, async/tokio, error handling, traits, serde, ecosystem |
| [typescript-ops](skills/typescript-ops/) | TypeScript type system, generics, utility types, strict mode, Zod |
| [javascript-ops](skills/javascript-ops/) | JavaScript/Node.js async patterns, modules, ES2024+, runtime internals |
| [react-ops](skills/react-ops/) | React hooks, Server Components, state management, performance, testing |
| [vue-ops](skills/vue-ops/) | Vue 3 Composition API, Pinia, Vue Router, Nuxt 3 |
| [astro-ops](skills/astro-ops/) | Astro islands, content collections, rendering strategies, deployment |
| [laravel-ops](skills/laravel-ops/) | Laravel Eloquent, architecture, authentication, testing with Pest |
| [cli-ops](skills/cli-ops/) | Production CLI tool patterns - agentic workflows, stream separation, exit codes |
| [tailwind-ops](skills/tailwind-ops/) | Tailwind CSS patterns, v4 migration, components, configuration |
| [color-ops](skills/color-ops/) | Color spaces, WCAG/APCA contrast checker, palette + harmony generators, CSS color functions, design tokens, color converter |
| [genart-ops](skills/genart-ops/) | Generative art - three.js scenes, p5.js sketches, SVG generation, GLSL shaders, procedural algorithms, colour theory |
| [unfold-admin](skills/unfold-admin/) | Django Unfold admin theme - ModelAdmin, dashboards, filters, widgets, theming |

#### Python Skills
| Skill | Description |
|-------|-------------|
| [python-async-ops](skills/python-async-ops/) | asyncio concurrency, aiohttp, error handling, sync/async mixing, production patterns |
| [python-cli-ops](skills/python-cli-ops/) | Click/Typer/argparse CLIs, stream handling, packaging |
| [python-database-ops](skills/python-database-ops/) | SQLAlchemy async, connection pooling, transactions |
| [python-fastapi-ops](skills/python-fastapi-ops/) | FastAPI dependency injection, background tasks, Pydantic |
| [python-observability-ops](skills/python-observability-ops/) | Structured logging, tracing, metrics for Python services |
| [python-pytest-ops](skills/python-pytest-ops/) | pytest fixtures, parametrization, property-based testing |
| [python-typing-ops](skills/python-typing-ops/) | Advanced generics, type narrowing, runtime validation |

#### Data & API Skills
| Skill | Description |
|-------|-------------|
| [api-design-ops](skills/api-design-ops/) | REST, gRPC, GraphQL design patterns, versioning, auth, rate limiting |
| [rest-ops](skills/rest-ops/) | HTTP methods, status codes, REST quick reference |
| [sql-ops](skills/sql-ops/) | CTEs, window functions, JOIN patterns, indexing |
| [postgres-ops](skills/postgres-ops/) | PostgreSQL operations, optimization, schema design, replication, monitoring |
| [sqlite-ops](skills/sqlite-ops/) | SQLite schemas, Python sqlite3/aiosqlite patterns |
| [claude-api-ops](skills/claude-api-ops/) | Build on Claude - Messages API, tool use, prompt caching, structured outputs, batches, Agent SDK |
| [mcp-ops](skills/mcp-ops/) | MCP server development, FastMCP, transports, tool design, testing |

#### Infrastructure Skills
| Skill | Description |
|-------|-------------|
| [docker-ops](skills/docker-ops/) | Dockerfile best practices, multi-stage builds, Compose, optimization |
| [ci-cd-ops](skills/ci-cd-ops/) | GitHub Actions, release automation, testing pipelines |
| [container-orchestration](skills/container-orchestration/) | Kubernetes, Helm, pod patterns |
| [nginx-ops](skills/nginx-ops/) | Nginx reverse proxy, SSL/TLS, load balancing, performance tuning |
| [auth-ops](skills/auth-ops/) | JWT, OAuth2, sessions, RBAC/ABAC, passkeys, MFA |
| [monitoring-ops](skills/monitoring-ops/) | Prometheus, Grafana, OpenTelemetry, structured logging, alerting |
| [debug-ops](skills/debug-ops/) | Systematic debugging, language-specific debuggers, common scenarios |
| [perf-ops](skills/perf-ops/) | Performance profiling - CPU, memory, bundle analysis, load testing, flamegraphs |
| [terraform-ops](skills/terraform-ops/) | Terraform/OpenTofu IaC - state management, module patterns, OIDC CI/CD, drift detection, secrets |
| [supply-chain-defense](skills/supply-chain-defense/) | Behavioural-first dependency security - Socket.dev (free CLI + depscore MCP), exposure-check (IOC match across npm/pnpm/yarn/bun/PyPI/Composer/Cargo/Go/RubyGems + extensions), integrity-audit (worm persistence), scan-extensions, install/manifest hooks |
| [prompt-injection-defense](skills/prompt-injection-defense/) | Instruction-integrity defense - hidden Unicode scanning (bidi/Trojan Source, tag-block smuggling, zero-width), content sanitization, trust-boundary doctrine |
| [security-ops](skills/security-ops/) | Reactive security auditing - 3 parallel agents (dependency CVEs, SAST patterns, auth/config review) consolidated into OWASP-mapped report |
| [portless-ops](skills/portless-ops/) | Local-dev HTTPS proxy operations for Vercel Labs' portless - TLD selection, supervisor pairing, Windows gotchas |
| [process-compose-ops](skills/process-compose-ops/) | Process Compose supervisor operations - YAML schema, readiness probes, dependency patterns, boot persistence |

#### Workstation & Network Diagnostics
| Skill | Description |
|-------|-------------|
| [windows-ops](skills/windows-ops/) | Windows workstation diagnostics - health audit, crash triage, drive mapping, dying-drive recovery |
| [mac-ops](skills/mac-ops/) | macOS workstation diagnostics - TCC privacy permissions, wake reasons, Spotlight, APFS storage pressure |
| [net-ops](skills/net-ops/) | Cross-platform network troubleshooting - layered ladder from link to app, IPv6 classifier, DoH detection, MTU/PMTU |

#### CLI Tool Skills
| Skill | Description |
|-------|-------------|
| [file-search](skills/file-search/) | Find files with fd, search code with rg, select with fzf |
| [find-replace](skills/find-replace/) | Modern find-and-replace with sd |
| [code-stats](skills/code-stats/) | Analyze codebase with tokei and difft |
| [data-processing](skills/data-processing/) | Process JSON with jq, YAML/TOML with yq |
| [markitdown](skills/markitdown/) | Convert PDF, Word, Excel, PowerPoint, images to markdown |
| [structural-search](skills/structural-search/) | Search code by AST structure with ast-grep |
| [log-ops](skills/log-ops/) | Log analysis, JSONL processing, cross-log correlation, timeline reconstruction |
| [leveldb-ops](skills/leveldb-ops/) | Read Chromium/Electron LevelDB stores (Local Storage, IndexedDB) - app-state forensics |

#### Workflow Skills
| Skill | Description |
|-------|-------------|
| [tool-discovery](skills/tool-discovery/) | Recommend agents and skills for any task |
| [git-ops](skills/git-ops/) | Git orchestrator - commits, PRs, releases, changelog. Routes to background Sonnet agent. |
| [github-ops](skills/github-ops/) | GitHub remote operations - repo creation, releases, metadata, README Recent Updates convention |
| [push-gate](skills/push-gate/) | Pre-push safety gate - gitleaks + regex secret scan, forbidden-file check, no bypass |
| [fleet-ops](skills/fleet-ops/) | Manage a fleet of concurrent Claude sessions - landing queue with test gate, pre-land scrub (experimental) |
| [summon](skills/summon/) | Transfer Claude Desktop Code-tab sessions between accounts - push/pull with picker |
| [doc-scanner](skills/doc-scanner/) | Scan and synthesize project documentation |
| [project-planner](skills/project-planner/) | Track stale plans, suggest session commands |
| [python-env](skills/python-env/) | Fast Python environment management with uv |
| [task-runner](skills/task-runner/) | Run project commands with just |
| [screenshot](skills/screenshot/) | Find and display recent screenshots from common screenshot directories |
| [pigeon](skills/pigeon/) | Inter-session pmail - send/receive messages between Claude Code sessions across projects. SQLite-backed (`~/.claude/pmail.db`), git-rooted project identity, threading, attachments, broadcast, search. Hook-driven notifications. Per-project disable. |

#### Development Skills
| Skill | Description |
|-------|-------------|
| [auto-skill](skills/auto-skill/) | Automatically detect skill-worthy workflows and create reusable skills. Stop hook suggests after complex sessions (8+ mutating ops across 4+ tool types). Agent Skills spec compliant with quality gates and duplicate detection. Toggle with `/auto-skill on/off`. |
| [skill-creator](skills/skill-creator/) | Guide for creating effective skills with specialized knowledge, workflows, and tool integrations. |
| [explain](skills/explain/) | Deep explanation of complex code, files, or concepts. Routes to expert agents. |
| [spawn](skills/spawn/) | Generate PhD-level expert agent prompts for Claude Code. |
| [atomise](skills/atomise/) | Atom of Thoughts reasoning - decompose problems into atomic units. |
| [setperms](skills/setperms/) | Set tool permissions and CLI preferences in .claude/ directory. |
| [introspect](skills/introspect/) | Analyze previous session logs without consuming current context. |
| [review](skills/review/) | Code review with semantic diffs, expert routing, and auto-TaskCreate. |
| [testgen](skills/testgen/) | Generate tests with expert routing and framework detection. |
| [techdebt](skills/techdebt/) | Technical debt detection using parallel subagents. |
| [migrate-ops](skills/migrate-ops/) | Framework/language migration patterns, version upgrades, codemods |
| [refactor-ops](skills/refactor-ops/) | Safe refactoring patterns, code smell detection, test-driven methodology |
| [scaffold](skills/scaffold/) | Project scaffolding - generate boilerplate for APIs, web apps, CLIs, monorepos |
| [iterate](skills/iterate/) | Autonomous improvement loop - modify, measure, keep or discard, repeat. Inspired by Karpathy's autoresearch. |
| [testing-ops](skills/testing-ops/) | Test strategy patterns - mocking, CI testing, test data design |
| [claude-code-ops](skills/claude-code-ops/) | Claude Code internals - full hook event catalog, skill frontmatter spec, headless/CLI reference, extension debugging |
| [playwright-ops](skills/playwright-ops/) | Playwright e2e testing - selector hierarchy, fixtures, network mocking, CI sharding, flake hunting |

### Hooks

| Hook | Type | Description |
|------|------|-------------|
| [pre-commit-lint.sh](hooks/pre-commit-lint.sh) | PreToolUse | Auto-lint staged files before commit (JS/TS, Python, Go, Rust, PHP) |
| [post-edit-format.sh](hooks/post-edit-format.sh) | PostToolUse | Auto-format files after Write/Edit (Prettier, Ruff, gofmt, rustfmt) |
| [dangerous-cmd-warn.sh](hooks/dangerous-cmd-warn.sh) | PreToolUse | Block destructive commands (force push, rm -rf, DROP TABLE) |
| [enforce-uv.sh](hooks/enforce-uv.sh) | PreToolUse | Enforce uv over pip/bare tools in uv projects (`pip install` → `uv add`, bare `pytest`/`ruff` → `uv run`) |
| [pre-install-scan.sh](hooks/pre-install-scan.sh) | PreToolUse | Advisory on dependency installs (npm/pnpm/yarn/bun/pip/uv/poetry/composer/gem/cargo, incl. `composer update`) - route through Socket, respect cooldown; `SUPPLY_CHAIN_BLOCK=1` for a hard gate |
| [manifest-dep-scan.sh](hooks/manifest-dep-scan.sh) | PostToolUse | Advisory when the agent edits a dependency manifest (package.json/requirements/composer.json/Cargo.toml/go.mod/Gemfile) - depscore + cooldown the added package; silent on version bumps |
| [check-mail.sh](hooks/check-mail.sh) | PreToolUse | Check for unread pmail via signal file (no cooldown, zero-cost when empty) |
| [session-start-unicode-scan.sh](hooks/session-start-unicode-scan.sh) | SessionStart | One-shot hidden-Unicode scan of project instruction files at boot (silent on clean) |
| [pre-commit-unicode-scan.sh](hooks/pre-commit-unicode-scan.sh) | Git pre-commit | Block commits that add critical hidden Unicode (bidi, tag-block) to instruction files |
| [config-change-guard.sh](hooks/config-change-guard.sh) | ConfigChange | Scan changed Claude settings files for worm-persistence IOCs the moment they're edited (advisory; `SUPPLY_CHAIN_BLOCK=1` to deny) |
| [worktree-guard.sh](hooks/worktree-guard.sh) | PreToolUse | Warn on commands that touch other sessions' `.claude/worktrees/` (rm, worktree remove/prune, sweeping `git add -A`); `WORKTREE_GUARD_BLOCK=1` to deny |

### Output Styles

| Style | Personality | Best For |
|-------|-------------|----------|
| [Vesper](output-styles/vesper.md) | Sophisticated British wit, intellectual depth | General development work |
| [Spartan](output-styles/spartan.md) | Minimal, bullet-points only | Quick tasks, CI output |
| [Mentor](output-styles/mentor.md) | Patient, educational | Learning, onboarding |
| [Executive](output-styles/executive.md) | High-level summaries | Non-technical stakeholders |
| [Pair](output-styles/pair.md) | Thinks out loud, explores together | Collaborative problem-solving |
| [Atlas](output-styles/atlas.md) | Strategic advisor, systems thinking | Architecture, planning |
| [Coach](output-styles/coach.md) | Celebrates wins, pushes to level up | Momentum, motivation |
| [Harbour](output-styles/harbour.md) | Warm, steady, calm in the storm | Complex or stressful tasks |
| [Meridian](output-styles/meridian.md) | Chief of staff, anticipatory | Project coordination |
| [Noir](output-styles/noir.md) | Hard-boiled detective, Chandler meets SRE | Debugging, investigations |
| [Roast](output-styles/roast.md) | Brutally honest friend | Code review, improvement |
| [Sage](output-styles/sage.md) | Thoughtful, measured, precise | Post-mortems, analysis |
| [Scout](output-styles/scout.md) | Curious, lateral, challenges assumptions | Design, problem reframing |

### Agents

> **Skills-first (v3.0):** language/framework expert agents (python-expert, react-expert, etc.) were
> deprecated in favour of their `-ops` skill twins — unique agent content was folded into the skills.
> Dispatching skills (review, testgen, perf-ops, security-ops, explain) now route to `general-purpose`
> agents that preload the relevant skill references. The agents below remain because no skill twin exists.

| Agent | Description |
|-------|-------------|
| [asus-router-expert](agents/asus-router-expert.md) | Asus routers, network hardening, Asuswrt-Merlin |
| [aws-fargate-ecs-expert](agents/aws-fargate-ecs-expert.md) | Amazon ECS on Fargate, container deployment |
| [bash-expert](agents/bash-expert.md) | Defensive Bash scripting, CI/CD pipelines |
| [claude-architect](agents/claude-architect.md) | Claude Code architecture, extensions, MCP, plugins, debugging |
| [cloudflare-expert](agents/cloudflare-expert.md) | Cloudflare Workers, Pages, DNS, security |
| [craftcms-expert](agents/craftcms-expert.md) | Craft CMS content modeling, Twig, plugins, GraphQL |
| [cypress-expert](agents/cypress-expert.md) | Cypress E2E and component testing, custom commands, CI/CD |
| [firecrawl-expert](agents/firecrawl-expert.md) | Web scraping, crawling, parallel fetching, structured extraction |
| [git-agent](agents/git-agent.md) | Background git operations - commits, PRs, releases (Sonnet) |
| [payloadcms-expert](agents/payloadcms-expert.md) | Payload CMS architecture and configuration |
| [project-organizer](agents/project-organizer.md) | Reorganize directory structures, cleanup |
| [wrangler-expert](agents/wrangler-expert.md) | Cloudflare Workers deployment, wrangler.toml |

### Rules

| Rule | Description |
|------|-------------|
| [cli-tools.md](rules/cli-tools.md) | Modern CLI tool preferences (fd, rg, eza, bat, etc.) |
| [commit-style.md](rules/commit-style.md) | Conventional commits format and examples |
| [naming-conventions.md](rules/naming-conventions.md) | Component naming patterns for agents, skills, commands |
| [prompt-injection.md](rules/prompt-injection.md) | Instruction-integrity defense - scan-on-entry, sanitize-on-ingest, hidden-Unicode hygiene |
| [skill-agent-updates.md](rules/skill-agent-updates.md) | Mandatory docs check before creating/updating skills or agents |
| [supply-chain.md](rules/supply-chain.md) | Behavioural-first dependency hygiene - scan before adding, day-zero cooldown, OIDC audit, persistence-hook awareness |
| [worktree-boundaries.md](rules/worktree-boundaries.md) | Never touch other sessions' worktrees - no rm -rf, no git add -A sweeping gitlinks |

### Tools & Hooks

| Resource | Description |
|----------|-------------|
| [tools/](tools/) | Modern CLI toolkit - token-efficient replacements for legacy commands |
| [hooks/](hooks/) | Hook examples for pre/post execution automation |

#### Web Fetching Hierarchy

When fetching web content, tools are used in this order:

| Priority | Tool | When to Use |
|----------|------|-------------|
| 1 | `WebFetch` | First attempt - fast, built-in |
| 2 | `r.jina.ai/URL` | JS-rendered pages, PDFs, cleaner extraction |
| 3 | `firecrawl <url>` | Anti-bot bypass, blocked sites (403, Cloudflare) |
| 4 | `firecrawl-expert` agent | Complex scraping, structured extraction |

See [tools/README.md](tools/README.md) for full documentation and install scripts.

## Testing & Validation

Validate all extensions before committing:

```bash
cd tests

# Run full validation (requires just)
just test

# Or run directly
bash validate.sh

# Windows
powershell validate.ps1
```

### What's Validated
- YAML frontmatter syntax
- Required fields (name, description)
- Naming conventions (kebab-case)
- File structure (agents/*.md, skills/*/SKILL.md)
- Plugin manifests (`.claude-plugin/plugin.json` + `marketplace.json`) via the authoritative `claude plugin validate`, plus a guard against a stray root `marketplace.json`

### Available Tasks

```bash
cd tests
just              # List all tasks
just test         # Run full validation
just validate-yaml # YAML only
just validate-names # Naming only
just stats        # Count extensions
just list-agents  # List all agents
```

## Session Continuity

The `/save` and `/sync` commands make session state **portable**.

**What's native now:** Claude Code remembers a lot on its own. `--resume` and the session picker restore conversation history, auto-memory writes a per-project `MEMORY.md` with learnings Claude decides are worth keeping, and `/rewind` checkpoints let you roll back within a session. All of it is machine-local — per the docs, auto-memory files "are not shared across machines or cloud environments" — and it remembers context *for you*, in a format Claude curates.

**What's still missing:** task state. Tasks (created via TaskCreate, managed via TaskList/TaskUpdate) are session-scoped and deleted when the session ends — by design. And none of the native state is something you can commit, review, or hand to a teammate.

**What `/save` + `/sync` add:** a state file you control — task restore, structured git/PR context, explicit human-readable handoff notes, and session-ID bridging. Because it lives in your repo, it's git-trackable, team-shareable, and follows you across machines. This implements the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

### What Persists vs What Doesn't

| Claude Code Feature | Persists? | Scope |
|---------------------|-----------|-------|
| Conversation history | Yes | This machine (`--resume` / session picker) |
| Auto-memory (MEMORY.md) | Yes | This machine, per repo — Claude-curated learnings, not task state |
| CLAUDE.md context | Yes | Wherever you commit it |
| Tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

### Session Workflow

```
Session 1:
  /sync                              # Bootstrap + restore saved state
  [work on tasks]
  /save "Stopped at auth module"     # Writes session-cache.json + MEMORY.md

Session 2:
  [MEMORY.md auto-loaded: "Goal: Auth, Branch: feature/auth, PR: #42"]
  /sync                              # Full restore: tasks, plan, git, PR
  → "Previous session: abc123... (claude --resume abc123...)"
  → "In progress: Auth module refactor"
  → "PR: #42 (claude --from-pr 42)"
```

### Why Not Just Use `--resume` or Auto-Memory?

| Feature | `--resume` | Auto-memory | `/save` + `/sync` |
|---------|------------|-------------|-------------------|
| Conversation history | Yes | No | No |
| Learnings/preferences | No | Yes (Claude-curated) | No |
| Tasks | **No** | **No** | Yes |
| Git/PR context | PR only (`--from-pr`) | Incidental | Yes (structured, `gh`-detected) |
| Session ID bridging | N/A | No | Yes (suggests `--resume <id>`) |
| Explicit handoff notes | No | No | Yes |
| Git-trackable | No | No | Yes |
| Works across machines | No | No (machine-local) | Yes (if committed) |
| Team sharing | No | No | Yes |

**Use all three together:** `claude --resume` for conversation context, auto-memory for accumulated learnings, `/sync` for task state and handoff. Since v3.1, `/save` stores your session ID so `/sync` can suggest the exact `--resume` command.

### Session Cache Schema (v3.1)

The `.claude/session-cache.json` file stores full task objects:

```json
{
  "version": "3.1",
  "session_id": "977c26c9-60fa-4afc-a628-a68f8043b1ab",
  "tasks": [
    {
      "subject": "Task title",
      "description": "Detailed description",
      "activeForm": "Working on task",
      "status": "completed|in_progress|pending",
      "blockedBy": [0, 1]
    }
  ],
  "plan": { "file": "docs/PLAN.md", "goal": "...", "current_step": "...", "progress_percent": 40 },
  "git": { "branch": "main", "last_commit": "abc123", "pr_number": 42, "pr_url": "https://..." },
  "memory": { "synced": true },
  "notes": "Session notes"
}
```

**Compatibility:** `/sync` handles both v3.0 and v3.1 files gracefully. Missing v3.1 fields are treated as absent.

## Updating

```bash
git pull
```

Then re-run the install script to update your global Claude configuration.

## Performance Tips

### MCP Tool Search

When using multiple MCP servers (Chrome DevTools, Vibe Kanban, etc.), their tool definitions consume context. Enable Tool Search to load tools on-demand:

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
| `"auto"` | Enable when MCP tools > 10% of context (default) |
| `"auto:5"` | Custom threshold (5%) |
| `"true"` | Always enabled (recommended) |
| `"false"` | Disabled |

**Requirements:** Sonnet 4+ or Opus 4+ (Haiku not supported)

### Skill Description Budget

With 80+ skills installed (this plugin alone ships 81), skill descriptions can overflow the listing budget. All skill names are always listed, but descriptions share a budget of **1% of the model context window** — on overflow, least-invoked skills lose their descriptions first and **silently stop auto-triggering** (explicit `/name` invocation still works). Each skill's combined `description` + `when_to_use` is also truncated at **1,536 chars**, so trigger phrases belong at the front.

- **Check:** run `/doctor` — it shows whether the budget is overflowing and which skills are affected.
- **Fix:** demote or disable skills you don't use via `skillOverrides` in settings (`"on"` / `"name-only"` / `"user-invocable-only"` / `"off"` per skill, or `/skills` + `Space`). Plugin skills are managed via `/plugin` instead.
- **Or raise the budget:** `skillListingBudgetFraction` setting (e.g. `0.02`), `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var for a fixed char count, or `maxSkillDescriptionChars` for the per-skill cap.

### Skills Over Commands

Most functionality lives in skills rather than commands. Skills get slash-hint discovery via trigger keywords and load on-demand, reducing context overhead. Only session management (`/sync`, `/save`) remains as commands.

See `docs/COMMAND-SKILL-PATTERN.md` for details.

## Resources

- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Official Anthropic guide
- [Claude Code Plugins](https://claude.com/blog/claude-code-plugins) — Plugin system documentation
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — The pattern behind `/save`

---

*Extend Claude Code. Your way.*
