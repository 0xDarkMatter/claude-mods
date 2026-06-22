# Loop Engineering — graduated-autonomy discipline for agent loops

Companion to the [`loop-ops`](../skills/loop-ops/SKILL.md) skill (the full playbook +
`loop-scaffold`/`loop-check`/`loop-doctor`/`loop-estimate` scripts). This file is the *directive*
— what to do every time you design or run a **recurring / scheduled / autonomous** agent
loop, in any project: a `/loop`, a `/schedule` routine, a cron `claude -p`, an `iterate`
run, a `fleet-worker` fan-out.

## The rule

**A loop is a recurring process you grant standing authority to. Grant it the *least*
authority that does the job, earn each increase with evidence, and never let it act on a
blast radius bigger than its stated purpose.** Three non-negotiables:

1. **Graduated autonomy — never start unattended.** `L1 report → L2 assisted → L3
   unattended`. A fresh loop runs read-only (L1) until its reports prove its judgment;
   only then does it earn write access (L2, human-gated merge), and only then autonomous
   landing (L3, inside an isolation boundary). Starting at L3 is how incidents and
   comprehension debt compound.
2. **A scheduler invokes `claude -p` — a session does not spawn ungated children.** The
   authorizer of an unattended loop is a human-configured cron / Task Scheduler / CI
   runner, *outside* any auto-mode session. An `auto`-mode session that launches a
   `--permission-mode bypassPermissions` child is hard-denied as *Create Unsafe Agents* —
   by design. Give the headless child *gates* (`dontAsk` + a narrow allowlist), not bypass
   — unless it runs in an isolated container.
3. **No gate, no kill switch, no budget → no loop.** Every loop has a `verify` gate (the
   check that decides land-vs-discard), a kill switch every run checks first, and a
   per-run token budget. A loop missing any of these doesn't get scheduled.

## Why this matters

Unattended loops amplify both good judgment and mistakes, and they do it on a schedule
while you're not watching. The failure modes are not hypothetical: a loop that force-pushes,
that burns a day's budget in an hour, that "fixes" CI by deleting the failing test, that
collides with another loop's worktree, or that silently stops triggering. The controls
above are what make a loop's authority *recoverable*: a kill switch stops it, a budget
bounds it, a gate keeps bad changes out, and the tier ladder means you only ever granted
the authority you'd already seen it use well.

## Directives — apply whenever a loop is involved

| Situation | Directive |
|---|---|
| Designing any scheduled/autonomous loop | Start at **L1 (read-only)**. Scaffold with `loop-scaffold`; fill a bounded `scope` (never `*`), a `verify` gate, an `escalation` rule, a `kill_switch`, a `budget_tokens`. |
| Before scheduling a loop | Run **`loop-check`** (config sane?) **then `loop-doctor --live`** (will it actually run — gate binary on PATH, budget fits a tick, permission mode achievable?). Don't schedule a loop that fails either. |
| Choosing the permission mode | Default to **`dontAsk` + a narrow allowlist** (runs anywhere, fully gated). Reserve `bypassPermissions` for an **isolated container** (the enumerate-vs-isolate fork). Never `default` (interactive) for a headless loop. |
| Wiring the cadence | A **scheduler** runs `claude -p` (the authorizer). Do **not** run an orchestrator session in auto mode whose job is spawning the loop. |
| Setting the cadence + cost | Cadence is the biggest cost lever; **caching** is the next (a loop re-sends the same prompt — cache the static prefix, and note a loop slower than ~1h can't cache). Estimate with `loop-estimate` before committing. |
| Running several loops | Give them a **priority order** (CI > PR > deps > cleanup > triage) and a **shared kill switch**; coordinate via `pigeon` so they don't collide on a worktree. |
| Anything high-blast-radius | **Escalate, don't act** (see below). A general goal is *not* authorization for a specific destructive action it implies. |

## The escalation gate — never auto-land

Bake into every loop's `escalation:` field. These **always** go to a human, regardless of
the loop's goal: force-push · push to `main` · production deploy/migration · mass deletion ·
granting IAM/repo permissions · destroying files that predate the run · editing `.claude/`
or settings (self-modification) · `curl | bash`. Safe to auto-land at L2/L3 *when
allowlisted*: a green PR on a feature branch, a lockfile patch bump past the guard, a
generated draft, a label/triage classification, a comment.

## Self-check before wiring a loop

- Is it starting at L1? If you're reaching for L3 on a fresh loop, stop.
- Does `loop-check` pass and `loop-doctor --live` say it will run?
- Is the child **gated** (`dontAsk`+allowlist) or genuinely **isolated** (container)? If
  you're using `bypassPermissions` on the host to avoid enumerating permissions, that's the
  exact pattern the auto-mode classifier blocks — authorize it properly or isolate it.
- Can you stop it (kill switch) and does it have a budget?

## When the playbook is needed

For the full operational workflow — the risk-tier ↔ permission-mode mapping, the STATE/
run-log/budget spine, the seven production patterns, multi-loop coordination, the
scheduler mechanics, and the `loop-scaffold`/`loop-check`/`loop-doctor`/`loop-estimate` tools —
**invoke the [`loop-ops`](../skills/loop-ops/SKILL.md) skill.**

## Cross-reference

- `~/.claude/skills/loop-ops/SKILL.md` — full playbook + scripts.
- `~/.claude/skills/loop-ops/references/risk-tiers.md` — the L1/L2/L3 ↔ permission-mode mapping.
- `~/.claude/docs/AUTO-MODE-CLASSIFIER.md` — the two-gate model behind directive #2.
- `worktree-boundaries.md` — never let a loop touch another session's `.claude/worktrees/`.
- `iterate` / `fleet-worker` / `fleet-ops` — the inner-loop, spawn, and land layers a loop composes.
