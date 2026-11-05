# Gate mode: what CI enforces (v1: deliberately small)

**Output:** CI checks that block only on what a tool measures or detects with no false
positives: lost tests, assertion-free PHP tests, and the **test-time budget**. Plus the
repo's `## Testing` section in AGENTS.md, so every agent and reviewer works to the same rule.

## Why the gate is small

In a 13-repo survey, static slop heuristics were 13% precise overall (assertion-free
detection 33%, snapshot flags 0%). A gate built on them blocks good PRs nine times in ten and
gets disabled within a week. One class is different: **lost tests (S17)**. Two Python test
functions with the same name in one scope mean the first never runs; pyflakes rule `F811`
detects it exactly. That, plus PHP's runtime no-assertion check (below), is all v1 blocks on.

The rest of the doctrine is enforced where it is cheap and accurate: at write time
(`--prove`), in review (evidence rows in the PR body), and in scheduled audits.

## What to wire

| Ecosystem | Lost-test check | Blocks? |
|---|---|---|
| Python | `ruff check --select F811 tests/` (or pylint `function-redefined`) | yes |
| JS/TS | none needed: duplicate titles both run. `no-identical-title` (eslint-plugin-vitest / -jest) is naming hygiene | advisory |
| Go | none needed: duplicate test names do not compile | - |
| PHP (PHPUnit, Pest, Laravel) | none needed: a duplicate method is a fatal error, and Pest refuses a duplicate description (`TestAlreadyExist`). Instead block **assertion-free tests**: `failOnRisky="true"` in `phpunit.xml` | yes |

**PHP gets a second exact check.** PHPUnit knows at runtime whether a test performed any
assertion, so `failOnRisky="true"` fails the existing test job on an assertion-free test: S2,
which is only a 33%-precise guess for a static scanner, becomes an exact check. A test that
genuinely asserts nothing (it only must not throw) declares it with
`$this->expectNotToPerformAssertions()`. One line in `phpunit.xml`, no new CI job; Pest reads
the same file.

Template: [`assets/test-gate.yml`](../assets/test-gate.yml) (GitHub Actions, pinned by SHA).
Common failure: the repo's ruff config already selects `F811`, but no CI job runs ruff over
`tests/`. Check that the linter actually runs before believing it.

Strictness does not change the v1 gate. It changes how much proof write mode demands and how
dense audits are ([profile.md](profile.md)).

## The budget ratchet: the suite may not get slower

Agents add tests at the rate they add code, and a suite that grows one second per change
takes minutes within a quarter. Time is measured, not guessed, so this check may block.
It is the mechanical half of "stop bloat at the source".

```bash
# once, from a full run on the CI runner class (local timings are not comparable)
python "<skill-dir>/scripts/budget-gate.py" baseline full.json --tolerance-pct 15 --max-test-s 2 > .test-budget.json
# every PR, in the job that ran the FULL suite (it refuses a subset run's profile)
python "<skill-dir>/scripts/budget-gate.py" check full.json --baseline .test-budget.json
```

| Rule | Blocks when | Why |
|---|---|---|
| B1 suite time | the total exceeds the baseline by more than the tolerance AND by more than `floor_s` (default 5 s) | the floor absorbs runner noise; the tolerance absorbs honest growth |
| B2 new slow test | a test not on the baseline's slow list takes more than `max_test_s` | a new slow test belongs in a slower tier, or needs a faster fixture |
| B3 slower slow test | a grandfathered slow test got slower than its record plus tolerance | grandfathered tests may stay; they may not grow |

- **The ratchet turns one way.** Re-baseline after a speed-up or prune, and the budget
  tightens. Re-baselining to absorb a slowdown needs a line in the PR body saying why
  (a new tier of e2e, say), and a reviewer who agrees.
- **Test count is reported, never blocked.** A count is not value. "Many new tests" is a
  question for review: were they each seen failing (write mode)?
- **Where the full suite runs only on merge**, run the check there and alert rather than block;
  the PR tier's own budget is its job's `timeout-minutes`.
- Template step: [`assets/ci-tiers.yml`](../assets/ci-tiers.yml); example baseline:
  [`assets/test-budget.example.json`](../assets/test-budget.example.json).

## The AGENTS.md section

Add [`assets/agents-testing-section.md`](../assets/agents-testing-section.md) to the repo's
AGENTS.md. It points at `.test-profile.yml`, states the evidence rule, and carries the
review-thread rule that keeps AI-reviewer loops honest ([ai-reviewers.md](ai-reviewers.md)).

## AI reviewers in CI

Separate lanes. A reviewer's check (Greptile and similar) stays advisory until its precision
on tests has been measured; this gate has its own check name, and never posts duplicate
inline comments on lines a reviewer already annotated.

## One row shape

A catalogue mutant, a `--prove` evidence row and a future red-proof table row are the same
object (`assets/mutant.example.json` plus the harness's result fields), so evidence written
today carries straight into the deferred levels below.

## Not in v1, and what would justify each

| Deferred | Build it when |
|---|---|
| **L1 seen-failing replay**: new tests in a PR must go red against the base revision | a team has used `--prove` for a few weeks and wants CI to check what PR bodies claim |
| **L2 red-proof replay**: a committed proofs table re-run nightly, each row by its `killedBy` tests, with a ratchet | a pilot repo wires an existing proof table. Several repos already keep one that no CI job runs; wiring one is the trigger |
| **L3 scheduled audit** | already possible: schedule audit mode as a report-only loop (loop-ops); no new code |
| **Diff-scoped generated mutants per PR**, time-boxed (15 minutes, adaptive count, sharded) | a mutation-engine spike shows mutants fit the budget on the slowest suite |
| **Network denial inside the harness** | a container or WSL spike on Windows; until then, containers for unattended runs |
| Policy read from the base branch, waivers with owner and expiry, a rebaseline protocol, a snapshot-only-kill status, a flake ledger, reviewer calibration, a pilot window | any heuristic check starts blocking: these keep a blocking gate honest, and are cost without benefit before then |
| A *blocking* slop detector (oracle-scan.py stays advisory), profile-proposal scripts | the reviewer agent and the written procedures prove too slow or inconsistent in practice |
| A blocking "new test must be proved" check | L1 seen-failing replay exists; until then the budget blocks on time and review blocks on proof |
