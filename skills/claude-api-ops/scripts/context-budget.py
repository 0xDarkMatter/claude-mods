#!/usr/bin/env python3
"""Append-vs-compact calculator for a cached multi-turn Claude conversation.

Answers the one question the context-engineering doctrine says to ask before
compacting: over the turns you actually have left, is rewriting the history
cheaper than carrying it? Under prompt caching the answer is usually no, and
the arithmetic is short enough that people skip it and guess wrong.

Models both paths in dollars (see references/compaction.md §3):
  append  : history rides the cache at CACHE_READ_MULTIPLIER of base input,
            every remaining turn, growing by --growth-per-turn.
  compact : summarisation call(s) (cached read in, summary out) + a cache
            WRITE of the new prefix each time + the remaining turns on the
            summary, and every token cached before a rewrite is forfeited.

            Compaction RECURS when the history grows. With --growth-per-turn
            set, the summary climbs back toward the original size and a real
            system compacts again; this models that cadence rather than
            charging a single one-shot rewrite. Assuming one compaction
            understated its cost by ~2.2x on a 60-turn, 4k-per-turn session.

Also checks the hard constraint first: if the projected history overflows the
context window, cost is moot and compaction (or offloading) is forced.

Two things to understand before trusting the verdict:

  * The break-even turn count is SCALE-INVARIANT. History size and price both
    cancel out of fixed_cost / per_turn_saving -- it is driven only by the
    summary ratio, the output/input price ratio, and the write multiplier. So
    "compact" vs "append" is almost entirely a question of how many turns you
    have left, not how big or expensive the conversation is.
  * RECALL IS NOT PRICED. This models dollars only, which is one of the three
    constraints in references/compaction.md. The measured recall cost of
    summarisation (92-100% -> 38-58% on a planted-fact probe) does not appear
    anywhere in these numbers. A "compact" verdict means compaction is cheaper,
    NOT that it is right. Probe your own recall before acting on it --
    assets/recall-probe.py does exactly that.

Usage:   context-budget.py --history-tokens N --turns-remaining N [OPTIONS]
Input:   argv only; no stdin, no network, no files read or written.
Output:  stdout = data only (JSON envelope under --json, else a plain summary)
Stderr:  headers, workings, notes
Exit:    0 append wins (keep everything), 2 usage, 4 validation (bad numbers),
         10 compaction indicated (cost crossover or context ceiling)

Examples:
  # Short session -> append wins (exit 0)
  context-budget.py --history-tokens 25000 --turns-remaining 5 --base-rate 0.30

  # 40 turns left on a 120K history -> cost favours compaction (exit 10)
  context-budget.py --history-tokens 120000 --turns-remaining 40 --base-rate 2.00

  # Premium tier, long session, history still growing each turn
  context-budget.py --history-tokens 300000 --turns-remaining 60 \
      --base-rate 10.00 --growth-per-turn 4000 --ttl 1h

  # Machine-readable, for an agent deciding mid-run
  context-budget.py --history-tokens 900000 --turns-remaining 10 \
      --base-rate 5.00 --json | python -m json.tool
"""
from __future__ import annotations

import argparse
import json
import os
import sys

# Windows consoles default to cp1252; force UTF-8 so the section glyphs in the
# human framing don't raise UnicodeEncodeError (matches check-model-table.py).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass


