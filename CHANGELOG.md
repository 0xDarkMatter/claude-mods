# Changelog

All notable changes to claude-mods are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Fuller narrative entries for
feature releases live in the README "Recent Updates" section.

## [3.2.0] - 2026-06-22

### Added
- **`fleet-worker` skill** - delegate tool-using, multi-step agent tasks to a cheaper
  headless Claude Code worker on a cheaper model — Anthropic Sonnet/Haiku, or a
  non-Anthropic endpoint (GLM via z.ai by default; any
  Anthropic-compatible endpoint via `ANTHROPIC_BASE_URL`). Each worker is a real
  `claude -p` carrying Claude Code's full tool harness but a "grunt" brain, isolated
  in its own git worktree + `CLAUDE_CONFIG_DIR` (the load-bearing auth-isolation
  finding - without it a host subscription token leaks to the endpoint and 401s). An
  Opus orchestrator fans workers out in parallel, gates raw results with
  `fleet-collect.sh` (the `is_error`-not-`subtype` footgun, encoded), and hands the
  winning branches to `fleet-ops` for test-gated landing - fleet-worker is the spawn
  layer fleet-ops disowns. Ships bash + PowerShell launchers, `fleet-doctor.sh`
  (offline structural / `--live` endpoint staleness verifier + the oauth-trap
  preflight), a sanitized design spec, the fleet-ops handoff recipes, and a
  34-assertion offline self-test. Provider-agnostic framing; carries a "know your
  terms" note (custom endpoints are documented Claude Code config; keep the
  orchestrator interactive or on an API key per Anthropic's automated-access terms).

## [3.1.0] - 2026-06-17

### Added
- **`mapbox-ops` skill** - advanced Mapbox GL JS toolkit for the web (v3, not the
  native SDKs): custom markers, thematic dataviz, 3D/terrain, cinematic camera, style
  composition, expressions, performance, and hard-won gotchas across 14 reference files.
  Ships a headless-Playwright map verifier (`screenshot_map.py` - asserts a marker
  projects to its lng/lat) and a stdlib-only `check-mapbox-facts.py` §7 staleness
  verifier: offline asserts the v3 Standard config enums, terrain tileset IDs, and
  weather/camera version gates stay internally consistent; live resolves the third-party
  style URLs and flags a GL JS major bump past v3. 37-assertion offline self-test.
- **`pypi-ops` skill** - publish Python packages to PyPI via OIDC Trusted Publishing
  with PEP 740 attestations (`gh-action-pypi-publish`), not stored API tokens. Covers
  first-publish pending-publisher setup, the invalid-publisher / already-exists failure
  ladder, TestPyPI dry runs, release-environment approval gates, local `uv publish` /
  `twine`, and a stale-OIDC-federation audit (the Mini Shai-Hulud publish-token vector).
- **`docs/SKILL-CREATION-PROTOCOL.md`** - the canonical "how to build a claude-mods
  skill" sequencing doc (warranted? → frontmatter → body → resources → tests → repo
  wiring → ship). Cites rather than restates the layer-owning docs (skill-creator,
  SKILL-SUBAGENT-REFERENCE, naming-conventions, SKILL-RESOURCE-PROTOCOL) and carries a
  precedence table for when they disagree. `skill-agent-updates.md` now routes here first.

### Changed (terminal output)
- **Terminal design system promoted from experimental to the standard** for claude-mods
  shell scripts (`docs/TERMINAL-DESIGN.md`), with the **enclosing panel as the default
  grammar**. The `github-ops` audit family (`repo-scorecard.sh`,
  `check-security-posture.sh`, `check-issues.sh`) now sources `skills/_lib/term.sh` and
  wraps its human output in the full `term_panel_open … term_panel_close` frame — brand
  header, `│` body rail, `term_section` sub-headers, colored `term_mark` rows, a score
  pip-bar, and a footer health indicator — matching the fleet-ops look. The `--json`/data
  product on stdout stays plain (stream separation preserved; verified zero ANSI on
  stdout). Every glyph falls back to ASCII under `TERM_ASCII=1` (a full scorecard renders
  pure-ASCII), and color follows the stderr TTY so piping `--json | jq` keeps framing colored.
