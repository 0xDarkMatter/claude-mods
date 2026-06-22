# Pattern Catalog — seven production loop shapes

Each pattern is a proven outer-loop shape with a cadence, a starting risk tier, a gate,
and an escalation rule. **Start every pattern at L1** (read-only) and graduate it only
after its reports prove its judgment. The `loop-scaffold` script seeds a `loop.config.yaml`
keyed by `--pattern <name>`; the names below are the canonical keys.

The columns that matter for every pattern: **cadence** (how often), **tier** (starting
autonomy), **gate** (what must pass before landing), **escalate** (what it must hand to a
human instead of doing).

---

## `daily-scan` — discover + prioritize

| | |
|---|---|
| Cadence | 1–2 h (weekday business hours) |
| Tier | L1 (report only) |
| Job | sweep the backlog/inbox/alerts; rank by priority; write the day's `STATE.md` |
| Gate | none — it writes nothing but the report |
| Escalate | everything; a human decides what to action |

The off-peak, lowest-priority loop. It produces the work-list the other loops and the
human draw from. Output is a `STATE.md` priority/watch/noise snapshot, nothing else.

---

## `pr-watch` — watch review state

| | |
|---|---|
| Cadence | 5–15 min |
| Tier | L1 |
| Job | list open PRs; flag stuck (no review N hours), failing checks, merge conflicts |
| Gate | none — surfaces state, posts a summary comment at most |
| Escalate | a human reviews/merges; the loop never merges |

Skeleton: `gh pr list --json …` → classify each (waiting-on-review / failing / conflict /
ready) → update `STATE.md` watch list → optionally one summary comment per PR.
Public-comment text follows the repo's preview-before-send discipline.

---

## `ci-watch` — triage build failures

| | |
|---|---|
| Cadence | 5–15 min |
| Tier | L2 (after L1 proves triage quality) |
| Job | detect red CI; classify the failure; at L2, propose a fix in a worktree |
| Gate | `verify` (the failing test passes) **and** `guard` (full suite + typecheck) |
| Escalate | flaky/infra failures, anything touching deploy/secrets, ambiguous root cause |

The highest-priority loop in the multi-loop order — a red build blocks everyone. At L1 it
classifies and reports; at L2 it opens a fix PR in an isolated worktree and hands the
branch to `fleet-ops` for the gated merge. Never auto-merges to `main`.

---

## `dep-bump` — patch-only bumps

| | |
|---|---|
| Cadence | 6 h – 1 d |
| Tier | L2 |
| Job | find outdated deps; bump **patch-only**, behind a release-age cooldown |
| Gate | `guard` (full suite + build) passes; supply-chain cooldown satisfied |
| Escalate | minor/major bumps, anything failing the guard, any flagged advisory |

Pair with [`supply-chain-defense`](../../supply-chain-defense/SKILL.md): respect the
7-day cooldown (`preinstall-check.sh`) and behavioural score before a bump lands. Patch
bumps that pass both the cooldown and the guard are the *only* class safe to auto-land,
and only on a feature branch, never `main`.

---

## `changelog-gen` — release-note drafts

| | |
|---|---|
| Cadence | 1 d, or on tag |
| Tier | L1 (draft only) |
| Job | summarize merged PRs since the last tag into a `RELEASE_NOTES_DRAFT.md` |
| Gate | none — produces a draft for human approval |
| Escalate | the human edits + publishes; the loop never runs `gh release create` |

Drafts to a file, never publishes. Publishing a release is a one-way visibility
commitment — it stays a human step (the repo's release-review discipline). Pair with
[`github-ops`](../../github-ops/SKILL.md) for the human-driven publish.

---

## `merge-hygiene` — hygiene

| | |
|---|---|
| Cadence | 1–6 h (off-peak) |
| Tier | L1 |
| Job | find merged-and-deletable branches, stale feature flags, orphaned artifacts |
| Gate | none at L1; at L2, branch deletion behind a "merged + N days old" rule |
| Escalate | anything ambiguous; never deletes a branch with unmerged commits |

Honors [worktree boundaries](../../../rules/worktree-boundaries.md): never touches another
session's `.claude/worktrees/`, never sweeps with `git add -A`.

---

## `issue-sort` — classify + label

| | |
|---|---|
| Cadence | 2 h – 1 d |
| Tier | L1 (propose-only) |
| Job | classify new issues (bug/feature/question/dupe), suggest labels + priority |
| Gate | none — proposes labels, applies only the mechanical ones at L2 |
| Escalate | priority calls, dupe-closing, anything needing product judgment |

At L1 it proposes; at L2 it may apply purely-mechanical labels (`needs-triage` →
`bug`/`docs`) but never closes an issue or sets priority unattended.

---

## Choosing a pattern → tier → cadence

1. **Match the job** to the closest pattern; use `custom` only if none fit.
2. **Start at the pattern's L1 tier.** Run it read-only until you trust its reports.
3. **Set the cadence** to the slowest that still catches the work in time — cadence is
   the biggest cost lever (see [loop-estimate](../scripts/loop-estimate.py)). A 5-min PR
   pr-watch loop costs 3× a 15-min one for marginal freshness gain.
4. **Graduate** to L2 only with a `guard`, a `worktree`, an `escalation` rule, and a
   `land_via` — then re-run `loop-check` at the new tier.

## See also

- [risk-tiers.md](risk-tiers.md) — what each tier may do and the permission-mode mapping.
- [state-spine.md](state-spine.md) — the multi-loop priority order these patterns share.
- [../assets/loop.config.template.yaml](../assets/loop.config.template.yaml) — the config every pattern fills in.
