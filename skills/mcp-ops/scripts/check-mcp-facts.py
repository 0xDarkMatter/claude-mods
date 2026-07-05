#!/usr/bin/env python3
"""Staleness verifier for mcp-ops: the MCP SDK packages + spec URL the skill
names must stay real, named, and current.

mcp-ops tells the reader to install `@modelcontextprotocol/sdk` (npm),
`@modelcontextprotocol/inspector` (npm), `mcp[cli]` / `fastmcp` (PyPI), and
cites the spec at spec.modelcontextprotocol.io. Those are exactly the facts
that drift silently (SKILL-RESOURCE-PROTOCOL.md §7): an SDK is renamed, a
package is unpublished, the prose stops mentioning one the catalog still
lists, or the spec URL goes dead — and nobody notices for months. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/mcp-facts.json parses and carries the schema + an as_of date
    * every catalogued package's prose_token is still named somewhere in the
      skill prose (SKILL.md + references/*.md) — the catalog can't drift from
      the docs
    * the spec URL token is still cited in the prose
    * SKILL.md still carries a dated "verified as of <year>" currency note
  --live (scheduled freshness job, never a PR gate): does each package still
    resolve on its registry (npm latest / PyPI JSON), and has any tracked
    SDK's major moved off the sampled major? Does the spec URL answer 200?

Usage:   check-mcp-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 registries/spec unreachable (live, advisory — never a real failure),
         10 drift found (offline: unnamed/currency-note gone; live: package
            gone, SDK major moved, or spec URL dead)

Examples:
  check-mcp-facts.py --offline                 # PR CI: catalog ⇆ prose consistency
  check-mcp-facts.py --live                    # weekly: SDKs still resolve + spec 200
  check-mcp-facts.py --offline --json | jq '.data[]'
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

SCHEMA = "claude-mods.mcp-ops.facts/v1"

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "mcp-facts.json"
DEFAULT_SKILL = HERE.parent

NPM_REGISTRY = "https://registry.npmjs.org"
PYPI_REGISTRY = "https://pypi.org/pypi"

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
        if not isinstance(data.get("packages"), dict) or not data["packages"]:
            raise ValueError("'packages' must be a non-empty object")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """Returns (skill_md_text, all_prose_text) across SKILL.md + references/*.md."""
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


def check_offline(catalog: dict, skill_dir: Path) -> list[Finding]:
    skill_md, corpus = read_corpus(skill_dir)
    findings: list[Finding] = []
    lower_corpus = corpus.lower()

    # Currency note still dated.
    if CURRENCY_RE.search(skill_md):
        m = CURRENCY_RE.search(skill_md)
        findings.append(Finding("currency-note", "ok", f"currency note dated {m.group(1)}"))
    else:
        findings.append(Finding("currency-note", "drift",
                                "no dated 'verified as of <year>' currency note in SKILL.md"))

    # Spec URL token still cited.
    spec = catalog.get("spec", {})
    spec_token = str(spec.get("prose_token", ""))
    if spec_token and spec_token.lower() in lower_corpus:
        findings.append(Finding("spec-cited", "ok", f"{spec_token} named in prose"))
    else:
        findings.append(Finding("spec-cited", "drift",
                                f"spec token {spec_token!r} no longer named in skill prose"))

    # Every catalogued package still named in the prose.
    for name, meta in catalog.get("packages", {}).items():
        token = str(meta.get("prose_token", name))
        if token.lower() in lower_corpus:
            findings.append(Finding(f"pkg-named:{name}", "ok", "named in skill prose"))
        else:
            findings.append(Finding(f"pkg-named:{name}", "drift",
                                    f"prose_token {token!r} not found in skill prose"))
    return findings


def _fetch(url: str, timeout: float, accept: str = "application/json") -> tuple[str, object]:
    """Return (ok|notfound|unavailable, payload-or-status)."""
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-mcp-ops-check/1",
                                               "Accept": accept})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return "ok", body
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "notfound", exc.code
        return "unavailable", exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable", None


def _npm_latest(pkg: str, timeout: float) -> tuple[str, str]:
    """Return (status, version-or-status-detail). status in ok|notfound|unavailable."""
    url = f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='')}/latest"
    status, payload = _fetch(url, timeout)
    if status != "ok":
        return status, str(payload)
    try:
        ver = json.loads(payload).get("version", "")
        return "ok", ver
    except json.JSONDecodeError:
        return "unavailable", "bad-json"


def _pypi_latest(pkg: str, timeout: float) -> tuple[str, str]:
    url = f"{PYPI_REGISTRY}/{urllib.parse.quote(pkg, safe='')}/json"
    status, payload = _fetch(url, timeout)
    if status != "ok":
        return status, str(payload)
    try:
        ver = json.loads(payload).get("info", {}).get("version", "")
        return "ok", ver
    except json.JSONDecodeError:
        return "unavailable", "bad-json"


def _major(ver: str) -> str:
    """Leading integer component of a version string ('1.2.3' -> '1')."""
    m = re.match(r"\s*(\d+)", ver)
    return m.group(1) if m else ""


def check_live(catalog: dict, timeout: float) -> list[Finding]:
    findings: list[Finding] = []

    for name, meta in catalog.get("packages", {}).items():
        registry = meta.get("registry", "npm")
        if registry == "npm":
            status, info = _npm_latest(name, timeout)
        else:
            status, info = _pypi_latest(name, timeout)
        if status == "notfound":
            findings.append(Finding(f"npm:{name}", "drift",
                                    "package gone from registry — renamed/removed, review skill"))
            continue
        if status == "unavailable":
            findings.append(Finding(f"npm:{name}", "unavailable", "registry unreachable"))
            continue
        ver = str(info)
        if meta.get("track_major"):
            sampled = str(meta.get("sampled_major", ""))
            latest_major = _major(ver)
            if latest_major and latest_major != sampled:
                findings.append(Finding(f"npm:{name}", "drift",
                                        f"{name}@{ver} major {latest_major} != sampled {sampled} — review skill"))
            else:
                findings.append(Finding(f"npm:{name}", "ok", f"latest {ver} (major {latest_major})"))
        else:
            findings.append(Finding(f"npm:{name}", "ok", f"latest {ver}"))

    # Spec URL must answer 200 (follows redirects).
    spec_url = str(catalog.get("spec", {}).get("url", ""))
    if spec_url:
        status, info = _fetch(spec_url, timeout, accept="text/html,application/json")
        if status == "ok":
            findings.append(Finding("spec-url", "ok", f"{spec_url} answered 200"))
        elif status == "notfound":
            findings.append(Finding("spec-url", "drift", f"{spec_url} returned 4xx — spec URL dead"))
        else:
            findings.append(Finding("spec-url", "unavailable", f"{spec_url} unreachable"))
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-mcp-facts.py",
        description="Verify mcp-ops' SDK packages + spec URL stay named (offline) and live (live).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe npm/PyPI registries + the spec URL")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
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
