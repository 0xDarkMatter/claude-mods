# Nested entry docs and ARCHITECTURE.md (2026-10)

Build spec for `lane/nested-entry-docs`: teach repo-doctor to spread a large repo's agent
docs across several files. That means a nested `AGENTS.md` where a folder has its own
contract, an `ARCHITECTURE.md` where the repo has outgrown a short structure map, and a
measure of what a session actually loads. Follows `AGENTS-MD-2026-10.md`, whose tools
this extends.

## Why

- **The protocol states the nesting rules; no tool enforces them.** Section 6 of
  `references/agents-md-protocol.md` says nest only for an own-contract folder, keep a
  nested file near 60 lines, link it from the root and never restate root rules. Today
  the tools only warn when a CLAUDE.md shadows a nested AGENTS.md, create one as a side
  effect of a split, and count them in the survey. Nothing says where a repo *should*
  nest, and nothing audits a nested file.
- **Size problems in the field are nesting problems.** In the 2026-10 survey of one
  organisation's 64 repos, 6 of the 14 AGENTS.md files ran 225 to 595 lines. Most of
  that is per-package detail that belongs in the package, which `audit --diff` cannot
  move, because it only moves whole sections.
- **One file's size is the wrong measure.** A session working in `packages/api/` loads
  the root doc, every nested doc down to that folder, their `@` imports and every rule
  without a `paths` field. The audit measures one file.
- **Large repos need a map that isn't the entry doc.** A codemap and the invariants
  between layers are too long for AGENTS.md and too stable to rewrite each week:
  matklad's ARCHITECTURE.md (Sources). The protocol's section 2 currently sends every
  architecture overview "nowhere", which is right for derivable tours and wrong for
  this.

## Decision: extend repo-doctor, in the same files

Everything lands in `skills/repo-doctor/`. Facts go in `repo-scan.py`, rendering and
auditing in `agents-md.py`, the score in `repo-doctor.py`. Both big scripts carry a
"deliberately one file" guard comment (the skill is copied as a folder and must run
alone); keep it, and update each section map. `agents-md.py` will likely pass 1,800
lines. The scorer treats a large file with a guard comment and a section map as
justified (an info finding asking you to verify its gate). The standalone-copy tests in
`tests/agents-md.sh` and `tests/repo-scan.sh` are that gate.

| Rejected | Why not |
|---|---|
| A new `architecture-ops` skill | A second judge of the same doc set; ARCHITECTURE.md is a split destination and pointer target of AGENTS.md, so they share the facts, the patch builder and the audit |
| A separate `nest.py` | The advisor needs repo-scan's areas, workspaces and candidates, and the audit needs the advisor; a third script means a third copy of the facts plumbing |
| Generating ARCHITECTURE.md for every repo | A generated tour is the derivable overview the protocol rejects, and it goes stale. Only the owner knows the invariants |

## Claude Code facts this relies on

Verified 2026-10-07 against https://code.claude.com/docs/en/memory. Add each one to
`check-memory-docs.py` (offline phrase in the protocol, live phrase copied from the page
after re-fetching it):

| Fact | Section |
|---|---|
| CLAUDE.md files above the working directory load at launch; files in subdirectories load on demand | "How CLAUDE.md files load" |
| A subdirectory's AGENTS.md loads when Claude opens a file there with the Read tool, and only if that folder has none of the three CLAUDE.md files | "AGENTS.md" |
| `@path` imports load at launch, resolve relative to the importing file, recurse at most four hops, and are skipped inside code spans and fenced blocks | "Import additional files" |
| `.claude/rules/` files without `paths` frontmatter load at launch; path-scoped ones load when Claude reads, writes or edits a matching file | "Path-specific rules" |
| `/import` appends a one-time copy of AGENTS.md to the matching CLAUDE.md | "AGENTS.md" (relevant to sibling lane A) |

## What ships

### N1. Nesting advisor (`repo-scan.py`, new section `nesting`)

Candidates: declared workspace members, the code-holding children of `CONTAINER_DIRS`,
and top-level code areas. Never: generated, vendored, docs, tests, CI or asset areas, or
a folder under `MIN_NEST_FILES` (15) tracked files.

| Signal | Kind | Points | Evidence |
|---|---|---|---|
| own manifest (`package.json`, `composer.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`) at the folder root | contract | 2 | its own commands |
| own test suite (a test config, or a `tests/` runner, inside the folder) | contract | 2 | its own gate |
| own deploy surface (the `DEPLOY_SURFACES` patterns anchored to the folder) | contract | 2 | its own release |
| landmine cluster: 2 or more history candidates whose paths all sit inside it | contract | 2 | local landmines |
| own gate script or boundary config (`check-*`, dependency-cruiser, import-linter, eslint-plugin-boundaries) | contract | 1 | an enforced invariant |
| dominant language differs from the repo's | contract | 1 | a different stack |
| touched by 15% or more of the scanned commits | weak | 1 | activity |
| file count | none | 0 | reported, never scored |

