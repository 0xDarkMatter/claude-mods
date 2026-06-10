# Changelog

All notable changes to claude-mods are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Fuller narrative entries for
feature releases live in the README "Recent Updates" section.

## [Unreleased]

## [3.0.0] - 2026-06-10

### Added (skill resource protocol)
- **`docs/SKILL-RESOURCE-PROTOCOL.md`** - the build standard for skill `scripts/`,
  `assets/`, and `references/`: stream separation, semantic exit codes, `--help`
  with EXAMPLES, first-comment-block contract, `--json` envelopes, agent safety,
  the resource-scaffold checklist, and the **staleness-verifier pattern** (an
  `--offline` structural check that gates PR CI plus a `--live` drift check that
  runs scheduled, never blocking a PR on a network blip)
- Four verifier/scanner scripts built to the protocol:
  `claude-api-ops/check-model-table.py` (model+pricing table drift),
  `terraform-ops/check-action-refs.sh` (GitHub Action `uses:` refs resolve —
  catches the exact `trivy-action` tag bug from v3.0),
  `claude-code-ops/validate-hooks-json.py` (lint a hooks.json against the
  30-event catalog), `playwright-ops/triage-flakes.py` (rank flaky tests from a
  JSON report). Plus assets: `agentic-loop.py`, `output-schema.json`,
  `hooks.json.template`
- CI: `tests/check-resources.sh` runs the offline verifiers in PR CI;
  `.github/workflows/freshness.yml` runs the live drift checks weekly (advisory)

### Removed
- **17 expert agents** deprecated as part of the skills-first restructure
  (23 → 6 agents):
  - 11 language/framework experts → their `-ops` skill twins (python,
    typescript, javascript, go, rust, react, vue, astro, laravel, sql, postgres)
  - cypress-expert → new `cypress-ops` skill; cloudflare-expert +
    wrangler-expert → new `cloudflare-ops` skill; bash-expert → new `bash-ops`
    skill
  - claude-architect → folded into `claude-code-ops`; aws-fargate-ecs-expert →
    folded into `container-orchestration`
  Per Anthropic's guidance, knowledge belongs in skills (progressive disclosure,
  single source of truth); subagents are reserved for context isolation. Only
  genuine workers (git-agent) and too-niche-for-always-on-budget domains
  (firecrawl, project-organizer, craftcms, payloadcms, asus-router) kept agent
  form. Dispatching skills route `general-purpose` agents with skill preloading.
- `claude-code-debug`, `claude-code-headless`, `claude-code-hooks` skills -
  merged into `claude-code-ops` (content was written against Claude Code
  ~2.0; the stale `$TOOL_INPUT` hook contract is gone, stdin JSON is current)

### Added
- **`claude-api-ops` skill** - building ON Claude: Messages API, tool use,
  prompt caching, structured outputs (`output_config.format`), batches,
  extended thinking, model selection, Agent SDK (Python + TypeScript)
- **`playwright-ops` skill** - e2e testing: selector hierarchy, fixtures/POM,
  network mocking, auth storageState, CI sharding, flake hunting, config template
- **`terraform-ops` skill** - Terraform/OpenTofu IaC: state management,
  module patterns, OIDC CI/CD workflow template, drift detection, write-only
  secrets, native `terraform test`
- **`claude-code-ops` skill** - merges + refreshes claude-code-debug,
  claude-code-headless, claude-code-hooks against current docs: 30-event hook
  catalog with JSON contracts, current skill frontmatter spec, headless/CLI
  reference, extension debugging decision trees (+ extension-architecture from
  claude-architect)
- **`cypress-ops`, `cloudflare-ops`, `bash-ops` skills** - converted from the
  cypress/cloudflare/wrangler/bash agents and refreshed against current docs
  (Cypress `data-test`/Test Replay/cy.session; wrangler `deploy` not `publish`,
  jsonc config, Workers static assets; defensive bash to the resource protocol)
