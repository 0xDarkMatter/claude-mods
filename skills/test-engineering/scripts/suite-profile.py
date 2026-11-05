#!/usr/bin/env python3
"""Profile a test suite from JUnit XML: time, slowest tests, flakes, before/after.

Usage:   suite-profile.py profile <junit.xml|dir>... [--top N] [--json]
         suite-profile.py flakes  <run>... [--json]       (each <run> is a file or a dir of XML)
         suite-profile.py compare <before.json> <after.json> [--json|--markdown]
Input:   JUnit XML from any runner (pytest --junitxml, vitest/jest junit reporters,
         phpunit/pest --log-junit, gotestsum --junitfile, cargo nextest's junit profile,
         playwright's junit reporter). Several files in one `profile` call are shards of ONE
         run and are merged. `compare` reads two `profile --json` outputs.
Output:  `profile --json` is the profile document `compare` and budget-gate.py read
         (schema claude-mods.test-engineering.suite-profile/v1). Without --json, a TSV
         summary. `compare --markdown` prints the before/after report section.
Stderr:  warnings (unparseable files, testcases with no time), errors.
Exit:    0 ok, 2 usage, 3 no input file found, 4 invalid XML or JSON,
         10 (flakes only) at least one test is flaky, or a run reported fewer tests than
         the fullest run (incomplete: a crashed runner is no evidence, never green).

Time is summed over <testcase> elements, never read from <testsuite time=...>: runners
nest suites (phpunit puts a file suite inside a run suite), so suite times double-count.
A testcase with <flakyFailure>/<rerunFailure> children (nextest, surefire-style rerun
reporters) passed only on retry: that is flaky, not green (references/triage.md).
Expat (Python 3.7.1+) refuses entity-expansion bombs, so untrusted XML is safe to parse.

Examples:
  pytest -p no:cacheprovider --junitxml=/tmp/r.xml && suite-profile.py profile /tmp/r.xml
  suite-profile.py profile reports/ --top 20 --json > before.json
  suite-profile.py flakes run1.xml run2.xml run3.xml
  suite-profile.py compare before.json after.json --markdown >> report.md
"""
import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

SCHEMA = "claude-mods.test-engineering.suite-profile/v1"


def err(msg):
    print(f"suite-profile: {msg}", file=sys.stderr)


