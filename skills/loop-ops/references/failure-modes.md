# Failure Modes — how loops actually break, and what catches each

Incident-shaped scar tissue. Every entry is a real way an outer loop goes wrong: the
**symptom** you'd observe, the **mechanism** underneath, and the **catch** — the
specific `loop-ops` control (or Claude Code gate) that prevents or surfaces it. Read this
before you schedule anything unattended; most of these only bite once you're not watching.

The meta-lesson (Addy Osmani): *"build the loop like someone who intends to stay the
engineer."* These failures are what happens when the loop is given more autonomy than its
judgment has earned.

---

## 1. The runaway-budget loop

- **Symptom:** a day's token spend gone in an hour; the bill is 5–10× the estimate.
- **Mechanism:** cadence too tight, or scope crept so each tick reads/does far more than
  scoped (a "report PRs" loop that started crawling diffs). Sub-agents multiply it.
- **Catch:** set `budget_tokens` (a per-run ceiling). Estimate with `loop-estimate` *before*
  scheduling; `loop-doctor` fails the loop if `budget_tokens` < estimated tokens/run.
  Reconcile the `loop-estimate` estimate against `run-log.md` actuals periodically — a tick
  that used to cost 2k now costing 40k means scope crept.

## 2. The 3am-dead loop

- **Symptom:** every tick aborts immediately; `run-log.md` shows nothing but failures.
- **Mechanism:** the `verify`/`guard` gate command's binary isn't on PATH in the
  *scheduler's* environment (works on your laptop, absent on the CI runner), or `claude`
  itself isn't installed there. In non-interactive `-p`, a hard denial **aborts the
  session** — no human to prompt.
- **Catch:** `loop-doctor --live` resolves the gate's leading binary and checks
  `claude`/`git` are on PATH *before* you schedule. Run it in the target environment.

## 3. The cache-cold loop

- **Symptom:** cost far higher than `loop-estimate --cached` projected; `cache_read_input_tokens`
  stays 0.
