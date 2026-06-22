#!/usr/bin/env python3
"""Offline verifier: loop-ops pricing must match claude-api-ops's model table.

loop-estimate.py reads assets/model-pricing.json. That table is a *copy* of the
authoritative "Current Models" table in skills/claude-api-ops/SKILL.md — and a
copy drifts silently (the exact §7 failure mode). This asserts every model in
loop-ops' pricing exists in the claude-api-ops table with matching input/output
prices. Both files are in-repo, so this is a pure OFFLINE consistency check and
safe to gate PR CI (no network). Live model-id drift is owned by
claude-api-ops/scripts/check-model-table.py.

Usage:   check-pricing-sync.py [--offline] [--pricing FILE] [--table FILE] [--json]
Input:   argv flags only (no stdin).
Output:  stdout = drift findings (plain rows, or --json envelope). Data only.
Stderr:  the verdict panel, notices, errors.
Exit:    0 in sync, 2 usage, 3 a file missing, 4 unparseable, 10 drift found

--offline is the default and only mode (accepted for parity with the other §7
verifiers invoked by tests/check-resources.sh).

Examples:
  check-pricing-sync.py --offline
  check-pricing-sync.py --json | jq '.data[]'
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
EX_UNPARSEABLE = 4
EX_DRIFT = 10

HERE = Path(__file__).resolve().parent
DEFAULT_PRICING = HERE.parent / "assets" / "model-pricing.json"
DEFAULT_TABLE = HERE.parent.parent / "claude-api-ops" / "SKILL.md"

PRICE_RE = re.compile(r"\$?\s*([0-9]+(?:\.[0-9]+)?)")


class Term:
    """Minimal ANSI helper (term.sh is bash-only; per TERMINAL-DESIGN.md §9 the
    Python port is inline). Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the
    bound stream's TTY + encoding so piped data stays plain ASCII."""

    _C = {"green": "\033[32m", "red": "\033[31m", "cyan": "\033[36m",
          "dim": "\033[2m", "off": "\033[0m"}

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

    def mark(self, ok):
        g = ("+" if self.ascii else "✓") if ok else ("x" if self.ascii else "✗")
        return self.c("green" if ok else "red", g)


def parse_price(cell: str) -> float | None:
    m = PRICE_RE.search(cell)
    return float(m.group(1)) if m else None


def load_pricing(path: Path) -> dict:
    """{model_id: (input_per_mtok, output_per_mtok)} from loop-ops' JSON."""
    if not path.is_file():
        print(f"error: pricing file not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        out = {}
        for mid, pr in data.get("models", {}).items():
            out[mid] = (float(pr["input_per_mtok"]), float(pr["output_per_mtok"]))
        if not out:
            print(f"error: no models in {path}", file=sys.stderr)
            raise SystemExit(EX_UNPARSEABLE)
        return out
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse pricing file: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def load_table(path: Path) -> dict:
    """{model_id: (input_price, output_price)} from the claude-api-ops markdown
    'Current Models' table. Columns: Model | ID | Context | Max Output | Input | Output."""
    if not path.is_file():
        print(f"error: claude-api-ops table not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    table: dict = {}
    in_table = False
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        low = s.lower()
        if s.startswith("|") and "id" in low and "context" in low and "output" in low:
            in_table = True
            continue
        if in_table:
            if not s.startswith("|"):
                if table:  # table ended
                    break
                continue
            if set(s) <= set("|-: "):  # separator row
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) < 6:
                continue
            mid = cells[1].strip("`").strip()
            if not mid.startswith("claude-"):
                continue
            ip, op = parse_price(cells[4]), parse_price(cells[5])
            if ip is not None and op is not None:
                table[mid] = (ip, op)
    if not table:
        print(f"error: no model rows parsed from {path}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)
    return table


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-pricing-sync.py",
        description="Verify loop-ops pricing matches claude-api-ops's model table (offline).",
    )
    p.add_argument("--offline", action="store_true", help="offline consistency check (default/only mode)")
    p.add_argument("--pricing", default=str(DEFAULT_PRICING), help="loop-ops model-pricing.json")
    p.add_argument("--table", default=str(DEFAULT_TABLE), help="claude-api-ops SKILL.md with the model table")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    pricing = load_pricing(Path(args.pricing))
    table = load_table(Path(args.table))

    findings = []
    for mid, (ip, op) in sorted(pricing.items()):
        if mid not in table:
            findings.append({"model": mid, "issue": "absent from claude-api-ops table",
                             "loop_ops": [ip, op], "authoritative": None})
            continue
        tip, top = table[mid]
        if abs(ip - tip) > 1e-9 or abs(op - top) > 1e-9:
            findings.append({"model": mid, "issue": "price mismatch",
                             "loop_ops": [ip, op], "authoritative": [tip, top]})

    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"count": len(findings), "models_checked": len(pricing),
                     "in_sync": not findings, "schema": "claude-mods.loop-ops.pricing-sync/v1"},
        }, indent=2))
    else:
        for f in findings:
            auth = f"authoritative {f['authoritative']}" if f["authoritative"] else "not in table"
            print(f"DRIFT  {f['model']}: {f['issue']} (loop-ops {f['loop_ops']} vs {auth})")
        t = Term(sys.stderr)
        ok = not findings
        print(f"{t.mark(ok)} pricing-sync: {len(pricing)} model(s) checked, "
              f"{len(findings)} drift "
              f"{t.c('dim', '(authoritative: claude-api-ops/SKILL.md)')}", file=sys.stderr)

    return EX_DRIFT if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
