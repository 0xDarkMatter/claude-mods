# Entry Docs — AGENTS.md anatomy, the CLAUDE.md question, nesting, freshness

The entry doc is the highest-leverage file in a repo for agentic development: every
session reads it, so every line is either recurring value or recurring token tax.
This reference owns the anatomy and the two recurring debates (AGENTS vs CLAUDE,
nested entry docs), with verdicts grounded in a 2026-07 audit of 37 repos.

---

## AGENTS.md anatomy (the template is assets/AGENTS-template.md)

Order matters — put what agents need most often first:

1. **What this repo is** — 2–4 lines. Not marketing; orientation.
2. **Commands** — run / test / `check` / deploy, exact and tested. A wrong command in
   an entry doc costs more than no command (agents trust it over exploration).
3. **Landmines** — MANDATORY, the highest-value section. The things that break
   *non-obviously*: coupled golden fixtures ("growing any pool invalidates three test
   suites — regeneration procedure below"), generated files ("index.html is baked —
   edit template.html"), ordering-sensitive registries, env quirks (OOM flags, path
   conversions). Rule of admission: *would a competent agent plausibly trip this?*
   Each landmine: what breaks, why, the procedure.
4. **Structure map** — folder → what lives there, one line each. For monorepos this
   becomes the ownership table (see monorepo-structure.md).
5. **Conventions** — the repo-specific deltas only (style, naming, commit scope).
   Global conventions live in global rules; don't re-state them.
6. **Pointers** — docs index, ADR dir, design docs. Link, don't inline.

**Length budget: ~150 lines target, 250 hard ceiling** (the scorer warns above 250).
What gets evicted first: human setup walkthroughs (→ README/CONTRIBUTING), procedural
tutorials (→ docs/), rationale essays (→ ADRs). The audit's sharpest contrast: a
269-line entry doc where every line was load-bearing (landmines, pinned commands,
terminology canon) scored 5/5; a 350-line one mixing agent hazards with human setup
guides scored 4/5 and cost every session the difference.

## AGENTS.md vs CLAUDE.md — the verdict

Survey data (37 active repos, 2026-07): 431 AGENTS.md vs 42 CLAUDE.md, and most
CLAUDE.md files were inside cloned third-party repos. AGENTS.md won; it's the open
standard read by all agent tooling (Claude Code, Codex, Cursor, …).

**Default: one AGENTS.md, no CLAUDE.md.** Claude Code reads AGENTS.md fine.

**Acceptable dual-file pattern** (one known-good production example): AGENTS.md holds
*universal invariants* (money rules, scoping, test discipline — stable, audience-
agnostic); CLAUDE.md holds *Claude-specific operational deltas* (implementation-stack
guardrails, crash-recovery mechanics — volatile, evolves with the work). Three
conditions make it work, and all three are required:

1. **Deltas only** — CLAUDE.md never restates AGENTS.md content.
2. **Lockstep maintenance** — a change to a shared rule updates both in one commit.
3. **Both stay under budget** — two lean files, not two bloated ones.

If you can't commit to all three, don't split. A CLAUDE.md that's a one-line pointer
to AGENTS.md is always fine for tool compatibility.

## Nested entry docs — when subfolder AGENTS.md/CLAUDE.md earns its place

Community advice says "nest CLAUDE.md everywhere." The drive-wide evidence says
otherwise: every blanket-nested example found was a cloned third-party repo, and the
only *home-grown* nested entry doc that worked was a subsystem with a genuinely
distinct contract (a portable design-system package with its own tokens-only law,
gallery, and lint gate).

**Nest when the subsystem has its own contract**, meaning at least one of:
- Its own invariant law (determinism engine, tokens-only design system, single-writer
  data layer)
- Its own audience (a package consumed by other repos; a per-tool CLI in a tool farm)
- Its own gate (`lint:design`, per-package `check`)

**Rules for a nested entry doc:**
- Deltas + local landmines ONLY — never duplicate root rules (duplication rots into
  contradiction, and agents can't tell which file wins).
- Root AGENTS.md links every nested one in its ownership table — nesting without the
  router breaks discoverability.
- Same length discipline, smaller budget (~60 lines).

**Do not nest** to restate root conventions per-folder, to shorten paths in prompts, or
because a folder is merely large. Large-but-contractless folders need a structure-map
line in root, not their own doc. Note the tooling asymmetry: Claude Code auto-loads
nested CLAUDE.md on demand when working in that subtree — that's the *mechanism*; the
own-contract test above is the *policy* for when to use it.

## Freshness — commits, not days

Measure entry-doc staleness in **commits since the doc was last touched**, never
wall-clock. Audit evidence: repos with week-old mtimes hid 100+ commits of drift; the
mtime looked fine because an unrelated edit touched the file.

- Healthy: entry doc touched within ~15 commits (scorer threshold).
- The discipline that keeps it healthy: any commit that invalidates an entry-doc claim
  updates the doc in the same commit — "done includes the doc touch"
  (rules/agentic-quality.md non-negotiable #3).
- Automatable check: `git rev-list --count HEAD ^$(git rev-list -1 HEAD -- AGENTS.md)`

## README.md relationship

README = first-time human (what/why, quickstart, badges, doc index). AGENTS.md =
recurring agent (commands, landmines, structure). Distinct audiences, minimal overlap;
each links the other. If they've converged into near-duplicates, the README is usually
the one that's drifted — trim it to narrative + links.

## Generation and consolidation

Missing or fragmented entry docs (CLAUDE.md + COPILOT.md + CURSOR.md …) → the
`doc-scanner` skill scans, synthesizes, and consolidates into one AGENTS.md. Seed new
repos from assets/AGENTS-template.md — the Landmines section ships with prompts so it
can't be skipped silently.
