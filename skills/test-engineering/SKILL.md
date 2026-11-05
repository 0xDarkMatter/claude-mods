---
name: test-engineering
description: "Tests that earn their CI seconds: proved able to fail, kept only if they catch something, fast, run where and when a change needs them. Triggers on: write tests, test plan, TDD, mutation testing, audit the tests, test slop, slow tests, slow CI, CI cost, prune tests, flaky test, parallel tests, offload tests, test gate, test budget, red test, Greptile test comments."
when_to_use: "Use for any testing work: planning or writing tests, auditing what a suite catches and costs, pruning tests that catch nothing, making a suite or CI faster and cheaper, wiring a CI gate or time budget, or triaging a red test, flake, survivor or reviewer comment about tests."
argument-hint: "<design|write|audit|prune|speed|gate|triage> [target] [--posture tdd|test-after|characterise] [--visual]"
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Agent"
metadata:
  author: claude-mods
  related-skills: "python-pytest-ops, playwright-ops, cypress-ops, security-ops, evals-ops, ci-cd-ops, loop-ops"
---

# Test Engineering

A test's value is **what it catches, divided by what it costs**. Agents write code at
many times the human rate and tests to match, and the suites they leave behind optimise for
count: hundreds of tests that restate the code, rarely fail, overlap each other, and all
run on every change. This skill optimises the ratio instead:

- **Catch**, proved, not assumed: does a planted bug turn the test red? (mutants)
- **Cost**, measured, not guessed: seconds per run, runs per day, flakes, CI minutes.

Every mode works one side of that ratio or both. One skill, seven modes, one read-only
reviewer agent, a zero-dependency mutation harness, and stdlib scripts for the cost side.

## The doctrine (no setting changes these)

1. **Seen failing, for the right reason, or it is not evidence.** Every new test goes red on a
   planted mutant or the unfixed code, as an assertion on a value. A missing symbol or an
   import crash is red for the wrong reason.
2. **Named for the bug it prevents.** `refuses a reset link that was already used`,
   not `test_reset_2`. If you cannot name the bug, do not write the test.
3. **Independent oracle, never a copy of the code.** The expected value comes from the
   requirement (a hand-derived literal, a spec vector), never from calling the code, and never
   from its formula re-typed in the test. A copied formula agrees with the code, bugs
   included, and breaks on every refactor: it pins the implementation, not the behaviour.
   Agents writing tests straight after the code produce it readily (S3, S15);
   `oracle-scan.py` finds candidates.
4. **The boundary users hit.** HTTP response, CLI exit code and stdout, tool result. Real
   lightweight dependencies; mock only at process boundaries; never mock the unit under test.
5. **Coverage and count are diagnostics, never goals.** Protection is measured by killed
   mutants; size by seconds.
6. **Heuristics triage, evidence decides.** A static flag or an overlap candidate is a
   question for a reader; a mutant result is an answer.
7. **Every test earns its seconds and its tier.** A test that catches nothing its neighbours
   do not is deleted, with evidence. A slow test with a unique catch moves to a slower tier,
   or gets faster. Count never justifies anything.
8. **Tests are conditional: run only what the change touched.** Change-aware selection is
   the default on every tier but one. The full suite runs on merge or nightly as the safety
   net, and any change selection cannot scope (lockfiles, config, an unmapped file) runs it too.
9. **Run it somewhere else, in parallel.** Offload is the default: few tests need the
   developer's machine. Local runs are always parallel and never take the whole machine.

## Why: the evidence

From a 13-repo survey (Go, Python, TypeScript: CLIs, MCP servers, Workers APIs, a web app,
data and media pipelines), every number measured, not estimated:

| Finding | Consequence here |
|---|---|
| Lead-authored mutants: 45 of 61 killed (74%) by suites that were all green | `audit` measures with mutants, never with coverage |
| Mutants a blind reviewer predicted were untested: **20 of 20 survived** | the reviewer agent is the cheapest source of real gaps |
| Behaviour a site comment warned about: protected 87%; unflagged behaviour: 66% | `design` walks a gap-class list to supply what nobody anticipated |
| Static slop heuristics: 13% precise | they never block; only exact checks and measured time do |
| New slop families: tests of copied production code, lost duplicate-named tests | catalogued as S15 and S17 |

## Modes

Pick from the request; say which mode you chose. Each mode loads only its own reference.

