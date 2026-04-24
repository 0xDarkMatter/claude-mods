---
description: "Session bootstrap - read project context, restore saved state, show status. Quick orientation with optional deep dive."
---

# Sync - Session Bootstrap & Restore

Read yourself into this project and restore any saved session state. Fast, direct file reads.

**Environment Requirements:**
- All shell commands use **Git Bash syntax** (works on Linux/macOS/Windows)
- NEVER use Windows cmd syntax (`find /c`, `2>nul`) - causes filesystem scanning on Git Bash
- Use `wc -l` for counting, `2>/dev/null` for error suppression

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
    |      +- Restore tasks via TaskCreate
    |      +- Resolve plan path (Step 0)
    |      +- Read plan (<plan-path>)
    |      +- Acknowledge memory context (already auto-loaded)
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

### Step 0: Resolve Plan Path

Determine the plan file location before reading:

1. If saved state exists (`.claude/session-cache.json`) and has a `plan.file` value, prefer that path
2. Else check `.claude/settings.local.json` for a `plansDirectory` key
3. Else check `.claude/settings.json` for `plansDirectory`
4. If found, plan path = `<plansDirectory>/PLAN.md`
5. Otherwise, default to `docs/PLAN.md`

Use the resolved path in all subsequent file reads and output.

### Step 1: Parallel Reads

