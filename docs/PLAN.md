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
| Agents | 23 | Domain experts + git-agent background worker (cull in progress — see below) |
| Skills | 80 | Operational skills, CLI tools, workflows, diagnostics, security |
| Commands | 2 | Session management (sync, save) |
| Rules | 7 | cli-tools, commit-style, naming-conventions, prompt-injection, skill-agent-updates, supply-chain, worktree-boundaries |
| Output Styles | 13 | Vesper, Spartan, Mentor, Executive, Pair, Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage, Scout |
| Hooks | 9 | lint, format, safety, uv, install-scan, manifest-scan, pmail, unicode-scan ×2 |

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

- [ ] **Agent cull**: deprecate language/framework experts with `-ops` skill twins
      (python, typescript, javascript, go, rust, react, vue, astro, laravel).
      Fold unique agent content into the twin skill first. Keep: git-agent,
      claude-architect, firecrawl-expert, niche experts without skill twins.
- [ ] **claude-code-internals**: merge + refresh claude-code-debug /
      claude-code-headless / claude-code-hooks against current official docs
      (new hook events, skill frontmatter fields, CLI flags).
- [ ] **New skills**: claude-api-ops (Messages API, tool use, caching, Agent SDK),
      playwright-ops, terraform-ops.

### Phase 3 — Distribution & native-feature adoption

- [ ] Submit to community marketplace (claude.ai/settings/plugins/submit)
- [ ] Reposition /save + /sync as session introspection + team-shareable state
      (native auto-memory now covers solo persistence)
- [ ] Adopt new hook events (ConfigChange guard for supply-chain-defense,
      WorktreeCreate/Remove for worktree-boundaries, InstructionsLoaded for
      unicode scanning)
- [ ] Skill-scoped hooks: move manifest-dep-scan inside supply-chain-defense
- [ ] Evaluate agent teams as fleet-ops v2 substrate

---

## Open Questions

- Should output styles be repositioned as "persona kits"? (still natively supported,
  but de-emphasized)
- Skill description budget at 80+ skills — document `skillOverrides` guidance?

---

## Guiding Principle

> The best enhancements solve problems you've already felt. Follow the pain.
