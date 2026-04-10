---
name: iterate
description: "Autonomous improvement loop - modify, measure, keep or discard, repeat. Inspired by Karpathy's autoresearch. Triggers on: iterate, improve autonomously, run overnight, keep improving, autoresearch, improvement loop, iterate until done, autonomous iteration."
license: MIT
allowed-tools: "Read Write Edit Glob Grep Bash Agent TaskCreate TaskUpdate TaskList"
metadata:
  author: claude-mods
---

# Iterate - Autonomous Improvement Loop

Inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch): constrain scope, clarify success with one mechanical metric, loop autonomously. The agent modifies code, measures the result, keeps improvements, discards regressions, and repeats - indefinitely or for N iterations.

The power is in the constraint. One metric. One scope. One loop. Git as memory.

## Preflight

Before the loop starts, do the work that makes the loop effective. Don't skip steps - this discipline is what separates a productive overnight run from a flailing one.

### 1. Collect Config

Five inputs. If provided inline, extract and proceed. If any are missing, ask once using `AskUserQuestion` with all missing fields batched together.

| Field | Required | What it is | Example |
|-------|----------|------------|---------|
| **Goal** | Yes | What you're improving, in plain language | "Increase test coverage to 90%" |
| **Scope** | Yes | File globs the agent may modify | `src/**/*.ts` |
| **Verify** | Yes | Shell command that outputs the metric (a number) | `npm test -- --coverage \| grep "All files"` |
| **Direction** | Yes | Is higher or lower better? | `higher` / `lower` |
| **Guard** | No | Command that must always pass (prevents regressions) | `npm run typecheck` |

**Bounded mode:** If the user includes `Iterations: N`, run exactly N iterations then stop with a summary. Otherwise, loop forever until interrupted.

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

### 4. Tasks

Create a TaskList to track progress across iterations. This provides structure the user can check without reading the full results log.

```
TaskCreate: "Establish baseline" (status: in_progress)
TaskCreate: "Iteration loop - [goal]" (status: pending)
TaskCreate: "Final summary and cleanup" (status: pending)
```

Update task status as the loop progresses. Mark the iteration task as `in_progress` when the loop starts, `completed` when it ends.

### 5. Tests and Verification

Before the first iteration, make sure verification actually works:

- Run the verify command on the current state. If it fails or produces no parseable number, fix this first.
- Run the guard command (if set). If it fails on the current state, the codebase has pre-existing issues - flag to the user.
- If tests don't exist yet for the scope, consider writing them as iteration 0. Good tests make the loop more effective.

### 6. Baseline

Record the starting point:

1. Run verify command, extract the metric - this is iteration 0
2. Create `results.tsv` with the header and baseline row
3. Update the baseline task to `completed`
4. Confirm setup to the user, then begin the loop

```
Goal:      Increase test coverage to 90%
Scope:     src/**/*.ts
Verify:    npm test -- --coverage | grep "All files"
Direction: higher
Guard:     npm run typecheck
Baseline:  72.3%
Mode:      unbounded
Tasks:     3 created
Permissions: verified (all commands pre-approved)

Starting iteration loop.
```

## The Loop

```
LOOP (forever, or N times):

  1. REVIEW    git log --oneline -10 + read results.tsv tail
              Know what worked, what failed, what's untried.

  2. IDEATE    Pick ONE change. Write a one-sentence description
              BEFORE touching any code. Consult git history -
              don't repeat discarded approaches.

  3. MODIFY    Make ONE atomic change to in-scope files only.
              Small, focused, explainable.

  4. COMMIT    git add <specific files> (never git add -A)
              git commit -m "experiment: <description>"
              Commit BEFORE verification. Enables clean rollback.

  5. VERIFY    Run the verify command. Extract the metric.
              If guard is set and metric improved, run guard too.

  6. DECIDE
              Improved + guard passes (or no guard) -> KEEP
              Improved + guard fails -> REVERT (git revert HEAD --no-edit)
              Same or worse                -> REVERT
              Crashed -> attempt fix (max 3 tries), else REVERT

  7. LOG       Append row to results.tsv

  8. REPEAT    Go to 1. Print a one-line status every 5 iterations.
              NEVER ask "should I continue?" - just keep going.
              If bounded and iteration N reached, print summary and stop.
```

### Rollback

Always use `git revert HEAD --no-edit` (preserves the experiment in history - the agent can learn from it). If revert conflicts, fall back to `git reset --hard HEAD~1`.

### When Stuck (5+ consecutive discards)

1. Re-read ALL in-scope files from scratch
2. Re-read the original goal
3. Review entire results.tsv for patterns
4. Try combining two previously successful changes
5. Try the opposite of what hasn't been working
6. Try something radical - architectural changes, different algorithms

## Rules

1. **One change per iteration.** Atomic. If it breaks, you know exactly why.
2. **Mechanical verification only.** No "looks good." The number decides.
3. **Git is memory.** Commit before verify. Revert on failure. Read `git log` before ideating. Failed experiments stay visible in history via revert commits.
4. **Simpler wins.** Equal metric + less code = keep. Tiny improvement + ugly complexity = discard. Removing code for equal results is a win.
5. **Never stop.** Unbounded loops run until interrupted. Never ask permission to continue. The user may be asleep.
6. **Read before write.** Understand full context before each modification.
7. **Scope is sacred.** Only modify files matching the scope globs. Never touch verify/guard targets, test fixtures, or config outside scope.

## Results Log

Tab-separated file: `results.tsv`

```tsv
iteration	commit	metric	status	description
0	a1b2c3d	72.3	baseline	initial state
1	b2c3d4e	74.1	keep	add edge case tests for auth module
2	-	73.8	discard	refactor test helpers (broke coverage)
3	c3d4e5f	75.0	keep	add missing null checks in user service
4	-	0.0	crash	switched to vitest (import errors)
```

**Status values:** `baseline`, `keep`, `discard`, `crash`

### Progress Output

Every 5 iterations, print a brief status:

```
Iteration 15: metric 81.2 (baseline 72.3, +8.9) | 6 keeps, 8 discards, 1 crash
```

When a bounded loop completes:

```
=== Iterate Complete (25/25) ===
Baseline: 72.3 -> Final: 88.7 (+16.4)
Keeps: 12 | Discards: 11 | Crashes: 2
Best iteration: #18 - add integration tests for payment flow (+3.2)
```

## Adapting to Any Domain

The pattern is universal. Change the five inputs, not the loop.

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

If the metric improves but the guard fails, the change is reverted. The agent should note WHY the guard failed and adapt future attempts accordingly.

Common guards: `npm test`, `tsc --noEmit`, `cargo check`, `pytest`, `go vet`

## Usage Examples

### Inline config (all fields provided)

```
/iterate
Goal: Increase test coverage from 72% to 90%
Scope: src/**/*.ts, src/**/*.test.ts
Verify: npm test -- --coverage | grep "All files" | awk '{print $10}'
Direction: higher
Guard: tsc --noEmit
Iterations: 30
```

### Minimal (triggers interactive setup)

```
/iterate
Goal: Make the API faster
```

Agent scans codebase for tooling, suggests scope/verify/direction, asks once, then goes.

### Unbounded overnight run

```
/iterate
Goal: Reduce bundle size below 150KB
Scope: src/**/*.ts, webpack.config.js
Verify: npm run build 2>&1 | grep "main.js" | awk '{print $2}'
Direction: lower
```

Agent runs indefinitely. User interrupts in the morning. Results are in `results.tsv` and git history.
