# Debugging Reference

Diagnosing Claude Code configuration, extensions, and behavior. Verified against https://code.claude.com/docs/en/debug-your-config (June 2026).

Core principle: when something you configured doesn't take effect, the cause is almost always one of three things — **it didn't load**, **it loaded from a different location than you expect**, or **another scope overrode it**. Inspect what actually loaded before editing anything.

## Inspection Commands (run these first)

| Command | Shows |
|---|---|
| `/context` | Everything in the context window by category: system prompt, memory, skills, MCP tools, messages |
| `/memory` | Which CLAUDE.md and rules files loaded, plus auto-memory |
| `/skills` | Available skills (project/user/plugin) with invocation badges; `Space` cycles `skillOverrides` states |
| `/agents` | Configured subagents and settings |
| `/hooks` | Every hook registered this session, grouped by event |
| `/mcp` | MCP servers, connection status, approval state |
| `/permissions` | Resolved allow/deny rules in effect |
| `/doctor` | Diagnostics: invalid settings keys, schema errors, skill-description budget overflow, install health. Press `f` to send the report to Claude for guided fixes |
| `/debug [issue]` | Enables debug logging and prompts Claude to self-diagnose from logs |
| `/status` | Active settings sources, incl. whether managed settings apply |

## CLI Diagnostic Flags

| Flag | Use |
|---|---|
| `claude --debug` | Debug logging; filter by category: `--debug "api,hooks"`, negate: `--debug "!statsig,!file"` |
| `claude --debug hooks` | Watch hook evaluation live: events fired, matchers checked, exit codes, output |
| `claude --debug mcp` | MCP server stderr (e.g. connected-but-zero-tools) |
| `claude --debug-file /tmp/claude.log` | Write debug logs to a file (implies debug mode; beats `CLAUDE_CODE_DEBUG_LOGS_DIR`) |
| `claude --safe-mode` | (v2.1.169+) All customizations off: CLAUDE.md, skills, plugins, hooks, MCP, custom commands/agents, output styles, themes, keybindings, LSP, auto-memory. Auth/model/tools/permissions normal. Managed policy still partially applies |
| `claude --bare` | Minimal startup for scripts (different goal than safe-mode: speed/reproducibility, not triage) |
| `claude --verbose` | Full turn-by-turn output |
| `claude doctor` / `claude --version` | Install health from the shell |

### Bisection workflow

