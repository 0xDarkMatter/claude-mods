---
name: claude-api-ops
description: "Building applications ON Claude - the Anthropic API and Claude Agent SDK. Use for: anthropic api, claude api, messages api, tool use, function calling, prompt caching, agent sdk, claude-agent-sdk, structured output, json schema output, batches api, extended thinking, adaptive thinking, model selection, claude pricing, build claude agent, anthropic sdk, stop_reason handling, streaming claude, token counting, cache_control, output_config, tool_choice, agentic loop, rate limits anthropic, context engineering, context window budget, compaction, context editing, context_management, clear_tool_uses, memory tool, context rot, tool result bloat, subagent context isolation."
when_to_use: "Use when building applications on the Anthropic API or Claude Agent SDK — e.g. 'add tool use to my Claude app', 'set up prompt caching', 'which Claude model should I use', 'handle stop_reason / streaming', 'should I compact this agent context'."
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
verified against platform.claude.com (2026-06). When in doubt — especially for
"latest model" or pricing questions — verify with WebFetch against
`https://platform.claude.com/docs/en/about-claude/models/overview.md` or query
the Models API (`client.models.list()`).

## Current Models (verified 2026-06)

| Model | ID (exact, no date suffix) | Context | Max Output | Input $/MTok | Output $/MTok |
|---|---|---|---|---|---|
| Claude Fable 5 | `claude-fable-5` | 1M | 128K | $10.00 | $50.00 |
| Claude Opus 4.8 | `claude-opus-4-8` | 1M | 128K | $5.00 | $25.00 |
| Claude Sonnet 4.6 | `claude-sonnet-4-6` | 1M | 64K | $3.00 | $15.00 |
| Claude Haiku 4.5 | `claude-haiku-4-5` | 200K | 64K | $1.00 | $5.00 |

Use these alias IDs verbatim. **Never append date suffixes** (`claude-sonnet-4-6-20251114`
is wrong → 404). Older actives: `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`,
`claude-sonnet-4-5`. Live capability lookup: `client.models.retrieve("claude-opus-4-8")`
→ `.max_input_tokens`, `.max_tokens`, `.capabilities` dict.

## Model Selection Decision Tree

```
What is the workload?
│
├─ Hardest problems, long-horizon agents, deep research, ceiling intelligence
│  └─ claude-fable-5 (premium) or claude-opus-4-8 (default flagship)
│
├─ Agentic coding, tool-heavy workflows, production assistants
│  └─ claude-opus-4-8 (quality) or claude-sonnet-4-6 (speed/cost balance)
│
├─ High-volume production: summarization, RAG answers, extraction
│  └─ claude-sonnet-4-6
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
    model="claude-opus-4-8",
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
  model: "claude-opus-4-8",
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
with client.messages.stream(model="claude-opus-4-8", max_tokens=64000,
                            messages=[{"role": "user", "content": "Write a long report"}]) as stream:
    for text in stream.text_stream:
        print(text, end="", flush=True)
    final = stream.get_final_message()   # full Message after streaming
```

Full params, response shape, stop reasons, errors, retries, rate limits:
[references/messages-api.md](references/messages-api.md)

## Thinking & Effort (quick reference)

- **Claude 4.6+ (Fable 5, Opus 4.8/4.7/4.6, Sonnet 4.6):** use
  `thinking: {"type": "adaptive"}`. The old fixed budget
  `{"type": "enabled", "budget_tokens": N}` is **removed on Fable 5 / Opus 4.8 / 4.7
  (400 error)** and deprecated on Opus 4.6 / Sonnet 4.6.
- **Effort (GA):** `output_config: {"effort": "low" | "medium" | "high" | "xhigh" | "max"}`
  — nested in `output_config`, not top-level. Default `high`. `xhigh` (Opus 4.7+)
  is best for coding/agentic work; `max` is Opus-tier + Sonnet 4.6 only.
- **Sampling params removed on Fable 5 / Opus 4.8 / 4.7:** `temperature`,
  `top_p`, `top_k` all return 400. Steer with prompting + effort.
- **Thinking + forced tool_choice is incompatible:** with thinking on, only
  `tool_choice: {"type": "auto"}` (default) or `"none"` is allowed —
  `{"type": "any"}` or `{"type": "tool", ...}` returns a 400.
