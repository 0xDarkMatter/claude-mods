---
name: project-planner
description: Manage ROADMAP.md and PLAN.md for project planning. Syncs sprint tasks with git commits and TodoWrite. Triggers on: sync plan, update roadmap, check sprint status, project planning, create roadmap, plan is stale, track progress, sprint sync.
---

# Project Planner

**Purpose**: Automatically manage ROADMAP.md and PLAN.md across all projects, keeping sprint plans in sync with git commits and TodoWrite tasks.

---

## When to Activate

This skill should be invoked when:

1. **User explicitly requests**:
   - "sync my plan"
   - "update sprint plan"
   - "check if plan is stale"
   - "create roadmap"
   - "track my progress"

2. **Proactive triggers** (check first, then suggest):
   - After git commits with significant changes
   - When TodoWrite items are marked completed
   - First invocation of the day (check staleness)
   - When PLAN.md is >3 days old

3. **Missing documentation**:
   - ROADMAP.md doesn't exist
   - PLAN.md doesn't exist
   - User asks about project planning

---

## Skill Invocation Modes

### Mode 1: Full Analysis

**What to do**:
1. Check if `docs/ROADMAP.md` exists
   - If missing: Analyze project and create comprehensive ROADMAP.md
   - If exists: Read and validate structure

2. Check if `docs/PLAN.md` exists
   - If missing: Generate from ROADMAP.md current phase
   - If exists: Read current content

3. Check if `CLAUDE.md` exists (root or docs/)
   - If missing: Flag for creation and suggest to user

4. Analyze recent git commits with **adaptive lookback**:
   ```bash
   git log --since="30 days ago" --oneline --no-merges
   # If no commits, expand to 60, 90, 180, 365 days
   ```

5. Detect uncommitted changes:
   ```bash
   git status --porcelain
   ```
   - Match changed files to PLAN.md tasks

6. Read current TodoWrite state and compare with PLAN.md

7. Update `docs/PLAN.md` and `docs/ROADMAP.md`:
   - Mark completed tasks as [x]
   - Mark in-progress tasks as [-]
   - Move completed to Completed section
   - Update timestamps

8. **Populate TodoWrite from PLAN.md**

9. Report summary to user

### Mode 2: Staleness Check

Quick check of plan freshness:
- Report age of PLAN.md
- Count uncommitted changes
- Show quick stats

### Mode 3: Quick Sync

Fast sync without full analysis:
- Read PLAN.md
- Check last 10 commits
- Update checkboxes
- Refresh TodoWrite

---

## Checkbox Convention

Both ROADMAP.md and PLAN.md use:
- `- [ ]` = Pending/Not started
- `- [-]` = In Progress
- `- [x]` = Completed

---

## File Locations

**Expected structure**:
```
project-root/
├── docs/
│   ├── ROADMAP.md    # Long-term vision
│   └── PLAN.md       # Current sprint
└── README.md
```

**Fallback**: Check root level if docs/ doesn't exist

---

## Tool Usage

**Required tools**:
- `Read` - Read ROADMAP.md, PLAN.md, README.md
- `Write` - Create/update PLAN.md, ROADMAP.md
- `Edit` - Make targeted edits
- `Bash` - Run git commands
- `Grep` - Search for TODO comments
- `Glob` - Find files for project analysis
- `TodoWrite` - Sync bidirectionally

---

## Best Practices

1. **Non-destructive**: Always preserve user's manual edits
2. **Additive**: Add tasks, don't remove (unless obviously complete)
3. **Timestamped**: Always update "Last Updated" field
4. **Confirmation**: Ask before major changes (>5 tasks affected)
5. **Git-aware**: Check if changes should be committed

---

**Version**: 1.2
