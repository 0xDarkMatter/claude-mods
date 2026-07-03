---
name: summon
description: "Transfer Claude Desktop Code-tab sessions between Claude accounts — copy (default) or move (--move) the session metadata file so the session shows up in another account's left-hand sidebar (the session picker on the left side of Desktop's Code tab). Two natural framings: push (run while still on your current near-limit account, send sessions to the next one, then Logout/Login as the natural switch) or pull (after switching accounts, bring earlier sessions into the now-active one). Push is the recommended workflow because the Logout/Login becomes invisible — it IS the switch you were going to do anyway. Triggers on: summon, summon sessions, push sessions, pull sessions, before switching accounts, account approaching usage limit, account ran out of usage, prepare next account, mid-flight desktop sessions, claude desktop multi-account workflow, transfer claude desktop sessions across accounts, peek session, see desktop sessions across accounts. Default copy keeps the session visible in both accounts' sidebars; --move for lean cleanup. Transcript JSONLs are account-agnostic and stay where they are — both wrappers point at the same conversation. No API calls, no summarisation, full transcripts intact. The left-hand session picker is loaded at login, so a Logout/Login on the destination is required for new sessions to appear there."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
---

# Summon

Copy (or move) Claude Desktop Code-tab sessions across accounts so they're visible from the account you switch to next. Full transcripts intact; no API calls; no summarisation.

## When to run it

**Before you switch accounts**, not after. The natural workflow:

1. Notice you're approaching usage limit on the account you're currently using
2. Run `summon --to <next-account>` — sessions get copied (default) into the next account's dir
3. Logout from current account in Desktop → Login to the new account
4. **All your mid-flight sessions appear in the new account's left-hand session picker** (the sidebar on the left side of Desktop's Code tab). The Logout/Login is the natural switch you were going to do anyway.

Running summon *after* hitting the usage limit also works — the file moves are pure local ops, no API needed — but you'll still need to Logout/Login on the destination to see the sessions, since Desktop's session list is cached at login. Doing it proactively just means the Logout/Login is no longer "extra friction," it's the same step you'd be doing anyway.

## Mental model

Each Desktop session has two halves:

| Half | Location | Account-bound? |
|------|----------|----------------|
| Metadata JSON | `%APPDATA%/Claude/claude-code-sessions/<account>/<workspace>/local_<uuid>.json` | **Yes** — lives under `<account>` |
| Transcript JSONL | `~/.claude/projects/<encoded-cwd>/<cli-uuid>.jsonl` | **No** — global, shared |

Summon copies (or with `--move`, relocates) the metadata wrapper into the destination account's dir. The transcript stays put — both wrappers point at the same conversation. After Logout/Login on the destination, the new entries appear in the **left-hand session picker** (Desktop's Code-tab sidebar).

## Run

```bash
# Wrapper (after install — see below)
summon [flags]

# Or direct
python ~/.claude/skills/summon/scripts/summon.py [flags]
```

Default behaviour: list candidate sessions across **all non-destination accounts**, grouped Account → Project → Session, then prompt to copy them into the destination account. **Copy semantics by default** — sessions remain visible in the source account too. Last 3 days; remote-VM sessions auto-skipped.

Two natural framings of the same operation:

- **Push** (proactive): you're approaching usage limit on your current account. Run `summon --to <next-account>` while still on the current one. Pick which sessions to push. Then Logout/Login is the account switch you were going to do anyway.
- **Pull** (rescue): you've already switched accounts and want to bring earlier sessions over. Run `summon` (no `--to`); destination defaults to your now-current account.

Mechanically identical — the file moves are the same regardless of which framing you have in mind. Push is the recommended workflow because the Logout/Login becomes invisible.

### Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--to <account>` | most-recently-active account | Destination — where the sessions land. Specify when **pushing** to a different account; omit when **pulling** into your current account. UUID prefix or email substring |
| `--from <account>` | all non-destination accounts | Restrict source to one account |
| `--days N` | 3 | Time window |
| `--all` | | Disable time filter |
| `--cwd <pattern>` | | Substring match against session cwd |
| `--title <pattern>` | | Substring match against session title |
| `--pick` | | Interactive multi-select by number |
| `--move` | | Move instead of copy — delete source after copying (lean cleanup) |
| `--dry-run` | | Preview without touching files |
| `--list-accounts` | | Show all accounts and exit |
| `--peek <id>` | | Preview a session's last messages and exit (id prefix or full) |
| `--flat` | | Flat list instead of grouped hierarchy |
| `--select <picks>` | | Non-interactive selection: `--select "1,2,4"` or `--select all`. Replaces the picker prompt for scripted callers |
| `--yes` | | Skip the final confirmation prompt only — selection is still required (picker prompt, piped stdin, or `--select`) |

