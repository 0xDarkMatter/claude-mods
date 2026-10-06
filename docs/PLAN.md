# Claude-Mods: Project Plan & Roadmap

**Goal**: A centralized repository of custom Claude Code commands, agents, and skills that enhance Claude Code's native capabilities with persistent session state, specialized expert agents, and streamlined workflows.

**Created**: 2025-11-27
**Last Updated**: 2026-10-06
**Status**: Active Development

> Historical record of what shipped lives in [CHANGELOG.md](../CHANGELOG.md) and the
> README "Recent Updates" section. This file only tracks what's *next*.

---

## Current Inventory

| Component | Count | Notes |
|-----------|-------|-------|
| Agents | 3 | Pure context-isolation/worker roles only: git-agent (background commits/PRs), firecrawl-expert (noisy scrapes), project-organizer (bulk restructure) |
| Skills | 112 | Operational skills, CLI tools, workflows, diagnostics, security |
| Commands | 3 | Session management + git orchestration (sync, save, git-ops) |
| Rules | 15 | agentic-quality, cli-tools, commit-style, deploy-gating, dev-servers, loop-engineering, modern-tools, naming-conventions, prompt-injection, public-posts, release-review, shell-preference, skill-agent-updates, supply-chain, worktree-boundaries |
| Output Styles | 13 | Vesper, Spartan, Mentor, Executive, Pair, Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage, Scout |
| Hooks | 13 | lint, format, safety, uv, install-scan, manifest-scan, pmail, unicode-scan ×2, config-change guard, worktree guard, peer-writer guard, touched-files ledger |

Counts are enforced by the CI doc-drift gate (see roadmap) — if this table rots, CI fails.

## Docs Map

The one docs index is [00_INDEX.md](00_INDEX.md). This file kept a second copy until
2026-10, and it drifted; don't add one back.

---

## Active Roadmap (June 2026 strategic review)

### Phase 1 — Hygiene & truth (v2.11)

- [x] README skill/hook/rule tables match disk (24 missing skills added)
- [x] Remove ghost references (`rules/thinking.md`, `docs/DASH.md`)
- [x] Rename `tests/skills/functional/git-workflow.*` → `git-cli-tools.*`
- [x] `CHANGELOG.md` (keep-a-changelog format, seeded from Recent Updates)
- [x] CI: doc-drift gate (counts on disk vs README claims, ghost-link check)
- [x] CI: run every `skills/*/tests/run.sh` behavioural suite

### Phase 2 — Skills-first restructure (v3.0)

- [x] **Agent cull**: deprecated 11 experts with `-ops` skill twins (python,
      typescript, javascript, go, rust, react, vue, astro, laravel, sql,
      postgres). Unique content folded into twin skills; dispatching skills
      now route general-purpose agents with skill preloading. 23 → 12 agents.
- [x] **claude-code-ops**: merged + refreshed claude-code-debug /
      claude-code-headless / claude-code-hooks against current official docs
      (30-event hook catalog, current skill frontmatter, current CLI flags).
- [x] **New skills**: claude-api-ops (Messages API, tool use, caching, Agent SDK),
      playwright-ops, terraform-ops.

### Phase 3 — Distribution & native-feature adoption

- [ ] Submit to the official plugin directory (form: https://clau.de/plugin-directory-submission).
      Structure already conforms — `.claude-plugin/plugin.json`, `commands/`,
      `agents/`, `skills/`, `README.md`. Separately, skills.sh needs no
      submission at all: a public repo with `SKILL.md` files is installable via
      `npx skills add <owner>/<repo>` and surfaces there on install telemetry.
- [x] Reposition /save + /sync as portable/team-shareable state (native
      auto-memory covers single-machine context)
- [x] Adopt new hook events: ConfigChange guard (worm-persistence IOCs on
      settings edits) + worktree guard (worktree-boundaries enforcement).
      Note: ConfigChange payload carries source-not-path, so VS Code settings
      stay covered by integrity-audit.sh instead.
- [x] Auto-wire security hooks via plugin hooks/hooks.json (skill-scoped hooks
      only fire while a skill is active, so plugin level is the right layer)
- [x] fleet-ops v2: repositioned as landing discipline (queue, test gate,
      scrub, revert) on top of native agent teams / background agents; new
      `fleet track` registers natively-spawned branches

### Phase 4 — Fleetflow quality wave (2026-07)

Full build spec: [docs/plans/QUALITY-2026-07.md](plans/QUALITY-2026-07.md).
Theme: subtraction and enforcement, not addition.

- [x] Phase 0 — closed the loop (README count fixes, plan committed, CI green)
- [x] Phase 1 — enforcement gates: description-budget gate (700 hard cap as
      shipped; raised to 1000 in 2026-08 — `tests/validate.sh` is authoritative),
      section-map drift gates (summon, svg-brand-tint-ops), doc-drift
      extensions (prose counts, frontmatter ghost refs), repo-doctor
      guard-comment recognition, hook wiring on script installs
- [x] Phase 2 — consolidation: `parallel-ops` router shipped, 22-skill
      description trim, portability sanitization (process-compose-ops,
      portless-ops, shell-preference.md), dsp-launch retirement,
      description-budget gate flipped WARN→FAIL
- [ ] Phase 3 — robustness floor: push-preflight test suite, verifier-wrap suites,
      security-sensitive suites (security-ops, pigeon, leveldb-ops),
      remaining test backlog, protocol backfill on 2025-12-21 scaffold batch
      (R6 within Phase 3 is done — see below)
- [x] R6 — docs truth pass: AGENTS.md refresh, this inventory update,
      test-floor policy in SKILL-CREATION-PROTOCOL.md, full-suite-gate note
      in fleet-ops, baseline-before-closeout note in fleetflow
- [ ] Deferred follow-ons — skill-telemetry, marketplace submission,
      claude-mods-local formalization, push-cadence advisory (wave's Phase 4,
      not this repo's Phase 4 heading)

### Phase 5 — AGENTS.md toolchain (2026-10)

Build spec, dogfood findings and the survey behind it:
[docs/plans/AGENTS-MD-2026-10.md](plans/AGENTS-MD-2026-10.md).

- [x] repo-doctor creates, audits, upgrades and org-surveys AGENTS.md (`repo-scan.py`,
      `agents-md.py`, archetype templates, memory-docs tripwire); landed `42d6862`
- [x] Fix the five gaps dogfooding found (size budget, split order, candidate noise,
      generic archetype, convention-found tests); see the plan
- [x] Dogfood: this repo's AGENTS.md from 199 lines / 16,744 chars to 172 / 13,293
      (Installation to README, generic tips dropped, the 2,313-char line split)
- [ ] Owner pass on this repo's AGENTS.md: answer or rule out the 10 scan candidates the
      audit lists, and trim Landmines toward the 150-line target
- [ ] Team rollout: a pilot needs the team lead's OK, then repo owners run scan,
      scaffold and audit in their own checkouts. In a repo that deploys on merge, the
      AGENTS.md merge is a deploy and stays the owner's (`rules/deploy-gating.md`)
- [ ] Team-plugin port: the protocol, `repo-scan.py`, `agents-md.py` and the archetype
      templates as one folder. The team plugin owns its copy and lands its own fixes

---

## Open Questions

- Should output styles be repositioned as "persona kits"? (still natively supported,
  but de-emphasized)
- Skill description budget at 80+ skills — document `skillOverrides` guidance?

---

## Guiding Principle

> The best enhancements solve problems you've already felt. Follow the pain.
