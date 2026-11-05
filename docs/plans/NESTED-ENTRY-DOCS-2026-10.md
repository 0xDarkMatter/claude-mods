# Nested entry docs and ARCHITECTURE.md (2026-10)

Build spec for `lane/nested-entry-docs` (Lane B), plus the design notes for its two
sibling lanes (A and C, at the end). Lane B teaches repo-doctor to spread a large repo's
agent docs across several files:

- a nested `AGENTS.md` where a folder has its own contract
- an `ARCHITECTURE.md` where the repo has outgrown a short structure map
- a per-tool view of what a session actually loads

It follows `AGENTS-MD-2026-10.md`, whose tools this extends. Field research behind the
design is condensed in "Field research" near the end.

## Why

- **The protocol states the nesting rules; no tool enforces them.** Section 6 of
  `references/agents-md-protocol.md` says nest only for an own-contract folder, keep a
  nested file near 60 lines, link it from the root and never restate root rules. Today
  the tools only warn when a CLAUDE.md shadows a nested AGENTS.md, create one as a side
  effect of a split, and count them in the survey. Nothing says where a repo *should*
  nest, and nothing audits a nested file.
- **Size problems in the field are nesting problems.** In the 2026-10 survey of one
  organisation's 64 repos, 6 of the 14 AGENTS.md files ran 225 to 595 lines. Most of
  that is per-package detail that belongs in the package. `audit --diff` cannot move it,
  because it only moves whole sections.
- **One file's size is the wrong measure, and tools load differently.** A session loads
  the root doc, nested docs, their `@` imports and always-on rules. What "nested" means
  also differs by tool: Claude Code and Amp load a subfolder's file when a file there is
  read, Codex loads root-to-launch-folder under a 32 KiB cap, Kiro always includes every
  AGENTS.md, and Jules reads only the root.
- **Large repos need a map that isn't the entry doc.** A codemap and the invariants
  between layers are too long for AGENTS.md and too stable to rewrite each week:
  matklad's ARCHITECTURE.md. The protocol's section 2 currently sends every architecture
  overview "nowhere", which is right for derivable tours and wrong for this.

## Decision: extend repo-doctor, in the same files

Everything lands in `skills/repo-doctor/`:

- facts in `repo-scan.py`
- rendering, auditing and the per-tool load view in `agents-md.py`
- the score in `repo-doctor.py`

Both big scripts carry a "deliberately one file" guard comment, because the skill is
copied as a folder and must run alone. Keep the guard, and update each section map.

`agents-md.py` will likely pass 1,800 lines. The scorer treats a large file with a guard
comment and a section map as justified, with an info finding asking you to verify its
gate. The standalone-copy tests in `tests/agents-md.sh` and `tests/repo-scan.sh` are that
gate.

Facts about other tools change fast, so they ship as data: `assets/agents-md/tool-profiles.json`,
with each fact's source URL and verified date. A `--live` check guards them
(SKILL-RESOURCE-PROTOCOL section 7), the same split `check-memory-docs.py` uses.

| Rejected | Why not |
|---|---|
| A new `architecture-ops` skill | It would be a second judge of the same doc set. ARCHITECTURE.md is a split destination and a pointer target of AGENTS.md, so they share the facts, the patch builder and the audit |
| A separate `nest.py` | The advisor needs repo-scan's areas, workspaces and candidates, and the audit needs the advisor. A third script means a third copy of the facts plumbing |
| Generating ARCHITECTURE.md for every repo | A generated tour is the derivable overview the protocol rejects. Generated wikis are documented to go stale, state confident errors and overwrite human corrections. Only the owner knows the invariants |
| An LLM-scored rubric | Model scoring drifts between runs. Factory reported about 7% before anchoring each run to the previous report. Rubrics that reward "comprehensive" fight the size budget. repo-doctor stays the deterministic counterpart to `/doctor prompt-audit` |

## Claude Code facts this relies on

Verified 2026-10-07 against https://code.claude.com/docs/en/memory. Add each to
`check-memory-docs.py`: the offline phrase goes in the protocol, the live phrase is copied
from the page after re-fetching it.

| Fact | Section |
|---|---|
| CLAUDE.md files above the working directory load at launch; files in subdirectories load on demand | "How CLAUDE.md files load" |
| A subdirectory's AGENTS.md loads when Claude opens a file there with the Read tool, and only if that folder has none of the three CLAUDE.md files | "AGENTS.md" |
| `@path` imports load at launch, resolve relative to the importing file, recurse at most four hops, and are skipped inside code spans and fenced blocks | "Import additional files" |
| `.claude/rules/` files without `paths` frontmatter load at launch; path-scoped ones load when Claude reads, writes or edits a matching file | "Path-specific rules" |
| `/import` appends a one-time copy of AGENTS.md to the matching CLAUDE.md | "AGENTS.md" (Lane A) |

