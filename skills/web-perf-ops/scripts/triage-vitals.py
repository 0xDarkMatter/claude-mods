#!/usr/bin/env python3
"""Rate a Lighthouse, PageSpeed Insights or CrUX API report against the Core Web
Vitals thresholds and name the reference to open next.

This is the measurement -> fix bridge: it reads whichever report you have, puts
field and lab numbers side by side (field first - it is what users felt), rates
each at the documented thresholds, prints the field LCP subparts when CrUX has
them, and lists lab audits that claim metric savings. Every row names the
web-perf-ops reference that holds the fix.

Input shapes (auto-detected from the top-level keys):
  * Lighthouse JSON (`lighthouse <url> --output=json`): has `lighthouseVersion` + `audits`
  * PSI API v5 response: has `lighthouseResult` and/or `loadingExperience`
      (field CLS arrives x100 as an integer: 5 means 0.05)
  * CrUX API `records:queryRecord` response: has `record.metrics`
      (CLS p75 arrives as a 2-decimal STRING: "0.05")
  * CrUX History API response: same, with `percentilesTimeseries`; the latest
      non-null p75 is used

Thresholds come from assets/web-perf-facts.json - never hardcoded here - so the
verifier (check-web-perf-facts.py) guards one copy of every number.

Usage:   triage-vitals.py REPORT.json [--catalog FILE] [--json] [--limit N] [-q]
         triage-vitals.py - < report.json
Input:   one JSON report path, or `-` for stdin.
Output:  stdout = TSV rows: source, metric, value, rating, next-reference
         (or a --json envelope). Data only.
Stderr:  the verdict line, notices (e.g. retired FID data ignored), errors.
Exit:    0 every rated metric is good, 2 usage, 3 report/catalog missing,
         4 unparseable or unrecognised report shape,
         10 at least one metric rated needs-improvement or poor (a finding)

Examples:
  triage-vitals.py psi.json
  curl -s "https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=$URL&key=$KEY" | triage-vitals.py -
  triage-vitals.py crux.json --json | jq '.data[] | select(.rating != "good")'
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import NoReturn

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_FINDING = 10

SCHEMA = "claude-mods.web-perf-ops.triage/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "web-perf-facts.json"

# Where the fix lives for each metric. TBT is Lighthouse's lab proxy for INP:
# no lab tool can measure INP on a cold load because nobody is interacting.
NEXT = {
    "LCP": "references/lcp.md",
    "INP": "references/inp.md",
    "TBT": "references/inp.md",
    "CLS": "references/cls.md",
    "FCP": "references/css.md",
    "TTFB": "references/caching-cdn.md",
}
# Lab audits route by keyword in the audit id, first match wins. Substrings, not
# exact ids, because Lighthouse renames ids across majors (13 replaced e.g.
# `uses-responsive-images` with `image-delivery-insight`) and LHCI still runs 12;
# both generations contain these words. No match -> route by the metric saved.
AUDIT_KEYWORDS = (
    ("image", "references/images.md"),
    ("font", "references/fonts.md"),
    ("third-part", "references/javascript.md"),
    ("javascript", "references/javascript.md"),
    ("bootup", "references/javascript.md"),
    ("mainthread", "references/javascript.md"),
    ("render-blocking", "references/css.md"),
    ("css", "references/css.md"),
    ("cache", "references/caching-cdn.md"),
    ("document-latency", "references/caching-cdn.md"),
    ("server-response", "references/caching-cdn.md"),
    ("redirect", "references/caching-cdn.md"),
    ("compression", "references/caching-cdn.md"),
    ("modern-http", "references/caching-cdn.md"),
    ("cls", "references/cls.md"),
    ("unsized", "references/cls.md"),
    ("lcp", "references/lcp.md"),
    ("inp", "references/inp.md"),
)
LAB_AUDITS = {  # Lighthouse metric audit id -> metric
    "largest-contentful-paint": "LCP",
    "cumulative-layout-shift": "CLS",
    "total-blocking-time": "TBT",
    "first-contentful-paint": "FCP",
    "interaction-to-next-paint": "INP",  # timespan mode only
}
PSI_KEYS = {
    "LARGEST_CONTENTFUL_PAINT_MS": "LCP",
    "INTERACTION_TO_NEXT_PAINT": "INP",
    "CUMULATIVE_LAYOUT_SHIFT_SCORE": "CLS",
    "FIRST_CONTENTFUL_PAINT_MS": "FCP",
    "EXPERIMENTAL_TIME_TO_FIRST_BYTE": "TTFB",
}
CRUX_KEYS = {
    "largest_contentful_paint": "LCP",
    "interaction_to_next_paint": "INP",
    "cumulative_layout_shift": "CLS",
    "first_contentful_paint": "FCP",
    "experimental_time_to_first_byte": "TTFB",
}
# CrUX field LCP subparts (image LCPs only). The dominant one names the fix.
CRUX_LCP_SUBPARTS = {
    "largest_contentful_paint_image_time_to_first_byte": "TTFB",
    "largest_contentful_paint_image_resource_load_delay": "load delay",
    "largest_contentful_paint_image_resource_load_duration": "load duration",
    "largest_contentful_paint_image_element_render_delay": "render delay",
}


def die(code: int, msg: str) -> NoReturn:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_json(src: str) -> dict:
    try:
        if src == "-":
            return json.load(sys.stdin)
        path = Path(src)
        if not path.is_file():
            die(EX_NOTFOUND, f"report not found: {src}")
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        die(EX_UNPARSEABLE, f"report is not valid JSON: {exc}")


def rate(metric: str, value: float, thresholds: dict) -> str:
    t = thresholds[metric]
    if value <= t["good"]:
        return "good"
    return "needs-improvement" if value <= t["poor"] else "poor"


def fmt(metric: str, value: float) -> str:
    if metric == "CLS":
        return f"{value:.2f}"
    return f"{value / 1000:.2f} s" if value >= 1000 else f"{round(value)} ms"


def row(source: str, metric: str, value: float, thresholds: dict) -> dict:
    return {"source": source, "metric": metric, "value": round(value, 3),
            "display": fmt(metric, value), "rating": rate(metric, value, thresholds),
            "next": NEXT[metric]}


def from_psi_field(block: dict, source: str, thresholds: dict) -> list[dict]:
    rows = []
    if block.get("origin_fallback"):
        source += "(origin-fallback)"
    for key, metric in PSI_KEYS.items():
        m = (block.get("metrics") or {}).get(key)
        if not m or m.get("percentile") is None:
            continue
        v = float(m["percentile"])
        rows.append(row(source, metric, v / 100 if metric == "CLS" else v, thresholds))
    if "FIRST_INPUT_DELAY_MS" in (block.get("metrics") or {}):
        print("notice: ignored FIRST_INPUT_DELAY_MS - FID was retired for INP on 2024-03-12",
              file=sys.stderr)
    return rows


def _p75(metric: dict) -> float | None:
    p = metric.get("percentiles") or {}
    if "p75" in p and p["p75"] is not None:
        return float(p["p75"])  # CLS arrives as a string: float() handles both
    series = (metric.get("percentilesTimeseries") or {}).get("p75s") or []
    live = [s for s in series if s is not None]
    return float(live[-1]) if live else None


def from_crux(record: dict, thresholds: dict) -> list[dict]:
    rows = []
    metrics = record.get("metrics") or {}
    key = record.get("key") or {}
    scope = "url" if "url" in key else "origin"
    for k, metric in CRUX_KEYS.items():
        if k in metrics:
            v = _p75(metrics[k])
            if v is not None:
                rows.append(row(f"field:crux-{scope}", metric, v, thresholds))
    parts = {label: _p75(metrics[k]) for k, label in CRUX_LCP_SUBPARTS.items() if k in metrics}
    parts = {k: v for k, v in parts.items() if v is not None}
    if parts:
        worst = max(parts, key=lambda k: parts[k])
        for label, v in parts.items():
            rows.append({"source": f"field:crux-{scope}", "metric": f"LCP subpart: {label}",
                         "value": round(v, 1), "display": fmt("LCP", v),
                         "rating": "dominant" if label == worst else "info",
                         "next": "references/lcp.md"})
    return rows


def from_lighthouse(lhr: dict, thresholds: dict, limit: int) -> list[dict]:
    rows = []
    audits = lhr.get("audits") or {}
    for audit_id, metric in LAB_AUDITS.items():
        a = audits.get(audit_id)
        if a and isinstance(a.get("numericValue"), (int, float)):
            rows.append(row("lab:lighthouse", metric, float(a["numericValue"]), thresholds))
    # Audits that claim savings against a metric. `metricSavings` is how current
    # Lighthouse attributes an audit to LCP/FCP/CLS/TBT/INP, so this needs no
    # hardcoded audit-id list (ids get renamed across majors; savings do not).
    opps = []
    for audit_id, a in audits.items():
        savings = a.get("metricSavings") or {}
        score = a.get("score")
        if score is None or score >= 0.9 or not isinstance(savings, dict):
            continue
        hits = {m: v for m, v in savings.items() if isinstance(v, (int, float)) and v > 0 and m in NEXT}
        if hits:
            top = max(hits, key=lambda k: hits[k])
            opps.append((hits[top], audit_id, hits, top))
    for _, audit_id, hits, top in sorted(opps, reverse=True)[:limit]:
        detail = "; ".join(f"{m} -{fmt(m, v)}" for m, v in sorted(hits.items(), key=lambda kv: -kv[1]))
        nxt = next((ref for kw, ref in AUDIT_KEYWORDS if kw in audit_id), NEXT[top])
        rows.append({"source": "lab:audit", "metric": audit_id, "value": hits[top],
                     "display": detail, "rating": "opportunity", "next": nxt})
    return rows


def triage(report: dict, thresholds: dict, limit: int) -> list[dict]:
    rows: list[dict] = []
    if "record" in report and isinstance(report["record"], dict):
        rows += from_crux(report["record"], thresholds)
    if "loadingExperience" in report or "lighthouseResult" in report:
        if report.get("loadingExperience"):
            rows += from_psi_field(report["loadingExperience"], "field:psi-url", thresholds)
        if report.get("originLoadingExperience"):
            rows += from_psi_field(report["originLoadingExperience"], "field:psi-origin", thresholds)
        if report.get("lighthouseResult"):
            rows += from_lighthouse(report["lighthouseResult"], thresholds, limit)
    elif "audits" in report and "lighthouseVersion" in report:
        rows += from_lighthouse(report, thresholds, limit)
    if not rows and not any(k in report for k in ("record", "loadingExperience", "lighthouseResult", "audits")):
        die(EX_UNPARSEABLE, "unrecognised report: expected a Lighthouse, PSI or CrUX API JSON")
    return rows


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="triage-vitals.py",
        description="Rate a Lighthouse / PSI / CrUX report at the Core Web Vitals thresholds; name the fix reference.",
        epilog=(
            "Examples:\n"
            "  triage-vitals.py psi.json\n"
            "  triage-vitals.py - < crux.json\n"
            "  triage-vitals.py lhr.json --json | jq '.data[] | select(.rating != \"good\")'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("report", help="report JSON path, or - for stdin")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON (thresholds)")
    p.add_argument("--limit", type=int, default=8, help="max lab audits listed (default 8)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    if args.limit < 0:
        print("error: --limit must be >= 0", file=sys.stderr)
        return EX_USAGE

    cat_path = Path(args.catalog)
    if not cat_path.is_file():
        die(EX_NOTFOUND, f"facts catalog not found: {cat_path}")
    try:
        thresholds = json.loads(cat_path.read_text(encoding="utf-8"))["thresholds"]
    except (json.JSONDecodeError, KeyError) as exc:
        die(EX_UNPARSEABLE, f"catalog unreadable: {exc}")

    report = load_json(args.report)
    if not isinstance(report, dict):
        die(EX_UNPARSEABLE, "report must be a JSON object")
    rows = triage(report, thresholds, args.limit)
    rated = [r for r in rows if r["rating"] in ("good", "needs-improvement", "poor")]
    failing = [r for r in rated if r["rating"] != "good"]

    if args.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "failing": len(failing),
                                                  "schema": SCHEMA}}, indent=2))
    else:
        for r in rows:
            print(f"{r['source']}\t{r['metric']}\t{r['display']}\t{r['rating']}\t{r['next']}")

    if not args.quiet:
        verdict = f"{len(failing)} metric(s) need work" if failing else "all rated metrics good"
        if not rated:
            verdict = "no rateable metrics in report (no CrUX data for this URL?)"
        print(f"triage-vitals: {verdict} ({len(rows)} rows)", file=sys.stderr)
    return EX_FINDING if failing else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
