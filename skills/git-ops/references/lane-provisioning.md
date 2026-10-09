# Lane Provisioning: What new-lane.sh Does

Detail for the Worktree Operations row in SKILL.md: what `scripts/new-lane.sh` creates, the safety preconditions it enforces, and how durable lane work is.

### Lane provisioning (the collision remedy)

`scripts/new-lane.sh <slug> [base-branch]` is the fast, model-invocable way to isolate parallel
work — the remedy the peer-writer guards (`session-start-unicode-scan.sh` at boot,
`pre-write-peer-guard.sh` mid-session) point you to. It:

- creates branch `lane/<slug>` off `[base-branch]` (default: current branch), placed by the first
  rule that applies:
  1. **`WORKTREE_ROOT` set** → `$WORKTREE_ROOT/<repo>/<slug>` (`<repo>` = the main checkout's dir
     name). The machine-wide root keeps project dirs free of lanes; it wins over `--sibling` and
     needs no gitignore entry;
  2. **`--sibling`** → `<repo>/../<repo>-<slug>`, outside the repo — structural isolation from
     repo-scoped destructive ops (`git clean -ff`, `rm -rf <repo>`), or a repo that can't gitignore
     the dir;
  3. default → **in-repo** at `<main>/.claude/worktrees/<slug>`, the native Claude Code location;
- **ensures the gitignore precondition** for the in-repo case only: if `.claude/worktrees/` isn't
  gitignored it adds the entry first (that location is only safe when ignored), so the default is
  safe in *any* repo;
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
