# fleet-worker → fleet-ops handoff

The two skills are the two halves of one cheap-labour pipeline:

```
Opus orchestrator (this session)
   │  fan out — one fleet-worker per task, each in its own worktree + config dir
   ▼
fleet-worker × N    ← cheap "grunt" workers, full Claude Code tool harness
   │  each leaves a branch with commits
   ▼
fleet-collect.sh    ← keep only the workers that truly succeeded (is_error:false)
   ▼
fleet track / fleet land   ← sequential, test-gated landing; you review each diff
   ▼
main
```

`fleet-worker` is the **spawn layer** that [`fleet-ops`](../../fleet-ops/) explicitly
disowns ("anything before *committed on a branch* is the spawning layer's
problem"). `fleet-ops` is the **landing layer**. Neither overlaps; together they
cover spawn → verify → land. No new code is needed in fleet-ops — the workers
produce ordinary branches, and fleet-ops lands branches.

## End-to-end walkthrough

### 1. Fan out (fleet-worker)

Each task gets its own worktree/branch and its own isolated config dir:

```bash
delegate() {                     # $1 = task-id, $2 = prompt
  local id="$1" prompt="$2" wt=".fleet-work/$1"
  git worktree add -q -b "fleet/$id" "$wt" HEAD
  ( cd "$wt"
    FLEET_WORKER_CONFIG_DIR="$HOME/.fleet-worker/cfg-$id" \
      fleet-worker --output-format json "$prompt" > "../$id.result.json" 2> "../$id.err"
    # the worker edits files; commit so the branch carries the work
    git add -A && git commit -q -m "fleet/$id: $prompt" || true
  )
}

delegate fix-lint    "Fix all eslint errors under src/, no behaviour changes"
delegate add-tests   "Add unit tests for src/auth/ to cover the happy + error paths"
delegate doc-sync    "Update README install section to match scripts/install.sh"
```

Run these in the background from the orchestrator's Bash tool
(`run_in_background: true`) and collect on completion. Keep concurrency ≤ 4–6.

> The worker commits inside its worktree so the branch has commits for fleet-ops
> to land. If you prefer, let the worker leave the tree dirty and commit from the
> orchestrator after reviewing — but `fleet land` needs an immutable commit.

### 2. Gate (fleet-collect.sh)

Decide which branches are even worth landing — `fleet-collect.sh` exits `0` only on
a true success (`is_error:false`), `10` on a failed/overloaded worker:

```bash
winners=()
for id in fix-lint add-tests doc-sync; do
  if fleet-collect.sh ".fleet-work/$id.result.json" >/dev/null; then
    winners+=("fleet/$id"); echo "fleet/$id  OK"
  else
    echo "fleet/$id  FAILED — discard or re-dispatch"
  fi
done
```

Re-dispatch failures idempotently (the worktree makes retries clean) or drop them.

### 3. Land (fleet-ops)

Register the winning branches as lanes and land them — sequential, test-gated,
with auto-rebase of the remaining lanes and your review of each diff:

```bash
fleet track "${winners[@]}"        # register existing branches as lanes
fleet status                        # see all lanes
fleet land fleet/fix-lint             # scrub → clean-base → merge → test gate → rebase others
fleet land fleet/add-tests
fleet land fleet/doc-sync
```

If a landing breaks the build, `fleet revert fleet/<id>` backs it out in one
command. fleet-ops' pre-land scrub also refuses diffs with forbidden patterns
(debug leftovers, `TODO_SCRUB`) — a useful backstop for grunt-worker output.

## Why the orchestrator stays in the loop

The worker is cheap and *unreviewed* by design. The value of the pairing is that
**Opus verifies before anything lands**:

- `fleet-collect.sh` filters out workers that errored or got overloaded.
- `fleet land` runs the **test gate** — a worker that wrote plausible-but-wrong
  code fails the tests and is hard-reset, never reaching `main`.
- You (Opus) **review each diff** at land time — the merge gate is the quality
  control the cheap model doesn't provide.

## Recovery scenarios

| Situation | Move |
|---|---|
| Worker returned `is_error:true` (529/overload) | Re-dispatch the same task (idempotent worktree); or route to `FLEET_WORKER_SMALL_MODEL` |
| Worker succeeded but diff is wrong on review | Don't `fleet track` it; delete the branch + worktree |
| Lane fails the test gate after merge | `fleet revert fleet/<id>`, then re-dispatch with a tighter prompt |
| Two workers touched the same files | fleet-ops lands sequentially and rebases; a rebase conflict marks the lane `CONFLICT` — resolve in its worktree |
| Scratch dirs cluttering the tree | `git worktree remove .fleet-work/<id>`; `.gitignore` `.fleet-work/` and `.fleet-worker/` |

## Boundaries (what each side owns)

| fleet-worker owns | fleet-ops owns |
|---|---|
| Spawning workers, model/endpoint/auth, isolated config dirs | Landing branches: scrub, test gate, sequential merge, rebase, revert |
| Producing a branch with commits per task | Ordering and integration against an up-to-date `main` |
| Gating raw worker results (`fleet-collect.sh`) | Fleet status across lanes/worktrees |

Don't try to make fleet-ops spawn workers, and don't make fleet-worker merge — the
seam is the branch.
