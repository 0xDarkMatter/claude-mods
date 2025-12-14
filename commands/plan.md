---
description: "Unified project planning and session continuity. Create plans, save/load state, track progress. Smart defaults with context detection."
---

# Plan - Project Planning & Session Continuity

Unified command for strategic planning and session state management. Creates persistent plans, saves/loads session state, and provides intelligent context-aware defaults.

## Arguments

$ARGUMENTS

- No args: **Interactive mode** - detects context, suggests action
- `<goal>`: Create or update plan for goal
- `save "notes"` or `--save`: Save session state (TodoWrite, plan context, git)
- `load` or `--load`: Restore session state from previous save
- `status` or `--status`: Quick read-only status view
- `sync` or `--sync`: Auto-update plan progress from git commits
- `diff` or `--diff`: Show what changed since last update
- `clear` or `--clear`: Archive current plan and start fresh

**Note:** Subcommands work with or without the `--` prefix.

## Architecture

```
/plan [goal] [--save|--load|--status|--sync|--clear]
    │
    ├─→ No args: INTERACTIVE MODE
    │     │
    │     ├─ No plan exists?
    │     │   └─ "No plan found. Create one: /plan 'your goal'"
    │     │
    │     ├─ Plan exists + saved state exists?
    │     │   ├─ State is stale (>2 hours)?
    │     │   │   └─ "Welcome back! Load previous session? (Y/n)"
    │     │   └─ State is fresh?
    │     │       └─ Show status + "Continue: <in_progress_task>"
    │     │
    │     └─ Plan exists + no saved state?
    │         └─ Show status + "Save before leaving: /plan --save"
    │
    ├─→ /plan "goal"
    │     ├─ Capture conversation context (goals, decisions, approaches)
    │     ├─ Capture git context (branch, uncommitted, recent commits)
    │     ├─ Merge with existing docs/PLAN.md if present
    │     └─ Write updated plan
    │
    ├─→ /plan --save "notes"
    │     ├─ Capture TodoWrite state
    │     ├─ Capture current plan step
    │     ├─ Capture git context
    │     ├─ Write .claude/session-cache.json
    │     └─ Write .claude/claude-progress.md (human-readable)
    │
    ├─→ /plan --load
    │     ├─ Read .claude/session-cache.json
    │     ├─ Restore TodoWrite tasks
    │     ├─ Show what changed since save
    │     └─ Suggest next action
    │
    ├─→ /plan --status
    │     ├─ Read docs/PLAN.md
    │     ├─ Read TodoWrite state
    │     ├─ Read git state
    │     └─ Display unified view
    │
    ├─→ /plan --sync
    │     ├─ Parse recent git commits
    │     ├─ Match to plan steps
    │     └─ Auto-update step status
    │
    └─→ /plan --clear
          ├─ Archive to docs/PLAN-<date>.md
          └─ Start fresh
```

---

## Interactive Mode (No Args)

When you run `/plan` with no arguments, it detects your context and suggests the right action:

### Scenario 1: No Plan Exists

```
📋 Plan Status

No plan found at docs/PLAN.md

Get started:
  /plan "your project goal"    Create a new plan
  /plan --status               View current tasks and git state
```

### Scenario 2: Plan Exists, Saved State Available

```
📋 Plan Status

┌─ Welcome Back ─────────────────────────────────────────────────────────────────┐
│ Last saved: 3 hours ago                                                        │
│ Branch: feature/auth                                                           │
│                                                                                 │
│ You were working on:                                                           │
│   ◐ Step 3: Implement OAuth flow                                               │
│   Task: Fix callback URL handling                                              │
│                                                                                 │
│ Notes: "Stopped at redirect issue"                                             │
└────────────────────────────────────────────────────────────────────────────────┘

Load previous session? [Y/n]
```

### Scenario 3: Plan Exists, No Saved State