Read these files simultaneously (skip any that don't exist):

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `AGENTS.md` | Agent instructions |
| `CLAUDE.md` | Project-specific rules |
| `<plan-path>` | Current plan (resolved in Step 0) |
| `.claude/session-cache.json` | Saved session state |

### Step 2: Restore Session State

If `.claude/session-cache.json` exists:

```
1. Parse saved tasks array from JSON
2. For each task, call TaskCreate with:
   - subject
   - description
   - activeForm
3. Build ID mapping: savedIndex → newTaskId
4. For each task with blockedBy, call TaskUpdate:
   - Map saved indices to new task IDs
   - Set blockedBy relationships
5. For each task, call TaskUpdate to set status:
   - "completed" | "in_progress" | "pending"
6. Note time since last save
7. If session_id present, note it for --resume suggestion in output
8. If git.pr_number/pr_url present, note for --from-pr suggestion in output
```

Note: Tasks do not persist across sessions automatically, which is why this restore step is needed.

### Step 3: Parallel Globs

Discover extensions:

```
docs/*.md
commands/*.md OR .claude/commands/*.md
skills/*/SKILL.md OR .claude/skills/*/SKILL.md
agents/*.md OR .claude/agents/*.md
```

### Step 4: Git State

**CRITICAL:** Use Git Bash syntax ONLY. Never use Windows cmd syntax (`find /c`, `2>nul`) - these will cause filesystem scanning.

Run these commands to get git state:

```bash
# Current branch
git branch --show-current 2>/dev/null

# Count uncommitted files - MUST use wc -l (works in Git Bash on Windows)
git status --porcelain 2>/dev/null | wc -l

# Latest commit
git log -1 --format="%h %s" 2>/dev/null
```

**Why this matters on Windows:**
- `find /c` in Git Bash = Unix find searching C: drive (WRONG)
- `wc -l` in Git Bash = count lines (CORRECT)
- Git Bash understands `2>/dev/null` but NOT `2>nul`

### Step 5: Check Mail

Check for unread pigeon messages using the globally installed script:

```bash
bash "$HOME/.claude/pigeon/mail-db.sh" status 2>/dev/null
bash "$HOME/.claude/pigeon/mail-db.sh" unread 2>/dev/null
```

- If the script doesn't exist or returns no unread, skip silently
- If unread messages exist, show count and preview in the output Mail section
- Do NOT auto-mark messages as read - just show what's waiting

### Step 6: Acknowledge Memory

MEMORY.md is auto-loaded into the system prompt by Claude Code - do NOT re-read the file.
Instead, check your system prompt for the memory content you already have, and surface it:

- If MEMORY.md has content (non-empty), summarise what it contains (especially any `## Last Session` section written by `/save`)
- If MEMORY.md is empty, note "Memory: Empty (no notes from previous sessions)"

This costs zero extra tokens while confirming the safety net is working.

### Step 7: Check Pending Skill Suggestions

The `auto-skill` Stop hook writes to `~/.claude/auto-skill/pending.log` whenever
it detects a skill-worthy session. Those suggestions go to Claude via
`systemMessage` — which usually dies silently. `/sync` is the surfacing point.

```bash
LOG="$HOME/.claude/auto-skill/pending.log"
[ -f "$LOG" ] || exit 0

# Show entries from the last 72 hours
CUTOFF=$(date -d '72 hours ago' -Iseconds 2>/dev/null || \
         date -v-72H '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)

awk -F'|' -v cutoff="$CUTOFF" '$1 >= cutoff' "$LOG" 2>/dev/null | tail -10
```

- If the log doesn't exist, or no entries in the last 72h, skip silently
- If entries exist, show a "Skill Suggestions" section with each row
- Format per row: timestamp (local), writes/unique, cwd, top tools
- Offer: run `/auto-skill` to capture, or `auto-skill clear` to dismiss

### Step 8: Output

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
| **Previous session** | abc123... |
| **Notes** | "Stopped at callback URL issue" |

Note: Previous session row only shown when session_id is present in saved state.

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
| **PR** | #42 - https://github.com/user/repo/pull/42 |

Note: PR row only shown when pr_number/pr_url are present in saved state.

## Memory

[If MEMORY.md has content, summarise key points - especially any `## Last Session` section]
[If MEMORY.md is empty: "No memory notes from previous sessions."]

Note: MEMORY.md is auto-loaded into the system prompt. This section surfaces
what's already in context - no file read needed.

## Mail

[If pigeon is installed and has unread messages:]
3 unread messages:
  From: some-api  |  Auth endpoints ready
  From: frontend  |  Need updated types
  From: infra     |  Deploy complete

Run `pigeon read` to read.

[If no unread messages or pigeon not installed: omit this section entirely]

## Skill Suggestions

[If ~/.claude/auto-skill/pending.log has entries from the last 72 hours:]
2 skill-worthy sessions detected (you missed the in-turn prompts):
  2026-04-24 19:28  |  12w/5t  |  X:/Forge/Axiom           |  Write(4) Edit(3) Bash(3)
  2026-04-24 14:47  |  9w/4t   |  X:/Forge/claude-mods     |  Edit(4) Bash(3) Write(2)

Run `/auto-skill` to capture a workflow, or `auto-skill clear` to dismiss.

[If no pending entries in last 72h, or log doesn't exist: omit this section entirely]

## Quick Reference

| Category | Items |
|----------|-------|
| **Commands** | /save, /sync, /review, /testgen... |
| **Skills** | 30 available |
| **Agents** | 23 available |

## Next Steps

1. **Read mail**: N unread messages - `pigeon read` (when unread mail exists)
2. **Continue**: Fix callback URL handling
3. **Check diff**: /sync --diff to see changes since save
4. **Resume conversation**: `claude --resume abc123...` (when session_id present)
5. **PR context**: `claude --from-pr 42` (when PR is linked)
```

Note: Next Steps items 3-4 are only shown when the corresponding data exists in saved state.

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
| **Memory** | [summary of MEMORY.md content, or "Empty"] |
| **Mail** | [N unread, or omit row if none/not installed] |
| **Git** | [branch], [N] uncommitted |

## Next Steps

1. **Read mail**: N unread messages - `pigeon read` (when unread mail exists)
2. **Ready for new task** - No pending work detected
3. **Create a plan** - Use native /plan for implementation planning
4. **Save before leaving** - /save "notes" to persist state
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
3. Update step status in the resolved plan path

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

## Updated <plan-path>

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

## Memory

[Summary of MEMORY.md content, or "Empty"]

## Mail

[N unread messages with preview, or omit if none/not installed]

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
