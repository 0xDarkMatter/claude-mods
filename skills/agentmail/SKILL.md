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
    |   (PreToolUse, silent    |                        |
    |    when empty)           |                        |
    |                          |                        |
    +-- /mail send some-api ---+--> unread message -----+
         "API changed"             appears next
                                   tool call
```

## Project Identity

Project name = `basename` of current working directory. No configuration needed.

- `C:\Projects\claude-mods` -> `claude-mods`
- `C:\Projects\some-api` -> `some-api`

## Commands

All commands use the helper script at `skills/agentmail/scripts/mail-db.sh`.

### Check for Mail

The `check-mail.sh` hook runs automatically on every tool call. When unread messages exist, it outputs a notification. No action needed from user or assistant.

To manually check:

```bash
bash skills/agentmail/scripts/mail-db.sh count
```

### Read Messages

Read all unread messages and mark them as read:

```bash
bash skills/agentmail/scripts/mail-db.sh read
```

Read a specific message by ID:

```bash
bash skills/agentmail/scripts/mail-db.sh read 42
```

### Send a Message

```bash
bash skills/agentmail/scripts/mail-db.sh send "<target-project>" "<subject>" "<body>"
```

**Examples:**

```bash
# Simple notification
bash skills/agentmail/scripts/mail-db.sh send "some-api" "Auth ready" "OAuth2 endpoints are implemented and tested on branch feature/oauth2"

# Request for action
bash skills/agentmail/scripts/mail-db.sh send "frontend" "API contract changed" "The /api/users endpoint now returns {data: User[], meta: {total: number}} instead of a flat array. See commit abc123."

# Broadcast to multiple projects
for project in frontend some-api; do
  bash skills/agentmail/scripts/mail-db.sh send "$project" "Main is broken" "Do not merge until fix lands - CI is red"
done
```

### List Messages

Show recent messages (read and unread):

```bash
bash skills/agentmail/scripts/mail-db.sh list        # Last 20
bash skills/agentmail/scripts/mail-db.sh list 50      # Last 50
```

### List Known Projects

Show all projects that have sent or received mail:

```bash
bash skills/agentmail/scripts/mail-db.sh projects
```

### Cleanup

Delete old read messages:

```bash
bash skills/agentmail/scripts/mail-db.sh clear        # Older than 7 days
bash skills/agentmail/scripts/mail-db.sh clear 30      # Older than 30 days
```

## Passive Notification (Hook)

The `hooks/check-mail.sh` hook provides passive notification. It:

1. Runs on every tool call (PreToolUse matcher: `*`)
2. Checks `~/.claude/mail.db` for unread messages where `to_project` matches current directory name
3. Outputs nothing if inbox is empty (zero overhead)
4. Shows count + preview of up to 3 messages when mail exists

### Hook Output Example

```
=== MAIL: 2 unread message(s) ===
  From: some-api  |  Auth endpoints ready
  From: frontend  |  Need updated types
Use /mail to read messages.
===
```

## When to Use

**Send messages when:**
- You've completed work another session depends on
- An API contract or shared interface changed
- A shared branch (main) is broken or fixed
- You need input from a session working on a different project

**The hook handles receiving automatically.** When this skill triggers from a user saying "check mail" or "read messages", run the read command.

## Database

Single SQLite file at `~/.claude/mail.db`. Schema:

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_project TEXT NOT NULL,
    to_project TEXT NOT NULL,
    subject TEXT DEFAULT '',
    body TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now')),
    read INTEGER DEFAULT 0
);
```

Database is auto-created on first use. Not inside any git repo - no gitignore needed.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `sqlite3: not found` | Install sqlite3 (ships with most OS installs, Git Bash on Windows) |
| Hook not firing | Check hook is registered in `.claude/settings.json` or `.claude/settings.local.json` |
| Wrong project name | Hook uses `basename $PWD` - ensure cwd is the project root |
| Messages not arriving | Check `to_project` matches target's directory basename exactly |
