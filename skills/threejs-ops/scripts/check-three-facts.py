#!/usr/bin/env python3
# Staleness verifier for the fast-moving facts the threejs-ops skill encodes.
#
# Two modes (SKILL-RESOURCE-PROTOCOL.md §7):
#   --offline (default): NO network. Asserts the skill is internally consistent —
#                        assets/three-facts.json parses, the version gates
#                        (examples/js removed r148, UMD builds removed r160) are
#                        stated in SKILL.md, the npm 0.<release> scheme example is
#                        arithmetically coherent, every package the facts file
#                        commits to is documented somewhere in the skill, and the
#                        importmap-starter.html import map parses with both "three"
#                        entries pinned to the same version. Runs in PR CI, MAY block.
#   --live:              network. Probes the npm registry: every committed package
#                        must still resolve (a 404 means renamed/removed = drift),
#                        and three's latest dist-tag must still use major 0
#                        (a 1.x would be the API-break signal that the whole skill
#                        needs a review pass). Runs in the scheduled freshness
#                        workflow and NEVER blocks a PR: transient network failure
#                        is UNAVAILABLE (exit 7); only confirmed change is DRIFT (10).
#
# Usage:   check-three-facts.py [--offline|--live] [--json] [-q] [--timeout SEC]
# Input:   none (reads the skill's own assets/ + references/ relative to this file)
# Output:  stdout = data only (TSV findings, or the --json envelope)
# Stderr:  headers, progress, warnings, errors
# Exit:    0 ok, 2 usage, 3 not-found (skill files missing), 4 validation
#          (offline inconsistency), 7 unavailable (live network), 10 drift
#
# Examples:
#   check-three-facts.py --offline
#   check-three-facts.py --offline --json | jq '.data[] | select(.status!="ok")'
#   check-three-facts.py --live --timeout 15
"""Staleness verifier for threejs-ops (see header comment)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_UNAVAILABLE = 7
EXIT_DRIFT = 10

SCHEMA = "claude-mods.threejs-ops.facts/v1"

SKILL_ROOT = Path(__file__).resolve().parent.parent
FACTS = SKILL_ROOT / "assets" / "three-facts.json"
STARTER = SKILL_ROOT / "assets" / "importmap-starter.html"
REFS = SKILL_ROOT / "references"
SKILL_MD = SKILL_ROOT / "SKILL.md"

REGISTRY = "https://registry.npmjs.org"


class Finding:
    __slots__ = ("check", "status", "detail")

    def __init__(self, check: str, status: str, detail: str) -> None:
        self.check = check
        self.status = status  # ok | fail | drift | unavailable
        self.detail = detail

    def as_dict(self) -> dict:
        return {"check": self.check, "status": self.status, "detail": self.detail}


class _NotFound(Exception):
    pass


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def load_facts(findings: list[Finding]) -> dict | None:
    try:
        facts = json.loads(read_text(FACTS))
        findings.append(Finding("facts-json", "ok", "three-facts.json parses"))
        return facts
    except json.JSONDecodeError as exc:
        findings.append(Finding("facts-json", "fail", f"invalid JSON: {exc}"))
        return None


# --------------------------------------------------------------------------- #
# Offline checks                                                              #
# --------------------------------------------------------------------------- #
def run_offline(findings: list[Finding]) -> None:
    missing = [p for p in (FACTS, STARTER, SKILL_MD, REFS) if not p.exists()]
    if missing:
        for p in missing:
            findings.append(Finding("files-present", "fail", f"missing: {p}"))
        raise _NotFound()

    facts = load_facts(findings)
    if facts is None:
        return  # nothing else is checkable

    skill_md = read_text(SKILL_MD)
    all_docs = skill_md + "".join(read_text(p) for p in sorted(REFS.glob("*.md")))

    # O1 — schema + as_of stamped.
    if facts.get("schema") == SCHEMA and re.match(r"\d{4}-\d{2}-\d{2}$", facts.get("as_of", "")):
        findings.append(Finding("facts-meta", "ok", f"schema {SCHEMA}, as_of {facts['as_of']}"))
    else:
        findings.append(Finding("facts-meta", "fail",
                                f"schema={facts.get('schema')!r} as_of={facts.get('as_of')!r}"))

    # O2 — version gates stated in SKILL.md exactly as the facts commit to them.
    gates = facts.get("version_gates", {})
    for key, gate in (("examples_js_removed", gates.get("examples_js_removed")),
                      ("umd_builds_removed", gates.get("umd_builds_removed"))):
        if not gate or not re.match(r"r\d{3}$", gate):
            findings.append(Finding(f"gate:{key}", "fail", f"malformed gate {gate!r} in facts"))
        elif re.search(rf"\*\*{gate}\*\*|\b{gate}\b", skill_md):
            findings.append(Finding(f"gate:{key}", "ok", f"{gate} stated in SKILL.md"))
        else:
            findings.append(Finding(f"gate:{key}", "fail", f"{gate} not stated in SKILL.md"))

    # O3 — npm scheme example arithmetic: "three@0.NNN.p is rNNN".
    scheme = facts.get("npm_scheme", {})
    m = re.match(r"three@0\.(\d+)\.\d+ is r(\d+)$", scheme.get("example", ""))
    if m and m.group(1) == m.group(2) and scheme.get("major") == 0:
        findings.append(Finding("npm-scheme", "ok", f"example coherent ({scheme['example']})"))
    else:
        findings.append(Finding("npm-scheme", "fail",
                                f"example {scheme.get('example')!r} incoherent or major != 0"))

    # O4 — every committed package is documented somewhere in the skill prose.
    pkgs = facts.get("packages", {})
    if not pkgs:
        findings.append(Finding("packages", "fail", "facts commit to zero packages"))
    for name in pkgs:
        if name in all_docs:
            findings.append(Finding(f"pkg-documented:{name}", "ok", "mentioned in SKILL.md/references"))
        else:
            findings.append(Finding(f"pkg-documented:{name}", "fail",
                                    "in facts but never mentioned in skill prose"))

    # O5 — importmap starter: the import map parses, has both entries, pins one version.
    starter = read_text(STARTER)
    im = re.search(r'<script type="importmap">\s*(\{.*?\})\s*</script>', starter, re.S)
    if not im:
        findings.append(Finding("importmap", "fail", "no importmap block in starter"))
    else:
        try:
            imports = json.loads(im.group(1))["imports"]
            three_url = imports.get("three", "")
            addons_url = imports.get("three/addons/", "")
            v_three = re.search(r"three@(0\.\d+\.\d+)/", three_url)
            v_addons = re.search(r"three@(0\.\d+\.\d+)/", addons_url)
            if not (v_three and v_addons):
                findings.append(Finding("importmap", "fail",
                                        "starter import map missing pinned three/addons entries"))
            elif v_three.group(1) != v_addons.group(1):
                findings.append(Finding("importmap", "fail",
                                        f"version mismatch: three@{v_three.group(1)} vs addons@{v_addons.group(1)}"))
            elif not addons_url.endswith("/"):
                findings.append(Finding("importmap", "fail", "three/addons/ URL missing trailing slash"))
            else:
                findings.append(Finding("importmap", "ok",
                                        f"both entries pinned to three@{v_three.group(1)}"))
        except (json.JSONDecodeError, KeyError) as exc:
            findings.append(Finding("importmap", "fail", f"import map does not parse: {exc}"))

    # O6 — every cc0 source / reference repo has an https url.
    for group in ("cc0_sources", "reference_repos"):
        bad = [e.get("id", "?") for e in facts.get(group, [])
               if not str(e.get("url", "")).startswith("https://")]
        if bad:
            findings.append(Finding(group, "fail", "no https url: " + ", ".join(bad)))
        else:
            findings.append(Finding(group, "ok", f"{len(facts.get(group, []))} entries addressable"))


# --------------------------------------------------------------------------- #
# Live checks                                                                 #
# --------------------------------------------------------------------------- #
def run_live(findings: list[Finding], timeout: float) -> None:
    import urllib.error
    import urllib.request

    facts = load_facts(findings)
    if facts is None:
        raise _NotFound()

    def fetch_latest(pkg: str) -> tuple[str, dict | None]:
        """Return (resolved|notfound|unavailable, latest-manifest-or-None)."""
        url = f"{REGISTRY}/{quote(pkg, safe='')}/latest"
        req = urllib.request.Request(url, headers={"User-Agent": "threejs-ops-staleness/1",
                                                   "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status >= 400:
                    return "unavailable", None
                return "resolved", json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return "notfound", None
            return "unavailable", None
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
            return "unavailable", None

    # L1 — every committed package still resolves on npm.
    for name in facts.get("packages", {}):
        res, manifest = fetch_latest(name)
        if res == "resolved":
            findings.append(Finding(f"npm:{name}", "ok",
                                    f"latest {(manifest or {}).get('version', '?')}"))
        elif res == "notfound":
            findings.append(Finding(f"npm:{name}", "drift",
                                    "package gone from npm — renamed/removed, review skill"))
        else:
            findings.append(Finding(f"npm:{name}", "unavailable", "registry unreachable"))

    # L2 — three's versioning scheme still major-0 (a 1.x = API-break signal).
    res, manifest = fetch_latest("three")
    if res == "resolved":
        ver = (manifest or {}).get("version", "")
        if ver.startswith("0."):
            findings.append(Finding("three-major", "ok", f"three@{ver} still 0.<release> scheme"))
        else:
            findings.append(Finding("three-major", "drift",
                                    f"three@{ver} left major 0 — review the whole skill"))
    elif res == "notfound":
        findings.append(Finding("three-major", "drift", "npm has no 'three' package (!)"))
    else:
        findings.append(Finding("three-major", "unavailable", "registry unreachable"))


# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True, description="threejs-ops staleness verifier")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural/internal-consistency only (default)")
    mode.add_argument("--live", action="store_true", help="probe the npm registry (network)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    ap.add_argument("-q", "--quiet", action="store_true", help="suppress stderr progress")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-request timeout for --live (seconds)")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        # argparse exits 2 on bad args (matches USAGE); 0 on --help.
        return EXIT_USAGE if e.code not in (0, None) else EXIT_OK

    mode_name = "live" if args.live else "offline"

    def emit(msg: str) -> None:
        if not args.quiet:
            print(msg, file=sys.stderr)

    findings: list[Finding] = []
    emit(f"== check-three-facts ({mode_name}) ==")
    try:
        if args.live:
            run_live(findings, args.timeout)
        else:
            run_offline(findings)
    except _NotFound:
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND",
                                        "message": "skill files missing",
                                        "details": [f.as_dict() for f in findings]}}))
        for f in findings:
            emit(f"  [{f.status.upper()}] {f.check}: {f.detail}")
        return EXIT_NOT_FOUND

    n_fail = sum(1 for f in findings if f.status == "fail")
    n_drift = sum(1 for f in findings if f.status == "drift")
    n_unavail = sum(1 for f in findings if f.status == "unavailable")

    # Output: stdout is data only.
    if args.json:
        print(json.dumps({
            "data": [f.as_dict() for f in findings],
            "meta": {"mode": mode_name, "count": len(findings),
                     "fail": n_fail, "drift": n_drift, "unavailable": n_unavail,
                     "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"{f.check}\t{f.status}\t{f.detail}")

    # Progress summary to stderr.
    for f in findings:
        if f.status != "ok":
            emit(f"  [{f.status.upper()}] {f.check}: {f.detail}")
    emit(f"-- {len(findings)} checks: {n_fail} fail, {n_drift} drift, {n_unavail} unavailable")

    # Exit precedence: inconsistency (offline) beats drift beats unavailable;
    # if the ONLY non-ok results are unavailable, exit 7, never 0.
    if n_fail:
        return EXIT_VALIDATION
    if n_drift:
        return EXIT_DRIFT
    if n_unavail:
        return EXIT_UNAVAILABLE
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