- Thinking text is **omitted by default** on Fable 5 / Opus 4.8 / 4.7 — opt in
  with `thinking: {"type": "adaptive", "display": "summarized"}` if you surface
  reasoning to users.

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
response = client.messages.create(model="claude-opus-4-8", max_tokens=16000,
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

## Context Engineering

Prompt engineering asks what to write in the prompt. **Context engineering asks what
earns a place in the window on *this* call** — including everything that lands there
without you typing it: tool definitions, tool results, retrieved documents, prior
turns, thinking blocks. It is iterative (every inference) where prompt engineering is
discrete (written once). Target: the smallest set of high-signal tokens that gets the
outcome.

The budget is real because attention degrades with length (**context rot** — n²
pairwise relationships), not just because tokens cost money. A 1M window is a
capacity, not a target.

### The three tiers

Every candidate fact lives in exactly one place. Choosing deliberately is most of the job.

| Tier | Where | Cost | Use when |
|---|---|---|---|
| **1 — In context** | `tools` / `system` / `messages`, every call | Paid every turn (≈0.1× cached) | It steers *most* turns |
| **2 — On disk, read on demand** | A file the agent can read; only the **path** stays in context | Paid only when read | The agent can tell from a *name* that it needs this |
| **3 — Retrieved** | Index / search tool behind a query | Paid only on a hit, plus a relevance gamble | The corpus is too large to enumerate |

When a prompt is too big, **demote before you delete** — a path is ~10 tokens; the
file it names may be 10,000.

**This repo already runs on the tier-1/tier-2 split.** A skill's `description` is
always resident (tier 1, so it must carry the routing signal); `SKILL.md` loads on a
match; `references/*.md` load only when cited and needed. "Description is the
trigger", "body under 500 lines", "one concept per reference", "every reference must
be cited" are context-engineering rules wearing authoring clothes.

### Cache-aware prompt architecture

Requests render `tools` → `system` → `messages`, and the cache is a **prefix match**.
So **static prefix first, volatile content last** — put the `cache_control` breakpoint
at the end of the stable part and let per-request content fall after it.

Reordering a prompt destroys the cache **silently**: no error, just a different prefix
hash, `cache_read_input_tokens: 0`, and a 1.25–2× bill where you expected 0.1×. The
usage block is the only symptom, which is why asserting `cache_read_input_tokens > 0`
in staging is a real test.

### The compaction decision

**Under modern prompt caching, keeping the full history has been measured to beat
summarisation on cost, latency AND recall at the same time.** A 2026 production-tutor
evaluation (660 turns, 11 configurations) put keep-everything at 92–100% fact recall,
$0.11/turn and 17 s TTFT, against 38–58% recall, $0.24/turn and 21 s for its
clear-plus-summarise preset. Summarising rewrites the cached prefix and forfeits the
0.1× discount — the cheap move is usually to **append**. (That study ran on a
non-Claude model; what transfers is the *mechanism*, and Claude's flat 0.1× cache
read makes it stronger, not weaker. Full caveats in
[references/compaction.md](references/compaction.md).)

So: **compact only as a deliberate response to a named constraint.**

| Constraint | Diagnose | Try first |
|---|---|---|
| **Context ceiling** — it will not fit | Projected tokens > window | Cap tool output → payloads to files → server-side clearing |
| **Cost ceiling** — the bill is unacceptable | Compare against *cached* cost, not uncached | **Verify the cache is hitting** → tier down → cap tool output |
| **Latency target** — TTFT too slow at depth | Confirm growth is in the prefix | Cap tool output → lower `effort` → stream |

Capping tool output at the tool boundary is the underrated lever: it shrinks context
**without rewriting the cached prefix** (the same study measured −38% cost/turn with
no recall loss). Clearing and summarising both break the cache; they are what people
reach for first and should reach for last.

First-party clearing is `context_management` (beta `context-management-2025-06-27`):
`clear_tool_uses_20250919` and `clear_thinking_20251015`, applied server-side. Always
set `clear_at_least` — it stops a trigger paying a full cache re-write to save a
handful of tokens. Pair with the memory tool so durable conclusions are written out
before raw material is cleared.

### Agentic specifics

- **Tool results are the growth term**, not the system prompt. Design tools to return
  decisions, not dumps.
- **Summarise vs write-to-file:** needed later *in full* → write to a file, return the
  path. Only the *conclusion* matters → summarise **at the tool boundary** (free of
  cache cost, unlike rewriting history after the fact).
- **Sub-agents are context isolation**, not just parallelism: 80K tokens of
  exploration are billed once inside the child and discarded; the parent sees a
  ~1–2K-token distillation. Costs: cold cache in the child, a lossy hand-off. Skip it
  when the subtask needs most of the parent's context to make sense.

Full doctrine — tiers, progressive disclosure, instrumentation:
[references/context-engineering.md](references/context-engineering.md).
Compaction economics, `context_management` parameters, memory tool:
[references/compaction.md](references/compaction.md).
For Claude Code's own context surface see the `claude-code-ops` skill; for
prompts re-sent on a cadence, `loop-ops`; for cross-provider fan-out, `fleetflow`.

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
| `budget_tokens` on Fable 5 / Opus 4.8 / 4.7 | 400 | `thinking: {"type": "adaptive"}` |
| Assuming thinking is opt-in on Fable 5 | Unexpected thinking tokens billed | Fable 5 thinking is always-on and cannot be disabled (`{"type": "disabled"}` rejected); budget for it |
| `temperature`/`top_p`/`top_k` on Fable 5 / Opus 4.8 / 4.7 | 400 | Remove; steer via prompt + `effort` |
| Thinking + `tool_choice: any/tool` | 400 | Only `auto`/`none` with thinking on |
| Assistant-turn prefill on 4.6+ models | 400 | `output_config.format` or system-prompt instruction |
| Cache marker on <minimum prefix | Silent no-cache (`cache_creation_input_tokens: 0`) | Min 512-4096 tokens depending on model (see caching ref) |
| Not handling `stop_reason: "tool_use"` | Agent "stops" after first tool call | Loop: execute tools, append `tool_result`, re-request |
| Missing `tool_result` for a `tool_use` id | 400 on follow-up | One `tool_result` per `tool_use` block, ids matching |
| Non-streaming with `max_tokens` > ~16K | SDK timeout / `ValueError` | Stream + `get_final_message()` / `finalMessage()` |
| `output_format` top-level param | Deprecated | `output_config: {"format": {...}}` |
| tiktoken for Claude token counts | 15-20%+ undercount | `messages.count_tokens` endpoint |
| String-matching error messages | Fragile retries | Typed exceptions: `anthropic.RateLimitError` etc. |
| Raw string-matching tool `input` | Breaks on escaping changes | Always `json.loads()` / use parsed `block.input` |
| Compacting by reflex on a long conversation | Higher cost, worse recall than doing nothing | Name the constraint first; under caching, appending usually wins (see Context Engineering) |
| `clear_tool_uses` without `clear_at_least` | A full cache re-write to reclaim a few hundred tokens | Set `clear_at_least` so each cache break is worth taking |

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
# suffix, prices numeric, the two files agree on the model lineup. It also
# guards the cache-economics constants that are stated in more than one file
# (0.1x read, 1.25x/2x writes, 4 breakpoints, 20-block lookback, the
# context-management beta id), asserts each doctrine reference carries a
# "verified <ISO date>" stamp, and checks SKILL.md <-> references/ citation
# integrity in both directions. Exit 4 on any contradiction.
python skills/claude-api-ops/scripts/check-model-table.py --offline
python skills/claude-api-ops/scripts/check-model-table.py --offline --json | python -m json.tool

# Live (advisory, needs ANTHROPIC_API_KEY): curls the Models API and compares
# its id set against the documented ids. Exit 10 if a documented id is gone or a
# newer alias id is missing from the table; exit 7 (not a failure) if the key is
# unset or the API is unreachable. Live mode checks model-ID coverage ONLY — the
# API returns no pricing, so pricing/context drift stays an --offline + docs concern.
ANTHROPIC_API_KEY=sk-... python skills/claude-api-ops/scripts/check-model-table.py --live
```

**`scripts/context-budget.py`** — append-vs-compact calculator. Models both paths
in dollars over the turns you actually have left, checks the context ceiling
first, and exits **10** when cost favours compaction, **0** when appending wins:

```bash
# Short session — appending is cheaper (exit 0)
python skills/claude-api-ops/scripts/context-budget.py \
    --history-tokens 25000 --turns-remaining 5 --base-rate 0.30

# Deep session — cost favours compaction (exit 10)
python skills/claude-api-ops/scripts/context-budget.py \
    --history-tokens 120000 --turns-remaining 40 --base-rate 2.00 --json
```

Two results worth knowing before you trust it: the break-even turn count is
**scale-invariant** (history size and price cancel out — it tracks the summary
ratio, not how big or costly the conversation is), and it prices **cost only**.
Recall loss is not in the model, so "compact" means cheaper, not better.

**`assets/cached-agent-loop.py`** — the cache-aware sibling of the minimal loop
below, and the executable form of the Context Engineering section: breakpoint at
the end of the static prefix, a rolling breakpoint on the newest turn, an
intermediate anchor every ~15 blocks so long tool-heavy turns don't jump the
20-block lookback, tool output capped at the boundary, and a per-turn
`cache_read_input_tokens` check that warns when the prefix silently changed.
Copy it when the agent is long-running; copy `agentic-loop.py` when it isn't.

**`assets/recall-probe.py`** — the "measure it on your workload" harness:
plants a fact, buries it under N turns, probes for it, and reports recall, cost
per turn and TTFT for **append** vs **compact**. Makes real API calls, so start
small (`--turns 6 --trials 1`). Replace the synthetic filler turns with traffic
from your own logs — that is the point of running it.

**`assets/agentic-loop.py`** — a minimal, runnable tool-use loop (define a tool,
call `messages.create`, loop while `stop_reason == "tool_use"`, append
`tool_result`, re-request until `end_turn`). Copy it as the starting point when
building a manual agent loop; the `>>> ADAPT` marks show what to change.

**`assets/output-schema.json`** — a known-good structured-outputs request body in
the canonical `output_config.format` shape (with `additionalProperties: false`
and a `required` array). Copy and reshape `schema.properties` when adding JSON
outputs; see [references/structured-outputs.md](references/structured-outputs.md)
for the rules. (Not supported on Fable 5 — that model uses system-prompt
instructions instead.)

## Reference Files

| File | Covers |
|---|---|
| [references/messages-api.md](references/messages-api.md) | Params, response shape, streaming events, stop reasons, error handling, retries, rate limits |
| [references/tool-use.md](references/tool-use.md) | Tool definitions, tool_choice, parallel tools, agentic loop, tool results, server tools, tool runners |
| [references/caching-and-cost.md](references/caching-and-cost.md) | Prompt caching mechanics, Batches API, token counting, model tiering economics |
| [references/structured-outputs.md](references/structured-outputs.md) | output_config.format, schema rules/limits, strict tools, parse() helpers, thinking interplay |
| [references/agent-sdk.md](references/agent-sdk.md) | Python + TS Agent SDK, ClaudeAgentOptions, hooks, MCP, sessions, SDK vs raw API |
| [references/context-engineering.md](references/context-engineering.md) | Context budget, the three tiers, progressive disclosure, cache-aware ordering, tool-result bloat, sub-agents as isolation, instrumentation |
| [references/compaction.md](references/compaction.md) | When compaction is justified, break-even arithmetic, context_management edits, memory tool, how to compact well |

## Live Documentation

When cached facts may be stale, WebFetch (append `.md` for clean markdown):

- Models/pricing: `https://platform.claude.com/docs/en/about-claude/models/overview.md`
- Messages API: `https://platform.claude.com/docs/en/api/messages`
- Tool use: `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview.md`
- Prompt caching: `https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md`
- Structured outputs: `https://platform.claude.com/docs/en/build-with-claude/structured-outputs.md`
- Batches: `https://platform.claude.com/docs/en/build-with-claude/batch-processing.md`
- Agent SDK: `https://code.claude.com/docs/en/agent-sdk/overview`
- Context editing: `https://platform.claude.com/docs/en/build-with-claude/context-editing`
- Context engineering: `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
