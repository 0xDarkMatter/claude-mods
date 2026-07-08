---
name: claude-code-ops
description: "Claude Code internals - hooks, skill frontmatter, headless mode, and extension debugging, current as of June 2026. Triggers: hooks, hook events, hook not firing, PreToolUse/PostToolUse/SessionStart, skill frontmatter, SKILL.md, skill not triggering, headless, claude -p, CI/CD scripting, plugin validate, MCP server not connecting, agent vs skill vs command vs hook."
when_to_use: "Use for questions about Claude Code itself - e.g. my hook is not firing, why won't this skill trigger, run claude headless in CI, plugin fails to validate, should this be an agent or a skill."
license: MIT
compatibility: "Claude Code CLI v2.1.x (June 2026 docs)"
allowed-tools: "Bash Read Grep"
metadata:
  author: claude-mods
  related-skills: "mcp-ops, setperms, parallel-ops"
---

# Claude Code Internals

One skill for the machinery of Claude Code itself: the **hook system**, the **skill format**, **headless/programmatic use**, and **debugging your configuration**. Replaces the former claude-code-hooks / claude-code-headless / claude-code-debug skills, refreshed against the June 2026 docs.

> Written against Claude Code ~v2.1.17x. These surfaces move fast — when precision matters, confirm against the live docs (links per section). Two contracts from older guides are **dead**: the `$TOOL_INPUT` env-var hook contract (hooks read **stdin JSON** now) and standalone command files as a separate system (commands merged into skills).

## Route to the Right Reference

| You're doing | Load |
|---|---|
| Writing/fixing a hook; event contracts; blocking tools; audit logging | [references/hooks-reference.md](references/hooks-reference.md) |
| Authoring a skill; frontmatter fields; `$ARGUMENTS`; `` !`cmd` `` injection; triggering problems | [references/skills-reference.md](references/skills-reference.md) |
| `claude -p`; CI scripts; output parsing; stream-json; structured output; background agents | [references/headless-reference.md](references/headless-reference.md) |
| Anything configured isn't taking effect; plugin validation; /doctor | [references/debugging-reference.md](references/debugging-reference.md) |
| Designing a new extension — which surface to build, where to scope it, how to author the description/prompt | [references/extension-architecture.md](references/extension-architecture.md) |

## Resources

| Resource | Use |
|---|---|
| [scripts/validate-hooks-json.py](scripts/validate-hooks-json.py) | Lint a `hooks.json` (or a settings.json `"hooks"` block) against the 30-event contract before trusting it |
| [assets/hooks.json.template](assets/hooks.json.template) | Starter `hooks.json` — one of each common pattern (PreToolUse `Bash`, PostToolUse `Edit\|Write`, SessionStart), `${CLAUDE_PLUGIN_ROOT}`-rooted |

**Validate a hooks file** (offline, structural — catches the unknown-event and matcher-as-array footguns the docs warn about):

```bash
# Lint this repo's own plugin hooks file (default target if no path given):
python skills/claude-code-ops/scripts/validate-hooks-json.py hooks/hooks.json
# → exit 0 clean, 10 findings (lists them), 4 malformed JSON, 3 not-found.
# Machine-readable for CI:
python skills/claude-code-ops/scripts/validate-hooks-json.py --json hooks/hooks.json | jq '.data[]'
# --strict makes portability warnings (unrooted command paths) count as findings.
```

**Start a new hooks file** from `assets/hooks.json.template` — copy it, strip the `//` comment lines (the live `hooks.json` must be strict JSON), then validate the result with the script above.

## Mental Model

- **Skills** = prompt content loaded on demand (descriptions always in context, body on invoke). Guidance, not guarantees.
- **Hooks** = deterministic shell/HTTP/MCP/model handlers on lifecycle events. Guarantees: use hooks (or permissions) for "must never happen", skills/CLAUDE.md for "we do it this way".
- **Subagents** = isolated context windows with their own system prompt, tools, model, permissions.
- **Headless** = the same agent loop driven by `claude -p` (Agent SDK under the CLI).
- **Plugins** = a directory bundling all of the above (`skills/`, `agents/`, `hooks/hooks.json`, `.mcp.json`), manifest at `.claude-plugin/plugin.json`.

## Hooks in 30 Seconds

Configure under the `"hooks"` key in `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, plugin `hooks/hooks.json`, or **skill/agent frontmatter**:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh" }] }
    ]
  }
}
```

Contract: JSON payload on **stdin** → respond with **exit code** (0 ok, 2 block + stderr feedback) and optional **stdout JSON** (`continue`, `systemMessage`, `hookSpecificOutput.permissionDecision/updatedInput/additionalContext/...`).

