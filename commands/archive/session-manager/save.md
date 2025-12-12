---
description: "Save session state with plan awareness. Persists TodoWrite tasks, current plan step, and git context for session continuity."
---

# Save - Session State Persistence

Save your current session state before ending work. Captures TodoWrite tasks, current plan step, and git context.

## Architecture

```
/save "optional notes"
    │
    ├─→ Capture TodoWrite state
    │     └─ completed, in_progress, pending tasks
    │
    ├─→ Capture plan context (NEW)
    │     ├─ Current step from docs/PLAN.md
    │     └─ Plan progress percentage
    │
    ├─→ Capture git context
    │     ├─ Branch, last commit
    │     └─ Uncommitted changes
    │
    └─→ Write state files
          ├─ .claude/claude-state.json (machine)
          └─ .claude/claude-progress.md (human)
```

## Why This Exists

Claude Code's native features don't persist across sessions:

| Feature | Persists? | Location |
|---------|-----------|----------|
| Conversation history | Yes | Internal (use `--resume`) |
| CLAUDE.md context | Yes | `./CLAUDE.md` |
| TodoWrite tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

This command bridges the gap by saving what Claude Code doesn't.

## Output Files

### .claude/claude-state.json (v2.0)

```json
{
  "version": "2.0",
  "timestamp": "2025-11-27T10:30:00Z",

  "todos": {
    "completed": ["Set up OAuth credentials"],
    "in_progress": ["Fix callback URL handling"],
    "pending": ["Add token refresh"]
  },

  "plan": {
    "file": "docs/PLAN.md",
    "goal": "Add user authentication with OAuth2",
    "current_step": "Step 3: Implement OAuth flow",
    "current_step_index": 3,
    "total_steps": 5,
    "progress_percent": 40
  },

  "git": {
    "branch": "feature/auth",
    "last_commit": "abc123f",
    "last_commit_message": "feat: Add OAuth config",
    "uncommitted_count": 3,
    "uncommitted_files": [
      "src/auth/oauth.ts",
      "src/auth/callback.ts",
      "tests/auth.test.ts"
    ]
  },

  "notes": "Stopped at callback URL issue - need to fix redirect"
}
```

### .claude/claude-progress.md

```markdown
# Session Progress

**Saved**: 2025-11-27 10:30 AM
**Branch**: feature/auth

## Plan Context

**Goal**: Add user authentication with OAuth2
**Current Step**: ◐ Step 3 - Implement OAuth flow [M]
**Progress**: ██████░░░░ 40% (2/5 steps)

## Tasks

### Completed
- ✓ Set up OAuth credentials

### In Progress
- ◐ Fix callback URL handling

### Pending
- ○ Add token refresh

## Git State

- Last commit: `abc123f` feat: Add OAuth config
- Uncommitted: 3 files

## Notes

> Stopped at callback URL issue - need to fix redirect

---
*Restore with: /load*
```

## Execution Steps

### Step 1: Gather TodoWrite State

Map current TodoWrite tasks by status:
- `completed` → completed array
- `in_progress` → in_progress array
- `pending` → pending array

### Step 2: Gather Plan Context (NEW)

```bash
# Check if plan exists
cat docs/PLAN.md 2>/dev/null
```

Parse from docs/PLAN.md:
- Goal line: `**Goal**:`
- Current step: line with `◐` marker
- Count `✓` for completed, total for progress

### Step 3: Gather Git Context

```bash
git branch --show-current
git log -1 --format="%h %s"
git status --porcelain
git diff --stat
```

### Step 4: Create Directory

```bash
mkdir -p .claude
```

### Step 5: Write State Files

Write both:
- `.claude/claude-state.json` - machine-readable
- `.claude/claude-progress.md` - human-readable

### Step 6: Confirm

```
✓ Session saved

┌─ Saved State ──────────────────────────────────────────────────────────────────────────────────┐
│ Plan: Step 3/5 (40%) - Implement OAuth flow                                                    │
│ Tasks: 1 completed, 1 in progress, 1 pending                                                   │
│ Git: 3 uncommitted files                                                                       │
│ Notes: "Stopped at callback URL issue..."                                                      │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

Files:
  • .claude/claude-state.json
  • .claude/claude-progress.md

Restore with: /load
```

## Usage Examples

```bash
# Basic save
/save

# Save with notes
/save "Stopped at callback URL issue"

# Save and commit state files
/save --commit

# Save with notes and commit
/save "Ready for review" --commit
```

## Flags

| Flag | Effect |
|------|--------|
| `--commit` | Git commit state files after saving |
| `--force` | Overwrite without confirmation |
| `--no-plan` | Skip plan context capture |

## Integration

Part of the session management suite:

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    Session Lifecycle                                           │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                │
│          START                        WORK                          END                        │
│            │                           │                             │                         │
│            ▼                           ▼                             ▼                         │
│         /load ─────────────→ /status (anytime) ─────────────→ /save                           │
│            │                           │                             │                         │
│         Restore                     Dashboard                     Persist                      │
│         context                       view                        state                        │
│                                                                                                │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Notes

- Always captures plan context if docs/PLAN.md exists
- State files are gitignored by default
- Use `--commit` to track state in git
- Notes are preserved and shown on `/load`
