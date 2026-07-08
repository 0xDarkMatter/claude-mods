#!/usr/bin/env python3
"""Staleness verifier for typescript-ops: the version-bearing facts the skill
encodes must stay real and cited.

typescript-ops anchors its currency to a few version-bearing facts — the
TypeScript major the prose assumes (feature floors like "TS 4.4+",
"TypeScript 4.7+"), and the runtime-validation stack (zod, valibot). That is
exactly the fact that drifts silently (SKILL-RESOURCE-PROTOCOL.md §7): a
package leaves its documented major upstream, or the prose stops naming a
package the catalog still commits to, and nobody notices for months. Two
modes guard it:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/typescript-facts.json parses; every entry has name + documented_major
    * every catalogued package is still named somewhere in the skill prose
      (SKILL.md / references/*.md) — the catalog can't drift from the docs
    * SKILL.md still carries a dated "as of 20XX" currency note
  --live (scheduled freshness.yml, never a PR gate): does each package's
    latest published major on npm still match the documented major? A newer
    major = the skill is behind reality (drift). Exit 7 if npm is unreachable.

Usage:   check-typescript-facts.py [--offline | --live] [--catalog FILE] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 npm unreachable (live, advisory — never a real failure),
         10 drift found (offline: uncited/undocumented/no currency note;
                         live: published major newer than documented major)

Examples:
  check-typescript-facts.py --offline                 # PR CI: catalog ⇆ prose consistency
  check-typescript-facts.py --live                     # weekly: every package's major still matches npm
  check-typescript-facts.py --offline --json | jq '.data[]'
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

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "typescript-facts.json"
DEFAULT_SKILL = HERE.parent
DEFAULT_REGISTRY = "https://registry.npmjs.org"
SCHEMA = "claude-mods.typescript-ops.facts/v1"
CURRENCY_RE = re.compile(r"as of 20\d\d")


def eprint(*a) -> None:
    print(*a, file=sys.stderr)


class Term:
    """Minimal ANSI helper (term.sh is bash-only; per TERMINAL-DESIGN.md §9 the
    Python port is inline). Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the
    bound stream's TTY + encoding so piped data stays plain ASCII."""

    _C = {"green": "\033[32m", "red": "\033[31m", "dim": "\033[2m", "off": "\033[0m"}

    def __init__(self, stream=sys.stderr) -> None:
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

    def c(self, name: str, text: str) -> str:
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, ok: bool) -> str:
        g = ("+" if self.ascii else "✓") if ok else ("x" if self.ascii else "✗")
        return self.c("green" if ok else "red", g)


