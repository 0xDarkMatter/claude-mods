# Land All: Full Procedure

The batch-land front door in full. SKILL.md keeps the summary, the HARD RULE to confirm the plan, and the safety invariants.

## Land all — batch-land every pending lane (T1 plan → fleet-ops execution)

The front-door for "I've got 4-5 chips/sessions/worktrees, land the ones that are
done." git-ops **discovers and classifies**; `fleet-ops` **executes** the sequential,
test-gated landing. No duplicated landing logic — the two compose.

**Triggers:** "land everything", "land all my worktrees", "land the pending chips",
"clean up and land what's done", "where are we and land it".

**Procedure:**

1. **Survey (T1, read-only).** Run `scripts/land-all.sh --porcelain` (add `--recent-days N`
   if the user's lanes span longer than a week). Each candidate branch is classified:

   | Status | Meaning | Default action |
   |--------|---------|----------------|
   | `LANDABLE` | clean, ahead, not merged, recent, no live writer | **land** |
   | `STALE` | clean + ahead but last commit > `--recent-days` old | park (offer to prune/archive, or land explicitly) |
   | `WIP` | uncommitted tracked changes | park — commit in-lane first |
   | `ACTIVE` | a session is writing it **right now** (recent file activity) | **never land** — park |
   | `MERGED` | already an ancestor of trunk (incl. nothing ahead) | prune candidate |

2. **Confirm the plan (`AskUserQuestion`, HARD RULE).** Present the three groups — *land these
   LANDABLE / park these WIP+ACTIVE+STALE / prune these MERGED* — and get explicit go.
   Never skip this: landing is outward-facing on the trunk. Surface `far behind (N)` notes so the
   user knows which lands may conflict.

3. **Execute via fleet-ops.** For the confirmed landable set:
   ```bash
   bash $HOME/.claude/skills/fleet-ops/scripts/fleet.sh track <landable-branches...>
   bash $HOME/.claude/skills/fleet-ops/scripts/fleet.sh land --all --running
   ```
   fleet-ops lands **oldest-first**, runs the test gate, **auto-rebases** the remaining lanes after
   each land, and marks any lane that hits a real conflict `CONFLICT` — it does **not** guess a
   resolution. This is a T2 write; dispatch through `git-agent` or run inline if the user is waiting.

4. **Escalate conflicts, don't auto-resolve.** A `CONFLICT` lane stops being landed and is reported.
   Offer: resolve in the lane, skip it, or revert (`fleet revert <branch>`). Sequential + auto-rebase
   *minimises* conflicts (each lane rebases onto a trunk that already has the prior lands); genuine
   semantic conflicts are always the user's call.

5. **Offer cleanup (survey-first, T3).** After landing, the `MERGED` branches and any
   now-landed worktrees are prune candidates. Follow **Survey-first discipline** + the T3 Remove
   preflight — never auto-`git worktree remove`; confirm per worktree. Respect
   `rules/worktree-boundaries.md` throughout: `ACTIVE`/orphan/unregistered trees are never touched.
