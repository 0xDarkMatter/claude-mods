---
name: git-ops
description: "Git + worktree orchestrator: status survey, per-worktree triage, commits, PRs, branches, releases, rebases — reads inline, writes to a background agent. Triggers on: git status, anything to commit, anything to push, commit, push, create PR, rebase, release, tag, changelog, worktree, land worktrees."
license: MIT
allowed-tools: "Read Bash Glob Grep Agent TaskCreate TaskUpdate"
metadata:
  author: claude-mods
  related-skills: review, ci-cd-ops, push-preflight
---

# Git Ops

Intelligent git operations orchestrator. Routes read-only queries inline for speed, dispatches write operations to a background Sonnet agent (`git-agent`) to free the main session.

## Architecture

```
User intent (commit, PR, rebase, status, etc.)
    |
    +---> Tier 1: Read-only (status, log, diff, blame)
    |       |
    |       +---> Execute INLINE via Bash (fast, no subagent)
    |
    +---> Tier 2: Safe writes (commit, push, tag, PR, stash)
    |       |
    |       +---> Gather context from conversation
    |       +---> Dispatch to git-agent (background, Sonnet)
    |       |       +---> Fallback: general-purpose with inlined protocol
    |       +---> Agent executes and reports back
    |
    +---> Tier 3: Destructive (rebase, reset, force-push, branch -D)
            |
            +---> Dispatch to git-agent (background, Sonnet)
            |       +---> Fallback: general-purpose with inlined protocol
            +---> Agent produces PREFLIGHT REPORT (does NOT execute)
            +---> Orchestrator relays preflight to user
            +---> On confirmation: re-dispatch with execute authority
```

## Safety Tiers

### Tier 1: Read-Only - Run Inline

No subagent needed. Execute directly via Bash for instant results.

| Operation | Command |
|-----------|---------|
| **Status (rich)** | `bash $HOME/.claude/skills/git-ops/scripts/status.sh` — one-shot HEAD + sync + tree + worktrees + branches + PR |
| **Worktree survey** | `bash $HOME/.claude/skills/git-ops/scripts/worktree-survey.sh` — per-worktree state, drift detection, prunable/WIP/ghost/orphan triage |
| **Land-all plan** | `bash $HOME/.claude/skills/git-ops/scripts/land-all.sh [--porcelain]` — classifies every branch as LANDABLE/STALE/WIP/ACTIVE/MERGED for a batch land (see "Land all" below) |
| Status (bare) | `git status --short` |
| Log | `git log --oneline -20` |
| Diff (unstaged) | `git diff --stat` |
| Diff (staged) | `git diff --cached --stat` |
| Diff (full) | `git diff [file]` or `git diff --cached [file]` |
| Branch list | `git branch -v` |
| Remote branches | `git branch -rv` |
| Stash list | `git stash list` |
| Blame | `git blame [file]` |
| Show commit | `git show [hash] --stat` |
| Reflog | `git reflog --oneline -20` |
| Tags | `git tag --list --sort=-v:refname` |
| Worktree list | `git worktree list` |
| PR list | `gh pr list` |
| PR status | `gh pr view [N]` |
| Issue list | `gh issue list` |
| CI checks | `gh pr checks [N]` |
| Run status | `gh run list --limit 5` |

For T1 operations, format results cleanly and present directly. Use `delta` for diffs when available.

**When to reach for the bundled scripts:**
- User asks "status", "where are we", "anything to commit", "anything to push" → `status.sh`
- User asks about worktrees, prunable branches, drift, "what can we clean up" → `worktree-survey.sh`
- Both scripts exit 0 if clean, 1 if attention needed, 2 if not-a-repo — composable.

## Hygiene Checks (Proactive — Run During Every T1 Status)

When running any status check, scan for these anti-patterns and surface them **before** the status output. Don't wait for the user to notice. The `status.sh` script handles checks 1 and 2 automatically; checks 3 and 4 are Claude's responsibility.

### Anti-pattern 1: Main checkout on a feature branch 🔴

**Signal:** In the main checkout (not a worktree) and `git branch --show-current` ≠ the repo's default branch (`main`/`master`/`trunk`).

