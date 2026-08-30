#!/usr/bin/env python3
"""Audit a golden eval set for the rot that silently kills a regression suite.

Checks duplicates and near-duplicates, bucket balance, undated/unexplained cases,
missing expectations, and drift from a frozen manifest.

Usage:   goldenset-audit.py [OPTIONS] <GOLDEN.jsonl>
Input:   JSONL, one case per line. Recognised fields: `id`, `bucket`, `added`
         (ISO date), `why`, `input`, `expected`, `criteria`. All optional --
         a missing field becomes a finding, never a crash. `-` reads stdin.
Output:  stdout -- human-readable report, or a --json envelope
         {"data": {"findings": [...], ...}, "meta": {...}} per §4.
Stderr:  headers, progress, warnings, errors.
Exit:    0 clean, 2 usage, 3 not-found, 4 validation (unparseable/empty),
         10 FINDINGS at or above --fail-on severity

Examples:
  goldenset-audit.py evals/golden.jsonl
  goldenset-audit.py evals/golden.jsonl --json | jq '.data.findings[]'
  goldenset-audit.py evals/golden.jsonl --write-freeze manifest.json
  goldenset-audit.py evals/golden.jsonl --freeze manifest.json --fail-on warn

Offline and stdlib-only. --write-freeze is the only write, and it is atomic.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter

SCHEMA = "claude-mods.evals-ops.goldenset-audit/v1"
FREEZE_SCHEMA = "claude-mods.evals-ops.goldenset-freeze/v1"

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_VALIDATION, EXIT_FINDINGS = 0, 2, 3, 4, 10

SEVERITY_ORDER = {"info": 0, "warn": 1, "error": 2}

# Recommended shares from references/golden-datasets.md. A bucket far outside its
# band means the set has stopped testing something it was built to test.
BUCKET_BANDS = {
    "production": (0.30, 0.65),
    "replay": (0.10, 0.40),
    "adversarial": (0.08, 0.35),
    "edge": (0.05, 0.30),
}

ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")
WORD = re.compile(r"[a-z0-9]+")


def canonical(obj):
    """Stable JSON text for hashing: key order must not change a case's identity."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def case_hash(case):
    payload = {k: case.get(k) for k in ("input", "expected", "criteria") if k in case}
    if not payload:
        payload = {k: v for k, v in case.items() if k not in ("added", "why")}
    return hashlib.sha256(canonical(payload).encode("utf-8")).hexdigest()


def tokens(case):
    return set(WORD.findall(canonical(case.get("input", "")).lower()))


def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def load_cases(path):
    if path == "-":
        text = sys.stdin.read()
    else:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except FileNotFoundError:
            raise FileNotFoundError(path)
        except IsADirectoryError:
            raise ValueError(f"{path} is a directory, not a JSONL file")

    cases = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"line {lineno}: not valid JSON ({exc.msg})")
        if not isinstance(obj, dict):
            raise ValueError(f"line {lineno}: expected a JSON object")
        obj.setdefault("_line", lineno)
        cases.append(obj)
    return cases


