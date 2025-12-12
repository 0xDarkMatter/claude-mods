---
description: "Session bootstrap - read project context (README, AGENTS, docs, skills, agents). Quick project orientation without full codebase exploration."
---

# Sync - Session Bootstrap

Read yourself into this project. Loads essential context without exploring the full codebase.

## CRITICAL: Cache-First Strategy

### Step 1: Check Cache

First, read `.claude/sync-cache.json`. If it exists and is valid, skip to Step 3.

Cache is valid if ALL are true:
- File exists
- `readme_hash` matches current README.md hash
- `agents_hash` matches current AGENTS.md hash
- `plan_hash` matches current docs/PLAN.md hash (or both null if file missing)

To check hashes, run ONE bash command:
```bash
md5sum README.md AGENTS.md docs/PLAN.md 2>/dev/null
```

### Step 2: Generate Cache (only if cache invalid/missing)

**INVOKE THE TASK TOOL** with `subagent_type: "general-purpose"` and `model: "haiku"`:

```
Gather project context. Return markdown.

READ (skip if missing):
- README.md (full)
- AGENTS.md (full)
- CLAUDE.md (first 100 lines)
- docs/PLAN.md (first 100 lines)

GLOB:
- docs/*.md
- .claude/commands/*.md
- .claude/skills/*/SKILL.md
- .claude/agents/*.md

RETURN THIS FORMAT:

## Summary
[1-2 paragraphs from README/AGENTS]

## Quick Reference
| Category | Items |
|----------|-------|
| **Project** | [name] - [purpose] |
| **Docs** | [filenames] |
| **Commands** | [names] or None |
| **Skills** | [names] or None |
| **Agents** | [names] or None |
```

Then WRITE `.claude/sync-cache.json`:
```json
{
  "readme_hash": "[MD5 hash of README.md]",
  "agents_hash": "[MD5 hash of AGENTS.md]",
  "plan_hash": "[MD5 hash of docs/PLAN.md or null if missing]",
  "content": "[the markdown output]"
}
```

### Step 3: Display Output

Read cache, then run ONE bash for live state:
```bash
git branch --show-current && git status --porcelain | wc -l && test -f .claude/claude-state.json && stat -c %Y .claude/claude-state.json 2>/dev/null
```

Output cached content + live git/plan/state info.

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
- If saved state exists: "Run `/loadplan` to restore your previous session tasks"
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
| `/loadplan` | Restore TodoWrite + plan state from saved JSON |
| `/saveplan` | Persist TodoWrite + plan state to JSON |
| `/dash` | Quick status dashboard (read-only) |
| `/plan` | Create or manage project plans |

### Typical Session Flow

```
New Session
────────────────────────────────────────────────────────────────────────
  1. /sync              ← Read project context (always)
  2. /loadplan          ← Restore saved tasks (if continuing work)
  3. ... work ...
  4. /dash              ← Check status anytime
  5. /saveplan          ← Save before ending session
```

## Notes

- This is a **read-only** command - never modifies files
- Designed for **quick orientation**, not deep analysis
- Works in any project, with or without Claude configuration
- Does NOT invoke skills or subagents - pure file reading
