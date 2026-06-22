---
name: loop-ops
description: "Design, scaffold, and safely run OUTER loops — scheduled discover→triage→implement→verify→escalate-or-land agent loops, the orchestration layer above a single run. Risk-tier ladder (L1 report → L2 assisted → L3 unattended) mapped onto Claude Code's permission model, a persistent STATE/run-log/budget spine, a production pattern catalog, multi-loop coordination, and a kill switch. Composes iterate (inner loop), fleet-worker (spawn), fleet-ops (land), and native /loop + /schedule. Triggers on: loop engineering, outer loop, loop design, design a loop, scheduled agent, autonomous loop, background agent loop, PR babysitter, CI sweeper, dependency sweeper, changelog drafter, issue triage, daily triage, loop audit, loop cost, loop readiness, ralph loop, agent harness, escalation gate, risk tier, kill switch, run it overnight on a schedule."
when_to_use: "Use when designing or running a recurring/scheduled agent loop rather than a one-shot task — e.g. 'set up a loop that triages PRs every 10 minutes', 'design an autonomous CI-failure sweeper', 'how risky is this loop / is it ready to run unattended', 'estimate what this loop costs per month', 'build a loop-engineering setup'. For a single-session improvement loop against one metric, use iterate instead."
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

> "You shouldn't be prompting coding agents anymore. You should be designing the loops
> that prompt your agents." — Peter Steinberger

This skill is the **outer loop**: the orchestration layer *above* a single agent run. It
is the twin of [`iterate`](../iterate/SKILL.md) — `iterate` is the *inner* loop (one
metric, one session, git-as-memory); `loop-ops` is the design discipline for the loop
that *schedules and gates* inner runs. It does not reimplement spawning or landing; it
**composes** what this repo already ships.

---

## The six primitives → what owns each here

Every durable loop rests on six primitives. The discipline is wiring them; the parts
already exist:

| Primitive | What it is | Owned in claude-mods by |
|---|---|---|
| **Schedule** | fire the loop on a cadence | native `/loop`, `/schedule` (cron agents), `ScheduleWakeup` |
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

## The state spine

A loop's memory lives **outside** the conversation, in three files (schemas +
read/write contract in [references/state-spine.md](references/state-spine.md)):

- **`STATE.md`** — the triage snapshot: priority / watch / noise + a readiness line.
  Read at the top of every run, rewritten at the end.
- **`run-log.md`** — append one line per run (timestamp, action, outcome, tokens). The
  audit trail that answers "what has this loop been doing?"
- **`loop.config.yaml`** — the loop's definition (goal, tier, cadence, scope, gate,
  budget, escalation). Scaffolded by `loop-init`, scored by `loop-audit`.

## Pattern catalog

Seven battle-tested shapes, each with a cadence, a risk tier, and an escalation rule.
Full skeletons in [references/pattern-catalog.md](references/pattern-catalog.md):

| Pattern | Cadence | Tier | One-line job |
|---|---|---|---|
| Daily Triage | 1–2 h | L1 | discover + prioritize, report only |
| PR Babysitter | 5–15 min | L1 | watch review state, surface stuck PRs |
| CI Sweeper | 5–15 min | L2 | triage build failures, propose a fix |
| Dependency Sweeper | 6 h–1 d | L2 | patch-only bumps behind the cooldown + guard |
| Changelog Drafter | 1 d / tag | L1 | draft release notes for human approval |
| Post-Merge Cleanup | 1–6 h | L1 | hygiene: dead branches, stale flags |
| Issue Triage | 2 h–1 d | L1 | classify + label, propose only |

Start any pattern at L1. Graduate to L2 only after the L1 reports prove its judgment.

## Multi-loop coordination & the kill switch

Running several loops? Two non-negotiables (detail in
[references/state-spine.md](references/state-spine.md)):

- **Priority order** prevents collisions: `CI Sweeper → PR Babysitter → Dependency
  Sweeper → Post-Merge/Changelog → Daily Triage (off-peak)`. A higher-priority loop's
  worktree wins; lowers defer. Loops signal each other via [`pigeon`](../pigeon/SKILL.md).
- **A kill switch every loop honors.** A single stop signal — a `PAUSED` sentinel file
  or a `loop-pause` label — that every loop checks at the top of its run and exits on.
  No loop ships without one. Put it in `kill_switch:` and check it first.

## Composition map — don't rebuild what exists

| You need to… | Use | Not |
|---|---|---|
| improve one metric in one session | [`iterate`](../iterate/SKILL.md) | a hand-rolled inner loop |
| spawn cheap parallel makers | [`fleet-worker`](../fleet-worker/SKILL.md) | bespoke `claude -p` plumbing |
| test-gate + land winning branches | [`fleet-ops`](../fleet-ops/SKILL.md) | a manual merge step |
| fire on a cadence | native `/loop`, `/schedule` | a custom cron in this skill |
| commit / PR / release | [`git-ops`](../git-ops/SKILL.md), [`github-ops`](../github-ops/SKILL.md) | raw `git push` |
| signal between loops | [`pigeon`](../pigeon/SKILL.md) | a shared scratch file |

`loop-ops` is the **design layer**; these are the **execution layers**.

---

## Tools

Three scripts, all following the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md)
(stdout = data, semantic exit codes, `--help` with EXAMPLES, `--json` envelopes). They
are the legs of a stool: **init** scaffolds, **audit** scores readiness, **cost**
estimates spend before you commit to a cadence.

### `scripts/loop-init.sh` — scaffold a loop's state spine

