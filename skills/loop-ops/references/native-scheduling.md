# Native Scheduling Primitives — what the harness now ships, and what it doesn't

**Verified 2026-08-30** against the live tool schemas in-session (`CronCreate`/`CronList`/
`CronDelete`, the `scheduled-tasks` MCP server, `ScheduleWakeup`) and the current docs:
[scheduled-tasks](https://code.claude.com/docs/en/scheduled-tasks),
[desktop-scheduled-tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks),
[routines](https://code.claude.com/docs/en/routines). These are fast-moving surfaces —
**re-verify before trusting a number here.** Where the docs and a tool description
disagree, this file says so rather than picking a winner.

[claude-code-loops.md](claude-code-loops.md) owns *which mechanism to pick and how to wire
it*. This file owns *what each primitive actually is*: parameters, limits, and the
failure semantics that decide whether a loop survives a night.

---

## The four hosts

A loop's **host** is where its ticks execute. It is not a style preference — it changes
what the loop can reach, what can stop it, and what "it didn't run" means.

| Host | Primitive | Executes on | Local files | Needs a session | Min cadence | Survives restart |
|---|---|---|---|---|---|---|
| `session-cron` | `CronCreate` / `/loop` | your machine | ✅ | **yes, open + idle** | 1 min | only via `--resume`, if unexpired |
| `desktop-task` | `scheduled-tasks` MCP / Routines→**Local** | your machine | ✅ | no (app open) | 1 min | ✅ on disk |
| `cloud-routine` | `/schedule` → Routines→**Cloud** | Anthropic cloud | ❌ fresh clone | no | **1 hour** | ✅ |
| `external` | cron / Task Scheduler / systemd → `loop-run.sh` | your machine | ✅ | no | yours | ✅ |
| `local` | *undeclared* — a generic local run | your machine | ✅ | — | — | — |

`local` is the template default and means "not yet decided": `loop-doctor` applies only
the host-agnostic checks. It is fine while scaffolding and while a loop is still L1, but
**pick a real host before scheduling** — a loop whose execution surface nobody named is a
loop whose limits nobody checked.

The doctrine is unchanged and now has a native shape: **the authorizer is the scheduler,
never a session that spawns ungated children** ([risk-tiers.md](risk-tiers.md)). Every host
above except `session-cron` is a human-configured authorizer.

---

## `session-cron` — `CronCreate` / `CronList` / `CronDelete`, and `/loop`

The in-session scheduler. `/loop` is a **bundled skill** that drives these tools; you do
not author it.

**Verified surface.** `CronCreate` takes a standard 5-field cron expression evaluated in
**local time** (`minute hour day-of-month month day-of-week`), a `prompt`, and
`recurring` (default `true`; `false` = fire once then auto-delete). It returns an
8-character job ID for `CronDelete`. `CronList` lists them. Wildcards, steps, ranges and
lists are supported; extended syntax (`L`, `W`, `?`, `MON`/`JAN` aliases) is not. When
day-of-month and day-of-week are both constrained, a date matches if **either** does
(vixie-cron semantics).

**The limits that decide whether you may use it for a real loop:**

- **Session-scoped and in-memory.** The `durable` parameter is present but documented as
  having **no effect** — "durable persistence is not available". A new conversation clears
  every task; `--resume` / `--continue` restores unexpired ones.
- **Seven-day expiry.** A recurring task fires one final time 7 days after creation, then
  deletes itself. This is a hard ceiling on unattended lifetime.
- **Fires only while the REPL is idle.** Not mid-response. If Claude is busy when a task
  comes due, it waits for the turn to end.
- **No catch-up.** A missed window fires **once** on return to idle, never once per
  missed interval.
- **Jitter, and the sources disagree.** The docs say recurring tasks fire up to **30 min**
  late (or up to half the interval for sub-hourly jobs); the in-session tool description
  says up to **10% of the period, max 15 min**. Both agree one-shots at `:00`/`:30` can
  fire up to 90 s *early*, and that the offset is derived from the task ID (so it is
  stable per task). **Do not build a loop that depends on exact fire times.** Picking a
  minute that is not `:00`/`:30` avoids the one-shot jitter and spreads API load.
- **50 tasks per session.**
- `CLAUDE_CODE_DISABLE_CRON=1` disables the scheduler entirely — cron tools *and* `/loop`.

**Verdict for loop-ops:** `session-cron` is an **L1 supervised** host only. It cannot host
an unattended L2/L3 loop: it needs an open idle session and evaporates after 7 days.
`loop-doctor` treats `host: session-cron` at L2+ as a predicted runtime failure.

### `/loop` — the bundled skill, and its dynamic mode

`/loop` is not something you author; it ships with the harness and reads its argument in
three shapes:

| You type | Behaviour |
|---|---|
| `/loop 5m <prompt>` | fixed cron cadence. `s`/`m`/`h`/`d`; seconds round up to a minute; awkward steps (`7m`, `90m`) round to the nearest clean cron step and Claude says what it picked |
| `/loop <prompt>` | **dynamic (self-paced)** — Claude picks each delay itself |
| `/loop` (bare) | the built-in maintenance prompt, self-paced |

A skill can be the prompt (`/loop 20m /review-pr 1234`), but a scheduled fire only runs
skills Claude may invoke on its own — built-ins (`/permissions`, `/model`), skills marked
`disable-model-invocation: true`, skill deny-rules and MCP prompts arrive as plain text
instead of executing. **A loop whose tick is a slash command must check that the command
is model-invocable**, or every tick silently no-ops.

**Dynamic mode** is driven by the `ScheduleWakeup` tool. Each iteration Claude calls it
with a `delaySeconds` **clamped to [60, 3600]**, a `reason` shown back to the user, and a
`noop` flag (`true` = nothing changed; consecutive noop ticks collapse in the transcript).
`stop: true` ends the loop immediately. If an iteration neither reschedules nor stops, one
fallback wakeup fires ~20 minutes later and the loop ends if that one doesn't reschedule
either. `Esc` clears a pending self-paced wakeup.

**The two sentinels.** An autonomous `/loop` with no user prompt passes a literal sentinel
back as its `prompt` so the runtime can re-resolve the instructions at fire time. They are
**not interchangeable**:

- `<<autonomous-loop-dynamic>>` — for `ScheduleWakeup` (self-paced mode)
- `<<autonomous-loop>>` — for the `CronCreate` fixed-cadence mode

Passing the wrong one wires an autonomous loop to the wrong pacing engine.

**Customising the default.** `.claude/loop.md` (project, wins) or `~/.claude/loop.md`
(user) replaces the built-in maintenance prompt for a bare `/loop`. It is ignored whenever
you supply a prompt. Edits take effect on the next iteration — you can refine a running
loop's instructions in place. Content past **25,000 bytes is truncated**.

**Polling vs pushing.** The docs are explicit that where the `Monitor` tool is available,
streaming a background script's output beats re-running a prompt on an interval — cheaper
and more responsive. Reach for a cadence only when there is nothing to stream.

---

## `desktop-task` — the `scheduled-tasks` MCP server

The durable local host, and the closest native analogue to a loop-ops loop.

**Verified surface.** Four tools: `create_scheduled_task` (`taskId` kebab-case, `prompt`,
`description`, plus **at most one** of `cronExpression` (recurring, local time) or
`fireAt` (ISO-8601 with offset, one-time, auto-disables after firing) — omit both for an
ad-hoc task that only runs manually; `notifyOnCompletion` defaults true),
`list_scheduled_tasks` (returns `taskId`, schedule, `enabled`, `nextRunAt`, `lastRunAt`
and a `path` to the task's `SKILL.md`), `update_scheduled_task` (partial; `enabled: false`
pauses), `delete_scheduled_task` (leaves the `SKILL.md` on disk so the prompt is
recoverable).

**On-disk shape.** Each task is `<config-dir>/scheduled-tasks/<task-id>/SKILL.md` —
YAML frontmatter carrying `name` and `description`, body = the prompt. Schedule, folder,
model and enabled state live **outside** that file (edit them through the app or by
asking). The config dir is `~/.claude` unless `CLAUDE_CONFIG_DIR` overrides it.

**What this gives a loop for free — and the caveats:**

| Native feature | What it replaces | The caveat that still bites |
|---|---|---|
| The task folder | a place for `STATE.md` / `run-log.md` | nothing is written for you; the *prompt* must read and rewrite them |
| Fresh session per run | the Ralph property | **no memory of the creating conversation** — the prompt must be fully self-contained |
| Per-task permission mode + saved always-allow approvals | `--permission-mode` on a wrapper | a task in Manual mode that hits an unapproved tool **stalls** until you answer — the classic 3am-dead loop, natively |
| Worktree toggle | `worktree: true` + manual setup | **off by default** — a task runs against your working dir *including uncommitted changes* |
| Active/Paused status toggle | the kill switch | pausing is out-of-band; an in-prompt sentinel check still stops a run *mid-tick* |
| Run history incl. skipped runs + reasons | part of the run-log | it records *that* a run happened, not what the loop decided |

**Failure semantics you must design around:**

- **Only runs while the app is open and the machine is awake.** Sleep through a window and
  the run is skipped.
- **Exactly one catch-up.** On launch or wake, Desktop starts one catch-up run for the
  *most recently* missed time within the last 7 days and discards everything older. A
  daily task that missed six days runs **once**. The docs' own advice is the right advice:
  put time guardrails in the prompt ("only review today's commits; if it's after 5pm, skip
  and post a summary of what was missed").
- **Deterministic stagger** of a few minutes after the scheduled time.
- MCP tools marked `requiresUserInteraction` prompt every call and stall the run each time.
- A task can call `update_scheduled_task` on **itself** to change its own schedule or
  prompt. That is genuinely useful (reschedule earlier when a release branch appears) and
  it is also **self-modification** — put it on the escalation list unless the loop's stated
  purpose is adaptive cadence.

---

## `cloud-routine` — Routines (`/schedule`)

Research preview. Runs on Anthropic-managed cloud infrastructure, so it keeps working with
the machine off — at the cost of the local filesystem.

**Triggers are no longer cadence-only.** A routine may carry any combination of:

- **Schedule** — presets (hourly/daily/weekdays/weekly) or a cron set via `/schedule
  update`; **minimum interval one hour, faster expressions are rejected**. Also one-off
  runs at a timestamp, which auto-disable after firing and do **not** count against the
  daily run cap.
- **API** — a per-routine `/fire` endpoint. `POST` with a bearer token starts a run and
  returns a session URL. An optional `text` field carries run-specific context.
- **GitHub** — `pull_request` and `release` events, with filters (author, title, body,
  base/head branch, labels, draft, merged) combined by equals / contains / starts-with /
  one-of / regex. `matches regex` tests the **whole** field: use `.*hotfix.*`, not
  `hotfix`.

The API trigger matters for loop-ops: it is a **native event trigger that needs no
persistent session**, which is the thing [Channels](claude-code-loops.md) could not offer.
An `event`-triggered `monitor` or `ci-watch` loop no longer has to be a kept-alive
session — it can be an alerting system POSTing to `/fire`.

**Two security properties worth encoding in the loop's design:**

- **Fire text is untrusted by construction.** The `text` payload arrives wrapped in a
  `<routine-fire-payload>` block labelled as untrusted data. A routine's prompt must
  *opt in* by referencing the payload explicitly, or the text is inert context. Anyone
  holding the bearer token can send it, so this wrapper is the control that keeps a leaked
  token from becoming instruction injection. Treat it exactly as
  [prompt-injection-defense](../../prompt-injection-defense/SKILL.md) treats any ingested
  content. The token is shown **once** at generation; rotate via Regenerate/Revoke.
- **A native escalation gate on pushes.** Claude pushes to `claude/`-prefixed branches
  freely; a push to any other branch is **rejected** if the branch is protected, someone
  else has an open PR from it, or it carries commits authored by someone else. That is
  close to loop-ops' "never push to main" rule, enforced by the platform.

**No permission mode at all.** Routines "run autonomously as full Claude Code cloud
sessions: there is no permission-mode picker and no approval prompts during a run." The
boundary therefore *cannot* come from a permission mode — it comes from three other
places, and scoping them is the entire safety story:

1. **Repositories** selected (each cloned fresh from its default branch)
2. **Environment** network policy — the Default environment is *Trusted*, allowing only
   the default allowlist; off-list hosts fail `403 x-deny-reason: host_not_allowed`
3. **Connectors** — **all connected connectors are attached by default**, and Claude may
   use every tool from an included connector, writes included, without asking. Remove
   everything the routine does not need. This is the single most common over-grant.

**Other limits:** research preview (surface may change); the `/fire` endpoint ships behind
a dated beta header; GitHub webhook events have per-routine and per-account hourly caps
and events beyond them are **dropped**; there is a daily cap on runs started per account
(one-off runs exempt); routines belong to an individual account and act as that identity;
Team/Enterprise Owners can disable them org-wide.

**And the trap that looks like success:** a green status in the run list "means the session
started and exited without an infrastructure error. It does not mean the task in your
prompt succeeded." A loop that grades itself on run status is grading the wrong thing —
which is exactly why the loop's own `verify` gate stays load-bearing.

---

## What the native primitives replaced — and what they did not

The plumbing is theirs now. The discipline is still yours.

| Loop-ops primitive | Native answer (2026-08-30) | Still yours to build |
|---|---|---|
| **Schedule** | ✅ all four hosts | picking the host against the constraint, not the habit |
| **Fresh context per tick** | ✅ desktop-task, cloud-routine | writing a genuinely self-contained prompt |
| **Isolation** | ~ desktop-task worktree toggle (**off by default**) | worktree at L2+, and verifying it is on |
| **Kill switch** | ~ Paused toggle, `Esc`, `CronDelete` | an **in-prompt** sentinel check — the out-of-band ones can't stop a tick already running |
| **Run log** | ~ run history / skipped-run reasons | what the loop *decided* and what it cost |
| **State between ticks** | ❌ (the task folder is a place, not a spine) | `STATE.md` — [state-spine.md](state-spine.md) |
| **Budget** | ❌ (a daily run cap is not a token budget) | `budget_tokens`, enforced in the run prompt |
| **The verify gate** | ❌ (green status ≠ success) | `verify:` — and it is an eval, see below |
| **The escalation rule** | ~ routines' branch-push guard only | the full never-auto-land list |
| **The tier ladder** | ❌ | L1 → L2 → L3, earned |

**A loop's `verify` gate is an eval.** Everything the eval discipline says about scoring —
outcome vs step vs trajectory, `pass^k` over `pass@k` for anything non-deterministic,
judge bias, and gates that are blocking rather than advisory — applies to the gate that
decides land-vs-escalate. Invoke the **`evals-ops`** skill when the gate is a judgement
call rather than a green test run; a gate you cannot trust is a loop you cannot graduate.

---

## Choosing a host — the short version

```
Needs local files / build / tools?
  ├─ no  → cloud-routine        (machine off; ≥1h; scope repos+env+connectors, no perm mode)
  └─ yes → unattended?
            ├─ no  → session-cron (/loop)   L1 supervised only; 7-day expiry
            └─ yes → desktop-task           (durable, per-task perms, worktree toggle)
                     └─ need sub-minute cadence, or non-Claude-Code control?
                        → external + loop-run.sh
```

Declare the answer as `host:` in `loop.config.yaml`. `loop-doctor` checks the loop against
its host's real constraints — a cadence faster than the host allows, a local PATH check
that proves nothing about a cloud run, an unattended tier on a session-scoped host.

## See also

- [claude-code-loops.md](claude-code-loops.md) — which mechanism, and how to wire it.
- [risk-tiers.md](risk-tiers.md) — L1/L2/L3 ↔ permission modes; the scheduler-not-session rule.
- [state-spine.md](state-spine.md) — the STATE/run-log/budget spine none of these hosts provide.
- [failure-modes.md](failure-modes.md) — the incident catalog these limits produce.
