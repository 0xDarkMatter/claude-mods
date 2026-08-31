# Hillclimbing — optimising against an eval without destroying it

> **Verified 2026-08.** The optimizer landscape below moves fast. Method names,
> reported numbers and library APIs need re-verification before you quote them.

Once you have a measurable harness, the obvious next move is to optimise against it:
change something, measure, keep if better, repeat. That loop works, and it is also the
single most reliable way to turn a good eval suite into a useless one.

**This file owns the discipline. It does not own the loop.** The loop mechanics — scope,
verify command, keep/discard, batch with bisect-on-regression, stop conditions, git as
memory — belong to the [`iterate`](../../iterate/SKILL.md) skill, which is domain-agnostic
and does not care whether your metric is test coverage or an eval score. Read that for
*how to run* the loop; read this for *what goes wrong* when the metric is an eval.

## The two failure modes

### 1. Banking noise

`iterate` keeps a change when the metric beats the previous best. With a deterministic
metric (line coverage, bundle bytes) that rule is exactly right. With an eval score it is
a coin flip dressed as a decision.

If your suite scores 0.88 ± 0.03 across reruns of *unchanged code*, then a change that
measures 0.90 has told you almost nothing. Keep it anyway and you have banked noise. Do
that fifty times overnight and you have executed a random walk with perfect discipline,
and the winning commit is whichever iteration got luckiest.

**The rule: a hillclimb step is only real if the delta clears the noise floor.**

```bash
python3 scripts/eval-baseline.py history.jsonl --candidate iter.jsonl --accept
# exit 0  = KEEP   (improvement clears the floor, or is significant on the paired test)
# exit 10 = DISCARD (inside the noise band, or a regression)
```

`--accept` inverts the usual exit semantics on purpose — see the script header. Wire it as
the keep/discard gate and the loop stops rewarding luck.

Two cheap amplifiers, when you can afford them:

- **Increase k before increasing iterations.** Three runs per candidate shrinks the noise
  floor and is usually a better spend than three times as many candidates evaluated once.
- **Paired comparison beats aggregate comparison.** Which specific cases flipped is far
  more informative than a delta of 0.01, and it is free once you store per-case results
  (`regression-gating.md`).

### 2. Overfitting the golden set

This one is slower, quieter, and permanent. Every look at the same frozen set leaks a
little information into your decisions. Optimise against it for long enough and you have
tuned the system to that specific 300 cases — Goodhart's law arriving exactly on schedule.

It is not hypothetical in the optimizer literature: **GEPA is documented to overfit by
encoding edge cases into increasingly verbose prompts**, because its reflection step
accumulates detail across iterations and nothing pushes back. Length constraints act as
regularisation there, which is a good general instinct: an optimizer with no pressure
toward simplicity will buy training score with complexity.

**Split the data before you optimise anything:**

| Split | Used for | Rule |
|---|---|---|
| **Train / reflect** | What the optimizer sees and reasons about | Look freely. This is the set you burn |
| **Validation** | Choosing between candidates each round | Scored every round; never shown to the optimizer's reflector |
| **Held-out test** | The number you actually report | Touch at milestones only. Every look costs you |

GEPA's own design makes the second row explicit: it reserves a disjoint validation subset
whose inputs and outputs are **never shown to the reflector model**. Adopt that separation
even when hand-rolling — the moment the thing proposing changes can read the set that
judges them, your validation score stops being evidence.

**The held-out set is a budget, not a dashboard.** Decide up front how often you may look
(a milestone, a release, once a week) and hold to it. A team that checks held-out every
iteration has three sets and one of them is a validation set wearing a disguise.

**Tells that you are overfitting:**

- Train score climbs; validation is flat. The classic.
- Validation climbs; held-out is flat. You are now overfitting the validation set.
- The system prompt or config grows monotonically, each addition patching one case.
- Wins stop transferring — a change that helped on the suite does nothing in production.

## Keep a frontier, not a champion

`iterate` maintains `iterate/best`: a single floating tag on the highest-metric commit.
For a scalar mechanical metric that is correct and simple. For an eval score it is a
local-optimum trap, because one aggregate number hides which *cases* a candidate won.

GEPA's central design choice is the alternative: **maintain a Pareto frontier** — retain
every candidate that is best on at least one validation instance, and sample from that
frontier rather than always mutating the current champion. A candidate that scores lower
overall but is the only one solving a hard case carries information the champion does not,
and discarding it is how a hillclimb walls itself into a local optimum.

