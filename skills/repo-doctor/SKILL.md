---
name: repo-doctor
description: "Audit any repo against the agentic-quality doctrine; create, audit, upgrade or org-survey its AGENTS.md. Triggers on: repo doctor, repo audit, agentic quality, agent-friendly, write AGENTS.md, audit AGENTS.md, upgrade AGENTS.md, AGENTS.md not loading, CLAUDE.md shadows AGENTS.md, AGENTS.md org survey, stale AGENTS.md, monorepo structure, nested CLAUDE.md."
license: MIT
allowed-tools: "Read Bash Glob Grep Agent"
metadata:
  author: claude-mods
  related-skills: "doc-scanner, adr-ops, refactor-ops, techdebt, scaffold, project-planner, github-ops"
---

# Repo Doctor

Scores a repository against the **agentic-quality doctrine** (the cross-repo standard
in [rules/agentic-quality.md](../../rules/agentic-quality.md) for code, comments, docs
and structure a cold agent session can navigate), and owns the **AGENTS.md protocol**:
creating, auditing, upgrading and org-surveying a repo's entry doc.

Read-only by default. The scorer, the scan, the audit and the survey never write. The
only writing step is `agents-md.py scaffold --write`, which **creates** an AGENTS.md and
refuses to overwrite one (there is deliberately no `--force`).

## AGENTS.md: create, audit, upgrade, survey

The protocol (what goes in, what stays out, the 150/200-line budget and how to split,
CLAUDE.md shadowing, staleness in commits) is
[references/agents-md-protocol.md](references/agents-md-protocol.md). Read it before
writing or judging an entry doc. The load-bearing fact: **Claude Code reads AGENTS.md
only when no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` sits in the working
directory or above it**, unless that CLAUDE.md imports `@AGENTS.md`.

```bash
# 1. Deep scan: deterministic facts JSON; every fact cites file:line or a command,
#    plus landmine CANDIDATES from git history (always questions, never facts)
python scripts/repo-scan.py --repo path/to/repo --json > facts.json

# 2. Create: draft from the facts (commands only from declared scripts, tagged [untested])
python scripts/agents-md.py scaffold --repo path/to/repo --facts facts.json > AGENTS.draft.md
python scripts/agents-md.py scaffold --repo path/to/repo --write      # creates; never overwrites

# 3. Audit, then upgrade with a reviewable patch
python scripts/agents-md.py audit --repo path/to/repo                 # exit 10 on warn/crit
python scripts/agents-md.py audit --repo path/to/repo --diff > agents-md.patch
git -C path/to/repo apply "$PWD/agents-md.patch"

