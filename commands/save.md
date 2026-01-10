---
description: "Save session state - persist TodoWrite tasks, plan content, and git context. Complementary to /sync."
---

# Save - Session State Persistence

Persist your current session state for later restoration with `/sync`.

## Arguments

$ARGUMENTS

- No args: Save current state (TodoWrite, plan, git context)
- `"notes"`: Save with descriptive notes
- `--archive`: Archive current plan to `PLAN-<date>.md`, then save fresh

## What It Saves

| Data | Source | Destination |
|------|--------|-------------|
| TodoWrite tasks | Current session | `.claude/session-cache.json` |
| Plan content | Conversation context | `docs/PLAN.md` |
| Git context | `git status/log` | `.claude/session-cache.json` |
| User notes | Command argument | `.claude/session-cache.json` |
| Human-readable summary | Generated | `.claude/claude-progress.md` |

## Execution

### Step 1: Capture TodoWrite State

Read current TodoWrite tasks and categorize:
- Completed tasks
- In-progress tasks
- Pending tasks

### Step 2: Capture Plan Content

Extract from conversation context:
- Goal statements ("I want to...", "We need to...")
- Approach discussions ("Option A vs B")
- Decisions made ("Let's go with...")
- Steps identified ("First... then...")
- Open questions
- Blockers

### Step 3: Capture Git Context

```bash
git branch --show-current
git rev-parse --short HEAD
git log -1 --format="%s"
git status --porcelain | wc -l
```

### Step 4: Write Files

**`.claude/session-cache.json`** (machine-readable):
```json
{
  "version": "2.0",
  "timestamp": "2025-12-13T10:30:00Z",
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
    "uncommitted_count": 3
  },
  "notes": "Stopped at callback URL issue - need to fix redirect"
}
```

**`docs/PLAN.md`** (strategic plan):
```markdown
# Project Plan

**Goal**: Add user authentication with OAuth2
**Created**: 2025-12-13
**Last Updated**: 2025-12-13
**Status**: In Progress

## Context

Building OAuth2 authentication for the web app. Need to support Google
and GitHub providers initially, with ability to add more later.

## Approach

Using JWT tokens with refresh rotation. Chose this over session-based
auth for better scalability and API compatibility.

### Alternatives Considered
- **Session-based auth**: Simpler but doesn't scale well
- **Auth0/Clerk**: Good but adds external dependency

## Implementation Steps

### Completed
- [x] Step 1: Research OAuth providers [S]
  - Completed: 2025-12-12
  - Commit: `abc123` research: Compare OAuth providers

### In Progress
- [ ] Step 3: Implement OAuth flow [M]
  - Started: 2025-12-13
  - Notes: Working on callback URL handling

### Pending
- [ ] Step 4: Add token refresh [S]
- [ ] Step 5: Write integration tests [M]

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 12-12 | Use JWT over sessions | Better API compatibility |
| 12-12 | Start with Google only | Largest user base |

## Open Questions

- Should we support "Remember me" functionality?
- How long should refresh tokens last?

---
*Plan saved by `/save` command. Last updated: 2025-12-13 10:30*
```

**`.claude/claude-progress.md`** (human-readable):
```markdown
# Session Progress

**Saved**: 2025-12-13 10:30 AM
**Branch**: feature/auth

## Plan Context

**Goal**: Add user authentication with OAuth2
**Current Step**: Step 3 - Implement OAuth flow
**Progress**: 40% (2/5 steps)

## Tasks

- [x] Set up OAuth credentials
- [ ] Fix callback URL handling (in progress)
- [ ] Add token refresh logic

## Notes

> Stopped at callback URL issue - need to fix redirect

---
*Restore with: /sync*
```

## Output Format

```
Session saved

| Category | Value |
|----------|-------|
| **Plan** | Step 3/5 (40%) - Implement OAuth flow |
| **Tasks** | 1 completed, 1 in progress, 1 pending |
| **Git** | 3 uncommitted files on feature/auth |
| **Notes** | "Stopped at callback URL issue..." |

Files written:
  .claude/session-cache.json
  .claude/claude-progress.md
  docs/PLAN.md

Restore with: /sync
```

---

## Archive Mode: `/save --archive`

Archives current plan before saving fresh state.

### What It Does

1. Moves `docs/PLAN.md` to `docs/PLAN-<date>.md`
2. Clears `.claude/session-cache.json`
3. Saves new state (if any)

### Output

```
Archived: docs/PLAN.md -> docs/PLAN-2025-12-13.md

Session saved (fresh start)

Files written:
  docs/PLAN-2025-12-13.md (archived)
  .claude/session-cache.json (cleared)
```

---

## Usage Examples

```bash
# Save current state
/save

# Save with notes
/save "Stopped at auth module, need to fix redirect"

# Archive current plan and start fresh
/save --archive
```

---

## Status Markers

| Marker | Meaning |
|--------|---------|
| [x] | Completed |
| [ ] | Pending/In Progress |

## Effort Indicators

| Tag | Meaning |
|-----|---------|
| `[S]` | Small - Quick task |
| `[M]` | Medium - Moderate effort |
| `[L]` | Large - Significant effort |

---

## File Locations

| File | Purpose | Git-tracked? |
|------|---------|--------------|
| `docs/PLAN.md` | Strategic plan | Yes |
| `.claude/session-cache.json` | Session state | Optional |
| `.claude/claude-progress.md` | Human-readable progress | Optional |
| `docs/PLAN-<date>.md` | Archived plans | Yes |

---

## Integration

| Command | Relationship |
|---------|--------------|
| `/save` | **This command** - Persist state out |
| `/sync` | Complementary - Read state back in |
| Native `/plan` | Claude Code's planning mode (captured on save) |

---

## Notes

- **Non-destructive** - Never overwrites without archiving option
- **Git-aware** - Captures branch, commit, uncommitted changes
- **Human-readable** - Progress files work without Claude Code
- Ensure `.claude/` directory exists (created if missing)
