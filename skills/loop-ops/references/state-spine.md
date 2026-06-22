# The State Spine — memory outside the conversation

A loop's durability comes from state that lives **outside** the conversation window. The
conversation is ephemeral and degrades as it fills (the Ralph insight: quality drops past
~100–150k tokens). The spine is three files the loop reads at the start of every run and
writes at the end. This is the loop's working memory, audit trail, and definition.

```
.loops/<name>/
├── loop.config.yaml    # the definition (immutable-ish; edited by a human)
├── STATE.md            # the triage snapshot (rewritten every run)
└── run-log.md          # append-only audit trail (one line per run)
```

`loop-init` scaffolds all three. The config is human-owned; `STATE.md` and `run-log.md`
are loop-owned.

---

## `loop.config.yaml` — the definition

Flat YAML so it's trivially parseable (no `yq` dependency). Full annotated template:
[../assets/loop.config.template.yaml](../assets/loop.config.template.yaml). Fields:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | the loop's identifier; matches the directory |
| `pattern` | yes | a catalog key (`pr-babysitter`, …) or `custom` |
| `tier` | yes | `L1` / `L2` / `L3` — the autonomy rung |
| `cadence` | yes | `10m` / `1h` / `6h` / `1d`, or a cron string |
| `goal` | yes | one sentence: what this loop does and what it must NOT do |
| `scope` | yes | bounded globs the loop may touch — **never `*`** |
| `verify` | L2+ | the gate command (the metric/check); a loop with no gate is invalid |
| `guard` | L2+ | a must-always-pass command (full suite / typecheck) |
| `permission_mode` | yes | `plan` / `dontAsk` / `auto` / `acceptEdits` / `bypassPermissions` |
| `worktree` | L2+ | `true` to isolate code changes in a git worktree |
| `escalation` | yes | what the loop escalates instead of doing (the gate rule) |
| `budget_tokens` | rec | per-run output-token ceiling |
| `kill_switch` | yes | the stop signal every run checks first |
| `land_via` | L2+ | who gates + lands winning branches (e.g. `fleet-ops`) |

`loop-audit` reads this file and scores it against the tier's requirements.

---

## `STATE.md` — the triage snapshot

Rewritten at the end of every run; read at the top of the next. It is **not** a database
— it's a lightweight snapshot of what the loop needs, what it's watching, and what it
ignored. Template: [../assets/STATE.template.md](../assets/STATE.template.md). Shape:

```markdown
# <loop-name> — STATE
_Updated: 2026-06-22T14:05:00Z · run #142 · readiness 100/100_

## Priority   (act on these next)
- [P1] PR #412 failing CI 3h — owner pinged
- [P2] dep `axios` patch 1.14.0→1.14.1 available, cooldown clears 2026-06-25

## Watch     (not yet actionable)
- PR #408 awaiting review 1h
- flag `new-checkout` at 100% rollout 6d — cleanup candidate

## Noise      (seen + dismissed this run)
- PR #410 draft — skip until ready
- dep `left-pad` major bump — escalates, not auto

---
_Source: .github/workflows/<loop>.yml · config: loop.config.yaml_
```

**The read/write contract:**
1. **Read** `STATE.md` first thing — it's the loop's memory of the last run.
2. **Check the kill switch** (`kill_switch:` from config) — exit immediately if set.
3. Do the run's work, drawing the next unit from the Priority list.
4. **Rewrite** `STATE.md` — promote/demote items across Priority/Watch/Noise, bump the
   `_Updated_` line + run number + readiness.

`readiness` is the loop's self-assessment (0–100): is its config still coherent, its
gate still passing, its scope still valid? A dropping readiness is an early signal to
re-audit.

---

## `run-log.md` — the append-only audit trail

One line per run, appended, never rewritten. Answers "what has this loop been doing, and
what did it cost?"

```
2026-06-22T14:05:00Z  run#142  action=reported  pr=412  outcome=escalated  tokens=18420
2026-06-22T13:55:00Z  run#141  action=none       -       outcome=quiet      tokens=2110
2026-06-22T13:45:00Z  run#140  action=proposed   pr=409  outcome=pr-opened  tokens=44380
```

The `tokens` column feeds back into the budget. Tail it to see drift: a loop that used to
cost 2k/run quietly now costing 40k/run is doing more than it was scoped to.

---

## Budget control

A loop's cost is `runs/day × tokens/run × price`, and sub-agents multiply tokens/run.
Two controls:

- **`budget_tokens`** in the config — a per-run output ceiling. The loop stops the run
  when it's reached (the same discipline as a dynamic `/loop` watching `budget.remaining()`).
- **The run-log** — the actual spend, line by line. Reconcile estimate (`loop-cost`)
  against actual periodically; if they diverge, the loop's scope crept.

Estimate before you schedule: [../scripts/loop-cost.py](../scripts/loop-cost.py). The
cheapest lever is **cadence** — halving the frequency halves the cost. The next is
**model** — a Haiku triage loop costs a fifth of an Opus one; put the cheap model on the
maker and reserve the expensive one for the gate decision.

---

## Multi-loop coordination

Running several loops against one repo, two rules prevent them tripping over each other:

### Priority order (collision avoidance)

```
CI Sweeper  ►  PR Babysitter  ►  Dependency Sweeper  ►  Post-Merge/Changelog  ►  Daily Triage
 (highest)                                                                        (off-peak)
```

A red build blocks everyone, so the CI sweeper wins any worktree contention; daily triage
yields to all. When two loops want the same worktree/branch, the higher-priority one
proceeds and the lower defers to its next cadence tick. Loops announce what they're
touching via [`pigeon`](../../pigeon/SKILL.md) so a peer can see "ci-sweeper holds a
worktree on PR #412" and stand off.

### The kill switch (every loop honors it)

One stop signal, checked at the top of **every** run, that halts **every** loop:

- a **sentinel file** — `.loops/PAUSED` (global) or `.loops/<name>/PAUSED` (one loop), or
- a **label** — `loop-pause` on the repo/issue, checked via `gh`.

No loop ships without one. It's the difference between "the loops are misbehaving, give me
a minute" and "the loops are misbehaving, where's the breaker?". Put the exact mechanism
in `kill_switch:` and make checking it the first action of every run, before the work.

## See also

- [risk-tiers.md](risk-tiers.md) — the autonomy ladder the config's `tier` selects.
- [pattern-catalog.md](pattern-catalog.md) — each pattern's place in the priority order.
- [claude-code-loops.md](claude-code-loops.md) — how the cadence actually fires.
