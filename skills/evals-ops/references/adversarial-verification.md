# Adversarial Verification — refute, do not confirm

Scoring answers a graded question ("how good is this?"). Verification answers a binary one
("is this finding real?"). The second is where a naive prompt does the most damage, because
agreeing is the path of least resistance for a language model.

## The inversion

Compare two prompts over the same finding:

```
❌  "Is this bug report correct?"
✅  "Try to refute this bug report. Default to refuted if uncertain."
```

The first invites confirmation and gets it — plausible-sounding findings sail through
because nothing in the prompt rewards saying no. The second makes the model argue against
the finding, so a finding only survives if the refutation attempt genuinely fails.

The asymmetry is deliberate: **uncertainty must resolve to "refuted", not "confirmed".** A
verifier that cannot decide has not verified anything, and treating that as a pass is how
plausible-but-wrong results reach a report.

Prompt shape that works:

```
Finding: <claim, with file:line or a concrete reproduction>
Your job is to REFUTE this finding. Look for reasons it is wrong, already
handled elsewhere, unreachable in practice, or based on a misreading.
If you cannot decisively refute it, say so — but default to refuted when
the evidence is ambiguous.
Return {"refuted": true|false, "reason": "..."}.
```

## Majority-refute thresholds

One refuter is a coin flip with an opinion. Run N and take a majority:

| N | Keep the finding if | Character |
|---|---|---|
| 1 | not refuted | Cheap triage only |
| **3** | **at least 2 fail to refute** | The default. Good precision/cost balance |
| 5 | at least 3 fail to refute | High-stakes; noticeably slower |

Tighten toward unanimity when a false positive is expensive (a finding that will be posted
publicly, or acted on automatically); loosen when a false negative is expensive (a security
sweep where missing a real issue costs more than investigating a dud).

Record the vote, not just the verdict — a 2/3 survival is materially weaker evidence than
3/3 and the consumer of the report deserves to know which they have.

## Lens diversity beats redundancy

Three identical refuters share their blind spots: whatever the first one fails to notice,
the other two also fail to notice. Give each refuter a **different lens** and their failure
modes stop overlapping:

| Lens | Asks |
|---|---|
| **Correctness** | Is the described behaviour actually what the code does? |
| **Reachability** | Can this state be reached by any real input, or is it guarded upstream? |
| **Reproduction** | Given the stated inputs, does the described failure actually occur? |
| **Prior art** | Is this already handled — a caller-side check, a test, a framework guarantee? |
| **Security** (where relevant) | Is there an exploit path, or is this only a code smell? |

Same reasoning as judge panels (`llm-judge.md`): diversity finds classes of error that
redundancy structurally cannot.

## Where this fits in a pipeline

The canonical shape — find wide, verify hard, keep little:

```
find (N parallel finders, different angles)
  → dedupe against everything seen so far   ← plain code, not an agent
  → refute (3 diverse lenses per finding)
  → keep majority survivors
  → repeat until K consecutive rounds find nothing new
```

Two details that decide whether this converges:

- **Dedupe against `seen`, not against `confirmed`.** If refuter-rejected findings are not
  added to `seen`, the finders resurface them every round and the loop never terminates.
- **Loop until dry, not until a count.** "Find 10 bugs" stops at 10 whether or not there are
  11; "stop when two consecutive rounds surface nothing new" finds the tail.

The fan-out mechanics — process isolation, worktrees, journals, model selection per stage —
belong to the parallel-work skills, not here. See `fleet-ops` for the landing discipline and
`parallel-ops` as the router for that family. This skill owns the *contract*: what a refuter
is asked, what it returns, and how votes become a verdict.

## Verifier output contract

Keep it small and structured so votes aggregate mechanically:

```json
{"refuted": true,
 "confidence": "high",
 "lens": "reachability",
 "reason": "The caller validates `id` against the allowlist at handler.ts:41 before this path."}
```

- `refuted` boolean, never a score — the whole point is a decisive vote.
- `reason` mandatory and specific. A refutation without a citable reason is an opinion, and
  should be treated as a non-refutation when you audit the run.
- `lens` recorded so you can later ask which lens is earning its cost. Lenses that never
  refute anything across many runs are candidates for removal.

## When not to bother

Adversarial verification costs N× per finding. Skip it when:

- The finding is **mechanically checkable** — run the test, run the type-checker, run the
  query. A deterministic check beats any number of refuters.
- The finding is **cheap to act on and cheap to revert** — a lint fix does not need a
  tribunal.
- You are **scoring quality, not adjudicating truth**. Use a judge (`llm-judge.md`); refuters
  answer a binary question and will flatten a graded one.

## Cross-reference

- Graded scoring instead of binary adjudication: `llm-judge.md`
- Using survival rates as an eval metric over time: `regression-gating.md`
