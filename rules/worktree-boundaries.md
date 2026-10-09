# Worktree Boundaries

Never touch `.claude/worktrees/` in any repo, or `$WORKTREE_ROOT/` when the machine sets it. Never touch git worktrees, submodules, gitlinks, or agent-spawned ephemeral dirs in repos outside your current working scope.

## The rule

**Worktrees belong to the project that owns them.** If cross-project housekeeping touches file X in repo Y, that does NOT extend to `.claude/worktrees/` in repo Y, nor to `$WORKTREE_ROOT/Y/`. Worktrees are the private state of whichever agent, session, or human spawned them. They may look orphaned and aren't.

## What counts as "don't touch"

- Do not `rm -rf .claude/worktrees/` in any repo, nor `$WORKTREE_ROOT/<repo>/` or anything under it
- Do not `git rm` or `git rm --cached` worktree entries
- Do not stage deletions of worktree dirs via `git add -A` (this is the subtle one — `-A` sweeps up changes you didn't intend)
- Do not `git clean -ff` / `--force --force` in a repo with `.claude/worktrees/` — a *single* `-f` git clean safely skips nested worktrees ("Skipping repository …"), but a **double** force deletes them, taking any uncommitted lane work with it
- Do not commit changes that reference `.claude/worktrees/` paths
- Do not reason about whether a worktree is "orphaned" unless the owning project explicitly asks

## Why

- Worktree names like `agent-<hash>` look like ephemeral agent artifacts but may be active sessions
- A gitlink/submodule pointing at a worktree is not garbage — it's a reference with meaning to the owning session
- Agent-spawned worktrees may contain uncommitted work the user wants to inspect
- Cross-project cleanup assumes context you don't have; when a project wants cleanup it will ask its own session

## The failure this came from

During an ecosystem-wide "commit + push all tool repos" pass, `git add -A` in one repo staged gitlinks to nine agent worktrees (from background agents running inside that repo). Those gitlinks were committed and pushed as part of a routine "chore: sync" commit. A follow-up `rm -rf .claude/worktrees/` then deleted the directories, leaving a dirty state behind. Cross-project housekeeping has no business touching another project's agent state.

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
| **`spawn_task` chips** | ⚠️ **don't assume** — whether a chip gets its own worktree depends on how it is started (it can start in a fresh worktree, but historically chips ran on the primary checkout's current branch — [claude-code#64605](https://github.com/anthropics/claude-code/issues/64605)). Seed every chip prompt to create and work in its own lane: `git worktree add .claude/worktrees/<slug> -b lane/<slug>` |
| Manual parallel sessions | give each its own worktree; **never two writing sessions in one checkout** |
| Agent teams | share one tree — only safe with file-partitioned, non-overlapping scopes |

**Detect a live peer writer before you write.** The "worktree contract" is not enforced (a chip may
not honour it; an agent can escape a worktree via an absolute path), so don't *assume* isolation —
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
  big-bang merge at the end — at 10+ lanes that's what bites. It's also your real safety net:
  **committed lane work lives in the shared object store and survives even deletion of the worktree
  directory** (recover with `git worktree add <path> lane/<slug>`); only *uncommitted* work is
  destructible. So commit-often is what makes a lane's work durable.
- **Lane location:** when the machine sets **`WORKTREE_ROOT`** (Claude Code `settings.json` `env`),
  every lane goes to **`$WORKTREE_ROOT/<repo>/<slug>`**, `<repo>` being the main checkout's dir name.
  Project dirs then hold no lanes at all, so `rg`/`fd`/`tokei`/`git add -A`/`git clean` in the
  project never see one, and no ignore entry is needed. `new-lane.sh` and `fleet init` use it by
  default; Claude Code's own worktrees follow only with the `hooks/worktree-create.sh` pair wired.
  Without the variable: **in-repo** at `<main>/.claude/worktrees/<slug>` — native to Claude Code's
  own worktrees, and safe only *because* `.claude/worktrees/` is gitignored, so a tool placing a lane
  there must ensure that ignore first (`new-lane.sh` does). A **sibling** (`<repo>-<slug>` —
  `new-lane.sh --sibling`) is the fallback for structural isolation from repo-scoped destructive
  ops (`git clean -ff`, `rm -rf <repo>`) or a repo that can't gitignore the dir. Tools that find
  lanes ask `git worktree list`, not a path pattern: a lane can live in any of the three places.
- **Lane naming:** `lane/<slug>` (and the native `claude/<slug>`) so the backlog is legible.
- **A branch name does not reveal isolation** — `claude/eager-wozniak` looks identical whether it's a
  worktree-isolated background agent or a session in your main checkout. Isolation is a structural
  property you enforce, not something you read off the label.

## Scope this rule covers

All projects. Never make exceptions "just for this session". If a worktree ever looks like it needs cleanup, ask the user explicitly before touching it.
