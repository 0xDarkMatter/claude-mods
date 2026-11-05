# Prune mode: delete what catches nothing, one module per PR, with evidence

**Output:** one PR per module that deletes, merges or re-tiers tests, with an evidence row
for every removed test and the suite time it saves. Deleting a redundant test is an
improvement (agentic-quality, "Tests: evidence, not ceremony"). A repo-wide sweep is
not: it cannot carry evidence per test, and it is unreviewable.

## Contents

- [Inputs](#inputs)
- [Candidates: where to look](#candidates-where-to-look)
- [Evidence: what makes a deletion safe](#evidence-what-makes-a-deletion-safe)
- [Actions other than delete](#actions-other-than-delete)
- [The PR](#the-pr)

## Inputs

Prune starts from an audit ledger ([audit.md](audit.md)): per file, what its tests catch
(mutants killed, audit verdicts) beside what they cost (seconds, flakes). Without a ledger,
run audit mode first. Pick the module with the **worst catch per second**: high time, few
unique kills. Not the one with the most tests.

## Candidates: where to look

| Source | Finds | Tool |
|---|---|---|
| Coverage overlap | a test whose lines another test fully covers | `coverage-overlap.py cov.json --profile full.json` |
| Copied logic | tests that re-type the source's formula or functions: rewrite with requirement-derived values, or delete if a neighbour already does that | `oracle-scan.py --repo .` |
| Slop review | S3 mirror oracles, S10 infrastructure tests, S12 duplicates, S15 shadow copies, S16 dead code, S18 coverage filler | `test-review-agent`, [slop-patterns.md](slop-patterns.md) |
| Mutation results | tests that kill no mutant the rest of the file does not already kill | the audit batch rows (`killedBy` per mutant) |
| Profile | the slowest tests, checked for their catch first | `suite-profile.py profile --top 30` |
| History | tests that never failed in CI, over many runs | CI test reports, where the repo keeps them |

```bash
python "<skill-dir>/scripts/coverage-overlap.py" cov.json --profile full.json --top 30
```

Every source yields **candidates**. Never-failed is the weakest signal of all: a test that
guards a rarely touched invariant never fails, and is exactly what you want to keep.

## Evidence: what makes a deletion safe

A test may go when **its neighbours kill every mutant it kills**. Build the evidence in
three steps:

1. **List the candidate's kills.** Plant the mutants relevant to the code it exercises
   (write.md's operator table, or the audit batch's rows) and record which tests kill each
   one. Use `mutate.mjs`, or the repo's mutation engine (mutmut, StrykerJS, Infection,
   cargo-mutants) restricted to the module.
2. **Revert-and-run.** Delete the candidate, re-run the same mutants against the remaining
   tests. Every mutant it killed must still be killed. One survivor means the test stays,
   or the survivor's catch moves into a neighbour first.
3. **Record it.** One row per deleted test: the test, the mutants it killed, the
   neighbour that kills each one, and its seconds.

```text
| Deleted | Mutants it killed | Still killed by | Saves |
|---|---|---|---|
| tests/test_invoice.py::test_total_2 | M3 rounding, M4 sign | test_total_rounds_half_up, test_refund_is_negative | 1.8 s |
```

Short of mutants (no engine, too slow): coverage overlap plus a reader's judgement that the
covering test asserts the same values is acceptable at `standard` strictness. Mark the row
`evidence: overlap`. In `strict` and `critical` zones, mutants are required.

## Actions other than delete

| Finding | Action |
|---|---|
| Two tests pin the same behaviour with different inputs | merge into one table-driven test; keep every distinct input |
| A slow test with a unique catch | keep it, and make it faster (speed mode), or move it to a slower tier (T2) |
| A slow e2e test that duplicates a component test's catch | keep one journey per critical path in e2e (profile.md); move the rest down a level |
| A test of dead code (S16) | delete the dead code and its test together |
| A shadow copy (S15) | point the test at the real module; its catch may be real once it does |
| A flaky test with a unique catch | fix it (triage.md). Never delete a guard because it is flaky |

## The PR

- **One module per PR**, so the evidence table is reviewable and a revert is clean.
- The body carries the evidence table, `suite-profile.py compare --markdown` output, and the
  new budget (`budget-gate.py check --shrink-ok <deleted count>`, then re-baseline).
- **A pruned suite must still be green and complete**: the compare shows exactly the
  removed tests as `removed`, and nothing else.
- Never prune and change behaviour in the same PR: a red test after the prune must mean
  the prune was wrong.
