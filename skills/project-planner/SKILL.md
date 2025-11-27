---
name: project-planner
description: Detects stale project plans and suggests /plan command usage. Triggers on: sync plan, update plan, check status, plan is stale, track progress, project planning.
---

# Project Planner Skill

Lightweight awareness layer for `docs/PLAN.md`. Detects when plans need attention and points to `/plan` command.

## Purpose

This skill does NOT manage plans directly. It:
- Detects when `docs/PLAN.md` exists or is missing
- Identifies stale plans (no recent updates vs git activity)
- Suggests appropriate `/plan` commands

All plan operations go through the `/plan` command.

## Detection Logic

### Plan Missing
```
No docs/PLAN.md found
→ Suggest: /plan "describe your project goal"
```

### Plan Stale
```
docs/PLAN.md last modified: 5 days ago
git log shows: 12 commits since then
→ Suggest: /plan --sync
```

### Uncommitted Work
```
git status shows: 5 modified files
docs/PLAN.md "In Progress" section outdated
→ Suggest: /plan --status
```

### Session Start
```
Resuming work on project with docs/PLAN.md
→ Suggest: /plan --review
```

## Quick Reference

| Situation | Suggestion |
|-----------|------------|
| No plan exists | `/plan "goal"` |
| Plan is stale | `/plan --sync` |
| Need to see plan | `/plan --review` |
| Update progress | `/plan --status` |
| Capture thinking | `/plan --capture` |
| Start fresh | `/plan --clear "new goal"` |

## Staleness Heuristics

A plan is considered **stale** when:
- Last modified > 3 days ago AND
- Git shows commits since last modification AND
- Commits relate to plan topics (feat:, fix:, refactor:)

A plan **needs review** when:
- Session just started
- Significant uncommitted changes exist
- User mentions progress or completion

## Notes

- This skill only suggests, never modifies
- All operations delegate to `/plan` command
- Single source of truth: `docs/PLAN.md`