- **`term.sh` additions**: `term_init` takes an optional fd (`term_init 2`) so
  stream-separated tools detect color on the stream the human actually sees; new
  `term_panel_line` (generic rail body-row, the open-ended counterpart to the
  branch-shaped `term_leaf_line`), `term_mark <ok|bad|warn|skip|na|unknown>` checklist
  primitive, a `TERM_ARROW` pointer glyph, and `github-ops`/`audit`/`supply-chain`/`net-ops`
  brand glyphs — all with registered ASCII proxies. github-ops test suite gained 6
  assertions (source-check + ASCII-fallback purity across panel + checklist primitives);
  40/40 offline.

### Fixed (docs)
- **`SKILL-SUBAGENT-REFERENCE.md` was self-contradictory and misleading** (surfaced by
  external PR #12): it declared "no other top-level keys are permitted" and its
  validation awk flagged `when_to_use`/`argument-hint`/`effort` as violations — yet those
  are documented *Claude Code* top-level fields the repo uses deliberately. Rewrote it to
  document **two layers** (the portable Agent Skills six-field minimum vs Claude Code's
  top-level superset), with a referenced field table, the precedence rule (Claude Code is
  our target → superset fields stay top-level), and an explicit warning that burying them
  under `metadata` *disables* them. Validation snippet now allowlists the superset and
  defers to `claude plugin validate`.

### Changed (docs review)
- Refreshed `WORKFLOWS.md` with a v3.0 orientation banner (skills-first; subagents are
  isolation/worker-only); fixed `naming-conventions.md` frontmatter example (metadata
  block, not top-level arrays); dated `RESERVED-COMMANDS.md`; noted `anthropic-skills-guide.md`
  as a vendored reference pointing at the creation protocol.
- Archived completed-migration docs to `docs/archive/`: `AGENT-SKILLS-COMPLIANCE-BRIEF.md`
  (spec migration done, CI-enforced) and `COMMAND-SKILL-PATTERN.md` (command→skill
  conversion done). docs/ top level is now 8 load-bearing docs + `archive/` + `references/`.

### Added
- **github-ops `repo-scorecard.sh`** (the audit capstone) - one read-only command
  for a scored repo-health report, fleet-aware. **Orchestrates** the existing
  auditors (`check-security-posture.sh`, `check-issues.sh`) rather than
  re-implementing them, and rolls five dimensions — security (w35), metadata
  (w25), release-consistency (w15), open-issues (w15), latest-Actions-run (w10) —
  into a 0–100 score + A–F grade with the top-3 fixes per repo. `--org` sweeps
  every non-archived repo into a matrix + roll-up (avg/median, worst repos, fleet
  open-alert total); `--min-score N` is a CI gate (exit 10 below N). An unreadable
  dimension scores zero ("n/a"), never a false-healthy. Read-only (CI-asserted);
  +15 test assertions (34 total). Now the headline of github-ops `audit` mode.
- **github-ops security-posture auditor** - `scripts/check-security-posture.sh`:
  read-only audit of a repo's GitHub security settings (Dependabot alerts +
  security updates, secret scanning + push protection, code scanning, private
  vulnerability reporting, SECURITY.md, default-branch protection). Three things
  make it more than a toggle-checker: **visibility-aware severity** (public-repo
  scanning gaps are findings; private-without-GHAS is a note, not a nag), **the
  exposure layer** (where a scanner is enabled it fetches open-alert counts + max
  severity — the real signal), and an **`--org` fleet sweep** that audits every
  non-archived repo you own in one pass. Emits the exact enable commands but never
  applies them (a CI-asserted read-only guarantee). Ships `assets/SECURITY.md.template`;
  wired into `audit` mode; +13 offline test assertions (19 total). Exit 10 on
  gaps/open-alerts, 7 when unavailable.
- **github-ops open-issue awareness** - `scripts/check-issues.sh` surfaces open
  issues you may not have seen (externally-authored + stale), read-only via
  `gh issue list`. Wired into the pre-push gate (`push-gate/preflight.sh`) as a
  post-gate **advisory** step: every push to a GitHub remote now flags unseen
  external/stale issues for that repo. Timeout-bounded, never changes the gate
  verdict, silent when gh is absent/unauthed or the remote isn't GitHub. Exit 10
  = issues to look at, 7 = unavailable (advisory). github-ops gains a 6-assertion
  offline test suite.
