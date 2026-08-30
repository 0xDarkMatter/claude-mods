# Caching, Batches & Cost Reference

The three big cost levers, in order of typical impact: model tiering, prompt
caching, Batches API. They stack — a cached Haiku batch request can cost ~2-3%
of an uncached Opus interactive request for the same tokens.

## Prompt Caching

### The one invariant

**Caching is a prefix match.** The cache key is the exact bytes of the
rendered prompt up to each `cache_control` breakpoint. One byte changed
anywhere in the prefix invalidates everything after it. Render order is
`tools` → `system` → `messages` — a breakpoint on the last system block caches
tools + system together.

### Syntax

```python
response = client.messages.create(
    model="claude-opus-5",
    max_tokens=16000,
    system=[{
        "type": "text",
        "text": LARGE_STABLE_PROMPT,                      # 50KB of docs, instructions...
        "cache_control": {"type": "ephemeral"},           # 5-minute TTL (default)
        # "cache_control": {"type": "ephemeral", "ttl": "1h"}  # 1-hour TTL
    }],
    messages=[{"role": "user", "content": question}],
)
```

```typescript
const response = await client.messages.create({
  model: "claude-opus-5",
  max_tokens: 16000,
  system: [{ type: "text", text: LARGE_STABLE_PROMPT,
             cache_control: { type: "ephemeral" } }],
  messages: [{ role: "user", content: question }],
});
```

Simplest option — top-level auto-caching (caches the last cacheable block, no
per-block markers):

```python
client.messages.create(model="claude-opus-5", max_tokens=16000,
                       cache_control={"type": "ephemeral"},
                       system=big_doc, messages=[...])
```

Rules:

- Max **4** `cache_control` breakpoints per request.
- Valid on system text blocks, tool definitions, and message content blocks
  (`text`, `image`, `tool_use`, `tool_result`, `document`).
- **Minimum cacheable prefix is model-dependent** — below it the marker is
  silently ignored (no error, just `cache_creation_input_tokens: 0`):

| Model | Minimum prefix tokens |
|---|---:|
| Opus 4.6 / 4.5, Haiku 4.5 | 4096 |
| Opus 4.7 | 2048 |
| Sonnet 5, Opus 4.8, Sonnet 4.6, Sonnet 4.5 | 1024 |
| Opus 5, Fable 5 | 512 |

Note the shape: the newest models cache *sooner* (512) while Haiku 4.5 — the
cheapest model, and the one you'd most want to cache in bulk — needs the largest
prefix (4096). Sizing a shared prefix for Haiku covers every other model too.

### Pricing & break-even

| Operation | Cost vs base input |
|---|---|
| Cache write, 5-min TTL | 1.25x |
| Cache write, 1-hour TTL | 2x |
| Cache read | ~0.1x |

Break-even: 5-min TTL pays off at the **2nd** request (1.25 + 0.1 = 1.35x vs
2x); 1-hour TTL needs **3+** requests (2 + 0.2 = 2.2x vs 3x). Steady-state
savings on a large cached prefix approach 90%.

### Multi-turn / agent placement

- **Multi-turn:** put the breakpoint on the last content block of the latest
  turn; earlier breakpoints remain valid read points, so hits accrue as the
  conversation grows. Top-level auto-caching does this for you.
- **Shared prefix, varying question:** breakpoint at the end of the *shared*
  part, not the end of the prompt — otherwise every request writes a distinct
  entry and nothing is ever read.
- **20-block lookback:** a breakpoint searches backward at most 20 content
  blocks for a prior entry. Agent turns adding >20 blocks (many
  tool_use/tool_result pairs) silently miss — add an intermediate breakpoint
  every ~15 blocks in long turns.
- **Concurrent fan-out:** an entry becomes readable only once the first
  response starts streaming. Fire 1 request, await first token, then fire the
  other N-1 so they read the fresh cache.

### Silent invalidators (audit checklist)

If `usage.cache_read_input_tokens` stays 0 across identical-prefix requests,
grep the prompt-assembly path for:

| Pattern | Why it kills the cache |
|---|---|
| `datetime.now()` / `Date.now()` in the system prompt | New prefix every request |
| `uuid4()` / request IDs early in content | Same |
| `json.dumps(d)` without `sort_keys=True` | Non-deterministic bytes |
| Per-user IDs interpolated into the system prompt | No cross-user sharing |
| Conditional system sections (`if flag: system += ...`) | Each flag combo = distinct prefix |
| Tool set built per-user / unsorted | Tools render at position 0 — full invalidation |
| Switching models mid-conversation | Caches are model-scoped |

Fix: move volatile content **after** the last breakpoint (or into the latest
user message), serialize deterministically, freeze the system prompt and tool
list.

### Verifying

```python
u = response.usage
print(u.cache_creation_input_tokens)  # written this request (paid 1.25-2x)
print(u.cache_read_input_tokens)      # served from cache (paid ~0.1x)
print(u.input_tokens)                 # uncached remainder (full price)
# total prompt = input + cache_creation + cache_read
```