def expand(paths):
    """Files as given, directories as their *.xml files (sorted, non-recursive)."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(os.path.join(p, f) for f in os.listdir(p) if f.lower().endswith(".xml"))
        elif os.path.isfile(p):
            out.append(p)
        else:
            err(f"not found: {p}")
            sys.exit(3)
    if not out:
        err("no JUnit XML files in the input")
        sys.exit(3)
    return out


def outcome_of(tc):
    tags = {child.tag for child in tc}
    if "failure" in tags:
        return "failed"
    if "error" in tags:
        return "error"
    if "skipped" in tags:
        return "skipped"
    return "passed"


def parse_file(path):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        err(f"invalid XML in {path}: {e}")
        sys.exit(4)
    tests = []
    # Walk with the nearest enclosing suite's file attribute, so phpunit's per-file suites
    # name the file even when a testcase omits it.
    def walk(node, suite_file):
        for child in node:
            if child.tag in ("testsuite", "testsuites"):
                walk(child, child.get("file") or suite_file)
            elif child.tag == "testcase":
                name = child.get("name", "")
                cls = child.get("classname") or child.get("class") or ""
                # Pest writes "tests/X.php::test name" into file=; keep the path only.
                f = (child.get("file") or suite_file or cls).split("::")[0]
                raw = child.get("time")
                try:
                    t = float(raw) if raw not in (None, "") else 0.0
                except ValueError:
                    t = 0.0
                retries = sum(1 for c in child if c.tag in ("flakyFailure", "flakyError",
                                                            "rerunFailure", "rerunError"))
                tests.append({
                    "id": f"{cls}::{name}" if cls else name,
                    "file": f,
                    "name": name,
                    "time_s": round(t, 6),
                    "outcome": outcome_of(child),
                    "retried": retries,
                })
    # The root is <testsuites> (most runners) or a bare <testsuite> (older jest-junit, some
    # go converters): wrap it, so walk() always starts one level above the first suite.
    wrapper = ET.Element("wrap")
    wrapper.append(root)
    walk(wrapper, None)
    return tests


def build_profile(files, top):
    tests = []
    for f in files:
        tests += parse_file(f)
    by_file = {}
    for t in tests:
        agg = by_file.setdefault(t["file"], {"file": t["file"], "tests": 0, "time_s": 0.0})
        agg["tests"] += 1
        agg["time_s"] += t["time_s"]
    files_out = sorted(by_file.values(), key=lambda a: -a["time_s"])
    for a in files_out:
        a["time_s"] = round(a["time_s"], 3)
    counts = {k: 0 for k in ("passed", "failed", "error", "skipped")}
    for t in tests:
        counts[t["outcome"]] += 1
    total = round(sum(t["time_s"] for t in tests), 3)
    slowest = sorted(tests, key=lambda t: -t["time_s"])[:top]
    flaky = [t["id"] for t in tests if t["retried"] and t["outcome"] == "passed"]
    return {
        "totals": {"tests": len(tests), **counts, "time_s": total, "flaky": len(flaky)},
        "files": files_out,
        "slowest": slowest,
        "flaky": flaky,
        "tests": tests,
    }


def cmd_profile(a):
    prof = build_profile(expand(a.inputs), a.top)
    if prof["totals"]["tests"] == 0:
        err("the report holds no testcases: the runner crashed before reporting, or selection ran "
            "nothing. An empty report is not a green run.")
    if a.json:
        print(json.dumps({"data": prof, "meta": {"schema": SCHEMA, "inputs": len(expand(a.inputs))}}, indent=2))
        return 0
    t = prof["totals"]
    print(f"tests\t{t['tests']}\npassed\t{t['passed']}\nfailed\t{t['failed']}\nerror\t{t['error']}"
          f"\nskipped\t{t['skipped']}\nflaky\t{t['flaky']}\ntime_s\t{t['time_s']}")
    print("# slowest tests (time_s, id)")
    for s in prof["slowest"]:
        print(f"{s['time_s']:.3f}\t{s['id']}")
    print("# slowest files (time_s, tests, file)")
    for f in prof["files"][: a.top]:
        print(f"{f['time_s']:.3f}\t{f['tests']}\t{f['file']}")
    return 0


def cmd_flakes(a):
    runs, counts = [], []
    for r in a.runs:
        outcomes = {}
        for t in build_profile(expand([r]), 0)["tests"]:
            outcomes[t["id"]] = "retried" if t["retried"] and t["outcome"] == "passed" else t["outcome"]
        runs.append(outcomes)
        counts.append(len(outcomes))
    # A run that reported fewer tests than the fullest one crashed or dropped files: it is no
    # evidence either way, and an empty report must never read as a green run.
    incomplete = [{"run": r, "tests": c, "expected": max(counts)}
                  for r, c in zip(a.runs, counts) if c < max(counts)]
    for i in incomplete:
        err(f"incomplete run: {i['run']} reported {i['tests']} of {i['expected']} tests (crashed runner?)")
    ids = sorted(set().union(*runs))
    flaky = []
    for i in ids:
        seen = [run.get(i) for run in runs if run.get(i) not in (None, "skipped")]
        fails = sum(1 for o in seen if o in ("failed", "error"))
        retried = sum(1 for o in seen if o == "retried")
        # Red in every run is a real failure, not a flake; a pass-on-retry anywhere is a flake.
        if retried or (0 < fails < len(seen)):
            flaky.append({"id": i, "runs": len(seen), "failed": fails, "passed_on_retry": retried})
    if a.json:
        print(json.dumps({"data": flaky, "meta": {"schema": SCHEMA.replace("suite-profile", "flakes"),
                                                  "runs": len(runs), "count": len(flaky),
                                                  "incomplete_runs": incomplete}}, indent=2))
    else:
        for f in flaky:
            print(f"{f['failed']}/{f['runs']}\t{f['passed_on_retry']}\t{f['id']}")
    return 10 if flaky or incomplete else 0


def load_profile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc["data"]
    except FileNotFoundError:
        err(f"not found: {path}")
        sys.exit(3)
    except (ValueError, KeyError, TypeError) as e:
        err(f"not a suite-profile --json document: {path} ({e})")
        sys.exit(4)


def cmd_compare(a):
    b, c = load_profile(a.before), load_profile(a.after)
    bt, ct = b["totals"], c["totals"]
    bids = {t["id"] for t in b["tests"]}
    cids = {t["id"] for t in c["tests"]}
    saved = round(bt["time_s"] - ct["time_s"], 3)
    out = {
        "before": bt, "after": ct,
        "time_saved_s": saved,
        "time_saved_pct": round(100 * saved / bt["time_s"], 1) if bt["time_s"] else 0.0,
        "removed": sorted(bids - cids),
        "added": sorted(cids - bids),
    }
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA.replace("suite-profile", "compare")}}, indent=2))
        return 0
    print("| | Before | After |\n|---|---|---|")
    for k in ("tests", "failed", "skipped", "flaky", "time_s"):
        print(f"| {k} | {bt[k]} | {ct[k]} |")
    print(f"\nSuite time saved: **{saved} s ({out['time_saved_pct']}%)**. "
          f"Tests removed: {len(out['removed'])}, added: {len(out['added'])}.")
    if out["removed"]:
        print("\nRemoved (each needs its evidence row in the prune report):")
        for i in out["removed"]:
            print(f"- `{i}`")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("profile", help="one run (shards merged)")
    pp.add_argument("inputs", nargs="+")
    pp.add_argument("--top", type=int, default=10)
    pp.add_argument("--json", action="store_true")
    pf = sub.add_parser("flakes", help="several runs of the same suite")
    pf.add_argument("runs", nargs="+")
    pf.add_argument("--json", action="store_true")
    pc = sub.add_parser("compare", help="before/after profiles")
    pc.add_argument("before")
    pc.add_argument("after")
    g = pc.add_mutually_exclusive_group()
    g.add_argument("--json", action="store_true")
    g.add_argument("--markdown", action="store_true")
    a = p.parse_args()
    if a.cmd == "profile" and a.top < 0:
        p.error("--top must be >= 0")
    return {"profile": cmd_profile, "flakes": cmd_flakes, "compare": cmd_compare}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
