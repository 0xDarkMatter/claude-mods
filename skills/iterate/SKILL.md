---
name: iterate
description: "Autonomous improvement loop - modify, measure, keep or discard, repeat. Inspired by Karpathy's autoresearch. Triggers on: iterate, improve autonomously, run overnight, keep improving, autoresearch, improvement loop, iterate until done, autonomous iteration, batch experiments."
license: MIT
allowed-tools: "Read Write Edit Glob Grep Bash Agent TaskCreate TaskUpdate TaskList"
metadata:
  author: claude-mods
---

# Iterate - Autonomous Improvement Loop

Inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch): constrain scope, clarify success with one mechanical metric, loop autonomously. The agent modifies code, measures the result, keeps improvements, discards regressions, and repeats - until any stop condition fires or the user interrupts.

The power is in the constraint. One metric. One scope. One loop. Git as memory.

## Preflight

Before the loop starts, do the work that makes the loop effective. Don't skip steps - this discipline is what separates a productive overnight run from a flailing one.

### 1. Collect Config

If provided inline, extract and proceed. If required fields are missing, ask once using `AskUserQuestion` with all missing fields batched together.

| Field | Required | What it is | Example |
|-------|----------|------------|---------|
| **Goal** | Yes | What you're improving, in plain language | "Increase test coverage to 90%" |
| **Scope** | Yes | File globs the agent may modify | `src/**/*.ts` |
| **Verify** | Yes | Shell command that outputs the metric (a number) | `npm test -- --coverage \| grep "All files"` |
| **Direction** | Yes | Is higher or lower better? | `higher` / `lower` |
| **Guard** | No | Command that must always pass (prevents regressions) | `npm run typecheck` |
| **Batch** | No | Changes per iteration. >1 enables bisect-on-regression. Default `1`. | `3` |
| **Iterations** | No | Hard cap on iteration count. | `30` |
| **Until** | No | Stop when metric crosses this target value. | `90` |
| **Stagnation** | No | Stop after N consecutive iterations with no improvement. | `15` |
| **Branch** | No | Branch isolation. `current` (default), `auto` (slug from goal), or explicit name. | `auto` |

**Stop conditions are OR'd**: any combination of `Iterations`, `Until`, `Stagnation` may be set. The loop stops when any one is satisfied. If none are set, the loop is unbounded - it runs until interrupted.

### 2. Plan

Read all in-scope files. Understand the codebase before touching anything.

- What's the current state? What's already been tried?
- What are the likely improvement vectors? Rank them.
- What are the risks? What could break?
- Form a rough strategy for the first 5-10 iterations.

### 3. Permissions

Check that `allowed-tools` cover what the loop needs. The verify and guard commands must run without permission prompts - a blocked tool at 3am kills the whole run.

- Dry-run the verify command. If it gets blocked, note which `Bash(command:*)` pattern is needed.
- Dry-run the guard command (if set). Same check.
- If permissions are missing, suggest specific wildcard additions for `.claude/settings.local.json` and ask the user to approve before starting. Reference `/setperms` for a full setup.

### 4. Branch Setup

The `Branch` field controls where iteration commits land.

| Value | Behavior |
|-------|----------|
| `current` (default) | Stay on the current branch. Commits land directly. |
| `auto` | Create `iterate/<slug-from-goal>` from current HEAD and switch to it. |
| `<explicit-name>` | Create branch with that exact name and switch to it. |

**Slug derivation** (for `auto`): lowercase the Goal, replace non-alphanumeric runs with `-`, trim leading/trailing dashes, truncate to 40 chars. "Increase test coverage to 90%" → `iterate/increase-test-coverage-to-90`.

**Collision**: if the branch already exists, suffix `-2`, `-3`, etc.

**Confirm before switching**: print the chosen branch name and source branch. Do not silently create a branch the user didn't ask for.

**Cleanup**: never auto-delete the branch. The user decides whether to merge, open a PR, or `git branch -D` it. The skill's job ends at "branch exists with results."

### 5. Tasks

Create a TaskList to track progress across iterations. This provides structure the user can check without reading the full results log.

```
TaskCreate: "Establish baseline" (status: in_progress)
TaskCreate: "Iteration loop - [goal]" (status: pending)
TaskCreate: "Final summary and cleanup" (status: pending)
```

Update task status as the loop progresses. Mark the iteration task as `in_progress` when the loop starts, `completed` when it ends.

### 6. Tests and Verification

Before the first iteration, make sure verification actually works:

- Run the verify command on the current state. If it fails or produces no parseable number, fix this first.
- Run the guard command (if set). If it fails on the current state, the codebase has pre-existing issues - flag to the user.
- If tests don't exist yet for the scope, consider writing them as iteration 0. Good tests make the loop more effective.

### 7. Baseline

Record the starting point:

1. Run verify command, extract the metric - this is iteration 0
2. Create `results.tsv` with the header and baseline row
3. Tag the baseline: `git tag iterate/best` (will float forward as the metric improves)
4. Update the baseline task to `completed`
5. Confirm setup to the user, then begin the loop

