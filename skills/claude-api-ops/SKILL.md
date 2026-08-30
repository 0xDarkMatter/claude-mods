---
name: claude-api-ops
description: "Building applications ON Claude - the Anthropic API and Claude Agent SDK. Use for: anthropic api, claude api, messages api, tool use, function calling, prompt caching, agent sdk, claude-agent-sdk, structured output, json schema output, batches api, extended thinking, adaptive thinking, model selection, claude pricing, build claude agent, anthropic sdk, stop_reason handling, streaming claude, token counting, cache_control, output_config, tool_choice, agentic loop, rate limits anthropic."
when_to_use: "Use when building applications on the Anthropic API or Claude Agent SDK — e.g. 'add tool use to my Claude app', 'set up prompt caching', 'which Claude model should I use', 'handle stop_reason / streaming'."
license: MIT
allowed-tools: "Read Write Bash WebFetch"
metadata:
  author: claude-mods
  related-skills: mcp-ops
---

# Claude API Operations

Building applications and agents on Anthropic's API: the Messages API, tool use,
prompt caching, structured outputs, batches, thinking/effort, and the Claude
Agent SDK. For developers writing apps *against* the API — not for using Claude
Code itself.

**API surfaces move fast.** Model IDs, parameters, and betas in this skill were
verified against platform.claude.com (2026-08). When in doubt — especially for
"latest model" or pricing questions — verify with WebFetch against
`https://platform.claude.com/docs/en/about-claude/models/overview.md` or query
the Models API (`client.models.list()`).

## Current Models (verified 2026-08)

| Model | ID (exact, no date suffix) | Context | Max Output | Input $/MTok | Output $/MTok |
|---|---|---|---|---|---|
| Claude Fable 5 | `claude-fable-5` | 1M | 128K | $10.00 | $50.00 |
| Claude Opus 5 | `claude-opus-5` | 1M | 128K | $5.00 | $25.00 |
| Claude Sonnet 5 | `claude-sonnet-5` | 1M | 128K | $2.00 | $10.00 |
| Claude Haiku 4.5 | `claude-haiku-4-5` | 200K | 64K | $1.00 | $5.00 |

Use these alias IDs verbatim. **Never append date suffixes** (`claude-sonnet-5-20260630`
is wrong → 404). Haiku 4.5 is the one current model with a *dated* snapshot id
(`claude-haiku-4-5-20251001`) behind its alias; from the 4.6 generation on, the dateless
id **is** the pinned snapshot.

**Legacy (still available, no longer current):** `claude-opus-4-8`, `claude-opus-4-7`,
`claude-opus-4-6`, `claude-opus-4-5`, `claude-sonnet-4-6`, `claude-sonnet-4-5`. Migrating
off one: `https://platform.claude.com/docs/en/models/opus-5/migration-guide.md` (or run
`/claude-api migrate` in Claude Code). Live capability lookup:
`client.models.retrieve("claude-opus-5")` → `.max_input_tokens`, `.max_tokens`,
`.capabilities` dict.

## Model Selection Decision Tree

```
What is the workload?
│
├─ Hardest problems, long-horizon agents, deep research, ceiling intelligence
│  └─ claude-fable-5 (premium ceiling) or claude-opus-5 (default flagship)
│
├─ Agentic coding, tool-heavy workflows, production assistants
│  └─ claude-opus-5 (quality) or claude-sonnet-5 (speed/cost balance)
│
├─ High-volume production: summarization, RAG answers, extraction
│  └─ claude-sonnet-5
│
├─ Classification, routing, simple Q&A, latency-critical
│  └─ claude-haiku-4-5
│
└─ Subagents inside a larger system
   └─ One tier below the orchestrator (Opus loop → Sonnet/Haiku workers)
```

Tiering rule: route by task difficulty, not by uniform default. An Opus
orchestrator dispatching Haiku classifiers is routinely 5-10x cheaper than
Opus-everywhere with no quality loss on the simple legs.

## Which Surface? (API vs Agent SDK vs Batches)

| Need | Use | Why |
|---|---|---|
| One request → one response (classify, summarize, extract, Q&A) | **Messages API** | Simplest; full control |
| Multi-step pipeline, your code controls the logic | **Messages API + tool use** | You own the loop |
| Custom agent with your own tools, your infra | **Messages API + tool use** (manual loop or SDK tool runner) | Max flexibility |
| Agent that reads/edits files, runs commands, searches — without building tools | **Claude Agent SDK** | Claude Code's tools + agent loop as a library |
| CI/CD automation, coding agents, production agent apps | **Claude Agent SDK** | Built-in tools, hooks, sessions, MCP |
| Large non-urgent workloads (eval runs, backfills, bulk extraction) | **Batches API** | 50% discount, ≤24h turnaround |
| Hosted agent, Anthropic runs loop + sandbox | **Managed Agents** (beta) | No infra; see official docs |

