# Regression Gating — making evals block CI without killing CI

An eval gate has exactly one job: stop a regression from merging. It fails at that job in
two ways — by letting regressions through, and by going red so often that everyone learns
to click merge anyway. The second failure is more common and much harder to reverse.

## The rule

**A blocking check must never be flaky.** Once a team has seen three red-for-no-reason eval
runs, the gate is socially dead even while it is still technically enforced. Design for that
first and for coverage second.

## The tier ladder

| Tier | Checks | Gate | Runs on |
|---|---|---|---|
| **0. Deterministic** | Schema validity, tool-call assertions, exact matches, forbidden strings | **Blocking**, zero tolerance | Every push |
| **1. Judge, uncalibrated** | Any new rubric, first few weeks | **Advisory** — comment the delta, never fail | Every PR |
| **2. Judge, calibrated** | kappa >= 0.6, variance measured | **Blocking with a margin** below rolling baseline | Every PR |
| **3. Consistency** | pass^3 over the full set | **Blocking on the nightly**, advisory on PRs | Nightly |
| **4. Cost / latency** | Tokens and p95 per case | **Blocking on an absolute ceiling**, advisory on trend | Every PR |

Promotion from tier 1 to tier 2 is an explicit decision backed by a calibration run
(`scripts/judge-calibration.py`), not something that happens because a rubric has been
around a while.

## The noise floor

You cannot set a threshold without knowing how much the suite moves when *nothing changes*.

Measure it once, properly: run the unchanged system against the frozen set N times (5 is
usually enough) and record the spread.

```
run 1: 0.88   run 2: 0.85   run 3: 0.89   run 4: 0.86   run 5: 0.88
baseline 0.872,  spread 0.04
```

Then gate **below the baseline by more than the spread**: threshold 0.80, not 0.87. A gate
inside the noise band fails on identical code, which is the fastest possible route to a
dead gate.

Keep it honest over time by committing a **rolling window of run results to git** — a small
JSON file, appended per run on the main branch:

```json
{"date": "2026-08-30", "dataset": "golden-v3", "judge": "<pinned-model-id>",
 "score": 0.871, "pass_at_1": 0.86, "pass_hat_3": 0.79,
 "cost_usd": 2.14, "p95_ms": 4180, "n": 287}
```

That file is what turns "today looks bad" into "today is 2.6 spreads below a stable
baseline" — and it costs nothing. Treating every run as standalone is what makes teams
unable to distinguish noise from regression.

Re-baseline (and say so in the commit) on any of: dataset version bump, judge model change,
rubric edit, or a deliberate accepted trade-off.

```bash
python3 scripts/eval-baseline.py evals/history.jsonl --candidate /tmp/run.jsonl
# prints baseline, noise floor, and the threshold your gate should use
```

## Is the drop real? — the paired test

The noise floor tells you whether an aggregate score moved further than it usually
does. It does **not** tell you whether the same cases moved, and that is the question
you actually care about.

Two runs over the same frozen set produce *paired binary outcomes*, and the right tool
for those is **McNemar's exact test**. It looks only at the discordant pairs:

|  | candidate passes | candidate fails |
|---|---|---|
| **baseline passes** | ignored | **b** — regressions |
| **baseline fails** | **c** — fixes | ignored |

Cases that behaved identically in both runs carry no information about whether the
change helped. Under the null hypothesis b is a coin flip over b+c trials, so the
p-value is a tail probability. Use the **exact** test rather than chi-square: eval
sets routinely produce b+c under 25, where the approximation misleads.

Why this matters more than the aggregate: a change that breaks 8 cases and fixes 7 moves
the headline score by 0.01 - invisible against any noise floor - while having silently
swapped which 15 things work. The paired view names those 15 cases; a score comparison
structurally cannot.

Note carefully what the test does and does not say there. 8-vs-7 gives p = 1.0: genuinely
indistinguishable from chance, and the tool will correctly call it noise. The value in that
run is not the verdict, it is the enumerated `regressed` and `fixed` lists telling you a
churn happened at all. Significance answers "did the system get worse"; the lists answer
"what moved" - and on a flat score only the second question has an answer worth having.

