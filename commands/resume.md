---
description: "Restore session context from checkpoint. Reads claude-state.json and claude-progress.md, shows what changed, suggests next action."
---

# Resume - Restore Session Context

Restore your session context from a previous checkpoint. Reads state files, shows what's changed since, and suggests the next action.

## Arguments

$ARGUMENTS

If no arguments, read from default `.claude/` location.

## What This Command Does

1. **Read State Files**
   - Load `.claude/claude-state.json`
   - Load `.claude/claude-progress.md`

2. **Analyze Changes Since Checkpoint**
   - Git commits since last checkpoint
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
⚠ No checkpoint found in .claude/

To create one, use: /checkpoint
```

### Step 2: Read State

Parse `.claude/claude-state.json`:
- Extract timestamp
- Extract task arrays
- Extract context (branch, last commit, notes)

### Step 3: Calculate Time Since Checkpoint

Compare checkpoint timestamp to current time:
- Format as human-readable ("2 hours ago", "3 days ago")

### Step 4: Analyze Git Changes

```bash
# Commits since checkpoint
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
# Session Resumed

**Checkpoint from**: <timestamp> (<relative time>)
**Branch**: <branch>

## Since Last Checkpoint
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
# Basic resume
/resume

# Resume from specific directory
/resume path/to/project

# Resume with verbose git log
/resume --verbose
```

## Flags

| Flag | Effect |
|------|--------|
| `--verbose` | Show full git log since checkpoint |
| `--no-restore` | Show state without restoring TodoWrite |
| `--clear` | Clear checkpoint after resuming |

## Edge Cases

### No Checkpoint Found
```
⚠ No checkpoint found

This could mean:
1. You haven't checkpointed yet (use /checkpoint)
2. Wrong directory (check pwd)
3. State files were deleted

To start fresh, just begin working normally.
```

### Stale Checkpoint (>7 days)
```
⚠ Checkpoint is 12 days old

A lot may have changed. Consider:
1. Review git log manually
2. Start fresh if context is lost
3. Resume anyway with: /resume --force
```

### Branch Changed
```
⚠ Branch changed since checkpoint

Checkpoint branch: feature/old-branch
Current branch: feature/new-branch

The checkpoint may not be relevant. Options:
1. Switch back: git checkout feature/old-branch
2. Resume anyway (tasks may still apply)
3. Clear and start fresh: /resume --clear
```

## Integration with /checkpoint

These commands form a pair:

```
Session 1:
  [work on tasks]
  /checkpoint "Stopped at auth module"

Session 2:
  /resume
  → Shows: "In progress: Auth module refactor"
  → Notes: "Stopped at auth module"
  → Suggests: "Continue with auth module testing"
```

## Notes

- Resume automatically populates TodoWrite
- Use `--no-restore` to preview without changing state
- Clear old checkpoints periodically with `--clear`
- Works across machines if .claude/ is committed
