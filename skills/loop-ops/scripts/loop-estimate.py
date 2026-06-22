#!/usr/bin/env python3
"""Estimate the token/$ cost of an outer loop by pattern × cadence × model.

A loop's cost is runs/day × tokens/run × price, and sub-agents multiply tokens/run.
This computes that - and, crucially, models **prompt caching**: a loop re-sends the
SAME run.md + system prefix every tick (the Ralph property), which is the textbook
caching case. Whether caching helps depends on cadence vs cache TTL, so this picks the
TTL and reports the cached projection alongside the naive one.

Pricing reads from assets/model-pricing.json (date-stamped; skills/claude-api-ops is
the source of truth - run its check-model-table.py if you suspect drift).

Usage:   loop-estimate.py --pattern P --cadence C --model M [OPTIONS]
Input:   argv flags only (no stdin).
Output:  stdout = the cost breakdown (plain rows, or --json envelope). Data only.
Stderr:  the assumptions + caching note, errors.
Exit:    0 ok, 2 usage, 3 pricing file missing, 4 bad cadence/model/pattern

Estimates, not guarantees - reconcile against the loop's run-log.md actuals. Levers in
order of impact: cadence (halving frequency halves cost), prompt caching (model below),
model tier.

Examples:
  loop-estimate.py --pattern pr-watch --cadence 10m --model claude-haiku-4-5
  loop-estimate.py --pattern ci-watch --cadence 15m --model claude-sonnet-4-6 --days 30 --json
  loop-estimate.py --pattern daily-scan --cadence 6h --model claude-opus-4-8   # too slow to cache
  loop-estimate.py --list-models
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

# Prompt-caching multipliers vs base input price (claude-api-ops/references/caching-and-cost.md).
CACHE_WRITE_5M = 1.25   # write a 5-minute-TTL entry
CACHE_WRITE_1H = 2.0    # write a 1-hour-TTL entry
CACHE_READ = 0.1        # read any cached entry

# Minimum cacheable prefix (tokens) - below this the cache_control marker is silently
# ignored (caching-and-cost.md). A loop whose static prefix is smaller can't cache.
MIN_PREFIX = {
    "claude-fable-5": 512,
    "claude-opus-4-8": 1024,
    "claude-sonnet-4-6": 1024,
    "claude-haiku-4-5": 4096,
}
DEFAULT_MIN_PREFIX = 1024


class Term:
    """Minimal ANSI helper (term.sh is bash-only; per TERMINAL-DESIGN.md §9 the Python
    port is inline). Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the bound stream's
    TTY + encoding, so piped data stays plain ASCII."""

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
        f"error: cannot derive runs/day from cadence '{cadence}' - "
        "use Nm/Nh/Nd, `*/N * * * *`, or pass --runs-per-day",
        file=sys.stderr,
    )
    raise SystemExit(EX_VALIDATION)


def caching_projection(in_tok, out_tok, sub, in_price, out_price, rpd, model,
                       prefix_frac, ttl_choice):
    """Model prompt-caching of the static run-prompt prefix across ticks.

    Returns a dict: ttl, beneficial, reason, cost_per_run/day, prefix_tokens.
    The cache stays warm only when the tick interval is <= the TTL (reads refresh it);
    a loop slower than the 1h max TTL writes a cold entry every tick - caching can't help.
    """
    interval_min = 1440.0 / rpd if rpd > 0 else 1e9
    prefix_tokens = int(round(in_tok * prefix_frac))
    variable_in = in_tok - prefix_tokens
    min_prefix = MIN_PREFIX.get(model, DEFAULT_MIN_PREFIX)

    # Pick TTL: smallest that stays warm at this cadence.
    if ttl_choice == "5m":
        ttl, warm = "5m", interval_min <= 5
    elif ttl_choice == "1h":
        ttl, warm = "1h", interval_min <= 60
    else:  # auto
        if interval_min <= 5:
            ttl, warm = "5m", True
        elif interval_min <= 60:
            ttl, warm = "1h", True
        else:
            ttl, warm = None, False

    out_cost_day = out_tok / 1e6 * out_price * rpd

    if prefix_tokens < min_prefix:
        return {"ttl": ttl, "beneficial": False,
                "reason": f"static prefix ~{prefix_tokens} tok < {model} minimum {min_prefix} tok "
                          "- cache marker silently ignored; enlarge the run prompt/system or skip caching",
                "prefix_tokens": prefix_tokens, "cost_per_day": None, "cost_per_run": None}
    if not warm or ttl is None:
        return {"ttl": ttl, "beneficial": False,
                "reason": f"tick interval ~{interval_min:.0f} min exceeds the cache TTL "
                          "- the entry expires between ticks, so every tick is a cold write; caching won't help",
                "prefix_tokens": prefix_tokens, "cost_per_day": None, "cost_per_run": None}

    write_mult = CACHE_WRITE_5M if ttl == "5m" else CACHE_WRITE_1H
    # Per day, warm: ~1 cache write of the prefix + (rpd-1) reads; variable input + output full price.
    prefix_day = prefix_tokens / 1e6 * in_price * (write_mult + max(rpd - 1, 0) * CACHE_READ)
    variable_day = variable_in / 1e6 * in_price * rpd
    cost_day = (prefix_day + variable_day + out_cost_day) * sub
    return {"ttl": ttl, "beneficial": True, "reason": "",
            "prefix_tokens": prefix_tokens, "write_mult": write_mult,
            "cost_per_day": cost_day, "cost_per_run": cost_day / rpd if rpd else cost_day}


def fmt_money(x: float) -> str:
    if x < 1:
        return f"${x:.4f}"
    return f"${x:,.2f}"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="loop-estimate.py",
        description="Estimate outer-loop cost by pattern × cadence × model, with prompt caching.",
    )
    p.add_argument("--pattern", default="custom", help="catalog pattern key (default: custom)")
    p.add_argument("--cadence", default="1h", help="10m | 1h | 6h | 1d, or a cron string (default: 1h)")
    p.add_argument("--model", default="claude-haiku-4-5", help="model id (default: claude-haiku-4-5)")
    p.add_argument("--days", type=int, default=30, help="horizon in days for the total (default: 30)")
    p.add_argument("--runs-per-day", type=float, default=None, help="override the cadence-derived runs/day")
    p.add_argument("--input-tokens", type=int, default=None, help="override per-run input tokens")
    p.add_argument("--output-tokens", type=int, default=None, help="override per-run output tokens")
    p.add_argument("--subagents", type=int, default=None, help="override the sub-agent fan-out multiplier")
    p.add_argument("--cache-prefix-frac", type=float, default=0.6,
                   help="fraction of input that is the static, cacheable run-prompt prefix (default: 0.6)")
    p.add_argument("--cache-ttl", choices=["auto", "5m", "1h"], default="auto",
                   help="cache TTL to model (default: auto - pick by cadence)")
    p.add_argument("--no-cache", action="store_true", help="report the uncached cost only")
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
    if not (0.0 <= args.cache_prefix_frac <= 1.0):
        print("error: --cache-prefix-frac must be between 0 and 1", file=sys.stderr)
        return EX_VALIDATION

    if args.model not in models:
        print(f"error: unknown model '{args.model}' - known: {', '.join(models) or '(none)'}", file=sys.stderr)
        return EX_VALIDATION
    in_price = float(models[args.model]["input_per_mtok"])
    out_price = float(models[args.model]["output_per_mtok"])

    if args.input_tokens is not None and args.output_tokens is not None:
        in_tok, out_tok = args.input_tokens, args.output_tokens
        sub = args.subagents if args.subagents is not None else 1
    elif args.pattern in pattern_defaults and not args.pattern.startswith("_"):
        d = pattern_defaults[args.pattern]
        in_tok = args.input_tokens if args.input_tokens is not None else int(d["input"])
        out_tok = args.output_tokens if args.output_tokens is not None else int(d["output"])
        sub = args.subagents if args.subagents is not None else int(d.get("subagents", 1))
    else:
        print(
            f"error: unknown pattern '{args.pattern}' - pass --input-tokens and "
            f"--output-tokens, or use one of: {', '.join(k for k in pattern_defaults if not k.startswith('_'))}",
            file=sys.stderr,
        )
        return EX_VALIDATION

    if min(in_tok, out_tok, sub) < 0:
        print("error: token counts and --subagents must be non-negative", file=sys.stderr)
        return EX_VALIDATION

    rpd = runs_per_day(args.cadence, args.runs_per_day)

    # ── uncached (naive) ──
    cost_in = in_tok / 1_000_000 * in_price
    cost_out = out_tok / 1_000_000 * out_price
    cost_run = (cost_in + cost_out) * sub
    tokens_run = (in_tok + out_tok) * sub
    cost_day = cost_run * rpd
    cost_horizon = cost_day * args.days

    # ── cached projection ──
    cache = None
    if not args.no_cache:
        cache = caching_projection(in_tok, out_tok, sub, in_price, out_price, rpd,
                                   args.model, args.cache_prefix_frac, args.cache_ttl)

    if args.json:
        data = {
            "pattern": args.pattern, "model": args.model, "cadence": args.cadence,
            "runs_per_day": round(rpd, 3), "tokens_per_run": tokens_run,
            "input_tokens": in_tok, "output_tokens": out_tok, "subagents": sub,
            "cost_per_run": round(cost_run, 6), "cost_per_day": round(cost_day, 4),
            "days": args.days, "cost_per_horizon": round(cost_horizon, 2),
        }
        if cache is not None:
            if cache["beneficial"]:
                cd = cache["cost_per_day"]
                data["caching"] = {
                    "beneficial": True, "ttl": cache["ttl"], "prefix_tokens": cache["prefix_tokens"],
                    "cost_per_day": round(cd, 4), "cost_per_horizon": round(cd * args.days, 2),
                    "savings_pct": round((cost_day - cd) / cost_day * 100, 1) if cost_day else 0.0,
                }
            else:
                data["caching"] = {"beneficial": False, "reason": cache["reason"],
                                   "prefix_tokens": cache["prefix_tokens"]}
        print(json.dumps({"data": data, "meta": {"as_of": as_of, "schema": "claude-mods.loop-ops.estimate/v1"}}, indent=2))
        return EX_OK

    t = Term(sys.stderr)
    print(f"{'pattern:':<16}{args.pattern}")
    print(f"{'model:':<16}{args.model}")
    print(f"{'cadence:':<16}{args.cadence}  ->  {rpd:g} runs/day")
    print(f"{'tokens/run:':<16}{tokens_run:,} ({in_tok:,} in + {out_tok:,} out) x {sub} subagent(s)")
    print(f"{'cost/run:':<16}{fmt_money(cost_run)}")
    print(f"{'cost/day:':<16}{fmt_money(cost_day)}")
    print(f"{'cost/'+str(args.days)+'d:':<16}{fmt_money(cost_horizon)}  (uncached)")
    if cache is not None:
        if cache["beneficial"]:
            cd, ch = cache["cost_per_day"], cache["cost_per_day"] * args.days
            save = (cost_day - cd) / cost_day * 100 if cost_day else 0.0
            print(f"{'cached/'+str(args.days)+'d:':<16}{t.c('cyan', fmt_money(ch))}  "
                  f"({t.c('green', f'-{save:.0f}%')}, TTL {cache['ttl']}, prefix ~{cache['prefix_tokens']:,} tok)")
            print(f"recommendation: cache the static run.md+system prefix at TTL {cache['ttl']} "
                  f"-> ~-{save:.0f}%/mo. Keep run.md BYTE-IDENTICAL every tick or the cache never hits.",
                  file=sys.stderr)
        else:
            print(f"caching: not beneficial here", file=sys.stderr)
            print(f"  why: {cache['reason']}", file=sys.stderr)
    print(f"estimate (as of {as_of} pricing) - reconcile against run-log.md actuals; "
          "cadence is the biggest lever, then caching, then model tier", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
