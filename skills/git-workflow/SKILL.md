---
name: git-workflow
description: "Enhanced git operations using lazygit, gh (GitHub CLI), and delta. Triggers on stage changes, create PR, review PR, check issues, git diff, commit interactively, GitHub operations, rebase, stash, bisect."
---

# Git Workflow

## Purpose
Streamline git operations with visual tools and GitHub CLI integration.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| lazygit | `lazygit` | Interactive git TUI |
| gh | `gh pr create` | GitHub CLI operations |
| delta | `git diff \| delta` | Beautiful diff viewing |

## Usage Examples

### Interactive Git with lazygit

```bash
# Open git TUI
lazygit

# Key bindings in lazygit:
# Space - stage/unstage file
# c - commit
# p - push
# P - pull
# b - branch operations
# r - rebase menu
# s - stash menu
# ? - help
```

### GitHub CLI with gh

```bash
# Create pull request
gh pr create --title "Feature: Add X" --body "Description"

# Create PR with web editor
gh pr create --web

# List open PRs
gh pr list

# View PR details
gh pr view 123

# Check out PR locally
gh pr checkout 123

# Merge PR
gh pr merge 123 --squash --delete-branch

# Create issue
gh issue create --title "Bug: X" --body "Steps to reproduce"

# List issues
gh issue list --label bug

# View repo in browser
gh repo view --web

# Run workflow
gh workflow run deploy.yml

# View workflow runs
gh run list --workflow=ci.yml
```

### Beautiful Diffs with delta

```bash
# View diff with delta
git diff | delta

# Side-by-side view
git diff | delta --side-by-side

# Configure git to use delta by default
git config --global core.pager delta
```

## Interactive Rebase

Clean up commit history before merging.

```bash
# Rebase last N commits
git rebase -i HEAD~5

# Rebase onto main
git rebase -i main

# Commands in interactive rebase:
# pick   - use commit as-is
# reword - edit commit message
# edit   - stop to amend commit
# squash - meld into previous commit (keep message)
# fixup  - meld into previous (discard message)
# drop   - remove commit
```

### Common Rebase Workflows

```bash
# Squash all feature commits into one
git rebase -i main
# Change all but first 'pick' to 'squash'

# Reorder commits
git rebase -i HEAD~3
# Move lines to change order

# Continue after resolving conflicts
git rebase --continue

# Abort if things go wrong
git rebase --abort
```

## Stash Operations

Save work temporarily without committing.

```bash
# Save current changes
git stash

# Save with description
git stash push -m "WIP: feature X"

# Stash including untracked files
git stash -u

# List all stashes
git stash list

# Apply most recent stash (keep in stash list)
git stash apply

# Apply and remove from list
git stash pop

# Apply specific stash
git stash apply stash@{2}

# Show stash contents
git stash show -p stash@{0}

# Drop specific stash
git stash drop stash@{1}

# Clear all stashes
git stash clear
```

### Stash Workflow Pattern

```bash
# Mid-feature, need to switch branches
git stash push -m "WIP: auth flow"
git checkout hotfix-branch
# ... fix bug ...
git checkout feature-branch
git stash pop
```

## Git Bisect

Find the commit that introduced a bug using binary search.

```bash
# Start bisect
git bisect start

# Mark current commit as bad
git bisect bad

# Mark known good commit
git bisect good v1.0.0

# Git checks out middle commit, test it, then:
git bisect good  # if this commit is OK
git bisect bad   # if this commit has the bug

# Repeat until git finds the culprit
# "abc123 is the first bad commit"

# End bisect session
git bisect reset
```

### Automated Bisect

```bash
# Run a test script automatically
git bisect start HEAD v1.0.0
git bisect run npm test
# Git will find first failing commit automatically
```

## Cherry-Pick

Apply specific commits to current branch.

```bash
# Apply single commit
git cherry-pick abc123

# Apply multiple commits
git cherry-pick abc123 def456

# Apply range of commits
git cherry-pick abc123..xyz789

# Cherry-pick without committing (stage only)
git cherry-pick -n abc123

# Continue after resolving conflicts
git cherry-pick --continue

# Abort cherry-pick
git cherry-pick --abort
```

## Worktrees

Work on multiple branches simultaneously without stashing.

```bash
# Create worktree for a branch
git worktree add ../project-hotfix hotfix-branch

# Create worktree with new branch
git worktree add ../project-feature -b new-feature

# List worktrees
git worktree list

# Remove worktree
git worktree remove ../project-hotfix

# Prune stale worktree info
git worktree prune
```

### Worktree Workflow

```bash
# Main repo at ~/project
# Need to work on hotfix while keeping feature work
git worktree add ~/project-hotfix hotfix-branch
cd ~/project-hotfix
# ... make fixes, commit, push ...
cd ~/project
git worktree remove ~/project-hotfix
```

## Reflog (Recovery)

Find and recover "lost" commits.

```bash
# Show reflog (all HEAD movements)
git reflog

# Show reflog for specific branch
git reflog show feature-branch

# Recover deleted branch
git reflog
# Find commit hash before deletion
git checkout -b recovered-branch abc123

# Undo a rebase
git reflog
# Find commit before rebase started
git reset --hard HEAD@{5}

# Recover after hard reset
git reflog
git reset --hard HEAD@{1}
```

## Conflict Resolution

```bash
# See which files have conflicts
git status

# Use merge tool
git mergetool

# Accept all changes from one side
git checkout --ours file.txt    # Keep current branch
git checkout --theirs file.txt  # Keep incoming branch

# After resolving
git add file.txt
git rebase --continue  # or git merge --continue
```

## Quick Reference

| Task | Command |
|------|---------|
| Interactive rebase | `git rebase -i HEAD~N` |
| Stash changes | `git stash push -m "msg"` |
| Apply stash | `git stash pop` |
| Find bug commit | `git bisect start` |
| Cherry-pick commit | `git cherry-pick <hash>` |
| Parallel worktree | `git worktree add <path> <branch>` |
| Recover commits | `git reflog` |
| Create PR | `gh pr create` |
| Merge PR | `gh pr merge --squash` |

## When to Use

- Interactive staging of changes
- Creating pull requests from terminal
- Reviewing PRs and issues
- Visual diff viewing
- Branch management
- Cleaning up commit history (rebase)
- Temporary work saving (stash)
- Bug hunting (bisect)
- Parallel feature work (worktrees)
- Recovering lost work (reflog)
