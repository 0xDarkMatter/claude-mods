#!/usr/bin/env python3
"""Estimate the token/$ cost of an outer loop by pattern × cadence × model.

A loop's cost is runs/day × tokens/run × price, and sub-agents multiply tokens/run.
This computes that before you commit to a cadence. Pricing reads from
assets/model-pricing.json (date-stamped; skills/claude-api-ops is the source of
truth — run its check-model-table.py if you suspect drift).

Usage:   loop-cost.py --pattern P --cadence C --model M [OPTIONS]
Input:   argv flags only (no stdin).
Output:  stdout = the cost breakdown (plain rows, or --json envelope). Data only.
Stderr:  the assumptions note, errors.
Exit:    0 ok, 2 usage, 3 pricing file missing, 4 bad cadence/model/pattern

Estimates, not guarantees — reconcile against the loop's run-log.md actuals. The
cheapest lever is cadence (halving frequency halves cost); the next is model.

Examples:
  loop-cost.py --pattern pr-babysitter --cadence 10m --model claude-haiku-4-5
  loop-cost.py --pattern ci-sweeper --cadence 15m --model claude-sonnet-4-6 --days 30 --json
  loop-cost.py --list-models
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_VALIDATION = 4

DEFAULT_PRICING = Path(__file__).resolve().parent.parent / "assets" / "model-pricing.json"


class Term:
    """Minimal ANSI helper (term.sh is bash-only; per TERMINAL-DESIGN.md §9 the
    Python port is inline). Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the
    bound stream's TTY + encoding, so piped data stays plain ASCII."""

    _C = {"green": "\033[32m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = os.environ.get("TERM_ASCII") == "1" or "utf" not in enc
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None
              or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name,'')}{text}{self._C['off']}" if self.color else text


