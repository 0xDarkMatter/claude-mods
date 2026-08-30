# Messages API Reference

`POST https://api.anthropic.com/v1/messages` — the single endpoint everything
runs through. Tools, structured outputs, thinking, and caching are all features
of this endpoint, not separate APIs.

## Required Headers

| Header | Value |
|---|---|
| `x-api-key` | Your API key (`sk-ant-...`) |
| `anthropic-version` | `2023-06-01` |
| `content-type` | `application/json` |
| `anthropic-beta` | Comma-separated beta IDs, only for beta features |

OAuth bearer tokens go on `Authorization: Bearer <token>` instead of
`x-api-key` (plus `anthropic-beta: oauth-2025-04-20`). Setting both
`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` makes the SDK send both headers
and the API rejects the request.

## Request Parameters

| Param | Type | Required | Notes |
|---|---|---|---|
| `model` | string | yes | Exact alias ID, e.g. `claude-opus-5` — no date suffixes |
| `max_tokens` | int | yes | Hard output cap. Default sensibly: ~16000 non-streaming, ~64000 streaming, ~256 classification |
| `messages` | array | yes | Alternating `user`/`assistant` turns; first must be `user`. Consecutive same-role messages are merged |
| `system` | string \| block[] | no | System prompt. Block-list form required for `cache_control` |
| `tools` | array | no | Custom + server tool definitions (see tool-use.md) |
| `tool_choice` | object | no | `auto` (default) / `any` / `tool` / `none` |
| `thinking` | object | no | Adaptive; **on by default** on Fable 5 / Opus 5 / Sonnet 5. `{"type": "enabled", "budget_tokens": N}` 400s on Opus 4.7+ |
| `output_config` | object | no | `{"effort": "...", "format": {...}, "task_budget": {...}}` |
| `stop_sequences` | string[] | no | Custom stop strings |
| `stream` | bool | no | SSE streaming |
| `metadata` | object | no | `{"user_id": "..."}` — opaque end-user id for abuse detection |
| `temperature` / `top_p` / `top_k` | number | no | **Removed on Opus 4.7 and later (400)** — Opus 5, Sonnet 5, Fable 5 included. On earlier 4.x: at most one of temperature/top_p |
| `cache_control` | object | no | Top-level auto-caching: caches the last cacheable block |
| `container` | string | no | Reuse a code-execution container id |
| `mcp_servers` | array | no | Remote MCP connector (beta `mcp-client-2025-11-20`) |

### Message content blocks

`content` is either a plain string or an array of blocks:

```json
{"role": "user", "content": [
  {"type": "text", "text": "What's in this image?"},
  {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<b64>"}},
  {"type": "image", "source": {"type": "url", "url": "https://example.com/img.png"}},
  {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": "<b64>"}},
  {"type": "tool_result", "tool_use_id": "toolu_...", "content": "..."}
]}
```

## Response Shape

```json
{
  "id": "msg_01...",
  "type": "message",
  "role": "assistant",
  "model": "claude-opus-5",
  "content": [
    {"type": "thinking", "thinking": "...", "signature": "..."},
    {"type": "text", "text": "Hello!"},
    {"type": "tool_use", "id": "toolu_01...", "name": "get_weather", "input": {"location": "Paris"}}
  ],
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 1024,
    "output_tokens": 256,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0
  }
}
```

`content` is a **list of typed blocks** — never index `content[0].text` blindly
(a `thinking` block may come first). Filter by `.type`.

## Stop Reasons

