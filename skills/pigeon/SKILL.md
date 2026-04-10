---
name: pigeon
description: "Inter-session pmail - send and receive messages between Claude Code sessions running in different project directories. Uses global SQLite database at ~/.claude/pmail.db. Triggers on: mail, pmail, send message, check mail, inbox, inter-session, message another session, pigeon."
license: MIT
allowed-tools: "Read Bash Grep"
metadata:
  author: claude-mods
  related-skills: sqlite-ops
---

# Pigeon

Inter-session messaging for Claude Code. Send and receive pmail between sessions running in different projects.

## Quick Reference

All commands go through `MAIL`, a shorthand for `bash "$HOME/.claude/pigeon/mail-db.sh"`.

Set this at the top of execution:

```bash
MAIL="$HOME/.claude/pigeon/mail-db.sh"
```

Then use it for all commands below.

## Command Router

Parse the user's input after `pigeon` (or `/pigeon`) and run the matching command:

| User says | Run |
|-----------|-----|
| `pigeon read` | `bash "$MAIL" read` |
| `pigeon read 42` | `bash "$MAIL" read 42` |
| `pigeon send <project> "<subject>" "<body>"` | `bash "$MAIL" send "<project>" "<subject>" "<body>"` |
| `pigeon send --urgent <project> "<subject>" "<body>"` | `bash "$MAIL" send --urgent "<project>" "<subject>" "<body>"` |
| `pigeon send --attach <path> <project> "<subject>" "<body>"` | `bash "$MAIL" send --attach "<path>" "<project>" "<subject>" "<body>"` |
| `pigeon reply <id> "<body>"` | `bash "$MAIL" reply <id> "<body>"` |
| `pigeon reply --attach <path> <id> "<body>"` | `bash "$MAIL" reply --attach "<path>" <id> "<body>"` |
| `pigeon broadcast "<subject>" "<body>"` | `bash "$MAIL" broadcast "<subject>" "<body>"` |
| `pigeon search <keyword>` | `bash "$MAIL" search "<keyword>"` |
| `pigeon status` | `bash "$MAIL" status` |
| `pigeon unread` | `bash "$MAIL" unread` |
| `pigeon list` | `bash "$MAIL" list` |
| `pigeon list 50` | `bash "$MAIL" list 50` |
| `pigeon projects` | `bash "$MAIL" projects` |
| `pigeon clear` | `bash "$MAIL" clear` |
| `pigeon clear 7` | `bash "$MAIL" clear 7` |
| `pigeon alias <old> <new>` | `bash "$MAIL" alias "<old>" "<new>"` |
| `pigeon purge` | `bash "$MAIL" purge` |
| `pigeon purge --all` | `bash "$MAIL" purge --all` |
| `pigeon id` | `bash "$MAIL" id` |
| `pigeon migrate` | `bash "$MAIL" migrate` |
| `pigeon init` | `bash "$MAIL" init` |

When the user just says "check mail", "read mail", "inbox", "any mail?", or "any pmail?" - run `bash "$MAIL" read`.

When the user says "send mail to X", "send pmail to X", or "message X" - parse out the project name, subject, and body, then run `bash "$MAIL" send`.

## Project Identity

Each project gets a stable 6-character hash ID derived from its **git root commit** (the very first commit in the repo). This means:

- IDs survive directory renames, moves, and clones
- Case-insensitive filesystems (macOS) don't cause collisions
- Every clone of the same repo shares the same identity

For non-git directories, falls back to a hash of the canonical path (`pwd -P`).

Use `pigeon id` to see your project's name and hash:

```
claude-mods 7663d6
```

When sending messages, you can address projects by **name**, **hash**, or **path** - they all resolve to the same hash ID.

### Identicons

Each project hash renders as a unique pixel-art identicon (11x11 symmetric grid using Unicode half-block characters). Run `identicon.sh` to see yours, or view all projects with `pigeon projects`.

## Passive Notification (Hook)

