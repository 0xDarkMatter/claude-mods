# Session Manager

Unified session management for Claude Code. Persist state, track progress, resume seamlessly.

## The Problem

Claude Code doesn't persist everything across sessions:

```
┌─────────────────────────────────────────────────────────────┐
│                What Persists?                                │
├──────────────────────────┬──────────────────────────────────┤
│ ✓ Conversation history   │ Use: claude --resume             │
│ ✓ CLAUDE.md context      │ File: ./CLAUDE.md                │
├──────────────────────────┼──────────────────────────────────┤
│ ✗ TodoWrite tasks        │ Deleted on session end           │
│ ✗ Plan Mode thinking     │ In-memory only                   │
│ ✗ "Where was I?"         │ Lost context                     │
└──────────────────────────┴──────────────────────────────────┘
```

## The Solution

Three commands that work together:

```
┌─────────────────────────────────────────────────────────────┐
│                  Session Lifecycle                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│     START              WORK                END              │
│       │                  │                  │               │
│       ▼                  ▼                  ▼               │
│   ┌──────┐          ┌────────┐         ┌──────┐            │
│   │/load │ ───────▶ │/status │ ──────▶ │/save │            │
│   └──────┘          └────────┘         └──────┘            │
│       │                  │                  │               │
│   Restore            Dashboard          Persist             │
│   context             view              state               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Commands

### `/status` - Dashboard View

See everything at a glance:

```
📊 Project Status

┌─ Plan ─────────────────────────────────────────┐
│ Goal: Add user authentication with OAuth2      │
│                                                │
│ ✓ Step 1: Research OAuth providers [S]         │
│ ✓ Step 2: Set up Google OAuth app [S]          │
│ ◐ Step 3: Implement OAuth flow [M]  ← CURRENT  │
│ ○ Step 4: Add token refresh [S]                │
│ ○ Step 5: Write integration tests [M]          │
│                                                │
│ Progress: ██████░░░░ 40% (2/5)                 │
└────────────────────────────────────────────────┘

┌─ Active Tasks ─────────────────────────────────┐
│ ◐ Fix callback URL handling                    │
│ ○ Add token refresh logic                      │
└────────────────────────────────────────────────┘

┌─ Git ──────────────────────────────────────────┐
│ Branch: feature/auth                           │
│ Uncommitted: 3 files (+45/-12)                 │
└────────────────────────────────────────────────┘
```

### `/save` - Persist State

Save before ending your session:

```
/save "Stopped at callback URL issue"

✓ Session saved

┌─ Saved State ──────────────────────────────────┐
│ Plan: Step 3/5 (40%) - Implement OAuth flow    │
│ Tasks: 1 completed, 1 in progress, 1 pending   │
│ Git: 3 uncommitted files                       │
└────────────────────────────────────────────────┘

Restore with: /load
```

### `/load` - Restore Context

Pick up where you left off:

```
/load

📂 Session Loaded

┌─ Plan Context ─────────────────────────────────┐
│ Goal: Add user authentication with OAuth2      │
│ Current: ◐ Step 3 - Implement OAuth flow       │
│ Progress: ██████░░░░ 40% (2/5)                 │
└────────────────────────────────────────────────┘

┌─ Restored Tasks ───────────────────────────────┐
│ ◐ Fix callback URL handling                    │
│ ○ Add token refresh logic                      │
└────────────────────────────────────────────────┘

┌─ Notes ────────────────────────────────────────┐
│ "Stopped at callback URL issue"                │
└────────────────────────────────────────────────┘

Suggested: Continue with "Fix callback URL handling"
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Commands                                │
├─────────────┬─────────────┬─────────────────────────────────┤
│   /status   │   /save     │   /load                         │
│   (read)    │   (write)   │   (read + restore)              │
└──────┬──────┴──────┬──────┴──────┬──────────────────────────┘
       │             │             │
       │             ▼             │
       │    ┌────────────────┐     │
       │    │ .claude/       │     │
       │    │ claude-state   │◄────┤
       │    │ .json          │     │
       │    ├────────────────┤     │
       │    │ {              │     │
       │    │   todos: {},   │     │
       │    │   plan: {},    │     │
       │    │   git: {},     │     │
       │    │   notes: ""    │     │
       │    │ }              │     │
       │    └────────────────┘     │
       │             │             │
       │             │             │
       ▼             ▼             ▼
