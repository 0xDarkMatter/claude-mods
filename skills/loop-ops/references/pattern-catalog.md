# Pattern Catalog — a morphology of loop shapes

Loops aren't a fixed list of recipes — they're **compositions of three orthogonal axes**.
Name the axes and the patterns fall out; you can also compose ones not named here. The
named patterns below are the well-trodden *points* in this space. `loop-scaffold` seeds a
`loop.config.yaml` keyed by `--pattern <name>` (the canonical keys); the rest of the space
you compose by hand. **Start every pattern at L1** and graduate only once its reports prove
its judgment.

## The three axes

**1. Trigger — what starts a tick.**

| Trigger | Fires when | Mechanism | Best for |
|---|---|---|---|
| `cadence` | a clock interval elapses | `/loop` (supervised), Desktop task, cloud routine, or a daemon | steady polling — backlog, PRs, deps |
| `event` | an external thing happens (CI fail, error, deploy, message) | a **Channel** (MCP webhook receiver) pushes it into a live session | responsiveness + low cost — no idle polling |
| `goal` | runs continuously **until a condition holds**, then stops | `/goal` (+ auto mode) | run-to-completion — migrations, metric targets |

> **Event beats poll when you can get it.** A CI webhook firing the tick is cheaper and
> faster than a 10-min poll. The cost: a Channel needs a **persistent session**
> (`claude --channels …` in a background process), and it's a research-preview,
> Anthropic-auth-only feature. Cadence stays fully detached; event trades that for
> responsiveness. See [claude-code-loops.md](claude-code-loops.md).

**2. Posture — how much autonomy** (the [risk tier](risk-tiers.md)): `L1` report · `L2`
propose-and-human-gates · `L3` autonomous-in-a-denylist.

**3. Locus — where it runs / what it can touch.**

| Locus | Mechanism | Can touch | Use when |
|---|---|---|---|
| `connector` | **cloud routine** (`/schedule`) | your claude.ai connectors (email, Asana, Slack, issues) — **no local files** | the work lives in services, not your repo |
| `local` | Desktop task / daemon / `/loop` | the repo, build, models, local tools | the work touches local state |

The recipe-selector in [claude-code-loops.md](claude-code-loops.md) is just these axes
resolved to a mechanism. A loop = **(trigger × posture × locus) + the [state spine](state-spine.md)**.

---

## The catalog

Each row: the axes, the recommended native mechanism, the job (gate → what it escalates),
and the **failure mode to watch** ([failure-modes.md](failure-modes.md)).

