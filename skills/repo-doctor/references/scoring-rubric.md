# Scoring Rubric — what repo-doctor measures, thresholds, and the fix per finding

Every check in `scripts/repo-doctor.py`, its threshold, why that threshold, and the
remediation. Grade bands: A ≥ 4.5 · B ≥ 3.5 · C ≥ 2.5 · D ≥ 1.5 · F below. `--strict`
exits 10 below B — that's the CI posture ("healthy or explain").

The scorer is heuristic and read-only. **Always verify a finding against the repo
before proposing work** — a flagged monster file may be justified (then the fix is the
guard-comment + gate route, not a split), and a "stale" entry doc may describe code
that genuinely didn't change (then touch it in the next honest commit, don't churn it).

---

## entry_docs (weight 2.0)

| Check | Threshold | Why | Fix |
|---|---|---|---|
| AGENTS.md or CLAUDE.md exists | crit if absent (score 0) | Agents enter blind; every session re-derives the repo | Generate via `doc-scanner`; seed from assets/AGENTS-template.md |
| Landmines section | warn | The highest-value lines in the file; absence means non-obvious breakage is tribal knowledge | Add `## Landmines` — what breaks, why, procedure (entry-docs.md §anatomy) |
| Length ≤ 250 lines | warn above | Recurring per-session token tax; bloat = human walkthroughs in the agent file | Evict setup guides to README/docs, keep deltas + landmines |
| Touched within 15 commits | warn above | Commit-lag is the real staleness metric; mtime lies (audit: 100+-commit drift behind week-old mtimes) | Verify claims vs code; update in the same commit as the fix |
| CLAUDE.md duplicates AGENTS.md | warn | Duplicates diverge into contradictions | Reduce to pointer or deltas-only (entry-docs.md §verdict) |

## docs_health (weight 1.5)

| Check | Threshold | Why | Fix |
|---|---|---|---|
| README.md exists | warn | Humans (and some tools) enter here | Short narrative + quickstart + doc links |
| docs/ index when > 6 md files | warn | Un-indexed doc dirs make agents hunt; the audit's index-less 16-file docs/ cost every session a search | assets/docs-index-template.md; delegate volatile lists to `ls` |
| Index links resolve | warn per ghost | Dead links teach agents to distrust the index | Fix or remove; index carries its own maintenance note |
| Docs missing from index | info | Coverage drift signal | Add one-line entries |

No docs/ dir at all: not penalised beyond a cap (small repos legitimately keep
everything in README + AGENTS.md).

## comments (weight 2.0)

Sampled over the N largest source files (default 12, `--sample`), ≥100 lines each.

| Check | Threshold | Why | Fix |
|---|---|---|---|
| Contract block | first 15 lines carry ≥3 comment/docstring lines | The cheapest orientation an agent gets; ratio drives the score | comment-doctrine.md §1 — what/invariants/refs |
| Section markers in >400-line files | info per file | Jumping beats scrolling; markers are how agents Grep-navigate | `// === SECTION ===` per region; >800 also gets a top map |

Not measured (deliberately): comment *density* — high density of WHAT-noise scores
worse in practice than sparse WHY comments. The doctrine reference owns quality;
the scorer only checks the two mechanically-checkable proxies.

## structure (weight 2.0)

| Check | Threshold | Why | Fix |
|---|---|---|---|
| Monster files | warn ≥800, crit ≥1500 (generated files exempt via header detection) | #1 agent friction in 3 of 4 audited clusters; a 9,560-line file is grep-only territory | Split (refactor-ops), OR guard comment + section map + invariant gate (the justified-monster route) |
| Justified monster | downgraded to info when the first 40 lines carry a justification marker (`ARCHITECTURE:`, `PERF:`, `Sections:`, "single-file", "single-writer", "do not split") | The scorer honours the doctrine's own escape hatch — a justified file shouldn't nag forever; the info reminds you to verify the map + gate still hold | Keep the marker honest: if the gate is gone, the justification is a lie — split or restore the gate |
| Repo-root junk | warn; media >1 MB or scratch-pattern names | Root is the first thing every agent lists; junk destroys signal | docs/screenshots/, dev/, scratchpad, or delete |

## enforcement (weight 1.5)

| Check | Points | Why | Fix |
|---|---|---|---|
| Tests present | 1.5 | Without tests every agent edit is a hope | testing-ops / testgen; name adversarial tests for the adversary |
| CI workflows | 1.0 | Local-only gates skip on exactly the sessions that forget | Minimal workflow running `check` |
| Single `check` entry | 1.5 | If verification isn't one command, agents won't run it | `npm run check` / `just check` fanning out typecheck+lint+tests+gates |
| Invariant gate scripts | 1.0 | Prose rules rot; 30-line scripts don't (the lint:db lesson) | `scripts/check-<invariant>.mjs` per ownership-table rule |

## doc_pairing (weight 1.0)

Fraction of the last 60 non-merge `feat|fix|refactor|perf` commits that touch any
`*.md` in the same commit. 50% pairing scores 5 (not every feature invalidates a doc —
demanding 100% would reward doc-churn theatre). Below 15% → warn: docs are drifting as
a matter of process, not accident. Fix is workflow, not writing: "done includes the doc
touch" (rules/agentic-quality.md non-negotiable #3).

---

## Reading the output

- **Findings are sorted crit → warn → info**; facts (`--json` → `.data.facts`) carry
  the raw numbers (monster list, pairing ratio, entry-doc age, gate inventory).
- **Fix order for a C/D repo**: entry doc (biggest single lever) → docs index → guard
  comments on justified weirdness → `check` entry point → splits. Re-run after each
  batch; `entry_docs` and `docs_health` move immediately, `comments` moves with the
  retrofit, `doc_pairing` only moves with sustained workflow change.
- **Fleet sweep**: loop `--json` over repo roots, tabulate `.data.grade` — the audit
  found grade variance within one developer's repos is a convention-enforcement
  signal, not a skill signal.
