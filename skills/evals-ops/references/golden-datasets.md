# Golden Datasets — build it, freeze it, keep it from rotting

The golden set is the most valuable artifact in an eval stack. The model, the prompt and
the framework will all be replaced; the dataset outlives them and is the only thing that
lets you compare across the replacements.

## What it is

A **reviewed, versioned, frozen** set of inputs paired with trusted expected outputs (or
trusted grading criteria, where the output is open-ended). "Reviewed" means a human agreed
the expected output is right. "Versioned" means it lives in git next to the code. "Frozen"
is the part teams skip and then regret.

## Why frozen beats growing

A set that grows every sprint cannot answer the only question a regression suite exists to
answer: *did my change make things worse?* If the score moved from 0.84 to 0.79 and the set
gained 30 cases, the two variables are confounded and no amount of analysis separates them.

The discipline:

- **Freeze v1.** Tag it. Every run reports against a named dataset version.
- **New cases go to a staging set** and are promoted in explicit, dated batches.
- **On promotion, re-baseline** — run the current system against v2 and record the new
  reference number. Never compare a v1 score to a v2 score.
- **Never edit a case in place to make it pass.** That is fitting the test to the code. If
  a case's expected output was genuinely wrong, delete it and add a new one with a note.

Ship a freeze manifest so drift is detectable rather than discovered:

```bash
python3 scripts/goldenset-audit.py golden.jsonl --write-freeze manifest.json  # at freeze
python3 scripts/goldenset-audit.py golden.jsonl --freeze manifest.json        # in CI
```

## Four-bucket composition

A set sampled only from happy-path production traffic tells you nothing about the failures
you will actually ship. Build it in four deliberate buckets and record the bucket on every
case.

| Bucket | Target share | Source | Catches |
|---|---|---|---|
| `production` | 40-50% | Stratified sample of real traffic | Drift on the common path; keeps the score meaningful |
| `replay` | 20-30% | Every incident that reached a human | Regressions on things that already broke once |
| `adversarial` | 15-20% | Injections, contradictory instructions, refusal-bait, out-of-scope asks | Silent policy failures; the class judges also fail on |
| `edge` | 10-15% | Empty, enormous, ambiguous, multilingual, malformed | Where deterministic code breaks first |

Those are **targets to compose against**, not thresholds. `goldenset-audit.py` warns on a
deliberately wider band (production 30-65%, replay 10-40%, adversarial 8-35%, edge 5-30%)
and names the target in the warning, because a check that fires on every healthy set gets
ignored within a week - the same rule this skill applies to CI gates. Hitting the target is
good practice; leaving the band is a finding.

**The replay bucket is the easiest to justify and the most neglected.** Every production
incident is a free, pre-validated, maximally relevant test case. Make "add the replay case"
a step in the incident checklist and the bucket fills itself.

Watch the balance: buckets skew over time because production sampling is easy and
adversarial authoring is not. A set that has become 90% `production` has quietly stopped
testing the things that break. The audit script flags this.

## Sizing

| Stage | Size | Note |
|---|---|---|
| Bootstrapping | 20 | Hand-written, eyeballable. Do this before choosing a metric. |
| Working regression set | 100-300 | Enough to move a percentage meaningfully; cheap enough to run per PR |
| Mature, production-sampled | 200-500 | The common steady state for a real product |
| Judge calibration subset | 50-200 human-labelled | Separate purpose — see `llm-judge.md` |

Past ~500 you are usually buying latency, not signal. Add cases when a **new failure class**
appears, not on a cadence. If two cases fail and pass together every time, one of them is
free to delete.

Cost check: at 300 cases × 3 runs (pass^3) × $0.01/case you are spending ~$9 a run. That is
fine nightly and painful on every push — which is why the PR tier runs a subset. See
`regression-gating.md`.

## Case schema

Nothing exotic. JSONL, one case per line, in git:

```json
{"id": "refund-partial-001",
 "bucket": "replay",
 "added": "2026-03-14",
 "why": "INC-482: agent refunded full amount on a partial-return request",
 "input": {"messages": [{"role": "user", "content": "..."}]},
 "expected": {"tool": "issue_refund", "args": {"amount": 24.99}},
 "criteria": ["refund amount matches the returned item only",
              "does not promise a timeline the policy does not state"]}
```

The fields that matter and get omitted:

- **`why`** — the reason this case exists. Without it, a future maintainer deletes cases
  they cannot interpret, and the set silently loses its adversarial teeth.
- **`added`** — dates are how you detect a set that stopped growing in 2025.
- **`bucket`** — without it you cannot see the balance drifting.
- **`criteria`** — for open-ended outputs, the grading rubric belongs *with the case*, not
  in a global judge prompt. Case-specific criteria are dramatically easier to calibrate.

## Rot, and how it shows up

| Rot | Symptom | Fix |
|---|---|---|
| **Duplicates / near-duplicates** | Score moves in suspiciously large jumps | Dedupe on normalised input; audit script flags exact and high-overlap pairs |
| **Bucket skew** | Adversarial pass rate stops moving | Rebalance; author new adversarial cases |
| **Staleness** | Newest `added` date is months old | Wire the incident checklist; sample fresh production traffic |
| **Saturation** | Score pinned at 1.0 for weeks | The set is too easy. Harvest harder cases from production; a saturated set detects nothing |
| **Contamination** | Score jumps on a model upgrade with no code change | Public benchmark cases leaked into training. Prefer private, product-specific cases |
| **Test-fitting** | Cases edited in commits that also change the prompt | Enforce in review: dataset changes land in their own commit |

Saturation deserves emphasis: a suite that always passes is not a passing suite, it is a
suite that has stopped measuring. Track the *distribution* of per-case results, not just the
mean, and retire-and-replace cases that have not failed in months.

## Synthetic cases

Useful for edge and adversarial coverage, dangerous as the backbone. Synthetic inputs
generated by the same model family you are testing inherit its blind spots — it will not
generate the phrasing it does not understand. Use synthetics to *expand* a bucket around a
real failure ("give me 10 variants of this injection"), never to found one.

Always human-review synthetic expected outputs before promotion. An unreviewed synthetic
case is a hypothesis, not a golden case.

## Cross-reference

- What to score these cases on: `eval-taxonomy.md`
- Grading the open-ended ones: `llm-judge.md`
- Running them in CI: `regression-gating.md`