## Other tools' loading, as reported 2026-10-07

Seed for `tool-profiles.json`. Re-verify each row from its source before encoding it.

| Tool | Which files, when | Precedence | Limits |
|---|---|---|---|
| Codex | Global, then git root down to the launch folder, at most one file per folder: `AGENTS.override.md` > `AGENTS.md` > fallback names. Below the launch folder, the model is told to look for files itself | Joined root-first; later (deeper) text wins | **32 KiB combined** (`project_doc_max_bytes`); stops adding files when full, so the deepest file drops first |
| Gemini CLI | Global, workspace and ancestors up to `.git`, plus just-in-time scans when a tool touches a folder. File names from `context.fileName` | All concatenated, sent every prompt | `@` imports up to 5 deep, cycle detection, skipped in code |
| Cursor | AGENTS.md at the root and in subfolders. `.mdc` rules are always on, attached by glob, pulled in by description, or manual | More specific wins | "Keep rules under 500 lines" |
| Copilot | Repo instructions file, `applyTo`-scoped instruction files, the nearest AGENTS.md. VS Code nested AGENTS.md is experimental and lists folders rather than preloading | Nearest AGENTS.md takes precedence. VS Code: additive, don't rely on order | Code review about 1,000 lines a file |
| Amp | The launch folder and its parents up to home are always loaded; subtree files load when a file there is read. Falls back to `AGENT.md` or `CLAUDE.md` per folder | Concatenated | none documented |
| Kiro | Every AGENTS.md always included; steering files have always, fileMatch, manual or auto inclusion | Workspace over global | none documented |
| Windsurf | A root AGENTS.md is always on; a subfolder's is scoped to it by glob | n/a | 6,000 characters global, 12,000 per workspace rule file |
| Jules | The root AGENTS.md only | n/a | none documented |

Design consequences:
- **A nested doc must be correct with or without the root loaded.** It states its scope
  and carries only deltas.
- **It must never contradict the root**, because tools resolve contradictions differently.
- **The root's pointer is the only way some tools find a nested doc**: Codex below the
  launch folder, and Jules.
- **Keep nested docs tight**, because Kiro loads every one of them, always.

## What ships

### N1. Nesting advisor (`repo-scan.py`, new section `nesting`)

Candidates: declared workspace members, the code-holding children of `CONTAINER_DIRS`,
and top-level code areas. Never: generated, vendored, docs, tests, CI or asset areas, or
a folder under `MIN_NEST_FILES` (15) tracked files.

| Signal | Kind | Points | Evidence |
|---|---|---|---|
| Own manifest at the folder root (`package.json`, `composer.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`) | contract | 2 | its own commands |
| Own test suite (a test config, or a `tests/` runner, inside the folder) | contract | 2 | its own gate |
| Own deploy surface (the `DEPLOY_SURFACES` patterns anchored to the folder) | contract | 2 | its own release |
| Landmine cluster: 2 or more history candidates whose paths all sit inside it | contract | 2 | local landmines |
| Own gate (a `check-*` script, or a boundary checker scoped to it; see the N7 table) | contract | 1 | an enforced invariant |
| Dominant language differs from the repo's | contract | 1 | a different stack |
| Touched by 15% or more of the scanned commits | weak | 1 | activity |
| File count | none | 0 | reported, never scored |

Recommend when contract points reach 4, from at least 2 distinct contract signals. Two
rules come from `references/monorepo-structure.md` section 3:

- **`apps/*` consume contracts; they rarely define them.** Recommend an app only with an
  own-deploy or landmine-cluster signal.
- **A farm gets one protocol doc.** When 8 or more siblings share one shape (the same
  manifest kind and the same root file names), recommend a single `<parent>/AGENTS.md`.
  Add nested docs only for siblings with a landmine cluster.

Output: `data.nesting = {"recommend": [...], "farms": [...], "considered": N}`. Each item
is `{dir, points, signals: [{kind, detail, source}], existing: {agents_md, claude_md}}`,
and every signal cites a source like every other scan fact. Thresholds are constants with
comments. Tune them only against fixtures, and record why in the comment.

