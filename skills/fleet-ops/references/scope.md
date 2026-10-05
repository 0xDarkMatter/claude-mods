# Scope and Future Work

What fleet-ops handles, what it deliberately does not, and what is planned.

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
| Deleting worktrees a session still owns | `fleet prune` removes only what is merged, clean, and claimed by no open session — and, for a `.claude/worktrees/` tree, positively claimed by an archived one. Anything live, dirty, unmerged, open, or unattributable is reported, never removed — and cross-repo removal is impossible by design. Removing one by any *other* path strands the session in a silent CPU spin — see [the ordering landmine](../SKILL.md#landmine-removing-a-worktree-out-from-under-a-live-session). |
| Multiple sessions on one shared working tree | Git limitation. Skill detects and refuses with worktree pointer. |
| Uncommitted work at signal time | `signal.sh` rejects dirty lanes. The queue needs an immutable commit. |
| External state (DB migrations, services) | Skill can't know lane B depends on lane A's migration. Order manually via `fleet land`. |
| Force-pushed lanes mid-flight | Detected at land time, not prevented. |

## Future work

- **JSONL activity log** — currently plain text. Switch when a TUI, `--json` output, or `log-ops` integration earns the cost.
- **`TaskCompleted` hook bridge** — auto-`signal.sh READY` when an agent-team task completes with green tests.

Shipped since first release:

- **`fleet land --all [--running]`** — batch-land all READY (or vetted RUNNING) lanes oldest-first, rebasing the rest after each and reporting once. Drives the `git-ops` "land all" front-door (`scripts/land-all.sh` discovers + classifies; fleet-ops executes).

## Platforms

Tested and working on:

| OS | Shell | Notes |
|----|-------|-------|
| Linux | bash 4+ | Native |
| macOS | bash 3.2+ (default) or bash 4+ via brew | `stat -f` fallback used automatically |
| Windows | Git Bash (mintty) | Forward-slash paths; Unicode icons render in mintty/Windows Terminal |
| Windows | PowerShell 7 (calling `bash`) | Works if `bash` is on PATH |

Requirements: `bash 3.2+`, `git 2.5+` (worktree support), `awk`, `grep`, `head`, `stat`. All standard.
