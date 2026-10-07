# Monorepo Structure — organising very large repos for agentic development

A monorepo is where agentic-quality economics bite hardest: entry-doc token cost
multiplies across sessions, navigability failures multiply across subsystems, and
parallel agent sessions multiply write-collision risk. This reference is the playbook,
distilled from the four large multi-subsystem repos in the 2026-07 audit (a pnpm
app/packages monorepo at 4.8/5, a multi-app Workers platform at 3.5/5, a Python
orchestration platform at 4.4/5, and a 116-tool CLI farm at 3.0/5) — what the strong
ones did that the weak ones didn't.

---

## Contents

- 1. The organising principle: subsystem = contract boundary
- 2. Root AGENTS.md is a router, not an encyclopedia
- 3. Nested entry docs: own-contract packages only
- 4. Mechanical gates make big shared code safe
- 5. Navigation aids that scale past folder-guessing
- 6. File-size discipline under monorepo gravity
- 7. Parallel agents in one monorepo
- 8. Extraction: when a subsystem should leave the monorepo
- 9. Monorepo audit checklist (repo-doctor lens)

## 1. The organising principle: subsystem = contract boundary

Structure the repo so every top-level unit is a **contract boundary** — a thing with
its own invariants, its own tests, and a one-line answer to "what may depend on me."
Not "frontend/backend", not file-kind buckets (`utils/`, `helpers/`), but:

```
apps/          deployable things (web SPA, worker API, admin)
packages/      shared contracts (engine, content, design-system, sim harness)
docs/          repo-level docs + index; per-package docs live IN the package
scripts/       invariant gates + repo tooling (check-*.mjs pattern)
migrations/    append-only, numbered
```

The test an agent applies constantly: *can I guess the path from the concept?*
`packages/engine/src/rng/` and `src/xero/` pass; `src/utils2/` and `lib/misc/` fail.
Every failed guess is a fan-out search an agent runs instead of one file read.

## 2. Root AGENTS.md is a router, not an encyclopedia

At monorepo scale the root entry doc changes job: repo-wide invariants + an
**ownership table**, nothing else. Target well under 150 lines — it's read every
session regardless of which package the session touches.

```markdown
## Ownership

| Subsystem | Path | Contract | Gate |
|---|---|---|---|
| Engine (deterministic sim) | packages/engine/ | packages/engine/AGENTS.md | engine golden tests |
| Design system | packages/halcyon/ | packages/halcyon/AGENTS.md + DESIGN.md | npm run lint:design |
| Data layer | src/db/ | "only module touching D1" (contract block) | scripts/check-no-raw-d1.mjs |
| Xero integration | src/xero/ | ADR-006/010 | xero-saga tests |
```

Root keeps: the ownership table, cross-cutting invariants (money, auth, determinism),
the `check` command, repo-wide landmines. Everything package-specific moves DOWN into
that package's entry doc. The audit's weakest monorepo entry docs were encyclopedias
that tried to hold every subsystem's rules at root — every session paid for all of
them, and package-local changes routinely forgot to update the far-away root doc.

`agents-md.py audit` checks the routing: a nested doc the root never names is
`nested-unlinked`, and `--diff` adds its row to the ownership table in the table's own
columns. A root landmine that names only one package's paths is reported as belonging in
that package's doc (`landmine-belongs-nested`); moving it stays the owner's call.

## 3. Nested entry docs: own-contract packages only

Full policy in [agents-md-protocol.md](agents-md-protocol.md) section 6; the monorepo
application:

- Every `packages/*` with its own invariant law, audience, or gate → its own
  AGENTS.md (deltas + local landmines; target 40 lines, 60 at most).
- `apps/*` usually DON'T need one — they consume contracts, they don't define them; a
  structure-map line at root suffices.
- A tool-farm (100+ sibling dirs of the same shape) needs a **protocol doc once** +
  per-tool docs only where a tool has real per-tool knowledge (auth quirks, API
  gotchas). Template-stamped boilerplate docs across 100 dirs are negative value —
  they bury the ones with real content.

These rules are mechanical now. `repo-scan.py`'s nesting advisor scores each candidate
on its contract signals (own manifest, tests, deploy, landmine cluster, gate), holds apps
to a deploy or landmine signal, and gives a farm of 8 or more same-shaped siblings one
doc at its parent. `agents-md.py scaffold --dir <package>` drafts the doc with a scope
line and the package's own commands in their root-runnable workspace form, and the audit
checks every nested doc against its own folder (protocol section 6). Past a few
contracted packages, the codemap and cross-package invariants go in an ARCHITECTURE.md
(protocol section 10).

## 4. Mechanical gates make big shared code safe

The single strongest pattern found in the audit: **a 30-line check script converts a
prose rule into a physical property of the repo.**

- `check-no-raw-d1.mjs` — "only repo.ts touches the database" → a 9,560-line data
  layer stays *safe* (every agent knows exactly where all queries live) even while it
  stays unpleasant.
- `lint:design` — "style only from tokens; no package→app imports" → a design-system
  package survives dozens of agent sessions without palette drift.
- Golden/replay tests — "engine output is byte-identical across refactors" → agents
  refactor the engine fearlessly.

Directive: **every cross-package invariant in the ownership table has a gate.** A rule
without a gate is a request; agents (and humans) will eventually violate it silently.
Wire all gates into ONE `check` entry point (`npm run check`, `just check`) that fans
out to per-package checks — if verification isn't one command, it doesn't happen.

