# AI code reviewers: the reviewer proposes, test-engineering proves

Greptile is the worked example; the same contract applies to CodeRabbit, Copilot review or a
custom bot.

**Why they fit together.** An AI PR reviewer is the same instrument as this skill's blind
reviewer agent: good at *finding* gaps (blind-review predictions of "untested" behaviour
survived mutation 20 times out of 20 in a survey) and unreliable at *grading* protection. So a
reviewer's test-related comment is a high-yield hypothesis, and this skill is where it gets
settled with evidence. How comments are fetched, summarised and resolved stays the reviewer's
own business (Greptile ships its own agent skills: `check-pr`, `cli-review`, `greploop`).
This skill adds one rule: **a test-related review thread is closed with evidence, never just
resolved.**

## Detection only

A repo uses Greptile when it has `greptile.json` or `.greptile/`, or its PRs carry a Greptile
check run or bot comments. Locally, the `greptile` CLI may be on PATH. Detection never
installs, logs in, or runs `greptile init`: the CLI is bound to one organisation's identity,
and initialising a repo under the wrong one is not undoable from here.

## What to do with each kind of comment

| The reviewer says | Do |
|---|---|
| "X is untested", "missing negative case", "this test cannot fail" | Triage it as a **predicted gap**: derive the mutant the claim implies, run it ([triage.md](triage.md)). Killed: reply naming the test and the evidence row, then resolve. Survived: write mode adds the killing test, proved; reply with the evidence; resolve |
| "Add a test for X" | Write the test through `--prove` before resolving; the reply cites the evidence row. A test that cannot go red does not close a thread |
| A test-related false positive | Reply with the evidence that refutes it (the killing test and row). Never resolve it silently |

## Review loops (`greploop`, `check-pr`)

A loop that iterates until the reviewer reports full confidence optimises the reviewer's
score. On tests that is the Goodhart trap: the cheapest way to satisfy "add a test" is a test
that cannot fail. This skill does not modify those skills; it puts one line in the repo's
AGENTS.md `## Testing` section, which the agent running the loop reads
([`assets/agents-testing-section.md`](../assets/agents-testing-section.md)):

> Test-related review threads are resolved with prove-it-fails evidence
> (test-engineering triage), never by resolving a false positive silently or adding a test
> that cannot fail.

## Exporting the doctrine to the reviewer (opt-in, per repo)

A team can make the reviewer enforce the same doctrine: copy
[`assets/greptile-rules.md`](../assets/greptile-rules.md) into the repo's Greptile rules
(a `.greptile/rules.md`, scoped to the test directories where your Greptile plan supports
directory scoping, or entries in `rules[]` of the Greptile config). It is opt-in because it
changes what the reviewer comments on for the whole team; that is the repo owner's call.
Greptile reads its configuration from the base branch, so a PR cannot loosen the rules that
review it. Only the portable catalogue goes in; never audit findings or private evidence.

## CI and local use

- **Separate lanes.** The reviewer's check stays advisory until its precision on tests has
  been measured; this skill's gate has its own check name and never duplicates the reviewer's
  inline comments ([gate.md](gate.md)).
- **Pre-PR, optional.** If the `greptile` CLI is installed and authenticated, write mode may run
  `greptile review --json` on committed work and send test-related findings through triage.
  Never auto-installed.
- **Measuring the reviewer.** Before letting a reviewer's test comments block anything, replay
  its historical test comments as predicted mutants in an audit and report how often they were
  right.
