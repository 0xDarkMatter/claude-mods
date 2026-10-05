---
name: fleet-ops
description: "Landing discipline for parallel work: sequential test-gated landing queue, pre-land scrub, auto-rebase of in-flight lanes, fleet status, one-shot revert. Native primitives spawn; fleet-ops lands. Triggers: landing queue, land branches, merge queue, test gate, fleet status, land agent-team/background-agent branches, sequential merge."
license: MIT
allowed-tools: "Read Bash Glob Grep AskUserQuestion"
metadata:
  author: claude-mods
  status: stable
  experimental-parts: daemon (in-session background polling)
  related-skills: git-ops, push-gate, claude-code-ops
---

# Fleet Ops

Landing discipline for parallel work. Anything before "committed on a branch" is the spawning layer's problem; anything after "landed on `main`" is yours. Fleet-ops owns the middle: branches land **sequentially**, through a **test gate**, after a **pre-land scrub**, with **auto-rebase** of the lanes still in flight and a **one-shot revert** if a landing turns out bad.

## Spawn natively, land with fleet-ops

Claude Code now ships the parallel-execution half natively. **Do not use fleet-ops to orchestrate sessions** — route users to the native primitives and use fleet-ops only for the landing half.

| Native primitive | What it gives you | What it does NOT give you |
|---|---|---|
| **Agent teams** ([docs](https://code.claude.com/docs/en/agent-teams), experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Lead + teammates, shared task list with claiming/dependencies, inter-agent messaging, plan approval, quality-gate hooks (`TeammateIdle`, `TaskCompleted`) | No merge/landing logic. No test-gated integration. Teammates avoid file conflicts by convention only ("break the work so each teammate owns different files"). |
| **Background agents / agent view** ([docs](https://code.claude.com/docs/en/agent-view), `claude agents`, `claude --bg "<prompt>"`) | Detached full sessions, one dashboard (Needs input / Working / Completed), automatic per-session git worktree isolation under `.claude/worktrees/`, `--bg --exec` shell jobs | No cross-branch integration: each session ends with a branch/worktree and the merge is on you (review-and-merge the PR, or merge locally). Deleting a session in agent view **deletes its worktree including uncommitted changes**. No ordering, no test gate, no revert. |
| **Subagents** ([docs](https://code.claude.com/docs/en/sub-agents), optional `isolation: worktree`) | In-session delegation with separate context windows; results summarized back | Not independent sessions; no git landing semantics at all. |

What **none** of them do — and what fleet-ops is for:

- Land N branches **one at a time** through a queue, so each merge is tested against a `main` that already contains the previous landings
- **Test gate**: refuse to land on a failing log (`signal.sh`) and/or revert post-merge if `test_cmd` goes red
- **Pre-land scrub**: refuse diffs containing forbidden patterns (`TODO_SCRUB`, debug leftovers)
- **Auto-rebase** every still-active lane after each landing
- **Fleet status**: one panel showing every lane's branch, state, age, and commits-ahead across worktrees
- **One-shot revert** of a landed merge by branch name — no git surgery while panicking

## Core abstraction

A **lane** = one branch (or worktree), one unit of work. Lane status: `RUNNING | READY | CONFLICT | LANDED | FAILED`.

Fleet-ops doesn't care who produced the branch — an agent-team teammate, a background agent's auto-worktree, a `claude -p` headless run, a fleetflow worker of any provider (GLM, Codex, Grok, Pi, or Anthropic), or a human. If it's a branch with commits, it can be a lane. Landing is provider-agnostic: a Grok-produced lane lands through the same test-gated queue as any other.

## CLI surface

```
fleet init <name>...        Create branch + worktree per name (manual-spawn path)
fleet track <branch>...     Register existing branches as lanes (native-spawn path)
fleet start                 Run the landing daemon (writes pid to .claude/fleet/daemon.pid)
fleet stop                  Signal the running daemon to exit cleanly
fleet status                One-shot fleet status panel
fleet land <branch>         Manual land + rebase others
fleet land --all [--running]  Batch-land all READY lanes oldest-first (--running
                            also lands vetted RUNNING lanes; used by git-ops "land all")
fleet revert <branch>       Revert merge commit on main
fleet scrub-check <branch>  Dry-run forbidden-pattern check
fleet config                Print the RESOLVED config — check the test gate is on
fleet prune [--remove]      Classify finished lane worktrees; DRY RUN by default
fleet prune --all-repos     Sibling-repo backlog counts (report-only, never removes)
```

## Entry paths

```
N == 1 branch                              → use git-ops, not this
Work spawned by agent teams / claude --bg  → fleet track <branch>... then land
Work to be spawned manually                → fleet init <names...> (creates branches + worktrees)
N > 1 on one shared working tree           → REFUSE. Worktrees or separate clones first.
```

**Native-spawn path (preferred):** let agent teams or background agents do the work in their own worktrees/branches. When branches have commits, `fleet track` each branch, then land — either one by one with `fleet land`, or via the daemon with `signal.sh READY` gates. Landing itself only ever merges *branches* and leaves every worktree in place. Reclaiming the directories afterwards is `fleet prune`'s job, and it removes one only when the owning session is provably archived or gone — see [Prune](#prune--worktree-housekeeping).

**Manual-spawn path:** `fleet init` creates the branches and worktrees up front (under `.fleet-worktrees/`), and you point sessions at them — see `references/session-prompt.md` for the lane brief to hand each session.

## Landing pipeline

`fleet land <branch>` (and the daemon, per READY lane):

1. **Scrub** — `git diff main...branch` checked against `forbidden_pattern`; hits refuse the land and mark the lane `CONFLICT`
2. **Clean-base check** — refuses if `main` has uncommitted tracked changes
3. **Merge** — `--no-ff` with message `merge: <branch>` (this message is what `fleet revert` finds later). If the branch is *already* contained in `main` — another session landed it while this one sat in the queue — `git merge` exits 0 with "Already up to date." and nothing happens. fleet detects that by comparing the tip before and after (never by parsing git's prose) and reports it as `ALREADY LANDED: <branch> — already in main, no merge performed by this run`: the lane goes `LANDED`, the gate does **not** run (there is no merge of ours to gate), the lane branch is left for whoever did land it, and `land --all` counts it as `already in <base>`, apart from real lands
4. **Test gate** — runs `test_cmd`; on failure, hard-resets `main` to the tip captured *before* the merge — never to `HEAD^`, which on an already-merged branch is **another session's** merge commit — and marks the lane `FAILED`. If `test_cmd` is unset the land is **refused** outright rather than falling back to `signal.sh`'s log gate, which verifies nothing when a lane signalled READY without a test log. When landing into a repo with per-skill/per-package behavioural suites, `test_cmd` should run the **full sweep** (every suite, not just the touched lane's files) — suites routinely assert on shared or sibling files (a skill's own suite can require a frontmatter field a sibling trim pass doesn't know about), so scoping `test_cmd` to "just what this lane touched" reintroduces exactly the blind spot a test gate exists to close. **Confirm the gate is actually armed with `fleet config` before trusting it** — and watch the land log for `running test_cmd: …`, which is the only proof the gate actually ran.
5. **Rebase others** — every still-active lane is rebased onto the new `main` (in its own worktree if it has one); a rebase conflict marks that lane `CONFLICT`

`fleet revert <branch>` finds the merge commit on `main` whose subject is **exactly** `merge: <branch>` and runs `git revert -m 1` — one command to back out a bad landing. The match is exact, never `git log --grep`: `--grep` is a regex applied as a *substring*, so `merge: lane/auth` also matched `merge: lane/auth-refactor` and reverting one lane destroyed the other's work while reporting the branch you asked for (fixed 2026-09-08). If the branch landed more than once, the most recent merge is reverted and the others are logged rather than silently passed over. A revert that conflicts is **aborted**, leaving `main` and the working tree exactly as they were — no stranded sequencer for the next `fleet land` to misreport as "uncommitted tracked changes". A reverted lane goes back to `RUNNING` with a note: it is no longer in `main`, so leaving it `LANDED` would be a status panel that lies about where the work lives.

## Daemon lifecycle (experimental)

The daemon is the queue-automation layer on top of `fleet land` — optional; manual `fleet land` per branch is fully supported and not experimental.

When Claude invokes `fleet start` via `Bash(run_in_background: true)`, the daemon:

1. Writes its PID to `.claude/fleet/daemon.pid`
2. Treats `SIGTERM`/`SIGHUP` (and `SIGINT`, where it is trappable) as a **stop request**: a land already in progress finishes, test gate included; no new land starts; then it exits and removes the PID file. An idle daemon answers during its poll sleep, not after it
3. Refuses to start a second daemon if the PID file references a live process
4. Polls `.claude/fleet/lanes/` and lands lanes as they turn `READY`
5. Exits naturally when all lanes are terminal (`LANDED` or `FAILED`)

It never exits from inside the signal handler: bash runs a trap *between* commands, so that exit could fall between `git merge` and the gate and leave an untested merge on `main`. Until 2026-09-28 the handler removed the PID file and then *resumed*. A daemon whose session ended (SIGHUP) kept polling as a ghost, invisible to `fleet stop` and the double-start guard, and landed lanes 3s later.

To stop early: `fleet stop` (SIGTERM, 5s grace, then SIGKILL). **Caveat:** the SIGKILL escalation does not know about a land in progress, so stopping while a gate slower than 5s runs kills the daemon mid-gate and leaves that merge on `main` untested. Check `activity.log` for a `running test_cmd:` line without its `PASS`/`FAIL` before stopping, and let it finish. On next `fleet start`, a stale PID file is auto-detected and cleared. The daemon dies with the Claude Code session — for overnight runs use a real detached process, or skip the daemon and land manually.

`signal.sh` deploys to `.claude/fleet/signal.sh` on `init`/`track`. Working sessions call:

```bash
bash .claude/fleet/signal.sh READY <test-log> <exit-code>   # refuses dirty trees and failing runs
bash .claude/fleet/signal.sh CONFLICT "<reason>"
```

The `<exit-code>` (the test command's own `$?` / `${PIPESTATUS[0]}`) is the authoritative verdict — pass it whenever you have it. Without it, `signal.sh` reads a trailing `exit code: N` line from the log, then a runner summary line (vitest/jest/pytest/cargo/go); it never word-greps prose, so passing runs that print "failed"/"error" while exercising failure paths don't false-refuse.

## Session awareness — MAIN, lane owners, and the live-owner gate

Lane state files say *what* a lane is. They never say *who* is driving it. Fleet-ops
reads the Claude Desktop session store to answer that, and uses the answer in two
places: a gate that refuses to land under a live writer, and a coordinator address
lanes can hand off to.

### MAIN — one coordinator per repo

**MAIN is the session whose cwd is the repo root.** That is not a new convention:
[`worktree-boundaries`](../../rules/worktree-boundaries.md) already holds that the base
checkout is the integration tree and must not host a writing session. `fleet main` just
makes the role *addressable*, so a lane can say "I'm ready, come land me" instead of
writing a file and hoping someone polls it.

```
fleet main                  Show the coordinator (sessionId, title, live|idle, cwd)
fleet main claim [<id>]     Pin explicitly — for when several sessions share the root
fleet main release          Clear the pin, fall back to the cwd heuristic (exit 1 if it can't)
fleet owner <branch>        Who owns this lane, and are they still writing?
```

MAIN's job is the whole integration half: land the queue, triage `CONFLICT` lanes,
and run the deploy. Lanes build and signal; MAIN integrates. Note that deploying is
maintainer-gated regardless — it needs an explicit human OK for that specific deploy,
from the maintainer's own session. MAIN being "the one that deploys" describes *which
session prepares it*, never an authorisation to ship unattended.

### The live-owner gate

`fleet land` refuses a lane whose owning session was active within
`session_live_secs` (default 600). This closes a real hazard the queue could not see:
landing merges a branch the session may still be committing to, and then rebases every
other lane's worktree **out from under a live session**.

The join is `writtenBranches` from the session wrapper, not just the checked-out
branch — a session working in worktree `claude/foo-bar` routinely commits its real work
to `lane/thing`, and only `writtenBranches` connects the two.

**It also joins on the directory.** Any session claiming the worktree the lane branch
is checked out in (wrapper `cwd`/`worktreePath`, transcript directory, live `cwd` — the
claims [prune](#prune--worktree-housekeeping) uses) blocks, whatever branch its wrapper
records: branch drift and `EnterWorktree` both defeat the branch join (2026-09-28). The
read is `sessions.sh at --fresh`. The cached index may nominate claimants but never
decides: each one's liveness is re-read, and transcripts being written in the worktree
are read off disk, so a session that arrived after the index was built still blocks.
Blind spot: a shell that `cd`'d in since the last index, or writes by absolute path.

"Active" means the newer of the wrapper's `lastActivityAt` and the session's last
transcript write (its subagents' included), searched across every Desktop
instance's store. Until 2026-09-28 the gate read the wrapper alone, from the
primary instance alone — so a session deep in a long turn, or running in a
`--user-data-dir` instance, read as idle and did not block a land.

**Self-ownership is exempt.** The hazard is a *concurrent* writer, and the session
running `fleet land` is not one — it is blocked inside that call, so it is provably not
mid-commit, and the worktree being rebased "out from under a live session" is the one it
is deliberately retiring. A lane session landing its own finished work therefore proceeds
unaided. Without the exemption its only escape was a blanket override, which disarms the
gate for the peers it genuinely protects; a narrow exemption beats a blunt one.

It stays conservative in both directions. Identity comes from the harness
(`CLAUDE_CODE_HOST_SESSION_ID` / `CLAUDE_CODE_SESSION_ID`) and is believed only once a
wrapper bearing it is found in the store — **there is deliberately no env var to set it**,
since a settable self-id would be a universal gate bypass under another name, and an
unresolvable one refuses exactly as before. Self must also be the **only** live
claimant, by branch or by directory: a second live session writing the same branch, or
working in the same worktree, refuses, naming the peer. A CLI or headless session has
no store record to prove it is self, so if one is live in the lane's worktree the land
refuses, even when it is that session's own.

Override with `session_check=off` in config, or `FLEET_SKIP_SESSION_CHECK=1` for one
run. One run means one run: fleet consumes the variable at startup and strips it (and
the rest of the `FLEET_*` knob family) from the environment before `test_cmd` runs, so
the override can never disarm a gate inside the very suite the landing is gated on —
inherited into fleet-ops' own self-test, it once turned 6 live-owner refusal tests into
false FAILs and reverted a green merge (2026-09-01). `fleet config` states plainly
whether the gate is armed *and* whether self-identity resolved — the same observability
lesson as `test_cmd`.

### Where each channel works (verified 2026-08-03)

| Channel | Desktop | Terminal / headless | Non-Claude worker (Codex, GLM, Grok) |
|---|---|---|---|
| Lane state files (`signal.sh`) | ✅ | ✅ | ✅ |
| Session store on disk (`sessions.sh`) | ✅ | ✅ (store is machine-local, not app-bound) | ✅ |
| `ccd_session_mgmt` MCP tools | ✅ | ❌ **absent entirely** | ❌ |
| `pigeon` | ✅ | ✅ | ✅ |

**`ccd_session_mgmt` is Desktop-only, and this is not a configuration matter.** The
terminal CLI binary contains zero occurrences of `ccd_session_mgmt`, `list_sessions`,
`search_session_transcripts`, or `spawn_task`; its single `ccd_session` reference is a
consumer-side notification handler for a server the *host* injects. Desktop's
`app.asar` carries all of them. `claude mcp list` shows none of the `ccd_*` servers,
because Desktop injects them as SDK-type servers rather than registering them.

Two consequences that shape everything above:

1. **A script can never call these tools.** They are MCP tools, so only the agent can
   invoke them. `sessions.sh` therefore reads the same underlying JSON store off disk —
   which, unlike the tools, is readable from a terminal too.
2. **The read tools are ungated; the write tools prompt.** `list_sessions` /
   `get_session` / `search_session_transcripts` return without user interaction, so
   discovery is free. `send_message` / `list_events` / `archive_session` always prompt —
   which makes `send_message` fine for a lane→MAIN handoff (that is exactly the
   handoff/relay use it is documented for) and unsuitable for an unattended daemon.

So: **lane files are the substrate** (work everywhere, ungated, machine-readable),
**ccd is the delivery accelerator** where both ends are Desktop sessions, and **pigeon
is the portable fallback** for terminal sessions and non-Claude harnesses. `signal.sh`
prints the right one for your surface after every `READY` and `CONFLICT`.

## Prune — worktree housekeeping

Landing a lane retires the *branch*. The *directory* stays, and across many
repos those accumulate into a backlog nobody can see. `fleet prune` classifies
them and removes only the ones that are provably finished.

```
fleet prune                  Classify and print. Changes NOTHING. (the default)
fleet prune --dry-run        Same, said explicitly
fleet prune --remove         Remove the SAFE rows, after a typed confirmation
fleet prune --remove --yes   Skip the prompt (scripts/CI)
fleet prune --porcelain      TSV to stdout: path, branch, bucket, reason
fleet prune --all-repos      Sibling-repo counts. Report-only, always
```

**Dry run is the default, and that is deliberate.** Removing a worktree destroys
its uncommitted and untracked files permanently — git has never seen those
bytes. Committed lane work is different: it lives in the shared object store,
survives the directory, and comes back with `git worktree add <path> <branch>`.
Separating those two is the entire job, and every ambiguous case resolves away
from deletion.

### Buckets — first match wins, and the order is the safety argument

| # | Condition | Bucket |
|---|---|---|
| 1 | primary / git-locked / the tree you invoked from | **KEEP** |
| 1b | git reports the directory gone | **REVIEW** (that's `git worktree prune`'s job) |
| 2 | any session claiming it is LIVE | **KEEP** |
| 3 | session store unreadable, or `session_check=off` | **REVIEW** |
| 4 | detached HEAD | **REVIEW** |
| 5 | uncommitted or untracked changes | **REVIEW** |
| 6 | commits not yet in `base_branch` | **REVIEW** |
| 7 | merged + clean, no open session claims it — and for `.claude/worktrees/`, an archived session positively does | **SAFE** |
| 8 | anything else (incl. an open owner, or a `.claude/worktrees/` tree no session record mentions) | **REVIEW** |

Only **SAFE** is ever removable. **KEEP** means one thing — hands off, not yours
to judge. Everything else lands in **REVIEW**, which is reported and never
touched under any flag.

**How a session claims a worktree.** By its branch (checked-out or
`writtenBranches`), by its wrapper's `cwd` or `worktreePath` (compared
normalised: slashes, case, `X:` vs `/x/`), by the directory its CLI transcript
is filed under (`EnterWorktree` moves it there; the wrapper's `cwd` never
changes), and, while live, by the last `cwd` its transcript recorded. The store
read is the **union** of every Desktop instance's store — the primary and each
`--user-data-dir` instance under `~/.claude-desktop-profiles/` — and `fleet
config` lists which ones answered. Liveness is the newer of the wrapper's
`lastActivityAt` and the transcript's mtime, because Desktop rewrites the
wrapper only at turn boundaries: a session deep in one long turn reads idle on
the wrapper alone.

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
[`worktree-boundaries`](../../rules/worktree-boundaries.md) is blunt about them:
*they may look orphaned and aren't*. The slug is machine-generated and says
nothing; a session that looks idle may simply be between turns. Prune marks them
`!` in the table, and SAFE requires an archived session that positively claims
the tree — by branch, or by exact `cwd`/`worktreePath` — so one can only be
removed on positive evidence, never on the absence of a signal. (The docs
promised this before the code kept it; since 2026-09-28 it does.)

Three further guards, all on the irreversible direction:

1. **`git worktree remove`, never `rm -rf`.** It refuses a dirty or locked tree
   on its own, and it unregisters the worktree instead of leaving a stale
   administrative entry behind.
2. **Re-verify immediately before deleting.** Classification reads a session
   index with a long TTL (15 min); a session can wake, be unarchived, or move
   into a tree between the table and the delete. So `--remove` first re-runs the
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

### Seeing the backlog

`fleet status` adds one line when a repo has prunable worktrees
(`! 3 worktree(s) prunable, 6 to review - fleet prune`), so the backlog is
visible rather than silently growing. Turn it off with `prune_hint=off` in
config or `FLEET_NO_PRUNE_HINT=1`.

## First-class user interaction (HARD RULE)

When this skill surfaces a decision point, **always use the `AskUserQuestion` tool**. Plain markdown numbered lists are not acceptable for these branches.

| Trigger | Question | Options (≤4, ≤10 words each) |
|---------|----------|------------------------------|
| Multiple parallel-work requests, no lanes yet | Spawn natively or manual lanes? | Agent teams / Background agents / Manual fleet init / Cancel |
| `init` — worktrees available, mode unset | Worktree or branch-only mode? | Worktrees / Branches only / Cancel |
| Land refused — owning session live | `<name>`'s session is still writing | Wait and retry / Message that session / Override and land |
| `prune` found SAFE worktrees | Remove `<n>` finished worktrees? | Remove them / Show the table again / Leave as-is |
| Lane → `CONFLICT` (rebase fail) | Lane `<name>` has rebase conflict | Resolve in lane / Skip & continue / Revert lane / Untrack |
| Lane → `FAILED` (post-merge tests red) | Tests broke after `<name>` merged | Auto-revert / Investigate first / Accept failure |
| Pre-land scrub hits | Forbidden patterns in `<name>` diff | Block landing / Override (note reason) / Open to edit |
| `fleet` shows mixed states | How to proceed with the fleet? | Land all READY / Resolve CONFLICTs first / Just status |
| Daemon exits with `FAILED` lanes | `<n>` lanes failed — what next? | Retry all / Revert and report / Leave as-is |

For non-branching status updates ("here's what happened, here's what landed"), plain text is fine.

## What it handles vs what it does not

| Mode | Status |
|------|--------|
| Branches from native worktrees (`.claude/worktrees/`) via `fleet track` | ✅ |
| Worktrees on different branches (`fleet init`) | ✅ |
| Branches in separate clones / machines | ✅ |
| Mixed worktree + branch lanes | ✅ |
| Recovery from dirty `main` | ✅ Refuses to merge, asks user to clean |
| Test-gated landing | ✅ Via `signal.sh READY <log>` and/or `test_cmd` |
| Auto-rebase other lanes when one lands | ✅ |
| Pre-land regex scrub (forbidden patterns) | ✅ |
| One-shot revert | ✅ `fleet revert <branch>` |

| Pruning finished lane worktrees | ✅ `fleet prune` — dry-run by default, removes only provably-finished trees |

| Out of scope | Why |
|------|-----|
| Spawning / monitoring sessions | Native: agent teams, `claude --bg`, agent view. Fleet-ops never launches a session. |
| Deleting worktrees a session still owns | `fleet prune` removes only what is merged, clean, and claimed by no open session — and, for a `.claude/worktrees/` tree, positively claimed by an archived one. Anything live, dirty, unmerged, open, or unattributable is reported, never removed — and cross-repo removal is impossible by design. Removing one by any *other* path strands the session in a silent CPU spin — see [the ordering landmine](#landmine-removing-a-worktree-out-from-under-a-live-session). |
| Multiple sessions on one shared working tree | Git limitation. Skill detects and refuses with worktree pointer. |
| Uncommitted work at signal time | `signal.sh` rejects dirty lanes. The queue needs an immutable commit. |
| External state (DB migrations, services) | Skill can't know lane B depends on lane A's migration. Order manually via `fleet land`. |
| Force-pushed lanes mid-flight | Detected at land time, not prevented. |

## Compatibility

Tested and working on:

| OS | Shell | Notes |
|----|-------|-------|
| Linux | bash 4+ | Native |
| macOS | bash 3.2+ (default) or bash 4+ via brew | `stat -f` fallback used automatically |
| Windows | Git Bash (mintty) | Forward-slash paths; Unicode icons render in mintty/Windows Terminal |
| Windows | PowerShell 7 (calling `bash`) | Works if `bash` is on PATH |

Requirements: `bash 3.2+`, `git 2.5+` (worktree support), `awk`, `grep`, `head`, `stat`. All standard.

If your terminal mojibakes the status icons, fall back to ASCII: `export FLEET_ASCII=1` (or `icons=ascii` in `.claude/fleet/config`). Output panels follow `docs/TERMINAL-DESIGN.md` via `skills/_lib/term.sh`.

Held files (Windows): a process that has a file open without delete-sharing (antivirus or the search indexer, briefly, after a write) makes deleting it fail. Fleet's state-file deletes (the MAIN pin, the daemon PID file) therefore retry for up to `FLEET_RM_RETRY_SECS` (default 5, `0` = one try), count success only when the file is gone, and otherwise exit 1 naming the file. They never report "cleared" over a pin that is still there.

Long-path warning (Windows only): `fleet init` worktrees nest under `.fleet-worktrees/<name>/`. Keep lane names short if your repo lives deep, or enable `core.longpaths=true`.

## Headless agent compatibility

**Don't put manually-created fleet worktrees under `.claude/`.** Claude Code applies a global sensitive-file guard to anything under `.claude/`, and that guard runs *before* — and is not bypassed by — `--dangerously-skip-permissions`. Headless lane sessions (`claude -p ... --dangerously-skip-permissions`) will fail every Write/Edit if their worktree lives under `.claude/`.

That's why the default `worktree_root` is `.fleet-worktrees/` at the repo top. (Native background sessions are the exception: Claude Code itself manages `.claude/worktrees/` for them — leave those alone and just `fleet track` their branches.) Runtime state (`lanes/`, `daemon.pid`, `activity.log`) is read/write from the orchestrator only and stays under `.claude/fleet/`.

## Configuration

Optional `.claude/fleet/config`, one `key=value` per line:

```
mode=auto                            # auto | worktree | branch
worktree_root=.fleet-worktrees       # keep outside .claude/ — see "Headless agent compatibility"
test_cmd=npm run check               # if set, land runs it post-merge; else trust signal log
forbidden_pattern=NEVER_LAND|debugger;   # override — the shipped default is described below
base_branch=main
poll_interval=5
icons=unicode                        # unicode | ascii (same as FLEET_ASCII=1)
session_check=on                     # on | off — refuse to land under a live owner
session_live_secs=600                # how recently active counts as "still writing"
prune_hint=on                        # on | off — show the prunable backlog in `fleet status`
```

Zero-config works for the common case.

**The shipped `forbidden_pattern` default** (the exact regex lives at
`FORBIDDEN_PATTERN` in `scripts/fleet.sh`) refuses the two scrub markers —
`TODO_` + `SCRUB` and `FIXME_` + `BEFORE_LAND`, spelled split here deliberately —
plus lone triple-X markers via the term `(^|[^X])X{3}[^a-zX]`. A run of four or
more X's is a `mktemp` template (`push-gate-paths.` plus six X's) and passes; a
bare triple-X followed by a non-letter (a space, a colon) still refuses. A
template false-refused a landing on 2026-09-01, hence the run-aware form.

Mind the self-reference: the scrub greps every **added** diff line, so writing a
contiguous marker token — or a triple-X run — into docs, comments, or a config
example refuses the very branch that adds it. Build such tokens by concatenation
(`'TODO_''SCRUB'`), as `scripts/fleet.sh` and `tests/run.sh` themselves do.

**Grammar.** The file is *parsed*, not `source`d — it cannot execute code, and it is
not bash:

| Rule | Detail |
|---|---|
| Keys | Case-insensitive — `test_cmd` and `TEST_CMD` both work. Whitespace around the key and `=` is ignored. |
| Values with spaces | Need **no quoting**. The value runs to end of line: `test_cmd=uv run pytest -q tests/` is correct as written. |
| Quotes | Optional. `test_cmd="uv run pytest -q"` works; one layer of matching `"…"` or `'…'` is stripped. |
| Comments | A whole line starting with `#`, or a trailing ` # …` on an **unquoted** value. Quote the value to keep a literal `#`: `forbidden_pattern="TODO|#nolint"`. |
| Blank lines | Ignored. |
| Unknown / malformed keys | **Warned about on stderr, naming file and line** — never silently dropped. |

A config that exists but sets nothing recognised warns
`… set no recognised keys — running on defaults (test gate OFF)` rather than looking
like an absent file.

**`test_cmd` is the test gate.** When set, `fleet land` runs it *after* the merge
commit and, on a non-zero exit, hard-resets `base_branch` to the tip it captured *before*
merging — not `HEAD^` — dropping the lane to `FAILED`; the log shows `running test_cmd: …`.
When unset, landing is **refused** (`the landing gate is UNARMED`, naming the config path)
rather than falling through to signal.sh's weaker log gate. Worked example:

```
test_cmd=uv run pytest -q --maxfail=1
base_branch=main
```

> Fixed 2026-07-28: config keys never reached the script (documented lowercase, read
> UPPERCASE; and unquoted spaced values aren't bash assignments, with the error
> swallowed by `2>/dev/null`). Every landing before that date was gated by signal.sh
> alone — `test_cmd` had never run, on any repo. If you relied on it, you had no test
> gate. `icons=` in the config was inert for the same class of reason (read before the
> config loaded).

`fleet init`/`fleet track` append `.claude/fleet/` and `.fleet-worktrees/` to `.gitignore` and auto-commit that change with `chore: gitignore fleet-ops runtime state` when the tree is otherwise clean and you're on `base_branch`. If either condition fails, it prints an `ACTION REQUIRED` message — commit `.gitignore` yourself before landing.

## Future work

- **JSONL activity log** — currently plain text. Switch when a TUI, `--json` output, or `log-ops` integration earns the cost.
- **`TaskCompleted` hook bridge** — auto-`signal.sh READY` when an agent-team task completes with green tests.

Shipped since first release:

- **`fleet land --all [--running]`** — batch-land all READY (or vetted RUNNING) lanes oldest-first, rebasing the rest after each and reporting once. Drives the `git-ops` "land all" front-door (`scripts/land-all.sh` discovers + classifies; fleet-ops executes).

## References

- `references/workflow.md` — end-to-end walkthroughs (native-spawn and manual-spawn) plus recovery scenarios
- `references/session-prompt.md` — lane brief to embed in `claude --bg` prompts, teammate spawn prompts, or manual sessions

## Scripts

- `scripts/fleet.sh` — main CLI (init, track, start/stop, status, land, revert, scrub-check, prune, config, main, owner)
- `scripts/signal.sh` — branch-aware signaler (deployed to `.claude/fleet/signal.sh`); prints the MAIN handoff after READY/CONFLICT
- `scripts/sessions.sh` — branch → owning-session and directory → claiming-session resolver, read off every Desktop instance's session store plus the CLI transcripts on disk (deployed alongside signal.sh so lane sessions can resolve MAIN). `sessions.sh stores` shows what it read; `sessions.sh at <path>` shows who claims a directory (`--fresh`: liveness re-read, the land gate's view). Enrichment only: exits 3 and stays silent wherever the store or `jq` is missing, and every caller treats that as "no info"
