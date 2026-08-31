# Tool Use Reference

Tool use is a feature of `POST /v1/messages` — you pass `tools`, Claude
responds with `tool_use` content blocks, you execute and return `tool_result`
blocks. **Client tools** run in your code; **server tools** (web_search,
code_execution, web_fetch) run on Anthropic's infrastructure.

## Tool Definition

```json
{
  "name": "get_weather",
  "description": "Get current weather for a location. Call this when the user asks about weather conditions, temperature, or forecasts.",
  "input_schema": {
    "type": "object",
    "properties": {
      "location": {"type": "string", "description": "City and state, e.g. San Francisco, CA"},
      "unit": {"type": "string", "enum": ["celsius", "fahrenheit"], "description": "Temperature unit"}
    },
    "required": ["location"]
  }
}
```

Rules that actually move the needle:

- **Descriptions are the routing signal.** Be prescriptive about *when* to
  call, not just what it does ("Call this when the user asks about current
  prices or recent events"). Recent Opus models reach for tools more
  conservatively — trigger conditions in the description give measurable lift.
- Describe every property; use `enum` for closed sets; only truly-required
  params in `required`.
- Specific names beat generic ones: `get_current_weather` > `weather`.
- Keep the tool set focused — too many similar tools degrades selection. For
  large tool libraries, use the server-side **tool search tool** (loads schemas
  on demand, preserves the prompt cache by appending rather than swapping).
- **Sample calls in definitions**: you can include example invocations
  (`input_examples` on supported surfaces / examples embedded in the
  description) to demonstrate parameter formats and cut parameter errors —
  most useful for complex nested schemas.
- `strict: true` on a tool guarantees the emitted `input` validates against
  the schema exactly (see structured-outputs.md; max 20 strict tools/request).

## tool_choice

| Value | Behavior |
|---|---|
| `{"type": "auto"}` | Claude decides (default when tools are present) |
| `{"type": "any"}` | Must call at least one tool |
| `{"type": "tool", "name": "get_weather"}` | Must call that specific tool |
| `{"type": "none"}` | Cannot call tools (definitions stay in context) |

Any variant accepts `"disable_parallel_tool_use": true` to cap at one tool
call per response.

Gotchas:

- **Manual extended thinking (`{"type": "enabled"}`) + `any`/`tool` = 400.**
  Only `auto`/`none` are compatible with it. **Adaptive thinking has no such
  limit** — including the models where it is on by default (Fable 5, Opus 5,
  Sonnet 5), forced tool choice is accepted.
- `any`/`tool` add more tool-use system-prompt tokens than `auto`/`none` (a
  measured ~410 vs ~290 on Opus 4.8; re-measure with `count_tokens` rather than
  carrying the figure across model generations).
- Changing `tool_choice` between requests does **not** invalidate the
  tools+system prompt cache (message cache only).

## Parallel Tool Use

By default Claude may emit **multiple `tool_use` blocks in one response**.
Execute them all (concurrently if safe), then return **all results in a single
user message** — one `tool_result` per `tool_use`, ids matching, results may
be in any order but must all be present:

```python
tool_results = []
for block in response.content:
    if block.type == "tool_use":
        result = execute_tool(block.name, block.input)   # block.input is parsed dict
        tool_results.append({
            "type": "tool_result",
            "tool_use_id": block.id,
            "content": result,
        })
messages.append({"role": "assistant", "content": response.content})
messages.append({"role": "user", "content": tool_results})
```

A follow-up request missing a `tool_result` for any outstanding `tool_use` id
is a 400.

## The Agentic Loop (manual)

Use the manual loop when you need approval gates, custom logging, or
conditional execution:

```python
import anthropic

client = anthropic.Anthropic()
messages = [{"role": "user", "content": user_input}]

while True:
    response = client.messages.create(
        model="claude-opus-5",
        max_tokens=16000,
        tools=tools,
        messages=messages,
    )

    if response.stop_reason == "end_turn":
        break

    if response.stop_reason == "pause_turn":
        # Server-side tool loop hit its iteration limit: append and re-send.
        # Do NOT inject a "continue" user message — the API resumes automatically.
        messages.append({"role": "assistant", "content": response.content})
        continue

    if response.stop_reason == "tool_use":
        messages.append({"role": "assistant", "content": response.content})
        results = []
        for block in response.content:
            if block.type == "tool_use":
                try:
                    out = execute_tool(block.name, block.input)
                    results.append({"type": "tool_result",
                                    "tool_use_id": block.id, "content": out})
                except Exception as e:
                    results.append({"type": "tool_result",
                                    "tool_use_id": block.id,
                                    "content": f"Error: {e}", "is_error": True})
        messages.append({"role": "user", "content": results})
        continue

    break  # max_tokens / refusal / stop_sequence — handle per stop_reason

final_text = next((b.text for b in response.content if b.type == "text"), "")
```

```typescript
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();
const messages: Anthropic.MessageParam[] = [{ role: "user", content: userInput }];

while (true) {
  const response = await client.messages.create({
    model: "claude-opus-5", max_tokens: 16000, tools, messages,
  });

  if (response.stop_reason === "end_turn") break;

  if (response.stop_reason === "pause_turn") {
    messages.push({ role: "assistant", content: response.content });
    continue;
  }

  const toolUses = response.content.filter(
    (b): b is Anthropic.ToolUseBlock => b.type === "tool_use",
  );
  messages.push({ role: "assistant", content: response.content });

  const results: Anthropic.ToolResultBlockParam[] = [];
  for (const t of toolUses) {
    results.push({ type: "tool_result", tool_use_id: t.id,
                   content: await executeTool(t.name, t.input) });
  }
  messages.push({ role: "user", content: results });
}
```

Loop invariants:

1. Append the **full** `response.content` as the assistant turn (preserves
   `tool_use` + `thinking` blocks; thinking `signature` must round-trip
   untouched).
2. One `tool_result` per `tool_use`, matching `tool_use_id`.
3. Tool results go in a **user** message.
4. Add a max-iterations guard (e.g. 10-20) so a confused model can't loop forever.
5. Parse `block.input` as structured data — never regex the serialized JSON
   (escaping varies across models).

## Tool Result Shapes

```json
{"type": "tool_result", "tool_use_id": "toolu_01...", "content": "plain string"}

{"type": "tool_result", "tool_use_id": "toolu_01...",
 "content": [{"type": "text", "text": "..."},
             {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}]}

{"type": "tool_result", "tool_use_id": "toolu_01...",
 "content": "Error: location 'xyz' not found. Provide a valid city.",
 "is_error": true}
```

`is_error: true` tells Claude the execution failed — it will typically adjust
approach or ask for clarification. Return **informative** error strings, not
stack traces.

## SDK Tool Runners (beta) — skip the manual loop

The runners handle call → execute → feed-back → repeat automatically.

```python
from anthropic import beta_tool
import anthropic

client = anthropic.Anthropic()

@beta_tool
def get_weather(location: str, unit: str = "celsius") -> str:
    """Get current weather for a location.

    Args:
        location: City and state, e.g. San Francisco, CA.
        unit: "celsius" or "fahrenheit".
    """
    return f"22°C and sunny in {location}"

runner = client.beta.messages.tool_runner(
    model="claude-opus-5", max_tokens=16000,
    tools=[get_weather],
    messages=[{"role": "user", "content": "Weather in Paris?"}],
)
for message in runner:        # iterates messages until Claude stops calling tools
    print(message)
```

```typescript
import Anthropic from "@anthropic-ai/sdk";
import { betaZodTool } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

const getWeather = betaZodTool({
  name: "get_weather",
  description: "Get current weather for a location",
  inputSchema: z.object({
    location: z.string().describe("City and state, e.g. San Francisco, CA"),
  }),
  run: async ({ location }) => `22°C and sunny in ${location}`,
});

const finalMessage = await client.beta.messages.toolRunner({
  model: "claude-opus-5", max_tokens: 16000,
  tools: [getWeather],
  messages: [{ role: "user", content: "Weather in Paris?" }],
});
```

Schemas are generated from the function signature/docstring (Python) or Zod
schema (TS). The runner executes tools **automatically** — for destructive
side effects (email, payments, deletes), validate inside the tool function or
use the manual loop with a human-approval gate.

## Server-Side Tools

Declared in `tools`, executed by Anthropic — no client handling:

| Tool | Type string | Notes |
|---|---|---|
| Web search | `web_search_20260209` | Per-search pricing; `allowed_domains`, `blocked_domains`, `max_uses` |
| Web fetch | `web_fetch_20260209` | Fetch URL content with citations |
| Code execution | `code_execution_20260120` | Sandboxed Python 3.11 (pandas/numpy/matplotlib preinstalled), no internet; container reusable via response `container.id` |
| Tool search | `tool_search_tool_bm25_20251119` / `..._regex_20251119` | On-demand tool discovery for large libraries |
| Memory | `memory_20250818` | Client-executed but Anthropic-defined schema |
| Bash / text editor | `bash_20250124` / `text_editor_20250728` (name `str_replace_based_edit_tool`) | Anthropic-defined, **you** execute |

Server tool runs may return `stop_reason: "pause_turn"` when the server-side
loop hits its iteration limit (default 10) — append the assistant turn and
re-request to resume (see loop above). Cap continuations (~5) to avoid
infinite resumes.

`web_search_20260209` / `web_fetch_20260209` include **dynamic filtering**
(model filters results in a sandbox before they hit context) automatically —
don't add a separate `code_execution` tool just for that; only declare
code_execution when you need it independently.

## Bash vs Dedicated Tools (design)

A bash tool gives breadth but the harness sees only an opaque command string.
Promote an action to a dedicated tool when you need to:

- **Gate** it (send_email behind confirmation — easy as a tool, impossible as `bash -c "curl ..."`)
- **Validate** invariants (an edit tool can reject writes to files changed since last read)
- **Render** it specially (question-asking as a modal)
- **Parallelize** safely (read-only tools marked parallel-safe; bash must serialize)

Start with bash for breadth; promote when you need to gate, render, audit, or
parallelize.
