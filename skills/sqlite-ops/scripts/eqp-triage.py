#!/usr/bin/env python3
"""Triage a SQLite EXPLAIN QUERY PLAN: classify each plan line and suggest a fix.

Usage:   eqp-triage.py [--db FILE --sql SQL | --plan-file FILE | -] [OPTIONS]
Input:   argv (--db + --sql, or --plan-file), or a plan on stdin. Accepts raw
         sqlite3 CLI text, `sqlite3 -json`, or `wrangler d1 execute --json` output.
Output:  stdout - findings, one per line: SEVERITY<TAB>CATEGORY<TAB>DETAIL<TAB>FIX
         (or the claude-mods.sqlite-ops.eqp/v1 envelope under --json)
Stderr:  headers, progress, warnings, errors
Exit:    0 clean, 2 usage, 3 file-not-found, 4 invalid-input/SQL-error,
         5 missing-dep, 10 findings at or above the reporting threshold

Examples:
  eqp-triage.py --db app.db --sql "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%'"
  sqlite3 app.db 'EXPLAIN QUERY PLAN SELECT * FROM t WHERE a=1;' | eqp-triage.py
  wrangler d1 execute mydb --remote --json --command "EXPLAIN QUERY PLAN SELECT ..." | eqp-triage.py
  eqp-triage.py --db app.db --sql "SELECT ..." --json | jq '.data[]'
  eqp-triage.py --plan-file plan.txt --strict     # also fail on low-severity findings
"""

import argparse
import json
import os
import re
import sys

SCHEMA = "claude-mods.sqlite-ops.eqp/v1"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_MISSING_DEP = 5
EXIT_FINDINGS = 10

SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3}

# Rules are evaluated in order; the FIRST match wins, so the most specific
# patterns must come first. In particular COVERING INDEX must be tested before
# the bare "SCAN ... USING INDEX" rule, because a covering scan is acceptable
# while a non-covering one usually means the index is not earning its place.
RULES = [
    (
        re.compile(r"\bSEARCH\b.*\bUSING COVERING INDEX\b", re.I),
        "info", "covering-seek",
        "Seek answered entirely from the index - the table is never read. Best case.",
    ),
    (
        re.compile(r"\bSEARCH\b.*\bUSING INTEGER PRIMARY KEY\b", re.I),
        "info", "rowid-seek",
        "Direct rowid lookup. Best case.",
    ),
    (
        re.compile(r"\bSEARCH\b.*\bUSING (?:INDEX|AUTOMATIC)\b", re.I),
        "info", "index-seek",
        "B-tree seek. Fine. Consider covering the projected columns if the row is wide.",
    ),
    (
        re.compile(r"\bSCAN\b.*\bUSING COVERING INDEX\b", re.I),
        "low", "covering-scan",
        "Full pass over narrow index entries, table never read. Often the right answer "
        "for an unseekable predicate; reduces latency but usually NOT rows-read.",
    ),
    (
        re.compile(r"\bSCAN\b.*\bUSING (?:INDEX|AUTOMATIC (?:COVERING )?INDEX)\b", re.I),
        "high", "noncovering-scan",
        "Every index entry read AND a table row fetched per hit - the index buys little. "
        "Extend it to cover the projected columns (filtered column first, projected "
        "second), or drop it.",
    ),
    (
        re.compile(r"\bCORRELATED\b", re.I),
        "high", "correlated-subquery",
        "Subquery re-executed once per outer row. Rewrite as a JOIN or a windowed "
        "aggregate.",
    ),
    (
        re.compile(r"\bSCAN\b", re.I),
        "high", "table-scan",
        "Full table scan. Add an index matching the WHERE/JOIN, or - if the predicate "
        "cannot be seeked (leading-wildcard LIKE, function on the column) - make the scan "
        "covering or move to FTS5 trigram.",
    ),
    (
        re.compile(r"\bUSE TEMP B-TREE FOR (?:RIGHT PART OF )?ORDER BY\b", re.I),
        "medium", "temp-btree-order",
        "Sorting because no index supplies the order. A composite index ending in the "
        "sort column removes it. Re-check AFTER any index change - it often clears itself.",
    ),
    (
        re.compile(r"\bUSE TEMP B-TREE FOR GROUP BY\b", re.I),
        "medium", "temp-btree-group",
        "Grouping without an index supplying the order. Re-check AFTER any index change - "
        "adding a covering index frequently removes this on its own.",
    ),
    (
        re.compile(r"\bUSE TEMP B-TREE FOR DISTINCT\b", re.I),
        "medium", "temp-btree-distinct",
        "De-duplicating in a temp B-tree. An index covering the DISTINCT columns removes it.",
    ),
    (
        re.compile(r"\bUSE TEMP B-TREE\b", re.I),
        "medium", "temp-btree",
        "A temporary B-tree is being built. Check which clause needs it and whether an "
        "index can supply that order.",
    ),
]

