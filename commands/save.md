---
description: "Save session state before ending. Creates claude-state.json and claude-progress.md for session continuity."
---

# Save - Session State Persistence

Save your current session state before ending work. Creates both machine-readable and human-readable progress files.

## Arguments

$ARGUMENTS

If no arguments, save current TodoWrite state and git context.

## What This Command Does

1. **Capture Current State**
   - Read current TodoWrite tasks (completed, in-progress, pending)
   - Get git branch and recent commits
   - Detect uncommitted changes
   - Note current working context

2. **Write State Files**
   - `.claude/claude-state.json` - Machine-readable state
   - `.claude/claude-progress.md` - Human-readable summary

3. **Optional Git Commit**
   - If `--commit` flag: commit state files with message

## Output Files

### .claude/claude-state.json

```json
{
  "version": "1.0",
  "timestamp": "<ISO timestamp>",
  "completed": ["task1", "task2"],
  "in_progress": ["task3"],
  "pending": ["task4", "task5"],
  "context": {
    "branch": "<current branch>",
    "last_commit": "<commit hash>",
    "last_commit_message": "<message>",
    "modified_files": ["file1.ts", "file2.ts"],
    "notes": "<any user-provided notes>"
  }
}
```

### .claude/claude-progress.md

```markdown
# Session Progress

**Last Updated**: <timestamp>
**Branch**: <branch name>

## Completed
- [x] Task 1
- [x] Task 2

## In Progress
- [ ] Task 3
  - Notes: <context>

## Next Steps
- Task 4
- Task 5

## Context
- Last commit: <hash> "<message>"
- Uncommitted: <count> files
```

## Usage Examples

```bash
# Basic save
/save

# Save with notes
/save "Stopped mid-refactor, auth module needs testing"

# Save and commit
/save --commit

# Save with notes and commit
/save "Ready for review" --commit
```

## Execution Steps

### Step 1: Gather State

```bash
# Get git info
git branch --show-current
git log -1 --format="%H %s"
git status --porcelain
```

### Step 2: Read TodoWrite State

Access the current TodoWrite state from the conversation context. Map statuses:
- `completed` → Completed section
- `in_progress` → In Progress section
- `pending` → Next Steps section

### Step 3: Create Directory

```bash
mkdir -p .claude
```

### Step 4: Write JSON State

Create `.claude/claude-state.json` with:
- Version: "1.0"
- Timestamp: Current ISO timestamp
- All task arrays from TodoWrite
- Git context (branch, last commit, modified files)
- User notes if provided in arguments

### Step 5: Write Markdown Summary

Create `.claude/claude-progress.md` with human-readable format:
- Header with timestamp and branch
- Checkbox lists for each status
- Context section with git info
- Any notes provided

### Step 6: Optional Commit

If `--commit` flag present:
```bash
git add .claude/claude-state.json .claude/claude-progress.md
git commit -m "chore: save session state"
```

## Output

After creating files, report:

```
✓ Session saved

State saved to:
  • .claude/claude-state.json
  • .claude/claude-progress.md

Summary:
  • Completed: X tasks
  • In Progress: Y tasks
  • Pending: Z tasks
  • Uncommitted files: N

Load with: /load
```

## Flags

| Flag | Effect |
|------|--------|
| `--commit` | Git commit the state files after creating |
| `--force` | Overwrite existing state without confirmation |

## Notes

- State files are gitignored by default (add to .gitignore if needed)
- Use `/load` to restore state in a new session
- Save frequently during long tasks
- Notes are preserved across sessions