Rule of thumb: start at the simplest tier. Reach for an agent only when the
task is genuinely open-ended (multi-step, hard to fully specify, errors
recoverable, value justifies cost).

## Messages API Quick Start

Everything goes through `POST /v1/messages`. Headers: `x-api-key`,
`anthropic-version: 2023-06-01`, `content-type: application/json`.

```python
# pip install anthropic
import anthropic

client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY

response = client.messages.create(
    model="claude-opus-5",
    max_tokens=16000,
    system="You are a concise technical assistant.",
    messages=[{"role": "user", "content": "Explain CRDTs in one paragraph."}],
)
for block in response.content:        # content is a list of typed blocks
    if block.type == "text":          # always check .type before .text
        print(block.text)
print(response.stop_reason, response.usage.input_tokens, response.usage.output_tokens)
```

```typescript
// npm install @anthropic-ai/sdk
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();

const response = await client.messages.create({
  model: "claude-opus-5",
  max_tokens: 16000,
  messages: [{ role: "user", content: "Explain CRDTs in one paragraph." }],
});
for (const block of response.content) {
  if (block.type === "text") console.log(block.text);  // narrow the union first
}
```

Streaming (default to it for long outputs — non-streaming above ~16K
`max_tokens` risks SDK HTTP timeouts):

```python
with client.messages.stream(model="claude-opus-5", max_tokens=64000,
                            messages=[{"role": "user", "content": "Write a long report"}]) as stream:
    for text in stream.text_stream:
        print(text, end="", flush=True)
    final = stream.get_final_message()   # full Message after streaming
```

Full params, response shape, stop reasons, errors, retries, rate limits:
[references/messages-api.md](references/messages-api.md)

## Thinking & Effort (quick reference)

- **Adaptive thinking is ON BY DEFAULT on Fable 5 / Opus 5 / Sonnet 5** — send no
  `thinking` field and you still get (and pay for) thinking. On the legacy
  4.6–4.8 models it stays off until you set `thinking: {"type": "adaptive"}`.
- **Manual budgets are gone.** `{"type": "enabled", "budget_tokens": N}` returns a
  **400 on Opus 4.7 and every later model** (Opus 5, Sonnet 5, Fable 5 included);
  deprecated on Opus 4.6 / Sonnet 4.6. Control depth with `effort`, not tokens.
- **Turning thinking off:** Sonnet 5 accepts `{"type": "disabled"}`. Opus 5 accepts
  it only at effort `high` or below — pairing it with `xhigh`/`max` is a **400**.
  Fable 5 **rejects it outright**; thinking there is unconditional, so budget for it.
- **Effort (GA):** `output_config: {"effort": "low" | "medium" | "high" | "xhigh" | "max"}`
  — nested in `output_config`, not top-level. Default `high` (identical to omitting
  it). `xhigh`: Fable 5, Opus 5, Opus 4.8/4.7, **Sonnet 5**. `max`: those plus Opus 4.6
  and Sonnet 4.6. Haiku 4.5 does not support `effort` at all.
- **Sampling params removed on Opus 4.7 and later** (so Opus 5, Sonnet 5, Fable 5):
  `temperature`, `top_p`, `top_k` all return 400 — and the Python SDK v1.0+ doesn't
  define them, so passing them raises `TypeError`. Steer with prompting + effort.
- **Forced tool_choice is fine with adaptive thinking.** The auto/none-only
  restriction applies to *manual* extended thinking (`{"type": "enabled"}`) only;
  adaptive mode — including the models where it's on by default — accepts
  `{"type": "any"}` and `{"type": "tool", ...}`.
- Thinking text is **omitted by default** on Fable 5 / Opus 5 / Sonnet 5 / Opus 4.8 /
  4.7 — opt in with `thinking: {"type": "adaptive", "display": "summarized"}` if you
  surface reasoning to users. Either way the blocks are billed, and must be echoed
  back **unmodified** (empty `thinking` field included) in a tool-use loop, or the
  next request 400s.

Details and gotchas: [references/structured-outputs.md](references/structured-outputs.md)
(thinking interplay) and [references/messages-api.md](references/messages-api.md).

## Tool Use (quick reference)

