# Headless Reference (`claude -p`)

Verified against https://code.claude.com/docs/en/headless and https://code.claude.com/docs/en/cli-reference (June 2026).

`claude -p` runs the same agent loop as interactive Claude Code via the Agent SDK. For full programmatic control (callbacks, message objects, structured outputs API), use the Python/TypeScript Agent SDK — this page covers the CLI surface.

> Billing note: from June 15, 2026, `claude -p` / Agent SDK usage on subscription plans draws from a separate monthly Agent SDK credit, not interactive limits.

## Core Flags

| Flag | Purpose |
|---|---|
| `-p`, `--print` | Non-interactive mode; print result and exit |
| `--output-format` | `text` (default) \| `json` \| `stream-json` |
| `--input-format` | `text` (default) \| `stream-json` (print mode) |
| `--json-schema '<schema>'` | Validated structured output (with `--output-format json`); result lands in `structured_output` |
| `--include-partial-messages` | Token-level streaming events (needs `-p` + `stream-json`) |
| `--include-hook-events` | Hook lifecycle events in the stream (needs `stream-json`) |
| `--replay-user-messages` | Echo stdin user messages back on stdout (stream-json in/out) |
| `-c`, `--continue` | Continue most recent conversation in this directory |
| `-r`, `--resume <id\|name>` | Resume a specific session |
| `--fork-session` | New session ID when resuming (don't mutate the original) |
| `--session-id <uuid>` | Pin the session ID |
| `--no-session-persistence` | Don't save the session to disk (print mode) |
| `--allowedTools` / `--allowed-tools` | Auto-approve matching tools (permission-rule syntax) |
| `--disallowedTools` | Deny rules; bare name removes the tool from context, `Bash(rm *)` denies matching calls only |
| `--tools "Bash,Edit,Read"` | Restrict available built-in tools (`""` = none, `"default"` = all). MCP unaffected — pair with `--disallowedTools "mcp__*"` |
| `--permission-mode` | `default` \| `acceptEdits` \| `plan` \| `auto` \| `dontAsk` \| `bypassPermissions` |
| `--dangerously-skip-permissions` | = `--permission-mode bypassPermissions` |
| `--permission-prompt-tool <mcp_tool>` | Delegate permission prompts to an MCP tool |
| `--max-turns N` | Cap agentic turns (print mode); exits with error at the cap |
| `--max-budget-usd N` | Spend cap (print mode) |
| `--model` / `--fallback-model sonnet,haiku` | Model + ordered fallback chain |
| `--effort low\|medium\|high\|xhigh\|max` | Effort level |
| `--system-prompt(-file)` / `--append-system-prompt(-file)` | Replace / append system prompt (replace drops ALL default guidance) |
| `--agents '<json>'` | Define session subagents inline (subagent frontmatter fields + `prompt`) |
| `--agent <name>` | Run a specific agent as the main session |
| `--settings <file\|json>` | Override settings for this invocation |
| `--setting-sources user,project,local` | Limit which settings files load |
| `--mcp-config <file\|json>` / `--strict-mcp-config` | Load MCP servers / ONLY those servers |
| `--add-dir <paths>` | Extra working directories |
| `--bare` | Minimal mode: skip hooks/skills/plugins/MCP/CLAUDE.md auto-discovery |
| `--bg` | Run as a background agent, return immediately (prints session ID); `--bg --exec 'cmd'` runs a shell job |
| `--verbose` | Turn-by-turn output (required for some stream-json modes) |
| `--init` / `--init-only` / `--maintenance` | Run Setup hooks (print mode); `--init-only` exits after hooks |
| `--exclude-dynamic-system-prompt-sections` | Move per-machine prompt sections to first user message (prompt-cache reuse across machines) |

Stdin is capped at **10MB** (v2.1.128+); larger inputs go in a file referenced by path.

## Bare Mode (recommended for CI/scripts)

```bash
claude --bare -p "Summarize this file" --allowedTools "Read"
```

Skips auto-discovery of hooks, skills, plugins, MCP servers, auto memory, and CLAUDE.md — same result on every machine; only explicit flags apply. Tools available: Bash, file read, file edit. Pass context back in explicitly: `--append-system-prompt(-file)`, `--settings`, `--mcp-config`, `--agents`, `--plugin-dir`/`--plugin-url`.

Caveat: bare mode skips OAuth/keychain reads — auth must come from `ANTHROPIC_API_KEY` or an `apiKeyHelper` in `--settings`. Docs state `--bare` will become the default for `-p` in a future release.

`--safe-mode` is the interactive cousin (troubleshooting, not speed): customizations off, auth/permissions normal. See debugging-reference.md.

## Output Formats

### `json`

```json
{
  "type": "result",
  "subtype": "success",
  "result": "…final text…",
  "structured_output": { },
  "session_id": "abc-123",
  "is_error": false,
  "num_turns": 3,
  "duration_ms": 12345,
  "total_cost_usd": 0.0123,
  "usage": { }
}
```

```bash
claude -p "Summarize this project" --output-format json | jq -r '.result'
session_id=$(claude -p "Start a review" --output-format json | jq -r '.session_id')
```

`total_cost_usd` includes a per-model cost breakdown — track spend per invocation.

Headless runs don't start the background-subagent summary timer, so `-p` spend carries no
status-line calls. That is observed on 2.1.309, not documented. The undocumented
`CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES=1` turns the timer on, for example to measure it.

### Structured output (`--json-schema`)

```bash
claude -p "Extract the main function names from auth.py" \
  --output-format json \
  --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}},"required":["functions"]}' \
  | jq '.structured_output'
```

The agent completes its full workflow, then the response is validated against the schema; metadata (session ID, usage) wraps the `structured_output` field.

### `stream-json`

Newline-delimited JSON events. Token streaming needs `--verbose --include-partial-messages`:

```bash
claude -p "Write a poem" --output-format stream-json --verbose --include-partial-messages | \
  jq -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
```

Notable event types:

- `system` / subtype `init` — first event; reports model, tools, MCP servers, `plugins` (loaded: `name`,`path`) and `plugin_errors` (`plugin`,`type`,`message`) — **fail CI on `plugin_errors`**.
- `system` / subtype `api_retry` — retryable API failure: `attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error` (`rate_limit`, `overloaded`, `server_error`, …).
- `system` / subtype `plugin_install` — with `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` set: `status` `started|installed|failed|completed`.
- `assistant` / `user` message events; `stream_event` partial deltas; final `result` event mirroring the `json` payload.

### `stream-json` input

`--input-format stream-json` accepts a stream of user messages on stdin for multi-turn programmatic driving; pair with `--output-format stream-json --verbose` (and `--replay-user-messages` for acks).

## Patterns

Pipe data:

```bash
cat build-error.txt | claude -p 'explain the root cause of this build error' > explanation.txt
git diff main | claude -p "you are a typo linter. report filename:line + issue per typo. nothing else."
```

Multi-turn:

```bash
claude -p "Review this codebase for performance issues"
claude -p "Now focus on the database queries" --continue
session=$(claude -p "Start a review" --output-format json | jq -r '.session_id')
claude -p "Continue that review" --resume "$session"
```

Scoped git permissions (note the space before `*` — `Bash(git diff *)` ≠ `Bash(git diff*)`, the latter also matches `git diff-index`):

```bash
claude -p "Look at my staged changes and create an appropriate commit" \
  --allowedTools "Bash(git diff *),Bash(git log *),Bash(git status *),Bash(git commit *)"
```

Locked-down CI:

```bash
claude --bare -p "Apply the lint fixes" --permission-mode acceptEdits
# dontAsk: deny anything not explicitly allowed — strictest non-interactive baseline
claude --bare -p "Audit only, change nothing" --permission-mode dontAsk --allowedTools "Read,Grep,Glob"
```

GitHub Actions review job (modernized):

```yaml
- name: Claude review
  run: |
    gh pr diff "$PR" | claude --bare -p \
      --append-system-prompt "You are a security engineer. Review for vulnerabilities." \
      --output-format json --allowedTools "Read,Grep" > review.json
    jq -e '.is_error == false' review.json
    jq -r '.result' review.json > review.md
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    PR: ${{ github.event.pull_request.number }}
```

Error handling:

```bash
result=$(claude -p "Task" --output-format json) || { echo "claude exited non-zero" >&2; exit 1; }
if [[ $(jq -r '.is_error' <<<"$result") == "true" ]]; then
  echo "Error: $(jq -r '.result' <<<"$result")" >&2; exit 1
fi
```

Background agents:

```bash
claude --bg "investigate the flaky test"   # prints session ID
claude agents --json                        # list background sessions
claude logs <id>; claude attach <id>; claude stop <id>; claude respawn <id>
```

Skills in prompts: `claude -p "/my-skill arg1"` expands before running. Interactive built-ins (`/config`, `/login`) are unavailable in `-p`.

Background Bash tasks started during a `-p` run (dev servers, watchers) are terminated ~5s after the final result (v2.1.163+).

## CI Auth

- API key: `ANTHROPIC_API_KEY` env var.
- Subscription: `claude setup-token` generates a long-lived OAuth token for CI/scripts.
- Bedrock/Vertex/Foundry: usual provider credentials.

## Agent SDK

For retries, hooks-as-callbacks, custom tools, native message objects, and structured outputs beyond `--json-schema`, use the Agent SDK packages: `@anthropic-ai/claude-agent-sdk` (TypeScript) / `claude-agent-sdk` (Python). Docs: https://code.claude.com/docs/en/agent-sdk/overview. The CLI flags above map 1:1 onto SDK options.