- **`okf-ops` skill** - assess, validate, and adopt the Open Knowledge Format
  (OKF) across markdown+frontmatter knowledge bases. `assess-okf.py` (read-only)
  scans a doc tree for OKF-readiness — frontmatter coverage, `type` presence, a
  key/value histogram, and a readiness % — so you can find good adoption
  candidates among many repos; `check-okf.py` validates a bundle for conformance
  (hard rules only, honouring OKF's permissive-consumption contract; `--strict`
  for CI gating). Honest scope baked in: OKF is a v0.1 draft, adopt per-repo not
  blanket. Both tools built to the Skill Resource Protocol; OKF format reference +
  copy-ready concept template; 10-assertion offline self-test.
- **`adr-ops` skill** - Architecture Decision Records as a cross-project workflow,
  generalized from a mature in-house ADR protocol: when-to-write / when-NOT
  decision rule, the canonical format (BLUF-first `## Decision`, fixed section
  order, frontmatter field set), the proposed→accepted→superseded/deprecated
  lifecycle, and append-only supersession discipline. Five tools to the Skill
  Resource Protocol:
  - `adr-init.sh` - bootstrap ADRs in a repo adopting them cold (dir +
    lint-clean ADR-001 + generated README)
  - `adr-new.sh` - scaffold the next sequential ADR (atomic, no-clobber,
    `--apply-supersede` flips the superseded record's frontmatter)
  - `adr-index.sh` - read-only index table from frontmatter; `--output` writes
    a generated Markdown index
  - `adr-touching.py` - query the `touches:` discovery surface ("what ADRs
    govern this path before I change it?"); exit 10 when a governing ADR exists,
    a usable pre-edit/CI guard
  - `adr-lint.py` - validates required fields, status enum, numbering, section
    order, cross-file supersession bidirectionality, lifecycle consistency
    (status vs `superseded-by`), and stale-`touches` paths
  Includes a CI-integration section (gate `adr-lint --strict` on exit 10).
  72-assertion offline self-test.

## [3.0.0] - 2026-06-10

### Added (media stack)
- **`ytdlp-ops` skill** - yt-dlp as the media ACQUISITION layer feeding
  ffmpeg-ops: format selection doctrine (`-S` sort over `-f` filters, codec
  targeting that avoids post-download transcodes), `--download-sections`
  clip-at-download, audio-only STT extraction (`-x --audio-format opus` =
  stream copy), playlist + `--download-archive` incremental channel syncs
  (`--break-on-existing --lazy-playlist` cron pattern), cookies/auth
  (`--cookies-from-browser`, Chrome 127+ Windows caveat, ban avoidance),
  rate limiting/politeness, SponsorBlock mark-vs-remove, output-template
  conventions (`[%(id)s]`, byte-safe `.100B` truncation), subtitles-as-cheap-
  transcripts, remux-vs-recode doctrine, livestream/premiere capture
  (`--live-from-start`, `--wait-for-video`), batch dry-runs (`--print
  filename`), a beyond-YouTube note, and a failure-triage ladder (the
  nsig/403/429/geo classes incl. TLS-fingerprint blocks → `--impersonate`,
  and the EJS class: missing formats from no JS runtime → deno default /
  `--js-runtimes node` opt-in, surfaced by the verifier as a warning;
  "outdated yt-dlp" is the diagnosis for most). Completes the acquire →
  process chain with ffmpeg-ops. Ships a §7 staleness
  verifier (`check-ytdlp-version.sh`: `--offline` structural in PR CI;
  `--live` = installed version >60 days behind the latest GitHub release,
  a documented core flag vanished from `yt-dlp --help`, or smoke-extraction
  failure → exit 10, network unreachable → exit 7 advisory; wired into
  `tests/check-resources.sh` + `freshness.yml`). 6 references, 1 date-stamped
  preset asset, 28-assertion offline self-test (age logic exercised via test
  seams - no network in tests).
- **`ffmpeg-ops` skill** - probe-first ffmpeg/ffprobe operations: ~30-command
  cookbook with footgun table (seek/keyframe semantics, `yuv420p`+`faststart`,
  quoting, VFR), EDL-driven editing (edit-as-code: schema asset +
  `cut-from-edl.py`, dry-run by default), `.cube` LUT grading with
  human-picks-the-grade chooser (`gen-luts.py`), STT/Whisper prep + the
  transcript-JSON contract, silence/scene segmentation (`detect-segments.py`),
  VMAF/SSIM quality gates (`quality-compare.py`), two-pass loudnorm automation,
  hw-encoder proof-encoding (`capability-scan.sh` - listed ≠ working), chapter
  authoring from scene/silence detection (`make-chapters.py` - ffmetadata mux /
  YouTube description / WebVTT), probe `--doctor` triage (each hazard - VFR,
  HDR transfer, rotation, interlacing, non-yuv420p, moov-at-EOF - paired with
  its exact fix command, exit 10), target-size compression
  (`smart-compress.py` - computed two-pass bitrate, auto audio/downscale,
  size-verified), scrub-preview sprites + WebVTT thumbnail track
  (`make-sprites.py`), an error-decoder reference (cryptic message → cause →
  fix), and a §7 staleness verifier (`verify-commands.sh`, wired into PR CI +
  freshness). Color grading is a first-class wing: a ~40-recipe look catalog
  (film stocks incl. CineStill halation as a verified composite, signature
  movie grades, era/genre moods, Sin City `colorhold`) with per-look scope
  checks and failure modes, an 18-variant mono/duo/tritone tone-map family
  (chroma = stop distance from the grey axis), the Hald-CLUT
  grade-anywhere→LUT workflow, a scope-matching ladder with its governing
  rule (transfer the chroma fingerprint globally; match key per scene-type,
  never the global mean) and a real-footage worked extraction (`grimdark`),
  plus a skin-tone equity caveat verified on the Kodak test portraits.
  `gen-luts.py` carries 32 parametric looks (channel-mix + 2/3-stop gradient
  maps). 19 references, 3 assets, 107-assertion self-test with
  lavfi-synthesized fixtures (no binary fixtures in repo).

### Fixed (media stack)
- **`ffmpeg-ops/cut-from-edl.py`** (found by real-media E2E):
  the output directory was created *after* ffmpeg opened the temp output, so
  any `-o` into a not-yet-existing directory died with a cryptic
  "Error opening output files"; and CLI `-o` resolved against the EDL's
  directory instead of the CWD (`-o work/final.mp4` with the EDL in `work/`
  silently meant `work/work/final.mp4`). `-o` is now CWD-relative (the EDL's
  own `output` field stays EDL-relative per the schema), and the destination
  dir is created before the concat runs.


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
- **20 expert agents** deprecated as part of the skills-first restructure
  (23 → 3 agents):
  - 11 language/framework experts → their `-ops` skill twins (python,
    typescript, javascript, go, rust, react, vue, astro, laravel, sql, postgres)
  - cypress-expert → `cypress-ops`; cloudflare-expert + wrangler-expert →
    `cloudflare-ops`; bash-expert → `bash-ops`; craftcms-expert → `craftcms-ops`;
    payloadcms-expert → `payloadcms-ops`; asus-router-expert → `asus-router-ops`
  - claude-architect → folded into `claude-code-ops`; aws-fargate-ecs-expert →
    folded into `container-orchestration`
  Per Anthropic's guidance, knowledge belongs in skills (progressive disclosure,
  single source of truth); subagents are reserved for context isolation. The
  only agents that remain are pure isolation/worker roles: `git-agent`,
  `firecrawl-expert`, `project-organizer`. Dispatching skills route
  `general-purpose` agents with skill preloading.
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
- **`craftcms-ops`, `payloadcms-ops`, `asus-router-ops` skills** - converted
  from the niche CMS/router agents and refreshed against current docs (Craft 5
  Matrix-as-entries; Payload 3 Next.js-native + Local API; Asuswrt-Merlin
  hardening + WireGuard)
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
