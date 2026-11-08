#!/usr/bin/env python3
"""Staleness verifier for linear-ops: stated Linear facts stay named and stay true.

linear-ops encodes endpoints, rate limits, schema limits and an MCP tool list. Those
drift silently (SKILL-RESOURCE-PROTOCOL.md section 7). Two modes:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/linear-facts.json parses, with the schema and an as_of date
    * SKILL.md carries a dated "Verified against the Linear MCP ... (YYYY-MM)" note
    * every prose_token and every MCP tool name is still named in the skill prose
    * every agent_ops fact (practice learned running agents in Linear) still names its prose_token,
      carries a valid evidence tag, and points at a shipped file that exists
    * SKILL.md's stated tool count matches the catalog
  --live (scheduled freshness job, never a PR gate):
    * each npm package resolves. A version change is NOT drift: @linear/sdk's major
      moves about weekly by design
    * each endpoint exists (404/410 is drift; 401, 405 and the like mean it is there)
    * the published GraphQL schema still contains each asserted sentence
    * each docs page is live, and each tripwire still contains its facts

Usage:   check-linear-facts.py [--offline | --live] [--catalog FILE] [--skill DIR]
                               [--npm-registry URL] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin).
Output:  stdout = findings (tab-separated rows, or a --json envelope). Data only.
Stderr:  the verdict line, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 a live source was unreachable (advisory, never a real failure),
         10 drift found

Examples:
  check-linear-facts.py --offline                 # PR CI: facts <-> prose consistency
  check-linear-facts.py --live                    # weekly: still true out there?
  check-linear-facts.py --offline --json | jq '.data[] | select(.status=="drift")'
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

SCHEMA = "claude-mods.linear-ops.facts/v1"
REQUIRED_KEYS = ("packages", "endpoints", "schema_sdl", "docs_liveness", "docs_tripwires", "mcp_tools")
EVIDENCE_TAGS = ("measured", "schema", "inferred", "untested")  # how sure the skill is of an agent_ops fact

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "linear-facts.json"
DEFAULT_SKILL = HERE.parent
NPM_REGISTRY = "https://registry.npmjs.org"
USER_AGENT = "claude-mods-linear-ops-check/1"

CURRENCY_RE = re.compile(r"Verified against the Linear MCP[^(]*\((\d{4}-\d{2})\)", re.IGNORECASE)
TOOL_COUNT_RE = re.compile(r"all (\d+)\s+tool names")
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
        for key in REQUIRED_KEYS:
            if key not in data:
                raise ValueError(f"missing key {key!r}")
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
    for ref in sorted((skill_dir / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def check_offline(catalog: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    findings: list[dict] = []

    def add(check: str, ok: bool, good: str, bad: str) -> None:
        findings.append({"check": check, "status": "ok" if ok else "drift", "detail": good if ok else bad})

    m = CURRENCY_RE.search(skill_md)
    add("currency-note", bool(m), f"dated {m.group(1)}" if m else "",
        "no dated 'Verified against the Linear MCP ... (YYYY-MM)' note in SKILL.md")

    tools = catalog["mcp_tools"]
    m = TOOL_COUNT_RE.search(skill_md)
    add("tool-count", bool(m) and int(m.group(1)) == len(tools), f"{len(tools)} tools",
        f"SKILL.md says {m.group(1) if m else 'nothing'}, catalog has {len(tools)}")

    for fact in catalog["packages"] + catalog["endpoints"]:
        token = str(fact["prose_token"])
        add(f"fact:{fact['key']}", token in corpus, f"{token} named", f"{token} no longer named in skill prose")

    # Word boundaries so `get_issue` is not satisfied by `get_issue_status`.
    missing = [t for t in tools if not re.search(rf"(?<![A-Za-z0-9_]){re.escape(t)}(?![A-Za-z0-9_])", corpus)]
    add("mcp-tools", not missing, f"all {len(tools)} named", "not named in prose: " + ", ".join(missing))
    # agent_ops is optional so an older catalog still loads. It holds practice, not Linear's contract:
    # a fact stays only while the prose names it, its evidence tag is honest, and its shipped file exists.
    for fact in catalog.get("agent_ops", []):
        token, tag, rel = str(fact["prose_token"]), fact.get("evidence"), fact.get("file")
        add(f"agent-ops:{fact['key']}", token in corpus and tag in EVIDENCE_TAGS and (not rel or (skill_dir / rel).is_file()),
            f"{token} named ({tag})",
            f"{token} not named in prose, or evidence {tag!r} not one of {EVIDENCE_TAGS}, or missing file {rel}")
    return findings


def _fetch(url: str, timeout: float) -> tuple[str, int, str]:
    """Return (kind, http_status, body). kind is ok | gone | present | unavailable."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return "ok", resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return "gone", exc.code, ""
        # Rate limits and server errors say nothing about the fact itself.
        if exc.code == 429 or exc.code >= 500:
            return "unavailable", exc.code, ""
        return "present", exc.code, ""
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return "unavailable", 0, str(exc)


