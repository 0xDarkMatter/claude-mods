#!/usr/bin/env python3
"""Staleness verifier for isometric-ops's canonical constants and citation graph.

Guards the fast-moving/easy-to-typo facts this skill depends on:
  - the canonical projection-math constants (26.565, 35.264, 81.65, 86.602,
    57.735/57.74, 1.22474, 54.736) actually appear in references/projection-math.md
  - every references/*.md file is cited (linked or path-mentioned) from SKILL.md
  - the third-party packages named in prose (@elchininet/isometric, isometric-css,
    svgo) still exist on the npm registry

Two modes (protocol SKILL-RESOURCE-PROTOCOL.md Section 7):
  --offline (default): parse the shipped markdown, assert the constants are present
                       and every reference is cited. No network. May block CI.
  --live:              query the npm registry for the named packages. Advisory
                       only — exits 7 on any network/registry unavailability,
                       never blocks a PR.

SKILL.md special-case: while the skill is mid-build its body is a short
"BUILD IN PROGRESS" placeholder with no reference citations yet. --offline
detects this placeholder (via the literal marker text) and SKIPS the citation
check gracefully (noted on stderr, not a failure) rather than failing on an
incomplete router. The constants check still runs regardless, since the
reference files it inspects are independent of SKILL.md's state.

Usage:   check-iso-facts.py [--offline | --live] [--json] [--skill-dir DIR] [-q]
Input:   reads SKILL.md and every references/*.md (resolved relative to this
         script's parent directory, or --skill-dir)
Output:  stdout = data only (JSON envelope under --json, else a plain summary)
Stderr:  headers, progress, notes, errors
Exit:    0 ok/consistent, 2 usage, 3 not-found, 4 validation (missing constant /
         uncited reference / unquotable package), 5 missing-dep (curl, --live
         only), 7 unavailable (registry unreachable, --live only),
         10 drift (a named package is gone/renamed on the live registry)

Examples:
  check-iso-facts.py --offline
  check-iso-facts.py --offline --json | python -m json.tool
  check-iso-facts.py --live
  check-iso-facts.py --live -q   # exits 7 (advisory) when npm is unreachable
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

# Windows consoles default to cp1252; force UTF-8 so em-dashes/degree signs in
# notes don't raise UnicodeEncodeError or print mojibake (repo-standard fix).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass


class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (bash-only per
    TERMINAL-DESIGN.md Section 9; this is the matching Python inline port).
    Honors FORCE_COLOR / NO_COLOR / TERM_ASCII; glyphs fall back to ASCII on
    TERM_ASCII or a non-UTF stream encoding."""

    _C = {"green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
          "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—",
              "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (os.environ.get("TERM_ASCII") == "1"
                      or os.environ.get("FLEET_ASCII") == "1" or "utf" not in enc)
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, state):
        return self.c(self._MARK_COLOR.get(state, ""),
                      (self._ASCII if self.ascii else self._GLYPH).get(state, "."))

    def hdr(self, text):
        return self.c("cyan", f"=== {text} ===")


TERM = Term(sys.stderr)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_MISSING_DEP = 5
EXIT_UNAVAILABLE = 7
EXIT_DRIFT = 10

SCHEMA = "claude-mods.isometric-ops.iso-facts/v1"

# The literal placeholder marker check-iso-facts.py uses to detect that
# SKILL.md's body has not been synthesized yet (see build brief: SKILL.md
# body is [SYNTHESIS — after everything]).
BUILD_PLACEHOLDER_MARKER = "BUILD IN PROGRESS"

