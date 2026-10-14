# Hooks Reference

Complete hook system reference, verified against https://code.claude.com/docs/en/hooks (June 2026).

> **Stale contract warning:** old guides describe a `$TOOL_INPUT` env-var contract. That is dead.
> Hooks receive a **JSON payload on stdin** and respond via **exit code + stdout JSON**.

## Event Catalog

| Event | Fires | Matcher matches | Blocking (exit 2) |
|---|---|---|---|
| `SessionStart` | Session begins | `startup`, `resume`, `clear`, `compact` | No |
| `SessionEnd` | Session ends | End reason: `clear`, `resume`, `logout`, `prompt_input_exit`, ... | No |
| `Setup` | Only with `--init`/`--init-only`/`--maintenance` | `init`, `maintenance` | No |
| `UserPromptSubmit` | Before prompt is processed (30s default timeout) | (none) | Yes — prompt rejected and erased |
| `UserPromptExpansion` | When a `/command` expands | Command/skill name | Yes — blocks expansion |
| `PreToolUse` | Before each tool call | Tool name | Yes — tool call prevented |
| `PermissionRequest` | When a permission dialog would show | Tool name | Yes — permission denied |
| `PermissionDenied` | After a tool call is denied | Tool name | No (`retry` output supported) |
| `PostToolUse` | After tool succeeds | Tool name | No (stderr fed back; tool already ran) |
| `PostToolUseFailure` | After tool fails | Tool name | No (tool already failed) |
| `PostToolBatch` | After a parallel tool batch resolves | (none) | Yes — stops loop before next model call |
| `Stop` | Main agent finishes a turn | (none) | Yes — prevents stop, conversation continues |
| `StopFailure` | Turn ends in API error | Error type (`rate_limit`, `overloaded`, ...) | No (output ignored) |
| `SubagentStart` / `SubagentStop` | Subagent spawn / finish | Agent type (e.g. `Explore`, custom names) | Start: No / Stop: Yes |
| `TaskCreated` / `TaskCompleted` | Task list changes | (none) | Yes — rolls back / prevents completion |
| `TeammateIdle` | Agent-team teammate goes idle | (none) | Yes — prevents idle |
| `Notification` | Notification sent | `permission_prompt`, `idle_prompt`, `auth_success`, ... | No |
| `MessageDisplay` | While a message streams (10s timeout) | (none) | No (`displayContent` rewrite, screen-only) |
| `ConfigChange` | Settings file changed mid-session | `user_settings`, `project_settings`, `local_settings`, `policy_settings`, `skills` | Yes — blocks the change (except policy) |
| `CwdChanged` | Working directory changes | (none) | No (`CLAUDE_ENV_FILE` available) |
| `FileChanged` | Watched file changes | Literal filenames, e.g. `.envrc\|.env` | No (`CLAUDE_ENV_FILE` available) |
| `PreCompact` / `PostCompact` | Before / after compaction | `manual`, `auto` | Pre: Yes — blocks compaction / Post: No |
| `InstructionsLoaded` | CLAUDE.md / rules file loads | Load reason: `session_start`, `nested_traversal`, `path_glob_match`, `include`, `compact` | No (async, observability) |
| `WorktreeCreate` / `WorktreeRemove` | Worktree lifecycle | (none) | Create: any non-zero fails creation |
| `Elicitation` / `ElicitationResult` | MCP server requests user input / response | MCP server name | Yes — denies / blocks response |

## Stdin JSON Contract

Every hook gets JSON on stdin. Common fields:

```json
{
  "session_id": "…",
  "transcript_path": "/abs/path/to/transcript.jsonl",
  "cwd": "/working/dir",
  "hook_event_name": "PreToolUse",
  "permission_mode": "default|plan|acceptEdits|auto|dontAsk|bypassPermissions"
}
```

`agent_id` / `agent_type` appear in subagent context; `effort: {"level": "low|medium|high|xhigh|max"}` on tool-context events.

Event-specific fields:

| Event | Extra stdin fields |
|---|---|
| Tool events (`PreToolUse`, `PermissionRequest`, `PermissionDenied`) | `tool_name`, `tool_input` (tool-specific object) |
| `PostToolUse` | + `tool_output` (string or object) |
| `PostToolUseFailure` | + `error_message` |
| `PermissionDenied` | + `denial_reason` |
| `SessionStart` | `source` (`startup\|resume\|clear\|compact`), `model` |
| `Setup` | `trigger` (`init\|maintenance`) |
| `UserPromptSubmit` | `prompt` |
| `UserPromptExpansion` | `command`, `expansion` |
| `StopFailure` | `error_type`, `error_message` |
| `SubagentStart`/`SubagentStop` | `agent_type`, `agent_id` |
| `Notification` | `notification_type`, `message` |
| `ConfigChange` | `source` |
| `FileChanged` | `file_path`, `change_type` (`create\|modify\|delete`) |
| `CwdChanged` | `directory` |
| `TaskCreated`/`TaskCompleted` | `task_id`, `task_title` |
| `InstructionsLoaded` | `file_path`, `memory_type`, `load_reason`, `globs?`, `trigger_file_path?`, `parent_file_path?` |
| `Elicitation` | `server_name`, `form_fields[]` (`name`, `type`, `label`, `required`) |
| `WorktreeCreate`/`WorktreeRemove` | `name` (create), `worktree_path` (remove) |