| `stop_reason` | Meaning | What to do |
|---|---|---|
| `end_turn` | Finished naturally | Done |
| `max_tokens` | Hit the `max_tokens` cap | Raise the cap or stream; output may be truncated mid-thought |
| `stop_sequence` | Hit a custom stop string | `stop_sequence` field has which one |
| `tool_use` | Claude wants tool(s) executed | Execute each `tool_use` block, send `tool_result`(s), re-request |
| `pause_turn` | Server-side tool loop hit its iteration limit | Append the assistant turn and re-send unchanged — server resumes; do NOT add a "continue" user message |
| `refusal` | Safety refusal | Check `stop_details` (`category`: "cyber"/"bio"/"reasoning_extraction" (Fable 5)/null, `explanation`); don't retry same prompt |
| `model_context_window_exceeded` | Context window exhausted (distinct from max_tokens) | Compact, truncate, or split the conversation |

```python
if response.stop_reason == "refusal" and response.stop_details:
    print(response.stop_details.category, response.stop_details.explanation)
```

## Multi-Turn Conversations

The API is stateless — send the full history every request:

```python
messages = []
def chat(user_msg: str) -> str:
    messages.append({"role": "user", "content": user_msg})
    r = client.messages.create(model="claude-opus-5", max_tokens=16000, messages=messages)
    # Append the FULL content list (preserves tool_use/thinking/compaction blocks)
    messages.append({"role": "assistant", "content": r.content})
    return next(b.text for b in r.content if b.type == "text")
```

For conversations that may exceed context: server-side **compaction** (beta
header `compact-2026-01-12`, `context_management: {"edits": [{"type":
"compact_20260112"}]}` on `client.beta.messages.create`). Critical: append
`response.content` back verbatim — compaction blocks must be preserved or
state is silently lost.

## Streaming

```python
with client.messages.stream(model="claude-opus-5", max_tokens=64000,
                            messages=[...]) as stream:
    for text in stream.text_stream:
        print(text, end="", flush=True)
    final = stream.get_final_message()
print(final.usage.output_tokens)
```

```typescript
const stream = client.messages.stream({ model: "claude-opus-5", max_tokens: 64000, messages });
stream.on("text", (delta) => process.stdout.write(delta));
const final = await stream.finalMessage();   // never wrap .on() in new Promise()
```

### SSE event sequence

```
message_start          → message metadata (id, model, usage so far)
content_block_start    → index + block type (text / thinking / tool_use)
content_block_delta    → text_delta | thinking_delta | input_json_delta
content_block_stop     → block finished
message_delta          → stop_reason + final usage
message_stop           → stream done
```

Tool inputs stream as `input_json_delta` (partial JSON strings) — accumulate
and parse at `content_block_stop`, or just use `get_final_message()` /
`finalMessage()` which assembles parsed blocks for you.

**Why stream:** non-streaming requests with large `max_tokens` exceed HTTP
timeouts (the Python SDK raises `ValueError` for non-streaming requests it
estimates will run >~10 min). Default to streaming for anything long.

## Error Handling

| HTTP | `error.type` | Retryable | Typical cause |
|---|---|---|---|
| 400 | `invalid_request_error` | no | Bad params: removed sampling params, `budget_tokens` on 4.7+, prefill on 4.7+, modified thinking blocks, role ordering |
| 401 | `authentication_error` | no | Missing/invalid key; both key + token set |
| 403 | `permission_error` | no | Key lacks model/feature access |
| 404 | `not_found_error` | no | Bad model ID (date-suffix mistake) or endpoint |
| 413 | `request_too_large` | no | Body over size limit — shrink images/history |
| 429 | `rate_limit_error` | yes | RPM/ITPM/OTPM exceeded — honor `retry-after` |
| 500 | `api_error` | yes | Transient server issue |
| 529 | `overloaded_error` | yes | Capacity — backoff; consider another model |

Error envelope:

```json
{"type": "error",
 "error": {"type": "rate_limit_error", "message": "..."},
 "request_id": "req_011CSH..."}
```

Log `request_id` (also `response._request_id` on SDK success objects) when
reporting issues to Anthropic.

### Typed exceptions — never string-match messages