Recommend when contract points reach 4 from at least 2 distinct contract signals. Two
rules come from `references/monorepo-structure.md` section 3:

- **`apps/*` consume contracts, they rarely define them.** An app is recommended only
  with an own-deploy or landmine-cluster signal.
- **Farms get one protocol doc.** When 8 or more siblings share one shape (the same
  manifest kind and the same root file names), recommend a single `<parent>/AGENTS.md`,
  plus nested docs only for siblings that have a landmine cluster.

Output: `data.nesting = {"recommend": [...], "farms": [...], "considered": N}`, each item
`{dir, points, signals: [{kind, detail, source}], existing: {agents_md, claude_md}}`.
Every signal cites a source like every other scan fact. Thresholds are constants with
comments; tune them only against fixtures, and record why in the comment.

### N2. `agents-md.py scaffold --dir <folder>`

A nested draft from `assets/agents-md/nested.md`. It contains:

- a one-line overview
- the folder's own commands, from its own manifest
- the landmine candidates whose paths all sit inside the folder
- a link back to the root

It contains nothing the root already says. When the repo declares workspaces, write
commands in the root-runnable form (`npm -w <dir> run x`, `pnpm --filter <name> x`,
`yarn workspace <name> x`, with the name sourced from the member's manifest). Otherwise
head the block "Run from `<dir>/`".

Budget: `NESTED_TARGET_LINES` 40 and `NESTED_CEILING_LINES` 60, with characters at 80 a
line (`NESTED_CEILING_CHARS` 4,800). `--write` creates `<folder>/AGENTS.md` only, refuses
to overwrite, and warns when a CLAUDE.md in that folder will shadow it. `repo-scan.py`
needs manifest facts per folder for this: parameterise the manifest readers on a
sub-root rather than duplicating them.

### N3. Audit every AGENTS.md in the repo

Iterate the tracked AGENTS.md files (skip `node_modules/`, `vendor/`, `.claude/`). Add
`data.docs[]` with one record per doc (`path`, `kind`: root, nested or architecture,
`lines`, `chars`, `commits_since`, findings). Keep the existing root fields for
backward compatibility; the tests read them.

| Finding | Severity | Rule |
|---|---|---|
| `nested-over-budget` | warn | over 60 lines or 4,800 characters |
| `nested-unlinked` | warn | the root AGENTS.md never names the folder's doc |
| `nested-restates-root` | info | 3 or more normalised lines of 40+ characters also appear in the root |
| `nested-dead-command` | warn | a command checked against *that folder's* manifest (reuse `check_command` with that folder's facts) |
| `nested-stale` | warn | over 15 commits touching `<dir>/` since the doc was last touched. Count the subtree only (`git rev-list --count <since>..HEAD -- <dir>/`): repo-wide commits say nothing about a package |
| `nested-shadowed` | warn | exists today; keep it |

