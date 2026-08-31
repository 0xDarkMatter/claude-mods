#!/usr/bin/env python3
"""Measure what compaction actually costs you — on YOUR workload.

references/compaction.md says the keep-everything baseline is far stronger
than teams assume, and that you should verify that on your own traffic before
compacting. This is the harness for doing so. It is the published methodology,
runnable: plant a fact, bury it under N turns, probe for it, and compare
strategies on the three axes people reach for compaction to improve.

  plant (turn 0)  ->  N filler turns  ->  probe ("what was the code?")
                                          |
                        recall hit/miss + $ per turn + time to first token

Strategies compared out of the box:
  append   keep the full history every turn (the baseline)
  compact  summarise everything older than --keep-recent turns, then continue
           from the summary (what most agent frameworks do by default)

The point is NOT to reproduce a published number. It is to find out whether
YOUR workload behaves like the studied one, because the answer decides whether
compaction is buying you anything. A strategy that wins on cost and loses on
recall has not won.

Run:  pip install anthropic   (then: export ANTHROPIC_API_KEY=sk-...)
      python recall-probe.py --turns 10 --trials 3

Costs real money — it makes (turns + 2) x trials x strategies API calls.
Start with --turns 6 --trials 1 on a cheap model to sanity-check the wiring.

>>> ADAPT: replace FILLER_TURNS with real turns from your own application.
Synthetic filler is the weakest part of any harness like this — a planted fact
survives generic chit-chat far more easily than it survives your actual
tool-heavy traffic, so results on the shipped filler will flatter both
strategies.
"""
# pyright: reportArgumentType=false
import argparse
import statistics
import sys
import time

import anthropic

client = anthropic.Anthropic()

MODEL = "claude-haiku-4-5"  # >>> ADAPT: probe on the tier you actually ship

SYSTEM_PROMPT = ("You are a helpful assistant. Answer concisely. "
                 "When asked to recall a specific detail from earlier in the "
                 "conversation, quote it exactly.")

# >>> ADAPT: the fact to plant. Make it arbitrary and unguessable, so a correct
# answer proves recall rather than a plausible reconstruction from priors.
SECRET_LABEL = "deployment code"
SECRET_VALUE = "TANGERINE-4471-QUAY"

PLANT = (f"Before we start: the {SECRET_LABEL} for this session is "
         f"{SECRET_VALUE}. Acknowledge it and we'll move on.")
PROBE = f"What was the {SECRET_LABEL} I gave you at the start? Answer with just the code."

# >>> ADAPT: replace with turns sampled from your own logs.
FILLER_TURNS = [
    "Explain the difference between a process and a thread.",
    "Now give me a short example of a race condition.",
    "How would you fix it with a mutex?",
    "What's the tradeoff versus a lock-free queue?",
    "Summarise when I should prefer each.",
    "What about async I/O — where does that fit?",
    "Give me a rule of thumb for choosing a concurrency model.",
    "What metrics would tell me I chose wrong?",
    "How would I load-test that?",
    "What's a common mistake teams make here?",
]

COMPACT_INSTRUCTION = (
    # Per Anthropic's guidance: maximise RECALL first, then tune precision. A
    # compaction prompt written for brevity silently drops the one detail the
    # next 40 turns needed -- which is precisely what this harness measures.
    "Summarise the conversation so far. Preserve every concrete detail, "
    "identifier, number, name and code mentioned — completeness matters more "
    "than brevity. Write it as notes for someone continuing the conversation."
)


def send(messages, cache=True):
    """One request. Returns (text, usage, time_to_first_token_seconds)."""
    system = [{"type": "text", "text": SYSTEM_PROMPT}]
    if cache:
        # Cache the static prefix -- otherwise 'append' is measured without the
        # very mechanism that makes it competitive, and the comparison is rigged.
        system[0]["cache_control"] = {"type": "ephemeral"}
    start = time.perf_counter()
    ttft = None
    chunks = []
    with client.messages.stream(model=MODEL, max_tokens=1024,
                                system=system, messages=messages) as stream:
        for text in stream.text_stream:
            if ttft is None:
                ttft = time.perf_counter() - start
            chunks.append(text)
        final = stream.get_final_message()
    return "".join(chunks), final.usage, (ttft if ttft is not None else 0.0)


def cost_usd(usage, in_rate: float, out_rate: float) -> float:
    """Bill the three input buckets at their real multipliers, plus output."""
    read = getattr(usage, "cache_read_input_tokens", 0) or 0
    write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    return (usage.input_tokens * in_rate
            + write * in_rate * 1.25      # 5-minute-TTL cache write
            + read * in_rate * 0.10       # cache read, flat across models
            + usage.output_tokens * out_rate) / 1_000_000


