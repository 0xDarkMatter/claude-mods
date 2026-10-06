# Landing Detail

The landing pipeline's fine print: the already-landed case of the merge, why the gate runs the full sweep, the landing marker and what `main` looks like while a land holds it, recovering a land that died, and `fleet revert`. The pipeline itself is in SKILL.md.

## Contents

- [Step 3, merge, in full](#step-3-merge-in-full)
- [Step 4, test gate, in full](#step-4-test-gate-in-full)
- [The landing marker](#the-landing-marker)
- [Provisional main](#provisional-main)
- [Interrupted lands](#interrupted-lands)
- [`fleet revert` in full](#fleet-revert-in-full)

## Step 3, merge, in full

3. **Merge** — `--no-ff` with message `merge: <branch>` (this message is what `fleet revert` finds later). If the branch is *already* contained in `main` — another session landed it while this one sat in the queue — `git merge` exits 0 with "Already up to date." and nothing happens. fleet detects that by comparing the tip before and after (never by parsing git's prose) and reports it as `ALREADY LANDED: <branch> — already in main, no merge performed by this run`: the lane goes `LANDED`, the gate does **not** run (there is no merge of ours to gate), the lane branch is left for whoever did land it, and `land --all` counts it as `already in <base>`, apart from real lands

## Step 4, test gate, in full

When landing into a repo with per-skill or per-package behavioural suites, `test_cmd` should run the **full sweep**: every suite, not just the touched lane's files. Suites routinely assert on shared or sibling files (a skill's own suite can require a frontmatter field a sibling trim pass doesn't know about), so scoping `test_cmd` to "just what this lane touched" reintroduces exactly the blind spot a test gate exists to close.

## The landing marker

Every land holds `.claude/fleet/landing`: `fleet land`, each lane of `fleet land --all`, and the daemon's. It is one line, `pid TAB start TAB base-tip TAB branch`, built only by `claim_landing` in `scripts/fleet.sh`, where the format is documented field by field.

- **Taken** just before the merge, after recovery has examined any marker a dead land left (below).
- **Released only once the land reached a verdict**: after the rebase pass on a green gate, straight away on a red one, a refusal or a merge conflict. Never from an exit trap or signal handler, because an exit mid-land is exactly when it is evidence.
- **A lock.** It is created exclusively (noclobber), so of two lands racing for it exactly one wins. The other refuses and names the holder (`another land is in progress: pid N on <lane>, started 4m ago`); the daemon, finding it taken, waits for its next pass.
- **Deleted through `remove_state_file`**, never a bare `rm -f`: a briefly-held file (antivirus, the indexer) fails a single delete with EBUSY on Windows.

`fleet stop` reads it too: a daemon that holds it is mid-land, so `fleet stop` waits instead of escalating to SIGKILL ([daemon.md](daemon.md)).

## Provisional main

`fleet land` merges first and gates second. For the whole gate, which is 20-45 minutes on a large suite, `main`'s tip is a `merge: <lane>` commit that a red gate hard-resets. On 2026-10-06 two peer sessions saw such a tip and read it as landed: one branched from it, the other rebased onto it and started a second gate beside the first. The second gate's load is what makes timing-sensitive suites flaky, and a red first gate would have reset `main` under the rebase. Nothing on disk said "provisional" then: only the daemon wrote a marker, and `fleet status` said nothing about `main`.

Now one reader, `landing_status`, answers "may I act on `main`'s tip?" for `fleet status` (its top line), `fleet landing` and `fleet sweep`. It only reads, so polling it can never disturb a land.

| State | When | `fleet status` top line | `fleet landing` |
|---|---|---|---|
| `CLEAR` | no marker, nothing untested | none | 0 |
| `LANDING` | a live land, nothing of it merged yet | `land of <lane> in progress since HH:MM (pid N); main <sha> is about to move` | 10 |
| `PROVISIONAL` | a live land merged; its gate has not ruled | `main <sha> is PROVISIONAL - gate for <lane> running since HH:MM (pid N); red resets to <base>` | 10 |
| `SETTLING` | gate green, the rebase pass is moving the other lanes | `main <sha> landed <lane> (gate green); its rebase pass is still running` | 10 |
| `UNTESTED` | a land died between merge and verdict | `main <sha> holds an UNTESTED merge of <lane>` | 10 |
| `STALE` | a land died and left nothing untested | dim note; the next land clears the marker | 0 |

**The rule for every other session: before branching from or rebasing onto `main`, run `fleet status`. A PROVISIONAL tip is not landed.** In a script, `fleet landing` exits 0 when it is safe and 10 when to wait. The lane brief ([session-prompt.md](session-prompt.md)) and the handoff `signal.sh` prints both say so. A repo's deployed `.claude/fleet/signal.sh` is never overwritten (it may be customised), so a repo initialised before this keeps the old handoff text until that copy is deleted; the next fleet command redeploys it.

`fleet landing --porcelain` prints one TSV row, `state, tip, base, lane, pid, start, verdict line`, with `-` for an empty field. `fleet sweep` reads that row rather than parsing the marker itself. While the state is not 0-exit, its first row is a `landing` row (`PROVISIONAL` or `UNTESTED-MERGE`), every other row's action reads `wait: main is not settled`, the next steps say only WAIT, and `--apply` refuses with exit 5. It refuses again after the confirmation prompt, which can sit for as long as a land takes to start. The guard matters because the lane being landed reads as merged, and sweep would otherwise route its worktree to removal.

## Interrupted lands

A marker whose process is gone means a land was cut short: kill -9, a crash, OOM, a torn-down process tree, Ctrl-C, or an agent's Bash tool timing out a slow `fleet land`. Before any land starts (`fleet land`, each daemon pass, `land --all`, `fleet start`), fleet examines what it left:

| Found | What fleet does |
|---|---|
| Base tip unchanged since the land began | Nothing merged. Clears the marker; the lane lands normally |
| A `merge: <lane>` since then, lane not `LANDED`/`FAILED` | **`UNTESTED MERGE`** warning; the lane goes `CONFLICT` |
| Another lane's worktree stuck mid-rebase onto the base | Warning with the `rebase --abort` command; that lane goes `CONFLICT`. The rebase is left for its owner |
| The main checkout mid-merge or mid-rebase | Refuses to land and prints the abort command. The marker stays until that is done |

Before this, the next land took the "already up to date" path and marked an untested merge `LANDED`. The `fleet land` call that prints the warning refuses that lane, so it cannot bless what it just flagged. To settle an `UNTESTED MERGE`, run `test_cmd` on the base branch yourself. If it passes, `fleet land <lane>` marks the lane `LANDED` and rebases the rest. If it fails, run `fleet revert <lane>`. Until one of those, `fleet status` keeps reporting the untested merge and `fleet landing` exits 10.

"Process gone" means no running process whose command line mentions fleet, not merely a dead PID: Windows reuses PIDs fast, and a reused one must not make a dead land look live. Git Bash's `/proc` lists every MSYS process on the machine, other sessions' included, so a peer's `fleet status` sees MAIN's land as live.

## `fleet revert` in full

`fleet revert <branch>` finds the merge commit on `main` whose subject is **exactly** `merge: <branch>` and runs `git revert -m 1` — one command to back out a bad landing. The match is exact, never `git log --grep`: `--grep` is a regex applied as a *substring*, so `merge: lane/auth` also matched `merge: lane/auth-refactor` and reverting one lane destroyed the other's work while reporting the branch you asked for (fixed 2026-09-08). If the branch landed more than once, the most recent merge is reverted and the others are logged rather than silently passed over. A revert that conflicts is **aborted**, leaving `main` and the working tree exactly as they were — no stranded sequencer for the next `fleet land` to misreport as "uncommitted tracked changes". A reverted lane goes back to `RUNNING` with a note: it is no longer in `main`, so leaving it `LANDED` would be a status panel that lies about where the work lives.
