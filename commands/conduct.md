---
description: "Coordinator ritual for a wave of child sessions: intake READY reports, review each diff, improve or send back, land one at a time through fleet queue, write the wave's changelog entry, report what would be pushed, sweep and archive. Triggers: conduct, coordinate the lanes, land all child sessions, review and land the wave, orchestrator pass, archive and prune. Thin trigger over the fleet-ops skill."
---

# /conduct - coordinate, review, land, clean up

Thin command wrapper over the **fleet-ops** skill. The procedure lives in
`skills/fleet-ops/references/conduct.md` and the landing machinery in `fleet queue`; this
file only routes `$ARGUMENTS`.

## Arguments

$ARGUMENTS

| Invocation | Mode |
|------------|------|
| `/conduct` | Every phase: pin, inventory, intake, review, improve, land, changelog, push report, sweep and archive, final report |
| `/conduct --dry-run` | Phases 0-3 only: inventory and review, with `fleet queue --dry-run` verdicts. Lands, writes and archives nothing |
| `/conduct --no-archive` | Every phase, but list the sessions it would archive instead of archiving them |

The two flags combine. Anything else in `$ARGUMENTS` (a wave name, a lane to start with)
is passed to the procedure as context.

## Steps

1. **Invoke the `fleet-ops` skill** (Skill tool).
2. **Read `references/conduct.md`** from that skill, and follow it phase by phase.
3. **Run it from MAIN**, the session at the main checkout's root. From a lane worktree,
   stop and say so: a lane never lands other lanes.

## Invariants

- Lands go through `fleet queue`, one lane per background call, never `git merge` by hand.
- Never `git push`, never deploy: phase 7 reports what would be pushed and asks.
- Archive only sessions that are idle, landed and clean, never this one.
