#!/usr/bin/env python3
"""Measure an LLM judge against human labels: Cohen kappa, confusion, bias probes.

Usage:   judge-calibration.py [OPTIONS] <LABELS.jsonl>
Input:   JSONL, one record per case. Required fields: `human`, `judge` (any
         hashable label -- "pass"/"fail", true/false, 1-5). Optional: `id`,
         `length` (or --verbosity-field NAME) for the verbosity-bias probe,
         and `position` ("first"/"second") for the position-bias probe.
         Use `-` to read the JSONL from stdin.
Output:  stdout -- human-readable report, or a --json envelope
         {"data": {...}, "meta": {...}} per SKILL-RESOURCE-PROTOCOL.md §4.
Stderr:  headers, progress, warnings, errors.
Exit:    0 calibrated (kappa >= --min-kappa), 2 usage, 3 not-found,
         4 validation (unparseable/empty/missing fields),
         10 UNDER-CALIBRATED (ran fine, kappa below threshold)

Examples:
  judge-calibration.py labels.jsonl
  judge-calibration.py labels.jsonl --min-kappa 0.8
  judge-calibration.py labels.jsonl --json | jq '.data.kappa'
  judge-calibration.py labels.jsonl --verbosity-field output_chars
  cat labels.jsonl | judge-calibration.py - --json

Offline and stdlib-only: this scores labels you already have, it never calls a model.
"""

import argparse
import json
import sys
from collections import Counter, defaultdict

SCHEMA = "claude-mods.evals-ops.judge-calibration/v1"

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_VALIDATION, EXIT_UNDER = 0, 2, 3, 4, 10

# Landis & Koch style bands, as used for judge calibration in practice.
# < 0.6 means the RUBRIC needs work, not the judge model -- see references/llm-judge.md.
BANDS = [
    (0.80, "strong", "production-ready; safe to gate on with a margin"),
    (0.60, "substantial", "usable; keep advisory or gate loosely"),
    (0.40, "moderate", "rubric needs work before this gates anything"),
    (0.20, "fair", "rubric is the problem, not the model"),
    (float("-inf"), "poor", "no better than chance; rewrite the rubric"),
]


def norm(value):
    """Normalise a label to a comparable string. true/1/'PASS' must all agree."""
    if isinstance(value, bool):
        return "pass" if value else "fail"
    if isinstance(value, str):
        return value.strip().lower()
    return str(value)


def cohens_kappa(pairs):
    """Cohen kappa for two raters over nominal labels. Returns None if undefined."""
    n = len(pairs)
    if n == 0:
        return None
    observed = sum(1 for a, b in pairs if a == b) / n
    a_counts, b_counts = Counter(a for a, _ in pairs), Counter(b for _, b in pairs)
    expected = sum((a_counts[k] / n) * (b_counts.get(k, 0) / n) for k in a_counts)
    if expected >= 1.0:
        # Both raters used a single identical label: agreement is total but chance-
        # corrected agreement is undefined (0/0). Report it rather than dividing.
        return None
    return (observed - expected) / (1.0 - expected)


def pearson(xs, ys):
    """Pearson correlation. Returns None when a series has no variance."""
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / ((sxx**0.5) * (syy**0.5))


def band_for(kappa):
    for floor, name, advice in BANDS:
        if kappa >= floor:
            return name, advice
    return "poor", "rewrite the rubric"


def load_records(path):
    """Read JSONL from a path or stdin. Raises ValueError with a line number."""
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

    records = []
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
        records.append((lineno, obj))
    return records