| Mode | Side | When | Read | Output |
|---|---|---|---|---|
| **design** | catch | "how should I test X", "test plan", "what could break" | [design.md](references/design.md) | failure list: one named test per bug, with level, oracle, doubles |
| **write** | catch | "write / add tests", TDD, a bug fix | [write.md](references/write.md) | tests, each proved with `mutate.mjs --prove`, or marked `unverified` |
| **audit** | both | "what do our tests catch", "why is CI slow", "what does a PR cost" | [audit.md](references/audit.md) | cost profile, mutation results, and the **ledger**: catch beside cost, per file |
| **prune** | both | "too many tests", "tests that copy the code", "delete low-value tests" | [prune.md](references/prune.md) | one PR per module: deletions and merges, an evidence row each |
| **speed** | cost | "slow tests", "slow CI", "parallelise", "offload", "only run tests for what changed" | [speed.md](references/speed.md), [ci.md](references/ci.md) | where it runs, workers, tiers, fixture and harness fixes; before/after |
| **gate** | both | "test gate in CI", "block bad tests", "test budget" | [gate.md](references/gate.md) | exact CI checks, the time-budget ratchet, the AGENTS.md Testing section |
| **triage** | catch | a red test, a survivor, a flake, a reviewer's test comment | [triage.md](references/triage.md) | one ruling per item, with the evidence that decided it |

The flow: design feeds write; audit produces the ledger that prune (worst catch per second
first) and speed (slowest unique catches first) act on; gate holds the line so the suite
cannot drift back; triage rules on what audit, CI and reviewers raise. "Make our tests
better" with no more detail means audit first.

## The profile and the budget

`.test-profile.yml` at the repo root tunes how much evidence is demanded, never the doctrine.
Missing: defaults apply (`standard`, `test-after`) and design mode proposes one, asking first.

```yaml
version: 1
shape: [http-service, cli]      # drives default kinds of test
strictness: standard            # standard | strict | critical
posture: test-after             # tdd | test-after (a developer preference; gates ignore it)
kinds: {}                       # exceptions to shape defaults, e.g. { e2e: full, visual: review }
zones:                          # money, auth, pii, irreversible -> strict; mission-critical -> critical
  - { paths: ["src/billing/**"], tags: [money] }
```

| | standard | strict | critical |
|---|---|---|---|
| New tests that must be proved | bug-fix tests | all | all, evidence in the PR |
| Audit mutants per zone file | 2 | 4 | 6 |
| Prune evidence | mutants, or overlap + reading | mutants | mutants |

`.test-budget.json` is separate and generated: measured suite time and grandfathered slow
tests, written by `budget-gate.py baseline` and checked in CI. Full schema, zone tags,
shapes, and the visual/e2e/browser policy: [profile.md](references/profile.md).

## The tools

All paths are relative to this skill's folder; run them from the repo under test.

**Catch: `scripts/mutate.mjs`.** Zero dependencies (Node 18+). Runners: `vitest`, `jest`,
`pytest`, `go`, `phpunit`, `pest` (Laravel included), and `command` for anything else.

```bash
# write mode: does this one test catch this one mutant?  exit 0 proved, 10 not proved
node "<skill-dir>/scripts/mutate.mjs" --runner vitest --catalogue m.json --prove "<test name>" -- <test file>
# audit mode: a batch, bracketed by automatic null controls
node "<skill-dir>/scripts/mutate.mjs" --runner pytest --catalogue audit.json --out results.jsonl
```

It restores files from memory (never `git checkout`, so uncommitted work is safe), refuses
a red or incomplete baseline, retries runs that silently dropped tests, classifies honestly
(only `killed` is a catch), and strips secret-looking env vars from every test run. It does
not deny network: unattended batches belong in a network-less container. Mutant rows:
[`assets/mutant.example.json`](assets/mutant.example.json); statuses: [audit.md](references/audit.md).

**Cost: stdlib Python 3.8+, `--json` everywhere, exit 10 = "found something".**

| Script | Answers | Worked call |
|---|---|---|
| `affected.py` | which test commands this diff needs, from a committed path map (for stacks with no native selector); unmappable -> full | `python "<skill-dir>/scripts/affected.py" --base origin/main` |
| `oracle-scan.py` | tests that re-type the source's formula, re-declare its functions, or call it on both sides of an assertion (advisory) | `python "<skill-dir>/scripts/oracle-scan.py" --repo .` |
| `run-plan.py` | where can this run, how many local workers fit now, which runner commands | `python "<skill-dir>/scripts/run-plan.py" targets --repo . --probe` |
| `suite-profile.py` | total time, slowest tests and files, flakes, before/after (JUnit from any runner) | `python "<skill-dir>/scripts/suite-profile.py" profile reports/ --json > full.json` |
| `ci-audit.py` | billed CI minutes per change, by OS and workflow; workflow waste CI1-CI4 | `python "<skill-dir>/scripts/ci-audit.py" cost --limit 50` |
| `coverage-overlap.py` | tests whose lines another test covers: prune candidates, ranked by seconds | `python "<skill-dir>/scripts/coverage-overlap.py" cov.json --profile full.json` |
| `budget-gate.py` | did the suite get slower, or gain a slow test? (the CI ratchet) | `python "<skill-dir>/scripts/budget-gate.py" check full.json --baseline .test-budget.json` |
| `coverage-check.sh` | pytest coverage, **report-only** by default; `--threshold` restores a gate | `bash "<skill-dir>/scripts/coverage-check.sh"` |

