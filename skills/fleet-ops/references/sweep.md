# Sweep: Post-Wave Housekeeping

`fleet sweep` is the one ordered pass to run after a wave of chips, background
agents or fleet lanes. It answers, per repo: what landed (by ancestry *or* by
content), which lanes fight over the same files, which worktrees, branches,
empty dirs and stashes are leftovers, and which finished sessions to ask to
archive. It reports by default; `--apply` does only the zero-loss part.

## Contents

- [The procedure](#the-procedure)
- [Verdicts](#verdicts)
- [Landed by content](#landed-by-content)
- [Competing work](#competing-work)
- [Sessions: requests vs direct archives](#sessions-requests-vs-direct-archives)
- [Desktop instances: act from the right window](#desktop-instances-act-from-the-right-window)
- [--apply: the zero-loss classes](#--apply-the-zero-loss-classes)
- [The never-push list](#the-never-push-list)
- [The hold list](#the-hold-list)
- [Limits](#limits)

## The procedure

Run `fleet sweep` from MAIN (the repo-root session). Then work the "Next, in
order" list it prints, **re-running the sweep after each step**. Nothing is
cached or journalled: every verdict is recomputed from git and the session
store, so a step you finished disappears and a step that half-worked shows what
is left. That is what makes it resumable after an interruption.

0. **Wait while `main` is not settled.** Every verdict is judged against `main`'s
   tip. While a land holds it (`PROVISIONAL`: merged, gate still running) or it
   holds an `UNTESTED-MERGE`, the lane being landed reads as merged and would be
   routed to removal. So the sweep's first row says so, every other action
   becomes `wait`, the next steps are just WAIT, and `--apply` refuses (exit 5).
   It asks at the start and again just before it prints. A land that begins
   mid-run, which on a busy machine is minutes long, still turns the report to
   `wait`.
   Re-run once `fleet landing` exits 0. See [landing.md](landing.md#provisional-main).
1. **Settle competing pairs** (phase 2). Pick the winner before landing either.
2. **Land** `LAND` rows (`fleet land <branch>`); hand `REBASE` rows back to their lane. Leave `ON-HOLD` rows alone.
3. **Inspect** `INSPECT` trees: commit the work in its lane, or discard it after review.
4. **Sessions** (phase 5): send each `ARCHIVE-REQUEST`, archive each `ARCHIVE-DIRECT`. Agent step, one gated call each, and only for sessions in your own Desktop instance. A row whose session lives in another instance names that window instead ([below](#desktop-instances-act-from-the-right-window)).
5. **Remove** `REMOVE` worktrees with `fleet prune --remove`. Archived owners now let prune prove them SAFE.
6. **Zero-loss hygiene**: `fleet sweep --apply`.
7. **By hand, with an OK**: `CONTENT-LANDED`, `VERIFY-OWNER`, `ORPHAN-DIR`, `STALE`, `STALE-STASH`, `LEAKED`.

The sweep never removes a worktree itself. That stays `fleet prune --remove`,
whose classifier the sweep reads (`--porcelain`) and never reimplements.

## Verdicts

| Phase | Verdict | Means | Next action |
|---|---|---|---|
| landing | `PROVISIONAL` | a land holds `main`: about to merge, merged and gating, or rebasing the other lanes | wait; re-run once `fleet landing` exits 0 |
| landing | `UNTESTED-MERGE` | a dead land left a merge no gate judged | verify, then `fleet land` (green) or `fleet revert` (red) |
| landing | `DEAD-LAND` | a dead land left nothing untested (informational) | none; the next land clears it |
| worktree | `KEEP` | prune's KEEP, or a claimant is live on a fresh read | none |
| worktree | `REMOVE` | prune's SAFE | `fleet prune --remove` |
| worktree | `GHOST` | git lists it, the directory is gone | `--apply` (`git worktree prune`) |
| worktree | `PARK` | its branch is on the never-push list | keep local; never land or push |
| worktree | `COMPETING` | shares non-ledger files with another lane | settle in phase 2 |
| worktree | `INSPECT` | uncommitted work, or a detached HEAD with new commits | commit in its lane, or discard |
| worktree | `ASK-ARCHIVE` | landed + clean, owner open and idle, owner done everywhere | phase 5 |
| worktree | `OWNER-BUSY` | landed + clean, but its owner has unlanded work elsewhere (or is this session / MAIN) | land the blocker first |
| worktree | `CONTENT-LANDED` | not an ancestor, but its content is in base | remove tree + branch after an OK |
| worktree | `VERIFY-OWNER` | merged + clean, prune cannot prove the owner archived | find the session (below) |
| worktree | `FLEETFLOW` | a landed fleetflow lane | `ff-clean.sh --run <run>` |
| worktree | `LAND` / `REBASE` | unlanded; merges cleanly / conflicts with base | `fleet land` / rebase in the lane |
| worktree | `ON-HOLD` | unlanded, and on the [hold list](#the-hold-list); the detail opens with the hold's reason | none: no land, no rebase, until the hold is lifted |
| compete | `OVERLAP` | the pair and the shared files; "uncommitted in X" names the side, "X ON HOLD" a side that cannot win yet | pick a winner |
| branch | `DELETE-MERGED` | worktree-less, every commit in base, nobody holds it | `--apply` |
| branch | `HELD` | merged, but an open session's record names it (archive flag read fresh) | none (deleted once it archives) |
| branch | `ON-HOLD` | worktree-less, unlanded, on the hold list | none, as above |
| branch | `TRACKED` | a fleet lane file in a non-terminal state names it | none |
| branch | `CONTENT-LANDED` / `STALE` / `UNLANDED` | as the words say, with ages | by hand |
| branch | `PARK` / `LEAKED` | never-push branch; with a remote copy it is `LEAKED` | `LEAKED`: review with the owner now |
| hygiene | `EMPTY-DIR` | empty, unregistered, unclaimed, older than an hour | `--apply` (`rmdir`) |
| hygiene | `HOLLOW` | empty, but an open session's cwd (named `id [instance]`) | archive that session first |
| hygiene | `ORPHAN-DIR` | unregistered with content | review by hand; never `rm -rf` |
| hygiene | `STALE-STASH` | older than `--stale-days` | inspect; the stack is shared, drop by hand |
| session | `ARCHIVE-REQUEST` | open, idle, every tree and written branch landed | `send_message` (below) |
| session | `ARCHIVE-DIRECT` | open, and its lane dir is gone or no longer a worktree | `archive_session` — never message it |
| session | `SPINNING?` | LIVE, and its lane dir is gone | check its CPU now ([prune.md](prune.md), landmine) |

Every session row's detail opens with `[instance]`, the Desktop instance its
session lives in (`[terminal]` for a CLI session). Its action is a tool call
only when that instance is yours; otherwise it names the window to act from.

Exit code: `0` nothing to act on (after `--apply`: every step it took
succeeded), `10` findings, `1` an `--apply` step failed, `2` usage, `5`
precondition. `KEEP`, `PARK`, `HELD`, `ON-HOLD`, `TRACKED`, `OWNER-BUSY`,
`STASH` and `FLEETFLOW-RUNS` are informational and never make it 10.

## Landed by content

Prune's "merged" is ancestry. A lane landed by squash, cherry-pick or
rebase-and-land is not an ancestor of base, so prune keeps it in REVIEW
("unmerged") forever. The sweep also runs `git merge-tree --write-tree base
lane` (git 2.38+): if merging the lane would leave base's tree unchanged, the
work is already there, and the row is `CONTENT-LANDED`. A landing that was later
reverted, or lines base has since edited again, read as unlanded or conflicting,
never as landed. A false "unlanded" costs a look; a false "landed" could cost
work. Without merge-tree, `git cherry` stands in; it catches cherry-picks and
rebases but not squashes. The same merge-tree run names the files a `REBASE`
row conflicts on.

## Competing work

Each lane contributes the files it changed that base does not have yet: its
committed diff (`base...lane`) if unlanded, plus every uncommitted or untracked
path in its tree. Two lanes sharing a file are an `OVERLAP` pair. Shared
ledgers (CHANGELOG/README/AGENTS/CLAUDE.md, `docs/PLAN.md`) and per-tree local
config (`.claude/launch.json`, `.claude/settings.local.json`) never count:
they conflict trivially or are not shared work. Override with
`FLEET_SWEEP_LEDGER`. Never-push lanes are left out, because they never land.

The pair that matters most is committed-vs-uncommitted: one lane has landed (or
will land) a fix to `x`, while another tree still holds unsaved edits to `x`.
Prune and the git-ops survey see the second tree only as "dirty".

## Sessions: requests vs direct archives

Session ids are the store's `local_<uuid>`, the same ids `ccd_session_mgmt`
takes. Those tools are Desktop MCP, agent-only, and the write tools always
prompt the user (see `~/.claude/rules/ccd-session-tools.md` on hosts that have
it). The sweep only names sessions; the agent acts, one gated call per row.

**`ARCHIVE-REQUEST`**: `send_message(session_id, …)` with this body, filled from
the row's detail:

```
Your lane is landed: <branch> is in <base> as <sha>, and your worktree is clean.
If nothing is left for you to do, please archive yourself (archive_session with
session_id "self"). If something is left, reply with what, and do not archive.
```

A request lets the session finish (save memory, report) and archive itself,
which is what "self-archive" means. A `cli:<id>` row is a terminal or headless
session with no archive API: close it, or `pigeon send <project>` to reach it.

**`ARCHIVE-DIRECT`**: call `archive_session(session_id)`, **never**
`send_message`. Its lane dir is gone (or a non-worktree dir), and a message
resumes it there. A session resumed into a missing tree spins a core
indefinitely ([prune.md](prune.md), landmine). Such a session never gets a
request, even when all its work landed.

**`VERIFY-OWNER`**: prune found no record proving the owner archived. Search
for the session that worked there (`search_session_transcripts("<slug>")`,
ungated), then `get_session`. If it is open, it is an archive request. If it is
archived, MAIN may remove the tree by hand with an OK (`git worktree remove`
still refuses a dirty tree). The live backlog is mostly lanes a session made
with `git worktree add` and `EnterWorktree`, whose claim is not in any record.

Never asked: live sessions, this session, MAIN, and archived sessions.

## Desktop instances: act from the right window

A machine can run several Desktop instances side by side: the primary one,
plus one per `--user-data-dir` profile (`~/.claude-desktop-profiles/<name>`).
Each keeps its own session store, and `sessions.sh` reads all of them
(`sessions.sh stores`). The `ccd_session_mgmt` tools do not: `archive_session`
and `send_message` reach only the sessions of the instance the calling agent
runs in. On 2026-10-06 a coordinator acted on a sweep's 9 `ARCHIVE-DIRECT` rows
from one profile. Five failed with "Session ... not found": 4 sessions lived in
the primary store and 1 in another profile.

So every session row names its instance: `[primary]`, or the profile's
directory name. The label is read off the store path at run time and never
written into a repo, since profile names are often personal.
`sessions.sh where <id>` prints a session's instance and store. The sweep finds
its own instance through `sessions.sh self`, the store holding the calling
session, and splits rows three ways:

| The session's instance is | Action in the row |
|---|---|
| this one (or the machine has one store) | the tool call, as before |
| another one | the window to use: archive it from that window's sidebar **without opening it** (opening resumes it into a dead tree), or ask it there |
| unknown: several stores, and `self` does not resolve (a terminal run, or a wrapper in two stores) | the tool call, plus the window it works from |

The next-steps line counts the rows that only another window can do. `HOLLOW`
and `ASK-ARCHIVE` rows name their sessions as `id [instance]` too.

## --apply: the zero-loss classes

After a typed `apply` (or `--yes`), and each re-verified immediately before it acts:

1. **`git worktree prune`**: admin entries whose directory is already gone.
2. **Merged branches**: worktree-less, every commit in base, not held by an open
   session, not a non-terminal fleet lane, not never-push, not matching
   `FLEET_SWEEP_KEEP` (default `main master trunk develop dev staging production
   release/* hotfix/*`). Deleted with `git update-ref -d <ref> <sha>`, a
   compare-and-swap on the sha verified a moment earlier, after re-checking it is
   still in base and checked out nowhere. Its commits stay reachable from base.
3. **Empty dirs**: unregistered, under `.claude/worktrees/` or the fleet
   worktree root, older than `FLEET_SWEEP_MIN_DIR_AGE` (default 3600s, since a
   dir may be mid-creation), and with no open claimant on a fresh
   `sessions.sh at --fresh` read. `rmdir`, which refuses a non-empty dir. With
   the session store unreadable, none qualify: no claim can be ruled out.

It never removes a worktree, drops a stash, deletes an unmerged branch, pushes,
or messages a session. `--porcelain` and `--json` are report-only.

## The never-push list

Some branches carry history that must never reach a remote: private
identifiers, client data. Name them in a **private** list, outside every repo:
`~/.claude/never-push.txt` (machine-wide) and/or `<git-common-dir>/info/never-push`
(per repo, never committed). `FLEET_NEVER_PUSH` (`;`-separated files) replaces
both; set-but-empty turns it off. One glob per line, `#` comments:

```
backup/*
lane/private-audit
```

A matching branch reads `PARK`, is never suggested for landing, is left out of
overlap, and is never deleted by `--apply`. If it has an upstream or any
remote-tracking copy, it reads `LEAKED`. Never write the list's contents into a
public repo; it would publish what it protects.

## The hold list

Some lanes are finished but must not land yet: the maintainer wants to land
one personally, or another waits on a review outside the repo. Without a hold
the sweep offered both as `LAND`. Name them in a second private list:
`~/.claude/held-lanes.txt` and/or `<git-common-dir>/info/held-lanes`.
`FLEET_HELD_LANES` (`;`-separated files) replaces both, and set-but-empty turns
it off. One `<glob> <reason>` per line, `#` comments:

```
lane/billing-rewrite    lands only with the maintainer
lane/api-v2             waits on the partner's security review
```

A matching unlanded lane reads `ON-HOLD` with its reason, in phase 1 (with a
worktree) and phase 3 (without), in place of `LAND`, `REBASE`, `UNLANDED` and
`STALE`. `ON-HOLD` is informational, so it never makes the exit 10. To lift a
hold, delete its line. A held lane that has landed anyway just reads as landed.

**Why a separate list, not a reason column on never-push.** The two mean
opposite things:

| | never-push | held |
|---|---|---|
| Lasts | for good: the history must never leave the machine | until someone approves |
| Lands? | never | yes, later |
| Overlap | left out (it never lands) | **kept**: a rival lane must know it will land |
| Remote copy | `LEAKED`: review with the owner now | expected: an outside review usually needs one |
| Rebase | n/a | **refused**: it rewrites the SHAs a reviewer is reading |

Folding holds into never-push would mark every pushed review branch `LEAKED`.
It would also drop held lanes from overlap, so a rival lane could land over
one unnoticed.

## Limits

- **Writes by absolute path are invisible**, as for prune: a session that never
  entered a tree but writes into it leaves no claim. Check your own lanes first.
- **Branch names in the session index are machine-wide.** A same-named branch
  in another repo can make a merged branch `HELD`. That errs toward keeping.
  `HELD` takes each open namer's archive flag from the same fresh read as
  phases 4 and 5, so a session archived since the index was cached (15 minutes)
  holds nothing. Only namers the cache still calls open are re-read: one the
  cache calls archived but that was unarchived since only delays a zero-loss delete.
- **The hold list is the sweep's, not the queue's.** `fleet land` does not read
  it, so a held lane still lands if someone runs `fleet land` on it by hand.
  The hold stops the sweep from suggesting it.
- **An instance is a store, not an account.** A store files wrappers per
  account (`<store>/<account>/<workspace>/`). The sweep has not been shown that
  a session filed under another account in the same store is unreachable, so
  it treats the whole store as one instance.
- **A transcript-directory claim is lossy** (`lane.x` and `lane-x` share a key).
  For prune it can only keep a tree; here it can attach a session to a
  neighbour's tree and so to a wrong archive request. The request is a polite
  question the session answers, but read the row's tree list before sending.
- **fleetflow owns `.fleetflow/`.** The sweep never scans it: a row says to run
  `ff-sweep.sh --list`, and landed fleetflow lanes go to `ff-clean.sh`, which
  archives the run to history before reclaiming anything.
- One repo per run. A machine-wide picture is `fleet prune --all-repos`
  (counts only), then `fleet sweep` inside each repo.