- **Live security guard hooks**: `config-change-guard.sh` (ConfigChange event -
  scans edited Claude settings files for worm-persistence IOCs the moment
  they're written, reusing integrity-audit patterns) and `worktree-guard.sh`
  (PreToolUse - mechanically enforces `rules/worktree-boundaries.md`)
- **Plugin hook auto-wiring** (`hooks/hooks.json`) - plugin installs get the
  security-advisory hook set (pre-install-scan, manifest-dep-scan,
  session-start unicode scan, config-change guard, worktree guard) with zero
  hand-wiring; formatting/lint hooks stay opt-in examples
- **`fleet track`** command - register natively-spawned branches as fleet lanes
- New frontmatter on high-traffic skills: `when_to_use` (10 skills),
  `argument-hint` (iterate/review/testgen/explain), `effort: high`
  (iterate/review)
- README "Skill Description Budget" guidance - /doctor overflow check,
  `skillOverrides`, 1,536-char per-skill cap
- CI: doc-drift gate (`tests/doc-drift.sh`) - docs must match disk
- CI: skill behavioural test suites (`tests/run-skill-tests.sh`)

### Fixed
- `fleet.sh` `ensure_fleet_dir` returned 1 under `set -e` on every invocation
  after the first, silently killing post-init commands
- fleet-ops e2e suite asserted a worktree path `fleet.sh` no longer uses
  (now 29/29 against real behaviour)

### Changed
- **fleet-ops v2** - repositioned as landing discipline (queue, test gate,
  pre-land scrub, one-shot revert) on top of native agent teams / background
  agents, which now own the spawning half; no longer EXPERIMENTAL except the
  daemon
- **/save + /sync repositioned** - native auto-memory covers single-machine
  context; these commands' value is portable state: task restore,
  git-trackable, team-shareable, cross-machine
- supply-chain-defense description trimmed under the 1,536-char listing cap
- README/AGENTS.md/PLAN.md reconciled with actual inventory; ghost references
  removed (`rules/thinking.md`, `docs/DASH.md`)
- `tests/skills/functional/git-workflow.*` renamed to `git-cli-tools.*`

## [2.10.1] - 2026-05-29

### Fixed
- Plugin + marketplace manifests made valid against the official schema;
  `claude plugin validate` added as a CI gate (#4)

## [2.10.0] - 2026-05-25

### Added
- `prompt-injection-defense` skill - instruction-integrity defense: hidden-Unicode
  scanner (bidi/Trojan Source, tag-block smuggling, zero-width), byte-faithful
  sanitizer, SessionStart + git pre-commit hooks, `rules/prompt-injection.md`

## [2.9.0] - 2026-05-25

### Added
- `supply-chain-defense` skill - behavioural-first dependency security:
  Socket.dev integration (free CLI + zero-auth depscore MCP), exposure-check
  across 6 ecosystems + editor extensions, integrity-audit for worm persistence,
  7-day release cooldown, install + manifest advisory hooks,
  `rules/supply-chain.md`, 42-assertion offline test suite

## [2.8.0] - 2026-05-18

### Added
- `mac-ops` skill finalized - macOS workstation diagnostics, peer to
  `windows-ops`: 23 scripts + 11 references (TCC privacy, wake reasons,
  Spotlight, APFS storage pressure)

## [2.7.0] - [2.7.8] - 2026-05-17 to 2026-05-18

### Added
- `mac-ops` incremental build-up: kext/firewall/keychain/bluetooth/font audits,
  brew-health, sysdiagnose-helper, quickrun consolidator, worked examples

## [2.6.0] - 2026-05-15

### Added
- `windows-ops` skill - Windows workstation diagnostics: health-audit panel,
  crash-triage (Event 41 BugCheck decoding), recover-clone for dying drives

## [2.5.0] - 2026-05-14

### Added
- `net-ops` skill - cross-platform network troubleshooting ladder (link → app),
  IPv6 classifier, MTU/PMTU, DoH detection, `--watch`/`--json`/`--redact`
- `portless-ops` skill - local-dev HTTPS proxy operations for Vercel Labs portless
- `process-compose-ops` skill - Process Compose supervisor operations

### Fixed
- `summon` + `fleet-ops` registered in plugin manifest (were committed but unindexed)

### Removed
- `/canvas` command + `canvas-tui` package - experimental, Warp-specific, unused;
  removes the only npm runtime-dep surface

## [2.4.12] - 2026-05-05

### Fixed
- `install.sh` made cross-platform (Linux/macOS/Windows Git Bash)

## [2.4.11] - 2026-05-02

### Added
- `summon` skill - transfer Claude Desktop Code-tab sessions between accounts

## [2.4.10] - 2026-04-29

### Changed
- `github-ops` Recent Updates rule sharpened: features-not-bugs criteria

## [2.4.9] - 2026-04-26

### Added
- `git-ops` hygiene checks - status.sh flags feature-branch checkouts, stale merges
- `docs/references/claude-desktop-internals.md` - Desktop session architecture map

## [2.4.7] - 2026-04-26

### Fixed
- `push-gate` first-push to new remote (gitleaks scan branches on remote-ref existence)

## [2.4.6] - 2026-04-26

### Added
- `github-ops` skill - GitHub remote operations: repo creation, releases,
  metadata, README Recent Updates convention; three modes (new/update/audit)

## [2.4.5] - 2026-04-26

### Added
- `leveldb-ops` skill - read Chromium/Electron LevelDB stores via ccl_chromium_reader

## [2.4.4] - 2026-04-25

### Changed
- `/iterate` enhancements - Batch+bisect, Until/Stagnation stop conditions,
  branch isolation, `iterate/best` tag, always-summarize-on-exit

## [2.4.3] - 2026-04-24

### Added
- Worktree-aware `git-ops` (status.sh + worktree-survey.sh)
- `push-gate` skill - pre-push secret/forbidden-file gate, no bypass
- `rules/worktree-boundaries.md`

### Fixed
- `auto-skill` suggestions persisted to pending.log, surfaced at `/sync`

## [2.4.2] - 2026-04

### Changed
- Registered push-gate, auto-skill visibility fix

## [2.4.1] - 2026-04

### Added
- 8 daemon output styles (Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage,
  Scout) - 13 total

## [2.4.0] - 2026-04

### Added
- `auto-skill` skill - self-learning skill creation via PostToolUse/Stop hooks
- `pigeon` skill (renamed from agentmail) - inter-session pmail, SQLite-backed

## [2.3.1] - 2026-04

### Added
- `genart-ops` skill (1,843 lines)

### Changed
- All skills migrated to the Agent Skills specification (agentskills.io)

## [2.3.0] - 2026-03

### Added
- Orchestrator-dispatch pattern: `git-ops` + `git-agent` (replaces
  `git-workflow`), `perf-ops`, `security-ops` parallel audits
- Skill preloading for dispatched agents; `model: sonnet` for expert dispatch

## [2.2.x] - 2026-03

### Changed
- `/introspect` Session Insights; `/setperms` 74 default permissions

### Removed
- `claude-code-templates` (redundant with first-party skill-creator)

## [2.1.0] - 2026-03

### Added
- `/iterate` skill - autonomous improvement loop (Karpathy autoresearch pattern)

## [2.0.0] - 2026-03

### Added
- 22 new `-ops` skills (React, Vue, Go, Rust, TypeScript, Docker, CI/CD,
  PostgreSQL, Nginx, Auth, Monitoring, Debug, MCP, Tailwind, and more)
- cc-session CLI, 3 hooks, 5 output styles

### Changed
- All 14 `-patterns` skills renamed to `-ops`

## [1.x] - 2025-11 to 2026-02

### Added
- Initial toolkit: session continuity (`/save` + `/sync`, schema v3.1), expert
  agents, Python skill family, tech-debt scanner, modern CLI toolkit, validation
  suite

[Unreleased]: https://github.com/0xDarkMatter/claude-mods/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.10.1...v3.0.0
[2.10.1]: https://github.com/0xDarkMatter/claude-mods/compare/v2.10.0...v2.10.1
[2.10.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.7.8...v2.8.0
[2.6.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.4.12...v2.5.0
