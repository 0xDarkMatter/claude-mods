#!/usr/bin/env python3
"""Find tests whose covered lines another test already covers: redundancy CANDIDATES.

Usage:   coverage-overlap.py <coverage.json> [--profile PROFILE.json] [--top N] [--json]
Input:   coverage.py JSON with per-test contexts:
           pytest --cov=src --cov-context=test && coverage json --show-contexts -o cov.json
         or a generic map {"<test id>": ["path:line", ...]} from any other per-test tool.
         --profile (suite-profile.py profile --json) adds each test's seconds, so the list
         ranks by the CI time a deletion would save.
Output:  one row per candidate: the test, the test that covers it, lines, seconds. TSV, or
         --json (schema claude-mods.test-engineering.coverage-overlap/v1).
Stderr:  summary, errors.
Exit:    0 no candidates, 2 usage, 3 not found, 4 invalid input, 10 candidates found.

A candidate is a QUESTION, never a verdict (references/prune.md): two tests can run the
same lines and pin different values. Deletion needs evidence that the covering test kills
every mutant the candidate kills. Tests with identical line sets are reported once, as a
pair, with the faster test kept as the cover. Tests that cover no lines are not reported
here: an empty set is a subset of everything, and those belong to slop review (S10, S18).

Examples:
  coverage-overlap.py cov.json
  coverage-overlap.py cov.json --profile full.json --top 30 --json | jq '.data[0]'
"""
import argparse
import json
import sys

SCHEMA = "claude-mods.test-engineering.coverage-overlap/v1"


def err(msg):
    print(f"coverage-overlap: {msg}", file=sys.stderr)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        err(f"not found: {path}")
        sys.exit(3)
    except ValueError as e:
        err(f"not JSON: {path} ({e})")
        sys.exit(4)


def lines_by_test(doc):
    if isinstance(doc, dict) and "files" in doc and "meta" in doc:  # coverage.py
        tests = {}
        for path, f in doc["files"].items():
            ctx = f.get("contexts")
            if ctx is None:
                err("this coverage.json has no contexts: re-run with --cov-context=test "
                    "and `coverage json --show-contexts`")
                sys.exit(4)
            for line, names in ctx.items():
                for n in names:
                    if not n:  # "" is the no-test context (import time)
                        continue
                    n = n.rsplit("|", 1)[0]  # "tests/x.py::test_a|run" -> the test id
                    tests.setdefault(n, set()).add(f"{path}:{line}")
        return tests
    if isinstance(doc, dict) and all(isinstance(v, list) for v in doc.values()):
        return {k: set(v) for k, v in doc.items()}
    err("unrecognised input: expected coverage.py JSON with contexts, or {test: [path:line]}")
    sys.exit(4)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("coverage")
    p.add_argument("--profile")
    p.add_argument("--top", type=int, default=50)
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    tests = {k: v for k, v in lines_by_test(load(a.coverage)).items() if v}
    secs = {}
    if a.profile:
        try:
            for t in load(a.profile)["data"]["tests"]:
                secs[t["id"]] = t["time_s"]
                # pytest junit ids are "pkg.module::name"; coverage ids are "path.py::name"
                secs.setdefault(t["name"], t["time_s"])
        except (KeyError, TypeError):
            err(f"not a suite-profile --json document: {a.profile}")
            return 4
    sec = lambda t: secs.get(t, secs.get(t.split("::")[-1], 0.0))
    # Largest first, so each test is checked only against tests at least its size.
    order = sorted(tests, key=lambda t: (-len(tests[t]), sec(t), t))
    out, seen_pair = [], set()
    for i, small in enumerate(order):
        s = tests[small]
        for big in order[:i] + order[i + 1:]:
            b = tests[big]
            if len(b) < len(s) or not s <= b:
                continue
            if s == b:
                pair = frozenset((small, big))
                if pair in seen_pair:
                    continue
                seen_pair.add(pair)
                # keep the faster one as the cover; the slower one is the candidate
                cand, cover = (small, big) if sec(small) >= sec(big) else (big, small)
                out.append({"candidate": cand, "covered_by": cover, "lines": len(s),
                            "identical": True, "time_s": sec(cand)})
            else:
                out.append({"candidate": small, "covered_by": big, "lines": len(s),
                            "identical": False, "time_s": sec(small)})
            break
    out.sort(key=lambda r: (-r["time_s"], r["candidate"]))
    out = out[: a.top]
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA, "tests": len(tests),
                                                "count": len(out)}}, indent=2))
    else:
        for r in out:
            print(f"{r['time_s']:.3f}\t{r['lines']}\t{'=' if r['identical'] else '<'}\t{r['candidate']}\t{r['covered_by']}")
    err(f"{len(out)} candidate(s) among {len(tests)} tests: each needs mutant evidence before deletion")
    return 10 if out else 0


if __name__ == "__main__":
    sys.exit(main())
