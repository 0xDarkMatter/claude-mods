# Eval Taxonomy — outcome, step, trajectory

The three levels an agent can be scored at, what each one catches that the others miss,
and how to pick metrics that survive contact with a non-deterministic system.

## The three levels

### Outcome-level

**Question:** is the final artifact correct?

The cheapest and most defensible level, and the one everybody starts with. SWE-bench
established binary pass/fail on the produced patch as the standard for coding agents; the
same shape works for any agent with a checkable end state — a booking exists, the file
parses, the database row has the right value.

Evaluate deterministically where you can:

```python
assert json.loads(out)["status"] == "confirmed"
assert db.query("SELECT count(*) FROM orders WHERE id=?", oid) == 1
```

**What it misses:** *how* the answer was reached. Which is most of what determines whether
it will be reached again.

### Step-level

**Question:** was this individual action right?

Scored per span: was the right tool chosen, was the argument schema valid, were the
argument *values* correct, did the agent read before it wrote. Step-level scoring is where
you catch the agent that calls `search` five times with near-identical queries, or that
passes a plausible-but-wrong ID.

Most step assertions are deterministic and belong in the blocking tier:

| Assertion | Cost |
|---|---|
| Tool `X` was called at least once | free |
| Every tool call validated against its JSON schema | free |
| No tool called with a value absent from the input context (hallucinated arg) | free |
| Read-before-write ordering held | free |

Reserve a span-level judge for the genuinely fuzzy step questions ("was this a reasonable
query to issue given what the agent knew?").

### Trajectory-level

**Question:** was the *path* sensible?

Scored over the whole nested span tree: sequence, redundancy, loop detection, recovery
after an error, total cost. Two forms:

1. **Reference-trajectory match** — compare against a known-good path. Exact-match is too
   brittle for anything real; use an ordered-subsequence match ("these 4 steps appeared in
   this order, extras allowed") or set-containment on the essential tool calls.
2. **Rubric judge over the trace** — hand the serialized trajectory to a judge with a
   rubric ("did it loop? did it retry the same failing call? did it ask the user something
   it could have looked up?").

Trajectory scores are diagnostics, not gates. A novel correct path scores badly against a
reference and is not a regression.

## The lucky pass

The single argument for scoring more than the outcome. An agent reaches the correct end
state by an accidental route — it guessed an ID that happened to be right, it retried until
a flaky tool succeeded, it hard-coded something that matched this case's expected output.
Outcome-only scoring banks that as a pass. The same case fails next week, and because the
suite was green the whole time, nobody knows when the real breakage started.

**Detection is cheap once you have traces:** a passing case whose trajectory contains a
loop, an error-then-retry, or a tool call with an argument that appears nowhere in the
input is a lucky-pass candidate. Flag them; do not fail on them. A `lucky_pass_suspects`
count trending upward on a green suite is one of the highest-value signals in the harness.

## pass@k vs pass^k

For any non-deterministic agent, a single run per case is a coin flip you are reporting as
a measurement.

| Metric | Definition | What it tells you |
|---|---|---|
| **pass@1** | One run, did it pass | The honest headline number |
| **pass@k** | Any of k runs passed | Ceiling / "is this reachable at all" |
| **pass^k** | *All* k runs passed | Consistency — what production actually experiences |

pass@k flatters. An agent that succeeds 1 time in 4 has pass@4 near 1.0 and is unusable.
**Report pass^k whenever consistency matters** (customer-facing, transactional, anything
where a retry costs the user something). The tau-bench family popularised this framing for
multi-turn tool-using agents and it generalises.

Practical: k=3 is usually enough to expose the difference and cheap enough to run per-PR on
a subset. Run the full k on a nightly, a k=1 pass on every PR.

## Choosing metrics

Start from the failure you actually fear, not from a metrics catalog.

| You fear | Measure | Level |
|---|---|---|
| Made-up facts | Faithfulness: every claim traceable to a retrieved chunk | Outcome (judge) |
| Wrong tool / wrong args | Tool-call accuracy, arg-schema validity | Step (deterministic) |
| Burning tokens | Steps per task, redundant-call rate, cost per case | Trajectory (deterministic) |
| Silent policy violations | Policy-compliance rubric over the trace | Trajectory (judge) |
| Flaky success | pass^3 | Outcome (deterministic, repeated) |
| Broke something that used to work | Failure-replay bucket pass rate | Outcome (deterministic) |

Two rules that save more time than any metric choice:

- **A metric nobody can act on is a metric nobody will maintain.** If a score drops and the
  team cannot name what to change, delete the metric or make it decomposable.
- **Deterministic first.** Every criterion you move from a judge into code removes cost,
  latency, and variance simultaneously. Re-audit periodically: rubric items often become
  codifiable once the output format stabilises.

## Cross-reference

- Dataset construction: `golden-datasets.md`
- Judge design for the fuzzy levels: `llm-judge.md`
- Which of these gate CI: `regression-gating.md`
