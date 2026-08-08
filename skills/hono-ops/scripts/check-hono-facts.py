#!/usr/bin/env python3
"""Staleness verifier for hono-ops: the documented Hono major line and the
named ecosystem packages must stay real, stated, and current.

hono-ops assumes Hono v4 and names @hono/zod-validator and
@cloudflare/vitest-pool-workers as the validation/testing packages. Those are
the facts that drift silently (SKILL-RESOURCE-PROTOCOL.md §7): Hono ships a v5
and the middleware/RPC advice quietly rots, or a package is renamed and every
install command in the prose 404s. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/hono-facts.json parses, carries the schema + an as_of date
    * every catalogued fact's prose_token is still named in the skill prose
      (SKILL.md + references/*.md + assets/worker-template.ts)
    * SKILL.md still carries a dated "Verified against Hono v<major> (<year>)"
      currency note whose major matches the catalog
  --live (scheduled freshness job, never a PR gate): does each package still
    resolve on npm, and has hono's major moved off the documented line?

Usage:   check-hono-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 npm unreachable (live, advisory - never a real failure),
         10 drift found (offline: fact no longer named / currency note gone or
            mismatched; live: package gone from npm or hono major drifted)

Examples:
  check-hono-facts.py --offline                 # PR CI: facts <-> prose consistency
  check-hono-facts.py --live                    # weekly: hono still v4 on npm?
  check-hono-facts.py --offline --json | jq '.data[]'
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

SCHEMA = "claude-mods.hono-ops.facts/v1"
FACT_KEYS = ("hono", "zod_validator", "pool_workers", "zod_openapi")

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "hono-facts.json"
DEFAULT_SKILL = HERE.parent

NPM_REGISTRY = "https://registry.npmjs.org"

CURRENCY_RE = re.compile(r"Verified against Hono v(\d+)\s*\((\d{4})\)", re.IGNORECASE)
AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


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
        for key in FACT_KEYS:
            fact = data.get(key)
            if not isinstance(fact, dict) or "prose_token" not in fact or "package" not in fact:
                raise ValueError(f"fact {key!r} missing prose_token/package")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """Return (skill_md_text, all_prose_text) across SKILL.md + references/*.md
    + assets/worker-template.ts (the starter names Hono v4 in its header)."""
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
    template = skill_dir / "assets" / "worker-template.ts"
    if template.is_file():
        parts.append(template.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def check_offline(catalog: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    lower = corpus.lower()
    findings: list[dict] = []

    m = CURRENCY_RE.search(skill_md)
    if not m:
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": "no dated 'Verified against Hono v<major> (<year>)' note in SKILL.md"})
    elif m.group(1) != str(catalog["hono"].get("documented_major")):
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": f"currency note says v{m.group(1)} but catalog documents v{catalog['hono'].get('documented_major')}"})
    else:
        findings.append({"check": "currency-note", "status": "ok",
                         "detail": f"currency note v{m.group(1)} dated {m.group(2)}"})

    for key in FACT_KEYS:
        token = str(catalog[key]["prose_token"])
        if token.lower() in lower:
            findings.append({"check": f"fact:{key}", "status": "ok",
                             "detail": f"{token!r} named in skill prose"})
        else:
            findings.append({"check": f"fact:{key}", "status": "drift",
                             "detail": f"prose_token {token!r} no longer named in skill prose"})
    return findings


def _npm_latest(pkg: str, timeout: float) -> tuple[str, str]:
    """Return (status, version-or-detail). status in ok|notfound|unavailable."""
    url = f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='@')}/latest"
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-hono-ops-check/1",
                                               "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "notfound", str(exc.code)
        return "unavailable", str(exc.code)
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable", ""
    try:
        return "ok", json.loads(payload).get("version", "")
    except json.JSONDecodeError:
        return "unavailable", "bad-json"


def check_live(catalog: dict, timeout: float) -> list[dict]:
    findings: list[dict] = []
    for key in FACT_KEYS:
        fact = catalog[key]
        pkg = str(fact["package"])
        status, ver = _npm_latest(pkg, timeout)
        if status == "notfound":
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{pkg} gone from npm - renamed/removed, review skill"})
            continue
        if status != "ok":
            findings.append({"check": f"npm:{key}", "status": "unavailable",
                             "detail": f"npm registry unreachable for {pkg}"})
            continue
        documented = fact.get("documented_major")
        m = re.match(r"\s*(\d+)", ver)
        latest_major = m.group(1) if m else ""
        if documented is not None and latest_major and latest_major != str(documented):
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{pkg}@{ver} major {latest_major} != documented v{documented}.x - review skill"})
        else:
            findings.append({"check": f"npm:{key}", "status": "ok",
                             "detail": f"latest {ver}"})
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-hono-facts.py",
        description="Verify hono-ops' Hono major + package facts stay stated (offline) and current (live).",
        epilog=(
            "Examples:\n"
            "  check-hono-facts.py --offline\n"
            "  check-hono-facts.py --live\n"
            "  check-hono-facts.py --offline --json | jq '.data[]'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe npm for package/major drift")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/ + assets/)")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress stderr progress/summary")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    catalog = load_catalog(Path(args.catalog))
    live = args.live
    findings = (check_live(catalog, args.timeout) if live
                else check_offline(catalog, Path(args.skill)))

    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "mode": "live" if live else "offline",
                                   "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")

    if not args.quiet:
        verdict = ("DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK")
        print(f"check-hono-facts: {verdict} ({len(findings)} checks, {len(drift)} drift)", file=sys.stderr)

    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
