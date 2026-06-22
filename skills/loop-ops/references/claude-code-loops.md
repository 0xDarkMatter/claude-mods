# Where Loops Actually Live in Claude Code

The outer loop is a *cadence + a headless run*. This file is the mechanics: the concrete
ways to fire a loop in Claude Code, when to use each, and how they compose with the tier
model. The doctrine — *a scheduler invokes `claude -p`, not a session that spawns ungated
children* — is in [risk-tiers.md](risk-tiers.md); this is the how.

---

## The four cadence mechanisms

| Mechanism | What it is | Best for | Tier fit |
|---|---|---|---|
| **`/loop`** | runs a prompt/slash-command on a recurring interval (or self-paced) in the *current* session | interactive, supervised loops; polling you watch | L1, supervised |
| **`/schedule`** | cron-scheduled **cloud** agents (routines) that run detached | unattended recurring loops, the real L2/L3 cadence | L2/L3 |
| **`ScheduleWakeup`** | re-enter *this* session after a delay (dynamic `/loop` pacing) | self-pacing a single long task; polling external state | L1, supervised |
| **OS scheduler / CI** | Task Scheduler / cron / GitHub Actions invoking `claude -p` | the canonical unattended loop; the authorizer is the scheduler | L2/L3 |

The first three keep a session in the loop (good for L1, supervised). The fourth is the
unattended pattern: **the scheduler is the human-configured authorizer**, so there's no
parent classifier to block the headless child.

---

## The canonical unattended shape

```
                    ┌────────────────────────────────────────────┐
   cron / Task      │  for each tick:                            │
   Scheduler / CI ──┤    claude -p "$(cat .loops/<name>/run.md)" \│
   (the authorizer) │      --permission-mode dontAsk \           │
                    │      --append-system-prompt "$(cat STATE.md)"│
                    │    → run reads STATE, does work, rewrites it │
                    └────────────────────────────────────────────┘
```

- The **scheduler** (not a Claude session) invokes `claude -p`. It is the human-configured
  authorizer; nothing upstream gates the run.
- `--permission-mode dontAsk` + a curated allowlist = a **gated** worker that runs
  anywhere. (For L3 arbitrary-execution jobs, swap to a container + `bypassPermissions` —
  see the enumerate-vs-isolate fork in [risk-tiers.md](risk-tiers.md).)
- The run prompt (`run.md`) is the same every tick — fresh context each time (the Ralph
  property). State survives in `STATE.md` + the codebase + git, not the conversation.

### Why not "a Claude session that launches the loop"?

Because an `auto`-mode session that spawns a detached `claude -p --permission-mode
bypassPermissions` child is blocked as **Create Unsafe Agents** — an ungated autonomous
agent with no human gate. The fix is structural, not a workaround: move the launch to the
scheduler. Trying to wrap the bypass flag in a script to dodge the gate is **Auto-Mode
Bypass**, a `hard_deny` (see [risk-tiers.md](risk-tiers.md) and the
[classifier reference](../../../docs/AUTO-MODE-CLASSIFIER.md)).

---

## Hooks — the loop's reflexes

Hooks fire shell commands at points in the agent's lifecycle. Useful loop wiring:

| Hook | Loop use |
|---|---|
| `PreToolUse` | enforce scope/kill-switch before a tool runs (deterministic gate 1) |
| `PermissionDenied` | react to a classifier denial — log it, signal a retry, escalate |
| `Stop` | write the run-log line + rewrite `STATE.md` as the run ends |
| `SessionStart` | load `STATE.md` into context at the top of a run |

A `PreToolUse` hook that checks `.loops/<name>/PAUSED` is the cheapest possible kill
switch — it blocks every tool the instant the sentinel appears, no matter where the run
is. See [`claude-code-ops`](../../claude-code-ops/SKILL.md) for the full 30-event hook
catalog and the stdin/stdout JSON contracts.

---

## Composing with the execution layers

The cadence fires; the work is done by the layers this repo already ships:

```
/schedule (cadence)
   └─▶ claude -p  (the run; dontAsk + allowlist)
         ├─▶ iterate          # inner improvement loop, if the unit of work is "improve metric X"
         ├─▶ fleet-worker     # spawn cheap parallel makers in worktrees
         └─▶ fleet-ops        # test-gate + land the winning branch
   └─▶ Stop hook → rewrite STATE.md + append run-log
```

- **`iterate`** when the unit of work is "drive metric X to target in this session".
- **`fleet-worker`** when one tick should fan out several maker attempts cheaply.
- **`fleet-ops`** as the `land_via` — the sequential, test-gated merge queue that turns a
  worker's green branch into a landed change (or escalates it).
- **`pigeon`** to coordinate across concurrent loops (the priority-order standoff).

---

## A worked L1 → L2 graduation

1. **L1, supervised:** `/loop 15m` in a session, running a read-only "report PR state to
   STATE.md" prompt. You watch it; it writes nothing but the snapshot. Permission mode
   `plan`.
2. **Prove judgment:** read a week of `STATE.md` snapshots + the run-log. Is its triage
   right? Does readiness hold?
3. **L2, unattended:** move the cadence to `/schedule` (or cron → `claude -p`). Switch the
   run prompt to "open a fix PR in a worktree" with `--permission-mode dontAsk` + a narrow
   allowlist (`Bash(npm test)`, `Bash(git …)`). Add a `guard`, set `land_via: fleet-ops`,
   write the `escalation` rule. Re-run `loop-audit` at L2 — fix every error — then enable.

The point of the ladder: the cadence mechanism *changes* (session `/loop` → scheduled
`claude -p`) exactly when the autonomy does, and the audit gates the transition.

## See also

- [risk-tiers.md](risk-tiers.md) — the permission-mode mapping + scheduler-not-session rule.
- [state-spine.md](state-spine.md) — the STATE.md the run reads and rewrites.
- [../../claude-code-ops/SKILL.md](../../claude-code-ops/SKILL.md) — the full hook catalog, `claude -p` flags, headless reference.
