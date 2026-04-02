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
| `agentmail id` | `bash "$MAIL" id` |
| `agentmail migrate` | `bash "$MAIL" migrate` |
| `agentmail init` | `bash "$MAIL" init` |

When the user just says "check mail", "read mail", "inbox", or "any mail?" - run `bash "$MAIL" read`.

When the user says "send mail to X" or "message X" - parse out the project name, subject, and body, then run `bash "$MAIL" send`.

## Project Identity

Each project gets a stable 6-character hash ID derived from its **git root commit** (the very first commit in the repo). This means:

- IDs survive directory renames, moves, and clones
- Case-insensitive filesystems (macOS) don't cause collisions
- Every clone of the same repo shares the same identity

For non-git directories, falls back to a hash of the canonical path (`pwd -P`).

Use `agentmail id` to see your project's name and hash:

```
claude-mods 7663d6
```

When sending messages, you can address projects by **name**, **hash**, or **path** - they all resolve to the same hash ID.

### Identicons

Each project hash renders as a unique pixel-art identicon (11x11 symmetric grid using Unicode half-block characters). Run `identicon.sh` to see yours, or view all projects with `agentmail projects`.

## Passive Notification (Hook)

A global PreToolUse hook checks for mail on every tool call (no cooldown). Silent when inbox is empty.

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

Agentmail requires two things: **scripts** (the mail engine) and a **hook** (passive notifications). Both install globally - one setup, every project gets mail.

### Prerequisites

- `sqlite3` - ships with macOS, most Linux distros, and Git Bash on Windows. No install needed.

### Step 1: Copy Scripts

```bash
mkdir -p ~/.claude/agentmail
cp skills/agentmail/scripts/mail-db.sh ~/.claude/agentmail/
cp hooks/check-mail.sh ~/.claude/agentmail/
chmod +x ~/.claude/agentmail/mail-db.sh ~/.claude/agentmail/check-mail.sh
```

This gives you the mail commands. You can now send and read messages manually:

```bash
bash ~/.claude/agentmail/mail-db.sh init      # Create database
bash ~/.claude/agentmail/mail-db.sh status    # Check it works
```

### Step 2: Enable the Hook

Add a `hooks` block to `~/.claude/settings.json`. This makes Claude check for mail automatically on every tool call (with a no cooldown so it doesn't slow anything down):

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

**Important:** If you already have a `hooks` section in your settings, merge the PreToolUse entry into the existing array - don't replace the whole block.

Without this step, agentmail still works but you have to check manually (`agentmail read`). With the hook, unread mail appears automatically.

### What Gets Created

```
~/.claude/
  settings.json            # Hook config (you edit this)
  mail.db                  # Message store (auto-created on first use)
  agentmail/
    mail-db.sh             # All mail commands (send, read, reply, etc.)
    check-mail.sh          # PreToolUse hook (silent when inbox empty)
```

### Verify

```bash
# Check your project identity
bash ~/.claude/agentmail/mail-db.sh id

# Send yourself a test message (use your project name from above)
bash ~/.claude/agentmail/mail-db.sh send "my-project" "Test" "Hello from agentmail"

# Check it arrived
bash ~/.claude/agentmail/mail-db.sh read

# Clean up
bash ~/.claude/agentmail/mail-db.sh purge --all
```

### Uninstall

```bash
rm -rf ~/.claude/agentmail ~/.claude/mail.db
# Then remove the hooks.PreToolUse entry from ~/.claude/settings.json
```

## Database

Single SQLite file at `~/.claude/mail.db`. Auto-created on first `init` or `send`.

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_project TEXT NOT NULL,   -- 6-char hash ID
    to_project TEXT NOT NULL,     -- 6-char hash ID
    subject TEXT DEFAULT '',
    body TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now')),
    read INTEGER DEFAULT 0,
    priority TEXT DEFAULT 'normal'
);

CREATE TABLE projects (
    hash TEXT PRIMARY KEY,        -- 6-char ID (git root commit or path hash)
    name TEXT NOT NULL,           -- Display name (basename of project dir)
    path TEXT NOT NULL,           -- Canonical path
    registered TEXT DEFAULT (datetime('now'))
);
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `sqlite3: not found` | Ships with macOS, Linux, and Git Bash on Windows. Run `sqlite3 --version` to check. |
| Hook not firing | Ensure `hooks` block is in `~/.claude/settings.json` (Step 2 above) |
| Hook fires but no notification | Working as intended - hook is silent when inbox is empty |
| Messages not arriving | Target must be a known name, hash, or path. Use `agentmail projects` to see registered projects |
| Upgraded from basename IDs | Run `agentmail migrate` to convert old messages to hash-based IDs |
| Changed display name | Use `agentmail alias old-name new-name` to update the project's display name |
| Want to disable for one project | `touch .claude/agentmail.disable` in that project's root |
| Check your project ID | Run `agentmail id` to see name and 6-char hash |