```
Goal:        Increase test coverage to 90%
Scope:       src/**/*.ts
Verify:      npm test -- --coverage | grep "All files"
Direction:   higher
Guard:       npm run typecheck
Branch:      iterate/increase-test-coverage-to-90 (created from main)
Batch:       3
Stop:        Iterations 50 OR Until ≥ 90.0 OR Stagnation 15
Baseline:    72.3
Permissions: verified

Starting iteration loop.
```

## The Loop

```
LOOP (until any stop condition met):

  1. REVIEW    git log --oneline -10 + read results.tsv tail
              Know what worked, what failed, what's untried.

  2. IDEATE    Pick UP TO `Batch` independent changes. Each must stand on
              its own and be applicable independently. Write a one-sentence
              description per change BEFORE touching code. Consult git history -
              don't repeat discarded approaches.

  3. MODIFY+COMMIT
              For each change in the batch (in order):
                a. Apply the change to in-scope files only.
                b. git add <specific files>   (never git add -A)
                c. git commit -m "experiment: <one-line description>"
              Each change is its own commit. Non-negotiable - bisection
              depends on it.

  4. VERIFY    Run the verify command after the final commit of the batch.
              Extract the metric. If guard is set, run it too.

  5. DECIDE
              Improved + guard ok (or no guard)
                -> KEEP entire batch
              Regressed / unchanged / guard failed:
                if Batch == 1 -> REVERT the one commit
                if Batch >  1 -> BISECT (see below)
              Crashed (verify or guard non-zero exit, not just regressed)
                -> attempt fix (max 3 tries), else REVERT entire batch

  6. LOG       Append one row per change to results.tsv.

  7. SNAPSHOT  If the new metric beats the previous best, force-update tag:
              git tag -f iterate/best

  8. CHECK STOP
              Iterations cap reached?       -> stop, summarize, exit.
              Until target crossed?          -> stop, summarize, exit.
              Stagnation N reached?          -> stop, summarize, exit.
              Interrupted / fatal error?     -> stop, summarize, exit.

  9. REPEAT    Go to 1. Print a one-line status every 5 iterations.
              NEVER ask "should I continue?" - just keep going.
```

### Bisection (Batch > 1, regression detected)

When a batched verify fails, the loop must identify which commit(s) caused the regression - keeping the good ones, dropping the bad ones.

```
1. Note C0   = the iteration's start commit (before the batch)
   Note C1..CN = the batch commits in order

2. git reset --hard C0

3. For each Ci in order:
     a. git cherry-pick Ci
     b. Run verify
     c. Improved or held + guard ok -> keep (commit stays in history)
        Regressed or guard failed   -> git reset --hard HEAD~1 (drop)

4. Log each change's outcome to results.tsv:
     status=bisect-keep   -> commit kept
     status=bisect-drop   -> commit dropped
```

**Cost**: worst case is N additional verify runs (1 batch + N individual). For `Batch: 3`, max 4 verifies. Worth it when batches are mostly good - i.e., when you're confident in the domain.

**Rule of thumb**: use `Batch: 1` for exploratory work, `Batch: 3-5` for mechanical fixes (lint, obvious test gaps, dead code), `Batch: 5+` only when you've watched the loop succeed at smaller batches first.

### Rollback

For single-commit reverts: `git revert HEAD --no-edit` (preserves the experiment in history). If revert conflicts, fall back to `git reset --hard HEAD~1`.

For batch reverts (full crash): `git reset --hard <iteration-start-commit>` - drops all batch commits cleanly.

### Best Snapshot

`iterate/best` is a force-updated tag pointing to the highest-metric commit so far. It floats forward whenever a new best is reached.

- Recovery from any later regression: `git checkout iterate/best`
- Inspect what's pinned: `git log iterate/best -1`
- The skill never deletes the tag - clear manually with `git tag -d iterate/best`

The tag is updated *after* the SNAPSHOT step, so it always reflects the best state visible in `results.tsv`.

### When Stuck (5+ consecutive discards or stagnation watermark)

1. Re-read ALL in-scope files from scratch
2. Re-read the original goal
3. Review entire results.tsv for patterns
4. Try combining two previously successful changes
5. Try the opposite of what hasn't been working
6. Try something radical - architectural changes, different algorithms

If `Stagnation: N` is set and reached, the loop will stop on its own. The "when stuck" protocol fires earlier (5 discards) as a course correction before the formal stop fires.

## Rules

1. **One change per commit.** With `Batch: 1`, one change per iteration. With `Batch: N`, N commits per iteration - each independently bisectable. The atomicity invariant lives at the commit, not the iteration.
2. **Mechanical verification only.** No "looks good." The number decides.
3. **Git is memory.** Commit before verify. Revert on failure. Read `git log` before ideating. Failed experiments stay visible in history via revert commits.
4. **Simpler wins.** Equal metric + less code = keep. Tiny improvement + ugly complexity = discard. Removing code for equal results is a win.
5. **Never stop early.** Unbounded loops run until interrupted or a stop condition fires. Never ask permission to continue.
6. **Always summarize on exit.** When the loop ends for any reason - bounded completion, target reached, stagnation, interrupt, or fatal error - emit the final summary block before yielding control. The user might be asleep; they'll read it in the morning.
7. **Read before write.** Understand full context before each modification.
8. **Scope is sacred.** Only modify files matching the scope globs. Never touch verify/guard targets, test fixtures, or config outside scope.

