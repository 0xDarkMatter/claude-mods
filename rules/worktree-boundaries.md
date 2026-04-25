# Worktree Boundaries

Never touch `.claude/worktrees/` in any repo. Never touch git worktrees, submodules, gitlinks, or agent-spawned ephemeral dirs in repos outside your current working scope.

## The rule

**Worktrees belong to the project that owns them.** If private-project housekeeping touches file X in repo Y, that does NOT extend to `.claude/worktrees/` in repo Y. Worktrees are the private state of whichever agent, session, or human spawned them. They may look orphaned and aren't.

## What counts as "don't touch"

- Do not `rm -rf .claude/worktrees/` in any repo
- Do not `git rm` or `git rm --cached` worktree entries
- Do not stage deletions of worktree dirs via `git add -A` (this is the subtle one — `-A` sweeps up changes you didn't intend)
- Do not commit changes that reference `.claude/worktrees/` paths
- Do not reason about whether a worktree is "orphaned" unless the owning project explicitly asks

## Why

- Worktree names like `agent-<hash>` look like ephemeral agent artifacts but may be active sessions
- A gitlink/submodule pointing at a worktree is not garbage — it's a reference with meaning to the owning session
- Agent-spawned worktrees may contain uncommitted work the user wants to inspect
- Cross-project cleanup assumes context you don't have; when a project wants cleanup it will ask its own session

## The specific failure this came from (2026-04-19)

During a private-project ecosystem-wide "commit + push all tool repos" pass, `git add -A` in flarecrawl staged gitlinks to 9 agent worktrees (from background agents running inside flarecrawl). Those gitlinks were committed and pushed as part of "chore: sync tool state". Then a subsequent `rm -rf .claude/worktrees/` deleted the filesystem dirs, creating a dirty state. The user correctly pushed back — private-project housekeeping has no business touching another project's agent state.

## Applied corrections when running bulk commits across repos

- Use explicit file paths to `git add`, not `-A` or `.`, when the repo contains any `.claude/` directory
- Inspect `git status --short` before any bulk commit loop; if `.claude/worktrees/` appears, STOP and ask
- Never include worktrees in commit messages, scripts, or cleanup routines
- If a repo's `.claude/` state looks "dirty" during cross-project work, that's the repo's problem, not yours

## Scope this rule covers

All projects. Never make exceptions "just for this session". If a worktree ever looks like it needs cleanup, ask the user explicitly before touching it.
