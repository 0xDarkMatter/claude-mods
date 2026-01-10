---
description: "Session bootstrap - read project context, restore saved state, show status. Quick orientation with optional deep dive."
---

# Sync - Session Bootstrap & Restore

Read yourself into this project and restore any saved session state. Fast, direct file reads.

## Arguments

$ARGUMENTS

- No args: Quick bootstrap + restore saved state + show status
- `--verbose`: Deep bootstrap - also reads all `*.md` in root + `docs/`
- `--diff`: Show what changed since last save
- `--git`: Auto-update plan steps from recent commits
- `--status`: Just show status (skip restore prompt)

## Architecture

```
/sync [--verbose|--diff|--git|--status]
    |
    +--> Default (no args): FULL BOOTSTRAP
    |      |
    |      +- Read project context (README, AGENTS, CLAUDE)
    |      +- Read saved state (.claude/session-cache.json)
    |      +- Restore TodoWrite tasks
    |      +- Read plan (docs/PLAN.md)
    |      +- Show unified status
    |      +- Suggest next action
    |
    +--> --verbose: DEEP BOOTSTRAP
    |      |
    |      +- Everything above, plus:
    |      +- Read all *.md in project root
    |      +- Read all *.md in docs/
    |
    +--> --diff: CHANGE DETECTION
    |      |
    |      +- Compare current state vs saved state
    |      +- Show new commits since save
    |      +- Show file changes since save
    |
    +--> --git: AUTO-UPDATE FROM COMMITS
    |      |
    |      +- Parse recent git commits
    |      +- Match to plan steps
    |      +- Update step status
    |
    +--> --status: STATUS ONLY
           |
           +- Show current status
           +- Skip restore prompt
           +- Read-only quick view
```

---

## Default Mode: `/sync`

Full bootstrap with state restoration.

### Step 1: Parallel Reads