def check_live(catalog: dict, timeout: float, registry: str) -> list[dict]:
    findings: list[dict] = []

    def add(check: str, status: str, detail: str) -> None:
        findings.append({"check": check, "status": status, "detail": detail})

    for fact in catalog["packages"]:
        pkg = str(fact["package"])
        kind, code, body = _fetch(f"{registry}/{urllib.parse.quote(pkg, safe='@')}/latest", timeout)
        if kind == "ok":
            try:
                add(f"npm:{fact['key']}", "ok", f"{pkg} latest {json.loads(body).get('version', '?')}")
            except json.JSONDecodeError:
                add(f"npm:{fact['key']}", "unavailable", f"{pkg}: registry returned bad JSON")
        elif kind == "gone":
            add(f"npm:{fact['key']}", "drift", f"{pkg} gone from npm ({code}): renamed or removed, review skill")
        else:
            add(f"npm:{fact['key']}", "unavailable", f"npm unreachable for {pkg} ({code})")

    for fact in catalog["endpoints"]:
        kind, code, _ = _fetch(str(fact["url"]), timeout)
        if kind == "gone":
            add(f"endpoint:{fact['key']}", "drift", f"{fact['url']} returned {code}")
        elif kind == "unavailable":
            add(f"endpoint:{fact['key']}", "unavailable", f"{fact['url']} unreachable ({code})")
        else:
            add(f"endpoint:{fact['key']}", "ok", f"answers ({code})")

    sdl = catalog["schema_sdl"]
    kind, code, body = _fetch(str(sdl["url"]), max(timeout, 30.0))
    if kind == "ok":
        for needle in sdl["assert_contains"]:
            if needle in body:
                add("schema", "ok", f"contains: {needle}")
            else:
                add("schema", "drift", f"published schema no longer contains: {needle}")
    elif kind == "unavailable":
        add("schema", "unavailable", f"schema unreachable ({code})")
    else:
        add("schema", "drift", f"schema URL returned {code}: {sdl['url']}")

    for url in catalog["docs_liveness"]:
        kind, code, _ = _fetch(str(url), timeout)
        if kind == "ok":
            add("docs", "ok", f"live: {url}")
        elif kind == "unavailable":
            add("docs", "unavailable", f"unreachable ({code}): {url}")
        else:
            add("docs", "drift", f"{code}: {url}")

    for wire in catalog["docs_tripwires"]:
        url = str(wire["url"])
        kind, code, body = _fetch(url, timeout)
        if kind == "unavailable":
            add("tripwire", "unavailable", f"unreachable ({code}): {url}")
        elif kind != "ok":
            add("tripwire", "drift", f"{code}: {url}")
        else:
            for needle in wire["contains"]:
                if needle in body:
                    add("tripwire", "ok", f"{url} contains {needle}")
                else:
                    add("tripwire", "drift", f"{url} no longer contains {needle}")
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-linear-facts.py",
        description="Verify linear-ops' Linear facts stay stated (offline) and true (live).",
        epilog=(
            "Examples:\n"
            "  check-linear-facts.py --offline\n"
            "  check-linear-facts.py --live\n"
            "  check-linear-facts.py --offline --json | jq '.data[]'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="probe npm, endpoints, schema and docs")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory")
    p.add_argument("--npm-registry", default=NPM_REGISTRY, help="npm registry base URL (live)")
    p.add_argument("--timeout", type=float, default=15.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    catalog = load_catalog(Path(args.catalog))
    findings = (check_live(catalog, args.timeout, args.npm_registry.rstrip("/")) if args.live
                else check_offline(catalog, Path(args.skill)))

    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "mode": "live" if args.live else "offline",
                                   "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")

    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-linear-facts: {verdict} ({len(findings)} checks, {len(drift)} drift, "
              f"{len(unavailable)} unavailable)", file=sys.stderr)

    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
