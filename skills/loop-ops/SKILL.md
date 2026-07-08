---
name: loop-ops
description: "Design and safely run OUTER loops - scheduled discover-triage-implement-verify-escalate agent loops. Risk-tier ladder (L1 report -> L3 unattended), STATE/run-log/budget spine, kill switch, pattern catalog. Triggers: outer loop, scheduled/autonomous agent loop, PR watch, CI watch, dep-bump loop, run on a schedule, kill switch, risk tier."
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
| **Schedule** | fire the loop on a cadence | native-first: `/loop` (in-session), **Desktop scheduled task** (local, unattended), `/schedule` cloud routines (no local files); `/goal` is the native completion gate. External (cron/Task Scheduler + `loop-run.sh`) only for non-Claude-Code control |
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
- **Scope the tools, not just the mode.** Allowlist exactly the tools/MCP connectors the
  job needs (read-only at L1); keep `gh pr merge` out and `land_via: fleet-ops` in. Full
  connector/MCP-scope discipline + the auto-merge guard: [references/risk-tiers.md](references/risk-tiers.md).

## The state spine

A loop's memory lives **outside** the conversation, in three files (schemas +
read/write contract in [references/state-spine.md](references/state-spine.md)):

- **`STATE.md`** — the triage snapshot: priority / watch / noise + a readiness line.
  Read at the top of every run, rewritten at the end.
- **`run-log.md`** — append one line per run (timestamp, action, outcome, tokens). The
  audit trail that answers "what has this loop been doing?"
- **`loop.config.yaml`** — the loop's definition (goal, tier, cadence, scope, gate,
  budget, escalation). Scaffolded by `loop-scaffold`, scored by `loop-check`.

## Pattern catalog (a morphology, not a fixed list)

Patterns are **compositions of three axes** — `trigger` (cadence / **event** via a Channel
/ `goal`) × `posture` (L1/L2/L3) × `locus` (connector→cloud routine / local→Desktop task).
The named patterns are well-trodden points in that space; compose your own from the axes.
Full recipes + the morphology in [references/pattern-catalog.md](references/pattern-catalog.md):

| Pattern | Trigger · Locus | Tier | One-line job |
|---|---|---|---|
| `daily-scan` | cadence · local | L1 | discover + prioritize, report only |
| `pr-watch` | event\|cadence · connector | L1 | watch review state, surface stuck PRs |
| `ci-watch` | **event** · local | L2 | triage build failures, propose a fix |
| `dep-bump` | cadence · local | L2 | patch-only bumps behind cooldown + guard |
| `changelog-gen` | event(tag)\|cadence · local | L1 | draft release notes for approval |
| `merge-hygiene` | cadence · local | L1 | dead branches, stale flags |
| `issue-sort` | cadence · connector | L1 | classify + label, propose only |
| `metric-chase` | **goal** · local | L2 | drive a metric (coverage/latency/eval) via `iterate` |
| `regression-watch` | cadence\|event · local | L1 | run a benchmark/eval, flag a regression |
| `digest` | cadence · **connector** | L1 | summarize email/Asana/news (cloud routine) |
| `backfill` | **goal** · local | L2 | drain a migration/queue **to completion** |
| `monitor` | **event** · local | L1 | error/deploy webhook → triage + page |
| `freshness` | cadence · local | L1 | re-check docs/data/deps vs reality |

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

| You need to… | Use | Not |
|---|---|---|
| improve one metric in one session | [`iterate`](../iterate/SKILL.md) | a hand-rolled inner loop |
| spawn cheap parallel makers | [`fleet-worker`](../fleet-worker/SKILL.md) | bespoke `claude -p` plumbing |
| route models across a fan-out (cheap finders, Opus judges) | [`fleet-worker` model-routing](../fleet-worker/references/model-routing.md) | every agent on the orchestrator's model |
| test-gate + land winning branches | [`fleet-ops`](../fleet-ops/SKILL.md) | a manual merge step |
| fire on a cadence | native `/loop` · Desktop scheduled task · `/schedule` cloud routine; `/goal` for completion | a custom cron in this skill |
| commit / PR / release | [`git-ops`](../git-ops/SKILL.md), [`github-ops`](../github-ops/SKILL.md) | raw `git push` |
| signal between loops | [`pigeon`](../pigeon/SKILL.md) | a shared scratch file |

`loop-ops` is the **design layer**; these are the **execution layers**.

---

## Tools

Five scripts, all following the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md)
(stdout = data, semantic exit codes, `--help` with EXAMPLES, `--json` envelopes): **init**
scaffolds the loop, **audit** scores whether the config is *well-formed*, **doctor**
preflights whether it will actually *run*, **cost** estimates spend (caching-aware), and
**check-pricing-sync** gates pricing drift in CI. The discipline before scheduling is
`init → fill → cost → audit → doctor --live`.

### `scripts/loop-scaffold.sh` — scaffold a loop's state spine