```
📋 Plan Status

┌─ Plan ─────────────────────────────────────────────────────────────────────────┐
│ Goal: Add user authentication with OAuth2                                      │
│                                                                                 │
│ ✓ Step 1: Research OAuth providers                                             │
│ ✓ Step 2: Set up Google OAuth app                                              │
│ ◐ Step 3: Implement OAuth flow  ← CURRENT                                      │
│ ○ Step 4: Add token refresh                                                    │
│ ○ Step 5: Write integration tests                                              │
│                                                                                 │
│ Progress: ██████░░░░ 40% (2/5)                                                 │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Tasks ────────────────────────────────────────────────────────────────────────┐
│ ◐ Fix callback URL handling                                                    │
│ ○ Add token refresh logic                                                      │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Git ──────────────────────────────────────────────────────────────────────────┐
│ Branch: feature/auth                                                           │
│ Uncommitted: 3 files (+45/-12)                                                 │
└────────────────────────────────────────────────────────────────────────────────┘

Suggestions:
  → Continue: Fix callback URL handling
  → Save before leaving: /plan --save
```

---

## Create/Update Plan: `/plan "goal"`

Creates or updates `docs/PLAN.md` with strategic planning.

### What It Captures

**From conversation:**
- Goal statements ("I want to...", "We need to...")
- Approach discussions ("Option A vs B")
- Decisions made ("Let's go with...")
- Steps identified ("First... then...")
- Open questions

**From git:**
- Current branch
- Uncommitted changes
- Recent commits

### Plan Format: `docs/PLAN.md`

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
- ✓ Step 1: Research OAuth providers [S]
  - Completed: 2025-12-12
  - Commit: `abc123` research: Compare OAuth providers

- ✓ Step 2: Set up Google OAuth app [S]
  - Completed: 2025-12-12
  - Commit: `def456` feat: Add Google OAuth credentials

### In Progress
- ◐ Step 3: Implement OAuth flow [M]
  - Started: 2025-12-13
  - Notes: Working on callback URL handling

### Pending
- ○ Step 4: Add token refresh [S]
- ○ Step 5: Write integration tests [M]

## Uncommitted Changes

```
📊 Working Tree Status:
  Modified:  3 files (+127/-45)

  Files:
  • src/auth/oauth.ts        +89/-12
  • src/auth/callback.ts     +25/-20
  • tests/auth.test.ts       +13/-13
```

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 12-12 | Use JWT over sessions | Better API compatibility |
| 12-12 | Start with Google only | Largest user base |

## Blockers

None currently.

## Open Questions

- Should we support "Remember me" functionality?
- How long should refresh tokens last?

## Success Criteria

- [ ] Users can sign in with Google
- [ ] Tokens refresh automatically
- [ ] 90% test coverage on auth module

---
*Plan managed by `/plan` command. Last captured: 2025-12-13 10:30*
```

### Execution Steps

```bash
# Step 1: Capture git context
git branch --show-current
git status --short
git diff --stat
git log --oneline -5

# Step 2: Check existing plan
cat docs/PLAN.md 2>/dev/null

# Step 3: Analyze conversation for plan-related content
# (Extract goals, decisions, approaches, steps)

# Step 4: Merge and write
mkdir -p docs
# Write updated docs/PLAN.md
```

---

## Save State: `/plan --save "notes"`

Persists session state for later restoration.

### What It Saves

| Data | Source | Destination |
|------|--------|-------------|
| TodoWrite tasks | Current session | `.claude/session-cache.json` |
| Current plan step | `docs/PLAN.md` | `.claude/session-cache.json` |
| Git context | `git status/log` | `.claude/session-cache.json` |
| User notes | Command argument | `.claude/session-cache.json` |

### Output Files

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

**`.claude/claude-progress.md`** (human-readable):
```markdown
# Session Progress

**Saved**: 2025-12-13 10:30 AM
**Branch**: feature/auth

## Plan Context

**Goal**: Add user authentication with OAuth2
**Current Step**: ◐ Step 3 - Implement OAuth flow
**Progress**: ██████░░░░ 40% (2/5 steps)

## Tasks

- ✓ Set up OAuth credentials
- ◐ Fix callback URL handling
- ○ Add token refresh logic