def audit(cases, near_threshold, max_pairs):
    findings = []

    def add(severity, code, message, **details):
        findings.append(
            {"severity": severity, "code": code, "message": message, "details": details}
        )

    n = len(cases)
    ids = [c.get("id") or f"line-{c['_line']}" for c in cases]

    # --- identity -----------------------------------------------------------
    missing_id = [c["_line"] for c in cases if not c.get("id")]
    if missing_id:
        add("warn", "MISSING_ID", f"{len(missing_id)} case(s) have no 'id'",
            lines=missing_id[:20])

    dup_ids = [i for i, c in Counter(ids).items() if c > 1]
    if dup_ids:
        add("error", "DUPLICATE_ID", f"{len(dup_ids)} id(s) used more than once",
            ids=sorted(dup_ids)[:20])

    # --- exact duplicates ---------------------------------------------------
    by_hash = {}
    for cid, case in zip(ids, cases):
        by_hash.setdefault(case_hash(case), []).append(cid)
    exact = {h: members for h, members in by_hash.items() if len(members) > 1}
    if exact:
        add("error", "DUPLICATE_CASE",
            f"{len(exact)} group(s) of identical cases -- they double-weight one behaviour",
            groups=[sorted(m) for m in list(exact.values())[:10]])

    # --- near-duplicates ----------------------------------------------------
    # O(n^2) on token sets; bounded by --max-pairs so a huge set degrades to a
    # skipped check with a note, never a hang.
    near = []
    if n * (n - 1) // 2 <= max_pairs:
        toks = [tokens(c) for c in cases]
        for i in range(n):
            for j in range(i + 1, n):
                sim = jaccard(toks[i], toks[j])
                if sim >= near_threshold:
                    near.append({"a": ids[i], "b": ids[j], "similarity": round(sim, 3)})
        if near:
            add("warn", "NEAR_DUPLICATE",
                f"{len(near)} case pair(s) above {near_threshold} input similarity",
                pairs=sorted(near, key=lambda p: -p["similarity"])[:15])
    else:
        add("info", "NEAR_DUPLICATE_SKIPPED",
            f"near-duplicate scan skipped: {n} cases exceeds --max-pairs budget",
            cases=n, max_pairs=max_pairs)

    # --- completeness -------------------------------------------------------
    no_expect = [cid for cid, c in zip(ids, cases)
                 if "expected" not in c and not c.get("criteria")]
    if no_expect:
        add("error", "NO_EXPECTATION",
            f"{len(no_expect)} case(s) have neither 'expected' nor 'criteria' -- ungradeable",
            ids=no_expect[:20])

    no_why = [cid for cid, c in zip(ids, cases) if not c.get("why")]
    if no_why:
        add("warn", "NO_RATIONALE",
            f"{len(no_why)} case(s) have no 'why' -- a future maintainer cannot tell "
            "whether deleting them loses coverage",
            ids=no_why[:20])

    # --- dates --------------------------------------------------------------
    dated = [c.get("added") for c in cases
             if isinstance(c.get("added"), str) and ISO_DATE.match(c["added"])]
    undated = [cid for cid, c in zip(ids, cases)
               if not (isinstance(c.get("added"), str) and ISO_DATE.match(c.get("added", "")))]
    if undated:
        add("warn", "UNDATED",
            f"{len(undated)} case(s) have no ISO 'added' date -- staleness is undetectable",
            ids=undated[:20])
    newest = max(dated)[:10] if dated else None

    # --- bucket balance -----------------------------------------------------
    buckets = Counter(c.get("bucket") or "_unset" for c in cases)
    shares = {b: round(c / n, 4) for b, c in buckets.items()}
    if buckets.get("_unset"):
        add("warn", "NO_BUCKET",
            f"{buckets['_unset']} case(s) have no 'bucket' -- balance cannot be tracked",
            count=buckets["_unset"])
    known = [b for b in buckets if b in BUCKET_BANDS]
    if known:
        for bucket, (lo, hi) in BUCKET_BANDS.items():
            share = shares.get(bucket, 0.0)
            if share < lo:
                add("warn", "BUCKET_THIN",
                    f"bucket '{bucket}' is {share:.0%} of the set (recommended >= {lo:.0%})",
                    bucket=bucket, share=share, floor=lo)
            elif share > hi:
                add("warn", "BUCKET_HEAVY",
                    f"bucket '{bucket}' is {share:.0%} of the set (recommended <= {hi:.0%})",
                    bucket=bucket, share=share, ceiling=hi)

    # --- size ---------------------------------------------------------------
    if n < 20:
        add("warn", "TOO_SMALL",
            f"{n} cases; below ~20 a percentage moves too coarsely to interpret", cases=n)
    elif n < 100:
        add("info", "SMALL",
            f"{n} cases; 100-300 is the working range for a regression set", cases=n)

    return findings, {
        "cases": n,
        "buckets": dict(buckets),
        "bucket_shares": shares,
        "newest_added": newest,
        "dated_cases": len(dated),
        "near_duplicate_pairs": len(near),
    }


def freeze_manifest(cases):
    entries = sorted(
        ({"id": c.get("id") or f"line-{c['_line']}", "hash": case_hash(c)} for c in cases),
        key=lambda e: (e["id"], e["hash"]),
    )
    digest = hashlib.sha256(
        canonical([[e["id"], e["hash"]] for e in entries]).encode("utf-8")
    ).hexdigest()
    return {"schema": FREEZE_SCHEMA, "count": len(entries), "digest": digest, "cases": entries}


def compare_freeze(cases, manifest):
    """Diff the live set against a frozen manifest. Returns findings."""
    if not isinstance(manifest, dict) or "cases" not in manifest:
        return [{"severity": "error", "code": "FREEZE_MALFORMED",
                 "message": "freeze manifest has no 'cases' list", "details": {}}]

    # An entry with no id cannot be matched to a live case; index it by its hash so it
    # still reports as removed rather than colliding on a None key.
    frozen = {
        str(e.get("id") or f"unnamed-{e.get('hash', '?')}"): e.get("hash")
        for e in manifest["cases"]
        if isinstance(e, dict)
    }
    live = {c.get("id") or f"line-{c['_line']}": case_hash(c) for c in cases}

    added = sorted(set(live) - set(frozen))
    removed = sorted(set(frozen) - set(live))
    changed = sorted(i for i in set(live) & set(frozen) if live[i] != frozen[i])

    findings = []
    if changed:
        findings.append({
            "severity": "error", "code": "FREEZE_CASE_CHANGED",
            "message": f"{len(changed)} frozen case(s) were edited in place -- this is "
                       "fitting the test to the code; delete and re-add instead",
            "details": {"ids": changed[:20]},
        })
    if removed:
        findings.append({
            "severity": "error", "code": "FREEZE_CASE_REMOVED",
            "message": f"{len(removed)} frozen case(s) are gone -- scores are no longer "
                       "comparable to the frozen baseline",
            "details": {"ids": removed[:20]},
        })
    if added:
        findings.append({
            "severity": "warn", "code": "FREEZE_CASE_ADDED",
            "message": f"{len(added)} case(s) added since freeze -- re-baseline before "
                       "comparing scores across this boundary",
            "details": {"ids": added[:20]},
        })
    return findings


