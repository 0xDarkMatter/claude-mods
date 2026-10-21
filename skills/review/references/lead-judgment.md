# Lead Judgment

The pass that turns reviewer output into a review (SKILL.md Step 6). Reviewers are asked to
find problems, so they report some whether or not the change has any. The lead is the
session running `/review`: it can read the whole repo, it holds the stated intent, and it
decides what each finding is worth before anything reaches the user. It is a filter with
opinions, not a relay that forwards every line.

## Contents

- Intent first
- The four buckets
- Checking a finding before it is act on
- Dismissal reasons
- Calibration: too many, too few, none
- Severity and bucket
- Second reviewer (optional)
- Output

## Intent first

Before any reviewer runs, write down what the change is for in one or two sentences.
Sources, in order: the PR body, the commit messages, what the user asked for, then the diff
itself. Mark an intent that only the diff supports as *inferred*. If the sources disagree,
or the purpose is unclear and the session is interactive, ask the user before reviewing.

Every reviewer gets the same statement. Their job is to test whether the change achieves it,
not to argue with the goal. A doubt about the goal is not a defect in the change: it can go
to Consider, labelled as a question about the goal, and no further.

## The four buckets

Every finding lands in exactly one bucket, naming the reviewer behind it and giving a
single-line reason.

| Bucket | Meaning | Where it goes |
|---|---|---|
| **Act on** | A defect the lead has confirmed, in correctness, security, data safety or maintainability, judged against the intent. A careful maintainer would not merge with it. | The verdict, and a task (TaskCreate) |
| **Consider** | Real, but fixing it now may cost more than it saves; or plausible and not yet confirmed. The user decides. | The review, with the tradeoff or the check that would settle it |
| **Noted** | True, but not worth action at this stage: low impact, speculative performance, an old issue beside the change. | One line each |
| **Dismissed** | Wrong, out of scope, a matter of taste, or written without the context the lead has. | One line each, with its reason |

Dismissed findings stay in the report. Dropping them silently hides what the reviewers
raised and leaves nobody able to audit the filter.

## Checking a finding before it is act on

A reviewer sees a diff; the lead can open the rest of the repo. Before a finding is act on:

1. **Find the real path.** "This breaks if `user` is null" needs a caller that can pass
   null. Read the call sites, the types and any validation upstream. With no such path the
   finding is hypothetical: dismiss it as unreachable.
2. **Compare with the codebase.** A pattern used the same way throughout the repo is a
   convention, not a defect this change introduced.
3. **Check the scope.** Code the change did not touch is out of scope, unless the change
   makes it newly reachable or newly wrong.
4. **Apply the merge test.** If a careful maintainer would merge without the fix, the
   finding is Consider or Noted, whatever severity the reviewer gave it.

Lean the other way for security and correctness. Before dismissing one, trace the path
yourself. If you can neither confirm nor rule it out, it is Consider with the check that
would settle it, never Dismissed. A finding two independent reviewers raised needs a
concrete reason before it is dismissed.

## Dismissal reasons

A small vocabulary keeps reasons comparable from one review to the next. Name one, then
the specifics (`unreachable: requireUser() throws before line 58`).

| Reason | Use when |
|---|---|
| unreachable | No real caller or input produces the failure |
| preference | It proposes another approach but shows no concrete defect in this one |
| convention | The code follows the codebase's established pattern |
| out of scope | The change neither touched the code nor made it reachable |
| premature | An abstraction, option or optimisation for a need that does not exist yet |
| misread | The reviewer misread the code; say what it missed |
| duplicate | Same issue as another finding; merged into that one |

## Calibration: too many, too few, none

- **More than about five act-on items means the filter is too loose.** Re-apply the merge
  test to each and demote what would not block. If more than five still stand, the change is
  not ready or is too large to review as one piece: say that in the verdict and list the
  worst blockers first.
- **A review made of small style points means the change likely needs nothing.** Report
  that, rather than promoting style points to fill the page.
- **No findings is a legitimate review.** When nothing survives, report `No findings` and
  the scope that was covered (files, focus, depth). Do not pad it.
- **Praise is not a finding.** The review has no praise section and no praise severity. If
  the user asks what is good about the change, answer that as a separate question.

## Severity and bucket

Severity is the reviewer's estimate of the damage if the finding is true. The bucket is the
lead's decision on whether it is true and worth acting on now. The report shows both, and
tasks follow the bucket.

| Reviewer severity | Usual bucket |
|---|---|
| CRITICAL, path confirmed | Act on |
| CRITICAL, not confirmed | Consider, with the check that would confirm it |
| WARNING | Act on if it fails the merge test, else Consider or Noted |
| SUGGESTION | Noted or Dismissed; act on only for a concrete defect, never for taste |

## Second reviewer (optional)

Reviewers from one model family share blind spots. When a miss is expensive, a second
reviewer from a **different model family** catches some of what the first cannot.

**When.** It runs when the user passes `--second-opinion`. Without the flag, the lead
offers it in one line of the verdict when the change touches authentication or
authorisation, cryptography, payments or billing, a data migration, deletion, concurrency
or a public API, or when the lead and a reviewer disagree on an act-on item. It never runs
under `--quick`, and it roughly doubles the cost of the review.

**How.**

- Same intent statement, same diff, same output format as the first reviewer; read-only.
- Keep the two independent: neither sees the other's findings. Independence is what gives
  their agreement weight.
- Another family means another provider, for example a `fleetflow` cross-provider worker or
  another provider's CLI that is already installed. If only one family is available, a
  different model from the same family is a weaker stand-in; say so in the report.
- The report names the model behind each reviewer.

**Agreement map.** Fold duplicates into one finding, then record which reviewer raised each.

| Finding | First | Second | Bucket |
|---|---|---|---|
| `auth.ts:42` token compared with `==` | yes | yes | Act on |
| `cache.ts:88` map grows without bound | yes | no | Consider |

Read it this way. A finding both reviewers raised on their own is the strongest signal in
the review, so dismissing it takes a concrete reason. A finding only one raised gets the
same checks as any other. Where the two flatly contradict each other, the lead reads the
code, decides, and records which side the evidence supports.

## Output

The sorted findings become the review body (SKILL.md Step 7): the intent, the verdict, then
Act On, Consider, Noted and Dismissed, then the agreement map if a second reviewer ran. The
verdict is "ready to commit" only when Act On is empty.
