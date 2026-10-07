# AGENTS.md Protocol: create, audit, upgrade

The entry doc is the highest-leverage file in a repo for agentic work. Every session
reads it, so every line is either recurring value or recurring token cost. This
reference is the single statement of what an `AGENTS.md` holds, how big it may get, how
it interacts with `CLAUDE.md`, and how staleness is measured. The tools in
`scripts/` (`repo-scan.py`, `agents-md.py`) implement it, and the doctrine it serves is
`rules/agentic-quality.md` ("Entry docs - AGENTS.md is the front door").

## Contents

1. What it must contain
2. What it must not contain
3. Size, and how to split
4. CLAUDE.md interplay (shadowing)
5. Staleness: commits, not days
6. Nested entry docs
7. Where this tooling fits beside Claude Code's own checks
8. Workflows: create, audit/upgrade, survey
9. Why the generator never runs repo commands
10. ARCHITECTURE.md
11. What each tool loads
12. Sources

Claude Code facts below were verified against the official docs on 2026-10-05, and the
loading facts in sections 3, 4 and 6 on 2026-10-07 (Sources, end of file).
`scripts/check-memory-docs.py --live` re-checks them on a schedule. Other tools' loading
rules live only in `assets/agents-md/tool-profiles.json`, each with a source and a date,
re-checked by `scripts/check-tool-profiles.py --live`.

---

## 1. What it must contain

In this order, because agents need the early sections most often:

| # | Section | Required | What goes in it |
|---|---|---|---|
| 1 | What this repo is | yes | 2-4 lines: what it is, what it produces, who consumes it. Orientation, not marketing |
| 2 | Commands | yes | Exact run / test / build / `check` commands, taken from real scripts and config, each run once by a human or agent before it is trusted. A wrong command costs more than a missing one, because agents trust it over exploration |
| 3 | Landmines | **mandatory** | What breaks non-obviously: coupled files, generated output that must not be hand-edited, ordering-sensitive registries, environment quirks. Admission test: *would a competent agent plausibly trip this?* Each entry says what breaks, why, and the procedure |
| 4 | Deploy notes | when the repo deploys | How it ships, which branch deploys, what the deploy hooks run. A merge into an auto-deploying branch *is* a deploy (`rules/deploy-gating.md`) |
| 5 | Structure map | yes, short | Only what a folder name doesn't tell you: ownership, generated versus hand-written, where a feature really lives. Claude Code's `/doctor` trims directory layouts it can derive, so a full tree is waste |
| 6 | Conventions | yes, short | Repo-specific deltas only: invariants ("money is integer cents"), the formatter and linter the repo enforces. Global rules stay global |
| 7 | Pointers | optional | Docs index, ADR directory, and every nested `AGENTS.md` (an ownership table in a monorepo) |

The auditor recognises a section by heading words: Commands (`commands`, `scripts`,
`build`, `test`, `quick start`...), Landmines (`landmines`, `gotchas`, `pitfalls`,
`footguns`, `caveats`...), Deploy (`deploy`, `release`, `hosting`, `CI/CD`...), Structure
(`structure`, `layout`, `directories`...), Conventions (`conventions`, `style`,
`standards`...). The overview is the prose under the title. Section names are free;
the heading has to say what it holds.

### Landmine candidates and the ruled-out record

The scan's landmine candidates (questions mined from git history) are asked of the doc
that owns their files: the deepest AGENTS.md whose folder holds every path, else the root.
An owner who decides a candidate is not a landmine records it in
`docs/agents/ruled-out.md`, one line per decision:

```
- [fragile] `src/legacy/parser.js` @3: replaced next quarter until 2027-03-31
```

- **Kind and paths** match the candidate (globs allowed). `@3` is the evidence when it was
  ruled out: shared commits for coupling, fix plus revert commits for fragile, commits for
  a hot spot, lines for an outlier.