## Results Log

Tab-separated file: `results.tsv`

```tsv
iteration	commit	metric	status	description
0	a1b2c3d	72.3	baseline	initial state
1	b2c3d4e	74.1	keep	add edge case tests for auth module
2	-	73.8	discard	refactor test helpers (broke coverage)
3.1	c3d4e5f	74.6	bisect-keep	add null check in user service
3.2	-	74.6	bisect-drop	rename helper module (regressed)
3.3	d4e5f6a	75.0	bisect-keep	add tests for token expiry
4	-	0.0	crash	switched to vitest (import errors)
```

**Status values**: `baseline`, `keep`, `discard`, `bisect-keep`, `bisect-drop`, `crash`

**Iteration column**: integer for atomic iterations (`Batch: 1`), `<iter>.<change>` decimal for batched iterations (one row per change in the batch).

### Progress Output

Every 5 iterations, print a brief status:

```
Iter 15: metric 81.2 (baseline 72.3, +8.9, best 81.2) | 6 keeps, 8 discards, 1 crash | stagnation 0/15
```

### Final Summary (always emitted on exit)

Whatever causes the stop - bounded completion, `Until` target, `Stagnation` cap, interrupt, fatal - print this block before yielding control:

```
=== Iterate Complete ===
Stopped:    target reached (Until ≥ 90.0)
Iterations: 23
Baseline:   72.3 -> Final 90.4 (+18.1)
Best:       90.4 @ iter 22 ("add integration tests for payment flow")
Keeps: 14 | Discards: 8 | Crashes: 1
Branch:     iterate/increase-test-coverage-to-90
Tag:        iterate/best -> 7f8a9b2

Next: review the branch, then merge / PR / cherry-pick / discard at your discretion.
Recovery from regression: git checkout iterate/best
```

The "Stopped" line names the trigger. Common values: `bounded completion`, `target reached`, `stagnation cap`, `user interrupt`, `fatal error`.

## Adapting to Any Domain

The pattern is universal. Change the inputs, not the loop.

| Domain | Goal | Verify | Direction |
|--------|------|--------|-----------|
| Test coverage | Coverage to 90% | `npm test -- --coverage` | higher |
| Bundle size | Below 200KB | `npm run build && stat -f%z dist/main.js` | lower |
| Performance | Faster API response | `npm run bench \| grep p95` | lower |
| ML training | Lower validation loss | `uv run train.py && grep val_bpb run.log` | lower |
| Lint errors | Zero warnings | `npm run lint 2>&1 \| grep -c warning` | lower |
| Lighthouse | Score above 95 | `npx lighthouse --output=json \| jq .score` | higher |
| Code quality | Reduce complexity | `npx complexity-report \| grep average` | lower |

## Guard: Preventing Regressions

The guard is an optional safety net - a command that must always pass regardless of what the main metric does.

- **Verify** answers: "Did the metric improve?"
- **Guard** answers: "Did anything else break?"

If the metric improves but the guard fails, the change is reverted (or bisected, in batch mode). The agent should note WHY the guard failed and adapt future attempts accordingly.

Common guards: `npm test`, `tsc --noEmit`, `cargo check`, `pytest`, `go vet`

## Usage Examples

### Inline config — full overnight run with target

```
/iterate
Goal: Increase test coverage from 72% to 90%
Scope: src/**/*.ts, src/**/*.test.ts
Verify: npm test -- --coverage | grep "All files" | awk '{print $10}'
Direction: higher
Guard: tsc --noEmit
Until: 90
Stagnation: 15
Batch: 3
Branch: auto
```

Runs until coverage hits 90% OR 15 consecutive iterations show no improvement, whichever first. 3 changes per iteration, bisected on regression. Lands on its own branch.

### Bounded throughput run — mechanical fixes

```
/iterate
Goal: Reduce lint warnings to zero
Scope: src/**/*.ts
Verify: npm run lint 2>&1 | grep -c warning
Direction: lower
Until: 0
Iterations: 50
Batch: 5
```

High-confidence mechanical fixes - batch aggressively. Stops at zero warnings or 50 iterations. Stays on current branch.

### Minimal — interactive setup

```
/iterate
Goal: Make the API faster
```

Agent scans codebase, suggests scope/verify/direction, asks once, then goes. Defaults: `Batch: 1`, `Branch: current`, unbounded.

### Unbounded overnight, atomic, isolated branch

```
/iterate
Goal: Reduce bundle size below 150KB
Scope: src/**/*.ts, webpack.config.js
Verify: npm run build 2>&1 | grep "main.js" | awk '{print $2}'
Direction: lower
Branch: auto
```

Runs indefinitely on `iterate/reduce-bundle-size-below-150kb`. User interrupts in the morning, reads the summary, decides whether to merge.