# Canonical constants (brief's "CANONICAL CONSTANTS" table) that MUST appear,
# verbatim as substrings, somewhere in references/projection-math.md. Each
# entry is (label, substring). Substring matching (not full-precision floats)
# because the source docs cite these to varying decimal places (e.g. "26.565"
# and "26.5651" both legitimately appear) — the invariant we guard is that the
# canonical short-form figure is present at least once, not a specific
# formatting.
CANONICAL_CONSTANTS = [
    ("2:1 dimetric ground-axis angle (arctan(1/2))", "26.565"),
    ("cube tilt / magic angle (arctan(1/sqrt2))", "35.264"),
    ("axonometric foreshortening (cos(35.264deg))", "81.65"),
    ("SSR vertical scale (cos(30deg))", "86.602"),
    ("Figma-hack height scale (tan(30deg))", "57.735"),
    ("CSS scale3d un-foreshorten (sqrt(3/2))", "1.22474"),
    ("CSS rotateX back-tip (90 - 35.264deg)", "54.736"),
]
# 86.062 is a documented typo (SRC-B misprint) for 86.602 — it must NOT be
# asserted as canonical anywhere without the correction being present nearby.
KNOWN_TYPO = "86.062"

# Packages named in prose across references/*.md that this skill treats as
# facts subject to drift (existence / rename on the npm registry).
NPM_PACKAGES = ["@elchininet/isometric", "isometric-css", "svgo"]

CONSTANTS_FILE = "projection-math.md"


def note(msg: str, quiet: bool) -> None:
    if not quiet:
        print(msg, file=sys.stderr)


def fail_validation(message: str, details: dict, json_mode: bool) -> NoReturn:
    if json_mode:
        print(json.dumps({"error": {"code": "VALIDATION", "message": message,
                                    "details": details}}))
    print(f"{TERM.mark('bad')} ERROR: {message}", file=sys.stderr)
    for k, v in details.items():
        print(f"  {k}: {v}", file=sys.stderr)
    sys.exit(EXIT_VALIDATION)


def _have(tool: str) -> bool:
    from shutil import which
    return which(tool) is not None


# ---------------------------------------------------------------------------
# Offline checks
# ---------------------------------------------------------------------------

