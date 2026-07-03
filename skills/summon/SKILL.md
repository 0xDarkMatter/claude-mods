---
name: summon
description: "Claude Desktop session toolbox: cross-account transfer, recovery picker, cwd rebind after folder moves, and a session-store doctor. Transfer (default mode): copy (default) or move (--move) the session metadata file so the session shows up in another account's left-hand sidebar — push (run while still on your current near-limit account, send sessions to the next one, then Logout/Login as the natural switch) or pull (after switching, bring earlier sessions into the now-active one); push is recommended because the Logout/Login IS the switch you were doing anyway. Toolbox modes: `summon pick` / `summon recover <id>` (picker over the whole session store that resolves the transcript JSONL — handling the wrapper-uuid vs transcript-filename trap — extracts the conversation in-script, distills it into a handover brief via one tool-less `claude -p` Sonnet call cached at `<transcript>.handover.md`, and emits a ready-to-paste handover for a new session; degrades to a plain pointer prompt when the `claude` CLI is unavailable, `--no-distill` to force that, `--refresh` to re-distill), `summon rebind <id> --cwd <newpath>` (fix a session's recorded cwd after a project folder moves, with backup + transcript bridging), `summon doctor` (scan all sessions for broken cwd bindings and report which need rebinding). Triggers on: summon, summon sessions, push sessions, pull sessions, before switching accounts, account approaching usage limit, account ran out of usage, prepare next account, mid-flight desktop sessions, claude desktop multi-account workflow, transfer claude desktop sessions across accounts, peek session, see desktop sessions across accounts, recover session, resume old session, handover brief, session picker, rebind session, moved project folder, session cwd broken, session won't reopen after folder move, broken session bindings, session doctor. Default copy keeps the session visible in both accounts' sidebars; transcript JSONLs are account-agnostic and stay where they are. Transfer makes no API calls and keeps full transcripts intact; recover's distillation is the only LLM call — one gated, tool-less `claude -p`. The left-hand session picker is loaded at login, so a Logout/Login on the destination is required for new sessions to appear there."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
---

# Summon

Claude Desktop session toolbox. Four jobs, one store:

| Mode | Invocation | Job |
|------|-----------|-----|
| **Transfer** (default) | `summon [flags]` | Copy/move sessions across accounts so they're visible from the account you switch to next |
| **Pick / Recover** | `summon pick` · `summon recover <id>` | Find a past session, resolve its transcript, distill a handover brief, emit a paste-ready handover for a new session |
| **Rebind** | `summon rebind <id> --cwd <newpath>` | Fix a session's recorded cwd after the project folder moved |
| **Doctor** | `summon doctor [--json]` | Scan every session for broken cwd bindings; report which need rebinding |

