---
name: loop-ops
description: "Design and safely run OUTER loops - scheduled discover-triage-implement-verify-escalate agent loops. Native primitives schedule; loop-ops governs. Risk-tier ladder (L1 report -> L3 unattended), STATE/run-log/budget spine, kill switch, pattern catalog. Triggers: outer loop, scheduled/autonomous agent loop, PR watch, CI watch, dep-bump loop, run on a schedule, kill switch, risk tier, CronCreate, scheduled task, cloud routine, /loop."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "iterate, fleet-ops, fleet-worker, pigeon, git-ops, ci-cd-ops"
---

# Loop Ops — outer-loop design discipline

**A loop is not a prompt.** Turn-by-turn prompting puts you in the loop forever. *Loop
engineering* inverts it: you design a **recurring process with memory, verification, and
boundaries** that discovers work, hands it to agents, verifies the result, and decides —
on a schedule or until a goal is met — whether to **land it or escalate to a human**.

This is the **outer loop** above a single agent run, the twin of [`iterate`](../iterate/SKILL.md) (the inner loop); it composes what this repo already ships rather than reimplementing it: [references/composition-map.md](references/composition-map.md).

## Native primitives schedule; loop-ops governs

Claude Code now ships the *cadence* half natively. **Do not hand-roll a scheduler** — pick
a native host, declare it as `host:` in the config, and spend the discipline where the
primitives leave a hole. Verified surface, parameters and limits (2026-08-30):
[references/native-scheduling.md](references/native-scheduling.md).

`/loop` (session-scoped, 7-day expiry, L1 only) · Desktop scheduled tasks (durable local, worktree toggle off by default) · cloud routines (machine-off, 1 h floor, no permission mode, every connector attached) · `/goal` (a completion gate, not a cadence). Gives vs lacks: [references/native-primitives-at-a-glance.md](references/native-primitives-at-a-glance.md).

What **none** of them provide — and what this skill is for: a **state spine** that survives
ticks, a **token budget**, a **verify gate** you can trust, an **escalation rule**, and the
**risk-tier ladder** that decides whether the loop has earned the autonomy you're about to
grant it. The plumbing moved into the harness; the judgement did not.

### When the native primitive is enough — stop here

Don't scaffold a loop for work the harness already does. **Use the primitive raw** when
*all* of these hold:

- it **writes nothing** you'd have to undo (watch a deploy, poll a build, remind you), or
  the only writes are ones you'll review anyway;
- it is **supervised or short-lived** — you're watching, or it stops in a session;
- **nothing needs to be remembered between ticks** beyond what's in the repo;
- and you'd **shrug if a tick silently didn't fire**.

`/loop 5m check if the deploy finished` is a complete, correct answer. Wrapping it in a
`loop.config.yaml` adds ceremony and no safety.

Reach for loop-ops the moment **any one** of those flips: the loop starts *changing*
things, runs *unattended*, needs to know what it did *last time*, or its silence would
cost you. That is the whole trigger — everything below is what to do once it fires.

---

## The six primitives → what owns each here

Every durable loop rests on six primitives. The discipline is wiring them; the parts
already exist:

| Primitive | What it is | Owned in claude-mods by |
|---|---|---|
| **Schedule** | fire the loop on a cadence *or an event* | native-first, declared as `host:` — `session-cron` (`/loop`+`CronCreate`, L1 only), `desktop-task` (`scheduled-tasks` MCP: local + durable), `cloud-routine` (`/schedule`: machine-off, plus API/GitHub event triggers), `/goal` for completion. `external` (cron/Task Scheduler + `loop-run.sh`) only for non-Claude-Code control |
| **Worktree** | isolated, discardable execution context | `git-ops` worktrees, `fleet-worker` (per-task worktree) |
| **Skills** | persistent project knowledge the run loads | this repo's skill layer + your `CLAUDE.md` |
| **Sub-agents** | maker/checker separation | `Agent`/`Task`; dispatching skills (`review`, `testgen`) |
| **Connectors** | reach tickets / CI / chat | MCP tools, `gh`, `github-ops` |
| **+ State** | a durable spine *outside* the conversation | `STATE.md` + run-log + budget (this skill) |

The inner improvement loop is `iterate`; cheap parallel makers are `fleet-worker`; the
test-gated merge queue is `fleet-ops`; inter-loop signalling is `pigeon`. `loop-ops` is
the doctrine that connects them.