The order that saves most, per [speed.md](references/speed.md): **offload** (`run-plan.py
targets`: own machines first, CI next, metered sandboxes last, cost stated once) → **run
only what changed** (the ecosystem's selector, else `affected.py`; full run on merge) →
**run wide** (`run-plan.py local` sizes workers to free CPU and memory) → **run faster**
(fixtures, clocks, network) → **a faster runner**, or a harness rewritten in Go or Rust
when process spawns dominate.

## The reviewer agent

`test-review-agent` (Read, Grep, Glob only) reviews a suite blind to any mutation results:
adjudicates heuristic flags, finds slop, and predicts behaviours no test would catch, with
plantable anchors. Spawn it from audit, prune and triage; persist its JSON reply unchanged.

## Security and AI reviewers

- **Protection here, discovery elsewhere.** This skill answers "would we notice if a guard
  broke?" (auth and pii zones, a proved test per guard). "Is there a hole?" belongs to
  security-ops; its findings come back here as regression tests seen failing against the
  vulnerable revision. A prune never deletes a zone guard's only proved test.
- **AI reviewers propose, this skill proves.** A Greptile (or similar) comment about tests is a
  predicted gap: run the mutant it implies, then close the thread with evidence, never on
  prose. [ai-reviewers.md](references/ai-reviewers.md), rules for the reviewer:
  [`assets/greptile-rules.md`](assets/greptile-rules.md).

## Deliberately not in v1

A blocking seen-failing replay, nightly red-proof replay, per-PR generated mutants, and the
machinery that keeps a *blocking* heuristic gate honest (waivers, rebaselines, flake ledgers)
wait for evidence they are needed. So does a home-made test selector or mutation engine:
the ecosystem's own (testmon, `--changed`, nx/turbo affected, StrykerJS, Infection,
cargo-mutants) come first. Each deferral and its trigger: [gate.md](references/gate.md).

## Neighbours

Framework mechanics live elsewhere; this skill decides what to test, whether it earns its
place, and where and when it runs. `python-pytest-ops` (pytest fixtures, plugins, config),
`playwright-ops` and `cypress-ops` (browser drivers), `ci-cd-ops` (workflow syntax in
general), `evals-ops` (LLM output quality), `loop-ops` (scheduling an audit as a
report-only loop), `security-ops` (finding holes).

## References and assets

| File | Contents |
|---|---|
| [slop-patterns.md](references/slop-patterns.md) | S1-S18: tests that look like protection and are not, one question each |
| [gap-classes.md](references/gap-classes.md) | G1-G13: where realistic bugs went through green suites |
| [speed.md](references/speed.md) | offload first, resource-capped parallelism, tiers and selection, where seconds go, faster runners |
| [ci.md](references/ci.md) | how CI bills, CI1-CI4, tiered pipelines, shards, runner sizing, reports, flakes |
| [prune.md](references/prune.md) | candidates, deletion evidence (revert-and-run), the one-module PR |
| [mocking-strategies.md](references/mocking-strategies.md) | what to fake, where, and why real lightweight dependencies win |
| [tdd-workflow.md](references/tdd-workflow.md) | the red-green-refactor cycle and the right-reason red |
| [frameworks.md](references/frameworks.md) | test idioms per language and framework |
| [visual-testing.md](references/visual-testing.md) | visual checks through browser tooling |
| [test-data-patterns.md](references/test-data-patterns.md) | fixtures, factories, builders |
| [`assets/agents-testing-section.md`](assets/agents-testing-section.md) | the `## Testing` section a repo adopts in its AGENTS.md |
| [`assets/test-gate.yml`](assets/test-gate.yml), [`assets/ci-tiers.yml`](assets/ci-tiers.yml) | the exact-check gate; the tiered pipeline with the budget step |
| [`assets/test-profile.example.yml`](assets/test-profile.example.yml), [`assets/test-budget.example.json`](assets/test-budget.example.json), [`assets/test-map.example.json`](assets/test-map.example.json) | annotated profile; example budget baseline; example path map for `affected.py` |
