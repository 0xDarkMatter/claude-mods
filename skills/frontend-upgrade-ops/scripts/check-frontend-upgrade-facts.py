#!/usr/bin/env python3
"""Staleness verifier for frontend-upgrade-ops: the Vite / Vue / craft-vite facts the
skill encodes must stay real and named in the prose.

The skill's advice is pinned to specific majors and dates: Vite 8, Vue 3 via
@vue/compat, Pinia 4, craft-vite 5, Vue 2's 31 December 2023 end of life, Mix's
last release, and - load-bearing for the whole upgrade order - @vitejs/plugin-vue2
accepting Vite only up to ^7. Any of those can move under the prose without anyone
noticing (SKILL-RESOURCE-PROTOCOL.md §7). Two modes guard it:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/frontend-upgrade-facts.json parses; every package prose token and every
      dated fact is named somewhere in SKILL.md / references/*.md
    * SKILL.md still carries a dated "as of <year>" currency note
  --live (scheduled freshness.yml, never a PR gate):
    * npm packages: latest dist-tag major vs documented_major
    * Packagist packages: highest stable major vs documented_major
    * peer_watch: the latest release's peer range for the watched dependency still
      tops out at documented_max_major (else the sequencing advice is stale)
    Gone (404) is DRIFT; transient registry failure is UNAVAILABLE (exit 7).

Usage:   check-frontend-upgrade-facts.py [--offline | --live] [--facts FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 facts/skill missing, 4 facts unparseable,
         7 registry unreachable (live, advisory - never a real failure),
         10 drift (offline: uncited token / missing note; live: major ahead, gone, peer widened)

Examples:
  check-frontend-upgrade-facts.py --offline              # PR CI: catalogue <-> prose
  check-frontend-upgrade-facts.py --live                 # weekly: did Vite/Vue/craft-vite move?
  check-frontend-upgrade-facts.py --offline --json | jq '.data[]'
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.frontend-upgrade-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_FACTS = HERE.parent / "assets" / "frontend-upgrade-facts.json"
DEFAULT_SKILL = HERE.parent
NPM = "https://registry.npmjs.org"
# p2 metadata lists every tagged version of a package (newest first) - stable and
# pre-release alike, hence the pre-release filter in packagist_major().
PACKAGIST = "https://repo.packagist.org/p2"
REGISTRIES = ("npm", "packagist")
CURRENCY_RE = re.compile(r"as of 20\d\d")
UA = {"User-Agent": "claude-mods-frontend-upgrade-ops-check/1", "Accept": "application/json"}


class Term:
    """Minimal ANSI helper. Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the
    bound stream's TTY + encoding so piped data stays plain ASCII."""

    _C = {"green": "\033[32m", "red": "\033[31m", "dim": "\033[2m", "off": "\033[0m"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = os.environ.get("TERM_ASCII") == "1" or "utf" not in enc
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None
              or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, ok):
        g = ("+" if self.ascii else "✓") if ok else ("x" if self.ascii else "✗")
        return self.c("green" if ok else "red", g)