**Why it's bad:** The main checkout is the fallback workspace. Feature branches sitting there block clean status reads, confuse worktree operations, and make it unclear what "current" state is. Feature work belongs in dedicated worktrees.

**Flag it:** Emit a prominent warning before the status output.

**Fix:**
```bash
git checkout main                                              # return main to trunk
git worktree add .claude/worktrees/<name> <feature-branch>   # move work to worktree
```

**Detecting main checkout vs worktree:**
```bash
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
# ".git"               → main checkout  → check applies
# contains "worktrees" → inside a worktree → skip this check
```

### Anti-pattern 2: Stale merged branches 🟡

**Signal:** `git branch --merged <default>` returns branches other than the trunk.

**Why it's bad:** Merged-but-undeleted branches are noise that obscures what's actually in flight.

**Flag it:** Report the count. Suggest `fleet sweep` (fleet-ops): its `--apply` deletes merged, worktree-less branches no open session holds, zero-loss, after a typed confirm.

### Anti-pattern 3: WIP commits on a pushed branch 🟡

**Signal:** `git log --oneline @{u}..HEAD` contains subject lines matching `wip|WIP|todo|TODO|fixme|FIXME|temp|TEMP|hack|HACK`.

**Why it's bad:** WIP markers in pushed history signal unfinished work that shouldn't have left the local machine. Creates confusing history and blocks clean PRs.

**Flag it:** List the offending commits and suggest an interactive rebase to squash or rename.

### Anti-pattern 4: Large uncommitted pile 🟡

**Signal:** staged + unstaged + untracked > 20 files.

**Why it's bad:** Large uncommitted diffs are hard to review, easy to lose, and signal a broken "commit as you go" habit.

**Flag it:** Note the total and suggest committing incrementally by logical unit.

---

### Tier 2: Safe Writes - Dispatch to Agent

Gather relevant context, then dispatch to `git-agent` (background, Sonnet).

**Context gathering before dispatch:**

| Operation | Context to Gather |
|-----------|-------------------|
| **Commit** | What the user has been working on (from conversation), staged files, recent commit style |
| **Push** | Current branch, tracking info, commits ahead of remote |
| **PR create** | All commits on branch vs main, conversation context for description |
| **Tag/release** | Commits since last tag, version pattern in use |
| **Stash** | Current changes, user's stash message if provided |
| **Cherry-pick** | Target commit details, current branch |
| **Branch create** | Base branch, naming convention from recent branches |
| **gh issue create** | User description, labels if mentioned |

**Dispatch template:**

```
You are the git-agent handling a Tier 2 (safe write) operation.

## Domain Knowledge
For release or PR operations, read CI context first:
- Read: skills/ci-cd-ops/SKILL.md (release workflows, PR conventions)

## Context
- Current branch: {branch}
- Repository: {repo info}
- User intent: {what the user asked for}
- Conversation context: {relevant summary of what was being worked on}

## Operation
{specific operation details}

## Project Conventions
{commit style, branch naming, PR template if detected}

Execute the operation following your T2 protocol (verify state, execute, confirm, report).
```

### Tier 3: Destructive - Preflight Required

Dispatch to `git-agent` with explicit instruction to produce a preflight report ONLY.

**Dispatch template (preflight):**

```
You are the git-agent handling a Tier 3 (destructive) operation.

## Context
- Current branch: {branch}
- Repository: {repo info}
- User intent: {what the user asked for}

## Operation
{specific operation details}

IMPORTANT: Do NOT execute this operation. Produce a T3 Preflight Report only.
Show exactly what will happen, what the risks are, and how to recover.
```

**After user confirms:** Re-dispatch with execute authority:

```
User has confirmed the Tier 3 operation after reviewing the preflight.

## Approved Operation
{exact operation from preflight}

## Confirmation
Proceed with execution. Follow T3 execution protocol:
1. Create a safety bookmark: note the current HEAD hash
2. Execute the operation
3. Verify the result
4. Report with the safety bookmark for recovery
```

## Dispatch Mechanics

Background is the default for T2/T3, foreground when the user is waiting on the result, worktree isolation only when asked. Call shapes: [references/dispatch.md](references/dispatch.md).

## Fallback: When git-agent Is Unavailable

If `git-agent` is not available, dispatch `general-purpose` with the tier protocol inlined in the prompt; inline execution is a last resort for simple T2 operations only. Template: [references/dispatch.md](references/dispatch.md).

