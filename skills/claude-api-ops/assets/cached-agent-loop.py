#!/usr/bin/env python3
"""A cache-correct agentic loop — the context-engineering doctrine, executable.

assets/agentic-loop.py is the MINIMAL correct loop: it shows stop_reason
handling and nothing else, on purpose. This file is its cache-aware sibling.
Same loop, plus the four things that decide whether a long-running agent costs
0.1x or 1.25x per turn (see SKILL.md "Context Engineering"):

  1. STATIC PREFIX FIRST, VOLATILE LAST. tools -> system -> messages is the
     render order, and the cache is a prefix match. The breakpoint goes at the
     end of the stable part; anything per-request falls after it.
  2. A ROLLING BREAKPOINT on the newest turn, so hits accrue as the
     conversation grows -- and never more than MAX_BREAKPOINTS of them.
  3. AN INTERMEDIATE BREAKPOINT every ~15 blocks. A breakpoint searches
     backward at most 20 content blocks; a turn that appends more than that
     jumps the window and silently misses.
  4. TOOL OUTPUT CAPPED AT THE BOUNDARY. The cheapest context lever there is:
     it shrinks context WITHOUT rewriting the cached prefix, so unlike
     compaction it costs nothing in cache terms.

And the one assertion that matters: cache_read_input_tokens > 0. A broken
cache produces no error, no warning, and no symptom other than the bill --
this loop prints the usage every turn and complains when the cache misses.

Run:  pip install anthropic   (then: export ANTHROPIC_API_KEY=sk-...)
      python cached-agent-loop.py

Copy this file and adapt the >>> ADAPT marks. Cache facts verified against
platform.claude.com 2026-08-30; see references/caching-and-cost.md.
"""
# The Anthropic SDK accepts plain dict literals for tools/messages at runtime
# (as the official docs show), but its strict TypedDict stubs over-narrow them.
# Silence those false positives so this starter stays readable.
# pyright: reportArgumentType=false
import anthropic

client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

MODEL = "claude-opus-4-8"  # >>> ADAPT: pick a tier (see the skill's model table)

# --- Cache tuning knobs (documented values, not guesses) --------------------
MAX_BREAKPOINTS = 4      # hard API limit: 4 cache_control markers per request
LOOKBACK_BLOCKS = 20     # a breakpoint searches back at most 20 content blocks
BREAKPOINT_EVERY = 15    # ...so re-anchor before that window is exhausted
TOOL_RESULT_CAP = 4000   # >>> ADAPT: chars kept per tool result (lever #4)

# The minimum cacheable prefix is MODEL-DEPENDENT (512-4096 tokens). Below it
# the marker is silently ignored -- cache_creation_input_tokens stays 0 and
# there is no error. If your system prompt is small, caching it buys nothing;
# check the per-model table in references/caching-and-cost.md before tuning.


# === 1. THE STATIC PREFIX ====================================================
# Everything here must be byte-identical on every request. The classic silent
# invalidators live in exactly this block: a datetime.now(), a request id, a
# per-user name, a conditionally-appended section, an unsorted json.dumps.
# >>> ADAPT: put your real instructions/docs here. Keep them CONSTANT.
SYSTEM_PROMPT = """You are a careful assistant with tool access.
Prefer calling a tool over guessing. Answer concisely once you have the facts.
""" + ("Reference material the agent needs on most turns goes here. " * 200)

# Tools render at position 0, ahead of system. Changing ANY tool definition
# invalidates the entire cache -- so build this list once, statically. Never
# assemble it per-user or per-request.
TOOLS = [
    {
        "name": "get_weather",  # >>> ADAPT
        "description": "Get current weather for a city. Call when asked about weather.",
        "input_schema": {
            "type": "object",
            "properties": {"location": {"type": "string",
                                        "description": "City, e.g. Paris"}},
            "required": ["location"],
        },
    },
]


def run_tool(name: str, tool_input: dict) -> str:
    """>>> ADAPT: dispatch to your real implementations."""
    if name == "get_weather":
        return f"18C, light rain in {tool_input.get('location', 'unknown')}."
    return f"No such tool: {name}"


def capped(text: str, limit: int = TOOL_RESULT_CAP) -> str:
    """Lever #4 — cap at the TOOL BOUNDARY, before the result enters context.

    This is the important asymmetry: truncating here shortens what gets
    APPENDED, so the cached prefix behind it is untouched. Summarising the same
    content *after* it is already in the history is compaction, and pays a full
    cache write. If the caller may need the full payload, write it to a file
    and return the path instead of truncating (tier 2 -- see
    references/context-engineering.md §5.2).
    """
    if len(text) <= limit:
        return text
    return (text[:limit]
            + f"\n... [truncated {len(text) - limit} chars. "
              f"Re-run with a narrower query, or read the full payload from disk.]")