Read it with jq:

```bash
#!/bin/bash
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success. stdout parsed as JSON if valid, else treated as plain text context |
| `2` | Blocking error. stdout ignored; **stderr** is fed to Claude as feedback |
| other | Non-blocking error. stderr logged, first line shown in transcript, execution continues |

## Stdout JSON Contract (exit 0)

Universal fields (any event):

```json
{
  "continue": false,              // false stops Claude entirely
  "stopReason": "why we stopped", // shown when continue:false
  "suppressOutput": true,         // hide stdout from transcript
  "systemMessage": "warning shown to user",
  "terminalSequence": "\u001b]…"  // raw OSC sequence (v2.1.141+)
}
```

Event-specific output goes inside `hookSpecificOutput` with a required `hookEventName`:

| Event | `hookSpecificOutput` fields |
|---|---|
| `PreToolUse` | `permissionDecision: allow\|deny\|ask\|defer`, `permissionDecisionReason`, `updatedInput` (replace tool args), `additionalContext` |
| `PermissionRequest` | `decision: { "behavior": "allow\|deny", "updatedInput": {…} }` |
| `PermissionDenied` | `retry: true` (let the model retry) |
| `PostToolUse` | `updatedToolOutput` (replace the result Claude sees), `additionalContext` |
| `SessionStart` / `SubagentStart` | `additionalContext`, `watchPaths: [...]` (feeds `FileChanged`), `reloadSkills: true`; SessionStart only: `sessionTitle`, `initialUserMessage` |
| `Stop` / `SubagentStop` | `additionalContext` (inject feedback and continue) |
| `PostToolBatch` / `Setup` | `additionalContext` |
| `MessageDisplay` | `displayContent` (screen-only rewrite, transcript untouched) |
| `Elicitation` / `ElicitationResult` | `action: accept\|decline\|cancel`, `content: {field: value}` |
| `WorktreeCreate` | `worktreePath` (or print path on stdout for command hooks) |

Top-level `decision`/`reason` pattern (alternative to exit 2) for `UserPromptSubmit`, `UserPromptExpansion`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `ConfigChange`, `PreCompact`, `Stop`, `SubagentStop`:

```json
{ "decision": "block", "reason": "explanation Claude sees" }
```

## Hook Types

Five types. All accept `timeout` (seconds), `if` (permission-rule filter), `statusMessage`.

### 1. `command` (default workhorse)

```json
{
  "type": "command",
  "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh",
  "args": ["--fast"],
  "async": false,
  "asyncRewake": false,
  "shell": "bash",
  "timeout": 600
}
```

- **Shell form** (no `args`): command string runs via shell (`sh -c`, Git Bash, or PowerShell with `shell: "powershell"`); pipes, `&&`, globs work.
- **Exec form** (with `args`): resolved as executable on PATH, spawned directly, no shell.
- **Claude Desktop runs `WorktreeCreate`/`WorktreeRemove` itself**, not through Claude Code. On Windows the command goes to `cmd.exe /d /s /c`, which expands neither `~` nor `$HOME`: the hook exits 127 and every Desktop worktree session aborts, so give the script an absolute path. Its env is its own (`PATH`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PROJECT_DIR`), never the settings `env` block, and its stdin has `"transcript_path": ""`. It calls the hook for a non-git folder too, aborts the session if the hook fails, and refuses a result equal to that folder ("it must create a separate workspace"). Read from Desktop 2.26454/2.31226 on 2026-10-09; claude-mods' `hooks/README.md` has the wiring.
- `async: true`: background, never blocks, output discarded.
- `asyncRewake: true`: background, but **wakes Claude on exit 2** with stderr as a system reminder. Implies async.

### 2. `http`

```json
{ "type": "http", "url": "https://hooks.internal/check",
  "headers": {"Authorization": "$HOOK_TOKEN"}, "allowedEnvVars": ["HOOK_TOKEN"] }
```

POST; 2xx = success (body parsed as JSON or plain text); non-2xx = non-blocking error. Env interpolation in headers requires `allowedEnvVars`.

### 3. `mcp_tool`

```json
{ "type": "mcp_tool", "server": "my-server", "tool": "validate",
  "input": {"cmd": "${tool_input.command}"} }
```

Calls a configured MCP server's tool; `${path.to.field}` interpolates from the stdin payload.

### 4. `prompt` (default timeout 30s)

```json
{ "type": "prompt", "prompt": "Is this command destructive? $ARGUMENTS", "model": "haiku" }
```

One-shot yes/no judgment by a fast model; returns the decision as JSON.

### 5. `agent` (default timeout 60s)

```json
{ "type": "agent", "prompt": "Verify the edited file still compiles. $ARGUMENTS" }
```

