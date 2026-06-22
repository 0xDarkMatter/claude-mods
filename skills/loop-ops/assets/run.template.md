<!--
run.md — the prompt a scheduler feeds to `claude -p` each tick. It is the SAME
every run (fresh context each time; state lives in STATE.md + the codebase + git,
not the conversation — the Ralph property). Fill the <PLACEHOLDERS>; keep it short.

Wire it up (see references/claude-code-loops.md):
  claude -p "$(cat .loops/<loop-name>/run.md)" \
    --permission-mode <permission_mode-from-config> \
    --append-system-prompt "$(cat .loops/<loop-name>/STATE.md)"
The SCHEDULER (cron / Task Scheduler / CI), not a Claude session, invokes this.
-->

# Run: <loop-name>  (tier <L1|L2|L3>)

You are one tick of a scheduled loop. Goal: **<one sentence — what to do AND what never to do>**.

## Do these in order

1. **Check the kill switch FIRST.** If <kill_switch — e.g. `.loops/<loop-name>/PAUSED` exists, or the `loop-pause` label is set>, STOP immediately and do nothing else.
2. **Read `STATE.md`** (appended to your system prompt). It is your memory of prior runs: the Priority / Watch / Noise lists.
3. **Pick the next unit of work** from the Priority list. Stay strictly within scope: `<scope globs — never *>`.
4. **Do the tier-appropriate action:**
   - **L1 (report-only):** investigate and summarize. Write NOTHING but `STATE.md`.
   - **L2 (assisted):** make the change in a **git worktree**; run the gate `<verify>` and guard `<guard>`; if both pass, hand the branch to `<land_via — e.g. fleet-ops>`; otherwise discard.
5. **Apply the escalation rule.** If the action would <escalation — e.g. force-push / push to main / deploy / delete pre-existing files / edit .claude>, do NOT do it — escalate to a human with context instead.
6. **Respect the budget.** Stop this run if you approach `<budget_tokens>` output tokens.
7. **Rewrite `STATE.md`:** promote/demote items across Priority / Watch / Noise, bump the `_Updated_` line + run number + readiness score.
8. **Append one line to `run-log.md`:** `<ISO-Z>  run#N  action=<…>  outcome=<…>  tokens=<N>`.

## Hard rules
- A general goal is NOT authorization for a specific high-blast action it implies — when in doubt, escalate.
- Never act outside `scope`. Never touch another session's `.claude/worktrees/`.
- Leave the repo in a clean, reviewable state every tick.
