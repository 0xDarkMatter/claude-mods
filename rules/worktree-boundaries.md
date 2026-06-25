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

## Provisioning discipline — one writer per tree (parallel isolation)

The rule above is *defensive* (don't touch others' trees). This is the *provisioning* half: how to
isolate your own parallel work so commits never clash. A git working tree has exactly one index and
one HEAD — **two sessions committing to the same tree is the write-time clash** (index locks,
interleaved commits, a working tree that mutates under you).

**One writer, one worktree, one branch. Always. No exception for "small" work.** "Feature branches
vs worktrees" is a false choice at parallel scale — a branch is the ref that lands, a worktree is
where it's written; you use both. Branches are unlimited and free; the scarce resource is the
*checkout* — one directory has exactly one branch checked out at a time, so two sessions in the same
folder are forced onto the same branch. Plain feature branches (one checkout, `git switch`) only
work for *sequential* work.

| Spawn type | Isolation |
|---|---|
| Background agents (`claude --bg`) | ✅ auto-worktree under `.claude/worktrees/` — safe by default |
| `Agent`-tool subagents / `/workflows` agents that **write** | set `isolation: 'worktree'` (read-only agents don't need it) |
| **`spawn_task` chips** | ❌ **do NOT isolate** — the spawned session runs on the *current branch* of the primary checkout ([claude-code#64605](https://github.com/anthropics/claude-code/issues/64605)); seed the chip prompt to `git switch -c <slug>` first |
| Manual parallel sessions | give each its own worktree; **never two writing sessions in one checkout** |
| Agent teams | share one tree — only safe with file-partitioned, non-overlapping scopes |

**Detect a live peer writer before you write.** The "worktree contract" is not enforced (chips
violate it; an agent can escape a worktree via an absolute path), so don't *assume* isolation —
verify it. When you start in a checkout whose tree is **already dirty with changes you didn't make**,
probe before writing: fingerprint `git diff | sha1sum` twice ~6s apart and check the newest
modified-file mtime. If the fingerprint changes (or a file was written seconds ago and you didn't do
it), **a peer session is live** — warn and move your work to its own worktree rather than sharing the
checkout. Old WIP with stale mtimes is fine. The `session-start-unicode-scan.sh` SessionStart hook
raises this flag automatically at boot.

Corollaries:

- **The main/base checkout is sacred — landing-only.** Never run a *writing* session there; it's the
  integration tree. Land parallel branches through [fleet-ops](../skills/fleet-ops/SKILL.md) (the
  manual, test-gated landing queue).
- **Land early, land often.** Bound divergence by integrating green lanes continuously, not as one
  big-bang merge at the end — at 10+ lanes that's what bites.
- **Lane naming:** `lane/<slug>` (and the native `claude/<slug>`) so the backlog is legible.
- **A branch name does not reveal isolation** — `claude/eager-wozniak` looks identical whether it's a
  worktree-isolated background agent or a session in your main checkout. Isolation is a structural
  property you enforce, not something you read off the label.

## Scope this rule covers

All projects. Never make exceptions "just for this session". If a worktree ever looks like it needs cleanup, ask the user explicitly before touching it.