`--diff` adds a pointer to each unlinked nested doc in the root: a row in an existing
`## Ownership` table, else one line under the structure section. The line says when the
doc applies (for example, "`packages/engine/`: own rules in packages/engine/AGENTS.md,
read before changing the engine"), never "see X".

### N4. Route candidates to the nearest doc

A candidate's owner doc is the deepest AGENTS.md whose folder contains all of the
candidate's `paths`, else the root. `uncovered_candidates` checks each candidate against
its owner doc, and is reported per doc.

When a root Landmines item names only paths inside one nested doc's folder, report
`landmine-belongs-nested` (info), naming the item's line and the target doc. The patch
never moves a landmine: protocol section 3 leaves that move to the owner.

### N5. Load per folder

For the root, and for each folder that has a nested doc, sum what a session working
there loads:

1. The entry docs from the repo root down to that folder, honouring shadowing: where a
   folder has any CLAUDE.md, its AGENTS.md counts only if imported.
2. Their `@` imports: relative to the importing file, at most four hops, ignoring code
   spans and fences.
3. Repo-level `.claude/rules/*.md` without `paths` frontmatter.

Report `data.load[] = {dir, files, chars, est_tokens}`, where `est_tokens` is chars /
3.6. Raise `load-over-budget` (warn) past `LOAD_CEILING_CHARS`, which is 16,000 + 4,800 =
20,800: the root ceiling plus one nested budget. Say in the output that user-scope files
(`~/.claude`) are excluded, because they are per-machine.

### N6. ARCHITECTURE.md

**Shape** (matklad, Sources): a bird's-eye view of the problem; a codemap ("where does X
happen?"), naming important files, modules and types rather than linking them, because
links rot and readers use symbol search; invariants, especially those stated as an
absence; layer and system boundaries; cross-cutting concerns. It stays short, holds only
what rarely changes, and is revisited a few times a year rather than kept in sync.

| Piece | Behaviour |
|---|---|
| Recognise | `ARCHITECTURE.md` at the root (also accept `docs/ARCHITECTURE.md` when it has a codemap section; recommend the root) |
| When it's warranted (scan: `architecture.warranted` plus reasons) | 2 or more nesting recommendations, or 4 or more code areas with contract signals, or 3 or more workspace members, or a root Structure section over 25 lines or 2,000 characters. Otherwise say nothing |
| `scaffold --architecture` (`assets/agents-md/architecture.md`) | The codemap is filled from facts: one row per area, with the entry points the scan found (manifest `main`/`bin`/`exports`, `index.*`, `cmd/*`, `__main__.py`), named not linked. Boundaries come from workspace-to-workspace dependencies in the manifests, when present and sourced. The bird's-eye view, invariants and cross-cutting concerns are `TODO(owner)` questions, with invariant questions seeded from coupling candidates and boundary configs. It refuses to overwrite |
| Budget | 200 lines / 16,000 characters, the same ceiling as the root entry doc |
| Root pointer | `--diff` adds one line to the root AGENTS.md when ARCHITECTURE.md exists but isn't linked: "Read ARCHITECTURE.md before adding a module or moving code between packages." |
| Split destination | When the root's Structure section overflows, the split moves it to ARCHITECTURE.md's codemap, when that file exists or is warranted, instead of `docs/agents/structure.md` |
| `architecture-stale` (warn) | Top-level folders or workspace members added or renamed since the doc was last touched, which the doc never names. Layout change is the trigger, not a commit count |
| `architecture-links-code` (info) | Links to source files or line anchors (`#L123`), which go stale; name the symbol instead |

### N7. Scorer and survey

- **`repo-doctor.py` `entry_docs`.** Warn when nesting is recommended and absent, and
  check each nested doc's budget. `docs_health` gives an info finding when ARCHITECTURE.md
  is warranted and missing. Keep weights unchanged; record any score change in
  `references/scoring-rubric.md`.
- **Survey.** Add `architecture_md`, keep `nested_agents_md`, and add a `flat-monorepo`
  status: workspaces declared (`pnpm-workspace.yaml` in the tree, or a `workspaces` field,
  which costs one more GET for `package.json`), no nested docs, and the root over its
  target. It stays GET-only. Adding fixture repos changes the roll-up assertions in
  `tests/agents-md.sh`; update them deliberately.

### N8. Docs

| Doc | Change |
|---|---|
| `references/agents-md-protocol.md` | Section 2: narrow the architecture row to "derivable overviews: nowhere; codemap and invariants: ARCHITECTURE.md". Section 3: add an ARCHITECTURE.md row to the split table and a paragraph on load per folder. Section 6: the advisor's signals, the numbers, subtree staleness and routing. A new section on ARCHITECTURE.md |
| `references/monorepo-structure.md` | Sections 2, 3 and 9: link the advisor and audit; checklist items that are now mechanical say so |
| `SKILL.md` | The workflow gains "nest" and "map" steps; keep the body under the size rule (`tests/skill-size.sh`) |
| `references/scoring-rubric.md` | Every new scorer check |
| `rules/agentic-quality.md` | One clause in "Entry docs": a large repo spreads its docs as root router + nested AGENTS.md + ARCHITECTURE.md, and the tools check all three. The rule is installed globally, so keep it doctrine-level |
| `docs/PLAN.md`, `CHANGELOG.md` | Same commit as the behaviour |

## Tests

Extend `tests/fixtures.sh` with `make_monorepo`:

- a root `package.json` with workspaces `packages/*` and `apps/*`
- `packages/engine`: own manifest, a tests runner, and history with a coupled pair plus
  3 fix commits inside it
- `packages/ui`: a manifest only, so one contract signal
- `apps/web`: a manifest and a Dockerfile
- `assets/` with 300 files
- `tools/t01` to `tools/t09`, same-shaped farm members
- a root AGENTS.md whose Landmines name an engine-only path

Each test is named for the bug it prevents, and is seen failing first: against the
unfixed code, or a mutant where the code already passes.

| Test | Prevents |
|---|---|
| recommends_nesting_for_package_with_own_contract | engine not suggested |
| never_recommends_nesting_for_size_alone | `assets/` suggested because it is big |
| one_contract_signal_is_not_enough | `packages/ui` suggested |
| tool_farm_gets_one_protocol_doc | nine stamped nested docs |
| nested_scaffold_holds_only_deltas | root lines copied into the nested draft |
| nested_commands_use_workspace_form | `cd packages/engine && ...` when `npm -w` exists |
| nested_doc_over_budget_warns, unlinked_nested_doc_warns | silent oversize or orphan |
| nested_staleness_counts_only_its_subtree | root churn marking a quiet package stale |
| nested_dead_command_checked_against_own_manifest | a valid package script flagged dead against the root |
| candidate_inside_nested_dir_is_owned_by_nested_doc | engine questions reported against the root |
| root_landmine_about_one_package_is_flagged_not_moved | the patch moving a landmine |
| load_counts_imports_and_unconditional_rules | the import blind spot |
| import_in_code_span_is_not_counted | backticked `@x` treated as an import |
| architecture_silent_for_small_repo | nagging every repo |
| architecture_draft_names_entry_points_without_links | links to code that rot |
| architecture_stale_when_top_level_dir_added | a codemap missing a new package |
| structure_overflow_moves_to_architecture | overflow sent to `docs/agents/` when a map exists |
| survey_flags_flat_monorepo | the rollout missing nesting candidates |

The standalone-copy test must still pass with the new templates in
`assets/agents-md/`. Dogfood on this repo and record what the advisor recommends: it is
a plugin repo with `skills/` and 100+ siblings, so expect a farm verdict, not 100
recommendations.

## Landmines for the builder

- **Both scripts are deliberately one file.** Don't split them; update the section maps
  and keep the standalone-copy tests in `tests/agents-md.sh` and `tests/repo-scan.sh`
  green.
- **Patches must be built from `read_raw()`.** `Path.read_text()` turns CRLF into LF,
  and the patch then never applies to a CRLF file.
- **The scan never runs repo tooling**, including per-folder manifests: read them,
  never execute them (protocol section 9).
- **The survey is GET-only.** The test asserts no write flags reach `gh`.
- **The Bash tool's heredocs collapse backslash escapes.** Write Python that edits files
  through the Write tool, not a heredoc, then byte-check for stray CR or LF.
- **`git branch -d` from a worktree on an old base** refuses a branch merged into main.
  Use a compare-and-swap `git update-ref -d` after checking ancestry to main.
- **A merge on main is provisional until MAIN's gate passes.** Run one gate at a time.
- **This repo is public.** Fixtures and docs name no client, person or private path
  (`tests/agnostic.sh`).

## Out of scope: sibling lanes

- **Lane A (small, do first).** Fix `--diff` for a CLAUDE.md that copies AGENTS.md.
  Today it prepends `@AGENTS.md` and keeps the copy, so the content loads twice;
  `/import` produces exactly this file. Replace it with the import plus the lines that
  differ. Also: a one-line-per-decision `docs/agents/ruled-out.md` that the audit honours
  and that expires when the evidence grows (a guard comment already answers the
  outlier questions), and trigger-bearing pointer text in split moves.
- **Lane C (before the team rollout).** An owner interview for `TODO(owner)` questions:
  one question at a time, each with a recommended answer the owner can accept in a word,
  written back into the draft.

## Done when

- [ ] `repo-scan.py --json` carries `nesting` (and `architecture.warranted`), every
      signal sourced, matching the monorepo fixture
- [ ] `scaffold --dir` and `scaffold --architecture` draft from facts, honour the
      budgets and refuse to overwrite
- [ ] `audit` reports `data.docs[]`, `data.load[]` and every finding above; `--diff`
      adds the pointers and never moves Landmines
- [ ] The scorer and survey changes are in, with rubric rows
- [ ] check-memory-docs carries the new facts; `--offline` is green; `--live` is
      verified once by hand
- [ ] All protocol, reference, SKILL.md, rule, PLAN.md and CHANGELOG updates landed in
      the same lane
- [ ] Every new test was seen failing first; `just check` is green
- [ ] The dogfood result on this repo is written into Status below

## Sources

- Claude Code memory docs: https://code.claude.com/docs/en/memory (fetched 2026-10-07)
- matklad, "ARCHITECTURE.md": https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html
- mattpocock/skills (reviewed 2026-10-07): it ships CLAUDE.md as a full copy of
  AGENTS.md, scaffolds dependency-cruiser boundaries and proves the rules fail on a
  violation (`setup-ts-deep-modules`), and treats AGENTS.md lines as context pointers
  whose wording decides when they fire (`writing-for-agents`)
- `docs/plans/AGENTS-MD-2026-10.md`: the toolchain this extends, and the survey

## Status

Spec only, written 2026-10-07. No code yet. The build starts on this lane.