def check_constants(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    """Assert every canonical constant appears in references/projection-math.md."""
    const_path = skill_dir / "references" / CONSTANTS_FILE
    if not const_path.is_file():
        if json_mode:
            print(json.dumps({"error": {"code": "NOT_FOUND",
                                        "message": f"missing file: {const_path}",
                                        "details": {}}}))
        print(f"ERROR: required file not found: {const_path}", file=sys.stderr)
        sys.exit(EXIT_NOT_FOUND)

    text = const_path.read_text(encoding="utf-8")

    missing = [{"label": label, "expected": needle}
               for label, needle in CANONICAL_CONSTANTS if needle not in text]
    if missing:
        fail_validation(
            f"{const_path.name} is missing canonical constant(s)",
            {"missing": ", ".join(m["expected"] for m in missing),
             "hint": "see the CANONICAL CONSTANTS table in the build brief"},
            json_mode)

    # The typo is allowed to appear ONLY as an explicitly-flagged correction
    # (i.e. the canonical 86.602 figure must also be present — already
    # asserted above — so a bare typo-only file would already have failed).
    typo_hits = text.count(KNOWN_TYPO)

    found = [{"label": label, "value": needle} for label, needle in CANONICAL_CONSTANTS]
    note(f"  {len(found)}/{len(CANONICAL_CONSTANTS)} canonical constants present in "
         f"{const_path.name}", quiet)
    if typo_hits:
        note(f"  note: {KNOWN_TYPO!r} (documented SRC-B typo) appears {typo_hits}x "
             f"alongside the corrected 86.602 figure", quiet)
    return {"file": str(const_path), "constants": found, "typo_mentions": typo_hits}


REF_LINK_RE = re.compile(
    r"\[(?:[^\]]*)\]\(\s*(?:references/)?([a-z0-9-]+\.md)\s*\)"  # [text](references/x.md) or [text](x.md)
)
REF_PATH_RE = re.compile(r"references/([a-z0-9-]+\.md)")
REF_BACKTICK_RE = re.compile(r"`([a-z0-9-]+\.md)`")


def _cited_basenames(text: str) -> set[str]:
    """Collect every reference basename cited in a markdown text, across the
    three citation styles seen in this repo's SKILL.md files: markdown links
    (relative or references/-prefixed), bare `references/x.md` paths, and
    backtick-quoted bare filenames (`x.md`)."""
    names: set[str] = set()
    for m in REF_LINK_RE.finditer(text):
        names.add(m.group(1))
    for m in REF_PATH_RE.finditer(text):
        names.add(m.group(1))
    for m in REF_BACKTICK_RE.finditer(text):
        names.add(m.group(1))
    return names


def check_citations(skill_dir: Path, json_mode: bool, quiet: bool) -> dict | None:
    """Assert every references/*.md is cited from SKILL.md.

    Returns None (and notes a graceful skip) while SKILL.md's body is still
    the BUILD IN PROGRESS placeholder — per the brief, the router is
    synthesized last, after every reference lands, so there is nothing
    meaningful to check yet.
    """
    skill_md = skill_dir / "SKILL.md"
    refs_dir = skill_dir / "references"
    if not skill_md.is_file():
        if json_mode:
            print(json.dumps({"error": {"code": "NOT_FOUND",
                                        "message": f"missing file: {skill_md}",
                                        "details": {}}}))
        print(f"ERROR: required file not found: {skill_md}", file=sys.stderr)
        sys.exit(EXIT_NOT_FOUND)

    skill_text = skill_md.read_text(encoding="utf-8")
    if BUILD_PLACEHOLDER_MARKER in skill_text:
        note(f"  SKILL.md body is still the {BUILD_PLACEHOLDER_MARKER!r} placeholder "
             "- skipping citation check (graceful, not a failure)", quiet)
        return None

    ref_files = sorted(p.name for p in refs_dir.glob("*.md")) if refs_dir.is_dir() else []
    if not ref_files:
        note("  no references/*.md files to check", quiet)
        return {"references": [], "uncited": []}

    cited = _cited_basenames(skill_text)
    uncited = [name for name in ref_files if name not in cited]
    if uncited:
        fail_validation(
            "reference file(s) not cited from SKILL.md",
            {"uncited": ", ".join(uncited),
             "hint": "every references/*.md must be linked or path-mentioned in SKILL.md"},
            json_mode)

    note(f"  {len(ref_files)}/{len(ref_files)} references/*.md cited from SKILL.md", quiet)
    return {"references": ref_files, "uncited": []}


def check_packages_named(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    """Assert the packages this skill discusses are actually named somewhere
    under references/ — i.e. the prose hasn't drifted to omit/rename them
    without the docs being updated to match."""
    refs_dir = skill_dir / "references"
    if not refs_dir.is_dir():
        if json_mode:
            print(json.dumps({"error": {"code": "NOT_FOUND",
                                        "message": f"missing dir: {refs_dir}",
                                        "details": {}}}))
        print(f"ERROR: required directory not found: {refs_dir}", file=sys.stderr)
        sys.exit(EXIT_NOT_FOUND)

    blob = ""
    for p in sorted(refs_dir.glob("*.md")):
        blob += p.read_text(encoding="utf-8") + "\n"

    missing = [pkg for pkg in NPM_PACKAGES if pkg not in blob]
    if missing:
        fail_validation(
            "package(s) expected in prose are absent from references/*.md",
            {"missing": ", ".join(missing),
             "hint": "see the brief's contested-fact list (svg-vector-generation.md)"},
            json_mode)

    note(f"  {len(NPM_PACKAGES)}/{len(NPM_PACKAGES)} named packages found in prose",
         quiet)
    return {"packages": list(NPM_PACKAGES)}


def validate_offline(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    note(TERM.hdr("offline iso-facts consistency check"), quiet)

    constants_result = check_constants(skill_dir, json_mode, quiet)
    citations_result = check_citations(skill_dir, json_mode, quiet)
    packages_result = check_packages_named(skill_dir, json_mode, quiet)

    note(f"{TERM.mark('ok')} OK: facts internally consistent.", quiet)

    return {
        "mode": "offline",
        "constants": constants_result,
        "citations": citations_result,
        "citations_skipped": citations_result is None,
        "packages": packages_result,
        "consistent": True,
    }


# ---------------------------------------------------------------------------
# Live checks
# ---------------------------------------------------------------------------

def fetch_npm_package(pkg: str, quiet: bool) -> dict | None:
    """Return the npm registry metadata dict for pkg, or None if unavailable
    (advisory — a network blip must never look like a real drift)."""
    url = f"https://registry.npmjs.org/{pkg.replace('/', '%2f')}"
    cmd = ["curl", "-fsS", "--max-time", "20", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as exc:
        note(f"NOTE: registry lookup for {pkg} failed ({exc}) - advisory, not a failure.",
             quiet)
        return None
    if proc.returncode != 0:
        note(f"NOTE: registry unreachable for {pkg} (curl exit {proc.returncode}) "
             "- advisory.", quiet)
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        note(f"NOTE: registry returned non-JSON for {pkg} - advisory.", quiet)
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def validate_live(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    if not _have("curl"):
        if json_mode:
            print(json.dumps({"error": {"code": "PRECONDITION",
                                         "message": "curl required for --live",
                                         "details": {}}}))
        print("ERROR: curl is required for --live", file=sys.stderr)
        sys.exit(EXIT_MISSING_DEP)

    note(TERM.hdr("live npm package-existence check"), quiet)

    results: dict[str, dict] = {}
    any_reachable = False
    drifted: list[str] = []

    for pkg in NPM_PACKAGES:
        payload = fetch_npm_package(pkg, quiet)
        if payload is None:
            results[pkg] = {"status": "unavailable"}
            continue
        any_reachable = True
        if payload.get("error") == "Not found" or "name" not in payload:
            results[pkg] = {"status": "drift", "reason": "not found on registry"}
            drifted.append(pkg)
            note(f"{TERM.mark('bad')} {TERM.c('red', 'DRIFT:')} {pkg} not found on npm",
                 quiet)
            continue
        latest = (payload.get("dist-tags") or {}).get("latest")
        results[pkg] = {"status": "ok", "latest": latest}
        note(f"  {pkg}: latest={latest}", quiet)

    if not any_reachable:
        # Every lookup failed to reach the network at all — advisory, exit 7.
        result = {"mode": "live", "status": "unavailable", "packages": results}
        if json_mode:
            print(json.dumps({"data": result,
                              "meta": {"schema": SCHEMA, "status": "unavailable"}}))
        sys.exit(EXIT_UNAVAILABLE)

    result = {
        "mode": "live",
        "status": "drift" if drifted else "ok",
        "packages": results,
        "drifted": drifted,
    }

    if drifted:
        if json_mode:
            print(json.dumps({"data": result, "meta": {"schema": SCHEMA,
                                                        "status": "drift"}}))
        else:
            print(f"DRIFT: package(s) gone/renamed on npm: {', '.join(drifted)}")
        sys.exit(EXIT_DRIFT)

    note(f"{TERM.mark('ok')} OK: all named packages resolve on the npm registry.", quiet)
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-iso-facts.py", add_help=True,
        description="Staleness verifier for isometric-ops canonical constants + citations.",
        epilog=(
            "EXAMPLES:\n"
            "  check-iso-facts.py --offline\n"
            "  check-iso-facts.py --offline --json | python -m json.tool\n"
            "  check-iso-facts.py --live\n"
            "  check-iso-facts.py --live -q   # exits 7 (advisory) when npm unreachable\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true",
                      help="parse + assert internal consistency, no network (default)")
    mode.add_argument("--live", action="store_true",
                      help="check named packages against the live npm registry (advisory)")
    parser.add_argument("--json", action="store_true",
                        help="emit the JSON envelope on stdout")
    parser.add_argument("--skill-dir", default=None,
                        help="skill root (default: parent of this script's dir)")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="suppress stderr progress/notes")
    args = parser.parse_args(argv)

    if args.skill_dir:
        skill_dir = Path(args.skill_dir).resolve()
    else:
        skill_dir = Path(__file__).resolve().parent.parent
    if not skill_dir.is_dir():
        print(f"ERROR: skill dir not found: {skill_dir}", file=sys.stderr)
        return EXIT_NOT_FOUND

    if args.live:
        result = validate_live(skill_dir, args.json, args.quiet)
    else:
        result = validate_offline(skill_dir, args.json, args.quiet)

    if args.json:
        print(json.dumps({"data": result,
                          "meta": {"schema": SCHEMA, "status": "ok"}}))
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(EXIT_USAGE)
