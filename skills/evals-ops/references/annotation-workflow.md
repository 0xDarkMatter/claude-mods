# Annotation Workflow — where the human labels come from

`llm-judge.md` says "label 50–200 cases by hand" and moves on. This is that step.
It is the least glamorous part of an eval stack and the one that determines whether
every number downstream means anything.

## The ceiling nobody measures

**A judge cannot beat the agreement two humans achieve with each other.** If your
annotators agree with one another at κ 0.65, a judge scoring κ 0.65 against one of
them is performing *at the human ceiling*, and chasing 0.8 is chasing noise in your
own labels.

So measure the ceiling first:

1. Have **two people independently label the same 30–50 cases**, blind to each
   other.
2. Compute human-human κ (`judge-calibration.py` does not care which rater is
   which — feed it `{"human": rater_a, "judge": rater_b}`).
3. That number is your realistic target, and the diagnosis when it is low.

**Human-human κ below ~0.6 means the rubric is ambiguous, not that your annotators
are bad.** Fix the rubric before labelling another case — every label produced
against an ambiguous rubric is wasted work, and a judge calibrated against it will
inherit the ambiguity as apparent noise.

This step is skipped almost universally, and it is why so many teams conclude "LLM
judges are unreliable" when what they actually have is an under-specified criterion.

## Who labels

| Labeller | Good for | Watch out for |
|---|---|---|
| **The engineer who built it** | Fast bootstrapping, catching obvious breakage | Knows what the system *meant* to do and scores it charitably. Never the sole labeller for a gate |
| **A domain expert** | Anything where correctness is a matter of policy, medicine, law, finance | Scarce and expensive — spend their time on the ambiguous cases, not the obvious ones |
| **A second engineer** | The human-human ceiling measurement | Shares the team's blind spots |
| **Crowdsourced** | High-volume, low-context judgments | Needs a much tighter rubric and gold-standard trap questions |

The practical shape for most teams: **the engineer labels everything, a domain
expert labels the 30 hardest, and the disagreements between them are the most
valuable output of the whole exercise** — each one is either a rubric ambiguity or
a genuine product decision nobody had made yet.

## Sampling: do not label a random slice

A uniform random sample of production traffic is mostly easy cases, and gives you a
calibration set that cannot measure the judge where it matters.

**Stratify across two axes:**

1. **Bucket** — production, replay, adversarial, edge (`golden-datasets.md`).
2. **The judge's own verdict** — include cases it passes *and* cases it fails, in
   meaningful numbers. Sampling only cases the judge failed measures one error
   direction and leaves you blind to false passes, which are the dangerous kind.

Add a third axis where you have one: cases near the judge's decision boundary
(low-confidence, or where a rerun flipped the verdict) are worth several times an
unambiguous case each.

## Running a labelling session

- **Label blind to the judge's verdict.** Showing it first anchors the human onto
  it and inflates apparent agreement — you will measure compliance, not agreement.
- **One criterion at a time, across all cases.** Labelling case-by-case across five
  criteria drifts; labelling criterion-by-criterion keeps the standard fixed.
- **Record the reason, not just the verdict.** A label without a reason cannot be
  audited later, and reasons are what you mine to rewrite an ambiguous rubric.
- **Timebox and batch.** Annotation quality falls off a cliff past ~45 minutes.
  50 cases in two sittings beats 100 in one.
- **Keep an explicit `unsure` option** — and then *do not* let unsure labels vote.
  Forcing a binary on a genuinely ambiguous case manufactures noise that looks like
  judge error. A high unsure rate is a rubric finding.

## Adjudication

Disagreements are the product, not a problem to be averaged away.

1. Both labellers state their reason.
2. Classify the disagreement:
   - **Rubric ambiguity** → rewrite the criterion, add a worked example, re-label
     the affected cases.
   - **Genuine product ambiguity** ("should the agent refuse this?") → escalate. A
     decision gets made, and it becomes a rubric example.
   - **Simple error** → correct it and move on.
3. **Never resolve by majority vote without reading the reasons.** A 2–1 split
   where the minority is right is exactly the case that most improves the rubric.

## Keeping labels fresh

Labels rot in three ways, and each has a different tell:

| Rot | Tell | Fix |
|---|---|---|
| **Judge drift** | κ falls with no rubric change | The judge model version moved. Pin it; re-calibrate |
| **Distribution drift** | Judge κ holds on the calibration set but production complaints rise | The calibration set no longer resembles traffic. Re-sample |
| **Annotator drift** | The same person labels the same case differently months apart | Real, and normal. Include ~10% repeats from earlier sessions to measure it |

That last trick is worth adopting: silently re-include a handful of previously
labelled cases in each session. Intra-annotator agreement below the
inter-annotator ceiling means the standard itself is sliding, and no amount of
judge tuning will fix it.

**Cadence:** re-sample ~50 fresh cases periodically, and *always* re-calibrate on a
judge model change or a rubric edit — both are re-baselining events
(`regression-gating.md`).

## Cost, honestly

At roughly 1–3 minutes per case per criterion, 150 cases × 2 criteria × 2
annotators is around 10–15 person-hours to establish a calibrated judge. That is
the real price, and it is worth naming up front — a team that budgets for "run the
calibration script" and not for the labelling will quietly skip the labelling and
gate CI on an uncalibrated judge.

The saving is that it is mostly one-off. Maintenance is ~50 cases periodically,
which is an hour or two.

## Cross-reference

- What the labels are for: `llm-judge.md`
- Which cases to draw from: `golden-datasets.md`
- The script that consumes them: `scripts/judge-calibration.py`
