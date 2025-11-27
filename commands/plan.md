---
description: "Create, review, and persist project plans. Captures Claude Code Plan Mode state and writes to git-trackable docs/PLAN.md."
---

# Plan - Persistent Project Planning

Create, review, and update project plans. Automatically captures Claude Code's internal Plan Mode state and persists to `docs/PLAN.md`.

## Why This Exists

Claude Code's native Plan Mode (Shift+Tab) is powerful for exploration, but **the plan state doesn't persist**. When your session ends, the strategic thinking is lost.

This command bridges that gap:
- **Captures** any active Plan Mode context
- **Persists** to `docs/PLAN.md` (git-trackable)
- **Survives** across sessions and machines
- **Pairs** with `/save` + `/load` for complete session continuity

## Arguments

$ARGUMENTS

- `<goal>` - Create/update plan for a goal
- `--review` - Display current plan
- `--status` - Update progress on steps
- `--capture` - Capture conversation context only (no new planning)
- `--sync` - Auto-update status from recent git commits
- `--diff` - Show what changed since last plan update
- `--clear` - Archive current plan and start fresh

## Default Behavior: Capture First

**Every invocation of `/plan` attempts to capture internal state first.**

```
/plan <anything>
  │
  ├─→ Step 0: Capture internal state (ALWAYS RUNS)
  │     ├─ Detect if Plan Mode was recently active
  │     ├─ Extract plan-related context from conversation
  │     ├─ Check for temp files (.claude/plan*, docs/PLAN.md)
  │     ├─ Gather git context (uncommitted changes, recent commits)
  │     └─ Merge into working state
  │
  ├─→ Step 1: Check existing docs/PLAN.md
  │     └─ Load and parse if exists
  │
  └─→ Step 2: Execute requested action
        ├─ Create new plan
        ├─ Update existing plan
        └─ Review/display plan
```

This ensures you never lose Plan Mode thinking, even if you forget to explicitly save.

## Execution Steps

### Step 0: Capture Internal State (Always)

```bash
# Check for Plan Mode artifacts
ls -la .claude/plan* docs/PLAN.md 2>/dev/null

# Gather git context
git status --short
git diff --stat
git log --oneline -5

# Check conversation for plan-related discussion
# (Analyze recent messages for: goals, approaches, decisions, steps)
```

**Extract from conversation:**
- Goal statements ("I want to...", "We need to...")
- Approach discussions ("Option A vs B", "We could...")
- Decisions made ("Let's go with...", "The best approach is...")
- Steps identified ("First... then... finally...")
- Open questions ("Should we...", "What about...")

**Git context to capture:**
- Uncommitted changes (files, insertions, deletions)
- Recent commits that may relate to plan steps
- Current branch and status

### Step 1: Check Existing docs/PLAN.md

```bash
# Read existing plan if present
cat docs/PLAN.md 2>/dev/null
```

Parse structure:
- Current goal
- Completed steps
- In-progress steps
- Pending steps
- Blockers
- Open questions
- Decision log

### Step 2: Merge and Execute

Combine:
1. Captured conversation context
2. Existing docs/PLAN.md content
3. Git context (uncommitted changes, recent commits)
4. New goal/instructions from command

### Step 3: Write docs/PLAN.md

```markdown
# Project Plan

**Goal**: <primary objective>
**Created**: <timestamp>
**Last Updated**: <timestamp>
**Status**: In Progress | Complete | Blocked

## Context

<Brief description of current state and constraints>

## Approach

<High-level strategy chosen and why>

### Alternatives Considered
- **Option A**: <description> - <why not chosen>
- **Option B**: <description> - <why not chosen>

## Implementation Steps

### Completed
- ✓ Step 1: <description> [S]
  - Completed: <date>
  - Commit: `abc123` <commit message>
  - Notes: <any relevant context>

### In Progress
- ◐ Step 2: <description> [M]
  - Started: <date>
  - Depends on: Step 1
  - Notes: <current status>

### Pending
- ○ Step 3: <description> [L]
  - Depends on: Step 2
- ○ Step 4: <description> [S]

### Blocked
- ⚠ Step 5: <description> [M]
  - Blocker: <what's blocking this>
  - Waiting on: <person/decision/external>

## Uncommitted Changes

```
📊 Working Tree Status:
  Modified:  X files (+Y/-Z lines)
  Staged:    X files
  Unstaged:  X files
  Untracked: X files

  Files:
  • path/to/file.ts    +89/-12 (staged)
  • path/to/other.ts   +38/-33 (unstaged)
