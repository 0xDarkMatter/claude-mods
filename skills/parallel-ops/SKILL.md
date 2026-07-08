---
name: parallel-ops
description: "Router for parallel or recurring agent work across six skills. Covers: parallel agents, fan out work, delegate to workers, run overnight, scheduled loop, land branches, mixed-model fleet, orchestrate workers, background agents at scale. Triggers on: which skill for parallel work, fan out agents, spawn workers, run this overnight, schedule a loop, land my branches, heterogeneous fleet, delegate to cheaper model, autonomous loop."
when_to_use: "Use first when parallel or recurring agent work is needed but the right skill among fleet-ops, fleet-worker, fleetflow, loop-ops, iterate, spawn is unclear - e.g. run several agents at once, set up something that runs overnight, delegate this cheaply."
license: MIT
allowed-tools: "Read"
metadata:
  author: claude-mods
  related-skills: "fleet-ops, fleet-worker, fleetflow, loop-ops, iterate, spawn"
---

# Parallel Ops — router

You have parallel or recurring agent work and don't know which skill owns it.
Six skills orbit this space and their names alone don't disambiguate. This
router owns cross-family discovery; read the table, jump to the one skill
you need, and stop reading here.

## The decision table

| You want | Go to | Not this, because |
|---|---|---|
| Parallel subtasks run by your session's OWN provider and model tier, in-process | native Workflow tool / `Agent` subagents (`isolation: worktree`) | not a fleet skill at all — no dedicated skill needed |
| Work done by a CHEAPER brain than your session (GLM/Haiku/Sonnet-under-Opus) — one subtask or a whole fan-out, all one brain type | [fleet-worker](../fleet-worker/) | [fleetflow](../fleetflow/) is overkill when every worker runs the same brain |
| DIFFERENT brains per work class in one run, or cross-provider dissent in verify (e.g. Codex refutes GLM) | [fleetflow](../fleetflow/) | [fleet-worker](../fleet-worker/) runs one brain type per run (any provider, but not mixed) |
| Work that RECURS on a schedule across sessions — cron, routine, unattended ticks | [loop-ops](../loop-ops/) | [iterate](../iterate/) is one continuous session, not a schedule |
| Drive ONE mechanical metric to a target in one continuous session (even a long overnight one) | [iterate](../iterate/) | [loop-ops](../loop-ops/) is the scheduler *around* sessions, not the session itself |
| Land/merge branches that parallel work produced | [fleet-ops](../fleet-ops/) | the terminus for every branch-producing row above (in-process subagents and prompt authoring produce no branches) |
| Author a static expert-agent prompt FILE (not a runtime worker) | [spawn](../spawn/) | listed only to catch the name collision with "spawn workers" |

Tie-breakers for the two classic overlaps: "many files, cheap models" is
**brain economics, not count** — cheaper brain → fleet-worker, own brain →
native. "Run overnight until X" is **session shape, not duration** — one
continuous run → iterate; scheduled re-entry across sessions → loop-ops.

## Two axes that confuse cold agents

**Spawn vs. land.** fleet-worker and fleetflow *spawn* workers and produce
branches; fleet-ops *lands* those branches through a test-gated queue.
Every branch-producing lane ends at fleet-ops regardless of how it was
spawned — agent team, background agent, `claude -p` worker, or human.

**Inner loop vs. outer loop.** iterate is the *inner* loop: one session,
one metric, git as memory, runs until a stop condition. loop-ops is the
*outer* loop: the scheduler and risk-tier discipline that decides when
and whether to fire a run (inner loop or otherwise) unattended.

## Composition chain

```
iterate (inner loop)  →  loop-ops (outer loop / scheduler)
                              ↓
        fleet-worker / fleetflow (spawn workers)
                              ↓
                fleet-ops (land branches)
```

Not every task uses the whole chain — most use exactly one link. Read the
table above first; only compose when the task genuinely spans spawn +
land or inner + outer.

## See also

- [fleet-ops](../fleet-ops/) — landing discipline: test-gated queue, pre-land scrub, auto-rebase, revert
- [fleet-worker](../fleet-worker/) — one cheap headless worker (GLM, Sonnet, Haiku) fanned out and gated
- [fleetflow](../fleetflow/) — heterogeneous cross-provider fleet (GLM + Codex + Anthropic)
- [loop-ops](../loop-ops/) — outer-loop design: risk tiers, kill switch, scheduling
- [iterate](../iterate/) — autonomous single-metric improvement loop
- [spawn](../spawn/) — generates expert-agent prompt files (authoring, not runtime)
