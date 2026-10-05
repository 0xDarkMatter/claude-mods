#!/usr/bin/env python3
"""Staleness verifier for craftcms-ops: the Craft + plugin major versions the
skill documents must stay stated in the prose (offline) and current on
Packagist (live).

craftcms-ops pins advice to version lines - Craft 5, SEOmatic 5, Blitz 5,
Formie 3, craft-vite 5, ... Those are the facts that rot silently
(SKILL-RESOURCE-PROTOCOL.md §7): Craft 6 goes stable, Formie 4 leaves beta,
and the version matrix quietly starts lying. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/craft-facts.json parses, carries the schema + an as_of date
    * every fact's prose_token is still stated in the skill prose
      (SKILL.md + references/*.md)
    * SKILL.md carries a "Versions verified YYYY-MM-DD" note equal to as_of
  --live (scheduled freshness job, never a PR gate): for each package, is the
    newest STABLE major on Packagist still the documented one? Pre-releases
    (Craft 6 alpha, Formie 4 beta) are ignored until they go stable.

Packagist source: https://repo.packagist.org/p2/<vendor>/<package>.json
(the documented Composer v2 metadata endpoint, https://packagist.org/apidoc).

Usage:   check-craft-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin).
Output:  stdout = findings (tab-separated rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 Packagist unreachable (live, advisory - never a real failure),
         10 drift found (offline: a fact no longer stated / note mismatched;
            live: package gone, or a newer stable major shipped)

Examples:
  check-craft-facts.py --offline                  # PR CI: catalog <-> prose consistency
  check-craft-facts.py --live                     # weekly: any new stable majors?
  check-craft-facts.py --offline --json | jq '.data[]'
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.craftcms-ops.facts/v1"

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "craft-facts.json"
DEFAULT_SKILL = HERE.parent

PACKAGIST = "https://repo.packagist.org/p2"

AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOTE_RE = re.compile(r"Versions verified (\d{4}-\d{2}-\d{2})")
# Stable = plain X.Y.Z (optionally v-prefixed). Anything with a suffix
# (-alpha.19, -beta.16, -RC1) is a pre-release and never counts as "shipped".
STABLE_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
PKG_RE = re.compile(r"^[a-z0-9_.-]+/[a-z0-9_.-]+$")


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
        facts = data.get("facts")
        if not isinstance(facts, list) or not facts:
            raise ValueError("facts must be a non-empty list")
        for fact in facts:
            if not isinstance(fact, dict):
                raise ValueError("each fact must be an object")
            for key in ("key", "package", "documented_major", "prose_token"):
                if key not in fact:
                    raise ValueError(f"fact {fact.get('key', '?')!r} missing {key!r}")
            if not PKG_RE.match(str(fact["package"])):
                raise ValueError(f"fact {fact['key']!r}: bad package name {fact['package']!r}")
            if not isinstance(fact["documented_major"], int):
                raise ValueError(f"fact {fact['key']!r}: documented_major must be an int")
        return data
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    parts = [skill_md]
    ref_dir = skill_dir / "references"
    if ref_dir.is_dir():
        for ref in sorted(ref_dir.glob("*.md")):
            parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def check_offline(catalog: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    findings: list[dict] = []

    m = NOTE_RE.search(skill_md)
    if not m:
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": "SKILL.md has no 'Versions verified YYYY-MM-DD' note"})
    elif m.group(1) != catalog["as_of"]:
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": f"SKILL.md says verified {m.group(1)} but catalog as_of is {catalog['as_of']}"})
    else:
        findings.append({"check": "currency-note", "status": "ok",
                         "detail": f"verified {m.group(1)}"})

    for fact in catalog["facts"]:
        token = str(fact["prose_token"])
        if token in corpus:
            findings.append({"check": f"fact:{fact['key']}", "status": "ok",
                             "detail": f"{token!r} stated in skill prose"})
        else:
            findings.append({"check": f"fact:{fact['key']}", "status": "drift",
                             "detail": f"prose_token {token!r} no longer stated in skill prose"})
    return findings


def latest_stable_major(package: str, timeout: float) -> tuple[str, str]:
    """Return (status, detail). status: ok (detail = 'MAJOR VERSION'),
    notfound, or unavailable."""
    url = f"{PACKAGIST}/{package}.json"
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-craftcms-ops-check/1",
                                               "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "notfound", str(exc.code)
        return "unavailable", str(exc.code)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
        return "unavailable", ""
    best: tuple[int, ...] | None = None
    best_ver = ""
    for entry in payload.get("packages", {}).get(package, []):
        m = STABLE_RE.match(str(entry.get("version", "")))
        if not m:
            continue
        ver = tuple(int(x) for x in m.groups())
        if best is None or ver > best:
            best, best_ver = ver, entry["version"]
    if best is None:
        return "unavailable", "no stable releases listed"
    return "ok", f"{best[0]} {best_ver}"


def check_live(catalog: dict, timeout: float) -> list[dict]:
    findings: list[dict] = []
    for fact in catalog["facts"]:
        pkg = str(fact["package"])
        status, detail = latest_stable_major(pkg, timeout)
        if status == "notfound":
            findings.append({"check": f"packagist:{fact['key']}", "status": "drift",
                             "detail": f"{pkg} gone from Packagist - renamed/abandoned, review skill"})
        elif status != "ok":
            findings.append({"check": f"packagist:{fact['key']}", "status": "unavailable",
                             "detail": f"Packagist unreachable for {pkg} {detail}".rstrip()})
        else:
            major, version = detail.split(" ", 1)
            documented = fact["documented_major"]
            if int(major) > documented:
                findings.append({"check": f"packagist:{fact['key']}", "status": "drift",
                                 "detail": f"{pkg} {version} is stable; skill documents {documented}.x - review"})
            else:
                findings.append({"check": f"packagist:{fact['key']}", "status": "ok",
                                 "detail": f"latest stable {version}"})
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-craft-facts.py",
        description="Verify craftcms-ops' version facts stay stated (offline) and current on Packagist (live).",
        epilog=(
            "Examples:\n"
            "  check-craft-facts.py --offline\n"
            "  check-craft-facts.py --live\n"
            "  check-craft-facts.py --offline --json | jq '.data[]'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe Packagist for newer stable majors")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=15.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    catalog = load_catalog(Path(args.catalog))
    findings = (check_live(catalog, args.timeout) if args.live
                else check_offline(catalog, Path(args.skill)))

    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings),
                                   "mode": "live" if args.live else "offline",
                                   "as_of": catalog["as_of"], "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")

    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-craft-facts: {verdict} ({len(findings)} checks, {len(drift)} drift)", file=sys.stderr)

    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