## Notes

> Stopped at callback URL issue - need to fix redirect

---
*Restore with: /plan --load*
```

### Output

```
✓ Session saved

┌─ Saved State ──────────────────────────────────────────────────────────────────┐
│ Plan: Step 3/5 (40%) - Implement OAuth flow                                    │
│ Tasks: 1 completed, 1 in progress, 1 pending                                   │
│ Git: 3 uncommitted files on feature/auth                                       │
│ Notes: "Stopped at callback URL issue..."                                      │
└────────────────────────────────────────────────────────────────────────────────┘

Files written:
  • .claude/session-cache.json
  • .claude/claude-progress.md

Restore with: /plan --load
```

---

## Load State: `/plan --load`

Restores session from previous save.

### What It Does

1. Reads `.claude/session-cache.json`
2. Restores TodoWrite tasks
3. Shows what changed since save
4. Suggests next action

### Output

```
📂 Session Loaded

┌─ Time ─────────────────────────────────────────────────────────────────────────┐
│ Saved: 2 hours ago (2025-12-13 10:30 AM)                                       │
│ Branch: feature/auth                                                           │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Plan Context ─────────────────────────────────────────────────────────────────┐
│ Goal: Add user authentication with OAuth2                                      │
│                                                                                 │
│ ✓ Step 1: Research OAuth providers                                             │
│ ✓ Step 2: Set up Google OAuth app                                              │
│ ◐ Step 3: Implement OAuth flow  ← YOU WERE HERE                                │
│ ○ Step 4: Add token refresh                                                    │
│ ○ Step 5: Write integration tests                                              │
│                                                                                 │
│ Progress: ██████░░░░ 40% (2/5)                                                 │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Restored Tasks ───────────────────────────────────────────────────────────────┐
│ ◐ Fix callback URL handling                                                    │
│ ○ Add token refresh logic                                                      │
│ ✓ Set up OAuth credentials                                                     │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Since Last Save ──────────────────────────────────────────────────────────────┐
│ Commits: 0 new                                                                 │
│ Files: 3 still uncommitted                                                     │
│ Plan: unchanged                                                                │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Notes ────────────────────────────────────────────────────────────────────────┐
│ "Stopped at callback URL issue - need to fix redirect"                         │
└────────────────────────────────────────────────────────────────────────────────┘

→ Continue with: Fix callback URL handling
```

### Edge Cases

**Stale state (>7 days):**
```
⚠ Saved state is 12 days old

Options:
  1. Load anyway (tasks may still be relevant)
  2. Start fresh: /plan --clear
```

**Branch changed:**
```
⚠ Branch changed since save

Saved on: feature/old-branch
Current:  feature/new-branch

Options:
  1. Load anyway
  2. Switch back: git checkout feature/old-branch
```

---

## Status View: `/plan --status`

Quick read-only view of current state.

### Output

```
📊 Plan Status

┌─ Plan ─────────────────────────────────────────────────────────────────────────┐
│ Goal: Add user authentication with OAuth2                                      │
│                                                                                 │
│ ✓ Step 1: Research OAuth providers [S]                                         │
│ ✓ Step 2: Set up Google OAuth app [S]                                          │
│ ◐ Step 3: Implement OAuth flow [M]  ← CURRENT                                  │
│ ○ Step 4: Add token refresh [S]                                                │
│ ○ Step 5: Write integration tests [M]                                          │
│                                                                                 │
│ Progress: ██████░░░░ 40% (2/5)                                                 │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Active Tasks ─────────────────────────────────────────────────────────────────┐
│ ◐ Fix callback URL handling                                                    │
│ ○ Add token refresh logic                                                      │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ Git ──────────────────────────────────────────────────────────────────────────┐
│ Branch: feature/auth                                                           │
│ Uncommitted: 3 files (+45/-12)                                                 │
│ Recent: abc123f feat: Add OAuth config                                         │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## Sync from Git: `/plan --sync`

Auto-updates plan step status from recent commits.

### How It Works

