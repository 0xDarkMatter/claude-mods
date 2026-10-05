# Lane Provisioning: What new-lane.sh Does

Detail for the Worktree Operations row in SKILL.md: what `scripts/new-lane.sh` creates, the safety preconditions it enforces, and how durable lane work is.

### Lane provisioning (the collision remedy)

`scripts/new-lane.sh <slug> [base-branch]` is the fast, model-invocable way to isolate parallel
work — the remedy the peer-writer guards (`session-start-unicode-scan.sh` at boot,
`pre-write-peer-guard.sh` mid-session) point you to. It:

- creates branch `lane/<slug>` **in-repo** at `<main>/.claude/worktrees/<slug>` — the native
  Claude Code worktree location: tidy (no sibling dirs scattered across the parent) and gitignored
  so `git add -A` can't stage its gitlinks — off `[base-branch]` (default: current branch);
- **ensures the gitignore precondition**: if `.claude/worktrees/` isn't gitignored it adds the entry
  first (the in-repo location is only safe when ignored), so the default is safe in *any* repo;
- **`--sibling`** places it outside the repo at `<repo>/../<repo>-<slug>` instead — use when you need
  structural isolation from repo-scoped destructive ops (`git clean -ff`, `rm -rf <repo>`) or in a
  repo that can't gitignore the dir;
- anchors at the **main** worktree root, so invoking it from inside a lane won't nest worktrees;
- **carries over gitignored env files** (`.dev.vars`, `.env*`, `.secrets`) the fresh worktree
  would otherwise lack, so the lane runs immediately;
- prints the worktree path on stdout (everything else on stderr), so it composes:
  `cd "$(bash scripts/new-lane.sh hotfix main)"`;
- refuses if the branch or path already exists — never clobbers.

Lane work durability: **committed** lane work lives in the shared object store and survives even
deletion of the worktree dir (recover via `git worktree add <path> lane/<slug>`); only *uncommitted*
work is at risk from `git clean -ff` / `rm -rf`. Land early/often — see `rules/worktree-boundaries.md`.

Run it **inline** (deterministic, non-destructive); land the lane back via the Worktree Land
Procedure below or `fleet-ops`. Reach for it whenever two sessions would otherwise share one checkout.
