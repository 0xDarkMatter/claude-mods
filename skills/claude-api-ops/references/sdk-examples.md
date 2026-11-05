# SDK Examples

The TypeScript Messages API call, the streaming pattern, and minimal Agent SDK `query()` loops in Python and TypeScript.

## TypeScript call and streaming

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

## Tool definition and loop check

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

## Agent SDK query loops

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
