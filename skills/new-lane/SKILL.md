---
name: new-lane
description: "Create an isolated git worktree + branch ('lane') for parallel work in one step, carrying over the gitignored env files a fresh worktree lacks. Use when the peer-writer guard warns that another session is editing this checkout, when you want to parallelise work without two sessions sharing one working tree, or when asked to 'spin up a worktree / lane / isolated branch'. Triggers on: new lane, isolate this work, worktree for X, parallel session without collision, peer-writer advisory, move to a worktree, spin up a lane."
license: MIT
allowed-tools: "Bash"
metadata:
  author: claude-mods
  related-skills: "git-ops, fleet-ops"
---

# New Lane

The one-command remedy for the collision problem: **one writer, one worktree, one branch.** When two
sessions share a checkout they fight over a single index/HEAD (see
[worktree-boundaries](../../rules/worktree-boundaries.md) → "Provisioning discipline"). This skill
spins up an isolated *lane* so parallel work never collides.

Reach for it when:
- the **peer-writer guard** fires (`session-start-unicode-scan.sh` at boot, or `pre-write-peer-guard.sh`
  mid-session) — another session is editing this tree; move your work into its own lane;
- you're about to start a second stream of work and don't want to share the checkout;
- the user asks to "isolate this", "spin up a worktree/lane", or "branch this off without touching main".

## Use

```bash
bash scripts/new-lane.sh <slug> [base-branch]
```

- `<slug>` → branch `lane/<slug>`, worktree at `<repo>/../<repo>-<slug>` (sibling dir — outside the
  repo, never under `.claude/`, no long-path nesting).
- `[base-branch]` defaults to the current branch.

It creates the worktree+branch and **carries over gitignored env files** (`.dev.vars`, `.env*`,
`.secrets`) the fresh worktree would otherwise be missing — the "right settings" that make the lane
immediately runnable. The new worktree's absolute path is printed on stdout (everything else on
stderr), so it composes: `cd "$(bash scripts/new-lane.sh hotfix main)"`.

## After

Open a Claude session with its cwd set to the printed worktree path — that session is the lane's sole
writer. Land the lane back onto the base branch through **[fleet-ops](../fleet-ops/SKILL.md)** (the
test-gated landing queue), not by sharing the checkout again.

## Boundaries

- Refuses if the branch or worktree path already exists (exit 1) — never clobbers.
- Does **not** spawn the session or run installs; it provisions the isolated tree, nothing more.
- Never touches `.claude/worktrees/` or another session's lanes (see worktree-boundaries).