Writes `<dir>/<name>/` with five files from the bundled templates:
`loop.config.yaml` ([assets/loop.config.template.yaml](assets/loop.config.template.yaml)),
`STATE.md` ([assets/STATE.template.md](assets/STATE.template.md)), `run-log.md`, `run.md`
(the headless run prompt, [assets/run.template.md](assets/run.template.md)), and an
executable **`loop-run.sh`** ([assets/run.sh.template](assets/run.sh.template)) — the
runner-agnostic tick wrapper any scheduler invokes (cron / Windows Task Scheduler /
systemd / by hand), **no GitHub Actions required**. Pass a known `--pattern`
(pr-watch, ci-watch, dep-bump, …) and the config is **seeded** with that
pattern's scope/goal/escalation — and, at L2+, its gate — so you get a near-ready config to
review, not blank placeholders (it audits clean immediately). Doctrine holds: it still
scaffolds at L1 by default with a graduation block.

```bash
# Create .loops/pr-watch/ with config + STATE.md + run-log.md + run.md from templates:
bash scripts/loop-scaffold.sh --name pr-watch --pattern pr-watch --tier L1

# Custom dir + cadence, preview without writing:
bash scripts/loop-scaffold.sh --name dep-bump --pattern dep-bump \
  --tier L2 --cadence 1d --dir .loops --dry-run
```

Refuses to overwrite a populated `<dir>/<name>/` (exit 5) unless `--force`. Atomic
writes. `--dry-run` prints what it would create and writes nothing. stdout = the created
config path.

### `scripts/loop-check.sh` — readiness scorer (run before you schedule)

The question this answers: *is this loop safe to turn on at its declared tier?* It scores
a `loop.config.yaml` against the readiness rubric — gate present, scope bounded,
escalation defined, guard + worktree at L2+, budget + kill switch set, permission mode
consistent with tier — and refuses a green light if any **critical** gap exists.

```bash
bash scripts/loop-check.sh .loops/pr-watch/loop.config.yaml   # exit 0 ready, 10 not ready
bash scripts/loop-check.sh --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.severity=="error")'
bash scripts/loop-check.sh --min 80 .loops/ci-watch/loop.config.yaml   # raise the score bar
```

Exit **0** = ready (no errors, score ≥ `--min`), **10** = not ready (findings on stdout),
`2` usage, `3` config not found, `4` config unparseable. `--strict` counts warnings
toward the not-ready signal.

### `scripts/loop-doctor.sh` — live preflight (will it actually run?)

`loop-check` proves the config is *well-formed*; `loop-doctor` proves the loop will
*execute* — catching the "blocked at 3am" failures audit can't see. `--offline` (CI-safe):
the budget fits a tick's estimated tokens, the permission mode is achievable (not
interactive), an L3 bypass declares an isolation boundary. `--live` adds runtime preflight:
the `verify`/`guard` gate's leading binary resolves on PATH, `claude`/`git` are present,
the kill-switch sentinel's parent dir exists.

```bash
bash scripts/loop-doctor.sh --offline .loops/pr-watch/loop.config.yaml   # CI gate
bash scripts/loop-doctor.sh --live .loops/ci-watch/loop.config.yaml          # before scheduling
bash scripts/loop-doctor.sh --live --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.state=="bad")'
```

Exit **0** = will run, **10** = a check predicts a runtime failure (gate binary missing,
bypass on host without isolation, budget too small for a tick), `2` usage, `3` not found,
`4` unparseable, `5` missing core dep. Run it **after** `loop-check` and before scheduling.

### `scripts/loop-estimate.py` — token/$ estimate by pattern × cadence × model (caching-aware)

Estimate spend **before** committing to a cadence — the cost of an outer loop is
runs/day × tokens/run × price, and sub-agents multiply it. It also models **prompt
caching**: a loop re-sends the same `run.md`+system prefix every tick (the Ralph
property), so the prefix should be cache-written once then read (~0.1×) — *but only if the
tick interval fits the cache TTL*. A loop slower than ~1h can't cache (the entry expires
between ticks); the estimator says so and recommends the TTL. Pricing reads from
`assets/model-pricing.json` (date-stamped; [`claude-api-ops`](../claude-api-ops/SKILL.md)
is the source of truth — run its `check-model-table.py` if you suspect drift).

```bash
python scripts/loop-estimate.py --pattern pr-watch --cadence 10m --model claude-haiku-4-5
python scripts/loop-estimate.py --pattern ci-watch --cadence 15m --model claude-sonnet-4-6 --days 30 --json
python scripts/loop-estimate.py --list-models      # the pricing table + its as-of date
```

Exit `0` ok, `2` usage, `3` pricing file missing, `4` bad cadence/model. Output names
every assumption (runs/day, tokens/run, sub-agent multiplier) — it's an estimate, and it
says so.

### `scripts/check-pricing-sync.py` — offline drift guard (CI)

