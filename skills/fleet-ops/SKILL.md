---
name: fleet-ops
description: "EXPERIMENTAL — manage a fleet of concurrent Claude sessions on parallel branches or worktrees. Landing queue with test gate, fleet status view, pre-land scrub, one-shot revert. Triggers on: multiple Claude sessions, parallel sessions, concurrent agents, 5 sessions, branch queue, landing queue, fleet of sessions, parallel feature work, merge multiple branches, parallel branches."
license: MIT
allowed-tools: "Read Bash Glob Grep AskUserQuestion"
metadata:
  author: claude-mods
  status: experimental
  related-skills: git-ops, push-gate
---

# Fleet Ops (experimental)

Manage how committed work from isolated lanes lands on `main`. Anything before "committed" or after "landed" is somebody else's problem.

> **Status: experimental.** Dogfooding phase. API may change. Not yet in `README.md` Recent Updates.

## Core abstraction

A **lane** = one branch (or worktree), one Claude session, one logical unit of work. Lane status: `RUNNING | READY | CONFLICT | LANDED | FAILED`.

The skill doesn't care if there are 2 lanes or 20, doesn't care about branch names, doesn't care if you use worktrees or separate clones.

## CLI surface

```
fleet init <name>...        Create branch + worktree per name
fleet start                 Run the daemon (Ctrl-C to stop)
fleet fleet                 One-shot status view
fleet land <branch>         Manual land + rebase others
fleet revert <branch>       Revert merge commit on main
fleet scrub-check <branch>  Dry-run forbidden-pattern check
```

`signal.sh` deploys to `.fleet/signal.sh` on `init`. Sessions call:

```bash
bash .fleet/signal.sh READY <test-log>
bash .fleet/signal.sh CONFLICT "<reason>"
```

## Decision tree

```
N == 1                                    → use git-ops, not this
N > 1, all on shared local working tree   → REFUSE. Use worktrees or separate clones.
N > 1, worktrees available                → fleet init <names...>
N > 1, separate clones / remote           → use mode=branch, manual git branch + signal.sh
```

## First-class user interaction (HARD RULE)

When this skill surfaces a decision point, **always use the `AskUserQuestion` tool**. Plain markdown numbered lists are not acceptable for these branches — they make the skill feel like a wrapped script instead of a native interaction.

| Trigger | Question | Options (≤4, ≤10 words each) |
|---------|----------|------------------------------|
| `init` — worktrees available, mode unset | Worktree or branch-only mode? | Worktrees / Branches only / Cancel |
| Lane → `CONFLICT` (rebase fail) | Lane `<name>` has rebase conflict | Resolve in lane / Skip & continue / Revert lane / Untrack |
| Lane → `FAILED` (post-merge tests red) | Tests broke after `<name>` merged | Auto-revert / Investigate first / Accept failure |
| Pre-land scrub hits | Forbidden patterns in `<name>` diff | Block landing / Override (note reason) / Open to edit |
| `fleet` shows mixed states | How to proceed with the fleet? | Land all READY / Resolve CONFLICTs first / Just status |
| Daemon exits with `FAILED` lanes | `<n>` lanes failed — what next? | Retry all / Revert and report / Leave as-is |

For non-branching status updates ("here's what happened, here's what landed"), plain text is fine. The split matches the global `~/.claude/CLAUDE.md` "Asking Questions" rule.

## What it handles vs what it does not

| Mode | Status |
|------|--------|
| Worktrees on different branches | ✅ Primary mode |
| Branches in separate clones / machines | ✅ |
| Mixed worktree + branch lanes | ✅ |
| Recovery from dirty `main` | ✅ Refuses to merge, asks user to clean |
| Test-gated landing | ✅ Via `signal.sh READY <log>` |
| Auto-rebase other lanes when one lands | ✅ |
| Pre-land regex scrub (forbidden patterns) | ✅ |
| One-shot revert | ✅ `fleet revert <branch>` |

| Out of scope | Why |
|------|-----|
| 5+ sessions on one local working tree | Git limitation. Skill detects and refuses with worktree pointer. |
| Uncommitted work at signal time | `signal.sh` rejects dirty lanes. Daemon needs an immutable commit. |
| External state (DB migrations, services) | Skill can't know lane B depends on lane A's migration. Order manually. |
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

If your terminal mojibakes the status icons (⏳ ✅ 🚀 ❌ ⚠️), fall back to ASCII:

```bash
export FLEET_ASCII=1
# or in .fleet/config:
icons=ascii
```

Long-path warning (Windows only): worktrees nest under `.fleet/worktrees/<name>/`. If your repo lives deep in the filesystem, lane names should stay short to avoid Windows' 260-char path limit. Enable `core.longpaths=true` in git if you hit it.

## Configuration

Optional `.fleet/config` (key=value, no quotes):

```
mode=auto                            # auto | worktree | branch
worktree_root=.fleet/worktrees
test_cmd=                            # if set, daemon runs this; else trust signal log
forbidden_pattern=TODO_SCRUB|XXX
base_branch=main
poll_interval=5
```

Zero-config works for the common case.

## References

- `references/session-prompt.md` — copy-paste template for each Claude session
- `references/workflow.md` — end-to-end walkthrough plus recovery scenarios

## Scripts

- `scripts/fleet.sh` — main CLI
- `scripts/signal.sh` — branch-aware signaler (deployed to `.fleet/signal.sh` on init)
