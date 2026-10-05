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

Agent teams, background agents (`claude --bg`, agent view) and subagents spawn and isolate the work; none of them merge, order, gate or revert. Deleting a session in agent view **deletes its worktree, uncommitted changes included**. Gives vs lacks: [references/native-spawn.md](references/native-spawn.md).

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
3. **Merge** — `--no-ff` with message `merge: <branch>` (what `fleet revert` finds later). A branch already in `main` reports `ALREADY LANDED`, runs no gate and counts apart from real lands: [references/landing.md](references/landing.md)
4. **Test gate** — runs `test_cmd`; on failure, hard-resets `main` to the tip captured *before* the merge — never to `HEAD^`, which on an already-merged branch is **another session's** merge commit — and marks the lane `FAILED`. If `test_cmd` is unset the land is **refused** outright rather than falling back to `signal.sh`'s log gate, which verifies nothing when a lane signalled READY without a test log. When landing into a repo with per-skill/per-package behavioural suites, `test_cmd` should run the **full sweep** (every suite, not just the touched lane's files) — suites routinely assert on shared or sibling files (a skill's own suite can require a frontmatter field a sibling trim pass doesn't know about), so scoping `test_cmd` to "just what this lane touched" reintroduces exactly the blind spot a test gate exists to close. **Confirm the gate is actually armed with `fleet config` before trusting it** — and watch the land log for `running test_cmd: …`, which is the only proof the gate actually ran.
5. **Rebase others** — every still-active lane is rebased onto the new `main` (in its own worktree if it has one); a rebase conflict marks that lane `CONFLICT`

`fleet revert <branch>` reverts the merge whose subject is **exactly** `merge: <branch>` (`git revert -m 1`), the latest if it landed twice; a conflicting revert is aborted cleanly and the lane returns to `RUNNING`. Detail: [references/landing.md](references/landing.md).

## Daemon lifecycle (experimental)

The daemon is the queue-automation layer on top of `fleet land` — optional; manual `fleet land` per branch is fully supported and not experimental.

`fleet start` (via `Bash(run_in_background: true)`) polls `.claude/fleet/lanes/`, lands each lane as it turns READY and exits once all are terminal; `fleet stop` lets an in-progress land finish. **Don't stop it mid-gate**: the 5 s SIGKILL escalation can leave an untested merge on `main` (check `activity.log` first). It dies with the session. Detail: [references/daemon.md](references/daemon.md).

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
fleet main release          Clear the pin, fall back to the cwd heuristic
fleet owner <branch>        Who owns this lane, and are they still writing?
```

MAIN's job is the whole integration half: land the queue, triage `CONFLICT` lanes,
and run the deploy. Lanes build and signal; MAIN integrates. Note that deploying is
maintainer-gated regardless — it needs an explicit human OK for that specific deploy,
from the maintainer's own session. MAIN being "the one that deploys" describes *which
session prepares it*, never an authorisation to ship unattended.

### The live-owner gate

`fleet land` **refuses a lane whose owning session was active within `session_live_secs` (default 600)**: it would merge a branch that session may still be committing to and rebase worktrees out from under it. Ownership joins on `writtenBranches` and on the lane's worktree directory, across every Desktop instance's store. A lane session landing its own finished work is exempt only as the sole live claimant. Override: `session_check=off`, or `FLEET_SKIP_SESSION_CHECK=1` for one run (stripped before `test_cmd`).

Channels: lane files (`signal.sh`) work everywhere, `ccd_session_mgmt` is Desktop-only and agent-only, `pigeon` is the portable fallback. Mechanics and history: [references/session-awareness.md](references/session-awareness.md).

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

Only **SAFE** is ever removable: merged, clean, no open session claiming it, and for a `.claude/worktrees/` tree an archived session positively claiming it. A live claimant or the invoking tree is **KEEP**; an unreadable store, detached HEAD, dirty, unmerged or unattributable tree is **REVIEW**, never touched under any flag. Removal uses `git worktree remove` (never `rm -rf`), re-verifies against a fresh scan right before each delete, and `--all-repos` never removes. Prune cannot see writes by absolute path, so it must never be the only guard. Table, claim rules and the near-miss behind them: [references/prune.md](references/prune.md).

### Landmine: removing a worktree out from under a live session

**Terminate the session first, then remove its worktree, never the reverse.** A session whose worktree vanishes neither exits nor errors: it spins at ~85% of a core indefinitely under a live parent, so orphan scans miss it. Detect by sustained CPU rate, check its `--add-dir` against `git worktree list`, then kill it (safe: it touches no files). Evidence and the one-liner: [references/prune.md](references/prune.md).

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

Handles tracked native worktrees, `fleet init` worktrees, separate clones and mixed lanes, with test-gated landing, auto-rebase, scrub, revert and prune; refuses a dirty `main`. Out of scope: spawning or monitoring sessions, deleting worktrees a session owns, several sessions on one working tree (refused), uncommitted work at signal time (rejected), cross-lane external state like migrations (order lands by hand), force-pushed lanes (caught at land time only). Detail: [references/scope.md](references/scope.md).

## Compatibility

Runs on Linux and macOS (bash 3.2+), Git Bash, and PowerShell 7 calling `bash`; needs `git 2.5+` and standard tools. Platform table: [references/scope.md](references/scope.md).

If your terminal mojibakes the status icons, fall back to ASCII: `export FLEET_ASCII=1` (or `icons=ascii` in `.claude/fleet/config`). Output panels follow `docs/TERMINAL-DESIGN.md` via `skills/_lib/term.sh`.

Long-path warning (Windows only): `fleet init` worktrees nest under `.fleet-worktrees/<name>/`. Keep lane names short if your repo lives deep, or enable `core.longpaths=true`.

## Headless agent compatibility

**Don't put manually-created fleet worktrees under `.claude/`.** Claude Code applies a global sensitive-file guard to anything under `.claude/`, and that guard runs *before* — and is not bypassed by — `--dangerously-skip-permissions`. Headless lane sessions (`claude -p ... --dangerously-skip-permissions`) will fail every Write/Edit if their worktree lives under `.claude/`.

## Configuration

Optional `.claude/fleet/config`, one `key=value` per line, **parsed, never sourced**: keys are case-insensitive, values need no quotes, unknown keys are warned about on stderr. Keys: `mode`, `worktree_root`, `test_cmd`, `forbidden_pattern`, `base_branch`, `poll_interval`, `icons`, `session_check`, `session_live_secs`, `prune_hint`. **`test_cmd` is the test gate; unset, landing is refused.** Never add a contiguous scrub-marker token to a diff (build it by concatenation) or the scrub refuses the branch. Grammar, defaults, the shipped `forbidden_pattern` and the gitignore behaviour: [references/configuration.md](references/configuration.md).

## References

- `references/workflow.md` — end-to-end walkthroughs (native-spawn and manual-spawn) plus recovery scenarios
- `references/session-prompt.md` — lane brief to embed in `claude --bg` prompts, teammate spawn prompts, or manual sessions
- Detail moved out of this file, one topic each: `references/configuration.md`, `references/session-awareness.md`, `references/prune.md`, `references/landing.md`, `references/daemon.md`, `references/native-spawn.md`, `references/scope.md`

## Scripts

- `scripts/fleet.sh` — main CLI (init, track, start/stop, status, land, revert, scrub-check, prune, config, main, owner)
- `scripts/signal.sh` — branch-aware signaler (deployed to `.claude/fleet/signal.sh`); prints the MAIN handoff after READY/CONFLICT
- `scripts/sessions.sh` — resolves a branch or directory to its owning session across every Desktop store and the CLI transcripts; exits 3 silently without the store or `jq`. Detail: [references/session-awareness.md](references/session-awareness.md)
