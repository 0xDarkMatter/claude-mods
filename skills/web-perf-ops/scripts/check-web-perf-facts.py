#!/usr/bin/env python3
"""Staleness verifier for web-perf-ops: the Core Web Vitals thresholds, the
FID-to-INP retirement, and the named tooling majors must stay stated and current.

web-perf-ops rates every measurement against a threshold table. If Google moves
a threshold, retires a metric (FID became INP on 2024-03-12) or a tool ships a
major that renames its audits (Lighthouse does this), an agent rating a page
against stale numbers is confidently wrong (SKILL-RESOURCE-PROTOCOL.md §7).
The thresholds live ONCE, in assets/web-perf-facts.json; SKILL.md's table and
scripts/triage-vitals.py both read from that catalog's values. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/web-perf-facts.json parses, carries the schema + an as_of date
    * SKILL.md's threshold table (rows like `| **LCP** | <= 2.5 s | > 4 s |`)
      matches the catalog numerically, row for row
    * SKILL.md carries a dated "Verified against web.dev + Chrome docs
      (YYYY-MM-DD)" currency note
    * every catalogued package's prose_token is still named in the skill prose
    * no line in the skill presents FID as current (any FID mention must sit
      on a line that also says INP / replaced / retired / removed)
  --live (scheduled freshness job, never a PR gate):
    * web-vitals' own source constants (LCPThresholds etc., read from unpkg)
      still equal the catalog - this is Google's canonical machine-readable copy
    * each package still resolves on npm, is not deprecated, and its major is
      the documented one; @lhci/cli still bundles the documented Lighthouse major

Usage:   check-web-perf-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin).
Output:  stdout = findings (TSV rows: check, status, detail; or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 npm/unpkg unreachable (live, advisory - never a real failure),
         10 drift found (offline: table/catalog mismatch, currency note gone,
            token missing, FID presented as current; live: threshold or major moved)

Examples:
  check-web-perf-facts.py --offline                  # PR CI: catalog <-> prose consistency
  check-web-perf-facts.py --live                     # weekly: did Google move a threshold?
  check-web-perf-facts.py --offline --json | jq '.data[] | select(.status=="drift")'
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.web-perf-ops.facts/v1"
METRICS = ("LCP", "INP", "CLS", "FCP", "TTFB", "TBT")
# Metrics whose thresholds web-vitals exports as `<M>Thresholds = [good, poor]`.
# TBT is a Lighthouse lab metric; web-vitals does not measure it.
WEB_VITALS_METRICS = ("LCP", "INP", "CLS", "FCP", "TTFB")

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "web-perf-facts.json"
DEFAULT_SKILL = HERE.parent

NPM_REGISTRY = "https://registry.npmjs.org"
# unpkg serves the published package files; `@<major>` pins the documented line
# so a new major is reported by the npm check, not as a threshold mismatch.
UNPKG = "https://unpkg.com/web-vitals@{major}/dist/modules/on{metric}.js"

CURRENCY_RE = re.compile(
    r"Verified against web\.dev \+ Chrome docs \((\d{4}-\d{2}-\d{2})\)", re.IGNORECASE
)
AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# A SKILL.md threshold row: `| **LCP** | <= 2.5 s | > 4 s | ...`. The first two
# value cells are good-ceiling and poor-floor; units are s, ms, or unitless.
ROW_RE = re.compile(r"^\|\s*\*\*(?P<m>[A-Z]{2,4})\*\*\s*\|(?P<good>[^|]+)\|(?P<poor>[^|]+)\|")
VALUE_RE = re.compile(r"(?P<n>\d+(?:\.\d+)?)\s*(?P<u>ms|s)?\b")
FID_RE = re.compile(r"\bFID\b")
FID_OK_RE = re.compile(r"\bINP\b|replac|retir|remov|deprecat", re.IGNORECASE)


def load_catalog(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalog not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            raise ValueError(f"schema must be {SCHEMA!r}")
        if not AS_OF_RE.match(str(data.get("as_of", ""))):
            raise ValueError(f"as_of must be YYYY-MM-DD, got {data.get('as_of')!r}")
        th = data["thresholds"]
        for m in METRICS:
            row = th[m]
            if not (isinstance(row["good"], (int, float)) and isinstance(row["poor"], (int, float))):
                raise ValueError(f"threshold {m} good/poor must be numbers")
            if not row["good"] < row["poor"]:
                raise ValueError(f"threshold {m}: good must be < poor")
        for key, pkg in data["packages"].items():
            if "name" not in pkg or "prose_token" not in pkg or "documented_major" not in pkg:
                raise ValueError(f"package {key!r} missing name/prose_token/documented_major")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def to_catalog_units(cell: str, metric: str) -> float | None:
    """'<= 2.5 s' -> 2500 (ms); '200 ms' -> 200; '0.1' -> 0.1 (CLS is unitless)."""
    m = VALUE_RE.search(cell)
    if not m:
        return None
    n = float(m.group("n"))
    if metric == "CLS":
        return n
    return n * 1000 if m.group("u") == "s" else n


def read_corpus(skill_dir: Path) -> tuple[str, list[tuple[str, str]]]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    files = [("SKILL.md", skill_md)]
    ref_dir = skill_dir / "references"
    if ref_dir.is_dir():
        for ref in sorted(ref_dir.glob("*.md")):
            files.append((f"references/{ref.name}", ref.read_text(encoding="utf-8", errors="replace")))
    return skill_md, files


def check_offline(catalog: dict, skill_dir: Path) -> list[dict]:
    skill_md, files = read_corpus(skill_dir)
    findings: list[dict] = []

    m = CURRENCY_RE.search(skill_md)
    findings.append({
        "check": "currency-note",
        "status": "ok" if m else "drift",
        "detail": f"dated {m.group(1)}" if m else
                  "no dated 'Verified against web.dev + Chrome docs (YYYY-MM-DD)' note in SKILL.md",
    })

    rows = {}
    for line in skill_md.splitlines():
        r = ROW_RE.match(line.strip())
        if r and r.group("m") in METRICS:
            rows[r.group("m")] = (r.group("good"), r.group("poor"))
    for metric in METRICS:
        want = catalog["thresholds"][metric]
        if metric not in rows:
            findings.append({"check": f"table:{metric}", "status": "drift",
                             "detail": f"no '| **{metric}** | good | poor |' row in SKILL.md"})
            continue
        good = to_catalog_units(rows[metric][0], metric)
        poor = to_catalog_units(rows[metric][1], metric)
        if good == float(want["good"]) and poor == float(want["poor"]):
            findings.append({"check": f"table:{metric}", "status": "ok",
                             "detail": f"good<={want['good']} poor>{want['poor']}"})
        else:
            findings.append({"check": f"table:{metric}", "status": "drift",
                             "detail": f"SKILL.md says {good}/{poor}, catalog says {want['good']}/{want['poor']}"})

    corpus = "\n".join(text for _, text in files).lower()
    for key, pkg in catalog["packages"].items():
        token = str(pkg["prose_token"])
        ok = token.lower() in corpus
        findings.append({"check": f"token:{key}", "status": "ok" if ok else "drift",
                         "detail": f"{token!r} named in skill prose" if ok else
                                   f"prose_token {token!r} no longer named in skill prose"})

    stale = []
    for name, text in files:
        for n, line in enumerate(text.splitlines(), 1):
            if FID_RE.search(line) and not FID_OK_RE.search(line):
                stale.append(f"{name}:{n}")
    findings.append({"check": "fid-retired", "status": "drift" if stale else "ok",
                     "detail": ("FID presented as current at " + ", ".join(stale[:5])) if stale else
                               "every FID mention is framed as replaced by INP"})
    return findings


def _get(url: str, timeout: float) -> tuple[str, str]:
    """Return (status, body-or-detail). status in ok|notfound|unavailable."""
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-web-perf-ops-check/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return "ok", resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return ("notfound" if exc.code in (404, 410) else "unavailable"), str(exc.code)
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable", ""


def check_live(catalog: dict, timeout: float) -> list[dict]:
    findings: list[dict] = []
    wv_major = catalog["packages"]["web_vitals"]["documented_major"]
    for metric in WEB_VITALS_METRICS:
        status, body = _get(UNPKG.format(major=wv_major, metric=metric), timeout)
        if status != "ok":
            findings.append({"check": f"web-vitals:{metric}", "status": "unavailable",
                             "detail": f"unpkg unreachable for on{metric}.js ({body})"})
            continue
        m = re.search(rf"{metric}Thresholds\s*=\s*\[\s*([\d.]+)\s*,\s*([\d.]+)\s*\]", body)
        want = catalog["thresholds"][metric]
        if not m:
            findings.append({"check": f"web-vitals:{metric}", "status": "drift",
                             "detail": f"{metric}Thresholds constant not found - library reshaped, review"})
        elif (float(m.group(1)), float(m.group(2))) != (float(want["good"]), float(want["poor"])):
            findings.append({"check": f"web-vitals:{metric}", "status": "drift",
                             "detail": f"library says [{m.group(1)}, {m.group(2)}], catalog "
                                       f"[{want['good']}, {want['poor']}] - Google moved a threshold"})
        else:
            findings.append({"check": f"web-vitals:{metric}", "status": "ok",
                             "detail": f"[{m.group(1)}, {m.group(2)}] matches"})

    for key, pkg in catalog["packages"].items():
        name = str(pkg["name"])
        status, body = _get(f"{NPM_REGISTRY}/{urllib.parse.quote(name, safe='@')}/latest", timeout)
        if status == "notfound":
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{name} gone from npm - renamed/removed, review skill"})
            continue
        if status != "ok":
            findings.append({"check": f"npm:{key}", "status": "unavailable",
                             "detail": f"npm registry unreachable for {name}"})
            continue
        try:
            manifest = json.loads(body)
        except json.JSONDecodeError:
            findings.append({"check": f"npm:{key}", "status": "unavailable", "detail": "bad json"})
            continue
        ver = str(manifest.get("version", ""))
        # A deprecated package still resolves and still has a "latest" - only this
        # field says it is dead. @builder.io/partytown passed a version-only check
        # for a year after it moved to @qwik.dev/partytown.
        if manifest.get("deprecated"):
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{name}@{ver} is deprecated: {manifest['deprecated']}"})
            continue
        documented = str(pkg["documented_major"])
        latest = _line(ver)
        if latest and latest != documented:
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{name}@{ver} line {latest} != documented {documented} - review skill"})
        else:
            findings.append({"check": f"npm:{key}", "status": "ok", "detail": f"latest {ver}"})
        bundled = pkg.get("bundled_lighthouse_major")
        if bundled is not None:
            dep = str((manifest.get("dependencies") or {}).get("lighthouse", ""))
            got = _line(dep.lstrip("^~=<> "))
            if got and got != str(bundled):
                findings.append({"check": f"npm:{key}:lighthouse", "status": "drift",
                                 "detail": f"{name} now bundles lighthouse {dep} (documented {bundled}.x) - "
                                           "revisit audit ids in budgets-ci.md"})
            else:
                findings.append({"check": f"npm:{key}:lighthouse", "status": "ok",
                                 "detail": f"bundles lighthouse {dep or '?'}"})
    return findings


def _line(ver: str) -> str:
    """Release line: the major, or '0.<minor>' for 0.x packages, which break on minors."""
    mm = re.match(r"\s*(\d+)(?:\.(\d+))?", ver)
    if not mm:
        return ""
    return f"0.{mm.group(2)}" if mm.group(1) == "0" and mm.group(2) else mm.group(1)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-web-perf-facts.py",
        description="Verify web-perf-ops' Core Web Vitals thresholds + tool majors stay stated (offline) and current (live).",
        epilog=(
            "Examples:\n"
            "  check-web-perf-facts.py --offline\n"
            "  check-web-perf-facts.py --live\n"
            "  check-web-perf-facts.py --offline --json | jq '.data[] | select(.status==\"drift\")'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe unpkg + npm for threshold/major drift")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    catalog = load_catalog(Path(args.catalog))
    findings = check_live(catalog, args.timeout) if args.live else check_offline(catalog, Path(args.skill))
    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"count": len(findings), "mode": "live" if args.live else "offline",
                     "as_of": catalog.get("as_of"), "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")

    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-web-perf-facts: {verdict} ({len(findings)} checks, {len(drift)} drift)", file=sys.stderr)

    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
