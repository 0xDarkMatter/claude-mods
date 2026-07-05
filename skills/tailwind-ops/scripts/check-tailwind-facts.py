#!/usr/bin/env python3
"""Staleness verifier for tailwind-ops: the Tailwind v4 facts the skill encodes
must stay real and named in the prose.

tailwind-ops centers on Tailwind CSS v4 (CSS-first config: @theme, @plugin,
@config, @import "tailwindcss"; @tailwindcss/postcss + @tailwindcss/vite) and
the v3->v4 migration. That is exactly the fact that drifts silently
(SKILL-RESOURCE-PROTOCOL.md §7): Tailwind ships a new major, a v4 directive is
renamed, or the prose stops mentioning a package the catalog lists, and nobody
notices for months. Two modes guard it:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/tailwind-facts.json parses and every package + v4 directive gate is
      named somewhere in the skill prose (SKILL.md / references/*.md) — the
      catalog can't drift from the docs
    * SKILL.md still carries a dated "as of <year>" currency note
  --live (scheduled freshness.yml, never a PR gate): query the npm registry for
    each package's latest dist-tag; flag DRIFT when the live major is newer than
    the documented major (the skill is now behind — e.g. tailwindcss 5 while the
    prose still says v4), or when a package is gone (404). Transient registry
    failure is UNAVAILABLE (exit 7), never a failure.

Usage:   check-tailwind-facts.py [--offline | --live] [--facts FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 facts/skill missing, 4 facts unparseable,
         7 npm registry unreachable (live, advisory — never a real failure),
         10 drift (offline: uncited/undocumented/missing note; live: major ahead or gone)

Examples:
  check-tailwind-facts.py --offline                 # PR CI: catalog ⇆ prose consistency
  check-tailwind-facts.py --live                    # weekly: is any documented major behind npm?
  check-tailwind-facts.py --offline --json | jq '.data[]'
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

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.tailwind-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_FACTS = HERE.parent / "assets" / "tailwind-facts.json"
DEFAULT_SKILL = HERE.parent
REGISTRY = "https://registry.npmjs.org"
CURRENCY_RE = re.compile(r"as of 20\d\d")


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
        print(f"error: facts catalog not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("schema") != SCHEMA:
            raise ValueError(f"schema {data.get('schema')!r} != {SCHEMA!r}")
        if not isinstance(data.get("packages"), dict) or not data["packages"]:
            raise ValueError("'packages' must be a non-empty object")
        for name, info in data["packages"].items():
            if not isinstance(info, dict) or "documented_major" not in info:
                raise ValueError(f"package {name!r} missing documented_major")
            if not isinstance(info.get("prose"), list) or not info["prose"]:
                raise ValueError(f"package {name!r} missing prose tokens")
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
    for key, token in facts.get("version_gates", {}).items():
        if key == "_comment":
            continue
        if str(token) not in corpus:
            findings.append({"package": "(gate)", "issue": f"version gate {key}={token!r} not stated in skill prose"})
    if not CURRENCY_RE.search(skill_md):
        findings.append({"package": "(SKILL.md)", "issue": "no dated 'as of <year>' currency note"})
    return findings


def npm_latest(name: str, timeout: float) -> tuple[str, object]:
    """Return (resolved|notfound|unavailable, version-string-or-status)."""
    url = f"{REGISTRY}/{urllib.parse.quote(name, safe='')}/latest"
    req = urllib.request.Request(url, method="GET",
                                 headers={"User-Agent": "claude-mods-tailwind-ops-check/1",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            manifest = json.loads(resp.read().decode("utf-8"))
            return ("resolved", manifest.get("version", ""))
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return ("notfound", exc.code)
        return ("unavailable", exc.code)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return ("unavailable", str(getattr(exc, "reason", exc)))


def major_of(version: str) -> int | None:
    m = re.match(r"\d+", version.strip())
    return int(m.group(0)) if m else None


def check_live(facts: dict, timeout: float) -> tuple[list[dict], list[dict]]:
    drift: list[dict] = []
    unreachable: list[dict] = []
    for name, info in facts["packages"].items():
        documented = info["documented_major"]
        status, info2 = npm_latest(name, timeout)
        if status == "notfound":
            drift.append({"package": name, "issue": "no longer resolves on npm (404) — renamed/removed"})
        elif status == "unavailable":
            unreachable.append({"package": name, "issue": f"registry unreachable: {info2}"})
        else:
            live = major_of(str(info2))
            if live is None:
                unreachable.append({"package": name, "issue": f"could not parse version {info2!r}"})
            elif live > documented:
                drift.append({"package": name,
                              "issue": f"live major {live} ({info2}) ahead of documented major {documented}"})
    return drift, unreachable


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-tailwind-facts.py",
        description="Verify tailwind-ops' Tailwind v4 facts stay named (offline) and current on npm (live).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="check each package's npm major vs documented")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    facts = load_facts(Path(args.facts))
    live = args.live and not args.offline
    t = Term(sys.stderr)

    if live:
        drift, unreachable = check_live(facts, args.timeout)
        findings = drift + unreachable
        if args.json:
            print(json.dumps({
                "data": findings,
                "meta": {"mode": "live", "packages_checked": len(facts["packages"]),
                         "drift": len(drift), "unreachable": len(unreachable),
                         "registry": REGISTRY, "schema": SCHEMA},
            }, indent=2))
        else:
            for f in findings:
                kind = "DRIFT" if f in drift else "UNREACH"
                print(f"{kind}  {f['package']}: {f['issue']}")
        if drift:
            print(f"{t.mark(False)} tailwind-facts/live: {len(drift)} package(s) drifted "
                  f"{t.c('dim', '(' + REGISTRY + ')')}", file=sys.stderr)
            return EX_DRIFT
        if unreachable:
            print(f"{t.mark(False)} tailwind-facts/live: npm unreachable for "
                  f"{len(unreachable)}/{len(facts['packages'])} {t.c('dim', '(advisory - retry next run)')}",
                  file=sys.stderr)
            return EX_UNAVAILABLE
        print(f"{t.mark(True)} tailwind-facts/live: all {len(facts['packages'])} package(s) "
              f"at or below documented major", file=sys.stderr)
        return EX_OK

    # offline (default)
    findings = check_offline(facts, Path(args.skill))
    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"mode": "offline", "packages_checked": len(facts["packages"]),
                     "drift": len(findings), "consistent": not findings, "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"DRIFT  {f['package']}: {f['issue']}")
    ok = not findings
    print(f"{t.mark(ok)} tailwind-facts/offline: {len(facts['packages'])} package(s) + "
          f"{sum(1 for k in facts.get('version_gates', {}) if k != '_comment')} gate(s) checked, "
          f"{len(findings)} inconsistency {t.c('dim', '(catalog vs skill prose)')}", file=sys.stderr)
    return EX_DRIFT if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