Read these files simultaneously (skip any that don't exist):

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `AGENTS.md` | Agent instructions |
| `CLAUDE.md` | Project-specific rules |
| `docs/PLAN.md` | Current plan |
| `.claude/session-cache.json` | Saved session state |

### Step 2: Restore Session State

If `.claude/session-cache.json` exists:
1. Parse saved TodoWrite tasks
2. Restore to TodoWrite (completed, in_progress, pending)
3. Note time since last save

### Step 3: Parallel Globs

Discover extensions:

```
docs/*.md
commands/*.md OR .claude/commands/*.md
skills/*/SKILL.md OR .claude/skills/*/SKILL.md
agents/*.md OR .claude/agents/*.md
```

### Step 4: Git State

```bash
git branch --show-current 2>/dev/null
git status --porcelain 2>/dev/null | wc -l
git log -1 --format="%h %s" 2>/dev/null
```

### Step 5: Output

Format and display unified status.

---

## Output Format

### With Saved State

```
Project Synced: [project-name]

## Session Restored

| Field | Value |
|-------|-------|
| **Last saved** | 2 hours ago |
| **Branch** | feature/auth |
| **Notes** | "Stopped at callback URL issue" |

## Plan Status

**Goal**: Add user authentication with OAuth2

| Step | Status |
|------|--------|
| Step 1: Research OAuth providers | Done |
| Step 2: Set up Google OAuth app | Done |
| Step 3: Implement OAuth flow | **Current** |
| Step 4: Add token refresh | Pending |
| Step 5: Write integration tests | Pending |

Progress: 40% (2/5)

## Restored Tasks

| Status | Task |
|--------|------|
| Done | Set up OAuth credentials |
| **In Progress** | Fix callback URL handling |
| Pending | Add token refresh logic |

## Git

| Field | Value |
|-------|-------|
| **Branch** | feature/auth |
| **Uncommitted** | 3 files |
| **Last commit** | abc123f feat: Add OAuth config |

## Quick Reference

| Category | Items |
|----------|-------|
| **Commands** | /save, /sync, /review, /testgen... |
| **Skills** | 30 available |
| **Agents** | 23 available |

## Next Steps

1. **Continue**: Fix callback URL handling
2. **Check diff**: /sync --diff to see changes since save
```

### Without Saved State

```
Project Synced: [project-name]

## Summary

[1-2 paragraph narrative based on README.md and AGENTS.md]

## Quick Reference

| Category | Items |
|----------|-------|
| **Project** | [name] - [purpose] |
| **Key Docs** | [list of docs/*.md] |
| **Commands** | [list of /commands] |
| **Skills** | [count] available |
| **Agents** | [count] available |
| **Plan** | No active plan |
| **Saved State** | None |
| **Git** | [branch], [N] uncommitted |

## Next Steps

1. **Ready for new task** - No pending work detected
2. **Create a plan** - Use native /plan for implementation planning
3. **Save before leaving** - /save "notes" to persist state
```

---

## Verbose Mode: `/sync --verbose`

Deep context loading for onboarding or complex tasks.

### Additional Reads

| Location | Files Read |
|----------|------------|
| Project root | All `*.md` files |
| `docs/` | All `*.md` files |

### Output

Same as default, plus:

```
## Documentation Loaded

| File | Summary |
|------|---------|
| CONTRIBUTING.md | Contribution guidelines |
| CHANGELOG.md | Recent changes |
| docs/ARCHITECTURE.md | System architecture |
| docs/WORKFLOWS.md | Development workflows |
| ... | ... |
```

---

## Diff Mode: `/sync --diff`

Show what changed since last save.

### Output

```
Changes Since Last Save

## Time

| Field | Value |
|-------|-------|
| **Saved** | 2025-12-13 10:30 AM |
| **Now** | 2025-12-13 12:45 PM |
| **Elapsed** | 2 hours 15 minutes |

## Git Changes

| Type | Count |
|------|-------|
| **New commits** | 3 |
| **Files changed** | 7 |
| **Insertions** | +142 |
| **Deletions** | -38 |

### Recent Commits

| Hash | Message |
|------|---------|
| def456 | fix: Handle redirect edge case |
| abc123 | feat: Add callback validation |
| 789xyz | test: Add OAuth flow tests |

## Plan Changes

| Field | Saved | Current |
|-------|-------|---------|
| **Current step** | Step 3 | Step 3 |
| **Progress** | 40% | 40% |
| **Status** | No change | - |

## Task Changes

| Change | Task |
|--------|------|
| **Completed** | Fix callback URL handling |
| **New** | Add error handling for token refresh |
```

---

## Git Sync Mode: `/sync --git`

Auto-update plan steps from recent commits.

### How It Works

1. Parse recent git commits (last 20)
2. Match commit messages to plan steps using keywords
3. Update step status in `docs/PLAN.md`

### Matching Rules

| Commit Pattern | Plan Update |
|----------------|-------------|
| `feat: Add OAuth...` | Mark matching step complete |
| `fix: Token refresh...` | Mark matching step in-progress |
| `test: OAuth flow...` | Mark matching test step complete |

### Output

```
Git Sync

## Matches Found

| Commit | Plan Step | Action |
|--------|-----------|--------|
| abc123 "feat: Add OAuth config" | Step 2 | Marked complete |
| def456 "fix: Callback handling" | Step 3 | Marked in-progress |

## Updated docs/PLAN.md

| Step | Previous | New |
|------|----------|-----|
| Step 2 | In Progress | Done |
| Step 3 | Pending | In Progress |
```

---

## Status Mode: `/sync --status`

Quick read-only status view. No restore prompt.

### Output

```
Status

## Plan

**Goal**: Add user authentication with OAuth2
**Progress**: 40% (2/5)
**Current**: Step 3 - Implement OAuth flow

## Tasks

| Status | Count |
|--------|-------|
| Completed | 1 |
| In Progress | 1 |
| Pending | 1 |

## Git

| Field | Value |
|-------|-------|
| **Branch** | feature/auth |
| **Uncommitted** | 3 files |
```

---

## Edge Cases

### No README.md
```
Warning: No README.md found - project overview unavailable
```

### No docs/ directory
```
Info: No docs/ directory - documentation not set up
```

### First time in project
```
Info: Fresh project - no Claude configuration found
Consider: Create CLAUDE.md for project-specific rules
```

### Stale saved state (>7 days)
```
Warning: Saved state is 12 days old

Options:
  1. Restore anyway (tasks may still be relevant)
  2. Start fresh: /save --archive
```

### Branch changed since save
```
Warning: Branch changed since save

| Field | Value |
|-------|-------|
| **Saved on** | feature/old-branch |
| **Current** | feature/new-branch |

Restore anyway? Tasks may not apply to current branch.
```

---

## Integration

| Command | Relationship |
|---------|--------------|
| `/sync` | **This command** - Read state in |
| `/save` | Complementary - Persist state out |
| Native `/plan` | Claude Code's planning mode |

### Typical Session Flow

```
Session Start
  /sync                    <- Read project, restore state

During Work
  /sync --status           <- Quick status check
  /sync --diff             <- What changed?
  /sync --git              <- Update from commits

Session End
  /save "notes"            <- Persist before leaving
```

---

## Flags Reference

| Flag | Effect |
|------|--------|
| (none) | Full bootstrap + restore + status |
| `--verbose` | Also read all *.md in root + docs/ |
| `--diff` | Show changes since last save |
| `--git` | Auto-update plan from commits |
| `--status` | Status only, skip restore prompt |

---

## Notes

- **Read-focused** - Only `/save` writes files
- **Fast by default** - Parallel reads, minimal overhead
- **Git-aware** - Tracks branch, commits, uncommitted changes
- **Smart restore** - Detects stale state, branch changes
- Works in any project, with or without Claude configuration
