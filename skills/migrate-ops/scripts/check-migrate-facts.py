#!/usr/bin/env python3
"""Staleness verifier for migrate-ops: the framework/language target versions
the skill hardcodes must stay stated where it claims, and must not silently lag
reality.

migrate-ops commits to specific target versions in its description and body —
React 19, Laravel 11, Python 3.12, Node 22, TypeScript 5, Go 1.22, Rust 2024,
PHP 8.4. Those are exactly the facts that drift silently
(SKILL-RESOURCE-PROTOCOL.md §7): a line gets rewritten and drops a version, or
the world moves (Python 3.12 → 3.13, Node 22 → 24) and the skill still names
the old target. Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/migrate-facts.json parses and carries the schema + an as_of date
    * every catalogued claim's regex still matches in each location it is
      recorded as appearing (description vs body) — the catalog can't drift
      from the docs
    * SKILL.md still carries a dated "verified as of <year>" currency note
  --live (scheduled freshness job, never a PR gate): resolves the current
    stable version of each product via endoflife.date (python, nodejs, laravel,
    php, go) and registry.npmjs.org (react, typescript), and flags any
    documented target that is no longer the latest stable major/line.

Usage:   check-migrate-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 endoflife.date/npm unreachable (live, advisory — never a real failure),
         10 drift found (offline: claim missing from a recorded location or
            currency note gone; live: a documented target lags the latest stable)

Examples:
  check-migrate-facts.py --offline                 # PR CI: catalog ⇆ prose consistency
  check-migrate-facts.py --live                    # weekly: any target lagging latest?
  check-migrate-facts.py --offline --json | jq '.data[]'
"""
from __future__ import annotations

import argparse
import datetime
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

SCHEMA = "claude-mods.migrate-ops.facts/v1"

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "migrate-facts.json"
DEFAULT_SKILL = HERE.parent

ENDOFLIFE = "https://endoflife.date/api"
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
        if not isinstance(data.get("claims"), list) or not data["claims"]:
            raise ValueError("'claims' must be a non-empty array")
        for c in data["claims"]:
            for k in ("label", "version", "where", "pattern"):
                if k not in c:
                    raise ValueError(f"claim missing {k}: {c!r}")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def split_skill(skill_md: str) -> tuple[str, str]:
    """Split SKILL.md into (description_value, body_text).

    description = the quoted value of the frontmatter `description:` field.
    body        = everything after the closing `---` fence."""
    lines = skill_md.splitlines()
    if not lines or lines[0].strip() != "---":
        return "", skill_md
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return "", skill_md
    desc = ""
    for ln in lines[1:end]:
        if ln.strip().startswith("description:"):
            desc = ln.strip()[len("description:"):].strip()
            if len(desc) >= 2 and desc[0] in "\"'" and desc[-1] == desc[0]:
                desc = desc[1:-1]
            break
    body = "\n".join(lines[end + 1:])
    return desc, body


def read_corpus(skill_dir: Path) -> tuple[str, str, str]:
    """Returns (skill_md, description, body_corpus). body_corpus = SKILL.md body
    + references/*.md (the prose a claim can be recorded as appearing in)."""
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    desc, body = split_skill(skill_md)
    parts = [body]
    ref_dir = skill_dir / "references"
    if ref_dir.is_dir():
        for ref in sorted(ref_dir.glob("*.md")):
            parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    return skill_md, desc, "\n".join(parts)


def check_offline(catalog: dict, skill_dir: Path) -> list[Finding]:
    skill_md, desc, body_corpus = read_corpus(skill_dir)
    findings: list[Finding] = []

    if CURRENCY_RE.search(skill_md):
        m = CURRENCY_RE.search(skill_md)
        findings.append(Finding("currency-note", "ok", f"currency note dated {m.group(1)}"))
    else:
        findings.append(Finding("currency-note", "drift",
                                "no dated 'verified as of <year>' currency note in SKILL.md"))

    for claim in catalog.get("claims", []):
        label = claim["label"]
        regex = re.compile(claim["pattern"], re.IGNORECASE)
        for loc in claim["where"]:
            text = desc if loc == "description" else body_corpus
            if regex.search(text):
                findings.append(Finding(f"claim:{label}:{loc}", "ok",
                                        f"{label} {claim['version']} present in {loc}"))
            else:
                findings.append(Finding(f"claim:{label}:{loc}", "drift",
                                        f"{label} {claim['version']} not found in {loc} "
                                        f"(pattern {claim['pattern']!r})"))
    return findings


