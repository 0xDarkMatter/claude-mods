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

**claude-mods** is a production-ready plugin that extends Claude Code with 91 specialized skills, 3 expert agents, 13 output styles, 11 hooks, and modern CLI tools designed for real-world development workflows. Whether you're debugging React hooks, optimizing PostgreSQL queries, or building production CLI applications, this toolkit equips Claude with the domain expertise and procedural knowledge to work at expert level across multiple technology stacks.

Built on the [Agent Skills specification](https://agentskills.io/specification) (an open standard backed by Anthropic, Vercel, Google, Microsoft, and 40+ agent platforms), claude-mods fills critical gaps in Claude Code's capabilities: persistent session state that survives across machines, on-demand expert knowledge for specialized domains, token-efficient modern CLI tools (10-100x faster than traditional alternatives), and proven workflow patterns for TDD, code review, and feature development. The toolkit implements Anthropic's [recommended patterns for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), ensuring your development context never vanishes when sessions end.

From Python async patterns to Rust ownership models, from AWS Fargate deployments to Craft CMS development - claude-mods provides the specialized knowledge and tools that transform Claude from a general-purpose assistant into a domain expert who understands your stack, remembers your workflow, and ships production code.

**3 agents. 91 skills. 13 styles. 11 hooks. 7 rules. One install.**

## Recent Updates

**v3.0.0** (June 2026)
- **Skills-first restructure** - *Breaking:* the expert-agent layer was cut from 23 to 3. Per Anthropic's guidance, knowledge belongs in skills (progressive disclosure, single source of truth) and subagents are reserved for context isolation — so *all* domain-knowledge agents became `-ops` skills (the 11 language/framework experts → their twins; cypress/cloudflare/bash/craftcms/payloadcms/asus-router → new skills; claude-architect/aws-fargate folded into existing skills). The 3 remaining agents are pure isolation/worker roles: `git-agent` (background commits/PRs), `firecrawl-expert` (noisy multi-page scrapes), `project-organizer` (bulk restructure). Dispatching skills now route `general-purpose` agents that preload skill references.
- **`claude-code-ops` skill** - the machinery of Claude Code itself in one skill: the complete 30-event hook catalog with per-event stdin/stdout JSON contracts and all five hook types; the current `SKILL.md` frontmatter spec (`when_to_use`, `context: fork`, skill-scoped hooks); a headless/CLI reference (`claude -p`, `stream-json`, structured output, background agents); and extension-debugging decision trees. Merges and rebuilds the old claude-code-debug/-headless/-hooks skills against the live June-2026 docs - the stale `$TOOL_INPUT` hook contract is gone (stdin JSON is current), with claude-architect's extension-architecture guidance folded in.
- **`claude-api-ops` skill** - building applications *on* Claude: the Messages API, tool-use loops, prompt caching, structured outputs (`output_config.format`), the Batches API, extended/adaptive thinking, a current model-selection + pricing table, and the Claude Agent SDK (Python + TypeScript). Carries a cost-optimization checklist and a `check-model-table.py` verifier that flags model/pricing drift against the live API.
- **`playwright-ops` skill** - end-to-end testing done right: the role-first selector hierarchy and web-first assertions (no manual waits), fixtures / Page-Object patterns, network mocking and HAR replay, `storageState` auth, sharding and parallelism, visual regression, and a flake-hunting playbook with a `triage-flakes.py` ranker. Ships a production `playwright.config.ts` template.
- **`terraform-ops` skill** - Terraform/OpenTofu infrastructure-as-code: directory-per-environment layout, remote-state management (`moved`/`import`/`removed`, drift detection, state-surgery discipline), module composition, write-only secrets, and native `terraform test`. Ships an OIDC plan-on-PR / apply-on-merge GitHub Actions workflow template and a `check-action-refs.sh` verifier (the check that would have caught the `trivy-action` tag bug).
- **`ffmpeg-ops` skill** - probe-first ffmpeg/ffprobe operations: a ~30-command cookbook with a footgun table (seek/keyframe semantics, `yuv420p`+`faststart`, quoting, VFR), EDL-driven editing (edit-as-code - schema asset + `cut-from-edl.py`, dry-run by default), `.cube`/Hald-CLUT colour grading with a ~40-recipe look catalog (film stocks incl. CineStill halation, signature movie grades, an 18-variant tone-map family) and a human-picks-the-grade chooser, VMAF/SSIM quality gates, two-pass loudnorm, hardware-encoder proof-encoding (listed ≠ working), chapter authoring, target-size compression, scrub-preview sprites, Whisper/STT prep, and a probe `--doctor` that pairs each hazard with its exact fix command. 19 references, a `verify-commands.sh` §7 staleness verifier, 107-assertion self-test on lavfi-synthesized fixtures.
- **`ytdlp-ops` skill** - the yt-dlp media-acquisition layer feeding `ffmpeg-ops`: format-selection doctrine (`-S` sort over `-f` filters, codec targeting that avoids re-transcodes), clip-at-download (`--download-sections`), audio-only STT extraction (stream-copy `-x`), incremental channel syncs (the `--break-on-existing --lazy-playlist` cron pattern), cookies/auth (`--cookies-from-browser`, the Chrome 127+ Windows caveat), SponsorBlock, livestream/premiere capture, and a failure-triage ladder (nsig/403/429/geo, TLS-fingerprint blocks → `--impersonate`, the EJS no-JS-runtime class). 6 references, a `check-ytdlp-version.sh` §7 verifier (flags an install >60 days behind the latest release, or a core flag that vanished from `--help`), 28-assertion offline self-test.
- **Live security guards, zero hand-wiring** - `config-change-guard.sh` scans Claude settings files for worm-persistence IOCs the moment they're edited; `worktree-guard.sh` mechanically enforces worktree boundaries. Plugin-level `hooks/hooks.json` auto-wires the security set on install.
- **Skill Resource Protocol** - one build standard for skill scripts and assets ([docs/SKILL-RESOURCE-PROTOCOL.md](docs/SKILL-RESOURCE-PROTOCOL.md)), headlined by the staleness-verifier pattern: offline checks gate PR CI, live drift checks run weekly without ever blocking a PR. Four verifiers ship with it.
- **fleet-ops v2** - repositioned as landing discipline (sequential queue, test-gated merge, pre-land scrub, one-shot revert, new `fleet track`) on top of native agent teams and background agents, which now own session spawning.
- **Docs that can't rot** - new `CHANGELOG.md`; a CI doc-drift gate fails the build when README counts diverge from disk or a link goes ghost; every skill's behavioural suite runs in CI; /save + /sync repositioned as portable, team-shareable state alongside native auto-memory.

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

[View full changelog →](CHANGELOG.md)

## Why claude-mods?

Claude Code is powerful out of the box, but it has gaps. This toolkit fills them:

- **Session continuity** — Tasks vanish when sessions end. We fix that with `/save` and `/sync`, implementing Anthropic's [recommended pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) for long-running agents.

- **Expert-level knowledge on demand** — 91 on-demand skills covering React, TypeScript, Python, Go, Rust, PostgreSQL, and more, plus 3 specialized agents reserved for genuine context-isolation/worker roles (git operations, web scraping, project reorganization). Skills-first: knowledge loads when relevant instead of living in heavyweight agent prompts.

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
├── agents/             # Expert subagents (3)
├── commands/           # Slash commands (2)
├── skills/             # Custom skills (91)
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
| [craftcms-ops](skills/craftcms-ops/) | Craft CMS 5 - entries/sections/fields, Matrix-as-entries, Twig, element queries, GraphQL, plugins |
| [payloadcms-ops](skills/payloadcms-ops/) | Payload CMS 3 (Next.js-native) - collections/globals, Local API, access control, hooks, fields |
| [cli-ops](skills/cli-ops/) | Production CLI tool patterns - agentic workflows, stream separation, exit codes |
| [bash-ops](skills/bash-ops/) | Defensive Bash - strict mode, traps, safe argument parsing, semantic exit codes, shellcheck, CI scripts |
| [cypress-ops](skills/cypress-ops/) | Cypress e2e + component testing - data-test selectors, cy.intercept, cy.session, Test Replay, flake diagnosis |
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
| [cloudflare-ops](skills/cloudflare-ops/) | Cloudflare Workers/Pages - wrangler (deploy, jsonc config), bindings (KV/D1/R2/DO/Queues/AI), edge deploy + CI |
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
| [asus-router-ops](skills/asus-router-ops/) | Asus / Asuswrt-Merlin routers - hardening, WireGuard/OpenVPN, segmentation, DNS privacy, JFFS scripting |

#### CLI Tool Skills
| Skill | Description |
|-------|-------------|
| [file-search](skills/file-search/) | Find files with fd, search code with rg, select with fzf |
| [find-replace](skills/find-replace/) | Modern find-and-replace with sd |
| [code-stats](skills/code-stats/) | Analyze codebase with tokei and difft |
| [data-processing](skills/data-processing/) | Process JSON with jq, YAML/TOML with yq |
| [markitdown](skills/markitdown/) | Convert PDF, Word, Excel, PowerPoint, images to markdown |
| [ffmpeg-ops](skills/ffmpeg-ops/) | ffmpeg/ffprobe operations - probe-first cookbook (transcode, cut/concat, GIF, subtitles, HLS), --doctor triage with fix commands, EDL-driven editing, STT/Whisper prep, VMAF quality gates, chapter authoring, target-size compression, scrub-preview sprites, hw-encoder verification, and a full grading wing: ~40-look recipe catalog, 32 parametric LUTs (mono/duo/tritone tone maps), Hald-CLUT extraction, scope-matching doctrine. 11 protocol scripts, 19 references, 107-assertion suite |
| [ytdlp-ops](skills/ytdlp-ops/) | yt-dlp acquisition layer feeding ffmpeg-ops - format selection that avoids transcodes (-S sort), clip-at-download sections, STT audio extraction, archive-driven channel syncs, cookies/auth, SponsorBlock, failure triage (nsig = outdated). Staleness verifier wired into CI + freshness |
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
| [adr-ops](skills/adr-ops/) | Architecture Decision Records - when-to-write, canonical format, supersession lifecycle, scaffold/index/lint tools |
| [okf-ops](skills/okf-ops/) | Open Knowledge Format - assess a doc repo's frontmatter-readiness, validate a bundle for conformance, decide per-repo adoption |
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
>
> **Why, per Anthropic's guidance:** skills and subagents solve different problems. A subagent's value is
> *context isolation* — it runs in a separate context window so a large, noisy investigation returns only its
> distilled result to the main thread. Skills are the home for *knowledge*: thanks to progressive disclosure
> they cost ~100 tokens (name + description) until they're relevant, then load their body and references on
> demand. A `python-expert` agent that only carried Python knowledge used none of the isolation benefit — it
> was a knowledge container paying a dispatch cost, and it duplicated the `python-*-ops` skills (5 of the 11
> retired agents had *no* content their skill twin lacked). Knowledge belongs in skills; subagents are reserved
> for delegation that needs its own context or model.
>
> Delegation stays where it earns its keep: dispatching skills (review, testgen, perf-ops, security-ops,
> explain) still route to `general-purpose` agents — but those agents now *preload the relevant skill* for
> their knowledge. Subagent = the isolation mechanism, skill = the knowledge it loads. The agents below remain
> because they have no skill twin (a distinct capability, or — like git-agent — a real background-worker role
> that uses the isolation boundary).
>
> The end state is clean: **every domain-knowledge agent is now a skill**, and the only agents left are the
> three whose value *is* the isolation mechanism — git-agent (a background worker), firecrawl-expert (large
> noisy scrapes), and project-organizer (bulk filesystem restructure).
>
> Sources: [Agent Skills](https://code.claude.com/docs/en/skills) — progressive disclosure and on-demand
> loading; [Subagents](https://code.claude.com/docs/en/sub-agents) — a separate context window for delegated work.

| Agent | Description |
|-------|-------------|
| [firecrawl-expert](agents/firecrawl-expert.md) | Web scraping, crawling, parallel fetching, structured extraction |
| [git-agent](agents/git-agent.md) | Background git operations - commits, PRs, releases (Sonnet) |
| [project-organizer](agents/project-organizer.md) | Reorganize directory structures, cleanup |

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

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the component model, and [docs/SKILL-CREATION-PROTOCOL.md](docs/SKILL-CREATION-PROTOCOL.md) for how to build a new skill.

## Resources

- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Official Anthropic guide
- [Claude Code Plugins](https://claude.com/blog/claude-code-plugins) — Plugin system documentation
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — The pattern behind `/save`

---

*Extend Claude Code. Your way.*