1. Parse recent git commits
2. Match commit messages to plan steps
3. Update step status in `docs/PLAN.md`

```bash
# Get recent commits
git log --oneline -20

# Match patterns like:
#   "feat: Add OAuth config" → matches Step 2
#   "fix: Token refresh" → matches Step 4
```

### Output

```
🔄 Syncing plan from git...

Found matches:
  • abc123f "feat: Add OAuth config" → Step 2 (marked complete)
  • def456a "fix: Callback handling" → Step 3 (in progress)

Updated docs/PLAN.md:
  ✓ Step 2: now marked complete
  ◐ Step 3: now marked in progress
```

---

## Clear and Archive: `/plan --clear`

Archives current plan and starts fresh.

```bash
/plan --clear "New feature: payment processing"
```

### What It Does

1. Moves `docs/PLAN.md` → `docs/PLAN-2025-12-13.md`
2. Clears `.claude/session-cache.json`
3. Creates new plan with provided goal

### Output

```
📦 Archived: docs/PLAN.md → docs/PLAN-2025-12-13.md

Starting fresh plan...
```

---

## Status Markers

| Marker | Meaning |
|--------|---------|
| ✓ | Completed |
| ◐ | In Progress |
| ○ | Pending |
| ⚠ | Blocked |

## Effort Indicators

| Tag | Meaning |
|-----|---------|
| `[S]` | Small - Quick task |
| `[M]` | Medium - Moderate effort |
| `[L]` | Large - Significant effort |

Effort is relative to project, not time-based. Avoid time estimates.

---

## Usage Examples

```bash
# Interactive mode - context-aware suggestions
/plan

# Create new plan
/plan "Add user authentication with OAuth2"

# Save session before leaving
/plan --save "Stopped at redirect issue"

# Load previous session
/plan --load

# Quick status check
/plan --status

# Sync progress from git commits
/plan --sync

# See what changed
/plan --diff

# Archive and start fresh
/plan --clear "New feature: payments"
```

---

## Flags Reference

| Flag | Effect |
|------|--------|
| `save "notes"` or `--save` | Save session state with optional notes |
| `load` or `--load` | Restore session from saved state |
| `status` or `--status` | Quick read-only status view |
| `sync` or `--sync` | Auto-update from git commits |
| `diff` or `--diff` | Show changes since last update |
| `clear` or `--clear` | Archive current plan, start fresh |
| `--capture` | Only capture context, no new planning |
| `--verbose` | Show detailed operation output |

---

## File Locations

| File | Purpose | Git-tracked? |
|------|---------|--------------|
| `docs/PLAN.md` | Strategic plan | Yes |
| `.claude/session-cache.json` | Session state | No (gitignored) |
| `.claude/claude-progress.md` | Human-readable progress | No (gitignored) |
| `docs/PLAN-<date>.md` | Archived plans | Yes |

---

## Workflow Examples

### Daily Session

```bash
# Start of day
/plan                        # Interactive: loads previous state if exists

# During work
[implement features]
/plan --status               # Quick check on progress

# End of day
/plan --save "Completed auth, starting tests tomorrow"
```

### With Native Plan Mode

```bash
# Enter Plan Mode for exploration
[Shift+Tab]

# Discuss approaches, make decisions
[Explore codebase, discuss options]

# Capture the thinking
/plan --capture

# Exit and implement
[Shift+Tab]
```

### Multi-Session Feature

```bash
# Session 1
/plan "Implement payment processing"
[work on steps 1-2]
/plan --save "Done with Stripe setup"

# Session 2
/plan --load                 # Restore context
[work on steps 3-4]
/plan --sync                 # Update from commits
/plan --save "Payment flow working"

# Session 3
/plan --load
[complete remaining work]
/plan --clear "Next: Add subscriptions"
```

---

## Notes

- **Never destructive** - Always archives before clearing
- **Git-aware** - Tracks uncommitted changes and recent commits
- **Session-aware** - Knows when state is stale
- **Human-readable** - Progress files work without Claude Code
- **Smart defaults** - No args = intelligent context detection