# === 2/3. BREAKPOINT PLACEMENT ==============================================
def _blocks(message) -> list:
    content = message["content"]
    return content if isinstance(content, list) else []


def place_message_breakpoints(messages: list) -> None:
    """Re-anchor rolling cache breakpoints across the message list, in place.

    Rules encoded here:
      * The newest turn always carries a breakpoint, so the next request can
        read everything up to it (hits accrue as the conversation grows).
      * An extra anchor every BREAKPOINT_EVERY blocks, because the backward
        search stops after LOOKBACK_BLOCKS (20). A tool-heavy turn that appends
        30 blocks would otherwise jump clean over the previous entry.
      * At most MAX_BREAKPOINTS - 1 markers here; the system block owns the
        fourth. Exceeding 4 is an API error, so oldest markers are dropped.
    """
    assert BREAKPOINT_EVERY < LOOKBACK_BLOCKS, "anchor must fall inside the window"

    # Clear existing markers, then re-place: idempotent, so the loop can call
    # this every turn without accumulating stale markers.
    for msg in messages:
        for block in _blocks(msg):
            if isinstance(block, dict):
                block.pop("cache_control", None)

    # Walk the flattened block stream, marking a candidate every N blocks and
    # always marking the final block.
    flat = [(mi, bi) for mi, msg in enumerate(messages)
            for bi, _ in enumerate(_blocks(msg))]
    if not flat:
        return
    candidates = [flat[i] for i in range(BREAKPOINT_EVERY - 1, len(flat), BREAKPOINT_EVERY)]
    if flat[-1] not in candidates:
        candidates.append(flat[-1])

    # Keep the most recent ones; the system breakpoint consumes one of the 4.
    for mi, bi in candidates[-(MAX_BREAKPOINTS - 1):]:
        block = _blocks(messages[mi])[bi]
        if isinstance(block, dict):
            block["cache_control"] = {"type": "ephemeral"}
            # >>> ADAPT: {"type": "ephemeral", "ttl": "1h"} if turns are minutes
            # apart. 1h writes cost 2x vs 1.25x, so it needs 3+ reads to pay off.


def report_usage(usage, turn: int, first_turn: bool) -> None:
    """The only symptom a broken cache produces is in here. Look at it."""
    read = getattr(usage, "cache_read_input_tokens", 0) or 0
    written = getattr(usage, "cache_creation_input_tokens", 0) or 0
    print(f"  [turn {turn}] uncached={usage.input_tokens} "
          f"cache_write={written} cache_read={read} out={usage.output_tokens}")
    if not first_turn and read == 0:
        # Not an exception on purpose: this is a cost bug, not a crash. In CI or
        # staging, promote it -- an assert here catches a stray timestamp in the
        # system prompt before it reaches production.
        print("  WARNING: cache_read_input_tokens == 0 on a repeat request.\n"
              "           The prefix changed. Check for a timestamp/uuid/per-user\n"
              "           value in SYSTEM_PROMPT, a reordered block, an unsorted\n"
              "           json.dumps, a swapped model, or a mutated tool list.\n"
              "           See references/caching-and-cost.md, 'Silent invalidators'.")


def main() -> None:
    # >>> ADAPT: your opening request. Volatile content belongs HERE, after the
    # cached system block -- never interpolated into SYSTEM_PROMPT.
    messages = [{"role": "user",
                 "content": [{"type": "text",
                              "text": "What's the weather in Paris and in Oslo?"}]}]

    for turn in range(1, 21):  # bounded: never ship an unbounded agent loop
        place_message_breakpoints(messages)

        response = client.messages.create(
            model=MODEL,
            max_tokens=4096,
            # The static prefix, with the breakpoint at its end. Tools render
            # ahead of system, so this one marker caches BOTH together.
            system=[{"type": "text", "text": SYSTEM_PROMPT,
                     "cache_control": {"type": "ephemeral"}}],
            tools=TOOLS,
            messages=messages,
        )
        report_usage(response.usage, turn, first_turn=(turn == 1))

        if response.stop_reason != "tool_use":
            for block in response.content:
                if block.type == "text":
                    print(block.text)
            return

        messages.append({"role": "assistant", "content": response.content})

        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            try:
                # block.input is already parsed -- never string-match the raw text.
                output = run_tool(block.name, block.input)
                is_error = False
            except Exception as exc:  # tool failures are data, not crashes
                output, is_error = f"Tool failed: {exc}", True
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,      # one result per tool_use, ids matching
                "content": capped(output),    # <- lever #4, at the boundary
                "is_error": is_error,
            })
        messages.append({"role": "user", "content": tool_results})

    print("Hit the turn ceiling without an end_turn — check the tool loop.")


if __name__ == "__main__":
    main()