def run_trial(strategy: str, turns: int, keep_recent: int,
              in_rate: float, out_rate: float, compact_every: int) -> dict:
    messages = [{"role": "user", "content": PLANT}]
    total_cost, ttfts, compactions = 0.0, [], 0
    turns_since_compaction = 0

    text, usage, ttft = send(messages)
    total_cost += cost_usd(usage, in_rate, out_rate)
    ttfts.append(ttft)
    messages.append({"role": "assistant", "content": text})

    for i in range(turns):
        messages.append({"role": "user", "content": FILLER_TURNS[i % len(FILLER_TURNS)]})
        text, usage, ttft = send(messages)
        total_cost += cost_usd(usage, in_rate, out_rate)
        ttfts.append(ttft)
        messages.append({"role": "assistant", "content": text})

        turns_since_compaction += 1
        if (strategy == "compact"
                and turns_since_compaction >= compact_every
                and len(messages) > 2 * keep_recent + 1):
            # Summarise everything except the most recent keep_recent exchanges,
            # then continue from the summary. This is the default behaviour of
            # most agent frameworks -- and the thing under test.
            #
            # FAIRNESS, and the reason for the cadence: an earlier version of
            # this harness compacted on EVERY turn once the history exceeded
            # keep_recent, so the compact arm paid a summarisation call per turn
            # (21 API calls against append's 12, over 10 turns). That inflates
            # the arm under test and would "confirm" the keep-everything result
            # regardless of what the data said. Real systems trigger on a token
            # threshold (context_management's `trigger`); a turn cadence is the
            # closest honest approximation without burning a count_tokens call
            # every turn.
            head, tail = messages[:-2 * keep_recent], messages[-2 * keep_recent:]
            summary_text, usage, _ = send(
                head + [{"role": "user", "content": COMPACT_INSTRUCTION}])
            total_cost += cost_usd(usage, in_rate, out_rate)
            messages = ([{"role": "user",
                          "content": f"[Summary of earlier conversation]\n{summary_text}"},
                         {"role": "assistant", "content": "Understood, continuing."}]
                        + tail)
            compactions += 1
            turns_since_compaction = 0

    messages.append({"role": "user", "content": PROBE})
    answer, usage, ttft = send(messages)
    total_cost += cost_usd(usage, in_rate, out_rate)
    ttfts.append(ttft)

    # Normalised substring match. Deliberately generous: a strategy that cannot
    # pass THIS has lost the fact outright, not merely paraphrased it.
    recalled = SECRET_VALUE.lower() in answer.lower()
    return {"recalled": recalled, "cost": total_cost, "compactions": compactions,
            "ttft": statistics.mean(ttfts), "answer": answer.strip()[:120]}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Plant-a-fact recall probe: append vs compact, on your workload.")
    ap.add_argument("--turns", type=int, default=10, help="filler turns before the probe")
    ap.add_argument("--trials", type=int, default=3, help="repeats per strategy")
    ap.add_argument("--keep-recent", type=int, default=2,
                    help="exchanges kept verbatim by the compact strategy")
    ap.add_argument("--compact-every", type=int, default=5,
                    help="turns between compactions (default: 5). Setting this "
                         "to 1 compacts every turn, which inflates the compact "
                         "arm and rigs the result toward keep-everything - only "
                         "do it if you are deliberately modelling that.")
    ap.add_argument("--in-rate", type=float, default=1.00, help="input $/MTok")
    ap.add_argument("--out-rate", type=float, default=5.00, help="output $/MTok")
    args = ap.parse_args()

    print(f"model={MODEL} turns={args.turns} trials={args.trials} compact_every={args.compact_every}\n")
    for strategy in ("append", "compact"):
        results = [run_trial(strategy, args.turns, args.keep_recent,
                             args.in_rate, args.out_rate, args.compact_every)
                   for _ in range(args.trials)]
        hits = sum(r["recalled"] for r in results)
        per_turn = statistics.mean(r["cost"] for r in results) / (args.turns + 2)
        print(f"{strategy:8s} recall {hits}/{args.trials}  "
              f"${per_turn:.5f}/turn  "
              f"ttft {statistics.mean(r['ttft'] for r in results):.2f}s  "
              f"compactions {statistics.mean(r['compactions'] for r in results):.1f}")
        for r in results:
            if not r["recalled"]:
                print(f"           miss -> {r['answer']!r}")

    print("\nIf append wins on all three, compaction is costing you twice. If "
          "compact wins on cost alone, price the recall loss before adopting it.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