### N2. `agents-md.py scaffold --dir <folder>`

A nested draft from `assets/agents-md/nested.md`, containing:

- **a scope line**: "Applies to `<dir>/` and below; extends the root AGENTS.md", so it
  reads correctly whether or not the root is loaded
- the folder's own commands, from its own manifest
- the landmine candidates whose paths all sit inside the folder
- a link back to the root

It contains nothing the root already says.

When the repo declares workspaces, commands use the root-runnable form: `npm -w <dir> run x`,
`pnpm --filter <name> x` or `yarn workspace <name> x`, with the name sourced from the
member's manifest. Otherwise the block is headed "Run from `<dir>/`".

Budget: `NESTED_TARGET_LINES` 40, `NESTED_CEILING_LINES` 60, with characters at 80 a line
(`NESTED_CEILING_CHARS` 4,800). A nested doc is paid for in every tool that loads it, and
Kiro loads them all.

`--write` creates `<folder>/AGENTS.md` only and refuses to overwrite. It warns when a
CLAUDE.md in that folder will shadow the new file. For this, `repo-scan.py` needs manifest
facts per folder: parameterise the manifest readers on a sub-root rather than duplicating
them.

### N3. Audit every AGENTS.md in the repo

Iterate the tracked AGENTS.md files, skipping `node_modules/`, `vendor/` and `.claude/`.
Add `data.docs[]`, one record per doc, with `path`, `kind` (root, nested or
architecture), `lines`, `chars`, `commits_since` and its findings. Keep the existing root
fields for backward compatibility, because the tests read them.

| Finding | Severity | Rule |
|---|---|---|
| `nested-over-budget` | warn | over 60 lines or 4,800 characters (info over the 40-line target) |
| `nested-unlinked` | warn | the root AGENTS.md never names the folder's doc. For Codex below the launch folder, and for Jules, the pointer is the only route |
| `nested-no-scope` | info | the doc never names its own folder, so a tool that loads it alone can't tell where it applies |
| `nested-restates-root` | info | 3 or more normalised lines of 40+ characters also appear in the root. Concatenating tools pay for them twice |
| `nested-dead-command` | warn | a command checked against *that folder's* manifest (reuse `check_command` with that folder's facts) |
| `nested-stale` | warn | over 15 commits touching `<dir>/` since the doc was last touched. Count the subtree only (`git rev-list --count <since>..HEAD -- <dir>/`); repo-wide commits say nothing about a package |
| `nested-shadowed` | warn | exists today; keep it |