```

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| <date> | <what was decided> | <why this choice> |

## Blockers

- ⚠ <blocker 1>: <description and what's needed to unblock>
- ⚠ <blocker 2>: <description>

## Open Questions

- ○ <question 1>
- ○ <question 2>

## Success Criteria

- ○ <criterion 1>
- ○ <criterion 2>

## Directory Structure

```
project/
├── src/
│   ├── core/           # Core functionality
│   └── features/       # Feature modules
├── tests/
├── docs/
│   └── PLAN.md         # This file
└── config/
```

## Sources & References

- [Official Documentation](https://example.com/docs)
- [API Reference](https://example.com/api)
- [Related RFC/Spec](https://example.com/spec)

## Notes

<Additional context, decisions, or observations>

---
*Plan managed by `/plan` command. Last captured: <timestamp>*
```

## Status Markers

| Marker | Meaning | Usage |
|--------|---------|-------|
| ✓ | Completed | Task finished successfully |
| ◐ | In Progress | Currently being worked on |
| ○ | Pending | Not yet started |
| ⚠ | Blocked | Cannot proceed, needs resolution |

## Effort Indicators

| Tag | Meaning | Guidance |
|-----|---------|----------|
| `[S]` | Small | Quick task, minimal complexity |
| `[M]` | Medium | Moderate effort, some complexity |
| `[L]` | Large | Significant effort, high complexity |

Effort is relative to the project, not absolute time. Avoid time estimates.

## Usage Examples

```bash
# Create new plan (captures any Plan Mode context first)
/plan "Add user authentication with OAuth2"

# Just capture current conversation to plan (no new analysis)
/plan --capture

# Review current plan
/plan --review

# Update progress on steps
/plan --status

# Sync status from recent git commits
/plan --sync

# Show what changed since last update
/plan --diff

# Start fresh (archives old plan)
/plan --clear "New feature: payment processing"
```

## Workflow Integration

### With Native Plan Mode

```
1. [Shift+Tab] Enter Plan Mode
2. [Explore codebase, discuss approaches]
3. /plan --capture              # Persist the thinking
4. [Shift+Tab] Exit Plan Mode
5. [Implement]
6. /plan --status               # Update progress
```

### With /save + /load

```
Session 1:
  /plan "Feature X"             # Strategic planning → docs/PLAN.md
  [work on implementation]
  /save "Completed step 2"      # Tactical state → claude-state.json

Session 2:
  /load                         # Restore TodoWrite tasks
  /plan --review                # See the strategy
  [continue work]
  /plan --status                # Update plan progress
  /save "Completed step 3"
```

### Complete Session Continuity

| Command | Captures | Persists To |
|---------|----------|-------------|
| `/plan` | Strategic thinking, decisions | `docs/PLAN.md` |
| `/save` | TodoWrite tasks, git context | `.claude/claude-state.json` |
| `/load` | - | Restores from `.claude/` |

## Flags

| Flag | Effect |
|------|--------|
| `--review` | Display current plan without modifications |
| `--status` | Interactive update of step progress |
| `--capture` | Only capture conversation context, no new planning |
| `--sync` | Auto-update step status from recent git commits |
| `--diff` | Show what changed since last plan update |
| `--clear` | Archive current plan to `docs/PLAN-<date>.md` and start fresh |
| `--verbose` | Show detailed capture/merge process |

## Output

```
🔍 Capturing internal state...
  ✓ Plan Mode context detected (8 relevant messages)
  ✓ Existing docs/PLAN.md found (3 steps complete)
  ✓ Git context captured
  ✗ No temp plan files

📊 Uncommitted Changes:
  Modified:  2 files (+127/-45)
  • src/auth.ts        +89/-12
  • tests/auth.test.ts +38/-33

📋 Merging sources...
  → Goal: "Add user authentication with OAuth2"
  → Approach: JWT tokens with refresh rotation
  → Progress: 3 complete, 1 in progress, 2 pending

📝 Updated docs/PLAN.md

Summary:
  ✓ Completed:     3 steps
  ◐ In Progress:   1 step
  ○ Pending:       2 steps
  ⚠ Blocked:       0 steps
  ? Open questions: 2
  📋 Decisions:    4 logged

Review with: /plan --review
```

## Notes

- Always captures internal state first—you can't lose Plan Mode thinking
- Archives old plans when using `--clear` (never destructive)
- Works across machines if docs/PLAN.md is committed
- Pairs with `/save` + `/load` for complete session continuity
- Human-readable format works without Claude Code
- Git context helps track what's changed since last session
- Effort indicators are relative, not time-based