def load_catalog(path: Path) -> tuple[list[dict], str]:
    """Returns (packages, registry). Each package has name + documented_major."""
    if not path.is_file():
        eprint(f"error: package catalog not found: {path}")
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        pkgs = data["packages"]
        if not isinstance(pkgs, list) or not pkgs:
            raise ValueError("'packages' must be a non-empty array")
        for p in pkgs:
            if not isinstance(p, dict) or "name" not in p or "documented_major" not in p:
                raise ValueError(f"package entry missing name/documented_major: {p!r}")
            dm = p["documented_major"]
            if not isinstance(dm, int) or isinstance(dm, bool) or dm < 0:
                raise ValueError(f"documented_major must be a non-negative int: {p!r}")
        registry = data.get("registry") or DEFAULT_REGISTRY
        return pkgs, registry
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        eprint(f"error: could not parse catalog {path}: {exc}")
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """Returns (skill_md_text, all_prose_text) across SKILL.md + references/*.md."""
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        eprint(f"error: SKILL.md not found under {skill_dir}")
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8")
    parts = [skill_md]
    for ref in sorted((skill_dir / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8"))
    return skill_md, "\n".join(parts)


def check_offline(pkgs: list[dict], skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    findings: list[dict] = []
    for p in pkgs:
        name = p["name"]
        # case-sensitive exact substring: npm names are case-sensitive (zod != Zod)
        if name not in corpus:
            findings.append({"package": name, "issue": "catalogued but not named in skill prose"})
    if not CURRENCY_RE.search(skill_md):
        findings.append({"package": "(SKILL.md)", "issue": "no dated 'as of 20XX' currency note"})
    return findings


def npm_latest(registry: str, name: str, timeout: float) -> tuple[str, object]:
    """Return ('ok', version_str) | ('gone', None) | ('unreachable', info)."""
    url = registry.rstrip("/") + "/" + urllib.parse.quote(name, safe="") + "/latest"
    req = urllib.request.Request(url, method="GET",
                                 headers={"User-Agent": "claude-mods-typescript-ops-check/1",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return ("ok", data.get("version", ""))
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return ("gone", None)
        return ("unreachable", exc.code)  # 5xx etc: transient, not a content finding
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return ("unreachable", str(getattr(exc, "reason", exc)))


def major_of(version: str) -> int | None:
    m = re.match(r"\D*(\d+)", version or "")
    return int(m.group(1)) if m else None


def check_live(pkgs: list[dict], registry: str, timeout: float) -> tuple[list[dict], list[dict]]:
    drift: list[dict] = []
    unreachable: list[dict] = []
    for p in pkgs:
        name = p["name"]
        doc = p["documented_major"]
        status, info = npm_latest(registry, name, timeout)
        if status == "gone":
            drift.append({"package": name, "issue": "no longer resolves on npm (404)"})
        elif status != "ok":
            unreachable.append({"package": name, "issue": f"unreachable: {info}"})
        else:
            live_major = major_of(str(info))
            if live_major is None:
                unreachable.append({"package": name, "issue": f"could not parse version {info!r}"})
            elif live_major > doc:
                drift.append({"package": name,
                              "issue": f"npm@{info} major {live_major} > documented major {doc}"})
    return drift, unreachable


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-typescript-facts.py",
        description="Verify typescript-ops' version-bearing facts stay cited (offline) and current on npm (live).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="check every package's latest major still matches npm")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=10.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    pkgs, registry = load_catalog(Path(args.catalog))
    live = args.live and not args.offline
    t = Term(sys.stderr)

    if live:
        drift, unreachable = check_live(pkgs, registry, args.timeout)
        findings = drift + unreachable
        if args.json:
            print(json.dumps({
                "data": findings,
                "meta": {"mode": "live", "packages_checked": len(pkgs),
                         "drift": len(drift), "unreachable": len(unreachable),
                         "registry": registry, "schema": SCHEMA},
            }, indent=2))
        else:
            for f in drift:
                print(f"DRIFT  {f['package']}: {f['issue']}")
            for f in unreachable:
                print(f"UNREACH  {f['package']}: {f['issue']}")
        # §7: confirmed drift -> 10; else transient/unreachable -> 7 (advisory); else 0.
        if drift:
            eprint(f"{t.mark(False)} ts-facts/live: {len(drift)} package(s) drifted from documented major "
                   f"{t.c('dim', '(' + registry + ')')}")
            return EX_DRIFT
        if unreachable:
            eprint(f"{t.mark(False)} ts-facts/live: npm unreachable for "
                   f"{len(unreachable)}/{len(pkgs)} {t.c('dim', '(advisory - retry next run)')}")
            return EX_UNAVAILABLE
        eprint(f"{t.mark(True)} ts-facts/live: all {len(pkgs)} package(s) match documented major on npm")
        return EX_OK

    # offline (default)
    findings = check_offline(pkgs, Path(args.skill))
    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"mode": "offline", "packages_checked": len(pkgs),
                     "drift": len(findings), "consistent": not findings, "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"DRIFT  {f['package']}: {f['issue']}")
    ok = not findings
    eprint(f"{t.mark(ok)} ts-facts/offline: {len(pkgs)} package(s) checked, "
           f"{len(findings)} inconsistency {t.c('dim', '(catalog vs skill prose)')}")
    return EX_DRIFT if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