def atomic_write_json(path, payload):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def print_human(findings, stats, source):
    out = [f"golden-set audit: {source}", f"  cases           {stats['cases']}"]
    if stats["buckets"]:
        shares = ", ".join(
            f"{b} {stats['bucket_shares'][b]:.0%}" for b in sorted(stats["buckets"])
        )
        out.append(f"  buckets         {shares}")
    out.append(f"  newest added    {stats['newest_added'] or '-'}")
    out.append("")
    if not findings:
        out.append("  no findings")
    else:
        for sev in ("error", "warn", "info"):
            rows = [f for f in findings if f["severity"] == sev]
            for f in rows:
                out.append(f"  [{sev.upper():<5}] {f['code']}: {f['message']}")
    print("\n".join(out))


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="goldenset-audit.py",
        description="Audit a golden eval set for duplicates, imbalance, staleness and drift.",
    )
    parser.add_argument("golden", help="JSONL golden set, or - for stdin")
    parser.add_argument("--freeze", metavar="MANIFEST",
                        help="compare against a freeze manifest written by --write-freeze")
    parser.add_argument("--write-freeze", metavar="MANIFEST",
                        help="write a freeze manifest for this set (atomic)")
    parser.add_argument("--fail-on", choices=("error", "warn", "info"), default="error",
                        help="lowest severity that exits 10 (default: error)")
    parser.add_argument("--near-threshold", type=float, default=0.9, metavar="R",
                        help="Jaccard similarity at which two inputs are near-duplicates "
                             "(default: 0.9)")
    parser.add_argument("--max-pairs", type=int, default=200000, metavar="N",
                        help="skip the O(n^2) near-duplicate scan above this pair count "
                             "(default: 200000)")
    parser.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")

    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        raise SystemExit(exc.code)

    def fail(code, kind, message):
        if args.json:
            print(json.dumps({"error": {"code": kind, "message": message, "details": {}}}))
        print(f"goldenset-audit: {message}", file=sys.stderr)
        return code

    if not (0.0 < args.near_threshold <= 1.0):
        return fail(EXIT_USAGE, "VALIDATION", "--near-threshold must be in (0, 1]")
    if args.max_pairs < 0:
        return fail(EXIT_USAGE, "VALIDATION", "--max-pairs must not be negative")
    if args.freeze and args.write_freeze:
        return fail(EXIT_USAGE, "VALIDATION", "--freeze and --write-freeze are mutually exclusive")

    try:
        cases = load_cases(args.golden)
    except FileNotFoundError as exc:
        return fail(EXIT_NOT_FOUND, "NOT_FOUND", f"no such file: {exc}")
    except ValueError as exc:
        return fail(EXIT_VALIDATION, "VALIDATION", str(exc))

    if not cases:
        return fail(EXIT_VALIDATION, "VALIDATION", "golden set is empty")

    findings, stats = audit(cases, args.near_threshold, args.max_pairs)

    if args.freeze:
        try:
            with open(args.freeze, "r", encoding="utf-8") as fh:
                manifest = json.load(fh)
        except FileNotFoundError:
            return fail(EXIT_NOT_FOUND, "NOT_FOUND", f"no such freeze manifest: {args.freeze}")
        except json.JSONDecodeError as exc:
            return fail(EXIT_VALIDATION, "VALIDATION", f"freeze manifest is not JSON: {exc.msg}")
        findings.extend(compare_freeze(cases, manifest))

    if args.write_freeze:
        try:
            atomic_write_json(args.write_freeze, freeze_manifest(cases))
        except OSError as exc:
            return fail(EXIT_VALIDATION, "VALIDATION", f"cannot write manifest: {exc}")
        print(f"goldenset-audit: wrote freeze manifest {args.write_freeze}", file=sys.stderr)

    threshold = SEVERITY_ORDER[args.fail_on]
    triggering = [f for f in findings if SEVERITY_ORDER[f["severity"]] >= threshold]

    if args.json:
        print(json.dumps({
            "data": {"findings": findings, "stats": stats, "fail_on": args.fail_on},
            "meta": {"count": len(findings), "schema": SCHEMA, "source": args.golden},
        }, indent=2))
    else:
        print_human(findings, stats, args.golden)

    return EXIT_FINDINGS if triggering else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
