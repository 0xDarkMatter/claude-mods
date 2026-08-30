# Where Loops Actually Live in Claude Code

The outer loop is a *cadence + a headless run*. This file is the mechanics: the concrete
ways to fire a loop in Claude Code, when to use each, and how they compose with the tier
model. The doctrine — *a scheduler invokes `claude -p`, not a session that spawns ungated
children* — is in [risk-tiers.md](risk-tiers.md); this is the how. The primitives
themselves — every parameter, limit and failure semantic, verified and date-stamped — are
in [native-scheduling.md](native-scheduling.md); read that before trusting a number here.

---

A loop's **trigger** answers *when a tick fires* — a **cadence** (poll on a clock) or an
**event** (something pushed in from outside) — and its **completion** rule answers *when
the work stops*. Claude Code has native answers to all three. **Prefer the native
mechanisms — zero/low-infra, no GitHub Actions.** Reach for an external scheduler only for
non-Claude-Code control.

## Cadence — when a tick fires

| Mechanism | `host:` | Runs on | Local files? | Open session? | Min interval | Best for |
|---|---|---|---|---|---|---|
| **`/loop`** (bundled skill) + `CronCreate` | `session-cron` | your machine | ✅ | **yes, idle** | 1 min | supervised, in-session polling (**L1 only** — 7-day expiry) |
| **`ScheduleWakeup`** — `/loop`'s dynamic mode | `session-cron` | your machine | ✅ | yes | 60 s–1 h clamp | self-pacing one task; Claude picks each delay |
| **Desktop scheduled task** (`scheduled-tasks` MCP) | `desktop-task` | your machine | ✅ | no (app open) | 1 min | **the local-first unattended default** — loops that touch the repo/build/tools |
| **Cloud routine** (`/schedule` → [Routines](https://code.claude.com/docs/en/routines)) | `cloud-routine` | **Anthropic cloud** | ❌ **fresh clone** | no | **1 hour** | unattended loops needing **no** local state (GitHub PRs, web, connectors) |
| external scheduler + `loop-run.sh` | `external` | your machine | ✅ | no | your call | non-Claude-Code control: cron / Task Scheduler / systemd / process-compose / CI |
| **GitHub Actions** | `external` | GH runner | fresh clone | no | — | *optional* — only if the repo already lives on GitHub |

Declare the choice as `host:` in `loop.config.yaml`; `loop-doctor` then enforces that
host's real constraints instead of assuming a local `claude -p`.

> **Three load-bearing caveats, all verified 2026-08-30:**
>
> 1. **Cloud routines run on a fresh clone with no access to your local files.** A loop
>    that touches a local repo, build, model dir, or tool **cannot** be a cloud routine —
>    use a Desktop scheduled task or `/loop`. They also have **no permission mode at all**:
>    the boundary is repos + environment network policy + connectors, and *every* connected
>    connector attaches by default.
> 2. **`/loop` and `CronCreate` are session-scoped and expire.** In-memory, gone on a new
>    conversation (`--resume` restores unexpired ones), fire only while the session is
>    **idle**, and every recurring job **self-deletes 7 days after creation**. That makes
>    `session-cron` an L1-supervised host — never the home of an unattended loop.
> 3. **A Desktop task's worktree toggle is OFF by default**, so a run works against your
>    working directory *including uncommitted changes*. At L2+ turn it on, or the loop's
>    "isolation" is imaginary.

The unattended options (Desktop task, cloud routine, external scheduler, Actions) are the
human-configured **authorizer** — no parent auto-mode session, so nothing blocks the
headless child. Many loop frameworks are CI/Actions-centric; loop-ops is
runner-agnostic and **native-first** on purpose.

## Event — when something happens (routine triggers, Channels)

Polling burns tokens while nothing changes and lags the thing it watches. There are now
**three** ways to fire on an event instead of a timer, and they differ in whether a session
must stay alive:

| Event source | Needs a live session? | Fires |
|---|---|---|
| **Routine API trigger** — `POST /fire` + bearer token | **no** | your alerting system, deploy pipeline or internal tool starts a cloud run |
| **Routine GitHub trigger** — `pull_request` / `release` + filters | **no** | a repo event starts a cloud run |
| **Channel** — an MCP plugin pushing into a session | **yes** | anything you can build a receiver for |

The routine triggers are the important addition: **a native event loop no longer has to be
a kept-alive background session.** An alert-triage or deploy-verification loop is an API
trigger; a PR-review loop is a GitHub trigger with filters. Both carry the cloud-routine
constraints above. `text` sent to `/fire` arrives wrapped in a `<routine-fire-payload>`
block **labelled untrusted** — the prompt must explicitly opt in to acting on it, which is
what stops a leaked bearer token from becoming instruction injection.

A [**Channel**](https://code.claude.com/docs/en/channels) (v2.1.80+, research preview) is an
MCP plugin that **pushes** an external event — a CI failure, an error-tracker alert, a
deploy webhook, a chat message — straight into a running session, so the tick fires *on the
event* instead of on a timer.

- **Cheaper + faster than polling** — no idle ticks; the loop reacts the instant the event
  lands. The right trigger for `ci-watch`, `pr-watch`, `monitor`.
- **The trade-off:** an event arrives only while a session is open, so an unattended
  event-loop is a **persistent background session** (`claude --channels plugin:<name> …`,
  or `-p` for non-interactive) kept alive — not a fully-detached cron. Detachment traded
  for responsiveness.
- **Setup:** install a channel plugin (Telegram/Discord/iMessage ship in the preview; build
  a [webhook receiver](https://code.claude.com/docs/en/channels-reference) for CI/error/
  deploy), launch with `--channels`, lock the sender allowlist. Anthropic-auth only (not
  Bedrock/Vertex/Foundry).
- **Still gated** — an event-driven tick runs under the same permission mode + allowlist as
  any other; a webhook firing the loop never widens what it may do.

## Completion — when the work stops: `/goal`

[`/goal <condition>`](https://code.claude.com/docs/en/goal) (v2.1.139+) keeps the session
working turn-after-turn until a small fast model confirms the condition holds, then
auto-clears — the **native inner-loop gate**. It's the native expression of a loop's
`verify`/Until rule: *"keep going until the acceptance criteria hold."* Bound it with
`or stop after N turns`. It's a session-scoped **prompt-based Stop hook**, and it pairs
with auto mode (auto removes per-*tool* prompts; `/goal` removes per-*turn* prompts).
Headless, one tick to completion:

```bash
claude -p "/goal all tests in test/auth pass and lint is clean, or stop after 20 turns"
```

`/loop`'s **dynamic mode** carries its own completion rule: Claude ends the loop itself by
calling `ScheduleWakeup` with `stop: true` once the task is done, and an iteration that
neither reschedules nor stops gets one ~20-minute fallback wakeup before the loop ends.
That is a *self-judged* stop, so it is weaker than `/goal`'s explicit condition — use it
for exploratory watching, not as a loop's `verify` gate.

**The fully-native, zero-external-infra loop** = a **Desktop scheduled task** (local, has
files, no open session) that runs `claude -p "/goal <tick condition>"` against the STATE
spine. No cron, no Task Scheduler, no Actions.

---

## Which mechanism? — the recipe selector

These mechanisms are **not interchangeable** — each has a load-bearing trade-off. Pick by
answering: does it need **local code**, is it **connector-driven**, is it **recurring** or
**run-to-completion**, and **does token cost matter**?

| Your situation | Prescribed recipe | The trade-off that decides it |
|---|---|---|
| **Connector work, no local code** — triage email, Asana, Slack, calendar, issues via your claude.ai connectors | **Cloud routine** (`/schedule`) | Runs unattended in the cloud and **keeps all your claude.ai connectors** — email/Asana/tools work with your machine *off*. The fresh-clone/no-local-files limit doesn't bite because the work isn't in your repo. (≥1-hour cadence.) |
| **Touches local code / build / tools**, unattended | **Desktop scheduled task**, or a **background daemon** running `claude -p` | Both have local files and need no open session. The daemon adds fresh context per tick + deterministic, tunable cost (next row). |
| **Sustained / heavy cadence where tokens matter** | a **deterministic daemon** (or cron) firing `claude -p` — **not** `/loop` | `/loop` runs in one *growing* session: context accumulates, tokens climb, quality drifts past ~150k. A daemon fires a **fresh** `claude -p` each tick — bounded cost, no drift — and is deterministic. **Wake it inside the cache TTL you're paying for** so the static `run.md`+system prefix stays warm and each tick reads it at ~0.1×: ~240–270 s for the default 5-minute TTL, or up to ~55 min if the prefix is written with `"ttl": "1h"`. Fresh context *and* cache reads — the cheap sustained-loop recipe. |
| **Supervised, light, you're watching** | **`/loop`** | Quickest to start, in-session — perfect for a short burst ("watch this deploy"). But it's **token-hungry if left running heavy**; graduate to a daemon for anything sustained. |
| **Long task with a fixed, verifiable end state** — "migrate until tests pass", "split until each file < N lines", "drain the labeled backlog" | **`/goal`** (+ auto mode) | Runs turn-after-turn until a fast model confirms the criteria, then stops — a *completion gate*, not a cadence. Auto mode makes each turn unattended; bound with `or stop after N turns`. |

**Cadence × completion compose.** A recurring loop whose every tick should run *to
completion* = a cadence mechanism driving `claude -p "/goal <tick condition>"`. E.g. a
Desktop task (or daemon) every morning running `/goal` over the issue backlog.

### The economics (why the daemon beats `/loop` at scale)

Cadence is the top cost lever, **caching is the next** ([state-spine.md](state-spine.md),
[loop-estimate](../scripts/loop-estimate.py)). The two interact:

- **`/loop`** keeps one session alive; its input grows every iteration (accumulating
  transcript), so cost climbs and the cache helps less. Great for short supervised runs.
- **A daemon/cron `claude -p`** starts fresh each tick (the Ralph property → flat per-tick
  cost) and, fired **inside the cache TTL**, keeps the static prefix warm (~0.1× reads).
  **The TTL is a choice, not a constant:** 5 minutes by default (1.25× write), or 1 hour
  with `"ttl": "1h"` (2× write) — so the practical daemon window is ~4.5 min *or* ~55 min.
  `loop-estimate` picks the cheapest TTL that stays warm at your cadence and says which;
  past 1 h nothing caches. Break-even and the multipliers:
  [claude-api-ops caching-and-cost](../../claude-api-ops/references/caching-and-cost.md).
  The same reasoning is why an in-session `/loop` gains less: its input *grows*, so the
  cached prefix is a shrinking share of each tick — the fresh-context daemon is what keeps
  the cacheable part dominant.

A minimal local daemon (no scheduler infra) — wake under the cache window, fresh context each tick:

```bash
# fires loop-run.sh every ~4.5 min: fresh `claude -p`, prefix stays cache-warm (5m TTL)
while true; do .loops/<name>/loop-run.sh; sleep 270; done
# with a 1h-TTL cache write on the prefix, ~55 min still reads warm: sleep 3300
# or run it under process-compose / a systemd timer / nohup for boot persistence
```

---

## The external-scheduler shape (when you're not using a native mechanism)

Native paths (Desktop task, cloud routine, `/loop`) run the tick prompt — or
`claude -p "/goal …"` — **directly**, so they need no wrapper. When you instead drive the
loop from an **external** scheduler (cron / Task Scheduler / systemd / process-compose /
CI — e.g. for sub-minute cadence or to fit existing infra), `loop-scaffold` scaffolds a
**`loop-run.sh`** in the loop dir as the runner-agnostic glue. No GitHub Actions required.

```
   any scheduler ──▶ .loops/<name>/loop-run.sh
   (the authorizer)      ├─ kill switch first (PAUSED sentinel) → exit if set
                         ├─ claude -p "$(cat run.md)" --permission-mode dontAsk \
                         │     --append-system-prompt "$(cat STATE.md)" --allowedTools …
                         └─ git add/commit STATE.md + run-log.md (if in a repo)
```

Wire it with whatever you already run — **no cloud dependency**:

```bash
# cron (Linux/macOS):
*/10 * * * *  /path/.loops/pr-watch/loop-run.sh >> /path/.loops/pr-watch/tick.log 2>&1

# Windows Task Scheduler (every 10 min; S4U logon, see windows-ops for the hardened form):
schtasks /Create /SC MINUTE /MO 10 /TN pr-watch \
  /TR "bash -lc '/c/path/.loops/pr-watch/loop-run.sh'"

# process-compose / systemd timer / a while-sleep loop — all work; loop-run.sh is just a script.
```

- The **scheduler** (not a Claude session) invokes `loop-run.sh`. It is the
  human-configured authorizer; nothing upstream gates the run.
- `--permission-mode dontAsk` + a curated allowlist = a **gated** worker that runs
  anywhere. (For L3 arbitrary-execution jobs, swap to a container + `bypassPermissions` —
  see the enumerate-vs-isolate fork in [risk-tiers.md](risk-tiers.md).)
- The run prompt (`run.md`) is the same every tick — fresh context each time (the Ralph
  property). State survives in `STATE.md` + the codebase + git, not the conversation.
- **GitHub Actions** is one option, not a requirement — the worked example ships an
  optional `github-actions.yml` for repos already on GitHub; everyone else uses the local
  schedulers above.

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

1. **L1, supervised:** `/loop 15m` in a session (`host: session-cron`), running a
   read-only "report PR state to STATE.md" prompt. You watch it; it writes nothing but the
   snapshot. Permission mode `plan`. Remember the 7-day expiry — this host is for the
   proving period, not the destination.
2. **Prove judgment:** read a week of `STATE.md` snapshots + the run-log. Is its triage
   right? Does readiness hold?
3. **L2, unattended:** move the host — `desktop-task` if the loop touches local code,
   `cloud-routine` if it doesn't, `external` for sub-minute cadence — and update `host:`
   so `loop-doctor` checks the right constraints. Switch the
   run prompt to "open a fix PR in a worktree" with `--permission-mode dontAsk` + a narrow
   allowlist (`Bash(npm test)`, `Bash(git …)`). Add a `guard`, set `land_via: fleet-ops`,
   write the `escalation` rule. Re-run `loop-check` at L2 — fix every error — then enable.

The point of the ladder: the cadence mechanism *changes* (session `/loop` → scheduled
`claude -p`) exactly when the autonomy does, and the audit gates the transition.

## See also

- [native-scheduling.md](native-scheduling.md) — the primitives themselves: verified parameters, limits and failure semantics per host.
- [risk-tiers.md](risk-tiers.md) — the permission-mode mapping + scheduler-not-session rule.
- [state-spine.md](state-spine.md) — the STATE.md the run reads and rewrites.
- [../../claude-code-ops/SKILL.md](../../claude-code-ops/SKILL.md) — the full hook catalog, `claude -p` flags, headless reference.