def analyse(records, verbosity_field):
    pairs, ids, skipped = [], [], []
    lengths, judge_numeric = [], []
    position_rows = defaultdict(list)

    for lineno, obj in records:
        if "human" not in obj or "judge" not in obj:
            skipped.append({"line": lineno, "reason": "missing 'human' or 'judge'"})
            continue
        h, j = norm(obj["human"]), norm(obj["judge"])
        pairs.append((h, j))
        ids.append(obj.get("id", f"line-{lineno}"))

        # Verbosity probe: does judge score track output length among cases the
        # HUMAN scored identically? Correlation there is bias, not signal.
        length = obj.get(verbosity_field)
        jn = obj["judge"]
        # bool is a subclass of int in Python, so a `true` in the length field
        # would silently read as 1.0 and yield a confident, meaningless
        # correlation. A length is never a boolean -- reject it explicitly.
        if isinstance(length, bool):
            length = None
        if isinstance(length, (int, float)) and isinstance(jn, (int, float, bool)):
            lengths.append(float(length))
            judge_numeric.append(float(jn))

        pos = obj.get("position")
        if isinstance(pos, str):
            position_rows[pos.strip().lower()].append(1 if h == j else 0)

    return pairs, ids, skipped, lengths, judge_numeric, position_rows


def build_report(pairs, ids, skipped, lengths, judge_numeric, position_rows, min_kappa):
    n = len(pairs)
    agreement = sum(1 for a, b in pairs if a == b) / n
    kappa = cohens_kappa(pairs)

    confusion = Counter(pairs)
    labels = sorted({lab for pair in pairs for lab in pair})

    disagreements = [
        {"id": cid, "human": h, "judge": j}
        for cid, (h, j) in zip(ids, pairs)
        if h != j
    ]

    # Per-class recall from the human's point of view: where does the judge go wrong?
    # A judge that only ever under-passes is safe to gate on; one that over-passes is not.
    per_class = {}
    for lab in labels:
        total = sum(c for (h, _), c in confusion.items() if h == lab)
        hit = confusion.get((lab, lab), 0)
        per_class[lab] = {
            "human_count": total,
            "judge_agreed": hit,
            "recall": round(hit / total, 4) if total else None,
        }

    verbosity_r = pearson(lengths, judge_numeric)
    position = {
        pos: {"n": len(v), "agreement": round(sum(v) / len(v), 4)}
        for pos, v in position_rows.items()
        if v
    }

    if kappa is None:
        band, advice, calibrated = "undefined", (
            "every case shares one label -- kappa is undefined; "
            "stratify the calibration sample across the judge's own verdicts"
        ), False
    else:
        band, advice = band_for(kappa)
        calibrated = kappa >= min_kappa

    warnings = []
    if n < 50:
        warnings.append(
            f"only {n} labelled cases; 50-200 is the recommended range for a "
            "meaningful kappa"
        )
    if len(labels) < 2:
        warnings.append("only one distinct label present -- the sample is not stratified")
    if verbosity_r is not None and abs(verbosity_r) >= 0.4:
        warnings.append(
            f"verbosity probe: judge score correlates {verbosity_r:+.2f} with output "
            "length -- separate correctness from style in the rubric"
        )
    if len(position) >= 2:
        vals = [v["agreement"] for v in position.values()]
        if max(vals) - min(vals) >= 0.1:
            warnings.append(
                "position probe: agreement differs by "
                f"{max(vals) - min(vals):.2f} across presentation positions -- "
                "run both orders and average, or score absolutely"
            )
    if skipped:
        warnings.append(f"{len(skipped)} record(s) skipped (missing required fields)")

    return {
        "n": n,
        "kappa": round(kappa, 4) if kappa is not None else None,
        "band": band,
        "advice": advice,
        "raw_agreement": round(agreement, 4),
        "min_kappa": min_kappa,
        "calibrated": calibrated,
        "labels": labels,
        "confusion": [
            {"human": h, "judge": j, "count": c} for (h, j), c in sorted(confusion.items())
        ],
        "per_class": per_class,
        "disagreements": disagreements,
        "probes": {
            "verbosity_correlation": round(verbosity_r, 4) if verbosity_r is not None else None,
            "position_agreement": position,
        },
        "skipped": skipped,
        "warnings": warnings,
    }