## Loop anatomy

```
   ┌──────────────────────────────────────────────────────────────┐
   │  SCHEDULE (cadence)                                           │
   │     └─▶ TRIAGE      read STATE.md → pick the next unit of work │
   │           └─▶ WORKTREE   isolate (git worktree)               │
   │                 └─▶ MAKER     implementer run (or fleet-worker)│
   │                       └─▶ CHECKER  verify gate + guard (tests) │
   │                             └─▶ GATE  safe & allowlisted?      │
   │                                   ├─ yes → LAND  (commit/PR)   │
   │                                   └─ no  → ESCALATE (+context) │
   │     └─▶ write STATE.md, append run-log, decrement budget ──────┘
```

The **gate** is the load-bearing decision. Everything before it is mechanical; the gate
is where a loop earns the right to run unattended — or doesn't.

## The risk-tier ladder (the heart of the discipline)

Never start a loop unattended. Graduate it. Each tier maps to a concrete Claude Code
**permission mode** — full mapping, the headless-profile table, and the *enumerate vs
isolate* fork in [references/risk-tiers.md](references/risk-tiers.md).

| Tier | Posture | Permission mode | May do | Lands by |
|---|---|---|---|---|
| **L1 Report** | read-only discovery + triage | `plan` / `dontAsk`+read allowlist | scan, summarize, propose — **writes nothing** | a human reads the report |
| **L2 Assisted** | suggest changes, human gates the merge | `dontAsk`+narrow allowlist, or `auto` | edit in a **worktree**, run tests, open a PR | a human approves the PR (or `fleet-ops`) |
| **L3 Unattended** | autonomous land within a denylist | `bypassPermissions` **in an isolated container only** | commit/merge allowlisted classes | the loop itself, inside its boundary |

**The host is part of the tier.** `session-cron` (`/loop` + `CronCreate`) cannot host L2+
at all: it needs an open idle session and every recurring job expires after 7 days.
`cloud-routine` has *no permission mode*, so its tier is expressed as repos + environment
network policy + connectors instead — which means a routine is effectively autonomous the
moment it is created, and the L1 posture has to come from the prompt being read-only.
`loop-doctor` enforces both. Details: [references/native-scheduling.md](references/native-scheduling.md).

The cardinal rule, straight from Claude Code's own gate model: **an unattended loop is a
*scheduler/script that invokes `claude -p`*, not a Claude session that spawns ungated
children.** A session in `auto` mode that tries to launch a `--permission-mode
bypassPermissions` child is blocked as *Create Unsafe Agents* — by design. See
[references/risk-tiers.md](references/risk-tiers.md) and the repo's
[auto-mode-classifier reference](../../docs/AUTO-MODE-CLASSIFIER.md).

## The escalation gate

What a loop may **land** vs what it must **escalate** is not a vibe — it mirrors Claude
Code's classifier tiers. Bake these into the config's `escalation:` field:

- **Always escalate (never auto-land):** force-push, push to `main`, production deploys
  or migrations, mass deletion, granting IAM/repo permissions, anything destroying
  pre-session files, editing `.claude/`/settings (self-modification), `curl | bash`.
- **Safe to auto-land at L2/L3 (when allowlisted):** a green PR on a feature branch,
  a lockfile patch bump that passes the guard, a generated changelog draft, a label/
  triage classification, a comment.
- **The test:** *would a careful human let this happen unattended in this repo?* If the
  action's blast radius exceeds the loop's stated purpose, it escalates. A general goal
  ("keep CI green") is **not** authorization for a specific high-blast action it implies.
- **Scope the tools, not just the mode.** Allowlist exactly the tools/MCP connectors the
  job needs (read-only at L1); keep `gh pr merge` out and `land_via: fleet-ops` in. Full
  connector/MCP-scope discipline + the auto-merge guard: [references/risk-tiers.md](references/risk-tiers.md).
  On a **cloud routine this is the whole gate** — there is no permission mode, and every
  connected connector is attached by default with full write access. Prune them.
- **A task that reschedules itself is self-modification.** The `scheduled-tasks` MCP lets a
  running task call `update_scheduled_task` on its own schedule or prompt. Useful, and on
  the always-escalate list unless adaptive cadence is the loop's *stated* purpose — a loop
  that can rewrite its own trigger has left the boundary you audited.

