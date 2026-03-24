---
name: git-ops
description: "Git operations orchestrator - commits, PRs, branch management, releases, changelog. Routes lightweight reads inline, dispatches heavy work to background Sonnet agent. Triggers on: commit, push, pull request, create PR, git status, git diff, rebase, stash, branch, merge, release, tag, changelog, semver, cherry-pick, bisect, worktree."
allowed-tools: "Read Bash Glob Grep Agent TaskCreate TaskUpdate"
related-skills: [review, ci-cd-ops]
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
| Status | `git status --short` |
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
| PR list | `gh pr list` |
| PR status | `gh pr view [N]` |
| Issue list | `gh issue list` |
| CI checks | `gh pr checks [N]` |
| Run status | `gh run list --limit 5` |

For T1 operations, format results cleanly and present directly. Use `delta` for diffs when available.

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

### Background Agent (Default for T2/T3)

```python
# Dispatch to git-agent, runs in background, Sonnet model
Agent(
    subagent_type="git-agent",
    model="sonnet",
    run_in_background=True,  # Frees main session
    prompt="..."             # From dispatch templates above
)
```

The main session continues working while the agent handles git operations. Results arrive asynchronously.

### Foreground Agent (When Result Needed Immediately)

For operations where the user is waiting on the result (e.g., "commit this then let's move on"):

```python
Agent(
    subagent_type="git-agent",
    model="sonnet",
    run_in_background=False,  # Wait for result
    prompt="..."
)
```

### Worktree Isolation (Only When Requested)

When the user explicitly asks for worktree isolation (e.g., "do this in a separate worktree", "prepare a branch without touching my working tree"):

```python
Agent(
    subagent_type="git-agent",
    model="sonnet",
    isolation="worktree",     # Isolated repo copy
    run_in_background=True,
    prompt="..."
)
```

## Fallback: When git-agent Is Unavailable

If `git-agent` is not registered as a subagent type (e.g., plugin not installed, agent files missing), fall back to `general-purpose` with the git-agent identity inlined in the prompt.

**Detection:** If dispatching to `git-agent` fails or the subagent type is not listed in available agents, switch to fallback mode automatically.

**Fallback dispatch template:**

```python
Agent(
    subagent_type="general-purpose",  # Fallback
    model="sonnet",
    run_in_background=True,
    prompt="""You are acting as a git operations agent. You are precise, safety-conscious,
and follow the three-tier safety system:
- T1 (read-only): execute freely
- T2 (safe writes): execute on instruction, verify before and after
- T3 (destructive): preflight report only unless explicitly told to execute

{original dispatch prompt here}
"""
)
```

**Key differences from primary dispatch:**
- Uses `general-purpose` instead of `git-agent` subagent type
- Inlines the safety tier protocol directly in the prompt (the agent won't have git-agent's system prompt)
- Everything else stays the same - context gathering, templates, foreground/background choice

**When to use each:**

| Condition | Dispatch Method |
|-----------|----------------|
| `git-agent` available | Primary: `subagent_type="git-agent"` |
| `git-agent` unavailable | Fallback: `subagent_type="general-purpose"` with inlined protocol |
| No agent dispatch possible | Last resort: execute T2 operations inline (main context) |

The last-resort inline path should only be used for simple T2 operations (single commit, simple push). Complex workflows (PR creation, release, changelog) should always use an agent.

## Extended Operations

### Release Workflow

When user asks to "create a release", "bump version", or "tag a release":

1. **Inline (T1):** Check current version and commits since last tag
   ```bash
   git describe --tags --abbrev=0 2>/dev/null
   git log --oneline $(git describe --tags --abbrev=0 2>/dev/null)..HEAD
   ```

2. **Determine version bump:**
   - `feat:` commits -> minor bump
   - `fix:` commits -> patch bump
   - `BREAKING CHANGE:` or `!:` -> major bump
   - Or use version specified by user

3. **Dispatch to git-agent (T2):** Tag, push tag, create GitHub release with generated notes

### Changelog Generation

When user asks to "generate changelog" or "update CHANGELOG.md":

1. **Inline (T1):** Gather commit history for the range
2. **Dispatch to git-agent (T2):** Categorise commits, format as Keep a Changelog, write file

### PR Workflow (Full Cycle)

When user says "create a PR" or "open a PR":

1. **Inline (T1):** Check branch state, diff against main
2. **Gather context:** What was the user working on? What does the conversation tell us about the goal?
3. **Dispatch to git-agent (T2):** Create PR with contextual title and body
4. **Report:** PR number, URL, summary

### Branch Cleanup

When user asks to "clean up branches" or "delete merged branches":

1. **Inline (T1):** List merged branches
   ```bash
   git branch --merged main | grep -v "main\|master\|\*"
   ```
2. **Show list to user** - this is a T3 preflight (deletion)
3. **On confirmation:** Dispatch to git-agent to delete them

### Semantic Versioning Analysis

When user asks "what should the next version be":

1. **Inline (T1):** Analyse commits since last tag
2. Categorise by Conventional Commits
3. Report recommended bump with reasoning

### Conflict Resolution Support

When user encounters merge conflicts:

1. **Inline (T1):** `git status` to show conflicted files
2. **Inline (T1):** Read conflict markers in each file
3. **Present options:** ours, theirs, manual resolution
4. **After resolution:** Dispatch to git-agent (T2) for staging and continue

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
| Check status | T1 | Inline |
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
| Rebase | T3 | Agent (preflight) |
| Force push | T3 | Agent (preflight) |
| Reset --hard | T3 | Agent (preflight) |
| Delete branch | T3 | Agent (preflight) |
| Discard changes | T3 | Agent (preflight) |
| Merge to main | T3 | Agent (preflight) |

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
