# Audit mode: what does this suite catch, and what does it cost?

**Output:** a report with an inventory, a cost profile, blind-review findings, mutation
results classified honestly, and a **ledger**: per file, its catch beside its cost. An audit
measures; it never edits the code it audits. Prune and speed modes act on the ledger.

A quick audit (`cost` only: "why is CI slow", "what does a PR cost") runs the cost half
and stops. A full audit runs both.

## Contents

- [Guardrails](#guardrails-before-anything-runs)
- [The cost half](#the-cost-half)
- [The catch half](#the-catch-half)
- [The ledger](#the-ledger)
- [Status taxonomy](#status-taxonomy)
- [Harness traps](#harness-traps-each-one-has-produced-a-false-result)
- [Mutation engines](#mutation-engines-as-of-2026-10-01)
- [Report skeleton](#report-skeleton)

## Guardrails (before anything runs)

- **Work in a disposable copy**, never the developer's tree: `git worktree add` or
  `git archive HEAD | tar -x -C <scratch>`. Install from the lockfile only (`npm ci`,
  `uv sync --frozen`, `go mod download`); never add or upgrade a dependency to make an
  audit run.
- **No live credentials.** `mutate.mjs` strips secret-looking env vars from every test run.
  It does not deny network: a mutant that disables a dry-run guard can turn an integration
  suite into real external writes. For unattended or scheduled batches, run inside a
  network-less container (`docker run --network none ...`), with local simulators only.
- **Read the repo's test doctrine first** (AGENTS.md, CONTRIBUTING, any red-proof table).
- **Run it somewhere else.** Full runs and mutation batches go to an offload target
  (`run-plan.py targets`); locally, cap workers with `run-plan.py local` ([speed.md](speed.md)).

## The cost half

1. **Inventory.** Runner (`run-plan.py stack`), test count (from a real run, not a grep),
   test-to-source ratio, mocking style (boundary or deep), snapshots, existing red-proof
   tables and whether CI runs them, which linters actually run over `tests/`.
2. **Profile a full run from JUnit XML** (`run-plan.py stack` prints each runner's JUnit flag):
   ```bash
   python "<skill-dir>/scripts/suite-profile.py" profile reports/ --top 20 --json > full.json
   ```
   Total time, the slowest tests and files, skips, and pass-on-retry flakes.
3. **Flakes.** Run the suite three times, or read the last N CI reports:
   `suite-profile.py flakes run1/ run2/ run3/` (exit 10 when any test is flaky).
4. **CI cost and waste.** `ci-audit.py cost --limit 50` gives billed minutes per run and
   per change, by OS and workflow, and what cancelled runs cost. `ci-audit.py lint` covers
   the free savings, CI1-CI4 ([ci.md](ci.md)).
5. **Overlap** (Python with pytest-cov, or any per-test coverage map):
   `coverage-overlap.py cov.json --profile full.json` lists redundancy candidates, ranked
   by seconds. Candidates only: prune mode decides.

## The catch half

1. **Baseline.** `mutate.mjs --baseline`: green and complete, or stop. A red baseline means
   every mutant will look killed.
2. **Copied logic.** `oracle-scan.py --repo .` lists tests that re-type the source's
   formulas, re-declare its functions, or call it on both sides of an assertion (S3, S15).
   Hand the hits to the reviewer as flags to adjudicate.
3. **Blind review.** Spawn the `test-review-agent` (read-only: Read, Grep, Glob) once per
   repo or package. It has not seen any mutation results and must not. It adjudicates
   heuristic flags, finds slop ([slop-patterns.md](slop-patterns.md)) and predicts 3-5
   behaviours no test would catch, each with an exact anchor line and a valid replacement.
   Persist its JSON reply as-is.
4. **Build two catalogues and never blend them:**
   - **authored:** your mutants for the riskiest modules: zones first, then the gap classes
     ([gap-classes.md](gap-classes.md)). As a tiebreaker, prefer sites with no warning
     comment: unflagged behaviour is protected far less often (66% vs 87%).
   - **predicted:** the reviewer's predictions, unchanged.
   Density per zone file: 2 at `standard`, 4 at `strict`, 6 at `critical`.
5. **Dry-run, then run.** `mutate.mjs --catalogue authored.json --dry-run` checks every
   anchor is unique; then the batch. Null controls open and close every batch automatically;
   `"trusted": false` (exit 10) means the environment drifted mid-batch and **no row in that
   batch counts**.
6. **Classify honestly** (table below), then check each survivor: is it reachable? Equivalent
   (probe the input space before claiming it)? Masked by another layer (still a gap, lower
   consequence)? Record equivalent and masked survivors with their reasoning.
7. **Verdict per file, judged by its declared subject.** A file named for invoicing is judged
   on invoicing mutants, not on what else it happens to touch.
8. **Report** (skeleton below). Authored and predicted kill rates are reported separately,
   always; blending them hides the most useful number.

## The ledger

One row per test file: what it catches beside what it costs. It is the hand-off to prune
mode (worst catch per second first) and speed mode (slowest unique catches first).

| File | Tests | Seconds | Flaky | Mutants killed | Unique kills | Overlap candidates | Verdict |
|---|---|---|---|---|---|---|---|
| tests/test_invoice.py | 42 | 31.0 | 0 | 9/11 | 3 | 14 | protected; prune candidates |

**Unique kills** are mutants no other file kills. A file with high seconds and no unique
kills is the first prune target. A file with unique kills is never pruned whole, however
slow: it goes to speed mode.

## Status taxonomy

Only `killed` means a test caught the mutant.

| Status | Meaning | Counts as |
|---|---|---|
| `killed` | at least one test failed (an assertion, or an exception inside a test body) | caught |
| `survived` | tests and typecheck green, every test ran | a gap, until shown equivalent |
| `type-killed` | tests green, typecheck red | a mutation-form problem: rewrite it type-valid and re-run |
| `compile-error` | the mutant does not build (common in Go: an unused variable) | a mutation-form problem, never a kill |
| `suite-error` | a test file crashed with no failing test (import or collection error) | red for the wrong reason |
| `incomplete` | fewer tests ran than the baseline, nothing failed, after retries | no evidence either way |
| `errors-row`, `timeout`, `no-report` | runner-level failure | no evidence; read the tail |

## Harness traps (each one has produced a false result)

- **Incomplete runs look green.** A runner can drop a test file and still exit 0. The
  harness compares every run's count with the baseline and retries; trust only complete runs.
- **Corrupted toolchains.** An interrupted install once left zero-filled binaries, and a
  no-op mutant came back "type-killed". The typecheck preflight and the closing null control
  exist for this; if either trips, reinstall from the lockfile.
- **Shell layers eat characters.** Unquoted heredocs expand `${...}` inside JS template
  literals; inline `sed`, `sd` and escaped regexes lose backslashes. Write catalogues and
  helpers as files (built by a script if they contain escapes), never inline shell.
- **Single-worker pools.** The Cloudflare Workers vitest pool runs one worker; on Windows it
  can drop a file on a busy-file error, which the count guard catches. Prefer Linux runners.
- **Type errors are not catches**, and neither are build failures. Re-form the mutant.
- **Tests that rewrite tracked files** (snapshot updates, golden regeneration) stop the
  batch: the harness refuses to continue when `git status` changes between mutants.

## Mutation engines (as of 2026-10-01)

The harness is the evidence layer: it classifies, guards counts and restores files. Engines
generate mutants at scale and are worth pairing with it for large audits. None is required.

| Engine | Ecosystem | Note |
|---|---|---|
| StrykerJS 10.x | JS/TS | mature; vitest and jest runners; a spike against the Workers pool is pending |
| cosmic-ray 8.x | Python | operator-based, resumable sessions |
| mutmut 3.x | Python | needs `fork`, so WSL or Linux on Windows hosts |
| gremlins 0.6 | Go | fast, coverage-guided |
| go-mutesting 2.x | Go | AST operators |
| Infection 0.35.x | PHP | runs PHPUnit, Pest or Codeception; reports a mutation score per file |
| cargo-mutants 25.x | Rust | runs `cargo test` or nextest; `--in-diff` for changed code only |
| `pest --mutate` | PHP | ships with Pest 5 (pest-plugin-mutate); the quickest start in a Laravel repo already on Pest |

Pin any engine to a release more than 7 days old and run it through the supply-chain checks
before adding it to a repo.

## Report skeleton

```
# Test audit: <repo> @ <sha> (<date>)
Inventory: runner, N tests, ratio, mocking style, snapshots, red-proof tables (wired?)
Cost: full run Ns (shards), slowest 10, flaky K, CI billed min per change M ($), CI1-CI4 findings
Baseline: green, N tests, Ns.  Null controls: opening green / closing green (trusted)
Authored: K/N killed (x%)   Predicted: K/N survived (shown separately, never blended)
Survivors: id, file, bug, class, reachable?, equivalent?, masked?
Slop found (reviewer, confirmed by reading): S-id, file, one line each
Per-file verdicts: file - declared subject - protected / partly / vacuous
Ledger: one row per file (catch beside cost)
Recommended next tests: the survivors, as rows for write mode
Recommended prunes / speed-ups: the ledger's top rows, for prune and speed modes
```

Run on a schedule, an audit is a report-only loop (loop-ops, L1): it posts the report and
never edits code.