## The state spine

A loop's memory lives **outside** the conversation, in three files (schemas +
read/write contract in [references/state-spine.md](references/state-spine.md)):

- **`STATE.md`** — the triage snapshot: priority / watch / noise + a readiness line.
  Read at the top of every run, rewritten at the end.
- **`run-log.md`** — append one line per run (timestamp, action, outcome, tokens). The
  audit trail that answers "what has this loop been doing?"
- **`loop.config.yaml`** — the loop's definition (goal, tier, cadence, **host**, scope,
  gate, budget, escalation). Scaffolded by `loop-scaffold`, scored by `loop-check`.

## Pattern catalog (a morphology, not a fixed list)

Patterns are **compositions of three axes** — `trigger` (cadence / **event** via a Channel
/ `goal`) × `posture` (L1/L2/L3) × `locus` (connector→cloud routine / local→Desktop task).
The named patterns are well-trodden points in that space; compose your own from the axes.
Full recipes + the morphology in [references/pattern-catalog.md](references/pattern-catalog.md):

Named patterns, L1: `daily-scan`, `pr-watch`, `changelog-gen`, `merge-hygiene`, `issue-sort`, `regression-watch`, `digest`, `monitor`, `freshness`. L2: `ci-watch`, `dep-bump`, `metric-chase` (goal), `backfill` (goal). Trigger, locus and job for each: [references/pattern-catalog.md](references/pattern-catalog.md).

Start any pattern at L1. Graduate to L2 only after the L1 reports prove its judgment.
**Prefer `event` over `cadence`** where a webhook exists (cheaper, faster than polling).

## Multi-loop coordination & the kill switch

Running several loops? Two non-negotiables (detail in
[references/state-spine.md](references/state-spine.md)):

- **Priority order** prevents collisions: `CI Watch → PR Watch → Dependency Bump →
  Merge-Hygiene/Changelog → Daily Scan (off-peak)`. A higher-priority loop's
  worktree wins; lowers defer. Loops signal each other via [`pigeon`](../pigeon/SKILL.md).
- **A kill switch every loop honors.** A single stop signal — a `PAUSED` sentinel file
  or a `loop-pause` label — that every loop checks at the top of its run and exits on.
  No loop ships without one. Put it in `kill_switch:` and check it first.

## Composition map — don't rebuild what exists

Compose, don't rebuild: `iterate` (one metric, one session), `fleet-worker` (cheap parallel makers, model routing), `fleet-ops` (test-gated landing), a native `host:` for cadence and events, **`evals-ops`** to trust the verify gate, `claude-api-ops` for per-tick cache cost, `git-ops`/`github-ops` for commits and PRs, `pigeon` between loops. Table: [references/composition-map.md](references/composition-map.md).

---

## Tools

Six scripts, all following the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md)
(stdout = data, semantic exit codes, `--help` with EXAMPLES, `--json` envelopes): **init**
scaffolds the loop, **audit** scores whether the config is *well-formed*, **doctor**
preflights whether it will actually *run* (host-aware), **cost** estimates spend
(caching-aware), and two drift guards — **check-pricing-sync** for the pricing table and
**check-native-facts** for the native-scheduling limits. The discipline before scheduling
is `init → fill → cost → audit → doctor --live`.

Scripts: `scripts/loop-scaffold.sh` (init), `scripts/loop-check.sh` (audit; exit 10 = not ready), `scripts/loop-doctor.sh` (doctor; exit 10 = predicted runtime failure), `scripts/loop-estimate.py` (cost), `scripts/check-pricing-sync.py` and `scripts/check-native-facts.py` (drift guards). Flags, examples and host-specific behaviour: [references/tools.md](references/tools.md).

---

## End-to-end workflow

1. **Pick a pattern** from the catalog (or `custom`), and **pick the host** — does the tick
   need local files? must it run with the machine off? is it supervised? Start at **L1**.
2. **Scaffold:** `bash scripts/loop-scaffold.sh --name <n> --pattern <p> --tier L1
   --host <h>`.
3. **Fill `loop.config.yaml`** — the real `goal`, `scope` (bounded globs, never `*`),
   `verify` gate, `escalation` rule, `budget_tokens`, `kill_switch`. On a `cloud-routine`,
   name the boundary that replaces the absent permission mode: repos, environment network
   policy, and the connectors you kept.
