#!/usr/bin/env python3
"""Minimal, correct tool-use agentic loop on the Anthropic Messages API.

The canonical pattern: define a tool, call messages.create, and keep looping
while stop_reason == "tool_use" — execute each requested tool, append a
tool_result, and re-request until stop_reason == "end_turn".

Run:  pip install anthropic   (then: export ANTHROPIC_API_KEY=sk-...)
      python agentic-loop.py

Copy this file and adapt the >>> ADAPT marks for your own tools.
Reflects the current API (model claude-opus-5, typed content blocks).
"""
# The Anthropic SDK accepts plain dict literals for tools/messages at runtime
# (as the official docs show), but its strict TypedDict stubs over-narrow them.
# Silence those false positives so this starter stays readable; real apps may
# prefer the SDK's typed params (anthropic.types.ToolParam, MessageParam).
# pyright: reportArgumentType=false
import anthropic

client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

MODEL = "claude-opus-5"  # >>> ADAPT: pick a tier (see the skill's model table)


# --- 1. Define your tool(s) ------------------------------------------------
# The input_schema is JSON Schema. Write a description that says WHEN to call.
TOOLS = [
    {
        "name": "get_weather",  # >>> ADAPT
        "description": "Get the current weather for a city. "
                       "Call this whenever the user asks about weather conditions.",
        "input_schema": {
            "type": "object",
            "properties": {
                "location": {"type": "string", "description": "City, e.g. 'Paris'"},
            },
            "required": ["location"],
        },
    }
]


# --- 2. Implement each tool ------------------------------------------------
# Map tool name -> a Python callable. Never trust the arguments blindly: they
# come from the model. Validate before doing anything with side effects.
def get_weather(location: str) -> str:  # >>> ADAPT: real implementation
    return f"It is 21°C and sunny in {location}."


TOOL_IMPLS = {"get_weather": get_weather}


def run_tool(name: str, tool_input: dict) -> str:
    """Dispatch a tool call, returning a string result for the model."""
    impl = TOOL_IMPLS.get(name)
    if impl is None:
        return f"ERROR: unknown tool {name!r}"
    try:
        return impl(**tool_input)
    except Exception as exc:  # surface failures back to the model, don't crash
        return f"ERROR running {name}: {exc}"


# --- 3. The loop -----------------------------------------------------------
def agent(user_prompt: str, max_turns: int = 10) -> str:
    # The conversation is a growing list of message dicts we own and replay.
    messages = [{"role": "user", "content": user_prompt}]

    for _ in range(max_turns):
        response = client.messages.create(
            model=MODEL,
            max_tokens=4096,
            tools=TOOLS,
            messages=messages,
        )

        # Append the assistant turn VERBATIM — content is a list of typed
        # blocks (text and/or tool_use). It must go back as-is next request.
        messages.append({"role": "assistant", "content": response.content})

        # If the model didn't ask for a tool, we're done — return its text.
        if response.stop_reason != "tool_use":
            return "".join(
                block.text for block in response.content if block.type == "text"
            )

        # Otherwise: execute EVERY tool_use block and collect tool_result
        # blocks (the model may request several tools in parallel).
        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue  # skip text/thinking blocks
            result_text = run_tool(block.name, block.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,   # MUST echo the matching id
                "content": result_text,
                # "is_error": True,        # set when the tool failed
            })

        # Feed results back as a single user turn, then loop to re-request.
        messages.append({"role": "user", "content": tool_results})

    return "Stopped: hit max_turns without an end_turn."


if __name__ == "__main__":
    answer = agent("What's the weather in Tokyo right now?")
    print(answer)
    # For debugging, inspect the assembled transcript:
    # print(json.dumps(..., indent=2, default=str))
