---
name: evals-ops
description: "Build and run evals for LLM and agent systems: golden datasets, LLM-as-a-judge with bias control, trajectory/step/outcome scoring, adversarial refuters, and CI regression gates. Triggers on: eval, evals, eval harness, golden dataset, golden set, LLM-as-a-judge, judge rubric, judge bias, judge calibration, Cohen kappa, agreement with human labels, pass@k, pass^k, trajectory eval, step-level eval, tool-call accuracy, regression gate, eval CI, blocking vs advisory eval, faithfulness score, DeepEval, Braintrust, Opik, Langfuse, AgentOps, did my prompt change make it worse, is my agent getting better."
license: MIT
metadata:
  author: claude-mods
  related-skills: "testing-ops, claude-api-ops, iterate, fleet-ops"
---

# Evals Ops

**Evals are the prerequisite, not the polish.** You cannot tune a prompt, a retriever, a
compaction strategy or a memory layer without a harness that says whether the change made
things better. Teams that skip this ship vibes and learn about regressions from users.

This skill is the operational layer: what to measure, how to build the dataset, how to
make a judge trustworthy, and how to gate CI on it without teaching everyone to ignore red.

## Route first

| The ask | Go to |
|---|---|
| "What should I even measure?" | [Three levels](#three-levels-of-agent-eval) → `references/eval-taxonomy.md` |
| "Where do the test cases come from?" | [Golden set](#the-golden-set) → `references/golden-datasets.md` |
| "My judge disagrees with me / is it any good?" | [Judges](#llm-as-a-judge) → `references/llm-judge.md` |
| "Verify a finding is real, not plausible" | [Refuters](#adversarial-verification) → `references/adversarial-verification.md` |
| "Should this block the merge?" | [Gating](#regression-gating) → `references/regression-gating.md` |
| "Which platform should we use?" | `references/tooling-landscape.md` |

## The 60-second version

1. **Write 20 cases before you write a metric.** A dataset you can eyeball beats a metric
   you cannot interpret. Grow to 100-300, then *freeze* it.
2. **Prefer a deterministic assertion to any judge.** The JSON parsed, the tool was called
   with the right argument, the query returned 3 rows - free, instant, zero variance.
   Reach for a judge only where correctness is genuinely a matter of language.
3. **Score the trajectory, not just the answer.** Most teams only check the final artifact
   and are surprised when a right answer came from a wrong path that breaks tomorrow.
4. **Calibrate the judge against humans before trusting it.** Cohen kappa, not raw
   agreement. `scripts/judge-calibration.py` does the arithmetic and the verdict.
5. **Blocking gates must be deterministic. Judge metrics start advisory.** One flaky red
   permanently devalues the signal.

## Three levels of agent eval

Most teams do only the third, then wonder why quality is unpredictable.

| Level | Question | Signal | Typical evaluator |
|---|---|---|---|
| **Outcome** | Is the final artifact correct? | Binary or scored end state | Deterministic assertion, unit test, judge |
| **Step** | Was *this* tool call right? | Per-span: tool choice, arg shape, arg values | Schema/argument assertion, span-level judge |
| **Trajectory** | Was the *path* sensible? | Sequence, loops, redundancy, cost | Reference-trajectory match, rubric judge |

The failure that motivates all three: an agent reaches the right end state by an accidental
route - the *lucky pass*. Outcome-only scoring records that as a win, and the same case
fails next week when the accident does not recur. Conversely a trajectory-only score
punishes a legitimately novel-but-correct path. **Gate on outcome; keep step and trajectory
as the diagnostics that tell you why the gate moved.**

For multi-turn or stateful agents also report **pass^k** (all k independent runs of the same
case succeed) alongside **pass@k** (any of k succeeded). pass@k flatters a non-deterministic
agent; pass^k is the number that predicts production. Full treatment:
`references/eval-taxonomy.md`.

## The golden set

A golden set is a **reviewed, versioned, deliberately frozen** collection of inputs with
trusted expected outputs. Frozen matters: a set that grows every sprint cannot tell you
whether last week's number moved because the system changed or because the set did.

**Composition - four buckets, not one:**

| Bucket | Source | Why |
|---|---|---|
| Production sample | Real traffic, stratified | Keeps the score connected to what users actually do |
| Failure replays | Every incident that reached a human | Regression protection; the easiest cases to justify |
| Adversarial | Injections, contradictions, refusal-bait | The class both agents and judges fail silently on |
| Edge cases | Empty, huge, ambiguous, multilingual | Where deterministic code breaks first |

**Sizing:** 20 to start, 100-300 for a working regression set, 200-500 once you have
production traffic to sample. Beyond that you are usually buying latency, not signal - add
cases when a new *failure class* appears, and record in the case itself why it exists.

`scripts/goldenset-audit.py` checks a set for the rot that accumulates: duplicates, a
bucket that quietly became 90% of the set, undated cases, and drift from a frozen manifest.

```bash
python3 scripts/goldenset-audit.py evals/golden.jsonl --json | jq '.data.findings[]'
```

Depth: `references/golden-datasets.md`.

## LLM-as-a-judge

A judge is a measurement instrument. Instruments need calibration, and this one has
documented, reproducible biases:

| Bias | What it does | Mitigation |
|---|---|---|
| **Position** | Prefers whichever candidate was shown first | Run both orders and average; or score absolutely, not pairwise |
| **Verbosity** | Rates longer answers higher regardless of quality | Separate correctness from style in the rubric; penalise unsupported length |
| **Self-preference** | Rates its own model family's output higher | Judge with a different family than the one under test |
| **Scale drift** | 1-5 scores cluster and shift between model versions | Binary pass/fail against explicit criteria; pin the judge model version |

**Panel vs N-identical.** Three calls to the same judge with the same rubric mostly buys the
same bias three times. A **panel with distinct lenses** - one asks "is this supported by the
source?", one "does it follow the stated policy?", one "would this reproduce?" - finds
failure modes redundancy structurally cannot. Use N-identical only to measure the judge's
own variance, which is a different question worth asking once.

**When a judge is the wrong tool:** if you can express the criterion as code, do. A judge
costs money, adds latency, drifts across model versions, and has variance a regex does not.
Judges earn their place on faithfulness, tone, policy compliance, and "is this a reasonable
answer to an open question" - nowhere else.

**Calibrate before you trust.** Label 50-200 cases by hand, run the judge on the same cases,
and compute Cohen kappa (raw agreement lies when classes are imbalanced):

```bash
python3 scripts/judge-calibration.py evals/labels.jsonl --min-kappa 0.6
# exit 0 = calibrated;  exit 10 = below threshold, fix the rubric before shipping it
```

kappa >= 0.8 production-ready - 0.6-0.8 substantial, usable with care - below 0.6 the rubric
is the problem, not the model. Re-sample ~50 fresh cases periodically; judges drift when the
underlying model version moves. Depth, including bias-probe design: `references/llm-judge.md`.

## Adversarial verification

For findings rather than scores - bug reports, audit results, review comments - flip the
prompt: **ask the verifier to REFUTE, not to confirm.** "Try to refute this finding; default
to refuted if uncertain" kills plausible-but-wrong results that an "is this correct?" prompt
waves through, because agreement is the path of least resistance for a model.

Then take a majority: run 3 refuters, keep the finding only if at least 2 fail to refute it.
Prefer **perspective-diverse** refuters (correctness / security / does-it-actually-reproduce)
over three identical skeptics - same reasoning as judge panels.

This composes with the parallel-work skills rather than duplicating them: `fleet-ops` and
`parallel-ops` own the fan-out mechanics; this skill owns the scoring contract the refuters
return. See `references/adversarial-verification.md`.

## Regression gating

The rule that keeps a gate alive: **a blocking check must never be flaky.**

| Check | Gate |
|---|---|
| Deterministic assertions (schema, tool-call, exact match) | **Blocking.** Any failure fails CI. |
| Judge metrics, first few weeks | **Advisory.** Post the delta as a PR comment. |
| Judge metrics, calibrated (kappa >= 0.6) and variance-measured | **Blocking with a margin** below the rolling baseline |
| Cost and p95 latency per case | **Blocking on a ceiling**, advisory on the trend |

Set the threshold *below* the baseline by more than the measured noise floor: if the suite
scores 0.88 +/- 0.03 across reruns, gate at 0.80, not 0.87. You cannot know the noise floor
from a single run - commit a rolling window of run results to git and read the variance off
it. That committed history is also what distinguishes "today is noisy" from "today broke".

Attribute **cost and latency per eval run** from the start. An eval suite is the only place
you find out the accuracy win cost 4x the tokens, and retrofitting attribution after the
harness exists is far more annoying than a `tokens_in` / `tokens_out` / `ms` field per case.
Full CI shape and the noise-floor method: `references/regression-gating.md`.

## Tooling

Trace-level observability and eval scoring have converged into the same products - you are
picking one system, not two. Open-source cores worth knowing: DeepEval (pytest-native),
MLflow (tracing, eval and prompt versioning in one OSS platform), Opik, Langfuse, Arize
Phoenix. Commercial-first: Braintrust (dataset curation for non-engineers), AgentOps,
LangSmith, Arize.

Honest default: **start with a JSONL file and a 40-line runner.** Adopt a platform when you
need shared dataset curation, trace search across production traffic, or scheduled runs -
not before. Which-one-when: `references/tooling-landscape.md`.

> The landscape moves fast. Treat every version, price and feature claim in that reference
> as needing re-verification; it carries a datestamp for exactly that reason.

## Scripts

| Script | Use |
|---|---|
| `scripts/judge-calibration.py` | Judge-vs-human agreement: Cohen kappa, confusion matrix, per-class breakdown, verbosity/position bias probes. Exit 10 = below `--min-kappa`. |
| `scripts/goldenset-audit.py` | Golden-set health: duplicates, bucket balance, staleness, freeze-manifest drift. Exit 10 = findings. |

Both accept `--help` and `--json`, and are offline and stdlib-only.

```bash
python3 scripts/judge-calibration.py labels.jsonl --json | jq '.data.kappa'
python3 scripts/goldenset-audit.py golden.jsonl --freeze manifest.json
```

## References

- `references/eval-taxonomy.md` - outcome/step/trajectory, lucky pass, pass@k vs pass^k, metric selection
- `references/golden-datasets.md` - building, four-bucket composition, sizing, freeze discipline, rot
- `references/llm-judge.md` - bias catalog and mitigations, rubric design, panels, calibration method
- `references/adversarial-verification.md` - refute-not-confirm, majority thresholds, lens diversity
- `references/regression-gating.md` - blocking vs advisory, noise floor, CI shape, cost/latency attribution
- `references/tooling-landscape.md` - platform comparison with verification datestamps
