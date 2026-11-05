# Lifetime traps: the default that kills your job, and what outlives the box

Every provider in this skill has a default that kills or erases a 1-4 hour headless job,
and most have something that outlives the box and keeps billing. These two facts are the
backbone of the provider-neutral rules. Per-provider detail and sources are in each card;
tags as there ([docs], [report], [inferred]).

## The default that ends a job

| Provider | Default | What happens at the end | Set instead |
|---|---|---|---|
| boat | auto-stop 1 h; exec and SSH do not extend it | a stop on a `--no-snapshots` box **erases** it | `--ttl` above the job; `extend` SETS the time left |
| E2B | timeout 5 min | `onTimeout: 'kill'`, irreversible | `timeoutMs` / `setTimeout()`; Hobby caps at 1 h, Pro 24 h |
| Modal | lifetime 5 min | terminated | `timeout` up to 24 h; snapshot and restore past that |
| Vercel | timeout 5 min | stopped (and snapshotted, by default) | `timeout`, `extendTimeout()`; Hobby 45 min, Pro 24 h |
| Daytona | auto-stop after 15 min idle; background work does not count | stopped mid-run | `--auto-stop 0` plus a wall-clock TTL |
| Fly | restart policy `always` | a one-shot job restarts forever | `fly machine run --rm` |

Read the rule as: **know your provider's default, set a lifetime above the job plus the
time to fetch results, and know whether the end kills, stops, pauses or erases.** A stop
that keeps the disk is recoverable; a kill or an erase is not.

## What outlives the box

| Provider | Leftover | Why it bites |
|---|---|---|
| boat | saved snapshots; a stopped box's disk (14 days) | snapshot copies can leave the EU |
| E2B | paused sandboxes | they never expire; storage billing not stated |
| Modal | filesystem snapshots (30 days) | no API lists them: keep their ids |
| Vercel | stop-snapshots, expiring 30 days after last use | billed per GB-month; `remove` keeps them |
| Daytona | stopped sandboxes (disk billed until archived); snapshots | auto-delete is off; snapshots bill after the delete |
| Fly | stopped Machines' rootfs; volumes, attached or not | both bill until deleted |

So "delete and confirm" is not the end of cleanup: after a run, list paused sandboxes,
snapshots and volumes as well, and delete the ones the run made.

## Extending a running box

- boat `extend --ttl <s>` and E2B `setTimeout()` both SET the remaining time from now;
  neither adds. Read the live expiry first so you never shorten a shared box.
- Vercel `extendTimeout()` extends within the plan's maximum session [docs].
- Modal has no extend after create [inferred from its docs]: plan the timeout.
- Daytona's idle timer resets on activity you signal; a wall-clock TTL is absolute.