def load_pricing(path: Path) -> dict:
    if not path.is_file():
        print(f"error: pricing file not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"error: could not read pricing file: {exc}", file=sys.stderr)
        raise SystemExit(EX_VALIDATION)


def runs_per_day(cadence: str, override: float | None) -> float:
    """Translate a cadence into runs/day. Supports Nm/Nh/Nd and the common cron
    forms `*/N * * * *` and `N * * * *`. --runs-per-day overrides everything."""
    if override is not None:
        if override <= 0:
            print("error: --runs-per-day must be positive", file=sys.stderr)
            raise SystemExit(EX_VALIDATION)
        return float(override)

    s = cadence.strip()
    m = re.fullmatch(r"(\d+)([mhd])", s)
    if m:
        n = int(m.group(1))
        if n <= 0:
            print(f"error: cadence value must be positive (got '{cadence}')", file=sys.stderr)
            raise SystemExit(EX_VALIDATION)
        return {"m": 1440.0, "h": 24.0, "d": 1.0}[m.group(2)] / n
    cron_min = re.fullmatch(r"\*/(\d+) \* \* \* \*", s)
    if cron_min:
        n = int(cron_min.group(1))
        return 1440.0 / n if n > 0 else 1440.0
    if re.fullmatch(r"\d+ \* \* \* \*", s):
        return 24.0
    print(
        f"error: cannot derive runs/day from cadence '{cadence}' — "
        "use Nm/Nh/Nd, `*/N * * * *`, or pass --runs-per-day",
        file=sys.stderr,
    )
    raise SystemExit(EX_VALIDATION)


def fmt_money(x: float) -> str:
    """Human dollar string: cents below $100, 4 decimals below $1 for tiny per-run costs."""
    if x < 1:
        return f"${x:.4f}"
    return f"${x:,.2f}"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="loop-cost.py",
        description="Estimate outer-loop cost by pattern × cadence × model.",
    )
    p.add_argument("--pattern", default="custom", help="catalog pattern key (default: custom)")
    p.add_argument("--cadence", default="1h", help="10m | 1h | 6h | 1d, or a cron string (default: 1h)")
    p.add_argument("--model", default="claude-haiku-4-5", help="model id (default: claude-haiku-4-5)")
    p.add_argument("--days", type=int, default=30, help="horizon in days for the total (default: 30)")
    p.add_argument("--runs-per-day", type=float, default=None, help="override the cadence-derived runs/day")
    p.add_argument("--input-tokens", type=int, default=None, help="override per-run input tokens")
    p.add_argument("--output-tokens", type=int, default=None, help="override per-run output tokens")
    p.add_argument("--subagents", type=int, default=None, help="override the sub-agent fan-out multiplier")
    p.add_argument("--pricing", default=str(DEFAULT_PRICING), help="path to model-pricing.json")
    p.add_argument("--list-models", action="store_true", help="print the pricing table + as-of date, exit 0")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    pricing = load_pricing(Path(args.pricing))
    models = pricing.get("models", {})
    as_of = pricing.get("_as_of", "unknown")
    pattern_defaults = pricing.get("_pattern_defaults", {})

    # ── --list-models ──
    if args.list_models:
        if args.json:
            print(json.dumps({"data": models, "meta": {"as_of": as_of, "schema": "claude-mods.loop-ops.pricing/v1"}}, indent=2))
        else:
            print(f"{'model':<22}{'input $/MTok':>14}{'output $/MTok':>16}")
            for mid, pr in models.items():
                print(f"{mid:<22}{pr.get('input_per_mtok', 0):>14.2f}{pr.get('output_per_mtok', 0):>16.2f}")
            print(f"\n(as of {as_of}; source of truth: claude-api-ops)", file=sys.stderr)
        return EX_OK

    if args.days <= 0:
        print("error: --days must be positive", file=sys.stderr)
        return EX_VALIDATION

    # ── model ──
    if args.model not in models:
        print(f"error: unknown model '{args.model}' — known: {', '.join(models) or '(none)'}", file=sys.stderr)
        return EX_VALIDATION
    in_price = float(models[args.model]["input_per_mtok"])
    out_price = float(models[args.model]["output_per_mtok"])

    # ── tokens/run: overrides win, else pattern defaults ──
    if args.input_tokens is not None and args.output_tokens is not None:
        in_tok, out_tok = args.input_tokens, args.output_tokens
        sub = args.subagents if args.subagents is not None else 1
    elif args.pattern in pattern_defaults:
        d = pattern_defaults[args.pattern]
        in_tok = args.input_tokens if args.input_tokens is not None else int(d["input"])
        out_tok = args.output_tokens if args.output_tokens is not None else int(d["output"])
        sub = args.subagents if args.subagents is not None else int(d.get("subagents", 1))
    else:
        print(
            f"error: unknown pattern '{args.pattern}' — pass --input-tokens and "
            f"--output-tokens, or use one of: {', '.join(k for k in pattern_defaults if not k.startswith('_'))}",
            file=sys.stderr,
        )
        return EX_VALIDATION

    if min(in_tok, out_tok, sub) < 0:
        print("error: token counts and --subagents must be non-negative", file=sys.stderr)
        return EX_VALIDATION

    rpd = runs_per_day(args.cadence, args.runs_per_day)

    # ── cost math ──
    cost_in = in_tok / 1_000_000 * in_price
    cost_out = out_tok / 1_000_000 * out_price
    cost_run = (cost_in + cost_out) * sub
    tokens_run = (in_tok + out_tok) * sub
    cost_day = cost_run * rpd
    cost_horizon = cost_day * args.days

    if args.json:
        envelope = {
            "data": {
                "pattern": args.pattern,
                "model": args.model,
                "cadence": args.cadence,
                "runs_per_day": round(rpd, 3),
                "tokens_per_run": tokens_run,
                "input_tokens": in_tok,
                "output_tokens": out_tok,
                "subagents": sub,
                "cost_per_run": round(cost_run, 6),
                "cost_per_day": round(cost_day, 4),
                "days": args.days,
                "cost_per_horizon": round(cost_horizon, 2),
            },
            "meta": {"as_of": as_of, "schema": "claude-mods.loop-ops.cost/v1"},
        }
        print(json.dumps(envelope, indent=2))
        return EX_OK

    t = Term(sys.stderr)
    print(f"{'pattern:':<16}{args.pattern}")
    print(f"{'model:':<16}{args.model}")
    print(f"{'cadence:':<16}{args.cadence}  ->  {rpd:g} runs/day")
    print(f"{'tokens/run:':<16}{tokens_run:,} ({in_tok:,} in + {out_tok:,} out) x {sub} subagent(s)")
    print(f"{'cost/run:':<16}{fmt_money(cost_run)}")
    print(f"{'cost/day:':<16}{fmt_money(cost_day)}")
    print(f"{'cost/'+str(args.days)+'d:':<16}{t.c('cyan', fmt_money(cost_horizon))}")
    print(
        f"estimate (as of {as_of} pricing) - reconcile against run-log.md actuals; "
        "cadence is the biggest lever",
        file=sys.stderr,
    )
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