Cheap approximation without any framework: alongside the best-overall commit, keep a note
of **which candidate best solved each failing case**. When the loop stagnates, mutate from
one of those instead of from the champion.

## Rich feedback beats a scalar reward

The most transferable finding in this line of work: **collapsing an evaluation to a number
throws away the signal an optimizer needs.** GEPA reflects in natural language over
execution traces — error messages, reasoning logs, why the case failed — and reports
outperforming MIPROv2 by roughly 10–13% and the RL baseline GRPO by ~6% on average (up to
20%) across six tasks, **using up to 35× fewer rollouts**. It is sample-efficient enough to
work from as few as 10 examples and 20–100 evaluations.

The number to take from that is not the benchmark delta, which will age. It is the
mechanism: a failure that explains itself is worth many failures that only score.

**This is an eval-design consequence, and it is why it lives in this skill.** If your judge
returns `0.4`, an optimizer has nothing to reflect on. If it returns
`{"reason": "cited chunk 12, which does not contain the refund window", "verdict": "fail"}`,
it has a diagnosis. `assets/judge-rubric.template.md` already demands `reason` alongside
`verdict` — that field is what makes hillclimbing tractable later, and it costs nothing to
add now. Same for per-case traces: store them, or you cannot reflect on them.

## The optimizer landscape

Families rather than products, since the products churn:

| Family | Mechanism | Note |
|---|---|---|
| **Reflective / evolutionary** (GEPA) | Natural-language reflection over traces; Pareto frontier over candidates | Sample-efficient; available in DSPy as an optimizer and standalone. Documented verbosity-overfit failure mode |
| **Bayesian / few-shot search** (MIPROv2) | Proposes instructions and demonstrations, searches the joint space | The prior DSPy default; the baseline GEPA is measured against |
| **Generate–score–select** (APE) | Generate candidate prompts, score on validation, keep the best | Simplest thing that works; a fine hand-rolled starting point |
| **Iterative self-rewrite** (ORPO and kin) | The model rewrites its own prompt guided by feedback on prior outputs | Needs a feedback signal richer than a score |
| **Self-contained preference loops** (SPO) | Generates its own data, refines by pairwise preference over its outputs | Removes the external-label dependency — and with it, your ground truth. Treat results with suspicion |
| **Scaffold-level** | Memory evolution, tool governance, whole-harness redesign | The wider "self-improving agent" framing; prompt optimization is one lever among several |

**When it helps is a live research question, not a settled one.** There is published work
specifically asking *when* prompt optimization improves multi-agent systems — the framing
implies the honest answer is "sometimes". Do not assume an optimizer will beat a careful
human rewrite on your task; measure it, on held-out, like anything else.

## Before you automate the loop

- [ ] A frozen golden set with train / validation / held-out splits (`golden-datasets.md`).
- [ ] A measured noise floor, from reruns of unchanged code (`regression-gating.md`).
- [ ] A calibrated judge, if a judge is in the metric (`llm-judge.md`). An uncalibrated
      judge in a hillclimb optimises the system toward the judge's biases, at speed.
- [ ] Per-case results and reasons stored, not just an aggregate.
- [ ] A stated held-out look budget, and a stop condition.
- [ ] A cost ceiling. Optimizer loops are the easiest way to spend a month of eval budget
      in an afternoon.

If any of those is missing, fix it before running the loop. A hillclimb amplifies whatever
your measurement already is — including its errors.

## When this should become its own skill

Kept here because it is currently one file, and the creation protocol says extend rather
than duplicate. **Extract it to a `prompt-optimization-ops` skill when the optimizer
material outgrows this page** — concretely, when it needs its own worked DSPy/GEPA
configuration, more than a couple of runnable scripts, or per-optimizer troubleshooting.
The discipline sections above (splits, noise floor, frontier, held-out budget) stay here
regardless: they are properties of the measurement, and this skill owns measurement.

## Cross-reference

- Loop mechanics, stop conditions, bisect-on-regression: [`iterate`](../../iterate/SKILL.md)
- Scheduling a loop across sessions, risk tiers, kill switch: [`loop-ops`](../../loop-ops/SKILL.md)
- Splits and freeze discipline: `golden-datasets.md`
- Noise floor and the paired test: `regression-gating.md`
- Why a judge must be calibrated before it steers anything: `llm-judge.md`