Spawns a subagent with tool access; returns a decision.

## Matchers

| Pattern | Interpreted as |
|---|---|
| `"*"`, `""`, omitted | Match everything |
| Letters/digits/`_`/`\|` only | Exact name or `\|`-list: `Bash`, `Edit\|Write` |
| Anything else | JavaScript regex: `^Notebook`, `mcp__memory__.*` |

- Matching is **case-sensitive** (`bash` never matches `Bash`).
- `matcher` must be a **string**, not an array — an array is a schema error and the hook is silently dropped (visible in `/doctor`).
- MCP tools: `mcp__<server>__<tool>`; match a whole server with regex `mcp__memory__.*`.

### `if` filters

Narrow within a matched event using permission-rule syntax — `"if": "Bash(git *)"` runs only for git commands (subcommands inside `&&` chains and `$()` are checked; leading `FOO=bar` assignments stripped). `Edit(*.ts)` filters by file pattern. **Fails open** if the command can't be parsed — use the permission system for hard enforcement.

## Where Hooks Live

| Location | Scope |
|---|---|
| `~/.claude/settings.json` | All your projects |
| `.claude/settings.json` | Project (committed) |
| `.claude/settings.local.json` | Project (gitignored) |
| Managed policy settings | Organization |
| Plugin `hooks/hooks.json` (or inline in plugin.json) | While plugin enabled |
| **Skill or agent frontmatter** | While that component is active |

Settings-file shape:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh" } ] }
    ]
  }
}
```

Skill/agent frontmatter shape (YAML):

```yaml
---
name: secure-operations
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/security-check.sh"
---
```

For subagents, `Stop` hooks auto-convert to `SubagentStop`. Plugin **subagents** ignore `hooks` frontmatter (security restriction).

Edits to `settings.json` hooks take effect in the running session after a brief delay — no restart. `disableAllHooks: true` turns everything off (managed hooks only by managed-level setting). Identical handlers are deduplicated. Browse live config with `/hooks`.

## Environment Variables in Hooks

| Variable | Available | Value |
|---|---|---|
| `CLAUDE_PROJECT_DIR` | All hooks | Project root |
| `CLAUDE_PLUGIN_ROOT` | Plugin hooks | Plugin install dir (changes on update) |
| `CLAUDE_PLUGIN_DATA` | Plugin hooks | Persistent data dir (survives updates) |
| `CLAUDE_ENV_FILE` | `SessionStart`, `Setup`, `CwdChanged`, `FileChanged` | File to append `export VAR=…` lines; persists into later Bash calls |
| `CLAUDE_EFFORT` | Tool-context events | `low`…`max` |
| `CLAUDE_CODE_REMOTE` | All | `"true"` on web, unset locally |

Path placeholders in hook config: `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, and (plugins) `${user_config.*}`.

## Recipes

Block dangerous commands (PreToolUse on `Bash`):

```bash
#!/bin/bash
CMD=$(jq -r '.tool_input.command // empty')
if echo "$CMD" | grep -qE 'rm -rf /|git push --force.*(main|master)'; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "Destructive command blocked by policy"}}'
fi
exit 0
```

Audit log (PostToolUse, matcher `*`):

```bash
#!/bin/bash
cat | jq -c '{ts: now|todate, tool: .tool_name, input: .tool_input}' >> ~/.claude/audit.jsonl
exit 0
```

Inject project context + reload skills at session start (SessionStart):

```bash
#!/bin/bash
jq -n --arg ctx "$(git -C "$CLAUDE_PROJECT_DIR" status --short)" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx, reloadSkills: true}}'
```

Force a re-check before stopping (Stop):

```bash
#!/bin/bash
if ! npm test --silent >/dev/null 2>&1; then
  echo "Tests are failing — fix them before finishing." >&2
  exit 2
fi
exit 0
```

Rewrite tool input (PreToolUse `updatedInput`):

```bash
#!/bin/bash
INPUT=$(cat)
SAFE=$(echo "$INPUT" | jq '.tool_input.command |= sub("^pip install"; "uv pip install")')
jq -n --argjson ti "$(echo "$SAFE" | jq '.tool_input')" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: $ti}}'
```

## Security Checklist

- Quote all shell variables (`"$VAR"`); validate paths (reject `..` traversal)
- Use `${CLAUDE_PROJECT_DIR}` instead of relative paths (hooks run from varying cwd)
- Keep `UserPromptSubmit` hooks fast (30s default timeout); set explicit `timeout` elsewhere
- `set -euo pipefail` plus jq fallbacks (`// empty`) so malformed payloads don't crash into exit-2 blocks
- Remember hooks execute arbitrary code with your credentials — review hooks in any repo before trusting it

## Debugging Hooks

```bash
claude --debug hooks      # live: events fired, matchers checked, exit codes, output
/hooks                    # what's registered this session
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ./my-hook.sh; echo "exit=$?"
```

See [debugging-reference.md](debugging-reference.md) for the hook-not-firing decision tree.
