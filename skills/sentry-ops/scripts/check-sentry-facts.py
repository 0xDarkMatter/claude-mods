#!/usr/bin/env python3
"""Staleness verifier for sentry-ops: the SDK major, the named packages and the
strict privacy baseline must stay stated and current.

The expensive drift here is silent. Sentry's v11 removed `sendDefaultPii` and
widened collection without an error for anyone still setting it. A future
`dataCollection` category defaults to ON, so STRICT_DATA_COLLECTION can go stale
while every test still passes. --live exists mainly to catch that second one.

  --offline (default, safe for PR CI): no network.
    * assets/sentry-facts.json parses, with the schema and an as_of date
    * every package's prose_token is still named in the skill prose
    * SKILL.md carries a dated "Verified against Sentry JavaScript SDK v<major>
      (<year>)" note whose major matches the catalog
    * STRICT_DATA_COLLECTION's keys equal the catalog's data_collection_keys
    * no shipped asset configures `sendDefaultPii`
  --live (scheduled freshness job, never a PR gate):
    * each package still resolves on npm, at its documented major
    * the SDK's own dataCollection defaults list the same keys as the catalog
    * each cited doc page still exists and still names its marker

Usage:   check-sentry-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 network unreachable (live, advisory),
         10 drift found

Examples:
  check-sentry-facts.py --offline
  check-sentry-facts.py --live
  check-sentry-facts.py --offline --json | jq '.data[]'
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

SCHEMA = "claude-mods.sentry-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "sentry-facts.json"
DEFAULT_SKILL = HERE.parent
NPM_REGISTRY = "https://registry.npmjs.org"
USER_AGENT = "claude-mods-sentry-ops-check/1"

CURRENCY_RE = re.compile(r"Verified against Sentry JavaScript SDK v(\d+)\s*\((\d{4})\)", re.IGNORECASE)
AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
STRICT_BLOCK_RE = re.compile(r"STRICT_DATA_COLLECTION\s*=\s*Object\.freeze\(\{(.*?)^\}\)", re.S | re.M)
DEFAULTS_BLOCK_RE = re.compile(r"const DEFAULTS\s*=\s*\{(.*?)^\};", re.S | re.M)
# Two-space indent marks a top-level key of these blocks, not a nested one.
TOP_KEY_RE = re.compile(r"^  ([A-Za-z]\w*):", re.M)
PII_CONFIG_RE = re.compile(r"^\s*sendDefaultPii\s*:", re.M)


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
        for key, fact in data["packages"].items():
            if "package" not in fact or "prose_token" not in fact:
                raise ValueError(f"package fact {key!r} missing package/prose_token")
        if not isinstance(data["data_collection_keys"], list) or not data["data_collection_keys"]:
            raise ValueError("data_collection_keys must be a non-empty list")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError, AttributeError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def check_offline(catalog: dict, skill_dir: Path) -> list[dict]:
    skill_md_path = skill_dir / "SKILL.md"
    if not skill_md_path.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = skill_md_path.read_text(encoding="utf-8", errors="replace")
    parts = [skill_md]
    for ref in sorted((skill_dir / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    corpus = "\n".join(parts).lower()
    findings: list[dict] = []

    m = CURRENCY_RE.search(skill_md)
    documented = str(catalog.get("documented_sdk_major"))
    if not m:
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": "no dated 'Verified against Sentry JavaScript SDK v<major> (<year>)' note"})
    elif m.group(1) != documented:
        findings.append({"check": "currency-note", "status": "drift",
                         "detail": f"note says v{m.group(1)}, catalog documents v{documented}"})
    else:
        findings.append({"check": "currency-note", "status": "ok",
                         "detail": f"v{m.group(1)} dated {m.group(2)}"})

    for key, fact in catalog["packages"].items():
        token = str(fact["prose_token"])
        ok = token.lower() in corpus
        findings.append({"check": f"fact:{key}", "status": "ok" if ok else "drift",
                         "detail": f"{token!r} {'named' if ok else 'no longer named'} in skill prose"})

    asset = skill_dir / "assets" / "scrub-event.mjs"
    if not asset.is_file():
        findings.append({"check": "strict-baseline", "status": "drift",
                         "detail": "assets/scrub-event.mjs is missing"})
    else:
        text = asset.read_text(encoding="utf-8", errors="replace")
        block = STRICT_BLOCK_RE.search(text)
        keys = sorted(TOP_KEY_RE.findall(block.group(1))) if block else []
        want = sorted(catalog["data_collection_keys"])
        if keys != want:
            findings.append({"check": "strict-baseline", "status": "drift",
                             "detail": f"STRICT_DATA_COLLECTION keys differ: missing {sorted(set(want) - set(keys))}, "
                                       f"extra {sorted(set(keys) - set(want))}"})
        else:
            findings.append({"check": "strict-baseline", "status": "ok",
                             "detail": f"{len(keys)} categories, matches catalog"})
        if PII_CONFIG_RE.search(text):
            findings.append({"check": "removed-option", "status": "drift",
                             "detail": "asset configures sendDefaultPii, which v11 removed"})
        else:
            findings.append({"check": "removed-option", "status": "ok",
                             "detail": "no asset configures sendDefaultPii"})
    return findings


def _get(url: str, timeout: float, accept: str = "*/*") -> tuple[str, str]:
    """Return (status, body-or-detail). status is ok|notfound|unavailable."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return "ok", resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "notfound", str(exc.code)
        return "unavailable", str(exc.code)
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable", ""


