# Judge Rubric — template

Copy per criterion. **One criterion per rubric**, one rubric per judge call. A
rubric asking "is it accurate, helpful and well-written?" returns an unactionable
blend; three separate binary questions return three actionable answers.

Adapt everything in `<angle brackets>`. Delete the guidance comments before use.

---

## Metadata (keep with the rubric, in git)

| Field | Value |
|---|---|
| Criterion name | `<faithfulness>` |
| Judge model | `<pinned-model-version>` — never "latest" |
| Temperature | `0` |
| Output | binary `pass` / `fail` |
| Rubric version | `<v1>` — bump on any edit, and re-baseline |
| Calibrated | `<kappa, date, n>` — from `judge-calibration.py` |

> A rubric edit is a re-baselining event, exactly like a judge upgrade or a
> dataset version bump. Scores across the boundary are not comparable.

---

## The prompt

```
You are grading one criterion. Answer only about this criterion; ignore every
other quality of the response.

CRITERION
<Every factual claim in the response appears in the SOURCE below.>

<!-- Concrete and checkable. "is accurate" is not a criterion, it is a mood. -->

SOURCE
<<<
{source}
>>>

RESPONSE
<<<
{response}
>>>

RULES
- Length is not evidence of quality. A correct, brief response scores the same
  as a correct, padded one.
  <!-- verbosity-bias counter; measure whether it works with
       judge-calibration.py --verbosity-field -->
- Style, tone and formatting are NOT part of this criterion.
  <!-- separates correctness from style so the gate rides on correctness -->
- Alternative correct answers are acceptable. Do not penalise a response for
  differing from any reference you may infer.
  <!-- anchoring counter -->
- If the evidence is genuinely ambiguous, answer "fail" and say why.
  <!-- forces uncertainty to resolve one way, deliberately; pick the direction
       that is safe for YOUR gate -- see the note below -->

EXAMPLES
pass: <a short worked example of a response that satisfies the criterion>
fail: <a short worked example that plausibly looks fine but does not>
fail: <a second failing example covering a different failure mode>
<!-- two or three worked failures do more for agreement than a page of prose -->

Think through the evidence first, then answer.
Return JSON only: {"reason": "<one sentence citing the specific evidence>",
                   "verdict": "pass" | "fail"}
```

---

## Which way should ambiguity resolve?

Decide deliberately, per criterion, and write it down:

| Gate consequence | Resolve ambiguity to |
|---|---|
| A false pass ships a bug | `fail` — under-passing is safe; the judge only over-reports work |
| A false fail blocks a good PR and erodes trust in the gate | `pass`, and keep the metric advisory until κ improves |

Read the direction off the confusion matrix after calibration, not off intuition:
a judge at κ 0.65 that errs only toward `fail` is gateable; the same κ erring
toward `pass` is not.

---

## Before this rubric gates anything

1. Sample 50–200 cases, stratified across buckets **and across the judge's own
   verdicts** — include cases it passes and cases it fails, or you can only
   measure one error direction.
2. Label them by hand against this exact rubric.
3. `python3 scripts/judge-calibration.py labels.jsonl --min-kappa 0.6`
4. Below 0.6, the rubric is the problem. Rewrite the criterion or add worked
   failure examples — do not reach for a bigger judge model.
5. Record κ, n and the date in the metadata table above.