┌─────────────────────────────────────────────────────────────┐
│                    docs/PLAN.md                              │
│  (Strategic plan - managed by /plan command)                │
└─────────────────────────────────────────────────────────────┘
```

## State File Format

`.claude/claude-state.json`:

```json
{
  "version": "2.0",
  "timestamp": "2025-11-27T10:30:00Z",

  "todos": {
    "completed": ["Set up OAuth credentials"],
    "in_progress": ["Fix callback URL handling"],
    "pending": ["Add token refresh"]
  },

  "plan": {
    "file": "docs/PLAN.md",
    "goal": "Add user authentication with OAuth2",
    "current_step": "Step 3: Implement OAuth flow",
    "progress_percent": 40
  },

  "git": {
    "branch": "feature/auth",
    "last_commit": "abc123f",
    "uncommitted_count": 3
  },

  "notes": "Stopped at callback URL issue"
}
```

## Workflow Examples

### Daily Workflow

```
Morning:
  $ claude
  > /load                    # See where you left off
  > /status                  # Check current state

Work:
  > (make changes)
  > /status                  # Quick check anytime

End of day:
  > /save "Finished auth, starting tests tomorrow"
```

### Context Switch

```
Working on Feature A:
  > /save "Pausing for urgent bug"

Switch to Bug Fix:
  > git checkout hotfix/bug
  > (fix bug)
  > git checkout feature-a

Resume Feature A:
  > /load                    # Restore Feature A context
```

### Team Handoff

```
Developer 1:
  > /save "Implemented OAuth, needs review" --commit
  > git push

Developer 2:
  > git pull
  > /load                    # See exactly where they stopped
```

## Integration with /plan

These commands integrate with the `/plan` command:

```
┌─────────────────────────────────────────────────────────────┐
│                 Unified State Model                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Strategic (Big Picture)          Tactical (Right Now)    │
│   ────────────────────────         ───────────────────────  │
│                                                             │
│   docs/PLAN.md                     .claude/claude-state.json│
│   ├─ Project goal                  ├─ TodoWrite tasks       │
│   ├─ Implementation steps          ├─ Current plan step ref │
│   ├─ Progress markers              ├─ Git context           │
│   └─ Decision log                  └─ Session notes         │
│                                                             │
│         ▲                                   ▲               │
│         │                                   │               │
│         │         ┌───────────┐             │               │
│         └─────────│  /status  │─────────────┘               │
│                   │ (unified  │                             │
│                   │   view)   │                             │
│                   └───────────┘                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Why Not Just Use `--resume`?

| Feature | `claude --resume` | Session Manager |
|---------|-------------------|-----------------|
| Conversation history | ✓ | - |
| TodoWrite tasks | ✗ | ✓ |
| Plan context | ✗ | ✓ |
| Git state | ✗ | ✓ |
| Human-readable | ✗ | ✓ |
| Git-trackable | ✗ | ✓ |
| Works across machines | ✗ | ✓ |
| Team sharing | ✗ | ✓ |

**Use both together:** `claude --resume` for conversation, `/load` for task state.

## Installation

This is a submodule of [claude-mods](https://github.com/0xDarkMatter/claude-mods).

```bash
# Via claude-mods (recommended)
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
./install.sh  # or .\install.ps1 on Windows

# Standalone
git clone https://github.com/0xDarkMatter/session-manager.git
# Copy *.md files to ~/.claude/commands/
```

## Command Reference

| Command | Purpose | Modifies Files |
|---------|---------|----------------|
| `/status` | Dashboard view | No (read-only) |
| `/save [notes]` | Persist state | Yes (.claude/) |
| `/load` | Restore state | Yes (TodoWrite) |

| Flag | Command | Effect |
|------|---------|--------|
| `--brief` | /status | Single-line output |
| `--commit` | /save | Git commit state files |
| `--no-restore` | /load | Preview without restoring |
| `--clear` | /load | Clear state after loading |

## License

MIT

---

*Part of the [claude-mods](https://github.com/0xDarkMatter/claude-mods) collection.*