# Informational plan lines that are never findings on their own.
BENIGN = re.compile(
    r"^\s*(QUERY PLAN|MULTI-INDEX OR|INDEX \d+|BLOOM FILTER|MATERIALIZE|CO-ROUTINE|"
    r"LIST SUBQUERY|SCALAR SUBQUERY|USING (?:ROWID SEARCH|INDEX FOR)|RIGHT-JOIN|"
    r"MERGE|LEFT-JOIN|COMPOUND QUERY|UNION|EXCEPT|INTERSECT|RECURSIVE)",
    re.I,
)

# Strip sqlite3's tree drawing and the legacy "0|0|0|" column prefix.
TREE_PREFIX = re.compile(r"^[\s|`+\-]*")
LEGACY_PREFIX = re.compile(r"^\d+\|\d+\|\d+\|")

# Vocabulary a genuine EQP line uses. Text input is filtered against this so
# that arbitrary text (a stray log, the wrong command's output) is reported as
# invalid input rather than silently triaged as "clean" - a false all-clear is
# the worst possible outcome for a tool whose job is finding problems.
PLAN_VOCAB = re.compile(
    r"\b(SCAN|SEARCH|USE TEMP B-TREE|CO-ROUTINE|SUBQUERY|MATERIALIZE|"
    r"MULTI-INDEX OR|BLOOM FILTER|COMPOUND QUERY|UNION|EXCEPT|INTERSECT|"
    r"RECURSIVE|MERGE|LEFT-JOIN|RIGHT-JOIN|USING (?:INDEX|COVERING|ROWID|"
    r"INTEGER PRIMARY KEY)|CORRELATED)\b",
    re.I,
)


def warn(message):
    """Human-facing output goes to stderr; stdout stays a clean data stream."""
    print(message, file=sys.stderr)


def collect_details(node, out):
    """Recursively pull every 'detail' string out of decoded JSON.

    Handles both `sqlite3 -json` ([{detail: ...}]) and wrangler's
    [{results: [{detail: ...}], meta: {...}}] shape without special-casing either.
    """
    if isinstance(node, dict):
        detail = node.get("detail")
        if isinstance(detail, str):
            out.append(detail)
        for value in node.values():
            collect_details(value, out)
    elif isinstance(node, list):
        for value in node:
            collect_details(value, out)


def parse_plan(text):
    """Return a list of plan detail strings from JSON or raw sqlite3 CLI text."""
    stripped = text.strip()
    if not stripped:
        return []

    if stripped[0] in "[{":
        try:
            details = []
            collect_details(json.loads(stripped), details)
            if details:
                return details
        except (ValueError, RecursionError):
            pass  # not JSON after all - fall through to text parsing

    lines = []
    for raw in stripped.splitlines():
        line = LEGACY_PREFIX.sub("", raw.strip())
        line = TREE_PREFIX.sub("", line).strip()
        if not line or line.upper() == "QUERY PLAN":
            continue
        if not PLAN_VOCAB.search(line):
            continue  # not a plan line - see PLAN_VOCAB
        lines.append(line)
    return lines


def classify(detail):
    """Return (severity, category, fix) for one plan line, or None if benign."""
    for pattern, severity, category, fix in RULES:
        if pattern.search(detail):
            return severity, category, fix
    if BENIGN.search(detail):
        return None
    return None