def _fetch(url: str, timeout: float, accept: str = "application/json") -> tuple[str, object]:
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-migrate-ops-check/1",
                                               "Accept": accept})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return "ok", resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "notfound", exc.code
        return "unavailable", exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable", None


def _vtup(s: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", str(s))) or (0,)


def _leading_int(s: str) -> str:
    m = re.match(r"\s*(\d+)", str(s))
    return m.group(1) if m else ""


def _endoflife_latest(product: str, timeout: float) -> tuple[str, str | None]:
    """Return (status, latest_supported_cycle_or_None). status in ok|unavailable."""
    url = f"{ENDOFLIFE}/{urllib.parse.quote(product, safe='')}.json"
    status, payload = _fetch(url, timeout)
    if status != "ok":
        return "unavailable", None
    try:
        cycles = json.loads(payload)
    except json.JSONDecodeError:
        return "unavailable", None
    today = datetime.date.today()
    supported: list[str] = []
    for c in cycles:
        cyc = str(c.get("cycle", ""))
        if not cyc:
            continue
        eol = c.get("eol", False)
        is_eol = False
        if isinstance(eol, str):
            try:
                is_eol = datetime.date.fromisoformat(eol[:10]) < today
            except ValueError:
                is_eol = False
        elif eol is False:
            is_eol = False
        else:
            is_eol = bool(eol)
        if not is_eol:
            supported.append(cyc)
    pool = supported or [str(c.get("cycle", "")) for c in cycles if c.get("cycle")]
    if not pool:
        return "ok", None
    return "ok", max(pool, key=_vtup)


def _npm_latest(pkg: str, timeout: float) -> tuple[str, str]:
    """Return (status, version-or-detail). status in ok|notfound|unavailable."""
    url = f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='')}/latest"
    status, payload = _fetch(url, timeout)
    if status != "ok":
        return status, str(payload)
    try:
        return "ok", json.loads(payload).get("version", "")
    except json.JSONDecodeError:
        return "unavailable", "bad-json"


def check_live(catalog: dict, timeout: float) -> list[Finding]:
    findings: list[Finding] = []
    for claim in catalog.get("claims", []):
        live = claim.get("live")
        label = claim["label"]
        if not live:
            findings.append(Finding(f"live:{label}", "ok", "not live-tracked (edition / no registry source)"))
            continue
        source = live.get("source")
        compare = live.get("compare", "major")
        documented = str(live.get("documented", ""))

        if source == "endoflife":
            status, latest = _endoflife_latest(live["product"], timeout)
            if status != "ok" or latest is None:
                findings.append(Finding(f"live:{label}", "unavailable",
                                        f"endoflife.date/{live['product']} unreachable"))
                continue
            if compare == "major":
                latest_major, doc_major = _leading_int(latest), _leading_int(documented)
                if latest_major and latest_major != doc_major:
                    findings.append(Finding(f"live:{label}", "drift",
                                            f"{label} documented {documented} lags latest stable {latest}"))
                else:
                    findings.append(Finding(f"live:{label}", "ok", f"latest stable {latest}"))
            else:  # line: compare MAJOR.MINOR
                if _vtup(latest)[:2] != _vtup(documented)[:2]:
                    findings.append(Finding(f"live:{label}", "drift",
                                            f"{label} documented {documented} lags latest stable {latest}"))
                else:
                    findings.append(Finding(f"live:{label}", "ok", f"latest stable {latest}"))
        elif source == "npm":
            status, ver = _npm_latest(live["product"], timeout)
            if status == "notfound":
                findings.append(Finding(f"live:{label}", "drift",
                                        f"{live['product']} gone from npm — renamed/removed"))
                continue
            if status != "ok":
                findings.append(Finding(f"live:{label}", "unavailable",
                                        f"npm/{live['product']} unreachable"))
                continue
            latest_major, doc_major = _leading_int(ver), _leading_int(documented)
            if latest_major and latest_major != doc_major:
                findings.append(Finding(f"live:{label}", "drift",
                                        f"{label} documented {documented} lags latest {ver}"))
            else:
                findings.append(Finding(f"live:{label}", "ok", f"latest {ver}"))
        else:
            findings.append(Finding(f"live:{label}", "drift", f"unknown live source {source!r}"))
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-migrate-facts.py",
        description="Verify migrate-ops' hardcoded target versions stay stated (offline) and current (live).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="resolve current versions via endoflife.date + npm")
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