4. **Cost it:** `python scripts/loop-estimate.py --pattern <p> --cadence <c> --model <m>` —
   sanity-check the monthly spend against the value.
5. **Audit it:** `bash scripts/loop-check.sh .loops/<n>/loop.config.yaml` — fix every
   error before scheduling. Don't schedule a loop that fails its own audit.
6. **Doctor it:** `bash scripts/loop-doctor.sh --live .loops/<n>/loop.config.yaml` — prove
   it will actually *run* (gate binary on PATH, budget fits a tick). Audit = well-formed;
   doctor = will-run.
7. **Schedule** the L1 run on the declared host, picked with the recipe selector in [references/claude-code-loops.md](references/claude-code-loops.md): connector-driven → cloud routine; local code → Desktop scheduled task; sustained and token-sensitive → cache-warm daemon, not `/loop`; fixed criteria → `/goal`; quick supervised polling → `/loop`. L1 is read-only: it writes `STATE.md` + a report.

8. **Read the reports.** Only after the loop's judgment is proven do you graduate it to
   **L2** (worktree + guard + `fleet-ops` landing), change `host:` if the proving host was
   `session-cron`, and re-audit at the higher tier. If the gate's verdict is a judgement
   rather than a green test run, harden it with the **`evals-ops`** discipline before you
   let it decide unattended.

## Worked example

A complete, audit- and doctor-clean L1 loop ships at [assets/examples/pr-watch/](assets/examples/pr-watch/): copy it, adjust scope and cadence, run `loop-check` + `loop-doctor --live`, then point your scheduler at its `loop-run.sh`. Detail: [references/tools.md](references/tools.md).

## Anti-patterns (these are detected and wrong)

The incident-shaped catalog — symptom → mechanism → the control that catches each — is
[references/failure-modes.md](references/failure-modes.md) (runaway budget, the 3am-dead
loop, cache-cold, force-push, ungated-child spawn, colliding loops, silent-stop,
gate reward-hacking, and the native-host trio — the **expired** 7-day loop, the
**over-connected** routine, the **stalled/skipped** Desktop task). The headline ones:

- **Routing around the gate.** Wrapping `claude -p --permission-mode bypassPermissions`
  in a script to dodge the classifier is *Auto-Mode Bypass* — a `hard_deny` nothing
  clears. If an outcome is blocked, **authorize it** (a narrow allow rule, or run the
  scheduler outside the auto-mode session), never **disguise it**.
- **The orchestrator session spawning ungated children.** A session in `auto` mode is
  the wrong place to launch the loop. The scheduler/cron/Task-Scheduler/CI runner that
  invokes `claude -p` is the authorizer. See [references/risk-tiers.md](references/risk-tiers.md) §"enumerate vs isolate".
- **No gate.** A loop whose `verify:` is empty is not a loop, it's an unsupervised typer.
  `loop-check` errors on it. Nor is a *green run status* a gate: on a cloud routine green
  means "the session started and exited without an infrastructure error", never that the
  task succeeded. Grade the work, not the process.
- **Assuming the native host gave you a boundary.** It gave you a cadence. A Desktop task's
  worktree toggle is off by default; a cloud routine has no permission mode and attaches
  every connector; `/loop` evaporates after 7 days. Each is a default that reads as safe
  and isn't.
- **Unbounded scope.** `scope: "*"` means "may touch anything" — the audit rejects it.
- **No kill switch / no budget.** A loop you can't stop, or whose spend you didn't
  bound, will eventually surprise you. Both are audit findings.
- **Skipping L1.** Starting a fresh loop at L3 is how comprehension debt and incidents
  compound. The ladder exists precisely so trust is *earned* before it's *granted*.

## See also

References: [risk-tiers](references/risk-tiers.md) · [pattern-catalog](references/pattern-catalog.md) · [state-spine](references/state-spine.md) · [native-scheduling](references/native-scheduling.md) · [claude-code-loops](references/claude-code-loops.md) · [failure-modes](references/failure-modes.md) · [native-primitives-at-a-glance](references/native-primitives-at-a-glance.md) · [composition-map](references/composition-map.md) · [tools](references/tools.md). Starters: [loop.config.template.yaml](assets/loop.config.template.yaml), [STATE.template.md](assets/STATE.template.md), [run.template.md](assets/run.template.md). What each covers: [references/reference-index.md](references/reference-index.md).
