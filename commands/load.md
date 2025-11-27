---
description: "Load session context from saved state. Reads claude-state.json and claude-progress.md, shows what changed, suggests next action."
---

# Load - Restore Session Context

Load your session context from a previous save. Reads state files, shows what's changed since, and suggests the next action.

## Why This Exists

This command pairs with `/save` to implement structured session continuity. While Claude Code's `--resume` restores conversation history, it **does not restore TodoWrite task state**.

From Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

`/load` reads those structured updates and restores your working context:
- **Tasks** are restored to TodoWrite
- **Git context** shows what changed since you left
- **Notes** remind you where you stopped
- **Suggested action** helps you pick up immediately

### How It Differs from `--resume`

| `claude --resume` | `/load` |
|-------------------|---------|
| Restores conversation history | Restores task state from files |
| Local to your machine | Portable (git-trackable) |
| Automatic | Explicit (you control when) |
| Full context | Structured summary |

**Use both together**: `claude --resume` for conversation context, `/load` for task state.

## Arguments

$ARGUMENTS

If no arguments, read from default `.claude/` location.

## What This Command Does

1. **Read State Files**
   - Load `.claude/claude-state.json`
   - Load `.claude/claude-progress.md`

2. **Analyze Changes Since Save**
   - Git commits since last save
   - File modifications
   - Time elapsed

3. **Restore TodoWrite State**
   - Populate TodoWrite with saved tasks
   - Preserve status (completed, in-progress, pending)

4. **Suggest Next Action**
   - Based on in-progress tasks
   - Highlight blockers or notes

## Execution Steps

### Step 1: Check for State Files

```bash
ls -la .claude/claude-state.json .claude/claude-progress.md 2>/dev/null
```

If missing, report:
```
⚠ No saved state found in .claude/

To create one, use: /save
```

### Step 2: Read State

Parse `.claude/claude-state.json`:
- Extract timestamp
- Extract task arrays
- Extract context (branch, last commit, notes)

### Step 3: Calculate Time Since Save

Compare save timestamp to current time:
- Format as human-readable ("2 hours ago", "3 days ago")

### Step 4: Analyze Git Changes

```bash
# Commits since save
git log --oneline <last_commit>..HEAD

# Current status
git status --short
```

### Step 5: Restore TodoWrite

Use TodoWrite tool to restore tasks:
- Map `completed` → status: "completed"
- Map `in_progress` → status: "in_progress"
- Map `pending` → status: "pending"

### Step 6: Display Summary

```markdown
# Session Loaded

**Saved**: <timestamp> (<relative time>)
**Branch**: <branch>

## Since Last Save
- <N> new commits
- <M> files modified
- <time> elapsed

## Restored Tasks

### In Progress
- [ ] Task that was being worked on

### Pending
- Task 1
- Task 2

### Completed (this session)
- [x] Previously completed task

## Notes from Last Session
> <any notes saved>

## Suggested Next Action
Based on your in-progress task: **<task name>**

<Context or suggestion based on what was being worked on>
```

## Usage Examples

```bash
# Basic load
/load

# Load from specific directory
/load path/to/project

# Load with verbose git log
/load --verbose
```

## Flags

| Flag | Effect |
|------|--------|
| `--verbose` | Show full git log since save |
| `--no-restore` | Show state without restoring TodoWrite |
| `--clear` | Clear saved state after loading |

## Edge Cases

### No Saved State Found
```
⚠ No saved state found

This could mean:
1. You haven't saved yet (use /save)
2. Wrong directory (check pwd)
3. State files were deleted

To start fresh, just begin working normally.
```

### Stale State (>7 days)
```
⚠ Saved state is 12 days old

A lot may have changed. Consider:
1. Review git log manually
2. Start fresh if context is lost
3. Load anyway with: /load --force
```

### Branch Changed
```
⚠ Branch changed since save

Saved branch: feature/old-branch
Current branch: feature/new-branch

The saved state may not be relevant. Options:
1. Switch back: git checkout feature/old-branch
2. Load anyway (tasks may still apply)
3. Clear and start fresh: /load --clear
```

## Integration with /save

These commands form a pair:

```
Session 1:
  [work on tasks]
  /save "Stopped at auth module"

Session 2:
  /load
  → Shows: "In progress: Auth module refactor"
  → Notes: "Stopped at auth module"
  → Suggests: "Continue with auth module testing"
```

## Notes

- Load automatically populates TodoWrite
- Use `--no-restore` to preview without changing state
- Clear old saves periodically with `--clear`
- Works across machines if .claude/ is committed