def check_live(catalog: dict, timeout: float) -> list[dict]:
    findings: list[dict] = []
    for key, fact in catalog["packages"].items():
        pkg = str(fact["package"])
        status, body = _get(f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='@')}/latest", timeout,
                            "application/json")
        if status == "notfound":
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{pkg} gone from npm: renamed or removed, review the skill"})
            continue
        if status != "ok":
            findings.append({"check": f"npm:{key}", "status": "unavailable",
                             "detail": f"npm registry unreachable for {pkg}"})
            continue
        try:
            version = str(json.loads(body).get("version", ""))
        except json.JSONDecodeError:
            findings.append({"check": f"npm:{key}", "status": "unavailable", "detail": "bad json"})
            continue
        major = version.split(".")[0]
        documented = fact.get("documented_major")
        if documented is not None and major != str(documented):
            findings.append({"check": f"npm:{key}", "status": "drift",
                             "detail": f"{pkg}@{version} major {major} != documented v{documented}: "
                                       "read the migration guide, re-check the privacy defaults"})
        else:
            findings.append({"check": f"npm:{key}", "status": "ok", "detail": f"latest {version}"})

    status, body = _get(str(catalog["data_collection_source"]), timeout)
    block = DEFAULTS_BLOCK_RE.search(body) if status == "ok" else None
    if status == "unavailable":
        findings.append({"check": "data-collection-keys", "status": "unavailable",
                         "detail": "could not fetch the SDK's defaults"})
    elif not block:
        findings.append({"check": "data-collection-keys", "status": "drift",
                         "detail": "SDK defaults moved or changed shape: re-read dataCollection by hand"})
    else:
        live = sorted(TOP_KEY_RE.findall(block.group(1)))
        want = sorted(catalog["data_collection_keys"])
        if live != want:
            findings.append({"check": "data-collection-keys", "status": "drift",
                             "detail": f"new in SDK (defaults ON, not in the baseline): {sorted(set(live) - set(want))}; "
                                       f"gone: {sorted(set(want) - set(live))}"})
        else:
            findings.append({"check": "data-collection-keys", "status": "ok",
                             "detail": f"{len(live)} categories match"})

    for page in catalog.get("doc_pages", []):
        url, marker = str(page["url"]), str(page["marker"])
        status, body = _get(url, timeout)
        short = url.replace("https://docs.sentry.io/", "")
        if status == "unavailable":
            findings.append({"check": f"doc:{short}", "status": "unavailable", "detail": "unreachable"})
        elif status == "notfound" or "Page Not Found" in body[:300]:
            findings.append({"check": f"doc:{short}", "status": "drift", "detail": "page gone"})
        elif marker not in body:
            findings.append({"check": f"doc:{short}", "status": "drift", "detail": f"no longer names {marker!r}"})
        else:
            findings.append({"check": f"doc:{short}", "status": "ok", "detail": f"names {marker!r}"})
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-sentry-facts.py",
        description="Verify sentry-ops' SDK major, packages and privacy baseline stay stated and current.",
        epilog=("Examples:\n"
                "  check-sentry-facts.py --offline\n"
                "  check-sentry-facts.py --live\n"
                "  check-sentry-facts.py --offline --json | jq '.data[]'\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe npm, the SDK's defaults and the docs")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    catalog = load_catalog(Path(args.catalog))
    findings = check_live(catalog, args.timeout) if args.live else check_offline(catalog, Path(args.skill))
    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({"data": findings, "meta": {"count": len(findings), "schema": SCHEMA,
                                                     "mode": "live" if args.live else "offline"}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")
    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-sentry-facts: {verdict} ({len(findings)} checks, {len(drift)} drift)", file=sys.stderr)
    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
