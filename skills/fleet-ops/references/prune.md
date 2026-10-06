# Prune: Buckets, Claims and the Removal Landmine

The full bucket table and the order that makes it safe, how a session claims a worktree, why `.claude/worktrees/` trees need positive evidence, and the silent-spin hazard of removing a worktree under a live session.

## Contents

- [Buckets — first match wins, and the order is the safety argument](#buckets--first-match-wins-and-the-order-is-the-safety-argument)
- [Why `.claude/worktrees/` gets extra care](#why-claudeworktrees-gets-extra-care)
- [Landmine: removing a worktree out from under a live session](#landmine-removing-a-worktree-out-from-under-a-live-session)

### Buckets — first match wins, and the order is the safety argument

| # | Condition | Bucket |
|---|---|---|
| 1 | primary / git-locked / the tree you invoked from | **KEEP** |
| 1b | git reports the directory gone | **REVIEW** (that's `git worktree prune`'s job) |
| 2 | any session claiming it is LIVE | **KEEP** |
| 3 | session store unreadable, or `session_check=off` | **REVIEW** |
| 4 | detached HEAD — **SAFE** only if clean, no git operation in progress (rebase, bisect, ...), HEAD already in `base_branch`, no open claim, and an archived session positively claims it | **REVIEW** |
| 5 | uncommitted or untracked changes | **REVIEW** |
| 6 | commits not yet in `base_branch` | **REVIEW** |
| 7 | merged + clean, no open session claims it — and for `.claude/worktrees/`, an archived session positively does | **SAFE** |
| 8 | anything else (incl. an open owner, an owner whose archive flag cannot be read, or a `.claude/worktrees/` tree no session record mentions) | **REVIEW** |

Only **SAFE** is ever removable. **KEEP** means one thing — hands off, not yours
to judge. Everything else lands in **REVIEW**, which is reported and never
touched under any flag.

**How a session claims a worktree.** By its branch (checked-out or
`writtenBranches`), by its wrapper's `cwd` or `worktreePath` (compared
normalised: slashes, case, `X:` vs `/x/`), by the worktree path a
`writtenBranches` pair names (`written`: Desktop writes `<path>\0<branch>` since
about 2026-09-24), by the directory its CLI transcript is filed under
(`EnterWorktree` moves it there; the wrapper's `cwd` never changes, and a resume
files it back under that `cwd`), and, while live, by the last `cwd` its
transcript recorded. `fleet owner` and the land gate read these same claims
([session-awareness](session-awareness.md#fleet-owner-sees-a-session-that-moved-in-2026-10-06)). The store
read is the **union** of every Desktop instance's store — the primary and each
`--user-data-dir` instance under `~/.claude-desktop-profiles/` — and `fleet
config` lists which ones answered. Liveness is the newer of the wrapper's
`lastActivityAt` and the transcript's mtime, because Desktop rewrites the
wrapper only at turn boundaries: a session deep in one long turn reads idle on
the wrapper alone. An **archived** session is live only if its transcript was
written after the archive (below).

**Archived owners (2026-10-05).** Ten sessions were archived after their lanes
landed, and a dry run still listed all 17 of their worktrees as KEEP, "live
session ... (by transcript)". Archiving stops a session, and the stop appends
records to its transcript ~2s before the wrapper gets `isArchived: true`. That
write read as activity for ten minutes, and the index cache carried it for up to
fifteen more. Now:

- An archived session counts as live only on a transcript write newer than the
  archive (the wrapper's mtime, plus 60s). A terminal `claude --resume` of it
  still keeps its trees.
- `fleet prune` re-reads every claimant of the repo's worktrees fresh
  (`sessions.sh state`) before classifying. The cache `fleet land` built is
  older than the archive, and it would still say "open".
- An `isArchived` that is missing or not a boolean is unreadable. It is treated
  as live/open, never as archived, and the reason says "archive flag unreadable".
- Archived + dirty or unmerged stays REVIEW, and the reason names the owner as
  archived. Detached leftovers follow rule 4.

**Positive evidence is an exact path.** An archived session proves a tree by its
wrapper's `cwd`/`worktreePath`, or by the cwd its transcript last recorded
(read fresh by `fleet prune`). For a lane the session `EnterWorktree`'d into,
that cwd is the only proof: its wrapper's `cwd` and `gitAnchors` name only the
tree it was spawned in. A `written` claim names the lane too, but it only keeps
a tree; it is not proof yet. The transcript *directory* key alone never proves
anything, because `lane.x` and `lane-x` encode to the same key.

**The near-miss that shaped this (2026-09-28).** A dry run in a real repo
classified 12 of 17 worktrees SAFE, "merged + clean, no session owns it" — five
of them the cwd of an open session, two of those running. The owners were all
in a second Desktop instance's store, which `sessions.sh` never opened; it read
the primary store, found it readable and populated, and took its silence for
evidence. Ownership was also joined on branch only, never on `cwd`, and the
wrapper's stale timestamp called the running sessions idle. `--remove` would
have stranded both in the silent spin described below. The fixes are the
claims above, and rule 7's positive-claim clause as the backstop for whatever
the joins still miss.

**Known limitation — writes by absolute path.** A session whose cwd never
entered a worktree, but which writes into it by absolute path, leaves no claim
in any store or transcript. Prune cannot see it, so prune must never be the
only guard: check `fleet status`, and your own lanes, before `--remove`.

Rule 3 is the one that matters most on a non-Desktop host: *"the store says
nobody owns this"* is evidence of abandonment, while *"the store could not be
read"* is no evidence at all — and an empty index looks identical to both. When
the store or `jq` is missing, **nothing can be classified SAFE** and prune
degrades to a pure report. It never fails, and it never guesses.

### Why `.claude/worktrees/` gets extra care

Those directories are Claude Code's own session worktrees, and
[`worktree-boundaries`](../../../rules/worktree-boundaries.md) is blunt about them:
*they may look orphaned and aren't*. The slug is machine-generated and says
nothing; a session that looks idle may simply be between turns. Prune marks them
`!` in the table, and SAFE requires an archived session that positively claims
the tree — by branch, by exact `cwd`/`worktreePath`, or by the exact cwd its
transcript last recorded — so one can only be removed on positive evidence,
never on the absence of a signal. (The docs promised this before the code kept
it; since 2026-09-28 it does.)

Three further guards, all on the irreversible direction:

1. **`git worktree remove`, never `rm -rf`.** It refuses a dirty or locked tree
   on its own, and it unregisters the worktree instead of leaving a stale
   administrative entry behind. On Windows it can still fail with `Permission
   denied` *after* emptying and unregistering the tree, because a process (a
   shell or editor standing in it) holds the directory itself. Prune checks for
   exactly that end state: unregistered and empty. It reports the tree as
   removed, plus an empty leftover. `fleet sweep` lists that leftover
   (`HOLLOW` while a session's cwd, `KEEP` for its first hour, then
   `EMPTY-DIR`), and `fleet sweep --apply` removes it once nothing holds it.
   Anything else still reads `FAILED`.
2. **Re-verify immediately before deleting.** Classification reads a session
   index with a long TTL (15 min), refreshed only for the sessions already in
   it; a session can wake, be unarchived, or move into a tree between the table
   and the delete. So `--remove` first re-runs the
   *same* classifier against a forced-fresh scan of every store (this can take
   a minute), skips any row that is no longer SAFE, and then re-checks each
   survivor's owner liveness and dirtiness once more right before its delete.
3. **`--all-repos` can never remove.** It reports counts for sibling repos and
   stops there. Acting on another repo means running `fleet prune` inside it,
   where that repo's own base branch and config apply — so a single command can
   never sweep the machine.

### Landmine: removing a worktree out from under a live session

**Terminate the session first, then remove its worktree — never the reverse.**
`fleet prune` already enforces this: bucket 2 keeps a LIVE owner, and guard 2
re-verifies liveness immediately before each delete. The hazard is every *other*
path — a hand-run `git worktree remove`, an `rm -rf`, an external teardown
script, or a `--remove --yes` sweep racing a session that wakes mid-run.

**A session whose worktree vanishes does not exit and does not error.** It drops
into a retry loop and spins at ~85% of a core, indefinitely. Six of them,
observed 2026-08-30 across one repo's lane worktrees, burned **66.6 core-hours
across 43.8 hours**; five pointed at directories absent from both disk *and*
`git worktree list`. Nothing logged, nothing alerted, no transcript was written.
The only symptom was a warm machine.

It also evades the obvious check. These processes keep a **live** parent — the
Desktop instance that spawned them — so a dead-parent orphan scan reports
nothing useful: on that same machine it found 3 orphans totalling 1.16 GB while
the six spinners held five cores. **Detect by CPU rate, not by lineage.** Sample
twice and flag sustained burn:

```powershell
$s=@{}; Get-Process claude,node -EA SilentlyContinue | % { $s[$_.Id]=$_.CPU }
Start-Sleep 10
Get-Process claude,node -EA SilentlyContinue |
  ? { $s[$_.Id] -ne $null -and ($_.CPU-$s[$_.Id])/10 -gt 0.5 } |
  Select Id,@{n='CorePct';e={[math]::Round(($_.CPU-$s[$_.Id])/10*100)}}
```

POSIX equivalent: `ps -eo pid,pcpu,etimes,args | grep claude` — a lane process
at steady high `pcpu` with a large `etimes` is the same signature. Cross-check
the offender's `--add-dir` against `git worktree list`; a target missing from
both is conclusive. Killing the process is safe — it frees the CPU and touches
no files, so uncommitted work in any surviving worktree is untouched.
