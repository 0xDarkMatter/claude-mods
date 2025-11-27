---
name: git-workflow
description: Enhanced git operations using lazygit (TUI for staging/commits), gh (GitHub CLI for PRs/issues), and delta (beautiful diffs). Triggers on: stage changes, create PR, review PR, check issues, git diff, commit interactively, GitHub operations.
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

# Create issue
gh issue create --title "Bug: X" --body "Steps to reproduce"

# List issues
gh issue list --label bug

# View repo in browser
gh repo view --web
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

## When to Use

- Interactive staging of changes
- Creating pull requests from terminal
- Reviewing PRs and issues
- Visual diff viewing
- Branch management
- GitHub workflow automation
