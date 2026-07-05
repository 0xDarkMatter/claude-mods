#!/usr/bin/env python3
"""Staleness verifier for cloudflare-ops: the Wrangler major line, the
recommended compatibility_date, and the config filename convention must stay
real, stated, and current.

cloudflare-ops assumes Wrangler v4.x, recommends a `wrangler.jsonc` config,
and pins a specific `compatibility_date` in its skeleton. Those are exactly
the facts that drift silently (SKILL-RESOURCE-PROTOCOL.md §7): Wrangler ships
a v5 and the old `wrangler publish`-era advice rots, the prose stops naming
`wrangler.jsonc`, or the compatibility_date sits stale — and nobody notices
for months. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/cloudflare-facts.json parses and carries the schema + an as_of date
    * every catalogued fact's prose_token is still named in the skill prose
      (SKILL.md + references/*.md + assets/wrangler.jsonc.template)
    * SKILL.md still carries a dated "verified as of <year>" currency note
  --live (scheduled freshness job, never a PR gate): does Wrangler still
    resolve on npm, and has its major moved off the documented v4 line?

Usage:   check-cloudflare-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 npm unreachable (live, advisory — never a real failure),
         10 drift found (offline: fact no longer named / currency note gone;
            live: wrangler gone from npm or major drifted off v4)

Examples:
  check-cloudflare-facts.py --offline                 # PR CI: facts ⇆ prose consistency
  check-cloudflare-facts.py --live                    # weekly: wrangler still v4 on npm?
  check-cloudflare-facts.py --offline --json | jq '.data[]'
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

SCHEMA = "claude-mods.cloudflare-ops.facts/v1"

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "cloudflare-facts.json"
DEFAULT_SKILL = HERE.parent

NPM_REGISTRY = "https://registry.npmjs.org"

CURRENCY_RE = re.compile(r"verified as of\s+(\d{4})", re.IGNORECASE)
AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class Finding:
    __slots__ = ("check", "status", "detail")

    def __init__(self, check: str, status: str, detail: str) -> None:
        self.check = check
        self.status = status  # ok | drift | unavailable
        self.detail = detail

    def as_dict(self) -> dict:
        return {"check": self.check, "status": self.status, "detail": self.detail}


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
        for key in ("wrangler", "compatibility_date", "config_format"):
            if not isinstance(data.get(key), dict) or "prose_token" not in data[key]:
                raise ValueError(f"fact {key!r} missing prose_token")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """Returns (skill_md_text, all_prose_text) across SKILL.md + references/*.md
    + assets/wrangler.jsonc.template (the compatibility_date pin lives there)."""
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
    template = skill_dir / "assets" / "wrangler.jsonc.template"
    if template.is_file():
        parts.append(template.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def check_offline(catalog: dict, skill_dir: Path) -> list[Finding]:
    skill_md, corpus = read_corpus(skill_dir)
    lower = corpus.lower()
    findings: list[Finding] = []

    if CURRENCY_RE.search(skill_md):
        m = CURRENCY_RE.search(skill_md)
        findings.append(Finding("currency-note", "ok", f"currency note dated {m.group(1)}"))
    else:
        findings.append(Finding("currency-note", "drift",
                                "no dated 'verified as of <year>' currency note in SKILL.md"))

    for key in ("wrangler", "compatibility_date", "config_format"):
        fact = catalog[key]
        token = str(fact["prose_token"])
        if token.lower() in lower:
            findings.append(Finding(f"fact:{key}", "ok", f"{token!r} named in skill prose"))
        else:
            findings.append(Finding(f"fact:{key}", "drift",
                                    f"prose_token {token!r} no longer named in skill prose"))
    return findings


def _npm_latest(pkg: str, timeout: float) -> tuple[str, str]:
    """Return (status, version-or-detail). status in ok|notfound|unavailable."""
    url = f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='')}/latest"
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-cloudflare-ops-check/1",
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


def check_live(catalog: dict, timeout: float) -> list[Finding]:
    findings: list[Finding] = []
    wr = catalog["wrangler"]
    documented_major = str(wr["documented_major"])
    status, ver = _npm_latest(wr["live"]["product"], timeout)
    if status == "notfound":
        findings.append(Finding("npm:wrangler", "drift",
                                "wrangler gone from npm — renamed/removed, review skill"))
        return findings
    if status != "ok":
        findings.append(Finding("npm:wrangler", "unavailable", "npm registry unreachable"))
        return findings
    m = re.match(r"\s*(\d+)", ver)
    latest_major = m.group(1) if m else ""
    if latest_major and latest_major != documented_major:
        findings.append(Finding("npm:wrangler", "drift",
                                f"wrangler@{ver} major {latest_major} != documented v{documented_major}.x — review skill"))
    else:
        findings.append(Finding("npm:wrangler", "ok", f"latest {ver} (major {latest_major})"))
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-cloudflare-facts.py",
        description="Verify cloudflare-ops' Wrangler major + config facts stay stated (offline) and current (live).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe npm for wrangler major drift")
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
    live = args.live and not args.offline
    mode_name = "live" if live else "offline"
    findings = check_live(catalog, args.timeout) if live else check_offline(catalog, Path(args.skill))

    n_drift = sum(1 for f in findings if f.status == "drift")
    n_unavail = sum(1 for f in findings if f.status == "unavailable")

    if args.json:
        print(json.dumps({
            "data": [f.as_dict() for f in findings],
            "meta": {"mode": mode_name, "count": len(findings),
                     "drift": n_drift, "unavailable": n_unavail, "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"{f.check}\t{f.status}\t{f.detail}")

    for f in findings:
        if f.status != "ok":
            print(f"  [{f.status.upper()}] {f.check}: {f.detail}", file=sys.stderr)
    if not args.quiet:
        print(f"-- {len(findings)} checks: {n_drift} drift, {n_unavail} unavailable", file=sys.stderr)

    if n_drift:
        return EX_DRIFT
    if n_unavail:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