# 4. Survey a GitHub org: read-only gh api, no clones, writes nothing
python scripts/agents-md.py survey --org my-org --json | jq '.meta'
```

Workflow rules:

1. **Scan before drafting.** The scaffold's archetype templates
   ([assets/agents-md/](assets/agents-md/): PHP CMS + DDEV + bundler, Node/TS app,
   Python service, static site) hold slots, not claims. Everything the scan can't
   verify becomes a `TODO(owner):` question.
2. **The owner finishes the draft.** Answer or delete every `TODO(owner)`, run each
   command once and drop its `[untested]` tag, delete the DRAFT comment. The audit flags
   all three until done. Optional synthesis (one read-only Explore subagent per custom
   code area, at most four, fed the facts JSON) is in the protocol's section 8.
3. **The patch never removes landmines.** `--diff` adds missing-section stubs, an
   `@AGENTS.md` import for a shadowing CLAUDE.md, annotations on dead commands, and moves
   for oversized sections (setup prose to README, subsystem detail to a nested
   AGENTS.md, the rest to `docs/agents/`). It leaves the overview, Commands, Landmines and
   Deploy where they are.
4. **Pair with Claude Code's own checks.** `/doctor prompt-audit` does the semantic pass
   (outdated or contradictory instructions); this tooling is the deterministic, CI-able
   one (protocol section 7).

Never run repo tooling to "verify" a command: Composer plugins, justfile backticks and
`make $(shell ...)` execute repo code even when listing. The scan reads tracked files and
git metadata only, never opens secret files, and keeps variable names (not values) from
`.env.example`.

## Repo scorer

```bash
python scripts/repo-doctor.py                          # audit cwd, human panel
python scripts/repo-doctor.py --repo path/to/repo      # audit another repo
python scripts/repo-doctor.py --json | jq .data.grade  # machine-readable
python scripts/repo-doctor.py --strict                 # CI gate: exit 10 below B
```

Six dimensions, 0-5 each, weighted into a letter grade:

| Dimension | Measures | Weight |
|---|---|---|
| `entry_docs` | AGENTS.md/CLAUDE.md present · Landmines section · 200-line budget · freshness in **commits-since-touched** · a CLAUDE.md that shadows AGENTS.md | 2.0 |
| `docs_health` | README · docs/ index when >6 files · ghost links in the index | 1.5 |
| `comments` | contract blocks on the largest source files · section markers in files >400 lines | 2.0 |
| `structure` | monster files (>800 warn, >1500 crit; generated exempt) · repo-root junk | 2.0 |
| `enforcement` | tests · CI · single `check` entry point · invariant gate scripts | 1.5 |
| `doc_pairing` | fraction of recent feat/fix commits touching a `*.md` in the same commit | 1.0 |

Full rubric (each check, threshold and fix): [references/scoring-rubric.md](references/scoring-rubric.md).

### Audit workflow

1. **Run the scorer.** On cp1252/plain terminals it degrades to ASCII; nothing is written.
2. **Read findings top-down** (crit, then warn, then info). Facts (monster-file list,
   pairing ratio, entry-doc age) ride in `--json` under `.data.facts`.
3. **Verify before acting.** The scorer is heuristic: a flagged 900-line file may be a
   justified single-writer module (then it needs the guard comment, section map and gate,
   not a split); a "stale" AGENTS.md may describe code that genuinely didn't change.
4. **Remediate via the owning skill** (below). Batch fixes into small commits: entry doc
   first (highest leverage), then indexes, guard comments, splits.
5. **Re-run to confirm** the grade moved. For fleets, loop `--json` over repo roots, or
   use `agents-md.py survey --org` for the entry-doc column without cloning.

## Remediation map: who owns each fix

| Finding | Owner |
|---|---|
| Missing/weak/oversized AGENTS.md, shadowing CLAUDE.md | `agents-md.py scaffold` / `audit --diff` (above); hand skeleton: [assets/AGENTS-template.md](assets/AGENTS-template.md) |
| Multi-platform doc mess (CLAUDE.md + COPILOT.md + CURSOR.md ...) | `doc-scanner` (consolidate), then audit the result here |
| Missing docs index | Write from [assets/docs-index-template.md](assets/docs-index-template.md) |
| Monster file needs splitting | `refactor-ops` (extract-module patterns, circular-dep cautions) |
| Monster file is *justified* | Guard comment + section map + a `scripts/check-*` invariant gate ([references/comment-doctrine.md](references/comment-doctrine.md)) |
| Missing/weak comments | [references/comment-doctrine.md](references/comment-doctrine.md): contract blocks, WHY-only, guard comments, citations |
| Decisions undocumented | `adr-ops` |
| Stale PLAN/roadmap | `project-planner` |
| Code-level debt (duplication, dead code, security) | `techdebt`: deliberately NOT scored here |
| New repo from scratch | `scaffold` + the templates in assets/ |

Boundary: repo-doctor audits **repo-level conventions**; `techdebt` scans **code-level
debt**; `review`/code-review judge **diffs**. Don't blur the three.

## Nested entry docs and monorepos

Nest an AGENTS.md only where a subsystem has its own contract (invariant law, audience
or gate); the root links every nested doc, and a CLAUDE.md beside a nested AGENTS.md
shadows it (protocol section 6). For large multi-subsystem repos the root entry doc is
judged as a *router* (invariants + ownership table), each contracted package needs its
own entry doc and `check`, and cross-package invariants need mechanical gates:
[references/monorepo-structure.md](references/monorepo-structure.md). Run the scorer
per package as well as at root.

## Resources

| Resource | What it owns |
|---|---|
| [scripts/repo-doctor.py](scripts/repo-doctor.py) | The scorer: six dimensions, findings, grade; `--json` envelope `claude-mods.repo-doctor/v1`; `--strict` CI gate |
| [scripts/repo-scan.py](scripts/repo-scan.py) | Deep scan: manifests, DDEV, deploy hooks and the scripts they call, CI, tests, generated output, code areas, size outliers, docs, env names, git-history landmine candidates; `--json` (`repo-scan/v1`), `--only` |
| [scripts/agents-md.py](scripts/agents-md.py) | `scaffold` (`--write` creates only), `audit` (`--diff` patch), `survey --org` / `--remote` (GET-only); exit 10 on findings |
| [scripts/check-memory-docs.py](scripts/check-memory-docs.py) | Tripwire for the Claude Code facts the protocol encodes: `--offline` in PR CI, `--live` in the scheduled freshness workflow |
| [references/agents-md-protocol.md](references/agents-md-protocol.md) | The AGENTS.md protocol: contents, exclusions, size and split, CLAUDE.md shadowing, staleness, how the tools fit beside `/doctor` |
| [references/scoring-rubric.md](references/scoring-rubric.md) | Every scorer check: what it measures, threshold, why, and the fix |
| [references/comment-doctrine.md](references/comment-doctrine.md) | Contract blocks, WHY-only inline, guard comments, section markers, format-at-site, citations |
| [references/monorepo-structure.md](references/monorepo-structure.md) | Structuring very large monorepos for agentic development |
| [assets/agents-md/](assets/agents-md/) | Archetype templates the scaffold fills (usable by hand: the slots are documented in each file's header) |
| [assets/AGENTS-template.md](assets/AGENTS-template.md) | Hand-fill entry-doc skeleton with the mandatory Landmines section |
| [assets/docs-index-template.md](assets/docs-index-template.md) | `docs/00_INDEX.md` skeleton with the two anti-rot rules baked in |
