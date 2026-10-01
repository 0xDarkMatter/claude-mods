---
name: test-engineering
description: "Tests proven able to fail: design, write, audit, gate, triage. Triggers on: write tests, generate tests, test plan, TDD, mocking, mutation testing, audit the tests, test slop, test gate, flaky test, red test, surviving mutant, Greptile test comments."
when_to_use: "Use for any testing work: planning tests, writing them (TDD or test-after), auditing what a suite catches, wiring a CI gate, or triaging a red test, survivor or reviewer comment about tests."
argument-hint: "<design|write|audit|gate|triage> [target] [--posture tdd|test-after|characterise] [--visual]"
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Agent"
metadata:
  author: claude-mods
  related-skills: "python-pytest-ops, playwright-ops, cypress-ops, security-ops, evals-ops, ci-cd-ops, loop-ops"
---

# Test Engineering

Tests that are **proven able to fail**, aimed at the failures nobody anticipated. One skill,
five modes, one read-only reviewer agent, one zero-dependency harness.

## The doctrine (no setting changes these)

1. **Seen failing, for the right reason, or it is not evidence.** Every new test goes red on a
   planted mutant or the unfixed code, as an assertion on a value. A missing symbol or an
   import crash is red for the wrong reason.
2. **Named for the bug it prevents.** `refuses a reset link that was already used`,
   not `test_reset_2`. If you cannot name the bug, do not write the test.
3. **Independent oracle.** Never the code under test, never a copy of it pasted into the test.
4. **The boundary users hit.** HTTP response, CLI exit code and stdout, tool result. Real
   lightweight dependencies; mock only at process boundaries; never mock the unit under test.
5. **Coverage is a diagnostic, not a goal.** Protection is measured by killed mutants.
6. **Heuristics triage, evidence decides.** A static flag is a question for a reader; a
   mutant result is an answer.

## Why: the evidence

From a 13-repo survey (Go, Python, TypeScript: CLIs, MCP servers, Workers APIs, a web app,
data and media pipelines), every number measured, not estimated:

| Finding | Consequence here |
|---|---|
| Lead-authored mutants: 45 of 61 killed (74%) by suites that were all green | `audit` measures with mutants, never with coverage |
| Mutants a blind reviewer predicted were untested: **20 of 20 survived** | the reviewer agent is the cheapest source of real gaps |
| Behaviour a site comment warned about: protected 87%; unflagged behaviour: 66% | `design` walks a gap-class list to supply what nobody anticipated |
| Static slop heuristics: 13% precise | they never block; only lost tests (exact) do |
| New slop families: tests of copied production code, lost duplicate-named tests | catalogued as S15 and S17 |

## Modes

Pick from the request; say which mode you chose. Each mode loads only its own reference.

| Mode | When | Read | Output |
|---|---|---|---|
| **design** | "how should I test X", "test plan", "what could break" | [design.md](references/design.md) | failure list: one named test per bug, with level, oracle, doubles |
| **write** | "write / generate / add tests", TDD, a bug fix | [write.md](references/write.md) | tests, each proved with `mutate.mjs --prove`, or marked `unverified` |
| **audit** | "what do our tests catch", "is this suite slop" | [audit.md](references/audit.md) | inventory, blind review, mutation results, per-file verdicts |
| **gate** | "test gate in CI", "block bad tests" | [gate.md](references/gate.md) | a CI job (v1: lost tests only) and the AGENTS.md Testing section |
| **triage** | a red test, a survivor, a flaky test, a reviewer's test comment | [triage.md](references/triage.md) | one ruling per item, with the evidence that decided it |

Write mode starts from design's failure list; audit hands survivors to write mode; triage
rules on what audit and reviewers raise.

## The profile

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

Full schema, zone tags, shapes, and the visual/e2e/browser policy: [profile.md](references/profile.md).

## The harness: `scripts/mutate.mjs`

Zero dependencies (Node 18+). Runners: `vitest`, `jest`, `pytest`, `go`, `command`.

```bash
# write mode: does this one test catch this one mutant?  exit 0 proved, 10 not proved
node scripts/mutate.mjs --runner vitest --catalogue m.json --prove "<test name>" -- <test file>
# audit mode: a batch, bracketed by automatic null controls
node scripts/mutate.mjs --runner pytest --catalogue audit.json --out results.jsonl
```

It restores files from memory (never `git checkout`, so a developer's uncommitted work is
safe), refuses a red or incomplete baseline, retries runs that silently dropped tests,
classifies honestly (only `killed` is a catch), and strips secret-looking env vars from every
test run. It does not deny network: unattended batches belong in a network-less container.
Mutant rows: [`assets/mutant.example.json`](assets/mutant.example.json). Statuses and traps:
[audit.md](references/audit.md).

## The reviewer agent

`test-review-agent` (Read, Grep, Glob only) reviews a suite blind to any mutation results:
adjudicates heuristic flags, finds slop, and predicts behaviours no test would catch, with
plantable anchors. Spawn it from audit and triage; persist its JSON reply unchanged.

## Security and AI reviewers

- **Protection here, discovery elsewhere.** This skill answers "would we notice if a guard
  broke?" (auth and pii zones, a proved test per guard). "Is there a hole?" belongs to
  security-ops; its findings come back here as regression tests seen failing against the
  vulnerable revision.
- **AI reviewers propose, this skill proves.** A Greptile (or similar) comment about tests is a
  predicted gap: run the mutant it implies, then close the thread with evidence, never on
  prose. [ai-reviewers.md](references/ai-reviewers.md).

## Deliberately not in v1

The CI ladder beyond lost tests (seen-failing replay, nightly red-proof replay, per-PR
generated mutants) and the machinery that keeps a *blocking* heuristic gate honest (waivers,
rebaselines, flake ledgers, pilot windows) wait for evidence they are needed. Each deferral and
its trigger: [gate.md](references/gate.md).

## References

| File | Contents |
|---|---|
| [slop-patterns.md](references/slop-patterns.md) | S1-S18: tests that look like protection and are not, one question each |
| [gap-classes.md](references/gap-classes.md) | G1-G13: where realistic bugs went through green suites |
| [mocking-strategies.md](references/mocking-strategies.md) | what to fake, where, and why real lightweight dependencies win |
| [tdd-workflow.md](references/tdd-workflow.md) | the red-green-refactor cycle and the right-reason red |
| [frameworks.md](references/frameworks.md) | test idioms per language and framework |
| [visual-testing.md](references/visual-testing.md) | visual checks through browser tooling |
| [test-data-patterns.md](references/test-data-patterns.md) | fixtures, factories, builders |
| [ci-testing.md](references/ci-testing.md) | CI pipelines, caching, sharding, reports |
| `scripts/coverage-check.sh` | pytest coverage, **report-only** by default; `--threshold` restores a gate |