`model-pricing.json` is a *copy* of claude-api-ops's authoritative model table, and a copy
drifts silently. This offline verifier asserts every model in
[assets/model-pricing.json](assets/model-pricing.json) matches claude-api-ops's "Current
Models" table (prices included). Both files are in-repo, so it's network-free and gates PR
CI via `tests/check-resources.sh`; live model-id drift is owned by claude-api-ops's
`check-model-table.py`.

```bash
python scripts/check-pricing-sync.py --offline   # exit 0 in sync, 10 drift, 3 a file missing
```

---

## End-to-end workflow

1. **Pick a pattern** from the catalog (or `custom`). Start at **L1**.
2. **Scaffold:** `bash scripts/loop-scaffold.sh --name <n> --pattern <p> --tier L1`.
3. **Fill `loop.config.yaml`** — the real `goal`, `scope` (bounded globs, never `*`),
   `verify` gate, `escalation` rule, `budget_tokens`, `kill_switch`.
4. **Cost it:** `python scripts/loop-estimate.py --pattern <p> --cadence <c> --model <m>` —
   sanity-check the monthly spend against the value.
5. **Audit it:** `bash scripts/loop-check.sh .loops/<n>/loop.config.yaml` — fix every
   error before scheduling. Don't schedule a loop that fails its own audit.
6. **Doctor it:** `bash scripts/loop-doctor.sh --live .loops/<n>/loop.config.yaml` — prove
   it will actually *run* (gate binary on PATH, budget fits a tick). Audit = well-formed;
   doctor = will-run.
7. **Schedule** the L1 run — but pick the mechanism deliberately; the **recipe selector**
   in [references/claude-code-loops.md](references/claude-code-loops.md) prescribes it per
   situation, because they're not interchangeable: connector-driven (email/Asana, no local
   code) → **cloud routine**; touches local code → **Desktop scheduled task**; sustained &
   token-sensitive → a **cache-warm daemon** (`claude -p` every ~270 s), *not* `/loop`
   (which grows a session and chews tokens); fixed-criteria long task → **`/goal`**; quick
   supervised polling → `/loop`. (L1 is read-only — it just writes `STATE.md` + a report.)
8. **Read the reports.** Only after the loop's judgment is proven do you graduate it to
   **L2** (worktree + guard + `fleet-ops` landing) and re-audit at the higher tier.

## Worked example

A complete, **audit + doctor-clean** L1 loop ships at
[assets/examples/pr-watch/](assets/examples/pr-watch/): a filled
`loop.config.yaml`, a *populated* `STATE.md`, the `run.md` run prompt, a sample
`run-log.md`, the runner-agnostic **`loop-run.sh`** (the tick wrapper, with the
kill-switch gate and `dontAsk` + allowlist baked in — point cron / Task Scheduler at it),
and an *optional* `github-actions.yml` for repos already on GitHub. Copy the dir, adjust
scope/cadence, run `loop-check` + `loop-doctor --live`, then wire `loop-run.sh` to your
scheduler. The other patterns don't ship as
static dirs that rot — `loop-scaffold --pattern <name>` *generates* the same, seeded and
gate-clean, for any pattern at any tier. CI runs `loop-check` + `loop-doctor` on this
example every build, so it can't drift out of validity.

## Anti-patterns (these are detected and wrong)

The incident-shaped catalog — symptom → mechanism → the control that catches each — is
[references/failure-modes.md](references/failure-modes.md) (runaway budget, the 3am-dead
loop, cache-cold, force-push, ungated-child spawn, colliding loops, silent-stop,
gate reward-hacking, …). The headline ones:

- **Routing around the gate.** Wrapping `claude -p --permission-mode bypassPermissions`
  in a script to dodge the classifier is *Auto-Mode Bypass* — a `hard_deny` nothing
  clears. If an outcome is blocked, **authorize it** (a narrow allow rule, or run the
  scheduler outside the auto-mode session), never **disguise it**.
- **The orchestrator session spawning ungated children.** A session in `auto` mode is
  the wrong place to launch the loop. The scheduler/cron/Task-Scheduler/CI runner that
  invokes `claude -p` is the authorizer. See [references/risk-tiers.md](references/risk-tiers.md) §"enumerate vs isolate".
- **No gate.** A loop whose `verify:` is empty is not a loop, it's an unsupervised typer.
  `loop-check` errors on it.
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
- [references/failure-modes.md](references/failure-modes.md) — how loops break (incident-shaped) and the control that catches each.
- [assets/loop.config.template.yaml](assets/loop.config.template.yaml) — the loop definition starter; [assets/STATE.template.md](assets/STATE.template.md) — the state-spine starter; [assets/run.template.md](assets/run.template.md) — the headless run prompt.
- Lineage (public sources): the [Ralph loop](https://ghuntley.com/ralph/) (fresh-context inner brute-force) and the broader *loop engineering* discipline framed by Peter Steinberger and Addy Osmani.
