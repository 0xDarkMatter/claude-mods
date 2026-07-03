# Claude-Mods: Project Plan & Roadmap

**Goal**: A centralized repository of custom Claude Code commands, agents, and skills that enhance Claude Code's native capabilities with persistent session state, specialized expert agents, and streamlined workflows.

**Created**: 2025-11-27
**Last Updated**: 2026-06-10
**Status**: Active Development

> Historical record of what shipped lives in [CHANGELOG.md](../CHANGELOG.md) and the
> README "Recent Updates" section. This file only tracks what's *next*.

---

## Current Inventory

| Component | Count | Notes |
|-----------|-------|-------|
| Agents | 3 | Pure context-isolation/worker roles only: git-agent (background commits/PRs), firecrawl-expert (noisy scrapes), project-organizer (bulk restructure) |
| Skills | 98 | Operational skills, CLI tools, workflows, diagnostics, security |
| Commands | 2 | Session management (sync, save) |
| Rules | 8 | cli-tools, commit-style, naming-conventions, prompt-injection, skill-agent-updates, supply-chain, worktree-boundaries, loop-engineering |
| Output Styles | 13 | Vesper, Spartan, Mentor, Executive, Pair, Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage, Scout |
| Hooks | 13 | lint, format, safety, uv, install-scan, manifest-scan, pmail, unicode-scan ×2, config-change guard, worktree guard, peer-writer guard, touched-files ledger |

Counts are enforced by the CI doc-drift gate (see roadmap) — if this table rots, CI fails.

---

## Active Roadmap (June 2026 strategic review)

### Phase 1 — Hygiene & truth (v2.11)

- [x] README skill/hook/rule tables match disk (24 missing skills added)
- [x] Remove ghost references (`rules/thinking.md`, `docs/DASH.md`)
- [x] Rename `tests/skills/functional/git-workflow.*` → `git-cli-tools.*`
- [ ] `CHANGELOG.md` (keep-a-changelog format, seeded from Recent Updates)
- [ ] CI: doc-drift gate (counts on disk vs README claims, ghost-link check)
- [ ] CI: run every `skills/*/tests/run.sh` behavioural suite

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

- [ ] Submit to community marketplace (claude.ai/settings/plugins/submit)
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

---

## Open Questions

- Should output styles be repositioned as "persona kits"? (still natively supported,
  but de-emphasized)
- Skill description budget at 80+ skills — document `skillOverrides` guidance?

---

## Guiding Principle

> The best enhancements solve problems you've already felt. Follow the pain.