| Pattern | Trigger · Locus | Start tier | Mechanism | Job → escalates | Watch |
|---|---|---|---|---|---|
| `daily-scan` | cadence · local | L1 | Desktop task (off-peak) | sweep backlog/alerts, write `STATE.md` → all to a human | silent-stop |
| `pr-watch` | event\|cadence · connector | L1 | Channel (PR webhook) or cloud routine | flag stuck/failing/conflicted PRs → never merges | runaway tokens if polled tight |
| `ci-watch` | **event** · local | L2 | Channel (CI webhook) → fix in a worktree | failing test passes + full guard → flaky/deploy/secrets | gate reward-hacking |
| `dep-bump` | cadence · local | L2 | Desktop task/daemon | patch-only behind cooldown + guard → minor/major, advisories | supply-chain |
| `changelog-gen` | event(on tag)\|cadence · local | L1 | tag-event or Desktop task | draft `RELEASE_NOTES_DRAFT.md` → human publishes | — |
| `merge-hygiene` | cadence · local | L1 | Desktop task (off-peak) | dead branches / stale flags → ambiguous deletes | worktree-boundaries |
| `issue-sort` | cadence\|event · connector | L1 | cloud routine | classify + suggest labels → priority/dupe-close | — |
| **`metric-chase`** | **goal** · local | L2 | `/goal` driving [`iterate`](../../iterate/SKILL.md) | drive coverage/latency/bundle/**eval-score** to target → unreachable / guard fails | gate reward-hacking · **high cost** |
| **`regression-watch`** | cadence\|event(on release) · local | L1→L2 | Desktop task/daemon | run a benchmark/eval, diff vs baseline → a real regression | flaky bench = false alarm · **high/run** |
| **`digest`** | cadence · **connector** | L1 | **cloud routine** | summarize email/Asana/calendar/news → nothing (read-only) | over-scoped connector |
| **`backfill`** | **goal** · local | L2/L3 | `/goal` (+ worktree/container) | drain a migration/queue **to completion** → an item needing judgment | runaway budget · **long** |
| **`monitor`** | **event** · local | L1 | **Channel** (error/log/deploy webhook) | triage the event → page a human on anomaly | alert fatigue · needs a live session |
| **`freshness`** | cadence · local | L1 | Desktop task (daily/weekly) | re-check docs/data/deps vs reality → confirmed drift | transient failure ≠ drift |

---

## Notes on the patterns that need them

- **`ci-watch` / `pr-watch` — prefer event over poll.** Wire a CI/PR webhook through a
  Channel so the tick fires on the event, not a timer. A polled `pr-watch` at 5 min costs
  ~3× a 15-min one for marginal freshness; the event-driven version costs ~nothing while
  quiet. At L2, `ci-watch` opens a fix in a worktree and hands the branch to `fleet-ops`;
  never auto-merges `main`.
- **`metric-chase` is the bridge to [`iterate`](../../iterate/SKILL.md).** The loop's
  *trigger* is a `/goal` ("coverage ≥ 90, or stop after N turns"); the *work* each turn is
  an `iterate` step (modify → measure → keep/discard). Use it for any measurable target —
  including an **eval score** (this is the GLM/Opus-bench shape). Highest cost class; bound it.
- **`digest` is the canonical cloud-routine pattern.** It needs *connectors, not code*, so
  it's the one archetype where the fresh-clone cloud routine is exactly right — it keeps
  your claude.ai connectors and runs with the machine off. Read-only: no write scopes.
- **`backfill` is run-to-completion, not recurring.** A `/goal` drains the queue/migration;
  when the condition holds it stops and clears. Bound it (`or stop after N`, a token budget)
  — it's the runaway-budget risk made flesh. For arbitrary execution, run it in a container.
- **`monitor` is the purest event loop.** An error-tracker/deploy webhook → a Channel → a
  persistent background session that triages and pages on anomaly. No polling at all. The
  trade-off is keeping that session alive.
- **`regression-watch`** runs a real suite each tick (expensive), so cadence it slowly or
  trigger it on a release event. Treat a transient/flaky failure as advisory (don't page on
  one red run) — the same exit-7-vs-exit-10 discipline our staleness verifiers use.

---

## Composing a pattern not in the catalog

Pick a point in the space the named patterns don't cover. Examples:

- *event · connector · L1* — a Slack message (Channel) triggers a read-only lookup against
  a connector. (A "support-triage" loop.)
- *goal · connector · L2* — drain an Asana backlog to empty via `/goal`, updating tasks
  through the connector.
- *cadence · local · L3* — a nightly autonomous refactor in an isolated container.

The discipline is identical regardless of the point: bounded scope, a gate, an escalation
rule, a kill switch, a budget — and **start at L1**.

## Choosing — the short version

1. **Locus first:** does it touch local code? → `local` (Desktop task/daemon). Pure
   connector work? → `connector` (cloud routine).
2. **Trigger next:** is there an event to react to? → `event` (Channel) — cheaper + faster.
   A clear finish line? → `goal`. Otherwise → `cadence`, slowest that still catches the work.
3. **Posture:** start **L1**. Graduate to L2 (with a guard, worktree, escalation, `land_via`)
   only once the reports earn it; re-run `loop-check` + `loop-doctor --live` at the new tier.

## See also

- [risk-tiers.md](risk-tiers.md) — the posture axis (permission-mode mapping).
- [claude-code-loops.md](claude-code-loops.md) — the trigger/locus axes resolved to mechanisms + the recipe selector.
- [failure-modes.md](failure-modes.md) — the "watch" column, in depth.
- [state-spine.md](state-spine.md) — the multi-loop priority order these share.
- [../assets/loop.config.template.yaml](../assets/loop.config.template.yaml) — the config every pattern fills in.