Gate detection is mechanical too. `repo-scan.py` (section `gates`) finds the boundary
checkers below, with each one's scope (its folder) and whether `check` or CI runs it. The
scorer credits only gates something runs in full; one nothing runs counts half.

| Tool | Detected from |
|---|---|
| import-linter, tach | `.importlinter` or `[tool.importlinter]`; `tach.toml` |
| dependency-cruiser | `.dependency-cruiser.{js,cjs,json}` |
| eslint-plugin-boundaries, Nx module boundaries | the plugin or `@nx/enforce-module-boundaries` in an eslint config; `project.json` tags |
| ArchUnit, deptrac | `@ArchTest` / `@AnalyzeClasses` in tests; `deptrac.php` / `deptrac.yaml` |
| Go | `internal/` folders; `depguard` in `.golangci.*` |
| Invariant tests | the root's `scripts/check-*`, or one `check` runs |

A gate with a list of tolerated violations (a baseline, a freeze store) is reported as
partial, with the list's size. The audit flags a prose invariant ("X never imports Y")
that no detected gate covers as `invariant-ungated`.

## 5. Navigation aids that scale past folder-guessing

When the repo outgrows guessability, add explicit maps — in this order of cost:

1. **docs index** (`docs/00_INDEX.md`) once docs/ passes ~6 files. Two anti-rot rules
   (from the one index that stayed accurate across a large project): the index carries
   its own maintenance instruction, and volatile lists are delegated to the filesystem
   ("ADRs: see `ls docs/adr/`") instead of hand-copied.
2. **Section maps inside justified monster files** — the 9,000-line single-writer file
   needs a top-of-file TOC more than any other file in the repo.
3. **A function/route map** (`docs/repository-map.md`) for a monster module that can't
   be split yet — cheaper than the split, buys most of the navigation back.
4. **A machine-readable registry** for farms of same-shaped units (tools, connectors,
   generators): one `REGISTRY.json` with name/category/description/status per unit.
   The audit's 116-tool farm without one forced every discovery into a filesystem walk
   or a shell-out; one JSON read replaces both.

## 6. File-size discipline under monorepo gravity

Big repos grow monster files faster (more contributors-per-file, more "just add it
here"). The escalation ladder (same as rules/agentic-quality.md, applied per package):

- ~400 lines → section markers
- ~800 lines → split along responsibility seams (refactor-ops), OR write the guard
  comment justifying why not
- deliberately-large files → guard comment + section map + the gate that enforces the
  invariant justifying them (a monster WITHOUT a gate is just debt with a story)

Splitting priorities when a package's core file bloats: split by *lifecycle* first
(read paths vs write paths), then by *entity*. Resist `utils.ts` as a split target —
it's where guessability goes to die.

## 7. Parallel agents in one monorepo

Monorepos concentrate agent traffic; collisions are structural, not behavioural.
The rules (full doctrine: rules/worktree-boundaries.md, fleet-ops skill):

- **One writer per checkout.** Parallel sessions get worktrees; the main checkout is
  landing-only.
- **Partition by subsystem**, not by file list — the ownership table doubles as the
  lane map ("this session owns packages/engine, that one owns apps/web").
- **Land early, land often** — long-lived divergence across a shared `packages/` layer
  is the monorepo-specific failure; cross-package refactors belong in short, dedicated
  lanes that land before feature lanes rebase.
- Per-package `check` gates keep landing cheap: a lane that only touched
  `packages/content` runs that package's suite, not 20 minutes of everything.

## 8. Extraction: when a subsystem should leave the monorepo

The audited ecosystem's own rule, proven twice: **when a subsystem grows a roadmap, an
asset library, or an audience of its own, it's a product — extract it** before it
distorts the host repo's docs, tests, and entry-doc budget. Signals:

- Its docs start explaining things no other subsystem cares about
- Its issues/plans track independently of repo releases
- Outside consumers appear (another repo vendors or clones it)
- Its assets dwarf the host (models, sample libraries, fixtures)

Extraction hygiene: the new repo gets its own AGENTS.md + README day one; the host
keeps a pointer (skill/package doc → "extracted to <repo>"); no stale paths back.

## 9. Monorepo audit checklist (repo-doctor lens)

Run `scripts/repo-doctor.py` and `agents-md.py audit` at root (both cover nested docs),
`scripts/repo-doctor.py` per major package, then verify the rest by hand. Items marked
*(checked)* are mechanical now:

- [ ] Root AGENTS.md is a router (<150 lines) with an ownership table *(checked: size;
      `nested-unlinked` for the table)*
- [ ] Every own-contract package has its nested entry doc, linked from the table
      *(checked: the nesting advisor, the scorer's entry_docs, survey's `flat-monorepo`)*
- [ ] Every ownership-table invariant has a named mechanical gate *(checked:
      `invariant-ungated`, the scorer's enforcement)*
- [ ] One `check` command fans out to per-package checks *(checked: gates that `check`
      never runs count half)*
- [ ] Past a few contracted packages, an ARCHITECTURE.md holds the codemap *(checked:
      `architecture-warranted`, then layout and name staleness)*
- [ ] docs/ has an index; volatile lists delegated to filesystem
- [ ] No package's core file is a gateless monster
- [ ] Farms of same-shaped units have a machine-readable registry
- [ ] Nothing in the repo is a stealth product overdue for extraction
