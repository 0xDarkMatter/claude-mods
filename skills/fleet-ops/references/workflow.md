# Workflow

End-to-end walkthrough plus recovery scenarios. The decision tree and CLI surface live in `SKILL.md` — this doc is the operational manual.

## End-to-end

### 1. Init

```bash
fleet init auth-mw rate-limiter cache-layer
```

Creates: a branch per name (off `main`), a worktree at `.fleet/worktrees/<name>/`, a status file at `.fleet/lanes/<name>` (state: `RUNNING`), and deploys `signal.sh` to `.fleet/signal.sh`.

Force branch-only mode: `mode=branch` in `.fleet/config`. Use this when each session is in a separate clone or remote machine — no worktrees needed.

### 2. Launch sessions

For each lane, open a Claude session pointing at that worktree (or that clone). Use `references/session-prompt.md` as the template — fill in `LANE`, `SCOPE`, `TASK`, `TESTS`.

Each session works in isolation, commits atomically, runs tests, and signals when ready:

```bash
bash .fleet/signal.sh READY tests/test_auth.log
```

`signal.sh` will refuse if the lane has uncommitted changes or if the test log shows failures.

### 3. Run the daemon

```bash
fleet start
```

Polls `.fleet/lanes/` every 5 seconds. When a lane shows `READY`:

1. Pre-land scrub — refuses if forbidden patterns found in the diff
2. Refuses if `main` is dirty
3. Merges the branch with `--no-ff`
4. Runs `test_cmd` if set; otherwise trusts `signal.sh`'s log gate
5. On pass: marks lane `LANDED`, deletes branch, rebases all other active lanes
6. On fail: hard-resets `main`, marks lane `FAILED`

### 4. Watch

```bash
fleet fleet
```

```
── Fleet ──────────────────────────────────────────────────────
       BRANCH                           STATUS     AGE
────────────────────────────────────────────────────────────────
  ⏳   auth-mw                          RUNNING    23m
  ✅   rate-limiter                     READY      1m
  🚀   cache-layer                      LANDED     8m
  ⚠️   error-handling                   CONFLICT   12m
────────────────────────────────────────────────────────────────
```

### 5. Cleanup

When all lanes are terminal (`LANDED` or `FAILED`), the daemon exits. To tear down:

```bash
git worktree remove .fleet/worktrees/<name>     # for each worktree lane
rm -rf .fleet                                    # nuke fleet state
```

`fleet init` is idempotent — keep `.fleet/` for the next round if you want.

## Recovery

### `CONFLICT` lane (rebase or merge failed)

Pop into that session's terminal. Tell Claude:

> "Rebase conflict on `<file>`. Lane that landed modified `<symbol>`. Resolve and re-signal READY."

Or resolve manually:

```bash
git checkout <lane-branch>
# fix conflicts
git rebase --continue
bash .fleet/signal.sh READY <test-log>
```

### `FAILED` lane (tests broke `main` post-merge)

Daemon already reverted the merge. Branch still exists:

```bash
git checkout <lane-branch>
# fix the test
bash .fleet/signal.sh READY <test-log>
```

Daemon picks it up on next poll.

### Bad land that snuck through scrub + tests

```bash
fleet revert <branch>
```

Finds the merge commit on `main` (by message `merge: <branch>`), runs `git revert -m 1`, logs the action. No git surgery while you're panicking.

## Common patterns

### Five small refactors, no shared scope

Default mode. Each lane is independent. Cleanest case — daemon handles everything.

### Lanes with shared dependencies

Land the foundational lane first via `fleet land <branch>`, others rebase against it automatically. Daemon will pick them up after.

### Long-running session + several quick fixes

Land the quick fixes first. The long-running lane rebases against each landing. By the time it's done, `main` has all the small wins.

### Hackathon pace, multiple lanes ready at once

Currently the daemon lands them strictly one at a time. If batch mode becomes a real need, the next iteration adds `--batch`.