```python
tools = [{
    "name": "get_weather",
    "description": "Get current weather. Call when the user asks about weather conditions.",
    "input_schema": {
        "type": "object",
        "properties": {"location": {"type": "string", "description": "City, e.g. Paris"}},
        "required": ["location"],
    },
}]
response = client.messages.create(model="claude-opus-5", max_tokens=16000,
                                  tools=tools, messages=messages)
if response.stop_reason == "tool_use":
    ...  # execute, send tool_result back, loop
```

`tool_choice`: `{"type": "auto"}` (default) | `{"type": "any"}` | `{"type":
"tool", "name": "..."}` | `{"type": "none"}`. Add
`"disable_parallel_tool_use": true` to force at most one call per response.

The agentic loop, parallel tool results, `pause_turn`, `is_error`, server-side
tools, and SDK tool runners: [references/tool-use.md](references/tool-use.md)

## Cost Optimization Checklist

Work top-down; each item is independent:

- [ ] **Right-size the model.** Haiku for classification/routing, Sonnet for
      volume work, Opus/Fable for the hard 10%. Largest single lever.
- [ ] **Prompt caching** on stable prefixes (system prompt, tool defs, big docs):
      `cache_control: {"type": "ephemeral"}`. Reads cost ~0.1x; up to 90% savings.
      Verify with `usage.cache_read_input_tokens > 0` — zero means a silent
      invalidator (timestamp in system prompt, unsorted JSON, varying tools).
- [ ] **Batches API** for anything that can wait ≤24h: flat 50% off all tokens,
      stacks with caching.
- [ ] **Cap output**: set `max_tokens` to what you need (256 for classification);
      stream + generous cap for long generation.
- [ ] **Tune effort down** where quality allows: `medium` is often the sweet
      spot; `low` for subagents and simple tasks.
- [ ] **Count before sending**: `client.messages.count_tokens(...)` (never
      tiktoken — it's OpenAI's tokenizer and undercounts Claude by 15-20%).
- [ ] **Keep prefixes stable**: order requests `tools` → `system` → `messages`,
      volatile content last; don't swap tool sets or models mid-conversation.

Mechanics, breakpoints, TTLs, batch lifecycle, tiering math:
[references/caching-and-cost.md](references/caching-and-cost.md)

## Claude Agent SDK (quick reference)

```python
# pip install claude-agent-sdk   (Python >= 3.10)
import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions

async def main():
    async for message in query(
        prompt="Find and fix the bug in auth.py",
        options=ClaudeAgentOptions(allowed_tools=["Read", "Edit", "Bash"]),
    ):
        if hasattr(message, "result"):
            print(message.result)

asyncio.run(main())
```

```typescript
// npm install @anthropic-ai/claude-agent-sdk
import { query } from "@anthropic-ai/claude-agent-sdk";

for await (const message of query({
  prompt: "Find and fix the bug in auth.ts",
  options: { allowedTools: ["Read", "Edit", "Bash"] },
})) {
  if ("result" in message) console.log(message.result);
}
```

Built-in tools (Read/Write/Edit/Bash/Glob/Grep/WebSearch/WebFetch/...), hooks
(`PreToolUse`, `PostToolUse`, ...), subagents, MCP servers, sessions
(resume/fork), permission modes, and the SDK-vs-raw-API decision:
[references/agent-sdk.md](references/agent-sdk.md)

## Common Pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| Date-suffixed or guessed model ID | 404 `not_found_error` | Use exact alias IDs from the table above |
| `budget_tokens` on Opus 4.7+ (incl. Opus 5 / Sonnet 5 / Fable 5) | 400 | `thinking: {"type": "adaptive"}` + `effort` |
| Assuming thinking is opt-in on Fable 5 / Opus 5 / Sonnet 5 | Unexpected thinking tokens billed | Adaptive thinking is on by default there; Fable 5 can't be disabled at all |
| `thinking: {"type": "disabled"}` at `xhigh`/`max` on Opus 5 | 400 | Drop effort to `high` or below, or leave thinking on |
| `temperature`/`top_p`/`top_k` on Opus 4.7+ | 400 (or `TypeError` on Python SDK v1.0+) | Remove; steer via prompt + `effort` |
| `effort` on Haiku 4.5 | 400 | Haiku 4.5 doesn't support the parameter |
| Rebuilding assistant turns in a tool loop (dropping empty `thinking` blocks) | 400 "thinking blocks cannot be modified" | Echo the content list back exactly as received |
| Assistant-turn prefill on Opus 4.7+ models | 400 | `output_config.format` or system-prompt instruction |
| Cache marker on <minimum prefix | Silent no-cache (`cache_creation_input_tokens: 0`) | Min 512-4096 tokens depending on model (see caching ref) |
| Not handling `stop_reason: "tool_use"` | Agent "stops" after first tool call | Loop: execute tools, append `tool_result`, re-request |
| Missing `tool_result` for a `tool_use` id | 400 on follow-up | One `tool_result` per `tool_use` block, ids matching |
| Non-streaming with `max_tokens` > ~16K | SDK timeout / `ValueError` | Stream + `get_final_message()` / `finalMessage()` |
| `output_format` top-level param | Deprecated | `output_config: {"format": {...}}` |
| tiktoken for Claude token counts | 15-20%+ undercount | `messages.count_tokens` endpoint |
| String-matching error messages | Fragile retries | Typed exceptions: `anthropic.RateLimitError` etc. |
| Raw string-matching tool `input` | Breaks on escaping changes | Always `json.loads()` / use parsed `block.input` |

