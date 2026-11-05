# Toolbox Modes: Output and Internals

Detail behind the toolbox modes in SKILL.md: the `pick --json` row schema and `--rich` metrics, how `recover` extracts, distills, caches and emits a brief, and the steps `rebind` takes.

## `summon pick` JSON output

**`summon pick --json`** skips the picker entirely and emits the filtered inventory as a `claude-mods.summon.pick/v1` envelope on stdout — JSON only, no panel glyphs (an empty inventory is `"data": []` with exit 0, not an error). Each session row carries: `id` (short) + `sessionId` (full) + `cliSessionId`, `title`, `cwd`, `projectRoot` + `worktree` (the cwd with any `\.claude\worktrees\<name>` suffix split out), `branch`, `model` + `effort`, `turns`, `isArchived`, `isRunning` (active in the last 10m), `brokenCwd` (doctor's check — recorded cwd missing on disk), `lastActivityAt` (ISO-8601 Z), `account` + `accountEmail`, and `transcriptPath` (resolved via the same wrapper→transcript logic as recover, scan fallback included; `null` when missing). This feeds the [in-chat visual card picker](../SKILL.md#in-chat-mode-visual-card-picker--the-default-for-picking-sessions) and any scripted caller:

```bash
summon pick --json | jq -r '.data[] | "\(.id)  \(.title)  \(.projectRoot)"'
```

**`summon pick --json --rich`** advances the schema to `claude-mods.summon.pick/v2` and adds transcript-derived **display metrics** to every row — one linear transcript read each, so it's opt-in (the plain `--json` inventory stays metadata-only and instant). Extra keys: `events` (transcript line count), `toolCalls`, `densityBuckets` (24-bucket activity histogram over the session's lifetime), `durationMin`, `sizeKB` (on-disk transcript size), `ctxTokens` (last-turn context occupancy — input + cache + output, matching Claude Code's live meter), `ctxPeak` (max before any auto-compaction), `ctxWindow` (200000, or 1000000 when peak exceeds 200k), `ctxPct` / `ctxPeakPct`, and `firstAsk` (the session's opening ask, boilerplate-stripped). This is the feed for the card picker.

## `summon recover` internals

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

Full transcript at C:\Users\<you>\.claude\projects\D--code-myapp-…\e640a2a8-….jsonl (session 6577b24c-…, branch claude/funny-hypatia-5e54f7); consult it only if something specific is missing.
```

## `summon rebind` steps

1. **Backs up** every matching wrapper to `~/.claude/summon-backups/<timestamp>/` (outside the live store) before touching anything
2. **Atomically rewrites** `cwd`, and rebases `originCwd`/`worktreePath` (worktree sessions record the project *root* in `originCwd` — the suffix math is handled)
3. **Bridges the transcript**: Desktop resolves the transcript via the munged *new* cwd, so the `<cliSessionId>.jsonl` is copied (never moved) into the new munged project dir. `--no-transcript` skips this
4. **Verifies** by re-reading the wrapper; on mismatch it restores from the backup
5. If the same session was transfer-copied into several accounts, **all copies are rebound**
6. When the new cwd is inside a `.claude\worktrees\` path, prints a reminder that **git worktree links break on folder moves** — run `git worktree repair <new-worktree-path>` from the repo root (verified fix 2026-07-03)
