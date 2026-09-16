<!-- Lifted from README.md (v3.8.0) so the landing page carries a summary and this file carries the depth.
     Update BOTH when /save or /sync change: the README summary and this reference. -->

# Session Continuity

The `/save` and `/sync` commands make session state **portable**.

**What's native now:** Claude Code remembers a lot on its own. `--resume` and the session picker restore conversation history, auto-memory writes a per-project `MEMORY.md` with learnings Claude decides are worth keeping, and `/rewind` checkpoints let you roll back within a session. All of it is machine-local — per the docs, auto-memory files "are not shared across machines or cloud environments" — and it remembers context *for you*, in a format Claude curates.

**What's still missing:** task state. Tasks (created via TaskCreate, managed via TaskList/TaskUpdate) are session-scoped and deleted when the session ends — by design. And none of the native state is something you can commit, review, or hand to a teammate.

**What `/save` + `/sync` add:** a state file you control — task restore, structured git/PR context, explicit human-readable handoff notes, and session-ID bridging. Because it lives in your repo, it's git-trackable, team-shareable, and follows you across machines. This implements the pattern from Anthropic's [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):

> "Every subsequent session asks the model to make incremental progress, then leave structured updates."

## What Persists vs What Doesn't

| Claude Code Feature | Persists? | Scope |
|---------------------|-----------|-------|
| Conversation history | Yes | This machine (`--resume` / session picker) |
| Auto-memory (MEMORY.md) | Yes | This machine, per repo — Claude-curated learnings, not task state |
| CLAUDE.md context | Yes | Wherever you commit it |
| Tasks | **No** | Deleted on session end |
| Plan Mode state | **No** | In-memory only |

## Session Workflow

```
Session 1:
  /sync                              # Bootstrap + restore saved state
  [work on tasks]
  /save "Stopped at auth module"     # Writes session-cache.json + MEMORY.md

Session 2:
  [MEMORY.md auto-loaded: "Goal: Auth, Branch: feature/auth, PR: #42"]
  /sync                              # Full restore: tasks, plan, git, PR
  → "Previous session: abc123... (claude --resume abc123...)"
  → "In progress: Auth module refactor"
  → "PR: #42 (claude --from-pr 42)"
```

## Why Not Just Use `--resume` or Auto-Memory?

| Feature | `--resume` | Auto-memory | `/save` + `/sync` |
|---------|------------|-------------|-------------------|
| Conversation history | Yes | No | No |
| Learnings/preferences | No | Yes (Claude-curated) | No |
| Tasks | **No** | **No** | Yes |
| Git/PR context | PR only (`--from-pr`) | Incidental | Yes (structured, `gh`-detected) |
| Session ID bridging | N/A | No | Yes (suggests `--resume <id>`) |
| Explicit handoff notes | No | No | Yes |
| Git-trackable | No | No | Yes |
| Works across machines | No | No (machine-local) | Yes (if committed) |
| Team sharing | No | No | Yes |

**Use all three together:** `claude --resume` for conversation context, auto-memory for accumulated learnings, `/sync` for task state and handoff. Since v3.1, `/save` stores your session ID so `/sync` can suggest the exact `--resume` command.

## Session Cache Schema (v3.1)

The `.claude/session-cache.json` file stores full task objects:

```json
{
  "version": "3.1",
  "session_id": "977c26c9-60fa-4afc-a628-a68f8043b1ab",
  "tasks": [
    {
      "subject": "Task title",
      "description": "Detailed description",
      "activeForm": "Working on task",
      "status": "completed|in_progress|pending",
      "blockedBy": [0, 1]
    }
  ],
  "plan": { "file": "docs/PLAN.md", "goal": "...", "current_step": "...", "progress_percent": 40 },
  "git": { "branch": "main", "last_commit": "abc123", "pr_number": 42, "pr_url": "https://..." },
  "memory": { "synced": true },
  "notes": "Session notes"
}
```

**Compatibility:** `/sync` handles both v3.0 and v3.1 files gracefully. Missing v3.1 fields are treated as absent.
