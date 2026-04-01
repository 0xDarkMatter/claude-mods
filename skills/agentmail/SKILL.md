---
name: agentmail
description: "Inter-session mail - send and receive messages between Claude Code sessions running in different project directories. Uses global SQLite database at ~/.claude/mail.db. Triggers on: mail, send message, check mail, inbox, inter-session, message another session, agentmail."
allowed-tools: "Read Bash Grep"
related-skills: [sqlite-ops]
---

# AgentMail

Inter-session messaging for Claude Code. Sessions running in different project directories can send and receive messages through a shared SQLite database.

## Architecture

```
~/.claude/mail.db          # Global message store (auto-created)

Session A (claude-mods)    Session B (some-api)     Session C (frontend)
    |                          |                        |
    +-- check-mail hook -------+-- check-mail hook -----+-- check-mail hook
    |   (PreToolUse, silent    |   (10s cooldown)       |
    |    when empty)           |                        |
    |                          |                        |
    +-- /mail send some-api ---+--> unread message -----+
         "API changed"             appears next
                                   tool call
```

## Project Identity

Project name = `basename` of current working directory. No configuration needed.

- `X:\Forge\claude-mods` -> `claude-mods`
- `X:\Forge\some-api` -> `some-api`

If a project directory is renamed, use the `alias` command to link old and new names:

```bash
bash skills/agentmail/scripts/mail-db.sh alias "old-name" "new-name"
```

## Commands

All commands use the helper script at `skills/agentmail/scripts/mail-db.sh`.

### Send a Message

```bash
bash skills/agentmail/scripts/mail-db.sh send "<target-project>" "<subject>" "<body>"
```

Send with urgent priority (highlighted in hook notifications):

```bash
bash skills/agentmail/scripts/mail-db.sh send --urgent "<target-project>" "<subject>" "<body>"
```

### Read Messages

```bash
bash skills/agentmail/scripts/mail-db.sh read          # All unread, mark as read
bash skills/agentmail/scripts/mail-db.sh read 42        # Single message by ID
```

### Reply

Reply to a message - automatically addresses the sender with Re: prefix:

```bash
bash skills/agentmail/scripts/mail-db.sh reply <message-id> "<body>"
```

### Broadcast

Send to all known projects (except self):

```bash
bash skills/agentmail/scripts/mail-db.sh broadcast "<subject>" "<body>"
```

### Search

Find messages by keyword in subject or body:

```bash
bash skills/agentmail/scripts/mail-db.sh search "<keyword>"
```

### Status

Inbox summary with per-project breakdown:

```bash
bash skills/agentmail/scripts/mail-db.sh status
```

### Other Commands

```bash
bash skills/agentmail/scripts/mail-db.sh count          # Unread count (number only)
bash skills/agentmail/scripts/mail-db.sh unread          # List unread (brief)
bash skills/agentmail/scripts/mail-db.sh list [N]        # Recent messages (default 20)
bash skills/agentmail/scripts/mail-db.sh projects        # All known projects
bash skills/agentmail/scripts/mail-db.sh clear [days]    # Delete read msgs older than N days
bash skills/agentmail/scripts/mail-db.sh alias <old> <new>  # Rename project in all messages
bash skills/agentmail/scripts/mail-db.sh init            # Initialize database
```

## Passive Notification (Hook)

The `hooks/check-mail.sh` hook provides passive notification:

1. Runs on every tool call (PreToolUse, 10-second cooldown)
2. Checks for unread messages matching current directory name
3. Silent when inbox is empty
4. Shows count + preview of up to 3 messages
5. Highlights urgent messages with `[!]` prefix

### Hook Output

```
=== MAIL: 3 unread message(s) ===
  From: some-api  |  Auth endpoints ready
  From: frontend  |  Need updated types
  ... and 1 more
Use /mail to read messages.
```

Urgent messages:

```
=== URGENT MAIL: 2 unread (1 urgent) ===
  [!] From: some-api  |  Production is down
  From: frontend  |  Need updated types
Use /mail to read messages.
```

## When to Use

**Send messages when:**
- You've completed work another session depends on
- An API contract or shared interface changed
- A shared branch (main) is broken or fixed
- You need input from a session working on a different project

**The hook handles receiving automatically.** When this skill triggers from a user saying "check mail" or "read messages", run the read command.

## Database

Single SQLite file at `~/.claude/mail.db`. Not inside any git repo.

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

All user inputs are sanitized via SQL single-quote escaping. Numeric inputs (IDs, limits) are validated before use.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `sqlite3: not found` | Ships with macOS, Linux, and Git Bash on Windows |
| Hook not firing | Register in `.claude/settings.json` or `.claude/settings.local.json` |
| Wrong project name | Uses `basename $PWD` - ensure cwd is project root |
| Messages not arriving | `to_project` must match target's directory basename exactly |
| Renamed directory | Use `alias` command to update old name to new name |