## Extended Operations

### Release Workflow

`git-ops` owns the **local** half of releases only — analysing commits, generating CHANGELOG content, creating the local tag. The **remote** half (push, `gh release create`, repo metadata) belongs to the `github-ops` skill.

When user asks to "create a release", "bump version", or "tag a release":

1. **Inline (T1):** Check current version and commits since last tag
   ```bash
   git describe --tags --abbrev=0 2>/dev/null
   git log --oneline $(git describe --tags --abbrev=0 2>/dev/null)..HEAD
   ```

2. **Determine version bump:**
   - `feat:` commits -> minor bump
   - `fix:` commits -> patch bump
   - `BREAKING CHANGE:` or `!:` -> requires explicit user approval (never auto-major)
   - Or use version specified by user

3. **Dispatch to git-agent (T2):** Generate CHANGELOG content + create local tag.

4. **Hand off to `github-ops`** for the remote half: push commits, push tag, create the GitHub release with notes, update repo metadata if warranted. Do not call `gh release create` from git-ops — that crosses the local/remote boundary. See `skills/github-ops/SKILL.md` mode `update`.

### Other extended operations

Changelog generation, the full PR cycle, branch cleanup (deleting branches is a T3 preflight), semver analysis and conflict-resolution support: [references/extended-operations.md](references/extended-operations.md).

## Worktree Operations

Worktrees are first-class in this skill. The classification is:

| Op | Tier | How |
|----|------|-----|
| **Survey** | T1 | `bash scripts/worktree-survey.sh` — read-only, reports per-worktree state + drift |
| **New lane** | T2 (inline) | `bash scripts/new-lane.sh [--sibling] <slug> [base]` — fast scripted provisioning: branch `lane/<slug>` **in-repo** at `.claude/worktrees/<slug>` (gitignored; `--sibling` for an outside `<repo>-<slug>` instead) + carries over gitignored env files. The one-command collision remedy — see "Lane provisioning" below |
| **Create (bespoke)** | T2 | `git worktree add <path> -b <branch>` via agent — for non-standard layouts the script doesn't cover |
| **Land** | T2 | Rebase worktree branch onto trunk + test + fast-forward. Multi-step procedure — see "Worktree Land Procedure" below |
| **Prune (clean)** | T2 | `git worktree prune` for ghost entries (registered but FS-missing). Always safe, no data loss possible |
| **Remove** | **T3** | `git worktree remove <path>` — destroys filesystem state. Requires preflight + explicit confirm per worktree |

### Lane provisioning (the collision remedy)

`bash scripts/new-lane.sh [--sibling] <slug> [base]`: branch `lane/<slug>` at `.claude/worktrees/<slug>`, gitignore ensured, env files carried, never clobbers. Committed lane work survives worktree deletion; land early. Details: [references/lane-provisioning.md](references/lane-provisioning.md).

### Survey-first discipline

Never recommend prune/remove without first running `scripts/worktree-survey.sh`
and presenting the output to the user. The survey categorises each worktree as:

- `(trunk)` — the main repo itself, never prune
- `PRUNABLE` — merged into trunk, no uncommitted work, no unpushed commits → safe to remove
- `has WIP` — uncommitted changes → commit or stash first, never auto-remove
- `unpushed` — commits ahead of upstream → push or cherry-pick before remove
- `in-flight` — not merged, not dirty → probably still in active use
- `GHOST` — registered but filesystem gone → `git worktree prune` fixes
- `UNREGISTERED` / orphan — filesystem dir with no git entry → **DO NOT touch without explicit review**

After a **wave** of parallel lanes, run `fleet sweep` (fleet-ops) instead: it adds what this survey cannot see — lanes landed by content, competing lanes, which orphan dirs an open session still uses, and which finished sessions to ask to archive.

### Worktree Land Procedure (T2)

For landing a branch from a worktree onto the trunk (rebase + test + ff):

1. Verify preconditions: worktree clean, branch ahead of trunk, not already merged
2. Fetch trunk, rebase worktree branch onto it
3. Run project test command (detect from `package.json` / `pyproject.toml` / `justfile`)
4. On test pass: fast-forward trunk to the rebased tip
5. Do NOT push — that's a separate explicit step (and should go through `push-preflight`)