`--diff` adds a pointer to each unlinked nested doc in the root: a row in an existing
`## Ownership` table, else one line under the structure section. The pointer names its
trigger, as a path ("when editing `packages/engine/**`") or a task ("before changing the
wire format"), never "see X".

### N4. Route candidates to the nearest doc

A candidate's owner doc is the deepest AGENTS.md whose folder contains all of the
candidate's `paths`, else the root. `uncovered_candidates` checks each candidate against
its owner doc and reports per doc.

When a root Landmines item names only paths inside one nested doc's folder, report
`landmine-belongs-nested` (info), naming the item's line and the target doc. The patch
never moves a landmine; protocol section 3 leaves that move to the owner.

### N5. `agents-md.py explain <folder> [--tool T]`: what loads, per tool

Every tool has a "what did I load" view: `/memory`, `/context`, Gemini's `/memory show`,
Copilot's References, Codex's "summarize the current instructions". repo-doctor gives the
offline, per-tool version.

For a folder, and for each tool profile (default: Claude Code; `--tool all` runs every
profile), print three things:

- **The ordered files**, honouring that tool's rules:
  - per-folder shadowing and fallback names: a folder with a CLAUDE.md hides its
    AGENTS.md from Claude Code unless imported; Codex prefers `AGENTS.override.md`; Amp
    falls back to `CLAUDE.md`
  - imports: Claude Code recurses four hops and Gemini five, both skipping code spans
    and fences, with cycles detected
  - unconditional rules: repo-level `.claude/rules/*.md` without `paths`
- **Why each file loaded:** ancestor, nested-on-read, import, always-on rule or glob.
- **Bytes, characters and estimated tokens** (characters / 3.6), split into always-loaded
  versus loaded-on-demand.

`audit` uses the same engine and reports `data.load[]` with these findings:

| Finding | Severity | Rule |
|---|---|---|
| `load-over-budget` | warn | Claude Code chain over `LOAD_CEILING_CHARS` = 16,000 + 4,800 = 20,800 |
| `root-starves-nested` | warn | under the Codex profile, the chain to a folder passes 32 KiB, so Codex drops the deepest files first. Also flag a root that alone takes more than half that budget |
| `tool-cap` | info | a file over the cap of a tool the repo visibly targets. Detect targets from their files: `.cursor/`, `.github/copilot-instructions.md`, `GEMINI.md`, `.windsurf/`, `.kiro/`. Report each cap with its source |

User-scope files (`~/.claude`, `~/.codex`, ...) are per-machine: exclude them, and say so
in the output.

### N6. ARCHITECTURE.md

**Shape** (matklad, with rust-analyzer as the model):

- a bird's-eye view of the problem
- **entry points** as their own short section
- a **codemap** ("where does X happen?") that names important files, modules and types
  rather than linking them, because links rot and readers use symbol search
- **invariants** as labelled callouts ("Architecture Invariant: ..."), especially ones
  stated as absences
- layer and system boundaries
- cross-cutting concerns

It stays short, holds only what rarely changes, and is revisited a few times a year
rather than kept in sync. Healthy examples change rarely: rust-analyzer's doc had 6
commits in 20 months. So staleness is measured by layout drift, never by age.

| Piece | Behaviour |
|---|---|
| Recognise | `ARCHITECTURE.md` at the root. Also accept `docs/ARCHITECTURE.md` when it has a codemap section, but recommend the root |
| When it's warranted (scan: `architecture.warranted` plus reasons) | 2 or more nesting recommendations, 4 or more code areas with contract signals, 3 or more workspace members, or a root Structure section over 25 lines or 2,000 characters. Otherwise say nothing |
| `scaffold --architecture` (`assets/agents-md/architecture.md`) | The **entry points** come from facts: manifest `main`, `bin` and `exports`, `index.*`, `cmd/*` and `__main__.py`, named not linked. The **codemap** has one row per area. **Boundaries** come from workspace-to-workspace dependencies in the manifests, when present and sourced. The **bird's-eye view**, **invariants**, **cross-cutting concerns** and **"What this is not"** (Tauri's non-goals section) stay `TODO(owner)` questions; invariant questions are seeded from coupling candidates and boundary configs. The draft ends with a layout fingerprint comment (below). It refuses to overwrite |
| Budget | 200 lines / 16,000 characters, the same ceiling as the root entry doc |
| Root pointer | `--diff` adds one line to the root AGENTS.md when ARCHITECTURE.md exists but isn't linked: "Read ARCHITECTURE.md before adding a module or moving code between packages." |
| Split destination | When the root's Structure section overflows, the split moves it to the ARCHITECTURE.md codemap if that file exists or is warranted, instead of to `docs/agents/structure.md` |
| `architecture-stale-name` (warn) | A backticked path or name in the codemap or entry points that no longer resolves to a tracked file or folder. Suggest the rename when `git log --follow` finds one. More precise than any date |
| `architecture-stale-layout` (warn) | The doc's `<!-- layout: sha1(...) -->` fingerprint covers the sorted top-level folders and workspace members. The audit recomputes it and reports a mismatch with the folders added or removed. This adapts rust-analyzer's doc-pinning hash, and runs no code |
| `architecture-stale-marker` (info) | An explicit staleness marker in the doc: "outdated", "TODO: document", "FIXME". esbuild's architecture doc has said it is outdated for six years |
| `architecture-links-code` (info) | Links to source files or line anchors (`#L123`), which go stale. Name the symbol instead |

### N7. Invariant gates, scorer and survey

**Gate detection** (`repo-scan.py`, new section `gates`). Each config below proves an
enforced architecture rule:

| Tool | Static signal |
|---|---|
| import-linter | `.importlinter`; `[tool.importlinter]` in `pyproject.toml` |
| tach | `tach.toml` |
| dependency-cruiser | `.dependency-cruiser.{js,cjs,json}`; `depcruise` in scripts or CI |
| eslint-plugin-boundaries | the package in devDependencies; `boundaries/` settings in an eslint config |
| Nx | `@nx/enforce-module-boundaries` in an eslint config; `tags` in `project.json` |
| ArchUnit | `@ArchTest` / `@AnalyzeClasses` in test sources; `archunit.properties` |
| deptrac | `deptrac.php` / `deptrac.yaml` |
| Go | `internal/` folders (the compiler enforces them); `depguard` in `.golangci.*` |
| invariant tests | `scripts/check-*`, or tests that read the repo tree |

