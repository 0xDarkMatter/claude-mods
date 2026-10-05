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

TypeScript and streaming versions: [references/sdk-examples.md](references/sdk-examples.md). Stream long outputs; non-streaming above ~16K `max_tokens` risks SDK HTTP timeouts.

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

Tool definition shape (`name`, `description`, JSON Schema `input_schema`) and the `stop_reason` check that drives the loop: [references/sdk-examples.md](references/sdk-examples.md).

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

**Compact only as a deliberate response to a named constraint** (context, cost or latency ceiling): under caching, appending usually wins, and capping tool output at the tool boundary is the underrated lever. Keep the static prefix first; reordering breaks the cache silently. First-party clearing: `context_management` (beta `context-management-2025-06-27`), always with `clear_at_least`.

One-page version (tiers, cache-aware order, compaction table, agentic specifics): [references/context-engineering-quickref.md](references/context-engineering-quickref.md). Full doctrine: [references/context-engineering.md](references/context-engineering.md). Compaction economics and `context_management`: [references/compaction.md](references/compaction.md).

## Claude Agent SDK (quick reference)

Minimal `query()` loops in Python (`pip install claude-agent-sdk`, Python >= 3.10) and TypeScript (`npm install @anthropic-ai/claude-agent-sdk`): [references/sdk-examples.md](references/sdk-examples.md).

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
| Compacting by reflex on a long conversation | Higher cost, worse recall than doing nothing | Name the constraint first; under caching, appending usually wins (see Context Engineering) |
| `clear_tool_uses` without `clear_at_least` | A full cache re-write to reclaim a few hundred tokens | Set `clear_at_least` so each cache break is worth taking |

## Resources & Verification

Worked invocations and caveats for each: [references/resources.md](references/resources.md).

- `scripts/check-model-table.py`: staleness verifier for the model table, cache constants and citations (`--offline`; `--live` needs a key).
- `scripts/context-budget.py`: append-vs-compact cost calculator (exit 10 = compacting is cheaper).
- `assets/cached-agent-loop.py`: cache-aware loop for long-running agents.
- `assets/recall-probe.py`: append vs compact recall, cost and TTFT harness (real API calls).
- `assets/agentic-loop.py`: minimal tool-use loop to copy.
- `assets/output-schema.json`: known-good `output_config.format` request body.

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
| [references/context-engineering-quickref.md](references/context-engineering-quickref.md) | One-page context engineering: three tiers, cache-aware order, the compaction decision table, agentic specifics |
| [references/resources.md](references/resources.md) | The shipped verifier, calculator and assets with worked invocations; the full live-docs list |
| [references/sdk-examples.md](references/sdk-examples.md) | TypeScript Messages API call, streaming, Agent SDK `query()` loops (Python + TS) |

## Live Documentation

When cached facts may be stale, WebFetch (append `.md` for clean markdown):

- Models/pricing: `https://platform.claude.com/docs/en/about-claude/models/overview.md`
- Messages API, tool use, caching, structured outputs, batches, Agent SDK, context editing and engineering: [references/resources.md](references/resources.md)