1. `claude --safe-mode` — problem gone? A customization is the cause; use targeted `/` commands to find which.
2. Still broken? Fully clean session: `cd /tmp && CLAUDE_CONFIG_DIR=/tmp/claude-clean claude` (no user/project config at all; managed settings and env vars still apply; you'll re-login on Linux/Windows).
3. Reintroduce config one piece at a time.

## Skill Not Working

| Symptom | Cause | Fix |
|---|---|---|
| Not in `/skills` | File at `.claude/skills/name.md` instead of a folder | Must be `.claude/skills/name/SKILL.md` |
| Not in `/skills` | New top-level skills dir created mid-session | Restart (existing dirs are live-watched; new top-level dirs are not) |
| In `/skills`, Claude never invokes it | `disable-model-invocation: true` ("user-only" badge), or description doesn't match request phrasing | Check badge; add natural trigger keywords to `description`/`when_to_use` |
| Used to trigger, stopped | Description budget overflow (1% of context window) | `claude --debug` logs the overflow; `/doctor` shows the biggest contributors. Raise `skillListingBudgetFraction`, set noise skills to `"name-only"` in `skillOverrides`, front-load key triggers (1,536-char per-skill cap) |
| Triggers too often | Description too broad | Tighten description or `disable-model-invocation: true` |
| Stops influencing behavior mid-session | Content usually still present; model preferring other approaches — or dropped by compaction (5k/skill, 25k combined budget) | Strengthen description/instructions, enforce with hooks, or re-invoke after compaction |
| Frontmatter ignored | YAML error (e.g. unquoted `:` in description) | Quote strings; validate YAML |

## Hook Not Firing

Decision tree:

1. **Not listed in `/hooks`?** It isn't being read:
   - Hooks belong under the `"hooks"` key in a **settings file** — there is no standalone hooks file for user/project config (only plugins use `hooks/hooks.json`).
   - `~/.claude.json` is app state, NOT settings — `hooks`/`permissions`/`env` go in `~/.claude/settings.json`.
   - `matcher` as a JSON **array** is a schema error: the entry is dropped, `/doctor` reports it.
2. **Listed but never fires?** Matcher problems:
   - Case-sensitive: `Bash` not `bash`; tool names are capitalized.
   - Multiple tools = one string with `|`: `"Edit|Write"`.
   - MCP tools need `mcp__server__tool` or regex `mcp__server__.*`.
3. **Fires but misbehaves?** `claude --debug hooks`, then test the script standalone:
   ```bash
   echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ./hook.sh; echo "exit=$?"
   ```
   - Script must read **stdin JSON** (the `$TOOL_INPUT` env contract is stale/dead).
   - Exit 2 + stderr = block; JSON decisions only parsed on exit 0 stdout.
   - Not executable / wrong shebang / CRLF line endings on Unix.
4. Settings edits apply after a brief file-stability delay — no restart needed; re-run `/hooks` to refresh.

## Agent Not Found / Not Used

- Locations: `.claude/agents/` (project, recursive scan), `~/.claude/agents/` (user), plugin `agents/`, `--agents` JSON, managed. Priority: managed > CLI > project > user > plugin.
- Identity comes from the `name` **frontmatter field**, not the filename. Duplicate names in one scope: one silently wins.
- Files added on disk load at **session start** — restart after manual edits (`/agents`-created ones apply immediately).
- `name` and `description` are required frontmatter; delegation quality depends on `description` (add "Use proactively…" phrasing).
- Plugin agents ignore `hooks`, `mcpServers`, `permissionMode` frontmatter (security restriction) — copy into `.claude/agents/` if needed.
- Explore/Plan built-ins skip CLAUDE.md — restate critical instructions in the delegating prompt or agent body.

## MCP Server Issues

- `/mcp` shows status. Project `.mcp.json` servers need one-time approval — a dismissed prompt leaves them disabled until approved from `/mcp`.
- `.mcp.json` lives at the **repo root**, not inside `.claude/`; `settings.json` has no `mcpServers` key (use `claude mcp add --scope user` for user scope).
- Failed to start: usually relative paths in `command`/`args` (resolve against launch dir) — use absolute paths.
- Connected but zero tools: Reconnect from `/mcp`; persists → `claude --debug mcp` for stderr.
- Server missing env vars: settings `env` doesn't propagate to MCP child processes — set per-server `env` in `.mcp.json`.

## Plugin Issues

```bash
claude plugin validate ./my-plugin            # schema check; warnings for unknown fields
claude plugin validate ./my-plugin --strict   # warnings become errors — use in CI
claude plugin list                            # what's installed/loaded
```

- Unrecognized plugin.json fields = warnings (plugin still loads); wrong **types** (e.g. `keywords` as string) = load errors.
- `.claude-plugin/` holds only `plugin.json` (and marketplace.json); all component dirs (`skills/`, `agents/`, `hooks/`, `commands/`, `output-styles/`) sit at the **plugin root**.
- Plugin `CLAUDE.md` is NOT loaded — ship context as a skill instead.
- In headless: the stream-json `system/init` event lists `plugins` and `plugin_errors` — assert on it in CI.
- `/plugin` manages enable/disable; `defaultEnabled: false` plugins install disabled (v2.1.154+).
- Plugin component changes need `/reload-plugins` (skills text is the only live-reloaded piece).

## Permission Surprises

- `/permissions` shows resolved rules. Precedence: managed always wins; then local > project > user; flags/env override files.
- `settings.local.json` silently overrides `settings.json` — the classic "my setting is ignored".
- `Bash(rm *)` deny matches the **literal command string** — `/bin/rm`, `find -delete` sail past. Hard guarantees need a PreToolUse hook or sandboxing.
- Prefix rules: trailing space matters — `Bash(git diff *)` vs `Bash(git diff*)` (also matches `git diff-index`).

## Common Causes Cheat Sheet

| Symptom | Likely cause |
|---|---|
| Global hooks/permissions/env ignored | Put in `~/.claude.json` instead of `~/.claude/settings.json` |
| settings.json value ignored | Same key in `settings.local.json` |
| Subdirectory CLAUDE.md ignored | Loads on demand when Claude Reads a file there, not at startup |
| Cleanup never runs at session end | No `SessionEnd` hook configured |
| Skill at `skills/name.md` invisible | Needs folder + `SKILL.md` |
| Hook with array matcher dropped | Matcher must be a string |
| MCP under `.claude/.mcp.json` never loads | Move to repo root |

## Debug Logs

- `--debug-file <path>` pins location; `CLAUDE_CODE_DEBUG_LOGS_DIR` sets the directory.
- Session transcripts (JSONL) live under `~/.claude/projects/<encoded-cwd>/` — greppable for tool inputs/outputs and hook activity.
- `claude project purge [path] --dry-run` previews clearing all local state for a project.
