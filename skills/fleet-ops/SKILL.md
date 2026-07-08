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

Fleet-ops doesn't care who produced the branch — an agent-team teammate, a background agent's auto-worktree, a `claude -p` headless run, or a human. If it's a branch with commits, it can be a lane.

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
```

## Entry paths

```
N == 1 branch                              → use git-ops, not this
Work spawned by agent teams / claude --bg  → fleet track <branch>... then land
Work to be spawned manually                → fleet init <names...> (creates branches + worktrees)
N > 1 on one shared working tree           → REFUSE. Worktrees or separate clones first.
```

**Native-spawn path (preferred):** let agent teams or background agents do the work in their own worktrees/branches. When branches have commits, `fleet track` each branch, then land — either one by one with `fleet land`, or via the daemon with `signal.sh READY` gates. Fleet-ops merges *branches*; it never deletes or relocates a worktree that a native session owns (worktree cleanup belongs to agent view / `claude rm`).

**Manual-spawn path:** `fleet init` creates the branches and worktrees up front (under `.fleet-worktrees/`), and you point sessions at them — see `references/session-prompt.md` for the lane brief to hand each session.

## Landing pipeline

`fleet land <branch>` (and the daemon, per READY lane):

1. **Scrub** — `git diff main...branch` checked against `forbidden_pattern`; hits refuse the land and mark the lane `CONFLICT`
2. **Clean-base check** — refuses if `main` has uncommitted tracked changes
3. **Merge** — `--no-ff` with message `merge: <branch>` (this message is what `fleet revert` finds later)
4. **Test gate** — runs `test_cmd` if set; on failure, hard-resets the merge and marks the lane `FAILED`. If unset, trusts `signal.sh`'s log gate (refused READY on failing logs)
5. **Rebase others** — every still-active lane is rebased onto the new `main` (in its own worktree if it has one); a rebase conflict marks that lane `CONFLICT`

`fleet revert <branch>` finds the `merge: <branch>` commit on `main` and runs `git revert -m 1` — one command to back out a bad landing.

## Daemon lifecycle (experimental)

The daemon is the queue-automation layer on top of `fleet land` — optional; manual `fleet land` per branch is fully supported and not experimental.

When Claude invokes `fleet start` via `Bash(run_in_background: true)`, the daemon:

1. Writes its PID to `.claude/fleet/daemon.pid`
2. Traps `SIGINT/SIGTERM/SIGHUP` and removes the PID file on exit
3. Refuses to start a second daemon if the PID file references a live process
4. Polls `.claude/fleet/lanes/` and lands lanes as they turn `READY`
5. Exits naturally when all lanes are terminal (`LANDED` or `FAILED`)

To stop early: `fleet stop` (SIGTERM, 5s grace, then SIGKILL). On next `fleet start`, a stale PID file is auto-detected and cleared. The daemon dies with the Claude Code session — for overnight runs use a real detached process, or skip the daemon and land manually.

`signal.sh` deploys to `.claude/fleet/signal.sh` on `init`/`track`. Working sessions call:

```bash
bash .claude/fleet/signal.sh READY <test-log>     # refuses dirty trees and failing logs
bash .claude/fleet/signal.sh CONFLICT "<reason>"
```

## First-class user interaction (HARD RULE)

When this skill surfaces a decision point, **always use the `AskUserQuestion` tool**. Plain markdown numbered lists are not acceptable for these branches.

| Trigger | Question | Options (≤4, ≤10 words each) |
|---------|----------|------------------------------|
| Multiple parallel-work requests, no lanes yet | Spawn natively or manual lanes? | Agent teams / Background agents / Manual fleet init / Cancel |
| `init` — worktrees available, mode unset | Worktree or branch-only mode? | Worktrees / Branches only / Cancel |
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

| Out of scope | Why |
|------|-----|
| Spawning / monitoring sessions | Native: agent teams, `claude --bg`, agent view. Fleet-ops never launches a session. |
| Deleting native session worktrees | Owned by agent view / `claude rm`. Fleet-ops merges branches only. |
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

Long-path warning (Windows only): `fleet init` worktrees nest under `.fleet-worktrees/<name>/`. Keep lane names short if your repo lives deep, or enable `core.longpaths=true`.

## Headless agent compatibility

**Don't put manually-created fleet worktrees under `.claude/`.** Claude Code applies a global sensitive-file guard to anything under `.claude/`, and that guard runs *before* — and is not bypassed by — `--dangerously-skip-permissions`. Headless lane sessions (`claude -p ... --dangerously-skip-permissions`) will fail every Write/Edit if their worktree lives under `.claude/`.

That's why the default `worktree_root` is `.fleet-worktrees/` at the repo top. (Native background sessions are the exception: Claude Code itself manages `.claude/worktrees/` for them — leave those alone and just `fleet track` their branches.) Runtime state (`lanes/`, `daemon.pid`, `activity.log`) is read/write from the orchestrator only and stays under `.claude/fleet/`.

## Configuration

Optional `.claude/fleet/config` (key=value, no quotes):

```
mode=auto                            # auto | worktree | branch
worktree_root=.fleet-worktrees       # keep outside .claude/ — see "Headless agent compatibility"
test_cmd=                            # if set, daemon runs this; else trust signal log
forbidden_pattern=TODO_SCRUB|XXX
base_branch=main
poll_interval=5
```

Zero-config works for the common case.

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

- `scripts/fleet.sh` — main CLI (init, track, start/stop, status, land, revert, scrub-check)
- `scripts/signal.sh` — branch-aware signaler (deployed to `.claude/fleet/signal.sh`)