def load_facts(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalogue not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("schema") != SCHEMA:
            raise ValueError(f"schema {data.get('schema')!r} != {SCHEMA!r}")
        if not isinstance(data.get("packages"), dict) or not data["packages"]:
            raise ValueError("'packages' must be a non-empty object")
        for name, info in data["packages"].items():
            if not isinstance(info, dict) or not isinstance(info.get("documented_major"), int):
                raise ValueError(f"package {name!r} needs an integer documented_major")
            if info.get("registry", "npm") not in REGISTRIES:
                raise ValueError(f"package {name!r} registry must be one of {REGISTRIES}")
            if not isinstance(info.get("prose"), list) or not info["prose"]:
                raise ValueError(f"package {name!r} missing prose tokens")
        for name, watch in data.get("peer_watch", {}).items():
            if name == "_comment":
                continue
            if not isinstance(watch, dict) or "peer" not in watch \
                    or not isinstance(watch.get("documented_max_major"), int):
                raise ValueError(f"peer_watch {name!r} needs 'peer' + integer documented_max_major")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """Returns (skill_md_text, all_prose_text) across SKILL.md + references/*.md."""
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    parts = [skill_md]
    for ref in sorted((skill_dir / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def check_offline(facts: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    findings: list[dict] = []
    for name, info in facts["packages"].items():
        for token in info["prose"]:
            if token not in corpus:
                findings.append({"package": name, "issue": f"prose token {token!r} not named in skill"})
    for key, token in facts.get("dated_facts", {}).items():
        if key == "_comment":
            continue
        if str(token) not in corpus:
            findings.append({"package": "(dated fact)", "issue": f"{key}={token!r} not stated in skill prose"})
    if not CURRENCY_RE.search(skill_md):
        findings.append({"package": "(SKILL.md)", "issue": "no dated 'as of <year>' currency note"})
    return findings


def fetch_json(url: str, timeout: float) -> tuple[str, Any]:
    """Return (ok|notfound|unavailable, parsed-json-or-status)."""
    req = urllib.request.Request(url, method="GET", headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return ("ok", json.loads(resp.read().decode("utf-8")))
    except urllib.error.HTTPError as exc:
        return ("notfound", exc.code) if exc.code in (404, 410) else ("unavailable", exc.code)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return ("unavailable", str(getattr(exc, "reason", exc)))


def major_of(version: str) -> int | None:
    m = re.match(r"v?(\d+)", str(version).strip())
    return int(m.group(1)) if m else None


def npm_latest(name: str, timeout: float) -> tuple[str, Any]:
    return fetch_json(f"{NPM}/{urllib.parse.quote(name, safe='')}/latest", timeout)


def packagist_major(name: str, timeout: float) -> tuple[str, Any]:
    status, body = fetch_json(f"{PACKAGIST}/{name}.json", timeout)
    if status != "ok":
        return (status, body)
    try:
        versions = [v.get("version", "") for v in body["packages"][name]]
    except (KeyError, TypeError, AttributeError):
        return ("unavailable", "unexpected Packagist payload")
    stable = [major_of(v) for v in versions if v and "-" not in v and not v.startswith("dev-")]
    stable = [m for m in stable if m is not None]
    return ("ok", max(stable)) if stable else ("unavailable", "no stable versions listed")


def peer_max_major(range_spec: str) -> int | None:
    """Highest major a semver range admits, e.g. '^3.0.0 || ^7.0.0' -> 7.
    Open-ended ranges ('>=7', '*') return None: treated as widened."""
    if not range_spec or re.search(r">=|>(?!=)|\*|\bx\b|latest", range_spec):
        return None
    majors = [int(m) for m in re.findall(r"(?:^|[\s|^~=<])v?(\d+)(?=\.|\s|$|\|)", range_spec)]
    return max(majors) if majors else None


def check_live(facts: dict, timeout: float) -> tuple[list[dict], list[dict]]:
    drift: list[dict] = []
    unreachable: list[dict] = []
    for name, info in facts["packages"].items():
        documented = info["documented_major"]
        if info.get("registry", "npm") == "packagist":
            status, val = packagist_major(name, timeout)
            live = val if status == "ok" else None
            shown = f"{val}.x" if status == "ok" else val
        else:
            status, val = npm_latest(name, timeout)
            live = major_of(val.get("version", "")) if status == "ok" else None
            shown = val.get("version") if status == "ok" else val
        if status == "notfound":
            drift.append({"package": name, "issue": f"no longer resolves ({val}) - renamed/removed"})
        elif status == "unavailable" or (status == "ok" and live is None):
            unreachable.append({"package": name, "issue": f"registry unreachable or unparseable: {shown}"})
        elif live > documented:
            drift.append({"package": name,
                          "issue": f"live major {live} ({shown}) ahead of documented major {documented}"})
    for name, watch in facts.get("peer_watch", {}).items():
        if name == "_comment":
            continue
        status, val = npm_latest(name, timeout)
        if status != "ok":
            (drift if status == "notfound" else unreachable).append(
                {"package": name, "issue": f"peer_watch lookup failed: {val}"})
            continue
        spec = (val.get("peerDependencies") or {}).get(watch["peer"], "")
        top = peer_max_major(spec)
        if top is None or top > watch["documented_max_major"]:
            drift.append({"package": name,
                          "issue": f"peer {watch['peer']} range {spec!r} now admits more than "
                                   f"major {watch['documented_max_major']} - re-check SKILL.md sequencing"})
    return drift, unreachable


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-frontend-upgrade-facts.py",
        description="Verify frontend-upgrade-ops' Vite/Vue/craft-vite facts stay named (offline) "
                    "and current on npm + Packagist (live).",
        epilog="Examples:\n"
               "  check-frontend-upgrade-facts.py --offline\n"
               "  check-frontend-upgrade-facts.py --live --json | jq '.data[]'",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="registry majors + peer ranges vs documented")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalogue JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    facts = load_facts(Path(args.facts))
    t = Term(sys.stderr)
    n_pkgs = len(facts["packages"])

    if args.live:
        drift, unreachable = check_live(facts, args.timeout)
        findings = drift + unreachable
        if args.json:
            print(json.dumps({
                "data": findings,
                "meta": {"mode": "live", "packages_checked": n_pkgs,
                         "drift": len(drift), "unreachable": len(unreachable),
                         "registries": [NPM, PACKAGIST], "schema": SCHEMA},
            }, indent=2))
        else:
            for f in findings:
                print(f"{'DRIFT' if f in drift else 'UNREACH'}  {f['package']}: {f['issue']}")
        if drift:
            print(f"{t.mark(False)} frontend-upgrade-facts/live: {len(drift)} drifted", file=sys.stderr)
            return EX_DRIFT
        if unreachable:
            print(f"{t.mark(False)} frontend-upgrade-facts/live: unreachable for {len(unreachable)} "
                  f"{t.c('dim', '(advisory - retry next run)')}", file=sys.stderr)
            return EX_UNAVAILABLE
        print(f"{t.mark(True)} frontend-upgrade-facts/live: {n_pkgs} package(s) at or below "
              f"documented major, peer ranges unchanged", file=sys.stderr)
        return EX_OK

    findings = check_offline(facts, Path(args.skill))
    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"mode": "offline", "packages_checked": n_pkgs,
                     "drift": len(findings), "consistent": not findings, "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"DRIFT  {f['package']}: {f['issue']}")
    ok = not findings
    n_dated = sum(1 for k in facts.get("dated_facts", {}) if k != "_comment")
    print(f"{t.mark(ok)} frontend-upgrade-facts/offline: {n_pkgs} package(s) + {n_dated} dated fact(s) "
          f"checked, {len(findings)} inconsistency {t.c('dim', '(catalogue vs skill prose)')}",
          file=sys.stderr)
    return EX_DRIFT if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
