#!/usr/bin/env python3
"""Test-time budget ratchet: the suite may not get slower, and no new slow test gets in.

Usage:   budget-gate.py baseline <profile.json> [--tolerance-pct P] [--floor-s S] [--max-test-s T]
         budget-gate.py check    <profile.json> --baseline <.test-budget.json> [--json]
Input:   <profile.json> is `suite-profile.py profile --json` output for the FULL suite (a
         change-aware subset run measures nothing about the suite and is refused: its test
         count must be at least the baseline's minus --shrink-ok).
Output:  baseline: the budget document on stdout (redirect it to .test-budget.json and commit).
         check: findings, TSV or --json (schema claude-mods.test-engineering.budget/v1).
Stderr:  the verdict line, errors.
Exit:    0 within budget, 2 usage, 3 file not found, 4 invalid input, 10 over budget.

The ratchet (references/gate.md):
  B1 suite time  > baseline total * (1 + tolerance) AND the growth exceeds floor-s.
                 The floor absorbs runner noise; a 0.4 s suite growing to 0.5 s is not news.
  B2 a test over max-test-s that the baseline does not list as grandfathered-slow.
  B3 a grandfathered-slow test that got slower than its recorded time * (1 + tolerance).
  Faster is always fine; `baseline` after a speed-up tightens the budget (a ratchet only
  turns one way). Test count changes are reported, never blocked: a count is not value.

Examples:
  budget-gate.py baseline full.json --tolerance-pct 15 --max-test-s 2 > .test-budget.json
  budget-gate.py check full.json --baseline .test-budget.json
  budget-gate.py check full.json --baseline .test-budget.json --json | jq '.data[]'
"""
import argparse
import json
import sys

SCHEMA = "claude-mods.test-engineering.budget/v1"


def err(msg):
    print(f"budget-gate: {msg}", file=sys.stderr)


def load(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        err(f"{what} not found: {path}")
        sys.exit(3)
    except ValueError as e:
        err(f"{what} is not JSON: {path} ({e})")
        sys.exit(4)


def profile_data(path):
    doc = load(path, "profile")
    try:
        d = doc["data"]
        return d["totals"], d["tests"]
    except (KeyError, TypeError):
        err(f"not a suite-profile --json document: {path}")
        sys.exit(4)


def cmd_baseline(a):
    totals, tests = profile_data(a.profile)
    slow = {t["id"]: round(t["time_s"], 3) for t in tests if t["time_s"] > a.max_test_s}
    doc = {
        "schema": SCHEMA,
        "policy": {"tolerance_pct": a.tolerance_pct, "floor_s": a.floor_s,
                   "max_test_s": a.max_test_s, "shrink_ok": a.shrink_ok},
        "suite": {"tests": totals["tests"], "time_s": totals["time_s"]},
        # Grandfathered: may stay, may not get slower. The list should only ever shrink.
        "slow": dict(sorted(slow.items())),
    }
    print(json.dumps(doc, indent=2))
    err(f"baseline: {totals['tests']} tests, {totals['time_s']} s, {len(slow)} grandfathered slow")
    return 0


def cmd_check(a):
    totals, tests = profile_data(a.profile)
    base = load(a.baseline, "baseline")
    try:
        pol, suite, slow = base["policy"], base["suite"], base["slow"]
        tol = pol["tolerance_pct"] / 100.0
    except (KeyError, TypeError):
        err(f"not a budget-gate baseline: {a.baseline}")
        sys.exit(4)
    if totals["tests"] < suite["tests"] - pol.get("shrink_ok", 0) - a.shrink_ok:
        err(f"profile has {totals['tests']} tests, baseline {suite['tests']}: this looks like a "
            "subset run. Profile the full suite, or re-baseline after a prune (--shrink-ok N).")
        sys.exit(4)
    findings = []
    limit = suite["time_s"] * (1 + tol)
    growth = totals["time_s"] - suite["time_s"]
    if totals["time_s"] > limit and growth > pol["floor_s"]:
        findings.append({"rule": "B1", "id": "<suite>", "time_s": totals["time_s"],
                         "budget_s": round(limit, 3),
                         "why": f"suite grew {growth:.1f} s over its {suite['time_s']} s baseline"})
    for t in tests:
        if t["id"] in slow:
            cap = slow[t["id"]] * (1 + tol)
            if t["time_s"] > cap and t["time_s"] - slow[t["id"]] > pol["floor_s"]:
                findings.append({"rule": "B3", "id": t["id"], "time_s": t["time_s"],
                                 "budget_s": round(cap, 3), "why": "grandfathered slow test got slower"})
        elif t["time_s"] > pol["max_test_s"]:
            findings.append({"rule": "B2", "id": t["id"], "time_s": t["time_s"],
                             "budget_s": pol["max_test_s"],
                             "why": "new test over the per-test budget: make it faster, or move it to a slower tier"})
    if a.json:
        print(json.dumps({"data": findings, "meta": {
            "schema": SCHEMA, "count": len(findings),
            "suite": {"time_s": totals["time_s"], "baseline_s": suite["time_s"],
                      "tests": totals["tests"], "baseline_tests": suite["tests"]}}}, indent=2))
    else:
        for f in findings:
            print(f"{f['rule']}\t{f['time_s']}\t{f['budget_s']}\t{f['id']}\t{f['why']}")
    delta = totals["tests"] - suite["tests"]
    err(f"{'OVER BUDGET' if findings else 'within budget'}: {totals['time_s']} s "
        f"(baseline {suite['time_s']} s), tests {totals['tests']} ({delta:+d})")
    return 10 if findings else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("baseline")
    b.add_argument("profile")
    b.add_argument("--tolerance-pct", type=float, default=15.0)
    b.add_argument("--floor-s", type=float, default=5.0)
    b.add_argument("--max-test-s", type=float, default=2.0)
    b.add_argument("--shrink-ok", type=int, default=0)
    c = sub.add_parser("check")
    c.add_argument("profile")
    c.add_argument("--baseline", required=True)
    c.add_argument("--shrink-ok", type=int, default=0,
                   help="tests this change deleted on purpose (prune mode)")
    c.add_argument("--json", action="store_true")
    a = p.parse_args()
    if a.cmd == "baseline" and (a.tolerance_pct < 0 or a.floor_s < 0 or a.max_test_s <= 0):
        p.error("tolerance and floor must be >= 0, max-test-s > 0")
    return cmd_baseline(a) if a.cmd == "baseline" else cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
