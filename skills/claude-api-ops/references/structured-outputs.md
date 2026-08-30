# Structured Outputs Reference

Two related features, same constrained-sampling mechanism:

| Feature | Parameter | Constrains |
|---|---|---|
| **JSON outputs** | `output_config: {"format": {...}}` | Claude's response text (guaranteed valid JSON matching your schema) |
| **Strict tool use** | `strict: true` on a tool definition | The `input` of tool calls |

They can be combined in one request. Supported on Fable 5, Opus 5, Sonnet 5, and
the legacy Opus 4.8/4.7/4.6/4.5 and Sonnet 4.6/4.5 line; Haiku 4.5 needs its dated
id (`claude-haiku-4-5-20251001`). Where a model lacks support, enforce output shape
via system-prompt instructions (the documented prefill replacement for that
model) or strict tool use instead.

**Naming:** the canonical parameter is `output_config.format`. The older
top-level `output_format` parameter (and the `structured-outputs-2025-11-13`
beta header) is **deprecated** — still accepted during a transition window,
and still used as a convenience kwarg by some SDK `parse()` methods, but write
new code against `output_config`.

## JSON Outputs — raw schema

```python
import json, anthropic

client = anthropic.Anthropic()
response = client.messages.create(
    model="claude-opus-5",
    max_tokens=16000,
    messages=[{"role": "user",
               "content": "Extract: John Smith (john@example.com) wants the Enterprise plan."}],
    output_config={
        "format": {
            "type": "json_schema",
            "schema": {
                "type": "object",
                "properties": {
                    "name":  {"type": "string"},
                    "email": {"type": "string", "format": "email"},
                    "plan":  {"type": "string", "enum": ["Free", "Pro", "Enterprise"]},
                },
                "required": ["name", "email", "plan"],
                "additionalProperties": False,
            },
        }
    },
)
text = next(b.text for b in response.content if b.type == "text")
data = json.loads(text)   # guaranteed valid against the schema (unless refusal/max_tokens)
```

cURL shape:

```json
{
  "model": "claude-opus-5",
  "max_tokens": 1024,
  "output_config": {
    "format": {"type": "json_schema", "schema": { ... }}
  },
  "messages": [{"role": "user", "content": "..."}]
}
```

## SDK helpers — `parse()` (recommended)

```python
from pydantic import BaseModel

class ContactInfo(BaseModel):
    name: str
    email: str
    plan: str
    demo_requested: bool

response = client.messages.parse(
    model="claude-opus-5",
    max_tokens=16000,
    messages=[{"role": "user", "content": "Extract: Jane Doe (jane@co.com), Enterprise, wants a demo."}],
    output_format=ContactInfo,          # parse() convenience kwarg
)
contact = response.parsed_output        # validated ContactInfo instance
```

```typescript
import { z } from "zod";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";

const ContactInfo = z.object({
  name: z.string(),
  email: z.string(),
  plan: z.string(),
  demo_requested: z.boolean(),
});

const response = await client.messages.parse({
  model: "claude-opus-5",
  max_tokens: 16000,
  output_config: { format: zodOutputFormat(ContactInfo) },
  messages: [{ role: "user", content: "Extract: ..." }],
});
console.log(response.parsed_output!.name);  // null if parsing failed — guard it
```

The SDKs strip unsupported schema constraints (e.g. `minLength`) before
sending and validate them client-side instead.

## Strict Tool Use

```python
tools = [{
    "name": "book_flight",
    "description": "Book a flight",
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "destination": {"type": "string"},
            "date":        {"type": "string", "format": "date"},
            "passengers":  {"type": "integer", "enum": [1, 2, 3, 4, 5, 6, 7, 8]},
        },
        "required": ["destination", "date", "passengers"],
        "additionalProperties": False,
    },
}]
```

- Per-tool opt-in; non-strict tools don't count toward complexity limits.
- Max **20 strict tools** per request.
- Guarantees the `tool_use.input` validates exactly — no missing required
  fields, no type drift.

## JSON Schema: supported vs not

**Supported:** object/array/string/integer/number/boolean/null; `enum`
(scalars only); `const`; `anyOf`/`allOf` (no `allOf` + `$ref` combo); internal
`$ref`/`$defs`; `default`; `required`; `additionalProperties: false`
(mandatory on every object); string `format` (`date-time`, `time`, `date`,
`duration`, `email`, `hostname`, `uri`, `ipv4`, `ipv6`, `uuid`); array
`minItems` 0 or 1 only; simple regex `pattern`.

**Not supported:** recursive schemas; external `$ref`; numeric constraints
(`minimum`/`maximum`/`multipleOf`); string length constraints
(`minLength`/`maxLength`); array constraints beyond `minItems` 0/1;
regex backreferences, lookahead/lookbehind, `\b`; `additionalProperties`
anything but `false`.

**Complexity limits:** 20 strict tools; 24 optional parameters total across
all schemas; 16 union-typed (`anyOf`) parameters; grammar compilation timeout
180s ("Schema is too complex"). Reduce by flattening nesting, making params
required, splitting across requests.

## Operational notes

- **First-request latency:** new schemas compile a grammar on first use;
  cached for 24h (keyed on schema + tool set; name/description changes don't
  invalidate).
- **Prompt cache interplay:** changing `output_config.format` invalidates the
  prompt cache; the feature also injects an extra system prompt (more input
  tokens).
- **Failure modes:** `stop_reason: "refusal"` → output may not match the
  schema; `stop_reason: "max_tokens"` → JSON may be truncated/incomplete —
  raise `max_tokens` and check before parsing.
- **Incompatible with:** citations (400) and assistant-message prefilling.
  **Works with:** batches, streaming, token counting, extended/adaptive
  thinking.
- Don't put PHI/PII in schema property names, enum values, or patterns —
  schemas are cached separately from ZDR-handled message content.

## Structured outputs vs tool-use extraction

Before structured outputs existed, the standard extraction trick was a forced
tool call (`tool_choice: {"type": "tool", "name": "record_result"}`) with the
target shape as `input_schema`. Decision now:

| Want | Use |
|---|---|
| The *final answer* as guaranteed JSON | `output_config.format` |
| Valid *parameters* for a real action/function | tool + `strict: true` |
| Extraction **while thinking is enabled** | `output_config.format` — forced `tool_choice` is a 400 with thinking on |
| Extraction mid-agentic-loop (model also has other tools) | A strict "report/record" tool keeps the loop uniform |
| Legacy prefill (`{"name": "` assistant prefill) | Dead on Opus 4.7+ models (400) — migrate to `output_config.format` |

## Thinking interplay

- `output_config.format` **works with adaptive/extended thinking** — the model
  thinks, then the final text block conforms to the schema.
- Forced tool extraction does **not** work with thinking
  (`tool_choice: any/tool` + thinking = 400). This is the main reason to
  prefer `output_config.format` for extraction on current models.
- Effort and format coexist in `output_config`:
  `output_config={"effort": "medium", "format": {...}}`.
