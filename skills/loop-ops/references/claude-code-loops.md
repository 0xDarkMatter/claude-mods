# Where Loops Actually Live in Claude Code

The outer loop is a *cadence + a headless run*. This file is the mechanics: the concrete
ways to fire a loop in Claude Code, when to use each, and how they compose with the tier
model. The doctrine — *a scheduler invokes `claude -p`, not a session that spawns ungated
children* — is in [risk-tiers.md](risk-tiers.md); this is the how.

---

A loop is two things, and Claude Code has **native** answers to both: a **cadence** (when
a tick fires) and a **completion** rule (when the work stops). **Prefer the native
mechanisms — they're zero/low-infra and need no GitHub Actions.** Reach for an external
scheduler only when you want non-Claude-Code control.

## Cadence — when a tick fires

| Mechanism | Runs on | Local files? | Open session? | Min interval | Best for |
|---|---|---|---|---|---|
| **`/loop`** | your machine | ✅ | **yes** | 1 min | supervised, in-session polling (L1) |
| **Desktop scheduled task** | your machine | ✅ | no | 1 min | **the local-first unattended default** — loops that touch the repo/build/tools |
| **Cloud routine** (`/schedule` → [Routines](https://code.claude.com/docs/en/routines)) | **Anthropic cloud** | ❌ **fresh clone** | no | **1 hour** | unattended loops needing **no** local state (GitHub PRs, web) |
| **`ScheduleWakeup`** | your machine | ✅ | yes | — | self-pacing one long task |
| external scheduler + `loop-run.sh` | your machine | ✅ | no | your call | non-Claude-Code control: cron / Task Scheduler / systemd / process-compose / CI |
| **GitHub Actions** | GH runner | fresh clone | no | — | *optional* — only if the repo already lives on GitHub |

> **Load-bearing caveat:** **cloud routines run on a fresh clone with no access to your
> local files.** A loop that touches a local repo, build, model dir, or tool **cannot** be
> a cloud routine — use a **Desktop scheduled task** or `/loop`. Cloud routines are for
> cloud-reachable, local-state-free work only.

The unattended options (Desktop task, cloud routine, external scheduler, Actions) are the
human-configured **authorizer** — no parent auto-mode session, so nothing blocks the
headless child. Upstream loop-engineering is GitHub-Actions-centric; loop-ops is
runner-agnostic and **native-first** on purpose.

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
| **Sustained / heavy cadence where tokens matter** | a **deterministic daemon** (or cron) firing `claude -p` — **not** `/loop` | `/loop` runs in one *growing* session: context accumulates, tokens climb, quality drifts past ~150k. A daemon fires a **fresh** `claude -p` each tick — bounded cost, no drift — and is deterministic. **Wake it just under the 5-min prompt-cache TTL (~240–270 s)** so the static `run.md`+system prefix stays cache-warm and each tick reads it at ~0.1×. Fresh context *and* cache reads — the cheap sustained-loop recipe. |
| **Supervised, light, you're watching** | **`/loop`** | Quickest to start, in-session — perfect for a short burst ("watch this deploy"). But it's **token-hungry if left running heavy**; graduate to a daemon for anything sustained. |
| **Long task with a fixed, verifiable end state** — "migrate until tests pass", "split until each file < N lines", "drain the labeled backlog" | **`/goal`** (+ auto mode) | Runs turn-after-turn until a fast model confirms the criteria, then stops — a *completion gate*, not a cadence. Auto mode makes each turn unattended; bound with `or stop after N turns`. |

**Cadence × completion compose.** A recurring loop whose every tick should run *to
completion* = a cadence mechanism driving `claude -p "/goal <tick condition>"`. E.g. a
Desktop task (or daemon) every morning running `/goal` over the issue backlog.

### The economics (why the daemon beats `/loop` at scale)

Cadence is the top cost lever, **caching is the next** ([state-spine.md](state-spine.md),
[loop-cost](../scripts/loop-cost.py)). The two interact:

- **`/loop`** keeps one session alive; its input grows every iteration (accumulating
  transcript), so cost climbs and the cache helps less. Great for short supervised runs.
- **A daemon/cron `claude -p`** starts fresh each tick (the Ralph property → flat per-tick
  cost) and, fired **under the 5-min cache TTL**, keeps the static prefix warm (~0.1× reads).
  `loop-cost --cadence 5m` will show this; a 6 h loop can't cache at all.

A minimal local daemon (no scheduler infra) — wake under the cache window, fresh context each tick:

```bash
# fires loop-run.sh every ~4.5 min: fresh `claude -p`, prefix stays cache-warm
while true; do .loops/<name>/loop-run.sh; sleep 270; done
# or run it under process-compose / a systemd timer / nohup for boot persistence
```

---

## The external-scheduler shape (when you're not using a native mechanism)

Native paths (Desktop task, cloud routine, `/loop`) run the tick prompt — or
`claude -p "/goal …"` — **directly**, so they need no wrapper. When you instead drive the
loop from an **external** scheduler (cron / Task Scheduler / systemd / process-compose /
CI — e.g. for sub-minute cadence or to fit existing infra), `loop-init` scaffolds a
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
*/10 * * * *  /path/.loops/pr-babysitter/loop-run.sh >> /path/.loops/pr-babysitter/tick.log 2>&1

# Windows Task Scheduler (every 10 min; S4U logon, see windows-ops for the hardened form):
schtasks /Create /SC MINUTE /MO 10 /TN pr-babysitter \
  /TR "bash -lc '/c/path/.loops/pr-babysitter/loop-run.sh'"

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
