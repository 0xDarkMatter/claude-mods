---
description: "Session bootstrap - read project context (README, AGENTS, docs, skills, agents). Quick project orientation without full codebase exploration."
---

# Sync - Session Bootstrap

Read yourself into this project. Fast, direct file reads - no caching overhead.

## Execution

### Step 1: Parallel Reads

Read these files simultaneously (skip any that don't exist):

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `AGENTS.md` | Agent instructions |
| `CLAUDE.md` | Project-specific rules |
| `docs/PLAN.md` | Current plan (first 50 lines) |
| `.claude/session-cache.json` | Saved session state |

### Step 2: Parallel Globs

Run these globs simultaneously to discover extensions:

```
docs/*.md
commands/*.md OR .claude/commands/*.md
skills/*/SKILL.md OR .claude/skills/*/SKILL.md
agents/*.md OR .claude/agents/*.md
```

### Step 3: Git State

One bash command for live state:
```bash
git branch --show-current 2>/dev/null && git status --porcelain 2>/dev/null | wc -l
```

### Step 4: Output

Format and display the results.

## Output Format

```
🔄 Project Synced: [project-name]

## Summary

[1-2 paragraph narrative summary based on README.md and AGENTS.md:
- What this project is and its purpose
- Key conventions or guidelines from AGENTS.md
- Current state (active plan, recent work, etc.)
- Any special instructions from CLAUDE.md that affect how to work]

## Quick Reference

| Category | Items |
|----------|-------|
| **Project** | [name] - [one-line purpose from README] |
| **Key Docs** | [list of docs/*.md filenames] |
| **Commands** | [list of /command names from .claude/commands/] |
| **Skills** | [list of skill names from .claude/skills/] |
| **Agents** | [list of agent names from .claude/agents/] |
| **Plan** | [Step X/Y - description] or "No active plan" |
| **Saved State** | [timestamp] or "None" |
| **Git** | [branch], [N] uncommitted files |

## Recommended Next Steps

Based on the current state, suggest 2-3 logical actions:

1. **[Primary action]** - [why this makes sense given current state]
2. **[Secondary action]** - [context]
3. **[Tertiary action or "Ready for new task"]**

Examples of recommendations:
- If saved state exists: "Run `/plan --load` to restore your previous session tasks"
- If plan exists and in-progress: "Continue with Step N: [description]"
- If uncommitted changes: "Review and commit staged changes"
- If no plan/state: "Ready for new task - no pending work detected"
```

## Edge Cases

### No README.md
```
⚠ No README.md found - project overview unavailable
```

### No docs/ directory
```
ℹ No docs/ directory - documentation not set up
```

### First time in project (no .claude/ directory)
```
ℹ Fresh project - no Claude configuration found
   Consider: /init to set up CLAUDE.md
```

## Integration with Other Commands

| Command | Relationship |
|---------|--------------|
| `/sync` | **This command** - Read project context |
| `/plan --load` | Restore TodoWrite + plan state from saved JSON |
| `/plan --save` | Persist TodoWrite + plan state to JSON |
| `/plan --status` | Quick status dashboard (read-only) |
| `/plan` | Create or manage project plans |

### Typical Session Flow

```
New Session
────────────────────────────────────────────────────────────────────────
  1. /sync              ← Read project context (always)
  2. /plan --load       ← Restore saved tasks (if continuing work)
  3. ... work ...
  4. /plan --status     ← Check status anytime
  5. /plan --save       ← Save before ending session
```

## Notes

- This is a **read-only** command - never modifies files
- Designed for **quick orientation**, not deep analysis
- Works in any project, with or without Claude configuration
- Does NOT invoke skills or subagents - pure file reading