## Auto-detect rules

- **Destination**: account with the most recent filesystem activity (mtime of any session JSON). This reliably tracks the active Desktop account.
- **Source**: by default, all accounts except destination. Use `--from <account>` to restrict to one.
- **Workspace dir under destination**: most-recently-active existing workspace. New UUID is created if the destination has no workspaces yet.

## Display

Output follows the [Terminal Panel Design System](../../docs/TERMINAL-DESIGN.md) (panel header, body with `│` rail, footer, ASCII fallback when stdout isn't UTF-8). The candidate hierarchy is **Account → Project → Session**, with sessions globally numbered for picker selection (`3, 5, 7`).

```
╭── 🪄 summon ──────────────────────────────────────────────── → mknv74 ───●
│
├── 4 sessions · from 1 account · last 3d
│
├── dev@example.com (4)
│   ├── X:\Projects\Axiom (2)
│   │   ├──  1. train-fasttext                    30t            16h
│   │   └──  2. make-doom-for-mips                64t            16h
│   └── X:\Work\client-site (2)
│       ├──  3. timekeeper                        35t            16h
│       └──  4. agency-os                         17t            16h
│
│   💡  best run BEFORE switching accounts: copy sessions to the next
│       account first, then Logout/Login (the switch you were doing anyway)
│
╰── # select · a all · blank cancel ───────────────────────────────────●
```

Header shows `→ destination`. Summary line shows count, source breadth, and active filter window. Body shows Account → Project → Session hierarchy with global numbering for picker selection (`3,5,7`). A rotating hint tile sits above the footer; the footer shows the active hotkeys.

## Edge cases handled

| Case | Behaviour |
|------|-----------|
| Session cwd is `/sessions/<vm>/mnt` (remote) | Skipped — no local transcript to bridge |
| Transcript JSONL missing on disk | Skipped with warning (orphan metadata) |
| Same `sessionId` already in destination | Skipped (idempotent) |
| Destination has no workspace dirs | New workspace UUID created |
| Stdout is not UTF-8 (Windows cp1252) | ASCII fallback for all panel glyphs |
| Stdout is not a TTY or `NO_COLOR` set | Plain text, no ANSI escapes |

## Sidebar refresh

Desktop loads sessions into its left-hand session picker on login and doesn't watch the filesystem afterwards (verified via bundle inspection — no `chokidar`, no relevant `fs.watch` on the session dir, only direct `fs.readdir` calls). Summon throws a best-effort nudge at fs.watch (sentinel pings, mtime touches, rename ping-pong) but **don't rely on it** — assume Logout/Login is required to populate the sidebar with new sessions.

This is why summon is best run **before switching accounts**: the Logout/Login is what you'd do anyway. Running summon as a "rescue" after the fact still works mechanically, but the Logout/Login still has to happen.

If sessions still don't appear:

1. Try View → Reload (rarely helps; Ctrl+R only re-renders)
2. **Logout → Login** triggers a full filesystem rescan and always works

## Wrapper install

Symlink (or copy) the wrapper into a directory on `PATH`:

```bash
# Linux/macOS/Git Bash
ln -s ~/.claude/skills/summon/bin/summon ~/.local/bin/summon

# Windows (PowerShell)
copy "$env:USERPROFILE\.claude\skills\summon\bin\summon.cmd" "$env:USERPROFILE\bin\summon.cmd"
```

Then `summon --pick` works directly from any shell.

## Architecture reference

Full file system layout, session schemas, account binding, and the validated cross-account transfer procedure live in `docs/references/claude-desktop-internals.md` (claude-mods). That document is canonical; this skill is the operating manual.

## Anti-patterns

- **Waiting until you've already hit the limit** — the file moves still work, but you've burned the chance to wrap up your current message before switching. Run summon proactively while you still have usage on the source.
- **Expecting sessions to appear in the sidebar without Logout/Login** — Desktop's session list is loaded on login; the kitchen-sink fs.watch nudge is best-effort and shouldn't be relied on. The Logout/Login becomes painless if you've timed summon as a *push* before switching.
- **Running while Desktop is mid-write to a session JSON** — quit Desktop first if you've literally just closed the session you want to push.
- **Trying to summon remote sessions** — they have no local transcript and can't be transferred.
- **Hardcoding account UUIDs** — use `--list-accounts` first, then email substring (more readable, less brittle).
- **Treating this as a transfer for archived sessions** — it's for mid-flight work; archived sessions belong in the source account's archive view.
- **Using `--move` for sessions you might want to access from both accounts** — copy is default precisely because multi-account workflows are the common case.