```bash
python3 scripts/eval-baseline.py evals/history.jsonl \
  --baseline-results base.jsonl --candidate-results new.jsonl --alpha 0.05
# exit 10 = significant regression, and it names the cases that flipped
```

Three cautions:

- **Significance is not magnitude.** With a large set, a trivially small real drop
  reaches p < 0.05. Read the count of regressed cases, not only the p-value.
- **Don't run the test repeatedly until it agrees with you.** Testing every PR against
  the same baseline is many comparisons; treat a single surprising red as a prompt to
  look at the named cases, not as proof on its own.
- **k > 1 breaks the pairing** unless you collapse each case to one outcome first
  (pass^k is the usual choice). Feed the collapsed per-case result, not every run.

## CI shape

A workable three-tier cadence:

| Trigger | Scope | Budget | Gate |
|---|---|---|---|
| **Every push** | Deterministic assertions on the full set | seconds, $0 | Blocking |
| **PR** | Judge metrics on a stratified ~30% subset, k=1 | a few minutes | Per tier ladder |
| **Nightly on main** | Full set, k=3, cost and latency recorded, appended to the history file | whatever it costs | Blocking; page on a real drop |

Notes that matter in practice:

- **Pin everything the score depends on** — judge model version, dataset version, prompt
  version, temperature (0 for the judge). An unpinned judge model is a silent
  re-baselining that will be blamed on your code.
- **Cache aggressively.** Eval runs re-send near-identical prompts; caching the static
  prefix cuts the bill substantially and does not change scores.
- **Report the delta, not the absolute.** "-0.04 vs main (noise floor 0.03)" is actionable;
  "0.83" is not.
- **Name the failing cases in the CI output.** A gate that says "score dropped" without
  listing which 6 cases flipped forces a local re-run and gets ignored.
- **Never auto-retry a failing eval to green.** Retry-until-pass converts a real regression
  into a flake report. If you retry, report all attempts.

## Cost and latency attribution

Record per case, from day one:

| Field | Why |
|---|---|
| `tokens_in` / `tokens_out` | The unit you actually pay for; also the best proxy for context bloat |
| `ms` (wall) and step count | p95 latency is a product requirement, and step count catches loops |
| `cost_usd` | Roll up per run so a "small" prompt change that doubles spend is visible immediately |
| `model` / `judge_model` | Attribution is meaningless if you cannot tell which model produced the number |

Two reasons this is not optional. First, an eval suite is the only place you learn that the
accuracy win cost 4x the tokens — production tells you eventually, and much more expensively.
Second, retrofitting attribution once the harness exists means touching every runner, every
stored result and every dashboard; adding four fields at the start costs nothing.

Gate on an **absolute ceiling** (cost per case must not exceed $X, p95 must not exceed Y ms)
rather than on the trend. Trend gates fire on noise; ceilings encode a product decision.

## Failure modes to design against

| Failure | Symptom | Fix |
|---|---|---|
| Flaky blocking judge | Reds nobody investigates | Demote to advisory until calibrated; widen the margin past the noise floor |
| Threshold inside the noise band | Identical code fails intermittently | Measure the spread; gate below baseline minus spread |
| Saturated suite | Green for months, then a production incident | The set stopped measuring — harvest harder cases (`golden-datasets.md`) |
| Confounded comparison | Score moved and nobody knows why | Version the dataset; never compare across versions |
| Judge upgrade drift | Step change in scores with no code change | Pin the judge; re-baseline explicitly on upgrade |
| Test-fitting | Cases edited in the same commit as the prompt | Enforce in review: dataset changes land separately |

## Cross-reference

- Case supply and freezing: `golden-datasets.md`
- Getting a judge to kappa >= 0.6 so it can be promoted to blocking: `llm-judge.md`
- Which metric belongs in which tier: `eval-taxonomy.md`
