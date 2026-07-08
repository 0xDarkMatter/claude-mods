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
| One-off parallel subtasks, same provider, this session | native Workflow tool / `Agent` subagents (`isolation: worktree`) | not a fleet skill at all — no dedicated skill needed |
| Cheap delegation — a few well-scoped tool-using subtasks on a cheaper brain | [fleet-worker](../fleet-worker/) | [fleetflow](../fleetflow/) is overkill for one brain |
| Brains differ by work class, or you need cross-provider dissent in verify | [fleetflow](../fleetflow/) | [fleet-worker](../fleet-worker/) is same-provider only |
| Recurring / scheduled / unattended loop | [loop-ops](../loop-ops/) | [iterate](../iterate/) is one session, not scheduled |
| Drive ONE mechanical metric to a target, in one session | [iterate](../iterate/) | [loop-ops](../loop-ops/) is the scheduler *around* this |
| Land/merge branches that parallel work produced | [fleet-ops](../fleet-ops/) | always the terminus — every row above ends here |
| Author a static expert-agent prompt FILE (not a runtime worker) | [spawn](../spawn/) | listed only to catch the name collision with "spawn workers" |

## Two axes that confuse cold agents

**Spawn vs. land.** fleet-worker and fleetflow *spawn* workers and produce
branches; fleet-ops *lands* those branches through a test-gated queue.
Every fleet lane ends at fleet-ops regardless of how it was spawned —
agent team, background agent, `claude -p` worker, or human.

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