Re-verify the file names before encoding them. A gate that keeps a list of tolerated
violations (an ArchUnit freeze store, deptrac skipped violations, a baseline file) is
**partially enforced**: report it with that list's size.

**Prose invariants with no gate** (info, `invariant-ungated`): a line in an
ARCHITECTURE.md invariant callout, or a Landmines/Conventions line shaped "X never
imports Y" / "only X touches Y", when no detected gate covers the paths it names. This
makes the monorepo reference's "every invariant has a gate" checkable.

**Scorer (`repo-doctor.py`):**
- `enforcement` credits the detected gates. Scripts still count, but a gate that `check`
  never runs counts half; fold it into the check entry point.
- `entry_docs` warns when nesting is recommended and absent, and checks each nested
  doc's budget.
- `docs_health` gives an info finding when ARCHITECTURE.md is warranted and missing.
- Keep the weights; record every change in `references/scoring-rubric.md`.

**Survey:**
- Add `architecture_md`, keep `nested_agents_md`, and add a `flat-monorepo` status:
  workspaces declared, no nested docs, root over its target. Workspaces are detected
  from `pnpm-workspace.yaml` in the tree, or a `workspaces` field, which costs one more
  GET for `package.json`.
- The roll-up reports the **share of repos passing the bar** and the five weakest active
  repos, not averages (Factory's "% of repos at Level 3+").
- Monorepos report nested coverage as a fraction, e.g. "3/4 packages".
- It stays GET-only. Adding fixture repos changes the roll-up assertions in
  `tests/agents-md.sh`, so update them deliberately.

### N8. Audit hygiene learned from the existing linters

- **Generated instruction files.** Detect ruler (`.ruler/`), rulesync (`.rulesync/`) and
  a `<!-- Source: ... -->` header. The audit reports on the source and the patch edits the
  source, never the generated output (`generated-entry-doc`, info).
- **Dead paths suggest their rename.** When a backticked path in any entry doc is gone,
  look for it with `git log --follow --name-status`, and put the new path in the
  annotation the patch adds.
- **`audit --explain <finding-id>`** prints the rule, its source (a protocol section or a
  doc URL) and the evidence for one finding. Finding IDs are stable already; this makes
  them explainable.

### N9. Docs

| Doc | Change |
|---|---|
| `references/agents-md-protocol.md` | Section 2: narrow the architecture row to "derivable overviews: nowhere; codemap and invariants: ARCHITECTURE.md". Section 3: an ARCHITECTURE.md row in the split table, and a paragraph on per-tool load and `explain`. Section 6: the advisor's signals, the 40/60-line budget, the scope line, subtree staleness, routing, and "correct with or without the root". A new section on ARCHITECTURE.md |
| `references/monorepo-structure.md` | Sections 2, 3 and 9: link the advisor, the audit and gate detection; the checklist items that are now mechanical say so |
| `SKILL.md` | The workflow gains "nest", "map" and "explain" steps; keep the body under the size rule (`tests/skill-size.sh`) |
| `references/scoring-rubric.md` | Every new scorer check |
| `rules/agentic-quality.md` | One clause in "Entry docs": a large repo spreads its docs as root router + nested AGENTS.md + ARCHITECTURE.md, and the tools check all three. The rule is installed globally, so keep it doctrine-level |
| `docs/PLAN.md`, `CHANGELOG.md` | Same commit as the behaviour |

## Tests

Extend `tests/fixtures.sh` with `make_monorepo`:

- a root `package.json` with workspaces `packages/*` and `apps/*`
- `packages/engine`: own manifest, a tests runner, a `.dependency-cruiser.cjs`, and history
  with a coupled pair plus 3 fix commits inside it
- `packages/ui`: a manifest only, so one contract signal
- `apps/web`: a manifest and a Dockerfile
- `assets/` with 300 files
- `tools/t01` to `tools/t09`, same-shaped farm members
- a root AGENTS.md whose Landmines name an engine-only path, and an `@`-import
- a `GEMINI.md` and a `.cursor/` folder, so tool targets are detected

Each test is named for the bug it prevents and is seen failing first: against the
unfixed code, or against a mutant where the code already passes.

| Test | Prevents |
|---|---|
| recommends_nesting_for_package_with_own_contract | engine not suggested |
| never_recommends_nesting_for_size_alone | `assets/` suggested because it is big |
| one_contract_signal_is_not_enough | `packages/ui` suggested |
| tool_farm_gets_one_protocol_doc | nine stamped nested docs |
| nested_scaffold_holds_only_deltas_and_a_scope_line | root lines copied in; a doc that misreads when loaded alone |
| nested_commands_use_workspace_form | `cd packages/engine && ...` when `npm -w` exists |
| nested_doc_over_budget_warns, unlinked_nested_doc_warns | silent oversize, or an orphan no pointer reaches |
| nested_staleness_counts_only_its_subtree | root churn marking a quiet package stale |
| nested_dead_command_checked_against_own_manifest | a valid package script flagged dead against the root |
| candidate_inside_nested_dir_is_owned_by_nested_doc | engine questions reported against the root |
| root_landmine_about_one_package_is_flagged_not_moved | the patch moving a landmine |
| explain_lists_files_in_load_order_with_reasons | an unexplained total |
| explain_claude_skips_agents_md_beside_claude_md | Claude Code loading a shadowed nested AGENTS.md |
| explain_codex_prefers_override_and_one_file_per_dir | Claude Code rules applied to Codex |
| import_in_code_span_is_not_counted, import_cycle_is_reported | backticked `@x` treated as an import; an infinite loop |
| root_starves_nested_under_codex_cap | a 30 KiB root silently pushing nested docs out of Codex |
| tool_cap_only_for_targeted_tools | Windsurf caps nagging a repo that never uses Windsurf |
| gate_detection_credits_dependency_cruiser | a real boundary gate scored as absent |
| prose_invariant_without_gate_is_flagged | "engine never imports ui" with nothing enforcing it |
| architecture_silent_for_small_repo | nagging every repo |
| architecture_draft_names_entry_points_without_links | links to code that rot |
| architecture_stale_name_suggests_rename | a renamed module left in the codemap |
| architecture_stale_layout_from_fingerprint | a new package missing from the map |
| structure_overflow_moves_to_architecture | overflow sent to `docs/agents/` when a map exists |
| generated_entry_doc_patches_the_source | a patch to ruler output that the next sync overwrites |
| survey_flags_flat_monorepo, survey_reports_share_at_bar | the rollout missing nesting candidates; averages hiding the worst repos |

The standalone-copy tests must still pass with the new templates and
`tool-profiles.json` in `assets/agents-md/`. Dogfood on this repo and record what the
advisor recommends. It is a plugin repo with `skills/` and 100+ siblings, so expect a
farm verdict, not 100 recommendations.

## Landmines for the builder

- **Both scripts are deliberately one file.** Don't split them. Update the section maps,
  and keep the standalone-copy tests in `tests/agents-md.sh` and `tests/repo-scan.sh`
  green.
- **Other tools' facts are fast-moving.** Encode them only in `tool-profiles.json`, each
  with a source URL and a verified date, behind a `--live` check. Never hard-code them in
  the scripts. Anthropic's own CLAUDE.md plugin ships the wrong local-file name
  (`.claude.local.md`), which is the failure this prevents.
- **Patches must be built from `read_raw()`.** `Path.read_text()` turns CRLF into LF,
  and the patch then never applies to a CRLF file.
- **The scan never runs repo tooling**, including per-folder manifests and docs-as-tests
  harnesses: read them, never execute them (protocol section 9).
- **The survey is GET-only.** The test asserts no write flags reach `gh`.
- **The Bash tool's heredocs collapse backslash escapes.** Write Python that edits files
  through the Write tool, not a heredoc, then byte-check for stray CR or LF.
- **`git branch -d` from a worktree on an old base** refuses a branch that is merged into
  main. Use a compare-and-swap `git update-ref -d` after checking ancestry to main.
- **A merge on main is provisional until MAIN's gate passes.** Run one gate at a time.
- **This repo is public.** Fixtures and docs name no client, person or private path
  (`tests/agnostic.sh`).

## Sibling lanes

### Lane A (small, do first): copy fix, ruled-out record, pointer wording

1. **A CLAUDE.md that copies AGENTS.md.** Today `--diff` prepends `@AGENTS.md` and keeps
   the copy, so the content loads twice (confirmed on a scratch repo, 2026-10-07).
   `/import` produces exactly this file. When CLAUDE.md mostly repeats AGENTS.md, replace
   it with the import plus only the lines that differ.
2. **`docs/agents/ruled-out.md`, one line per decision**, e.g.
   `` - `skills/hono-ops/**` coupling, 4 commits: one skill built in one go ``.
   - **Its fields:** the finding kind and paths, the evidence count when ruled out, and a
     required reason. Who and when come from git blame, so they are never stored.
   - **The audit honours a line** only while current evidence is at or below the recorded
     count. Past it, the question comes back (the ESLint bulk-suppression and PHPStan
     baseline model). An optional `until YYYY-MM-DD` is a backstop (Trivy, Snyk, Cortex).
   - **A line that matches no current finding is itself a finding** (`ruled-out-stale`),
     so the file can't rot.
   - **A ruled-out check leaves the score; it is not counted as passed.** The grade shows
     "N ruled out" (Cortex point scorecards; Scorecard's inconclusive checks).
   - **A guard comment already answers the outlier questions.** Don't duplicate them here.
   - **Proposed versus accepted** (SARIF's underReview): an agent may append a line marked
     `(proposed)`. Only an unmarked line, which a human committed, changes the score. This
     fits the rule that child sessions don't authorise things.
3. **Pointers that name their trigger.** The split's "read it when this topic matters"
   becomes a path or task trigger derived from the moved section (N3's pointer rule).
   The audit flags bare "see X" pointers (info).

### Lane C (before the team rollout): owner interview

`agents-md.py scaffold --json` already lists the questions. The interview is the agent
workflow that resolves them, documented in SKILL.md and driven with the harness's
question tool:

- **Ask only what the evidence can't answer.** Split the questions into guided ones
  (resolvable from facts, answered with a citation) and assisted ones (they need the
  owner). Only the assisted ones reach the owner (AgentLint's split).
- **One question at a time**, each showing its evidence and a recommended answer the
  owner can accept in a word (the setup flow in mattpocock/skills; Claude's new `/init`
  also shows its findings before asking).
- **Each answer goes to the cheapest place it will last.** Prefer a test or assertion
  that enforces it, then a comment at the code site, and a doc line only last. Offer only
  the first that applies (a community AGENTS.md skill's "prevent recurrence" ladder,
  which is also `rules/agentic-quality.md`). A "not a rule" answer becomes a Lane A
  ruled-out line.
- **Preview before writing:** a per-file diff with a one-line "why"
  (`/revise-claude-md`). Nothing is written without approval.

## Later (not in these lanes)

- **SARIF output** for audit and scorer, for CI annotations. Map ruled-out lines to
  `suppressions[]`, remediation to `help.markdown`, and use `partialFingerprints`.
- **Mark commands covered by docs-as-tests.** A command covered by a docs-as-tests
  harness (trycmd, rustdoc doctests, cram, Doc Detective, `embedme --verify` in CI) gets
  `[tested-by: X]` instead of `[untested]`.
- **A ranked codemap.** Rank candidates by references (aider's repo map: a graph over
  definitions and references within a token budget). It needs a parser beyond the
  stdlib, so it waits until a real repo shows the codemap is too thin without it.

## Field research (2026-10-07)

Read-only research across several dozen primary sources, in four tracks, with no code
copied. Several pages
held text aimed at AI readers (including a search result titled "INSTRUCTIONS FOR
LLMs"). All of it was ignored.

| Area | Sources | What it changed |
|---|---|---|
| How agent tools load instructions | agents.md; Codex agents-md docs and base prompt; Gemini CLI GEMINI.md and memport docs; Cursor rules; GitHub Copilot repository instructions and VS Code custom instructions; Kiro steering; Windsurf (Devin docs); Amp AGENTS.md docs; OpenHands skills; Cline rules; Jules | N2 scope line and 40-line target; N3 `nested-no-scope` and pointer rules; N5 per-tool `explain`, `root-starves-nested`, `tool-cap`; `tool-profiles.json` |
| Tools that write or lint these files | Claude Code `/init` and `/doctor prompt-audit`; anthropics/claude-plugins-official `claude-md-management`; Codex `/init`; ruler; rulesync; ctxlint; AgentLint; agnix; Factory agent readiness; community AGENTS.md skills on skills.sh | N8 generated-source detection, rename suggestions and `--explain`; Lane C's guided/assisted split, answer ladder and diff preview; the rejected LLM rubric |
| Scorers and waivers | OpenSSF Scorecard; todogroup repolinter (archived 2026-02); Backstage Tech Insights; Spotify Soundcheck; Cortex; OpsLevel; ESLint inline and bulk suppressions; PHPStan baseline; Semgrep; CodeQL and SARIF 2.1.0 suppressions; GitHub code-scanning dismissals; Trivy; Snyk; Hadolint; gitleaks | Lane A's evidence-pinned ruled-out record, stale-entry finding, score exclusion, proposed-vs-accepted; N7 survey share-at-bar |
| Architecture docs and gates | matklad "ARCHITECTURE.md"; rust-analyzer, esbuild, Helix and Tauri architecture docs; aider repo map; DeepWiki docs and community reports; import-linter; tach; dependency-cruiser; eslint-plugin-boundaries; Nx module boundaries; ArchUnit; deptrac; Go `internal/` and depguard; rust-analyzer's tidy test; rustdoc; trycmd; cram; Doc Detective; embedme; C4; arc42; Nygard's ADR post | N6 shape, name and fingerprint staleness, markers; N7 gate detection, partial enforcement, ungated invariants; "Later" items |

Primary URLs for the facts that get encoded:

- Claude Code memory docs: https://code.claude.com/docs/en/memory
- Codex AGENTS.md: https://learn.chatgpt.com/docs/agent-configuration/agents-md
- Gemini CLI: https://geminicli.com/docs/cli/gemini-md
- Cursor rules: https://cursor.com/docs/context/rules
- VS Code custom instructions: https://code.visualstudio.com/docs/copilot/customization/custom-instructions
- Kiro steering: https://kiro.dev/docs/steering/
- Windsurf: https://docs.devin.ai/desktop/cascade/memories
- Amp: https://ampcode.com/docs/customize/agents-md
- matklad: https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html
- aider repo map: https://aider.chat/docs/repomap.html
- mattpocock/skills, reviewed the same day: CLAUDE.md shipped as a full copy of
  AGENTS.md; dependency-cruiser boundaries proved to fail on a violation; AGENTS.md lines
  treated as context pointers

## Done when

- [x] `repo-scan.py --json` carries `nesting`, `gates` and `architecture.warranted`, every
      signal sourced, matching the monorepo fixture
- [x] `scaffold --dir` and `scaffold --architecture` draft from facts, honour the budgets
      and refuse to overwrite
- [x] `explain <folder>` prints the ordered files, reasons and sizes for each profile in
      `tool-profiles.json`, and every profile fact carries a source and date
- [x] `audit` reports `data.docs[]`, `data.load[]` and every finding above; `--diff` adds
      the pointers and never moves Landmines
- [x] The scorer and survey changes are in, with rubric rows
- [x] check-memory-docs carries the new Claude Code facts, and the tool-profiles check has
      `--offline` and `--live`; offline is green and live was verified once by hand
- [x] All protocol, reference, SKILL.md, rule, PLAN.md and CHANGELOG updates land in the
      same lane
- [ ] Every new test was seen failing first, and `just check` is green (the first half
      holds; `just check` is MAIN's to confirm at landing)
- [x] The dogfood result on this repo is written into Status below

## Status

Shipped on `lane/nested-entry-docs`, 2026-10-07: Lanes A and B in full, and Lane C's
tooling (`scaffold --json` guided/assisted split, `references/owner-interview.md`). One
fleetflow run built the scan and the tool profiles; the rest was built in the
orchestrating session as one writer, because it all lives in `agents-md.py`. The run's
frozen contracts, with the additive fields as built, are in
`docs/plans/REPO-DOCTOR-ABC-2026-10.md`. Still open: running the interview on a real
repo, and the "Later" items.

**Adversarial review (2026-10-07).** An Opus refute of the integrated lane found 25
problems the green suites missed. Among them:
- a crash on a sparse checkout
- `--diff` moving a `### Gotchas` block that sits under a movable section
- a generated CLAUDE.md still patched
- dotted paths mangled by `lstrip("./")`
- workspace globs crossing folders
- one check script silencing every `invariant-ungated`
- a user-scope Windsurf cap applied to repo files
- four tests that could not fail against their named bug

All the high and medium findings, and most low ones, are fixed with tests seen failing
first. The rest:
- Gemini's import depth and code skipping stay as researched, though unverified on its
  page.
- `check-tool-profiles.py`'s partial-unreachable exit and `tool-cap` for always-assumed
  tools are documented departures (REPO-DOCTOR-ABC section 1.3).

**Dogfood on this repo.** The nesting advisor considers 1 folder and recommends none. It
reports one farm, `skills/` (101 members, one doc at the parent; `skills/fleet-ops/` has
its own landmine cluster). There are 19 gates, all check scripts, all wired. ARCHITECTURE.md
is not warranted. The audit lists 11 uncovered landmine candidates and no shadowing, and
`explain . --tool all` loads only the root AGENTS.md for every tool. That is the expected
verdict for a plugin repo of 100+ same-shaped skills.