```python
import anthropic
try:
    r = client.messages.create(...)
except anthropic.BadRequestError as e:      # 400
    raise                                    # don't retry client errors
except anthropic.RateLimitError as e:       # 429
    wait = int(e.response.headers.get("retry-after", "60"))
except anthropic.APIStatusError as e:        # catch-all with .status_code / .type
    if e.status_code >= 500: ...             # retryable
except anthropic.APIConnectionError:
    ...                                      # network — retryable
```

```typescript
try {
  await client.messages.create({...});
} catch (err) {
  if (err instanceof Anthropic.RateLimitError) { /* backoff */ }
  else if (err instanceof Anthropic.APIError) { console.error(err.status, err.message); }
}
```

All subclasses expose `.type` (e.g. `"overloaded_error"`) for finer
classification than the status code (e.g. `billing_error` vs
`permission_error`, both 403).

### Retries

The official SDKs **auto-retry** connection errors, 408/409/429 and >=500 with
exponential backoff — default `max_retries=2`. Configure per client
(`anthropic.Anthropic(max_retries=5)`) or per call
(`client.with_options(max_retries=5, timeout=20.0).messages.create(...)`).
Only hand-roll retry logic when you need behavior beyond that (e.g. queue +
jitter across many workers):

```python
import random, time

def call_with_retry(client, max_retries=5, base=1.0, cap=60.0, **kwargs):
    last = None
    for attempt in range(max_retries):
        try:
            return client.messages.create(**kwargs)
        except anthropic.RateLimitError as e:
            last = e
        except anthropic.APIStatusError as e:
            if e.status_code < 500:
                raise          # 4xx (except 429) is not retryable
            last = e
        time.sleep(min(base * 2 ** attempt + random.random(), cap))
    raise last
```

Default request timeout is 10 minutes (`timeout=` on the client or
`with_options`). On timeout: `anthropic.APITimeoutError`, retried per
`max_retries`.

## Rate Limits

Limits are per-organization, per-model-class, measured three ways:

- **RPM** — requests per minute
- **ITPM** — input tokens per minute (cache reads often discounted/exempt — check headers)
- **OTPM** — output tokens per minute

Tiers scale with cumulative spend (Tier 1-4, then custom/scale). Check live
limits in Console or response headers:

| Header | Meaning |
|---|---|
| `retry-after` | Seconds to wait (on 429) |
| `anthropic-ratelimit-requests-limit` / `-remaining` / `-reset` | RPM state |
| `anthropic-ratelimit-input-tokens-*` / `-output-tokens-*` | ITPM / OTPM state |

Practical guidance:

- Treat 429 as backpressure: honor `retry-after`, add jitter, cap concurrency.
- Long-running agent fleets: budget OTPM, not just RPM — output is usually the
  binding constraint.
- Batches API has separate, much higher throughput and doesn't draw from
  interactive rate limits — move bulk traffic there.
- 529 `overloaded_error` is capacity, not your quota — backoff and/or fail over
  to a different model tier.

## Token Counting

`POST /v1/messages/count_tokens` — free, model-specific, counts a request
without running it:

```python
n = client.messages.count_tokens(
    model="claude-opus-5",
    system=system, tools=tools,
    messages=[{"role": "user", "content": text}],
).input_tokens
```

Never estimate with `tiktoken` (OpenAI tokenizer; 15-20% undercount on prose,
worse on code). Token counts differ **between Claude models** too — count
against the model you'll run.

## Vision & Documents

- Images: `{"type": "image", "source": {...}}` blocks — base64, URL, or Files
  API `{"type": "file", "file_id": ...}`. Opus 4.7+ supports high-res input
  (up to 2576px long edge, pixel-accurate coordinates; up to ~3x image tokens).
- PDFs: `{"type": "document", "source": {...}}` — base64, URL, plain text, or
  file_id. Optional `citations: {"enabled": true}`.
- Files API (beta `files-api-2025-04-14`): upload once
  (`client.beta.files.upload(...)`), reference by `file_id` across requests.
  500 MB/file, 100 GB/org.
