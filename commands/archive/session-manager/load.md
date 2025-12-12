---
description: "Restore session context with plan awareness. Shows plan progress, restores TodoWrite tasks, displays what changed since last save."
---

# Load - Restore Session Context

Restore your session context from a previous save. Shows plan progress, restores tasks, and displays what's changed.

## Architecture

```
/load
    │
    ├─→ Read .claude/claude-state.json
    │     ├─ TodoWrite tasks
    │     ├─ Plan context
    │     └─ Git context at save time
    │
    ├─→ Analyze changes since save
    │     ├─ New commits
    │     ├─ File modifications
    │     └─ Plan updates
    │
    ├─→ Restore TodoWrite state
    │     └─ Populate with saved tasks
    │
    └─→ Display unified summary
          ├─ Plan context
          ├─ Restored tasks
          ├─ What changed
          └─ Suggested next action
```

## Output Format

```
📂 Session Loaded

┌─ Time ─────────────────────────────────────────────────────────────────────────────────────────┐
│ Saved: 2 hours ago (2025-11-27 10:30 AM)                                                       │
│ Branch: feature/auth                                                                           │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Plan Context ─────────────────────────────────────────────────────────────────────────────────┐
│ Goal: Add user authentication with OAuth2                                                      │
│                                                                                                │
│ ✓ Step 1: Research OAuth providers                                                             │
│ ✓ Step 2: Set up Google OAuth app                                                              │
│ ◐ Step 3: Implement OAuth flow  ← YOU WERE HERE                                                │
│ ○ Step 4: Add token refresh                                                                    │
│ ○ Step 5: Write integration tests                                                              │
│                                                                                                │
│ Progress: ██████░░░░ 40% (2/5)                                                                 │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Restored Tasks ───────────────────────────────────────────────────────────────────────────────┐
│ ◐ Fix callback URL handling                                                                    │
│ ○ Add token refresh logic                                                                      │
│ ✓ Set up OAuth credentials                                                                     │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Since Last Save ──────────────────────────────────────────────────────────────────────────────┐
│ Commits: 0 new                                                                                 │
│ Files: 3 still uncommitted (+45/-12)                                                           │
│ Plan: unchanged                                                                                │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Notes ────────────────────────────────────────────────────────────────────────────────────────┐
│ "Stopped at callback URL issue - need to fix redirect"                                         │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Suggested Next Action ────────────────────────────────────────────────────────────────────────┐
│ Continue with: Fix callback URL handling                                                       │
│                                                                                                │
│ Context: You were implementing OAuth flow (Plan Step 3) and stopped at a redirect issue.       │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Execution Steps

### Step 1: Check for State Files

```bash
ls -la .claude/claude-state.json 2>/dev/null
```

If missing:
```
┌─ Session ──────────────────────────────────────────────────────────────────────────────────────┐
│ ⚠  State: No saved state found in .claude/claude-state.json                                    │
│                                                                                                │
│    To create one, use: /save                                                                   │
│    Or check current status: /status                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Step 2: Read State

Parse `.claude/claude-state.json`:
- Extract todos (completed, in_progress, pending)
- Extract plan context (goal, current step, progress)
- Extract git context (branch, last commit)
- Extract notes

### Step 3: Calculate Time Since Save

```bash
# Compare timestamps
# Format as: "2 hours ago", "3 days ago"
```

### Step 4: Analyze Changes

```bash
# Commits since save
git log --oneline <saved_commit>..HEAD

# Current uncommitted
git status --porcelain

# Check if plan was modified
git log -1 --format="%H" -- docs/PLAN.md
```

### Step 5: Restore TodoWrite

Use TodoWrite tool:
```json
{
  "todos": [
    {"content": "Fix callback URL handling", "status": "in_progress"},
    {"content": "Add token refresh logic", "status": "pending"},
    {"content": "Set up OAuth credentials", "status": "completed"}
  ]
}
```

### Step 6: Generate Suggestion

Based on saved state:
- If `in_progress` task exists → "Continue with: <task>"
- If all complete → "Start next pending task"
- If blocked → "Resolve blocker: <blocker>"

## Edge Cases

### Stale State (>7 days)

```
⚠ Saved state is 12 days old

A lot may have changed since then.

Options:
  1. Load anyway (tasks may still be relevant)
  2. Check current status: /status
  3. Start fresh: /load --clear
```

### Branch Changed

```
⚠ Branch changed since save

Saved on: feature/old-branch
Current:  feature/new-branch

The saved context may not apply. Options:
  1. Switch back: git checkout feature/old-branch
  2. Load anyway (some tasks may apply)
  3. Clear and start fresh: /load --clear
```

### Plan Updated Since Save

```
ℹ Plan was updated since you saved

Changes to docs/PLAN.md:
  • Step 3 marked complete (was in-progress)
  • Step 4 now in-progress

Your saved context shows Step 3, but plan shows Step 4.
Consider: /plan --review to see current state
```

## Flags

| Flag | Effect |
|------|--------|
| `--verbose` | Show full git log since save |
| `--no-restore` | Preview without restoring TodoWrite |
| `--clear` | Clear saved state after loading |
| `--force` | Load even if stale or branch mismatch |

## Usage Examples

```bash
# Basic load
/load

# Preview without restoring
/load --no-restore

# Load with full git history
/load --verbose

# Load and clear state
/load --clear
```

## Integration

Part of the session management suite:

```
Session Lifecycle
─────────────────────────────────────────────────────────────────────────────────────────────────

  ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                              │
  │         ┌─────────┐                   ┌─────────┐                   ┌─────────┐              │
  │         │  START  │                   │  WORK   │                   │   END   │              │
  │         └────┬────┘                   └────┬────┘                   └────┬────┘              │
  │              │                             │                             │                   │
  │              ▼                             ▼                             ▼                   │
  │         ┌────────┐                   ┌──────────┐                   ┌────────┐              │
  │         │ /load  │──────────────────▶│ /status  │──────────────────▶│ /save  │              │
  │         └────────┘                   └──────────┘                   └────┬───┘              │
  │              │                             │                             │                   │
  │           Restore                      Dashboard                      Persist               │
  │           context                        view                          state                │
  │              │                             │                             │                   │
  │              └─────────────────────────────┴─────────────────────────────┘                   │
  │                                            │                                                 │
  │                                            ▼                                                 │
  │                               .claude/claude-state.json                                      │
  │                               docs/PLAN.md                                                   │
  │                                            │                                                 │
  └────────────────────────────────────────────┘                                                 │
                                    Next Session                                                 │
```

## Notes

- Automatically restores TodoWrite unless `--no-restore`
- Shows plan context from saved state + current plan
- Detects and warns about state/branch mismatches
- Notes from `/save` are prominently displayed