Events (full catalog + per-event schemas in the reference): `SessionStart`, `SessionEnd`, `Setup`, `UserPromptSubmit`, `UserPromptExpansion`, `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`, `TeammateIdle`, `Notification`, `MessageDisplay`, `ConfigChange`, `CwdChanged`, `FileChanged`, `PreCompact`, `PostCompact`, `InstructionsLoaded`, `WorktreeCreate`, `WorktreeRemove`, `Elicitation`, `ElicitationResult`.

Hook types: `command` (sync/`async`/`asyncRewake`), `http`, `mcp_tool`, `prompt`, `agent`. Matchers are case-sensitive strings (`"Edit|Write"`, regex allowed); `if` filters add permission-rule conditions like `Bash(git *)`.

## Skills in 30 Seconds

`.claude/skills/<name>/SKILL.md` (project) or `~/.claude/skills/<name>/SKILL.md` (personal). Frontmatter fields beyond `name`/`description`: `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`, `model`, `effort`, `context: fork` + `agent`, `hooks`, `paths`, `shell`.

- Substitutions: `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N` (0-based!), `$name`, `${CLAUDE_SKILL_DIR}`, `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}`.
- `` !`command` `` runs at load time and inlines output (dynamic context injection).
- Body persists all session; keep SKILL.md < 500 lines, details in supporting files.
- Description + `when_to_use` capped at 1,536 chars in the listing; listing budget = 1% of context window — `/doctor` reports overflow.

## Headless in 30 Seconds

```bash
claude --bare -p "query" --allowedTools "Read,Grep" --output-format json | jq -r '.result'
```

- `--bare` for reproducible CI runs (skips hooks/skills/plugins/MCP/CLAUDE.md; auth via `ANTHROPIC_API_KEY` or `claude setup-token`).
- `--output-format json` → `.result`, `.session_id`, `.is_error`, `.total_cost_usd`, `.num_turns`; add `--json-schema '<schema>'` → `.structured_output`.
- `stream-json` (+ `--verbose --include-partial-messages`) for token streaming; `system/init` event lists loaded `plugins`/`plugin_errors` (assert in CI).
- Multi-turn: `--continue`, `--resume <id|name>`, `--fork-session`; caps: `--max-turns`, `--max-budget-usd`.
- Fire-and-forget: `claude --bg "task"`, then `claude agents --json` / `logs` / `attach` / `stop`.

## Debugging Decision Tree

```
Something configured isn't working
├─ What loaded? /context → then /memory /skills /agents /hooks /mcp /permissions
├─ Config valid? /doctor (invalid keys, schema errors, skill budget overflow)
├─ Which scope won? /status  (managed > local > project > user; flags/env on top)
├─ Watch it live: claude --debug hooks | --debug mcp | --debug "api,hooks"
└─ Bisect: claude --safe-mode (customizations off)
   └─ still broken → CLAUDE_CONFIG_DIR=/tmp/clean claude  (nothing loads)
```

Fast classics: hooks belong in `settings.json` not `~/.claude.json`; matcher is a case-sensitive **string**, not an array; skills need a folder + `SKILL.md`; `.mcp.json` at repo root; `settings.local.json` overrides `settings.json`; agent files on disk load at session start; `claude plugin validate --strict` in CI.

## Subagents (quick facts)

Markdown + YAML frontmatter in `.claude/agents/` / `~/.claude/agents/` / plugin `agents/` / `--agents '<json>'`. Required: `name` (the identity — filename doesn't matter), `description`. Optional: `tools`, `disallowedTools`, `model` (default `inherit`), `permissionMode`, `maxTurns`, `skills` (preloads **full** skill content), `mcpServers`, `hooks`, `memory` (`user|project|local`), `background`, `effort`, `isolation: worktree`, `color`, `initialPrompt`. Plugin agents ignore `hooks`/`mcpServers`/`permissionMode`. Built-in Explore/Plan skip CLAUDE.md. The Task tool was renamed **Agent** (v2.1.63; `Task(...)` rules still alias).

## Official Docs (verify here when it matters)

- https://code.claude.com/docs/en/hooks — hook events, contracts, types
- https://code.claude.com/docs/en/skills — skill format and lifecycle
- https://code.claude.com/docs/en/cli-reference — every flag (note: `--help` doesn't list them all)
- https://code.claude.com/docs/en/headless — `claude -p` patterns
- https://code.claude.com/docs/en/sub-agents — subagent frontmatter
- https://code.claude.com/docs/en/plugins-reference — plugin schemas + `claude plugin` CLI
- https://code.claude.com/docs/en/debug-your-config — diagnosis workflow
- https://code.claude.com/docs/llms.txt — full docs index
