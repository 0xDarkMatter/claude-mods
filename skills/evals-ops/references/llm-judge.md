# LLM-as-a-Judge — biases, rubrics, panels, calibration

A judge is a measurement instrument built out of a language model. It is useful, it is
often the only option, and it is biased in documented, reproducible ways. Treat it like an
instrument: know its error modes, calibrate it against a reference, and re-check it when
anything underneath changes.

## Decide whether you need one at all

| Criterion | Evaluator |
|---|---|
| Output must parse / match a schema | `json.loads`, a JSON-Schema validator |
| Exact value, ID, amount, tool name | `==` |
| Contains a required citation / does not contain a banned string | regex |
| Ordering, latency, cost, step count | arithmetic over the trace |
| **Faithfulness to a source** | judge |
| **Policy / tone compliance** | judge |
| **"Is this a reasonable answer to an open question"** | judge |
| **Relative quality of two candidates** | judge (pairwise, with position control) |

Every criterion you move out of the judge and into code removes cost, latency *and*
variance in one edit. Re-audit the rubric periodically — items become codifiable once the
output format stabilises, and nobody goes back to check.

## The bias catalog

### Position bias

In pairwise comparison, judges prefer whichever candidate was presented first — strongly
enough that swapping the order flips a meaningful share of verdicts.

**Mitigations, in order of preference:**

1. **Score absolutely, not pairwise.** Each candidate graded against the rubric alone. Kills
   the bias by construction and makes results comparable across runs.
2. **Both orders, averaged.** If you need pairwise, run A/B and B/A and require agreement.
   Doubles cost; the disagreement rate is itself a useful instability metric.
3. Never accept a single-order pairwise verdict as a gate.

### Verbosity bias

Judges rate longer answers higher regardless of quality. Evidence is heterogeneous — some
models are genuinely quality-sensitive and penalise filler — which is exactly why you must
measure it on *your* judge rather than assume.

**Mitigations:**

- Split the rubric: score *correctness* and *style* separately, and gate on correctness.
- State the anti-bias instruction explicitly ("length is not evidence of quality; an answer
  that is correct and brief scores higher than one that is correct and padded").
- **Probe it.** Correlate judge score against output length on your calibration set. A
  strong positive correlation on cases with equal human scores is the bias, quantified.
  `scripts/judge-calibration.py --verbosity-field length` computes this.

### Self-preference bias

Judges rate outputs from their own model family higher. Fatal when you are comparing models
and using one of the contenders as the judge.

**Mitigation:** judge with a different family from the system under test. If that is
impossible, at minimum report the judge model alongside every score and never compare
scores produced by different judges.

### Scale drift and clustering

1-5 scores cluster (almost everything gets a 4), and the cluster shifts when the judge
model version changes — silently re-baselining your whole history.

**Mitigations:**

- **Binary pass/fail against explicit criteria** wherever the decision is genuinely binary.
  Easier to calibrate, easier to act on, far more stable across model versions.
- **Pin the judge model version** and treat a judge upgrade like a dataset version bump:
  re-baseline, do not compare across it.
- If you need a scale, define each point with a concrete example, not an adjective.

### Other effects worth knowing

| Effect | Note |
|---|---|
| **Sycophancy toward the prompt** | A judge asked "confirm this is correct" confirms. Phrase neutrally, or invert — see `adversarial-verification.md` |
| **Format preference** | Markdown/bulleted answers score above equivalent prose. Normalise formatting before judging where you can |
| **Anchoring on the reference** | Given a reference answer, judges penalise correct-but-different. Say explicitly that alternative correct answers are acceptable |

## Rubric design

The rubric is where most judge quality lives — far more than the model choice.

- **One criterion per question.** A rubric asking "is it accurate, helpful and well-written?"
  returns an unactionable blend. Three separate binary questions return three actionable
  answers.
- **Concrete and checkable.** "Every factual claim appears in the provided source" beats
  "is accurate".
- **Case-specific criteria where possible.** Criteria stored with the golden case
  (`criteria: [...]`) calibrate dramatically better than one global rubric stretched over a
  heterogeneous set.
- **Require reasoning before the verdict.** Chain-of-thought judging (the G-Eval line of
  work) improves human agreement; and the reasoning is what lets you debug a disagreement
  instead of shrugging at it.
- **Demand structured output** — `{"reason": "...", "verdict": "pass"}` — so scoring is
  parseable and the reason is stored, not discarded.
- **Include the failure examples.** Two or three worked examples of what a `fail` looks like
  do more for agreement than a page of prose.

## Panels vs N-identical

Running the same judge three times with the same rubric mostly buys the same bias three
times. It measures the judge's *own* variance — worth knowing once, not worth paying for
every run.

A **panel with distinct lenses** is different in kind: each judge is asked a different
question, so their failure modes do not overlap.

| Shape | Use when |
|---|---|
| Single judge, absolute scoring | Default. Cheapest thing that works |
| N-identical, same rubric | One-off: measure judge variance to set your CI noise floor |
| **Panel, distinct lenses** | The thing can fail in several independent ways (correct? policy-compliant? reproducible?) |
| **Panel, distinct model families** | High-stakes scoring; aggregate by majority to damp single-model bias |

Majority voting across heterogeneous judges measurably improves correlation with human
judgment. It also multiplies cost — reserve it for the scores you gate on.

## Calibration — the step that makes a judge trustworthy

Calibration has gone from nice-to-have to table stakes. The method:

1. **Sample 50-200 cases** from the golden set, stratified across buckets and across the
   judge's own verdicts (include cases it passes *and* fails, or you cannot measure both
   error directions).
2. **Label them by hand.** Same rubric the judge gets. Two humans on a subset gives you a
   human-human ceiling — a judge cannot beat the agreement humans achieve with each other,
   so that number tells you what "good" even means here.
3. **Compute Cohen kappa**, not raw agreement. On an imbalanced set (90% pass) a judge that
   says "pass" unconditionally scores 90% agreement and is worthless; kappa discounts the
   agreement you would get by chance and lands it near zero.

```bash
python3 scripts/judge-calibration.py labels.jsonl --min-kappa 0.6
```

| kappa | Reading |
|---|---|
| >= 0.8 | Strong. Production-ready; safe to gate on with a margin |
| 0.6 - 0.8 | Substantial. Usable, keep it advisory or gate loosely |
| < 0.6 | The rubric is the problem, not the model. Rewrite before spending more on judges |

4. **Read the confusion matrix, not just the headline.** A judge with kappa 0.65 that is
   wrong only in the false-*negative* direction is safe for a gate (it under-passes, never
   over-passes). One with the same kappa that hallucinates passes is not. The two need
   opposite fixes.
5. **Re-calibrate on a schedule** — roughly 50 fresh cases periodically, and *always* after
   a judge model version change or a rubric edit.

## Cross-reference

- Refuting rather than confirming: `adversarial-verification.md`
- Where the labelled cases come from: `golden-datasets.md`
- Turning a calibrated judge into a CI gate: `regression-gating.md`