A global PreToolUse hook checks for pmail on every tool call (no cooldown). Silent when inbox is empty.

```
=== PMAIL: 3 unread message(s) ===
  From: some-api  |  Auth endpoints ready
  From: frontend  |  Need updated types
  ... and 1 more
Use pigeon read to read messages.
```

## Attachments

Send file references with `--attach <path>` (repeatable). Paths are resolved to absolute and stored as references - files are not copied.

```bash
# Send with one attachment
pigeon send --attach src/config.ts my-api "Config update" "Updated the auth config"

# Send with multiple attachments
pigeon send --attach src/schema.sql --attach docs/API.md my-api "Schema + docs" "See attached"

# Reply with attachment
pigeon reply --attach output/report.json 42 "Here's the analysis"
```

Recipients see attachment paths with file sizes and can read them directly with the Read tool. If a file has been moved or deleted since sending, it shows as `(missing)`.

## When to Send

- You've completed work another session depends on
- An API contract or shared interface changed
- A shared branch (main) is broken or fixed
- You need input from a session working on a different project

## Per-Project Disable

```bash
touch .claude/pigeon.disable    # Disable hook notifications
rm .claude/pigeon.disable       # Re-enable
```

Only the hook is disabled - you can still send messages from the project.

---

## Installation

Pigeon requires two things: **scripts** (the mail engine) and a **hook** (passive notifications). Both install globally - one setup, every project gets pmail.

### Prerequisites

- `sqlite3` - ships with macOS, most Linux distros, and Git Bash on Windows. No install needed.

### Step 1: Copy Scripts

```bash
mkdir -p ~/.claude/pigeon
cp skills/pigeon/scripts/mail-db.sh ~/.claude/pigeon/
cp hooks/check-mail.sh ~/.claude/pigeon/
chmod +x ~/.claude/pigeon/mail-db.sh ~/.claude/pigeon/check-mail.sh
```

This gives you the pmail commands. You can now send and read messages manually:

```bash
bash ~/.claude/pigeon/mail-db.sh init      # Create database
bash ~/.claude/pigeon/mail-db.sh status    # Check it works
```

### Step 2: Enable the Hook

Add a `hooks` block to `~/.claude/settings.json`. This makes Claude check for pmail automatically on every tool call:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/pigeon/check-mail.sh\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Important:** If you already have a `hooks` section in your settings, merge the PreToolUse entry into the existing array - don't replace the whole block.

Without this step, pigeon still works but you have to check manually (`pigeon read`). With the hook, unread pmail appears automatically.

### What Gets Created

```
~/.claude/
  settings.json            # Hook config (you edit this)
  pmail.db                 # Message store (auto-created on first use)
  pigeon/
    mail-db.sh             # All pmail commands (send, read, reply, etc.)
    check-mail.sh          # PreToolUse hook (silent when inbox empty)
```

### Verify

```bash
# Check your project identity
bash ~/.claude/pigeon/mail-db.sh id

# Send yourself a test message (use your project name from above)
bash ~/.claude/pigeon/mail-db.sh send "my-project" "Test" "Hello from pigeon"

# Check it arrived
bash ~/.claude/pigeon/mail-db.sh read

# Clean up
bash ~/.claude/pigeon/mail-db.sh purge --all
```

### Uninstall

```bash
rm -rf ~/.claude/pigeon ~/.claude/pmail.db
# Then remove the hooks.PreToolUse entry from ~/.claude/settings.json
```

## Database

Single SQLite file at `~/.claude/pmail.db`. Auto-created on first `init` or `send`.

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
| Messages not arriving | Target must be a known name, hash, or path. Use `pigeon projects` to see registered projects |
| Upgraded from basename IDs | Run `pigeon migrate` to convert old messages to hash-based IDs |
| Changed display name | Use `pigeon alias old-name new-name` to update the project's display name |
| Want to disable for one project | `touch .claude/pigeon.disable` in that project's root |
| Check your project ID | Run `pigeon id` to see name and 6-char hash |
