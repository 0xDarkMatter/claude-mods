---
description: "Show plan status: progress, active tasks, git state. Quick read-only view of current project state."
---

# ShowPlan - Plan Status View

Quick read-only view showing plan progress, active tasks, and git state.

## What This Command Does

```
/showplan
    │
    ├─→ Read docs/PLAN.md
    │     └─ Parse current step, progress, blockers
    │
    ├─→ Read TodoWrite state
    │     └─ Get in-progress and pending tasks
    │
    ├─→ Read git state
    │     └─ Branch, uncommitted changes, recent commits
    │
    └─→ Display unified status view
```

## Output Format

```
📊 Plan Status

┌─ Plan ─────────────────────────────────────────────────────────────────────────────────────────┐
│ docs/PLAN.md (updated 2 hours ago)                                                             │
│                                                                                                │
│ Goal: Add user authentication with OAuth2                                                      │
│                                                                                                │
│ ✓ Step 1: Research OAuth providers [S]                                                         │
│ ✓ Step 2: Set up Google OAuth app [S]                                                          │
│ ◐ Step 3: Implement OAuth flow [M]  ← CURRENT                                                  │
│ ○ Step 4: Add token refresh [S]                                                                │
│ ○ Step 5: Write integration tests [M]                                                          │
│                                                                                                │
│ Progress: ██████░░░░ 40% (2/5)                                                                 │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Active Tasks ─────────────────────────────────────────────────────────────────────────────────┐
│ ◐ Fix callback URL handling                                                                    │
│ ○ Add token refresh logic                                                                      │
│ ✓ Set up OAuth credentials                                                                     │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Git ──────────────────────────────────────────────────────────────────────────────────────────┐
│ Branch: feature/auth                                                                           │
│ Uncommitted: 3 files (+45/-12)                                                                 │
│   • src/auth/oauth.ts               +32/-8                                                     │
│   • src/auth/callback.ts            +13/-4                                                     │
│   • tests/auth.test.ts              (new)                                                      │
│                                                                                                │
│ Recent commits:                                                                                │
│   • abc123f feat: Add OAuth config                                                             │
│   • def456a fix: Handle token expiry                                                           │
│   • 789ghij refactor: Extract auth utils                                                       │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Suggestions ──────────────────────────────────────────────────────────────────────────────────┐
│ → 3 files ready to commit                                                                      │
│ → Plan is 2 days stale, run: /plan --sync                                                      │
│ → Save before leaving: /saveplan                                                               │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Execution Steps

### Step 1: Check for Plan

```bash
# Check if plan exists
cat docs/PLAN.md 2>/dev/null
```

If no plan found:
```
┌─ Plan ─────────────────────────────────────────────────────────────────────────────────────────┐
│ ⚠  Plan: No docs/PLAN.md found                                                                 │
│    Create one with: /plan "your project goal"                                                  │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

If no saved state but plan exists:
```
┌─ Session ──────────────────────────────────────────────────────────────────────────────────────┐
│ ⚠  State: No saved state found in .claude/session-cache.json                                    │
│ ✅  Plan: Project plan found at docs/PLAN.md                                                    │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Step 2: Parse Plan

Extract from docs/PLAN.md:
- **Goal**: from `**Goal**:` line
- **Steps**: lines starting with `✓`, `◐`, `○`, `⚠`
- **Current step**: the one marked with `◐`
- **Progress**: count completed vs total

### Step 3: Get TodoWrite State

Read current TodoWrite tasks:
- `in_progress` → show with ◐
- `pending` → show with ○
- `completed` → show with ✓ (recent only)

### Step 4: Get Git State

```bash
# Current branch
git branch --show-current

# Uncommitted changes with stats
git diff --stat
git diff --cached --stat

# Count changes
git status --porcelain
```

### Step 5: Generate Suggestions

Based on state, suggest next actions:

| Condition | Suggestion |
|-----------|------------|
| Uncommitted files > 0 | "X files ready to commit" |
| Plan modified > 2 days ago | "Plan may be stale, run: /plan --sync" |
| No saved state exists | "Save progress with: /saveplan" |
| In-progress task exists | "Continue: <task name>" |
| All tasks complete | "Mark plan step complete: /plan --status" |

## Flags

| Flag | Effect |
|------|--------|
| `--brief` | Compact single-line summary |
| `--plan` | Show only plan section |
| `--tasks` | Show only tasks section |
| `--git` | Show only git section |

## Brief Mode

```bash
/showplan --brief
```

Output:
```
📊 Plan: 2/5 (◐ Step 3) │ Tasks: 1 active, 2 pending │ Git: 3 uncommitted
```

## Integration

Part of the plan management suite:

| Command | Purpose |
|---------|---------|
| `/sync` | Read project context at session start |
| `/loadplan` | Restore TodoWrite + plan state from saved JSON |
| `/showplan` | **This command** - Quick status view |
| `/saveplan` | Persist state before leaving |
| `/plan` | Create or manage project plans |

## Notes

- Read-only command, never modifies files
- Fast execution, can run frequently
- Shows suggestions based on detected state
- Works even without plan (shows tasks + git only)
