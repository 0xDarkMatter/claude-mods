---
name: agentmail
description: "Inter-session mail - send and receive messages between Claude Code sessions running in different project directories. Uses global SQLite database at ~/.claude/mail.db. Triggers on: mail, send message, check mail, inbox, inter-session, message another session, agentmail."
allowed-tools: "Read Bash Grep"
related-skills: [sqlite-ops]
---

# AgentMail

Inter-session messaging for Claude Code. Send and receive messages between sessions running in different projects.

## Quick Reference

All commands go through `MAIL`, a shorthand for `bash "$HOME/.claude/agentmail/mail-db.sh"`.

Set this at the top of execution:

```bash
MAIL="$HOME/.claude/agentmail/mail-db.sh"
```

Then use it for all commands below.

## Command Router

Parse the user's input after `agentmail` (or `/agentmail`) and run the matching command:

| User says | Run |
|-----------|-----|
| `agentmail read` | `bash "$MAIL" read` |
| `agentmail read 42` | `bash "$MAIL" read 42` |
| `agentmail send <project> "<subject>" "<body>"` | `bash "$MAIL" send "<project>" "<subject>" "<body>"` |
| `agentmail send --urgent <project> "<subject>" "<body>"` | `bash "$MAIL" send --urgent "<project>" "<subject>" "<body>"` |
| `agentmail reply <id> "<body>"` | `bash "$MAIL" reply <id> "<body>"` |
| `agentmail broadcast "<subject>" "<body>"` | `bash "$MAIL" broadcast "<subject>" "<body>"` |
| `agentmail search <keyword>` | `bash "$MAIL" search "<keyword>"` |
| `agentmail status` | `bash "$MAIL" status` |
| `agentmail unread` | `bash "$MAIL" unread` |
| `agentmail list` | `bash "$MAIL" list` |
| `agentmail list 50` | `bash "$MAIL" list 50` |
| `agentmail projects` | `bash "$MAIL" projects` |
| `agentmail clear` | `bash "$MAIL" clear` |
| `agentmail clear 7` | `bash "$MAIL" clear 7` |
| `agentmail alias <old> <new>` | `bash "$MAIL" alias "<old>" "<new>"` |
| `agentmail purge` | `bash "$MAIL" purge` |
| `agentmail purge --all` | `bash "$MAIL" purge --all` |
| `agentmail init` | `bash "$MAIL" init` |

When the user just says "check mail", "read mail", "inbox", or "any mail?" - run `bash "$MAIL" read`.

When the user says "send mail to X" or "message X" - parse out the project name, subject, and body, then run `bash "$MAIL" send`.

## Project Identity

Project name = `basename` of current working directory. No configuration needed.

- `C:\Projects\claude-mods` -> `claude-mods`
- `C:\Projects\some-api` -> `some-api`
- `X:\Roam\Fathom` -> `Fathom`

## Passive Notification (Hook)

A global PreToolUse hook checks for mail on every tool call (10-second cooldown). Silent when inbox is empty.

```
=== MAIL: 3 unread message(s) ===
  From: some-api  |  Auth endpoints ready
  From: frontend  |  Need updated types
  ... and 1 more
Use agentmail read to read messages.
```

## When to Send

- You've completed work another session depends on
- An API contract or shared interface changed
- A shared branch (main) is broken or fixed
- You need input from a session working on a different project

## Per-Project Disable

```bash
touch .claude/agentmail.disable    # Disable hook notifications
rm .claude/agentmail.disable       # Re-enable
```

Only the hook is disabled - you can still send messages from the project.

---

## Installation

Agentmail installs globally - one setup, every project gets mail automatically.

### Files

```
~/.claude/
  mail.db                  # Message store (auto-created on first use)
  agentmail/
    mail-db.sh             # Mail commands
    check-mail.sh          # PreToolUse hook
```

### Setup

1. Copy scripts to global location:

```bash
mkdir -p ~/.claude/agentmail
cp skills/agentmail/scripts/mail-db.sh ~/.claude/agentmail/
cp hooks/check-mail.sh ~/.claude/agentmail/
```

2. Add the hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/agentmail/check-mail.sh\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Database

Single SQLite file at `~/.claude/mail.db`. Auto-created on first use.

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_project TEXT NOT NULL,
    to_project TEXT NOT NULL,
    subject TEXT DEFAULT '',
    body TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now')),
    read INTEGER DEFAULT 0,
    priority TEXT DEFAULT 'normal'
);
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `sqlite3: not found` | Ships with macOS, Linux, and Git Bash on Windows |
| Hook not firing | Add PreToolUse hook to `~/.claude/settings.json` (see Installation) |
| Wrong project name | Uses `basename $PWD` - ensure cwd is project root |
| Messages not arriving | `to_project` must match target's directory basename exactly |
| Renamed directory | Use `agentmail alias old-name new-name` |
