---
name: repo-doctor
description: "Audit any repo against the agentic-quality doctrine — score entry docs, structure, and enforcement gates, then map each finding to its fix. Triggers on: repo doctor, repo audit, agentic quality, is this repo agent-friendly, doc drift, stale AGENTS.md, monorepo structure, nested CLAUDE.md."
license: MIT
allowed-tools: "Read Bash Glob Grep Agent"
metadata:
  author: claude-mods
  related-skills: "doc-scanner, adr-ops, refactor-ops, techdebt, scaffold, project-planner"
---

# Repo Doctor

Scores a repository against the **agentic-quality doctrine** — the cross-repo standard
in [rules/agentic-quality.md](../../rules/agentic-quality.md) for code, comments,
docs, and structure that a cold agent session can navigate. The rule says *what good
looks like*; this skill measures a repo against it and maps each gap to its fix.

Read-only. The scorer never writes; remediation is always a separate, deliberate step.

## Quick start

```bash
python scripts/repo-doctor.py                          # audit cwd, human panel
python scripts/repo-doctor.py --repo X:/path/to/repo   # audit another repo
python scripts/repo-doctor.py --json | jq .data.grade  # machine-readable
python scripts/repo-doctor.py --strict                 # CI gate: exit 10 below B
```

Six dimensions, 0–5 each, weighted into a letter grade:

| Dimension | Measures | Weight |
|---|---|---|
| `entry_docs` | AGENTS.md/CLAUDE.md present · Landmines section · length budget (~250 lines) · freshness in **commits-since-touched** | 2.0 |
| `docs_health` | README · docs/ index when >6 files · ghost links in the index | 1.5 |
| `comments` | contract blocks on the largest source files · section markers in files >400 lines | 2.0 |
| `structure` | monster files (>800 warn, >1500 crit; generated exempt) · repo-root junk | 2.0 |
| `enforcement` | tests · CI · single `check` entry point · invariant gate scripts | 1.5 |
| `doc_pairing` | fraction of recent feat/fix commits touching a `*.md` in the same commit | 1.0 |

Full rubric — what each check means, thresholds, and the fix for every finding:
[references/scoring-rubric.md](references/scoring-rubric.md).

## Audit workflow

1. **Run the scorer** on the target repo. On cp1252/plain terminals it degrades to
   ASCII automatically; nothing is written.
2. **Read findings top-down** — they're sorted crit → warn → info. Facts (monster-file
   list, pairing ratio, entry-doc age) ride in `--json` under `.data.facts`.
3. **Verify before acting.** The scorer is heuristic: a flagged 900-line file may be a
   justified single-writer module (then it needs the guard comment + section map + gate,
   not a split); a "stale" AGENTS.md may describe code that genuinely didn't change.
   Confirm each finding against the repo before proposing work.
4. **Remediate via the owning skill** (below) — repo-doctor diagnoses, it does not
   operate. Batch fixes into small commits: entry-doc fixes first (highest leverage),
   then indexes, then guard comments, then splits.
5. **Re-run to confirm** the grade moved. For fleets, loop the scorer over repo roots
   with `--json` and tabulate grades.

## Remediation map — who owns each fix

| Finding | Owner |
|---|---|
| Missing/weak AGENTS.md, multi-platform doc mess | `doc-scanner` (generate/consolidate), template: [assets/AGENTS-template.md](assets/AGENTS-template.md) |
| Missing docs index | Write from [assets/docs-index-template.md](assets/docs-index-template.md) |
| Monster file needs splitting | `refactor-ops` (extract-module patterns, circular-dep cautions) |
| Monster file is *justified* | Guard comment + section map + a `scripts/check-*` invariant gate (pattern in [references/comment-doctrine.md](references/comment-doctrine.md)) |
| Missing/weak comments | [references/comment-doctrine.md](references/comment-doctrine.md) — contract blocks, WHY-only, guard comments, citations |
| Decisions undocumented | `adr-ops` |
| Stale PLAN/roadmap | `project-planner` |
| Code-level debt (duplication, dead code, security) | `techdebt` — deliberately NOT scored here |
| New repo from scratch | `scaffold` + the two templates in assets/ |

Boundary: repo-doctor audits **repo-level conventions**; `techdebt` scans **code-level
debt**; `review`/code-review judge **diffs**. Don't blur the three.

## Interpreting the two entry-doc questions

**AGENTS.md vs CLAUDE.md** — AGENTS.md is the single source of truth (open standard,
read by all agent tooling). CLAUDE.md is legitimate only as a pointer or as
Claude-specific *deltas* maintained in lockstep. The scorer flags apparent duplication;
the decision tree and the one known-good dual-file pattern are in
[references/entry-docs.md](references/entry-docs.md).

**Nested entry docs** — nest only where a subsystem has its own contract (design-system
package, determinism-bound engine, per-tool CLI); root file carries an ownership table
linking each. Anatomy, length budgets, Landmines guidance, freshness discipline: same
reference.

## Monorepos

For large multi-subsystem repos the audit shifts: the root entry doc is judged as a
*router* (invariants + ownership table), each contracted package needs its own entry
doc and `check`, and cross-package invariants need mechanical gates, not prose. The
full playbook — boundaries, navigation aids, extraction signals, parallel-agent
(worktree) interplay, and the split-the-repo decision — is
[references/monorepo-structure.md](references/monorepo-structure.md). Run the scorer
per-package as well as at root; a healthy root with a failing core package is the
common monorepo blind spot.

## Resources

| Resource | What it owns |
|---|---|
| [scripts/repo-doctor.py](scripts/repo-doctor.py) | The scorer: six dimensions, findings, grade; `--json` envelope `claude-mods.repo-doctor/v1`; `--strict` CI gate |
| [references/scoring-rubric.md](references/scoring-rubric.md) | Every check: what it measures, threshold, why, and the fix |
| [references/comment-doctrine.md](references/comment-doctrine.md) | Contract blocks, WHY-only inline, guard comments, section markers, format-at-site, citations — with good/bad examples |
| [references/entry-docs.md](references/entry-docs.md) | AGENTS.md anatomy + Landmines, AGENTS-vs-CLAUDE decision, nesting policy, freshness discipline |
| [references/monorepo-structure.md](references/monorepo-structure.md) | Structuring very large monorepos for agentic development |
| [assets/AGENTS-template.md](assets/AGENTS-template.md) | Entry-doc skeleton with mandatory Landmines section |
| [assets/docs-index-template.md](assets/docs-index-template.md) | `docs/00_INDEX.md` skeleton with the two anti-rot rules baked in |