### What does NOT invalidate

Changing `tool_choice`, toggling thinking, or message content changes leave
the tools+system cache intact. Only tool-definition changes and model switches
force a full rebuild.

## Batches API

`POST /v1/messages/batches` — asynchronous Messages requests at a **flat 50%
discount on all token usage** (stacks with prompt caching).

| Fact | Value |
|---|---|
| Max batch size | 100,000 requests or 256 MB |
| Turnaround | Usually <1 hour; max 24h |
| Results retention | 29 days |
| Feature support | All Messages features (tools, vision, caching, structured outputs, thinking) — no streaming |
| Rate limits | Separate pool from interactive traffic |

```python
import anthropic, time
from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
from anthropic.types.messages.batch_create_params import Request

client = anthropic.Anthropic()

# 1. Create
batch = client.messages.batches.create(requests=[
    Request(custom_id=f"item-{i}",
            params=MessageCreateParamsNonStreaming(
                model="claude-haiku-4-5", max_tokens=64,
                messages=[{"role": "user",
                           "content": f"Classify sentiment (one word): {text}"}]))
    for i, text in enumerate(texts)
])

# 2. Poll
while True:
    batch = client.messages.batches.retrieve(batch.id)
    if batch.processing_status == "ended":
        break
    time.sleep(60)
print(batch.request_counts)  # succeeded / errored / canceled / expired

# 3. Results (order not guaranteed — key on custom_id)
for result in client.messages.batches.results(batch.id):
    if result.result.type == "succeeded":
        msg = result.result.message
        text = next((b.text for b in msg.content if b.type == "text"), "")
    elif result.result.type == "errored":
        # error.type == "invalid_request" → fix and resubmit; otherwise safe to retry
        ...
```

```typescript
const batch = await client.messages.batches.create({
  requests: [{
    custom_id: "request-1",
    params: { model: "claude-sonnet-5", max_tokens: 1024,
              messages: [{ role: "user", content: "Summarize..." }] },
  }],
});
// poll batches.retrieve(batch.id) until processing_status === "ended"
for await (const result of await client.messages.batches.results(batch.id)) {
  if (result.result.type === "succeeded") { /* result.result.message */ }
}
```

Batch gotchas:

- `custom_id` is your only join key — results stream in completion order, not
  submission order.
- Result types: `succeeded` | `errored` | `canceled` | `expired`. Resubmit
  `expired`; inspect `errored` (validation vs server error).
- Cancel is async: `batches.cancel(id)` → status `"canceling"`; some requests
  may still complete.
- Caching inside batches works, but hit rates are best-effort (requests run
  concurrently) — put a shared cached `system` block on every request and use
  the 1-hour TTL.
- Per-request params are full `MessageCreateParams` minus `stream`.

Use batches for: eval suites, backfills, bulk extraction/classification,
nightly report generation, regenerating embeddings-adjacent metadata — any
workload where minutes-to-hours latency is fine.

## Model Tiering Economics

Worked example, 10M input + 1M output tokens/day:

| Strategy | Cost/day |
|---|---|
| Everything Opus 5 | 10×$5 + 1×$25 = **$75** |
| Everything Sonnet 5 | 10×$2 + 1×$10 = **$30** |
| Route: 80% Haiku, 15% Sonnet, 5% Opus | input 8×$1 + 1.5×$2 + 0.5×$5 = $13.5; output 0.8×$5 + 0.15×$10 + 0.05×$25 = $6.75 = **~$20** |
| Same + cached system prompts (70% of input cached at ~0.1x) | input → ~$5 = **~$12** |
| Same + batchable share moved to Batches | **lower still (50% off that share)** |

Patterns:

- **Router**: a Haiku call classifies difficulty, dispatches to the right model.
- **Cascade**: try Haiku; escalate to Sonnet/Opus only when confidence is low
  or validation fails (works well with structured outputs as the validator).
- **Subagents**: keep the orchestrator on Opus, push parallel/simple legs to
  Haiku/Sonnet. Spawn a separate request per subagent (don't switch models
  mid-conversation — it kills the cache).
- **Effort tuning**: on supported models, dropping `output_config.effort` from
  `high` to `medium` often cuts output tokens substantially at minor quality
  cost — cheaper than switching model tier for borderline workloads.

## Token Counting for Cost Estimation

```python
count = client.messages.count_tokens(
    model="claude-opus-5", system=system, tools=tools, messages=messages)
est_input_cost = count.input_tokens * 5.00 / 1_000_000   # Opus 5 input rate
```

- Free endpoint; counts include tools and system.
- Tool use adds a hidden system prompt (~290-800 tokens depending on model and
  `tool_choice`).
- Token counts are model-specific — re-baseline when migrating models; don't
  apply blanket multipliers.