- **The audit honours the line only while the evidence stays at or below that count.**
  Past it, the question comes back (the ESLint bulk-suppression and PHPStan baseline
  model). `until YYYY-MM-DD` is an optional backstop. Who and when come from git blame,
  so the line never stores them.
- **A line marked `(proposed)` is an agent's suggestion**: reported, never honoured,
  until an owner removes the marker. Child sessions don't authorise things.
- **A line that matches no current candidate is a finding** (`ruled-out-stale`), so the
  file can't rot. Honoured lines leave the audit's counts and show on its header ("N
  ruled out"); the scorer is not affected.

## 2. What it must not contain

| Content | Where it goes instead |
|---|---|
| Setup prose for humans: install walkthroughs, prerequisites, onboarding | `README.md` or `CONTRIBUTING.md` (README and AGENTS.md link each other) |
| Anything Claude can derive from the code: full directory trees, dependency lists, derivable overviews | Nowhere. The code is the source |
| A codemap and the invariants between layers | `ARCHITECTURE.md`, once the scan finds it warranted (section 10) |
| Rationale essays | ADRs (`adr-ops`) |
| Unverified commands | Run it first, or leave it out |
| Secrets, real hostnames, credentials | Never: the file is committed and read by every tool |
| Rules already in global instruction files | Nowhere. Restating them is how two copies start to disagree |
| Claude-only behaviour (plan mode for a path, a hook) | A `CLAUDE.md` that imports `@AGENTS.md` (section 4) |

## 3. Size, and how to split

**Target 150 lines; 200 is the ceiling.** Claude Code's memory docs target "under 200
lines per CLAUDE.md file. Longer files consume more context and reduce adherence", and
Claude Code warns at startup and in `/status` when an instruction file runs over the
recommended length. The house target is lower because an AGENTS.md is read by every
tool, every session. In the 2026-10 survey, 6 of 14 existing files ran past 200 lines.

**Size counts too: target 12,000 characters, ceiling 16,000 characters** (150 and 200
lines at 80 characters). The line budget assumes wrapped prose, and a file with long
lines reaches the same context cost in fewer lines: claude-mods' own AGENTS.md once sat
at 199 lines and 16,744 characters, one line alone 2,313. The audit and the scorer check
both measures, and the audit lists lines over 500 characters. Characters / 3.6 is the
rough token count.

**`@path` imports do not shrink anything.** Imported files load at launch with the file
that imports them, so splitting with imports reorganises but costs the same context.
Imports resolve relative to the importing file, recurse at most four hops, and are
skipped inside code spans and fences. Split into things that load *on demand*:

| Content | Destination | When it loads |
|---|---|---|
| Detail for one subsystem | Nested `<dir>/AGENTS.md` | When Claude reads a file in `<dir>/`, if `<dir>/` has no `CLAUDE.md` of its own. It reloads after compaction only once a file there is read again |
| Rules for a file type or path | `.claude/rules/<topic>.md` with `paths:` frontmatter | When matching files are in play (rules without paths frontmatter load at launch). Claude Code only: other agents never see these, so cross-tool invariants stay in AGENTS.md |
| A structure map that overflows | The `ARCHITECTURE.md` codemap, when that file exists or is warranted (section 10) | When an agent follows the pointer |
| Walkthroughs, long reference tables | `docs/...`, linked from AGENTS.md | When an agent follows the link |
| Human setup | README / CONTRIBUTING | When a human reads it |

**What never moves:** the overview, Commands and Landmines. A subsystem's landmines may
move into that subsystem's nested AGENTS.md, but the owner makes that move, never the
tool. Once a file is over either ceiling, `agents-md.py audit --diff` proposes moves
until it is back under both targets, in this order: human setup prose first (it doesn't
belong at any size), then the other movable sections largest first, then Structure and
Conventions (required and short, so they go last). It reports when that is not enough.

**A moved section leaves a pointer that names its trigger**: a path ("before editing
`src/engine/**`") when the section names folders, else a task from its title. A pointer
that never says when to read its target is reported (`bare-pointer`); "see X" gets
skipped. What a split saves depends on the tool, so check it with
`agents-md.py explain` (section 11).

## 4. CLAUDE.md interplay (shadowing)

Claude Code v2.1.277 and later read `AGENTS.md` directly, **but only as a fallback**.
With the default **Project instructions** value (`claude-md-or-agents-md`):

| The working directory or a directory above it has | Claude Code reads |
|---|---|
| `AGENTS.md`, and no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` | `AGENTS.md` (and `.claude/AGENTS.md`) |
| `AGENTS.md` plus any of those three | **The CLAUDE.md files only** |
| A `CLAUDE.md` that imports `@AGENTS.md` | The CLAUDE.md, with AGENTS.md included through the import |

`~/.claude/CLAUDE.md`, an organisation's managed CLAUDE.md and `.claude/rules/` files
don't count, and keep loading alongside AGENTS.md.

### Shadowing landmines

- **A personal `CLAUDE.local.md` silently stops AGENTS.md loading for that developer.**
  It is uncommitted, so nobody else sees the cause. The documented fix is the user-level
  setting below; a repo can't fix it.
- **A CLAUDE.md that points to AGENTS.md in prose loads nothing.** "See AGENTS.md" is a
  sentence, not an import: Claude sees AGENTS.md only if it decides to open it. Use the
  `@AGENTS.md` import.
- **`/init` writes a `CLAUDE.md`**, which then shadows an existing AGENTS.md. After
  `/init`, put `@AGENTS.md` on its first line or delete it.
- **/import appends a one-time copy of AGENTS.md into CLAUDE.md.** The copy then drifts,
  and with an import on top the text loads twice. The audit flags a CLAUDE.md that mostly
  repeats AGENTS.md (`shadowed-copy`, `claude-imports-duplicate`), and `--diff` replaces it
  with the import plus only the lines that differ.
- **A committed symlink `CLAUDE.md -> AGENTS.md` breaks on Windows.** Without
  `core.symlinks`, git checks it out as a one-line text file reading `AGENTS.md`, which
  then shadows the real file. The docs say to use the `@AGENTS.md` import if anyone
  clones on Windows.
- **A `CLAUDE.md` in a parent directory** (say, a folder that holds many checkouts)
  shadows the AGENTS.md of every repo below it.
- **Nested docs shadow too:** a subdirectory's AGENTS.md is skipped where that
  subdirectory has a CLAUDE.md, `.claude/CLAUDE.md` or `CLAUDE.local.md` of its own.

### The setting, and why a repo can't use it

`/config` -> **Project instructions** takes four values: `claude-md-or-agents-md` (the
default above), `claude-md-and-agents-md` (both; in each directory the CLAUDE.md files
first, then AGENTS.md, and an AGENTS.md already imported or symlinked isn't read twice),
`claude-md`, and `managed-only`. In a settings file it lives at
`pluginConfigs["agents-md@builtin"].options.instructionFiles`, and Claude Code **ignores
it in project and local settings**: only user settings, a `--settings` file or managed
settings can set it. So a repo has exactly two portable shapes:

1. **No CLAUDE.md at all.** AGENTS.md loads by fallback. The default for a repo with no
   Claude-specific content.
2. **A CLAUDE.md whose first line is `@AGENTS.md`**, with Claude-only deltas below it.
   This works on every version, including the sessions below that can't read AGENTS.md.
   From `.claude/CLAUDE.md` the import is `@../AGENTS.md`, because imports resolve
   relative to the importing file.

An organisation can also set the value in managed settings.

### When AGENTS.md support is unavailable

Claude Code reads CLAUDE.md only before v2.1.277, when the built-in `agents-md` plugin is
disabled, and in some cases in the first session after upgrading from v2.1.276 or
earlier. Before v2.1.281, some sessions (Amazon Bedrock, telemetry disabled) read
CLAUDE.md only. **v2.1.281 is the effective floor** for relying on the fallback; shape 2
covers everything older.

### Other differences for an AGENTS.md read through the setting

- `InstructionsLoaded` hooks don't fire for it. They do fire when a CLAUDE.md imports it
  or symlinks to it.
- Directories added with `--add-dir` (with
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` set) load their CLAUDE.md, never their
  AGENTS.md.
- An `@path` import of a file outside the working directory loads only if external
  imports were already approved for the project, with no prompt.
- `AGENTS.local.md`, `AGENTS.override.md` and anything under `.agents/` are never read.

### Order, not precedence

Files are concatenated, not overridden: root to working directory, `CLAUDE.local.md`
after `CLAUDE.md` at each level, and with `claude-md-and-agents-md` each directory's
CLAUDE.md before its AGENTS.md. The docs describe only this load order. They state no
precedence rule, and say that with contradictory instructions "Claude may pick one
arbitrarily". The fix for a contradiction is to remove it, not to rely on order.

### When a CLAUDE.md is justified

Only for Claude-specific deltas (plan mode for a path, a hook, a Claude Code setting), for
teams on versions that can't read AGENTS.md, or for `InstructionsLoaded` hooks. Then it
uses shape 2, holds deltas only (never a restatement), and both files stay under budget.

**Check what loaded:** a session start line such as `no CLAUDE.md found; AGENTS.md
loaded: <path>`; `/memory` lists the AGENTS.md path (v2.1.280 and later); `/context`
lists CLAUDE.md files under **Memory files**.

## 5. Staleness: commits, not days

Measure staleness in **commits since the file was last touched**, never wall-clock time.
A week-old mtime can hide 100+ commits of drift, and an unrelated edit resets mtime
without fixing anything.

- Healthy: touched within 15 commits (the scorer's and the auditor's threshold).
- Sharper signal: commits since the touch that changed `package.json`, `composer.json`,
  a Makefile or a justfile. Commands drift with those.
- By hand: `git rev-list --count HEAD ^$(git rev-list -1 HEAD -- AGENTS.md)`.
- Remotely (the survey): the last commit touching the path, then the compare API's
  `ahead_by` against the default branch. No clone.
- Discipline that keeps it healthy: the commit that invalidates a claim updates the doc
  in the same commit ("done includes the doc touch").
- Nested docs count only their own folder's commits (section 6), and ARCHITECTURE.md
  counts layout drift, never age (section 10).
- **Dead paths:** a backticked path git once tracked and the tree no longer has is
  `dead-path`, and the patch annotates it with the rename git history shows. A path git
  never knew (an example, a build output) is left alone.

## 6. Nested entry docs

**Nest only where a subsystem has its own contract:** its own invariant law
(determinism engine, tokens-only design system, single-writer data layer), its own
audience (a package other repos consume, a per-tool CLI), or its own gate. A folder
being large is not a contract; it needs one line in the root structure map.

**Loading (Claude Code, verified 2026-10-07):** subdirectory files load on demand. A
nested AGENTS.md loads only when Claude reads a file in that folder, and never where the
folder has its own CLAUDE.md (section 4). Other tools differ: Codex reads root to the
working folder, one file per folder; Kiro includes every AGENTS.md always; Jules reads
the root only (section 11). So a nested doc must be **correct with or without the root**:
its scope line makes it read right alone, and the root's pointer reaches it for tools
that read only the root.

### The advisor

`repo-scan.py` (section `nesting`) scores candidate folders: workspace members, children
of container folders, and top-level code areas, never generated, vendored, docs, tests or
asset folders, nor one under 15 tracked files.

| Signal | Points |
|---|---|
| Own manifest (`package.json`, `composer.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`) | 2 |
| Own test suite, own deploy surface, or a landmine cluster (2+ history candidates inside) | 2 each |
| Own gate, or a dominant language that differs from the repo's | 1 each |
| Touched by 15% or more of scanned commits (weak, never enough alone) | 1 |
| File count | 0, reported only |

It recommends a folder at 4 contract points from 2 or more distinct contract signals.
An app (`apps/*`) needs an own-deploy or landmine-cluster signal. A farm of 8 or more
same-shaped siblings gets one doc at its parent, plus one per sibling with a landmine
cluster. A folder that holds recommended folders is judged only on what is left once
they take theirs, so `packages/` never gets a second doc for `packages/engine/`'s
contract.

### Writing one

`agents-md.py scaffold --dir <folder>` drafts `<folder>/AGENTS.md` (`--write` creates it
once, never overwrites):

- **a scope line**: "Applies to `<dir>/` and below; extends the root AGENTS.md"
- **the folder's own commands**, in the root-runnable form when the repo declares
  workspaces (`npm -w <dir> run x`, `pnpm --filter <name> x`, `yarn workspace <name> x`),
  else under "Run from `<dir>/`"
- **the landmine candidates whose paths all sit inside it**, and a link back to the root
- **nothing the root already says**

**Budget: target 40 lines, ceiling 60 lines or 4,800 characters.** Some tools load every
nested AGENTS.md on every task.

### What the audit checks

Every tracked `<folder>/AGENTS.md` (not under `node_modules/`, `vendor/` or `.claude/`):

| Finding | Severity | Rule |
|---|---|---|
| `nested-over-budget` | warn (info past 40 lines) | over 60 lines or 4,800 characters |
| `nested-unlinked` | warn | the root never names it; `--diff` adds a row to an existing Ownership table, else a trigger line in Structure |
| `nested-no-scope` | info | it never names its own folder |
| `nested-restates-root` | info | 3 or more long lines copied from the root |
| `nested-dead-command` | warn | neither the folder's manifest nor the root's can run it |
| `nested-stale` | warn | over 15 commits to the folder itself since the doc was touched (`git rev-list --count <touch>..HEAD -- <dir>/`) |
| `nested-shadowed` | warn | the folder has its own CLAUDE.md |

A root landmine that names only paths inside one nested doc's folder gets
`landmine-belongs-nested` (info). Moving it is the owner's call; the patch never does.

## 7. Where this tooling fits beside Claude Code's own checks

| Need | Claude Code built-in | repo-doctor |
|---|---|---|
| Outdated or contradictory instructions, references to missing files or commands (semantic) | `/doctor prompt-audit` (v2.1.283+; covers AGENTS.md; LLM-run, interactive, proposes edits) | Not duplicated: run prompt-audit for the semantic pass |
| Over-length | Startup and `/status` warning | `agents-md.py audit`: lines and characters, long lines, and a concrete split diff |
| Unanswered landmines | None | Audit: scan candidates whose files the doc never names |
| Trim derivable content | `/doctor` checkup (v2.1.206+): trims checked-in **CLAUDE.md** | Section 2 here; audit flags setup prose |
| Which files loaded | `/memory`, `/context` (this session, this machine) | Audit: shadowing by CLAUDE.md, `.claude/CLAUDE.md`, CLAUDE.local.md, parent dirs, nested dirs, symlink-as-text. `explain`: what every tool profile loads for a folder. Offline and CI-able |
| Dead commands | prompt-audit (semantic) | Audit: deterministic check against package.json, composer.json, Makefile, justfile and script paths |
| Staleness | None | Commits since the touch, plus manifest commits since |
| Create from scratch | `/init` writes a CLAUDE.md, model-authored | `agents-md.py scaffold` writes an AGENTS.md from sourced facts only |
| Many repos | None | `agents-md.py survey --org` through `gh api`, no clones |

Put the deterministic audit in CI; run `/doctor prompt-audit` by hand.

## 8. Workflows

### Create

1. `python scripts/repo-scan.py --repo <path> --json > facts.json`: the deep scan. Every
   fact carries a source (`file:line` or the command), and git history yields landmine
   *candidates*: co-changing files, churn hot spots, fix and revert clusters, config
   edits followed by build or migration changes. Candidates are questions, never facts.
   Only tracked files raise them; test fixtures, a file changing with its own tests, and
   a second question about the same file are left out.
2. `python scripts/agents-md.py scaffold --repo <path> --facts facts.json`: prints a
   draft built from the archetype template (`assets/agents-md/`: PHP CMS, Node app,
   Python service, static site, and generic for anything else). Commands come only
   from declared scripts and config, tagged `untested`. Everything unverifiable is a
   `TODO(owner):` question, and the landmine candidates sit under Landmines as
   questions.
3. Optional synthesis, documented rather than scripted: for each custom-code area in
   the facts (`areas[]`, at most four), launch a read-only Explore subagent at "medium"
   breadth, give it the facts JSON, and ask for the conventions it can cite with
   `file:line`. Merge only what the owner confirms. Skip it for small repos.
4. The owner answers every `TODO(owner)`, runs each command once and drops its
   `untested` tag. Then `scaffold --write` creates `AGENTS.md`. It refuses if one
   exists.
5. `agents-md.py audit` until it exits 0.
6. **Nest and map** where the scan says so: `scaffold --dir <folder>` for each folder
   the advisor recommends (section 6), and `scaffold --architecture` once ARCHITECTURE.md
   is warranted (section 10).

The owner's questions are an interview, not a form: `scaffold --json` splits them into
guided ones the facts can answer (each with a recommended answer and its source) and
assisted ones that need the owner. The procedure is `references/owner-interview.md`.

### Audit and upgrade

`agents-md.py audit --repo <path>` reports findings (exit 10 on any warn or crit).
`--diff` prints a `git apply`-able patch: stubs for missing required sections, an
`@AGENTS.md` import for a shadowing CLAUDE.md, an annotation on each dead command, and
the split moves. Review it, then `git apply`. The patch only adds, annotates or moves.
**It never deletes or moves the Landmines section**, and moved sections leave a link
behind. The audit also lists the scan's landmine candidates whose files the owning doc
never names (`uncovered_candidates` in `--json`): answer each as a landmine, or rule it
out (section 1).

It audits every entry doc, not only the root: nested docs (section 6), ARCHITECTURE.md
(section 10), and what each tool loads (section 11). `--json` gives one `data.docs[]`
record per doc. A generated entry doc (ruler, rulesync, a `<!-- Source: ... -->` header)
is reported against its source, and the patch edits that source, never the output the
next sync overwrites. `audit --explain <finding-id>` prints a finding's rule, where it
comes from, and this repo's evidence.

### Survey an org

`agents-md.py survey --org <owner>` lists, per repo: AGENTS.md / CLAUDE.md presence,
shadowing, line count and size, commits since the last touch, section coverage, nested
coverage in a monorepo ("1/2" packages), and ARCHITECTURE.md. A monorepo with nothing
nested and a root past its target is `flat-monorepo`. The roll-up gives the share of
active repos at the bar and the five weakest, never an average, which would hide them.
Add `--json` for the envelope. It is GET-only through `gh api` (plus `gh repo list`),
clones nothing, and writes nothing anywhere.

## 9. Why the generator never runs repo commands

Even "listing" commands execute repository code: Composer loads plugins from `vendor/`
on any command, justfile backtick variables evaluate at parse time, `make -n` still
expands `$(shell ...)`, and npm runs lifecycle scripts. So the scan reads files and git
metadata only, never opens secret files (`.env`, `auth.json`, `.npmrc`; from
`.env.example` it takes variable names only), and every command stays `untested` until
someone runs it on purpose.

## 10. ARCHITECTURE.md

In matklad's shape (rust-analyzer's is the model): a bird's-eye view, the entry points, a
**codemap** that names important files, modules and types rather than linking them
(links rot; readers use symbol search), **invariants** as labelled callouts ("Architecture
Invariant: the engine never imports the UI"), often stated as absences, then boundaries
and cross-cutting concerns. It holds only what rarely changes and is revisited a few
times a year, not kept in sync, so its staleness is layout drift, never age.

**When it is warranted** (`repo-scan.py` section `architecture`): 2 or more nesting
recommendations, 4 or more code areas with contract signals, 3 or more workspace
members, or a root Structure section over 25 lines or 2,000 characters. Otherwise the
tools say nothing about it.

`agents-md.py scaffold --architecture` drafts it from facts: entry points from manifest
`main`, `bin` and `exports`, `index.*`, `cmd/*` and `__main__.py` (named, one line per
file); a codemap row per area; boundaries from workspace-to-workspace dependencies; and
invariant questions seeded from the detected gates and coupling candidates. The
bird's-eye view, cross-cutting concerns and non-goals stay owner questions. The draft
closes with a layout fingerprint, the sha1 of the sorted folders plus the folders
themselves, and `--write` refuses to overwrite. Its budget is the root entry doc's.

| Finding | Severity | Rule |
|---|---|---|
| `architecture-stale-name` | warn | a codemap or entry-point path is gone; it names the rename git history shows |
| `architecture-stale-layout` | warn | the fingerprint no longer matches; it names the folders added and removed |
| `architecture-over-budget` | warn | past 200 lines or 16,000 characters |
| `architecture-stale-marker` | info | "outdated", "TODO: document", "FIXME" |
| `architecture-links-code` | info | links to source files or `#L123` anchors |
| `architecture-unlinked` | info | the root never points to it; `--diff` adds one line |
| `invariant-ungated` | info | a prose invariant (an ARCHITECTURE.md callout, or "X never imports Y" / "only X touches Y" in Landmines or Conventions) that no detected gate covers |

`docs/ARCHITECTURE.md` is accepted when it holds a codemap; the root is recommended.

## 11. What each tool loads

`agents-md.py explain <folder> [--tool ID|all]` lists, per tool, the repo files an agent
working in that folder loads: in order, with the reason (ancestor, nested-on-read,
import, always-on rule, glob, fallback), the characters, an estimated token count, and
always-loaded versus on-demand. It is the offline, every-tool version of `/memory` and
`/context`. User-scope files (`~/.claude`, `~/.codex`) are per-machine and left out.

The audit runs the same engine over the root and every nested folder (`data.load[]`):

| Finding | Severity | Rule |
|---|---|---|
| `load-over-budget` | warn | Claude Code loads over 20,800 characters for one folder (a root at its ceiling plus one nested doc) |
| `root-starves-nested` | warn | the Codex chain to a folder passes its 32 KiB cap (Codex drops the deepest files first), or the root alone takes over half of it |
| `import-cycle` | info | two files import each other |
| `tool-cap` | info | a file over the cap of a tool the repo visibly targets (`.cursor/`, `.windsurf/`, `GEMINI.md`, `.kiro/`, Copilot instructions) |

## 12. Sources

- Claude Code, "How Claude remembers your project":
  https://code.claude.com/docs/en/memory (sections "AGENTS.md", "When Claude Code reads
  AGENTS.md", "Choose which instruction files load", "When AGENTS.md support is
  unavailable", "Where AGENTS.md differs from CLAUDE.md", "Share one file with other
  coding tools", "Audit your instruction files", "My CLAUDE.md is too large"). Fetched
  2026-10-05.
- Claude Code commands reference (`/doctor`, `/init`, `/memory`):
  https://code.claude.com/docs/en/commands. Fetched 2026-10-05.
- Other tools' loading rules: `assets/agents-md/tool-profiles.json`, one source URL and a
  verified date per fact (Codex, Gemini CLI, Cursor, GitHub Copilot, Amp, Kiro, Windsurf,
  Jules). Verified 2026-10-07.
- matklad, "ARCHITECTURE.md": https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html
- Design and field research: `docs/plans/NESTED-ENTRY-DOCS-2026-10.md` in claude-mods.
- Survey evidence and the design decision: `docs/plans/AGENTS-MD-2026-10.md` in
  claude-mods.