```bash
# Create .loops/pr-babysitter/ with config + STATE.md + run-log.md from templates:
bash scripts/loop-init.sh --name pr-babysitter --pattern pr-babysitter --tier L1

# Custom dir + cadence, preview without writing:
bash scripts/loop-init.sh --name dep-sweeper --pattern dependency-sweeper \
  --tier L2 --cadence 1d --dir .loops --dry-run
```

Refuses to overwrite a populated `<dir>/<name>/` (exit 5) unless `--force`. Atomic
writes. `--dry-run` prints what it would create and writes nothing. stdout = the created
config path.

### `scripts/loop-audit.sh` — readiness scorer (run before you schedule)

The question this answers: *is this loop safe to turn on at its declared tier?* It scores
a `loop.config.yaml` against the readiness rubric — gate present, scope bounded,
escalation defined, guard + worktree at L2+, budget + kill switch set, permission mode
consistent with tier — and refuses a green light if any **critical** gap exists.

```bash
bash scripts/loop-audit.sh .loops/pr-babysitter/loop.config.yaml   # exit 0 ready, 10 not ready
bash scripts/loop-audit.sh --json .loops/dep-sweeper/loop.config.yaml | jq '.data[] | select(.severity=="error")'
bash scripts/loop-audit.sh --min 80 .loops/ci-sweeper/loop.config.yaml   # raise the score bar
```

Exit **0** = ready (no errors, score ≥ `--min`), **10** = not ready (findings on stdout),
`2` usage, `3` config not found, `4` config unparseable. `--strict` counts warnings
toward the not-ready signal.

### `scripts/loop-cost.py` — token/$ estimate by pattern × cadence × model

Estimate spend **before** committing to a cadence — the cost of an outer loop is
runs/day × tokens/run × price, and sub-agents multiply it. Pricing reads from
`assets/model-pricing.json` (date-stamped; [`claude-api-ops`](../claude-api-ops/SKILL.md)
is the source of truth — run its `check-model-table.py` if you suspect drift).

```bash
python scripts/loop-cost.py --pattern pr-babysitter --cadence 10m --model claude-haiku-4-5
python scripts/loop-cost.py --pattern ci-sweeper --cadence 15m --model claude-sonnet-4-6 --days 30 --json
python scripts/loop-cost.py --list-models      # the pricing table + its as-of date
```

Exit `0` ok, `2` usage, `3` pricing file missing, `4` bad cadence/model. Output names
every assumption (runs/day, tokens/run, sub-agent multiplier) — it's an estimate, and it
says so.

---

## End-to-end workflow

1. **Pick a pattern** from the catalog (or `custom`). Start at **L1**.
2. **Scaffold:** `bash scripts/loop-init.sh --name <n> --pattern <p> --tier L1`.
3. **Fill `loop.config.yaml`** — the real `goal`, `scope` (bounded globs, never `*`),
   `verify` gate, `escalation` rule, `budget_tokens`, `kill_switch`.
4. **Cost it:** `python scripts/loop-cost.py --pattern <p> --cadence <c> --model <m>` —
   sanity-check the monthly spend against the value.
5. **Audit it:** `bash scripts/loop-audit.sh .loops/<n>/loop.config.yaml` — fix every
   error before scheduling. Don't schedule a loop that fails its own audit.
6. **Schedule** the L1 run with native `/loop` or `/schedule` (read-only — it just
   writes `STATE.md` + a report).
7. **Read the reports.** Only after the loop's judgment is proven do you graduate it to
   **L2** (worktree + guard + `fleet-ops` landing) and re-audit at the higher tier.

## Anti-patterns (these are detected and wrong)

- **Routing around the gate.** Wrapping `claude -p --permission-mode bypassPermissions`
  in a script to dodge the classifier is *Auto-Mode Bypass* — a `hard_deny` nothing
  clears. If an outcome is blocked, **authorize it** (a narrow allow rule, or run the
  scheduler outside the auto-mode session), never **disguise it**.
- **The orchestrator session spawning ungated children.** A session in `auto` mode is
  the wrong place to launch the loop. The scheduler/cron/Task-Scheduler/CI runner that
  invokes `claude -p` is the authorizer. See [references/risk-tiers.md](references/risk-tiers.md) §"enumerate vs isolate".
- **No gate.** A loop whose `verify:` is empty is not a loop, it's an unsupervised typer.
  `loop-audit` errors on it.
- **Unbounded scope.** `scope: "*"` means "may touch anything" — the audit rejects it.
- **No kill switch / no budget.** A loop you can't stop, or whose spend you didn't
  bound, will eventually surprise you. Both are audit findings.
- **Skipping L1.** Starting a fresh loop at L3 is how comprehension debt and incidents
  compound. The ladder exists precisely so trust is *earned* before it's *granted*.

## See also

- [references/risk-tiers.md](references/risk-tiers.md) — L1/L2/L3 ↔ permission modes, headless profiles, enumerate-vs-isolate.
- [references/pattern-catalog.md](references/pattern-catalog.md) — the seven patterns, full skeletons + escalation rules.
- [references/state-spine.md](references/state-spine.md) — STATE.md / run-log / budget schemas, multi-loop coordination.
- [references/claude-code-loops.md](references/claude-code-loops.md) — where loops actually live: `/loop`, `/schedule`, hooks, the scheduler pattern.
- [assets/loop.config.template.yaml](assets/loop.config.template.yaml) — the loop definition starter.
- The lineage: [Ralph loop](https://ghuntley.com/ralph/) (inner brute-force), [loop-engineering](https://github.com/cobusgreyling/loop-engineering) (the methodology this distills).