Transfer touches no transcripts and makes no API calls. Recover/pick make exactly one optional, gated LLM call (the distillation) and degrade gracefully without it. Transfer is documented first; the toolbox modes follow under [Toolbox modes](#toolbox-modes-pick--recover--rebind--doctor).

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

**The uuid-mismatch trap.** The wrapper filename uuid (`local_<uuid>.json` / `sessionId`) does **not** name the transcript — the transcript file is named by the wrapper's `cliSessionId`, a different uuid (e.g. wrapper `local_6577b24c-…` → transcript `e640a2a8-….jsonl`). And the transcript's parent dir is the *munged cwd* (`X:\Roam\LCMap\.claude\worktrees\funny-hypatia-5e54f7` → `X--Roam-LCMap--claude-worktrees-funny-hypatia-5e54f7`), which occasionally doesn't derive from the wrapper's recorded cwd at all. All toolbox modes resolve via `cliSessionId` at the expected munged path first, then fall back to scanning every project dir for `<cliSessionId>.jsonl`.

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

## Toolbox modes (pick / recover / rebind / doctor)

Semantic exit codes across all modes: `0` ok, `2` usage/ambiguous id, `3` session or path not found, `10` doctor found broken sessions.

### `summon pick` — session picker → distilled handover

Interactive picker over the **whole** session store (all accounts, default last 30 days — `--days N`/`--all` to widen, `--cwd`/`--title` to narrow). Uses `fzf` when it's on PATH and the terminal is interactive; falls back to a numbered list (`--select N` answers it non-interactively). A `●` marks sessions active in the last 10 minutes — don't recover a session that's still running.

Selecting a session emits a **paste-ready handover on stdout** (context panel and progress on stderr, so `summon pick | clip` stays clean). Same output as `recover`, below.

### `summon recover <id>` — distilled handover brief

`summon recover 6577b24c` — id is a `sessionId` or `cliSessionId`, prefix ok. Four-stage flow:

1. **Extract** (in-script, no LLM): parses the transcript JSONL and pulls conversational content only — user/assistant text turns, skipping `tool_result` blobs and `tool_use` inputs (they are most of the bytes). The final ~15 turns are included verbatim; earlier turns fill the remaining budget from the start (so the goal statement survives), middle elided when too long. Total capped at a char budget (`--budget`, default 120k).
2. **Distill** (cheap, tool-less): pipes the extraction to a single `claude -p --model sonnet --permission-mode dontAsk` call — one-shot stdin summarisation, no tools, no agentic loop, never `bypassPermissions` (per `rules/loop-engineering.md`). Produces a brief with fixed sections: **Goal / What landed** (branch + commits if mentioned) **/ Unfinished / Open decisions / Key context**, ~1k-word cap. `--model` overrides sonnet.
3. **Cache**: the brief is written to `<transcript-path>.handover.md` next to the JSONL and reused while it's newer than the transcript's mtime. `--refresh` forces re-distillation.
4. **Emit** (stdout = the data product): the brief inline plus a pointer clause:

```
Continue a previous Claude session: 'Fix overlapping photo pins with gentle displacement'.
Branch: claude/funny-hypatia-5e54f7

## Goal
…
## What landed
…
## Unfinished
…
## Open decisions
…
## Key context
…

Full transcript at C:\Users\Mack\.claude\projects\X--Roam-LCMap-…\e640a2a8-….jsonl (session 6577b24c-…, branch claude/funny-hypatia-5e54f7); consult it only if something specific is missing.
```

**Degrade, never hard-fail**: if the `claude` CLI is absent from PATH, or the call fails/times out (60s), recover falls back to the classic non-distilled pointer prompt (Title/Branch/Orig cwd/Transcript + tail-reading instruction) with a stderr warning and **exit 0** — worker unavailability is advisory, not an error. `--no-distill` forces the fallback (no LLM call at all).

| Flag | Default | Effect |
|------|---------|--------|
| `--no-distill` | | Skip the LLM distillation; emit the plain pointer prompt |
| `--refresh` | | Ignore a cached `<transcript>.handover.md` and re-distill |
| `--model <m>` | `sonnet` | Model for the distillation call |
| `--budget <n>` | `120000` | Char budget for the transcript extraction fed to the distiller |

### `summon rebind <id> --cwd <newpath>` — fix cwd after a folder move

When a project folder moves (e.g. `X:\Roam\LCMap` → `X:\Maplab\LCMap`), sessions bound to the old cwd fail to restart in the Desktop UI. Rebind repairs the binding:

```bash
summon rebind 6577b24c --cwd "X:\Maplab\LCMap\.claude\worktrees\funny-hypatia-5e54f7"
```

1. **Backs up** every matching wrapper to `~/.claude/summon-backups/<timestamp>/` (outside the live store) before touching anything
2. **Atomically rewrites** `cwd`, and rebases `originCwd`/`worktreePath` (worktree sessions record the project *root* in `originCwd` — the suffix math is handled)
3. **Bridges the transcript**: Desktop resolves the transcript via the munged *new* cwd, so the `<cliSessionId>.jsonl` is copied (never moved) into the new munged project dir. `--no-transcript` skips this
4. **Verifies** by re-reading the wrapper; on mismatch it restores from the backup
5. If the same session was transfer-copied into several accounts, **all copies are rebound**
6. When the new cwd is inside a `.claude\worktrees\` path, prints a reminder that **git worktree links break on folder moves** — run `git worktree repair <new-worktree-path>` from the repo root (verified fix 2026-07-03 on X:\Maplab\LCMap)

`--dry-run` previews; `--force` allows a `--cwd` that doesn't exist yet. The new cwd must normally exist on disk. After a rebind, restart Desktop (or Logout/Login) so the sidebar re-reads the wrapper.

Wrapper edit + backup + transcript bridge are verified against the live store (throwaway-session test, 2026-07-03). End-to-end "session reopens in the Desktop UI after rebind" — confirm on your first real rebind before bulk-rebinding.

### `summon doctor` — find broken sessions

Scans **every** wrapper (all accounts, all time) and reports sessions whose recorded cwd no longer exists on disk, with a ready-made `summon rebind <id> --cwd <new-location>` line per finding. Also counts transcript-missing and found-by-scan sessions. Exit `10` when anything is broken; `--json` emits a `claude-mods.summon.doctor/v1` envelope for scripted use:

```bash
summon doctor --json | jq -r '.data[] | "\(.sessionId)  \(.cwd)"'
```

Broken-cwd findings are mostly **pruned worktrees** (the session ended, the worktree was cleaned — nothing to fix unless you want to recover it, which needs no rebind: `summon recover` works regardless of cwd) and **moved project folders** (the real rebind case).

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

Then `summon pick`, `summon doctor`, etc. work directly from any shell.

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
- **Rebinding without checking the new path** — `rebind` refuses a nonexistent `--cwd` for a reason; a typo'd rebind is two edits instead of one. `--force` is for pre-creating bindings, not for skipping the check.
- **Recovering by pasting the whole transcript** — the handover brief exists so the new session starts from a distilled summary and consults the JSONL only for specifics. Feeding a full multi-MB transcript into a fresh session burns the context you were trying to save.
- **Re-distilling on every recover** — the brief is cached at `<transcript>.handover.md` and reused while the transcript is unchanged; reach for `--refresh` only when the session has genuinely moved on since the cache was written.