class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (term.sh is bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline with matching keys/glyphs).
    Honors FORCE_COLOR / NO_COLOR / TERM_ASCII; color tracks the bound stream's TTY,
    and glyphs fall back to ASCII on TERM_ASCII or a non-UTF stream encoding."""

    _C = {"green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
          "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (os.environ.get("TERM_ASCII") == "1"
                      or os.environ.get("FLEET_ASCII") == "1" or "utf" not in enc)
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, state):
        return self.c(self._MARK_COLOR.get(state, ""),
                      (self._ASCII if self.ascii else self._GLYPH).get(state, "."))

    def hdr(self, text):
        return self.c("cyan", f"=== {text} ===")


TERM = Term(sys.stderr)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_VALIDATION = 4
EXIT_COMPACT = 10

SCHEMA = "claude-mods.claude-api-ops.context-budget/v1"

# --- Cache economics (verified against platform.claude.com 2026-08-30) -------
# Guarded by check-model-table.py --offline: these literals are cross-checked
# against the prose in SKILL.md and references/*.md, so a one-file edit trips
# CI instead of leaving the docs and this calculator quietly disagreeing.
CACHE_READ_MULTIPLIER = 0.1     # cache read, every model, flat
CACHE_WRITE_5M = 1.25           # cache write, 5-minute TTL
CACHE_WRITE_1H = 2.0            # cache write, 1-hour TTL

# Every model in the current lineup prices output at exactly 5x its input rate
# (10/50, 5/25, 2/10, 1/5), so --output-rate defaults to 5x --base-rate rather
# than forcing the caller to look it up. Override it if that ever stops holding.
OUTPUT_RATE_RATIO = 5.0

PER_MTOK = 1_000_000.0


def note(msg: str, quiet: bool) -> None:
    if not quiet:
        print(msg, file=sys.stderr)


def fail(code: str, message: str, details: dict, json_mode: bool, exit_code: int):
    if json_mode:
        print(json.dumps({"error": {"code": code, "message": message,
                                    "details": details}}))
    print(f"{TERM.mark('bad')} ERROR: {message}", file=sys.stderr)
    for k, v in details.items():
        print(f"  {k}: {v}", file=sys.stderr)
    sys.exit(exit_code)


def cached_carry_cost(start_tokens: float, turns: int, growth: float,
                      rate: float) -> float:
    """Cost of re-sending a growing history at cache-read price for `turns` turns."""
    total_tokens = sum(start_tokens + growth * t for t in range(turns))
    return total_tokens * CACHE_READ_MULTIPLIER * rate / PER_MTOK


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="context-budget.py", add_help=True,
        description="Append-vs-compact calculator for a cached Claude conversation.",
        epilog=(
            "EXAMPLES:\n"
            "  context-budget.py --history-tokens 25000 --turns-remaining 5 "
            "--base-rate 0.30      # append wins (exit 0)\n"
            "  context-budget.py --history-tokens 120000 --turns-remaining 40 "
            "--base-rate 2.00      # cost favours compaction (exit 10)\n"
            "  context-budget.py --history-tokens 300000 --turns-remaining 60 "
            "--base-rate 10.00 --growth-per-turn 4000 --ttl 1h\n"
            "  context-budget.py --history-tokens 900000 --turns-remaining 10 "
            "--base-rate 5.00 --json\n"
            "\nEXIT: 0 append wins, 2 usage, 4 bad numbers, 10 compaction indicated\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--history-tokens", type=float, required=True,
                        help="current conversation/prefix size in tokens")
    parser.add_argument("--turns-remaining", type=int, required=True,
                        help="turns you expect AFTER this decision (a compaction "
                             "just before the end is pure loss)")
    parser.add_argument("--base-rate", type=float, default=5.00,
                        help="base INPUT price in $/MTok (default: 5.00)")
    parser.add_argument("--output-rate", type=float, default=None,
                        help=f"output price in $/MTok (default: {OUTPUT_RATE_RATIO}x "
                             "--base-rate, which holds across the current lineup)")
    parser.add_argument("--summary-tokens", type=float, default=None,
                        help="expected size of the summary (default: 10%% of history)")
    parser.add_argument("--growth-per-turn", type=float, default=0.0,
                        help="tokens the history grows each turn (default: 0)")
    parser.add_argument("--ttl", choices=["5m", "1h"], default="5m",
                        help="cache TTL, sets the write multiplier (default: 5m)")
    parser.add_argument("--context-window", type=float, default=1_000_000,
                        help="model context window in tokens (default: 1000000)")
    parser.add_argument("--json", action="store_true",
                        help="emit the JSON envelope on stdout")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="suppress stderr framing/workings")
    args = parser.parse_args(argv)

    jm, quiet = args.json, args.quiet

    # --- validate (agents fabricate plausible inputs; §6 of the resource protocol)
    if args.history_tokens <= 0:
        fail("VALIDATION", "--history-tokens must be positive",
             {"got": args.history_tokens}, jm, EXIT_VALIDATION)
    if args.turns_remaining < 0:
        fail("VALIDATION", "--turns-remaining cannot be negative",
             {"got": args.turns_remaining}, jm, EXIT_VALIDATION)
    if args.base_rate <= 0:
        fail("VALIDATION", "--base-rate must be positive",
             {"got": args.base_rate}, jm, EXIT_VALIDATION)
    if args.growth_per_turn < 0:
        fail("VALIDATION", "--growth-per-turn cannot be negative",
             {"got": args.growth_per_turn}, jm, EXIT_VALIDATION)
    if args.context_window <= 0:
        fail("VALIDATION", "--context-window must be positive",
             {"got": args.context_window}, jm, EXIT_VALIDATION)

    rate = args.base_rate
    out_rate = args.output_rate if args.output_rate is not None else rate * OUTPUT_RATE_RATIO
    if out_rate <= 0:
        fail("VALIDATION", "--output-rate must be positive", {"got": out_rate},
             jm, EXIT_VALIDATION)
    summary = (args.summary_tokens if args.summary_tokens is not None
               else args.history_tokens * 0.10)
    if summary <= 0:
        fail("VALIDATION", "--summary-tokens must be positive", {"got": summary},
             jm, EXIT_VALIDATION)
    if summary >= args.history_tokens:
        fail("VALIDATION", "--summary-tokens must be smaller than the history "
                           "(a 'summary' that isn't smaller saves nothing)",
             {"summary": summary, "history": args.history_tokens},
             jm, EXIT_VALIDATION)

    write_mult = CACHE_WRITE_1H if args.ttl == "1h" else CACHE_WRITE_5M
    turns = args.turns_remaining

    note(TERM.hdr("append vs compact"), quiet)

    # --- Constraint A: does it even fit? Checked first; cost is moot if not.
    projected = args.history_tokens + args.growth_per_turn * turns
    overflows = projected > args.context_window

    # --- Path 1: append. Carry the growing history at cache-read price.
    cost_append = cached_carry_cost(args.history_tokens, turns,
                                    args.growth_per_turn, rate)

    # --- Path 2: compact. Summarise now, then carry the summary.
    #   a) one summarisation call: history read from cache, summary generated
    per_summarise = (args.history_tokens * CACHE_READ_MULTIPLIER * rate / PER_MTOK
                     + summary * out_rate / PER_MTOK)
    #   b) writing the new (shorter) prefix into the cache, once per compaction
    per_rewrite = summary * write_mult * rate / PER_MTOK
    #   c) HOW MANY compactions. With growth, the summary climbs back to the
    #      original size after (history - summary)/growth turns and a real
    #      system compacts again. Charging a single one-shot rewrite flatters
    #      compaction badly on long agentic sessions (~2.2x on 60 turns at
    #      4k/turn), which is the regime where people actually reach for it.
    if args.growth_per_turn > 0:
        regrow_turns = (args.history_tokens - summary) / args.growth_per_turn
        compactions = max(1, 1 + int(turns / regrow_turns)) if turns > 0 else 0
    else:
        compactions = 1 if turns > 0 else 0
    cost_summarise = per_summarise * compactions
    cost_rewrite = per_rewrite * compactions
    #   d) carrying the summary for the remaining turns, growing as before
    cost_carry = cached_carry_cost(summary, turns, args.growth_per_turn, rate)
    cost_compact = cost_summarise + cost_rewrite + cost_carry

    delta = cost_append - cost_compact          # >0 means compaction is cheaper
    # Break-even: turns needed to repay ONE compaction's fixed cost. With
    # growth the cycle repeats, so this is a per-cycle repayment period, not a
    # whole-session verdict -- the verdict below compares the full modelled
    # costs including every compaction. Per-turn saving is the token difference
    # carried at cache-read price.
    per_turn_saving = ((args.history_tokens - summary)
                       * CACHE_READ_MULTIPLIER * rate / PER_MTOK)
    fixed_cost = per_summarise + per_rewrite   # one compaction's fixed cost
    breakeven = (fixed_cost / per_turn_saving) if per_turn_saving > 0 else float("inf")

    if overflows:
        verdict, reason = "compact", "context ceiling: projected history overflows the window"
    elif delta > 0:
        verdict, reason = "compact", "cost ceiling: compaction is cheaper over the remaining turns"
    else:
        verdict, reason = "append", "keep everything: appending is cheaper over the remaining turns"

    note(f"  projected history at turn {turns}: {projected:,.0f} tokens "
         f"(window {args.context_window:,.0f})", quiet)
    note(f"  compactions modelled: {compactions}"
         + (" (history regrows at --growth-per-turn)" if args.growth_per_turn > 0
            else " (no growth given -> one-shot)"), quiet)
    note(f"  append  ${cost_append:.4f}   compact ${cost_compact:.4f}"
         f"   (summarise ${cost_summarise:.4f} + rewrite ${cost_rewrite:.4f}"
         f" + carry ${cost_carry:.4f})", quiet)
    note(f"  break-even at ~{breakeven:.1f} turns per compaction cycle "
         f"(you have {turns} turns, {compactions} compaction(s) modelled)", quiet)
    note("  note: break-even is scale-invariant - size and price cancel out; it "
         "tracks the summary ratio, not how big or costly the conversation is.",
         quiet)
    if verdict == "append":
        note(f"{TERM.mark('ok')} APPEND. {reason}.", quiet)
        note("  Cheaper levers before compaction: cap tool output at the boundary, "
             "move payloads to files, verify the cache is actually hitting.", quiet)
    else:
        note(f"{TERM.mark('warn')} COMPACT. {reason}.", quiet)
        note("  Still try the cache-preserving levers first (tool-output caps, "
             "payloads to files) - they do not rewrite the prefix.", quiet)
        note("  RECALL IS NOT PRICED HERE. Cheaper is not the same as better: "
             "summarisation has measured 92-100% -> 38-58% on planted-fact "
             "recall. Probe yours (assets/recall-probe.py) before acting.", quiet)

    data = {
        "verdict": verdict,
        "reason": reason,
        "context_ceiling_hit": overflows,
        "inputs": {
            "history_tokens": args.history_tokens,
            "turns_remaining": turns,
            "base_rate_per_mtok": rate,
            "output_rate_per_mtok": out_rate,
            "summary_tokens": summary,
            "growth_per_turn": args.growth_per_turn,
            "ttl": args.ttl,
            "context_window": args.context_window,
        },
        "multipliers": {
            "cache_read": CACHE_READ_MULTIPLIER,
            "cache_write": write_mult,
        },
        "cost_usd": {
            "append": round(cost_append, 6),
            "compact": round(cost_compact, 6),
            "compact_summarise_call": round(cost_summarise, 6),
            "compact_cache_rewrite": round(cost_rewrite, 6),
            "compact_carry": round(cost_carry, 6),
            "delta_append_minus_compact": round(delta, 6),
        },
        "breakeven_turns_per_compaction": (
            round(breakeven, 2) if breakeven != float("inf") else None),
        "compactions_modelled": compactions,
        "projected_history_tokens": projected,
        "caveats": [
            "models cost only - recall loss from summarisation is not priced",
            "break-even turns is scale-invariant: driven by the summary ratio, "
            "the output/input price ratio and the write multiplier - not by "
            "history size or price level",
            "break-even is the repayment period for ONE compaction; the verdict "
            "compares full modelled costs across all modelled compactions",
        ],
    }

    if jm:
        print(json.dumps({"data": data,
                          "meta": {"schema": SCHEMA, "status": verdict}}))
    else:
        print(f"{verdict}\tappend=${cost_append:.4f}\tcompact=${cost_compact:.4f}"
              f"\tbreakeven_turns_per_compaction={breakeven:.1f}"
              f"  compactions={compactions}")

    return EXIT_COMPACT if verdict == "compact" else EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(EXIT_USAGE)