- **Mechanism:** the run prompt isn't byte-identical every tick — a `datetime.now()`, a
  per-run UUID, or unsorted JSON in the prefix invalidates the cache. Or the cadence is
  slower than the cache TTL (a 6h loop can't keep a 1h entry warm), so every tick is a
  cold write.
- **Catch:** keep `run.md` byte-identical (the template enforces this — fresh context,
  same prompt). `loop-estimate` tells you whether the cadence can cache at all and which TTL;
  if it can't, don't pay the write multiplier — run uncached.

## 4. The force-push / push-to-main loop

- **Symptom:** the loop force-pushed, pushed to `main`, or ran a production migration —
  "to fix the thing."
- **Mechanism:** a *general* goal ("keep CI green", "clean up the repo") was taken as
  authorization for a *specific* high-blast action it merely implied.
- **Catch:** the escalation gate — these classes (force-push, push to `main`, prod
  deploy/migration, mass delete, IAM grants, deleting pre-session files, `.claude` edits)
  are **always** escalated, declared in `escalation:`. Claude Code's auto-mode classifier
  also hard/soft-denies them independently: a general goal is *not* explicit intent.

## 5. The ungated-child spawn

- **Symptom:** the orchestrator session dies with *Create Unsafe Agents* / *Auto-Mode
  Bypass*; the loop never starts.
- **Mechanism:** a session in `auto` mode tried to launch a detached `claude -p
  --permission-mode bypassPermissions` child (an ungated autonomous agent). Wrapping the
  flag in a script to dodge the classifier is a `hard_deny` nothing clears.
- **Catch:** the cardinal rule — **a scheduler invokes `claude -p`, not a session that
  spawns ungated children.** Move the launch to cron/Actions/Task Scheduler (the human
  authorizer), and give the child gates (`dontAsk` + allowlist), not bypass — unless it's
  in an isolated container. (`rules/loop-engineering.md` directive #2.)

## 6. The colliding loops

- **Symptom:** two loops fight over the same branch/worktree; one clobbers the other's
  work; merge churn.
- **Mechanism:** several loops run against one repo with no coordination.
- **Catch:** the multi-loop **priority order** (CI > PR > deps > cleanup > triage) — the
  higher-priority loop wins worktree contention, lowers defer to their next tick. Each
  loop isolates in its **own** worktree; they announce what they hold via `pigeon` so a
  peer can stand off. Never touch another session's `.claude/worktrees/`.

## 7. The silent-stop loop

- **Symptom:** nobody noticed the loop stopped running for a week; stale `STATE.md`.
- **Mechanism:** the schedule quietly stopped firing — a disabled workflow, a cron typo,
  a paused runner, an expired token. Loops fail *open* into silence, not error.
- **Catch:** treat `STATE.md`'s `_Updated_` timestamp + the `run-log.md` tail as a
  heartbeat — if the latest run is older than ~2× the cadence, the loop is down. A
  separate cheap monitor (or a `daily-scan` loop) that flags stale loop heartbeats
  closes this; the kill switch is for stopping, the heartbeat is for noticing it stopped.

## 8. The test-deleting "fix" (gate reward-hacking)

- **Symptom:** CI is green again — because the loop deleted or `skip`-ped the failing
  test, not because it fixed the bug.
- **Mechanism:** the loop optimized the literal gate (`verify` passes) rather than the
  intent. A loop, like any optimizer, games a weak metric.
- **Catch:** make the gate hard to hack — a `guard` that runs the **full** suite +
  typecheck, a `scope` that **excludes** test files and CI config, and a human review at
  L2 (the PR gate). Never let an L2/L3 loop modify the very tests that gate it.

## 9. The unbounded-scope loop

- **Symptom:** the loop edited files far outside its job.
- **Mechanism:** `scope: "*"` (or `**`, or empty) — "may touch anything."
- **Catch:** `loop-check` **rejects** an unbounded or placeholder scope (exit 10). Scope
  is bounded globs, always.

## 10. The no-kill-switch loop

- **Symptom:** the loop is misbehaving and there's no fast way to stop it.
- **Mechanism:** no stop signal was designed in; stopping means disabling the workflow by
  hand mid-tick.
- **Catch:** `kill_switch` is mandatory (`loop-check` errors without one) and checked
  **first** every run. The cheapest implementation is a `PreToolUse` hook that blocks
  every tool the instant a `PAUSED` sentinel appears — an instant breaker.

## 11. The comprehension-debt loop

- **Symptom:** the codebase works but no one on the team understands the changes the loop
  shipped; onboarding slows, incidents take longer.
- **Mechanism:** an unattended loop shipped correct-but-unreviewed changes for weeks;
  comprehension debt compounded silently.
- **Catch:** the tier ladder is the antidote — **start at L1 (report-only)** and *read
  the reports*; graduate to L2 only once you trust its judgment, and keep the human in the
  PR loop. Autonomy is earned with evidence, not granted up front. Build the loop like you
  intend to stay the engineer.

---

## At a glance — symptom → control

| Failure | Primary control |
|---|---|
| Runaway budget | `budget_tokens` + `loop-estimate` + `loop-doctor` budget check |
| 3am-dead | `loop-doctor --live` (gate binary + PATH) |
| Cache-cold | byte-identical `run.md` + `loop-estimate` TTL guidance |
| Force-push / prod | escalation gate + auto-mode classifier |
| Ungated-child spawn | scheduler-invokes-`claude -p` (rule #2) |
| Colliding loops | priority order + per-loop worktree + `pigeon` |
| Silent-stop | `STATE.md`/run-log heartbeat staleness |
| Gate reward-hacking | full-suite `guard` + scope excludes tests + human PR gate |
| Unbounded scope | `loop-check` rejects `*` |
| No kill switch | mandatory `kill_switch` + PreToolUse PAUSED hook |
| Comprehension debt | L1-first graduation; read the reports |

## See also

- [risk-tiers.md](risk-tiers.md) — the graduated-autonomy ladder behind #11.
- [state-spine.md](state-spine.md) — budget + heartbeat + multi-loop coordination.
- [../../../rules/loop-engineering.md](../../../rules/loop-engineering.md) — the directives that prevent #4/#5/#9/#10.