def print_human(report, source):
    out = []
    out.append(f"judge calibration: {source}")
    out.append(f"  cases           {report['n']}")
    kappa = report["kappa"]
    out.append(
        f"  cohen kappa     {kappa if kappa is not None else 'undefined'}  "
        f"({report['band']})"
    )
    out.append(f"  raw agreement   {report['raw_agreement']}  (kappa is the honest one)")
    out.append(f"  threshold       {report['min_kappa']}")
    out.append("")
    out.append("  confusion (human -> judge)")
    for row in report["confusion"]:
        mark = " " if row["human"] == row["judge"] else "!"
        out.append(f"    {mark} {row['human']:>12} -> {row['judge']:<12} {row['count']}")
    out.append("")
    out.append("  per human class")
    for lab, stats in report["per_class"].items():
        recall = stats["recall"]
        out.append(
            f"    {lab:>12}  n={stats['human_count']:<4} "
            f"agreed={stats['judge_agreed']:<4} recall={recall if recall is not None else '-'}"
        )
    probes = report["probes"]
    if probes["verbosity_correlation"] is not None or probes["position_agreement"]:
        out.append("")
        out.append("  bias probes")
        if probes["verbosity_correlation"] is not None:
            out.append(f"    verbosity r     {probes['verbosity_correlation']:+.4f}")
        for pos, stats in probes["position_agreement"].items():
            out.append(f"    position {pos:<8} n={stats['n']:<4} agreement={stats['agreement']}")
    if report["disagreements"]:
        out.append("")
        out.append(f"  disagreements ({len(report['disagreements'])})")
        for d in report["disagreements"][:20]:
            out.append(f"    {d['id']}: human={d['human']} judge={d['judge']}")
        if len(report["disagreements"]) > 20:
            out.append(f"    ... {len(report['disagreements']) - 20} more")
    out.append("")
    out.append(f"  verdict         {report['advice']}")
    print("\n".join(out))


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="judge-calibration.py",
        description="Cohen kappa and bias probes for an LLM judge vs human labels.",
        add_help=True,
    )
    parser.add_argument("labels", help="JSONL of {human, judge, ...} records, or - for stdin")
    parser.add_argument(
        "--min-kappa", type=float, default=0.6,
        help="kappa at or above which the judge counts as calibrated (default: 0.6)",
    )
    parser.add_argument(
        "--verbosity-field", default="length", metavar="NAME",
        help="numeric field carrying output length for the verbosity probe (default: length)",
    )
    parser.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")

    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        # argparse exits 2 on bad args and 0 on --help; both already match the protocol.
        raise SystemExit(exc.code)

    if not (0.0 <= args.min_kappa <= 1.0):
        print("judge-calibration: --min-kappa must be between 0 and 1", file=sys.stderr)
        return EXIT_USAGE

    def fail(code, kind, message):
        if args.json:
            print(json.dumps({"error": {"code": kind, "message": message, "details": {}}}))
        print(f"judge-calibration: {message}", file=sys.stderr)
        return code

    try:
        records = load_records(args.labels)
    except FileNotFoundError as exc:
        return fail(EXIT_NOT_FOUND, "NOT_FOUND", f"no such file: {exc}")
    except ValueError as exc:
        return fail(EXIT_VALIDATION, "VALIDATION", str(exc))

    pairs, ids, skipped, lengths, judge_numeric, position_rows = analyse(
        records, args.verbosity_field
    )
    if not pairs:
        return fail(
            EXIT_VALIDATION, "VALIDATION",
            "no usable records (every line missing 'human' or 'judge')",
        )

    report = build_report(
        pairs, ids, skipped, lengths, judge_numeric, position_rows, args.min_kappa
    )

    if args.json:
        print(json.dumps({
            "data": report,
            "meta": {"count": report["n"], "schema": SCHEMA, "source": args.labels},
        }, indent=2))
    else:
        print_human(report, args.labels)

    for warning in report["warnings"]:
        print(f"judge-calibration: warning: {warning}", file=sys.stderr)

    return EXIT_OK if report["calibrated"] else EXIT_UNDER


if __name__ == "__main__":
    sys.exit(main())
