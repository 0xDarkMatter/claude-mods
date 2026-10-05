---
name: summon
description: "Claude Desktop session toolbox: transfer sessions between accounts, recover an old session via a picker + AI handover brief, rebind cwd after a folder move, audit broken bindings, render an in-chat picker. Triggers on: summon, transfer/recover session, session picker, rebind, session doctor."
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

**The uuid-mismatch trap:** the transcript is named by the wrapper's `cliSessionId`, not its `sessionId`, and may not sit under the wrapper's munged cwd. Every mode resolves by `cliSessionId` with a scan fallback: [references/session-store.md](references/session-store.md).

## Run

```bash
# Wrapper (after install — see below)
summon [flags]

# Or direct
python ~/.claude/skills/summon/scripts/summon.py [flags]
```

Default behaviour: list candidate sessions across **all non-destination accounts**, grouped Account → Project → Session, then prompt to copy them into the destination account. **Copy semantics by default** — sessions remain visible in the source account too. Last 3 days; remote-VM sessions auto-skipped.

Push (`--to <next-account>` before switching) and pull (no `--to`, after switching) are mechanically identical; push is recommended. [references/transfer.md](references/transfer.md#push-vs-pull).

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

`summon pick --json` emits the inventory as a `claude-mods.summon.pick/v1` envelope (no picker); `--json --rich` adds display metrics as `pick/v2`, the card picker's feed. Keys: [references/toolbox-modes.md](references/toolbox-modes.md).

### `summon recover <id>` — distilled handover brief

`summon recover 6577b24c` — id is a `sessionId` or `cliSessionId`, prefix ok. Four-stage flow:

Extract turns (no LLM), distill with one tool-less `claude -p --model sonnet` call, cache at `<transcript>.handover.md`, emit the brief plus a transcript pointer on stdout. Detail and sample: [references/toolbox-modes.md](references/toolbox-modes.md).

**Degrade, never hard-fail**: if the `claude` CLI is absent from PATH, or the call fails/times out (60s), recover falls back to the classic non-distilled pointer prompt (Title/Branch/Orig cwd/Transcript + tail-reading instruction) with a stderr warning and **exit 0** — worker unavailability is advisory, not an error. `--no-distill` forces the fallback (no LLM call at all).

| Flag | Default | Effect |
|------|---------|--------|
| `--no-distill` | | Skip the LLM distillation; emit the plain pointer prompt |
| `--refresh` | | Ignore a cached `<transcript>.handover.md` and re-distill |
| `--model <m>` | `sonnet` | Model for the distillation call |
| `--budget <n>` | `120000` | Char budget for the transcript extraction fed to the distiller |

### `summon rebind <id> --cwd <newpath>` — fix cwd after a folder move

When a project folder moves (e.g. `D:\code\myapp` → `D:\archive\myapp`), sessions bound to the old cwd fail to restart in the Desktop UI. Rebind repairs the binding:

```bash
summon rebind 6577b24c --cwd "D:\archive\myapp\.claude\worktrees\funny-hypatia-5e54f7"
```

Backs up, rewrites and verifies the wrapper (every account's copy) and bridges the transcript. **For a worktree path, run `git worktree repair <new-worktree-path>` from the repo root**; worktree links break on folder moves. Steps: [references/toolbox-modes.md](references/toolbox-modes.md).

`--dry-run` previews; `--force` allows a `--cwd` that doesn't exist yet. The new cwd must normally exist on disk. After a rebind, restart Desktop (or Logout/Login) so the sidebar re-reads the wrapper.

Wrapper edit + backup + transcript bridge are verified against the live store (throwaway-session test, 2026-07-03). End-to-end "session reopens in the Desktop UI after rebind" — confirm on your first real rebind before bulk-rebinding.

### `summon doctor` — find broken sessions

Scans **every** wrapper (all accounts, all time) and reports sessions whose recorded cwd no longer exists on disk, with a ready-made `summon rebind <id> --cwd <new-location>` line per finding. Also counts transcript-missing and found-by-scan sessions. Exit `10` when anything is broken; `--json` emits a `claude-mods.summon.doctor/v1` envelope for scripted use:

```bash
summon doctor --json | jq -r '.data[] | "\(.sessionId)  \(.cwd)"'
```

Broken-cwd findings are mostly **pruned worktrees** (the session ended, the worktree was cleaned — nothing to fix unless you want to recover it, which needs no rebind: `summon recover` works regardless of cwd) and **moved project folders** (the real rebind case).

## In-chat mode (visual card picker) — the default for picking sessions

When summon is invoked from **inside a Claude chat session** (Desktop chat, claude.ai), the terminal picker can't run interactively — stdin isn't a TTY, so fzf and the numbered prompt are out. **This card picker is the default way to present sessions in chat** — reach for it whenever the user asks to see, pick, recover, or summon sessions, not just when they say "picker".

1. Run **`summon widget --days 30`** (add `--cwd`/`--title` filters as asked). It prints the **finished, self-contained card-picker HTML on stdout** — the rich inventory already trimmed and injected into the template.
2. **Pass that stdout straight to the `show_widget` tool** as `widget_code`. That's the whole job: no manual injection, no key-trimming, no reading a file back. The builder also writes the same HTML to `%TEMP%\claude\summon-widget.html` (override with `--out`), so you can `Read` it if you'd rather not re-run.

> **Don't hand-assemble the widget.** `show_widget` takes only inline code, and a hand-merged file trips the 25k-token `Read` cap. Why, and the trimming flags: [references/in-chat-picker.md](references/in-chat-picker.md).

Widget features, and the optional per-row `summary` that replaces `firstAsk`: [references/in-chat-picker.md](references/in-chat-picker.md).

**Manual fallback** (only if `summon widget` is unavailable): inject `pick --json --rich` output into [`assets/picker-widget.html`](assets/picker-widget.html); steps in [references/in-chat-picker.md](references/in-chat-picker.md).

3. Act on the `sendPrompt` callbacks the widget fires. Per-card `↗ summon` and `⟳ recover` (and the footer's "Recover/Summon selected") are worded to be **spawned as background chips** — when one arrives, call `spawn_task` (one chip per session) rather than doing the work inline, so the user's current turn keeps flowing:
   - **"Recover … as a background chip"** → one `spawn_task` per session (the batch button sends a single prompt listing all selected — fan it into one chip **per session**, not one mega-chip, so each recovers independently in its own project folder). For each chip:
     - **Title = the original session name, verbatim** (e.g. `revoicing`) — never a `Recover "…" session` label. The chip should look like a continuation of the original in the sidebar, not a new errand.
     - **`cwd` = the session's project root** (strip any `\.claude\worktrees\<name>` suffix).
     - Word the prompt so the chip *is* the recovered session: it reads the original transcript (resolve via `summon recover <id>` / the wrapper→transcript logic), writes a hand-off brief, and **resumes the work in place** in the project folder. The chip must **not** spawn a further chip and must **not** open the original worktree path as a separate session — that path is reference-only, for locating the branch and any in-progress changes. (The failure mode this prevents: a chip prompt that says "start a fresh session there" plus a worktree path makes the recovering chip spawn a *second* chip into the worktree. The chip already **is** the fresh session — tell it to continue, not to spawn.)
   - **"Summon (copy) these…"** → transfer flow: `summon` with `--select` for exactly those sessions, `--dry-run` preview first, then the real run once the user confirms.
   - **"Peek session…"** → `summon --peek <id>`.

The template is deliberately self-contained: host CSS variables + the host's Tabler `ti` webfont (both available in the `show_widget` context, light/dark safe), no external assets, and the host-provided `sendPrompt(text)` bridge for the buttons. **Chat contexts only** — terminal users keep the fzf/numbered picker; don't route a TTY user through the widget.

## Auto-detect rules

- **Destination**: account with the most recent filesystem activity (mtime of any session JSON). This reliably tracks the active Desktop account.
- **Source**: by default, all accounts except destination. Use `--from <account>` to restrict to one.
- **Workspace dir under destination**: most-recently-active existing workspace. New UUID is created if the destination has no workspaces yet.

## Display

Account → Project → Session panel, globally numbered for picker selection (`3,5,7`), ASCII fallback off UTF-8: [references/display.md](references/display.md).

## Edge cases handled

Remote-VM sessions and missing transcripts are skipped, existing `sessionId`s are idempotent, non-UTF-8/non-TTY output degrades: [references/transfer.md](references/transfer.md#edge-cases-handled).

## Sidebar refresh

Desktop reads its session list at login and doesn't watch the filesystem: **Logout → Login is required** for new sessions to appear. Evidence: [references/transfer.md](references/transfer.md#sidebar-refresh).

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
