---
description: "Save session state - persist tasks (via TaskList), plan content, and git context. Complementary to /sync."
---

# Save - Session State Persistence

Persist your current session state for later restoration with `/sync`.

## Arguments

$ARGUMENTS

- No args: Save current state (tasks, plan, git context)
- `"notes"`: Save with descriptive notes
- `--archive`: Archive current plan to `PLAN-<date>.md`, then save fresh

## What It Saves

| Data | Source | Destination |
|------|--------|-------------|
| Tasks | TaskList API | `.claude/session-cache.json` |
| Plan content | Conversation context | `<plan-path>` (see Step 0) |
| Git context | `git status/log` | `.claude/session-cache.json` |
| User notes | Command argument | `.claude/session-cache.json` |
| Human-readable summary | Generated | `.claude/claude-progress.md` |

## Execution

### Step 0: Resolve Plan Path

Determine where the strategic plan file lives:

1. Check `.claude/settings.local.json` for a `plansDirectory` key
2. If not found, check `.claude/settings.json` for `plansDirectory`
3. If found, plan path = `<plansDirectory>/PLAN.md`
4. If not found, default to `docs/PLAN.md`

Store the resolved path for use in all subsequent steps.

Note: `plansDirectory` is a Claude Code setting (added in v2.1.9) for plan file storage.
Our strategic `PLAN.md` co-locates with native plans when this is set.

### Step 1: Capture Task State

Use TaskList and TaskGet to capture full task data:

```
1. Call TaskList to get all task IDs and summaries
2. For each task, call TaskGet to retrieve:
   - subject (title)
   - description (full details)
   - status (pending, in_progress, completed)
   - blockedBy (dependency IDs)
3. Store as array with index-based dependency mapping
```

Note: Tasks do not persist across sessions automatically. This is why /save exists.

### Step 2: Capture Plan Content

Extract from conversation context:
- Goal statements ("I want to...", "We need to...")
- Approach discussions ("Option A vs B")
- Decisions made ("Let's go with...")
- Steps identified ("First... then...")
- Open questions
- Blockers

### Step 3: Capture Git & Session Context

```bash
git branch --show-current
git rev-parse --short HEAD
git log -1 --format="%s"
git status --porcelain | wc -l

# Detect linked PR (requires gh CLI, fails gracefully)
gh pr view --json number,url --jq '{number,url}' 2>/dev/null
```

Additionally, capture your current session ID. You have access to this from your
runtime context - it is the unique identifier for this conversation session.

If `gh` is not installed or no PR exists for the current branch, skip the PR fields.

### Step 4: Write Files

**`.claude/session-cache.json`** (machine-readable):
```json
{
  "version": "3.1",
  "session_id": "<your-current-session-id>",
  "timestamp": "2025-12-13T10:30:00Z",
  "tasks": [
    {
      "subject": "Set up OAuth credentials",
      "description": "Configure Google OAuth app in GCP console",
      "activeForm": "Setting up OAuth credentials",
      "status": "completed",
      "blockedBy": []
    },
    {
      "subject": "Fix callback URL handling",
      "description": "OAuth callback URL mismatch in production config",
      "activeForm": "Fixing callback URL handling",
      "status": "in_progress",
      "blockedBy": [0]
    },
    {
      "subject": "Add token refresh",
      "description": "Implement JWT refresh token rotation",
      "activeForm": "Adding token refresh",
      "status": "pending",
      "blockedBy": [1]
    }
  ],
  "plan": {
    "file": "<resolved-plan-path>",
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
    "pr_number": 42,
    "pr_url": "https://github.com/user/repo/pull/42"
  },
  "memory": {
    "synced": true
  },
  "notes": "Stopped at callback URL issue - need to fix redirect"
}
```

**`<plan-path>`** (strategic plan, at resolved path):
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

### Step 5: Update Native Memory

Write a brief session summary to your auto memory directory as a safety net.
This ensures basic session context appears in the system prompt of future sessions,
even without running `/sync`.

**Target file:** Your auto memory `MEMORY.md` (path is in your system prompt).

**Procedure:**

1. Read `MEMORY.md` from your auto memory directory if it exists
2. If it contains a `## Last Session` section, replace that entire section
   (from the heading to the next `##` heading or end of file) with the updated content
3. If no such section exists, append it to the end of the file
4. If the file does not exist, create it with only this section

**`## Last Session` content** (keep under 10 lines):

```markdown
## Last Session

- **Goal**: [plan goal or "No active plan"]
- **Branch**: [current git branch]
- **Step**: [current plan step or "N/A"]
- **Session**: [session_id] (resume with `claude --resume <id>`)
- **PR**: [#number if linked, omit line if none]
- **Notes**: [user notes if provided, omit line if none]
- **Restore**: Run `/sync` to restore full task state
```

**Important:**
- Do NOT overwrite existing MEMORY.md content outside `## Last Session`
- Keep the section under 10 lines to preserve the 200-line MEMORY.md budget
- If the memory directory does not exist, create it with `mkdir -p`
- This is best-effort - warn but do not fail `/save` if memory write fails

## Output Format

```
Session saved

| Category | Value |
|----------|-------|
| **Plan** | Step 3/5 (40%) - Implement OAuth flow |
| **Tasks** | 1 completed, 1 in progress, 1 pending |
| **Git** | 3 uncommitted files on feature/auth |
| **PR** | #42 (https://github.com/user/repo/pull/42) |
| **Session** | abc123... (resumable via --resume) |
| **Notes** | "Stopped at callback URL issue..." |

Note: PR and Session rows are omitted when not available.

Files written:
  .claude/session-cache.json
  .claude/claude-progress.md
  <plan-path>
  ~/.claude/projects/.../memory/MEMORY.md (session summary)

Restore with: /sync
```

---

## Archive Mode: `/save --archive`

Archives current plan before saving fresh state.

### What It Does

1. Moves `<plan-path>` to `<plan-dir>/PLAN-<date>.md`
2. Clears `.claude/session-cache.json`
3. Saves new state (if any)

### Output

```
Archived: <plan-path> -> <plan-dir>/PLAN-2025-12-13.md

Session saved (fresh start)

Files written:
  <plan-dir>/PLAN-2025-12-13.md (archived)
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
| `<plan-path>` | Strategic plan (default: `docs/PLAN.md`) | Yes |
| `.claude/session-cache.json` | Session state | Optional |
| `.claude/claude-progress.md` | Human-readable progress | Optional |
| `<plan-dir>/PLAN-<date>.md` | Archived plans | Yes |
| `~/.claude/.../memory/MEMORY.md` | Session summary (auto-loaded) | No (user home) |

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
