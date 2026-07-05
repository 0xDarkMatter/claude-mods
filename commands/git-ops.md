---
description: "Git + worktree orchestrator entry point. /git-ops --landall surveys every branch/worktree and batch-lands the ones that are done; bare /git-ops runs a status survey. Thin router over the git-ops skill."
---

# /git-ops — git + worktree orchestrator

Thin command wrapper over the **git-ops** skill. The skill owns the logic
(`SKILL.md`, `scripts/`); this command just routes `$ARGUMENTS` to the right mode.

## Arguments

$ARGUMENTS

| Invocation | Mode |
|------------|------|
| `/git-ops --landall` (aliases: `landall`, `land-all`, `land all`) | **Land all** — survey → classify → confirm → batch-land |
| `/git-ops` (no args) | Status survey (`status.sh` + `worktree-survey.sh`) |
| `/git-ops <anything else>` | Pass the request to the git-ops skill as-is |

Always **invoke the `git-ops` skill** (Skill tool) first, then follow the branch below.

## `--landall` — batch-land every pending lane

This is the front-door for "I've got 4-5 chips/sessions/worktrees, land the ones
that are done." git-ops discovers + classifies; **fleet-ops** executes the
sequential, test-gated landing. Follow the skill's **"Land all"** section exactly.
The flow, in short:

1. **Survey (read-only).** Run:
   ```bash
   bash $HOME/.claude/skills/git-ops/scripts/land-all.sh --porcelain
   ```
   Pass `--recent-days N` through from `$ARGUMENTS` if the user gave one (their
   lanes may span longer than the 7-day default); pass `--active-window N` to tune
   the live-writer threshold. Each branch is classified
   **LANDABLE / STALE / WIP / ACTIVE / MERGED**.

2. **Confirm the plan (`AskUserQuestion`, required).** Present three groups —
   *land these LANDABLE / park these WIP+ACTIVE+STALE / prune these MERGED* — and
   get an explicit go. Surface any `far behind (N)` notes so the user knows which
   lands may conflict. Never land without this confirm: it writes to the trunk.

3. **Execute via fleet-ops** (only the confirmed landable set):
   ```bash
   bash $HOME/.claude/skills/fleet-ops/scripts/fleet.sh track <landable-branches...>
   bash $HOME/.claude/skills/fleet-ops/scripts/fleet.sh land --all --running
   ```
   Lands oldest-first, through the test gate, auto-rebasing the rest after each.

4. **Escalate conflicts — never auto-resolve.** A `CONFLICT` lane is reported, not
   guessed. Offer: resolve in the lane, skip, or `fleet revert <branch>`.

5. **Offer cleanup (survey-first, T3).** `MERGED` branches + now-landed worktrees are
   prune candidates — follow the skill's Survey-first + T3 Remove preflight. Never
   auto-remove. Respect `rules/worktree-boundaries.md`: `ACTIVE`/orphan trees are
   never touched.

**Safety invariants:** `ACTIVE` (a live peer writer) is never landed. `WIP` needs an
explicit in-lane commit first. `STALE` needs explicit opt-in (`--recent-days` or naming
the branch). Only `LANDABLE` lands by default.

## No args — status survey

Invoke the git-ops skill and run its Tier-1 status + worktree survey; present the
result. This is the "where are we / anything to commit or land" quick view.