def run_plan(db_path, sql):
    """Run EXPLAIN QUERY PLAN against a database using Python's bundled sqlite3."""
    try:
        import sqlite3
    except ImportError:  # pragma: no cover - stdlib module absent is a broken build
        warn("error: Python's sqlite3 module is unavailable in this interpreter")
        sys.exit(EXIT_MISSING_DEP)

    if not os.path.isfile(db_path):
        warn("error: database not found: %s" % db_path)
        sys.exit(EXIT_NOT_FOUND)

    # Read-only URI: this script must never be able to modify the database it
    # is asked to analyse, even if handed a statement with side effects.
    uri = "file:%s?mode=ro" % db_path.replace("?", "%3f").replace("#", "%23")
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as exc:
        warn("error: cannot open database: %s" % exc)
        sys.exit(EXIT_VALIDATION)

    try:
        rows = conn.execute("EXPLAIN QUERY PLAN " + sql).fetchall()
    except sqlite3.Error as exc:
        warn("error: %s" % exc)
        sys.exit(EXIT_VALIDATION)
    finally:
        conn.close()

    # EQP rows are (id, parent, notused, detail); detail is always last.
    return [str(row[-1]) for row in rows]


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="eqp-triage.py",
        description="Triage a SQLite EXPLAIN QUERY PLAN and suggest fixes.",
        epilog=(
            "EXAMPLES:\n"
            "  eqp-triage.py --db app.db --sql \"SELECT * FROM t WHERE a LIKE '%x%'\"\n"
            "  sqlite3 app.db 'EXPLAIN QUERY PLAN SELECT * FROM t;' | eqp-triage.py\n"
            "  wrangler d1 execute db --remote --json --command \"EXPLAIN QUERY PLAN "
            "SELECT ...\" | eqp-triage.py\n"
            "  eqp-triage.py --db app.db --sql 'SELECT ...' --json | jq '.data[]'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("stdin_marker", nargs="?", default=None,
                        help="'-' to read the plan from stdin (the default when piped)")
    parser.add_argument("--db", help="SQLite database file to run the plan against")
    parser.add_argument("--sql", help="Statement to explain (requires --db)")
    parser.add_argument("--plan-file", help="File containing captured plan output")
    parser.add_argument("--json", action="store_true",
                        help="Emit the claude-mods.sqlite-ops.eqp/v1 envelope on stdout")
    parser.add_argument("--strict", action="store_true",
                        help="Exit 10 on low-severity findings too (default: medium+)")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress stderr headers; findings still go to stdout")

    args, extra = parser.parse_known_args(argv)
    if extra:
        parser.print_usage(sys.stderr)
        warn("error: unrecognised arguments: %s" % " ".join(extra))
        return EXIT_USAGE
    if args.stdin_marker not in (None, "-"):
        parser.print_usage(sys.stderr)
        warn("error: unexpected positional argument: %s" % args.stdin_marker)
        return EXIT_USAGE
    if args.sql and not args.db:
        warn("error: --sql requires --db")
        return EXIT_USAGE
    if args.db and not args.sql:
        warn("error: --db requires --sql")
        return EXIT_USAGE
    if args.db and args.plan_file:
        warn("error: --db/--sql and --plan-file are mutually exclusive")
        return EXIT_USAGE

    # --- acquire the plan ---
    source = None
    if args.db:
        details = run_plan(args.db, args.sql)
        source = args.db
    elif args.plan_file:
        if not os.path.isfile(args.plan_file):
            warn("error: plan file not found: %s" % args.plan_file)
            return EXIT_NOT_FOUND
        with open(args.plan_file, "r", encoding="utf-8", errors="replace") as handle:
            details = parse_plan(handle.read())
        source = args.plan_file
    else:
        if sys.stdin is None or sys.stdin.isatty():
            parser.print_usage(sys.stderr)
            warn("error: no input - pass --db/--sql, --plan-file, or pipe a plan on stdin")
            return EXIT_USAGE
        details = parse_plan(sys.stdin.read())
        source = "stdin"

    if not details:
        warn("error: no EXPLAIN QUERY PLAN lines found in input from %s" % source)
        return EXIT_VALIDATION

    # --- classify ---
    findings = []
    for detail in details:
        verdict = classify(detail)
        if verdict is None:
            continue
        severity, category, fix = verdict
        findings.append({
            "severity": severity,
            "category": category,
            "detail": detail,
            "fix": fix,
        })

    findings.sort(key=lambda f: -SEVERITY_ORDER[f["severity"]])
    threshold = SEVERITY_ORDER["low" if args.strict else "medium"]
    actionable = [f for f in findings if SEVERITY_ORDER[f["severity"]] >= threshold]

    # --- report ---
    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {
                "count": len(findings),
                "actionable": len(actionable),
                "plan_lines": len(details),
                "source": source,
                "threshold": "low" if args.strict else "medium",
                "schema": SCHEMA,
            },
        }, indent=2))
    else:
        if not args.quiet:
            warn("eqp-triage  %d plan line(s) from %s" % (len(details), source))
        for finding in findings:
            print("%s\t%s\t%s\t%s" % (
                finding["severity"].upper(), finding["category"],
                finding["detail"], finding["fix"]))
        if not args.quiet:
            if actionable:
                warn("  %d actionable finding(s) at or above %s severity"
                     % (len(actionable), "low" if args.strict else "medium"))
            else:
                warn("  no actionable findings")

    return EXIT_FINDINGS if actionable else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