## Resources & Verification

This skill ships a staleness verifier and two copy-and-adapt starter assets. The
model table and pricing above are the facts most likely to drift — run the
verifier when you suspect they're stale.

**`scripts/check-model-table.py`** — guards the Current Models table (this file)
and the per-model prompt-cache minimum table
([references/caching-and-cost.md](references/caching-and-cost.md)) against drift.
Two modes per the [resource protocol §7](../../docs/SKILL-RESOURCE-PROTOCOL.md):

```bash
# Structural (default, no network): every row well-formed, ids carry no date
# suffix, prices numeric, the two files agree on the model lineup. Exit 4 on a
# malformed/contradictory row.
python skills/claude-api-ops/scripts/check-model-table.py --offline
python skills/claude-api-ops/scripts/check-model-table.py --offline --json | python -m json.tool

# Live (advisory, needs ANTHROPIC_API_KEY): curls the Models API and compares
# its id set against the documented ids. Exit 10 if a documented id is gone or a
# newer alias id is missing from the table; exit 7 (not a failure) if the key is
# unset or the API is unreachable. Live mode checks model-ID coverage ONLY — the
# API returns no pricing, so pricing/context drift stays an --offline + docs concern.
ANTHROPIC_API_KEY=sk-... python skills/claude-api-ops/scripts/check-model-table.py --live
```

**`assets/agentic-loop.py`** — a minimal, runnable tool-use loop (define a tool,
call `messages.create`, loop while `stop_reason == "tool_use"`, append
`tool_result`, re-request until `end_turn`). Copy it as the starting point when
building a manual agent loop; the `>>> ADAPT` marks show what to change.

**`assets/output-schema.json`** — a known-good structured-outputs request body in
the canonical `output_config.format` shape (with `additionalProperties: false`
and a `required` array). Copy and reshape `schema.properties` when adding JSON
outputs; see [references/structured-outputs.md](references/structured-outputs.md)
for the rules. (Supported on Fable 5, Opus 5, Sonnet 5, and the 4.5–4.8 line;
Haiku 4.5 needs its dated id, `claude-haiku-4-5-20251001`.)

## Reference Files

| File | Covers |
|---|---|
| [references/messages-api.md](references/messages-api.md) | Params, response shape, streaming events, stop reasons, error handling, retries, rate limits |
| [references/tool-use.md](references/tool-use.md) | Tool definitions, tool_choice, parallel tools, agentic loop, tool results, server tools, tool runners |
| [references/caching-and-cost.md](references/caching-and-cost.md) | Prompt caching mechanics, Batches API, token counting, model tiering economics |
| [references/structured-outputs.md](references/structured-outputs.md) | output_config.format, schema rules/limits, strict tools, parse() helpers, thinking interplay |
| [references/agent-sdk.md](references/agent-sdk.md) | Python + TS Agent SDK, ClaudeAgentOptions, hooks, MCP, sessions, SDK vs raw API |

## Live Documentation

When cached facts may be stale, WebFetch (append `.md` for clean markdown):

- Models/pricing: `https://platform.claude.com/docs/en/about-claude/models/overview.md`
- Messages API: `https://platform.claude.com/docs/en/api/messages`
- Tool use: `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview.md`
- Prompt caching: `https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md`
- Structured outputs: `https://platform.claude.com/docs/en/build-with-claude/structured-outputs.md`
- Batches: `https://platform.claude.com/docs/en/build-with-claude/batch-processing.md`
- Agent SDK: `https://code.claude.com/docs/en/agent-sdk/overview`