Dispatch this to `git-agent` as a T2 operation with the worktree path + trunk name.

### Land all — batch-land every pending lane (T1 plan → fleet-ops execution)

Survey with `scripts/land-all.sh --porcelain`, **confirm the land / park / prune plan with the user before anything lands (HARD RULE)**, land via `fleet-ops`, escalate every CONFLICT instead of resolving it, then survey-first cleanup. Full procedure: [references/land-all.md](references/land-all.md).

**Safety invariants:** `ACTIVE` lanes (live peer writer) are never landed — this is the
worktree-boundaries live-writer guard applied to landing. `WIP` needs an explicit commit first.
`STALE` needs explicit opt-in (`--recent-days` or naming the branch). Only `LANDABLE` lands by default.

### Boundaries (HARD RULE)

See `rules/worktree-boundaries.md`. Summary:

- **Never** `rm -rf .claude/worktrees/` — the orphan count in survey is informational, never a cleanup cue
- **Never** `git add -A` when `.claude/worktrees/` has untracked entries (sweeps gitlinks into commits)
- **Never** decide another session's worktree is "orphaned" — ask first
- Cross-project work stays cross-project; a worktree in repo X is never our concern when we're operating on repo Y

## Decision Logic

When a git-related request arrives, follow this flow:

```
1. Classify the operation tier (T1/T2/T3)

2. If T1:
   - Execute inline via Bash
   - Format and present results
   - DONE

3. If T2:
   - Gather context (conversation, git state, conventions)
   - Decide foreground vs background:
     * User waiting on result? -> foreground
     * User continuing other work? -> background
   - Dispatch to git-agent with context
   - Relay result when received

4. If T3:
   - Gather context
   - Dispatch to git-agent for PREFLIGHT ONLY
   - Present preflight report to user
   - Wait for explicit confirmation
   - Re-dispatch with execute authority
   - Relay result
```

## Quick Reference

| Task | Tier | Inline/Agent |
|------|------|-------------|
| Check status (rich) | T1 | Inline (`scripts/status.sh`) |
| Worktree survey | T1 | Inline (`scripts/worktree-survey.sh`) |
| View diff | T1 | Inline |
| View log | T1 | Inline |
| List PRs | T1 | Inline |
| Commit | T2 | Agent |
| Push | T2 | Agent |
| Create PR | T2 | Agent |
| Create tag | T2 | Agent |
| Create release | T2 | Agent |
| Stash push/pop | T2 | Agent |
| Cherry-pick | T2 | Agent |
| Create branch | T2 | Agent |
| Create worktree | T2 | Agent |
| Land worktree | T2 | Agent (rebase + test + ff) |
| Prune ghost worktrees | T2 | Agent (`git worktree prune`) |
| Rebase | T3 | Agent (preflight) |
| Force push | T3 | Agent (preflight) |
| Reset --hard | T3 | Agent (preflight) |
| Delete branch | T3 | Agent (preflight) |
| Discard changes | T3 | Agent (preflight) |
| Merge to main | T3 | Agent (preflight) |
| Remove worktree | T3 | Agent (preflight per worktree) |

## Tools

| Tool | Purpose |
|------|---------|
| `git` | All git operations |
| `gh` | GitHub CLI - PRs, issues, releases, actions |
| `delta` | Syntax-highlighted diffs (if available) |
| `lazygit` | Interactive TUI (suggest to user, not for agent) |

## Additional Resources

For detailed patterns, load:
- `./references/rebase-patterns.md` - Interactive rebase workflows and safety
- `./references/stash-patterns.md` - Stash operations and workflows
- `./references/advanced-git.md` - Bisect, cherry-pick, worktrees, reflog, conflicts
- `./references/dispatch.md` - Agent call shapes (background, foreground, worktree isolation) and the fallback when git-agent is unavailable
- `./references/extended-operations.md` - Changelog, full PR cycle, branch cleanup, semver analysis, conflict-resolution support
- `./references/lane-provisioning.md` - What `new-lane.sh` creates and enforces, and lane-work durability
- `./references/land-all.md` - Batch landing in full: triggers, status table, fleet-ops commands, conflicts, cleanup
