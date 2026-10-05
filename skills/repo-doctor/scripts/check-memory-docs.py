#!/usr/bin/env python3
"""check-memory-docs - staleness tripwire for the Claude Code facts the AGENTS.md protocol encodes.

Usage:   check-memory-docs.py [--offline | --live] [--json]
Input:   --offline (default): references/agents-md-protocol.md and the two scripts that
         share the size ceiling, beside this file. --live: the official memory docs page
         (https://code.claude.com/docs/en/memory) over HTTPS.
Output:  plain "ok"/"drift" lines per fact on stdout, or --json:
         {"data": [{"id", "claim", "ok"}], "meta": {"mode", "drift", "schema":
         "claude-mods.repo-doctor.check-memory-docs/v1"}}
Stderr:  fetch progress and errors
Exit:    0 every fact holds, 2 usage, 7 docs page unreachable (live only: advisory,
         never a failure), 10 drift (the protocol lost a fact, the scripts disagree on the
         ceiling, or the live page no longer states a fact)

Offline runs in PR CI (tests/check-resources.sh); live runs on a schedule
(.github/workflows/freshness.yml), never as a PR gate (SKILL-RESOURCE-PROTOCOL.md 7).
When live reports drift: re-read the page, fix agents-md-protocol.md section 4, then
update the matching FACTS row here.

Examples:
  check-memory-docs.py --offline
  check-memory-docs.py --live --json | jq '.data[] | select(.ok | not)'
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTOCOL = HERE.parent / "references" / "agents-md-protocol.md"
URLS = ("https://code.claude.com/docs/en/memory.md", "https://code.claude.com/docs/en/memory")
SCHEMA = "claude-mods.repo-doctor.check-memory-docs/v1"

# (id, claim, phrase the live page must contain, phrase the protocol must contain).
# Phrases are compared after removing backticks and collapsing whitespace, both sides.
FACTS = (
    ("version-floor", "AGENTS.md is read directly from v2.1.277",
     "Reading AGENTS.md directly requires Claude Code v2.1.277", "v2.1.277"),
    ("effective-floor", "before v2.1.281 some sessions read CLAUDE.md only",
     "Before v2.1.281, some sessions", "v2.1.281 is the effective floor"),
    ("shadow-trio", "CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md shadow AGENTS.md",
     "a CLAUDE.md, .claude/CLAUDE.md, or CLAUDE.local.md in your working directory or any directory above it",
     "AGENTS.md plus any of those three"),
    ("both-mode", "claude-md-and-agents-md loads both",
     "claude-md-and-agents-md", "claude-md-and-agents-md"),
    ("setting-scope", "the setting is ignored in project and local settings",
     "ignores it in project and local settings files", "ignores it in project and local settings"),
    ("setting-key", "the setting lives under the agents-md@builtin plugin",
     "agents-md@builtin", 'pluginConfigs["agents-md@builtin"].options.instructionFiles'),
    ("size-target", "target under 200 lines per instruction file",
     "target under 200 lines per CLAUDE.md file", "Target 150 lines; 200 is the ceiling"),
    ("imports-cost", "imports load at launch, so they don't reduce context",
     "imported files also load at launch", "@path imports do not shrink anything"),
    ("local-shadow", "a CLAUDE.local.md stops AGENTS.md loading",
     "stops Claude from reading AGENTS.md", "A personal CLAUDE.local.md silently stops AGENTS.md loading"),
    ("hooks", "InstructionsLoaded hooks don't fire for AGENTS.md read via the setting",
     "InstructionsLoaded", "InstructionsLoaded hooks don't fire"),
    ("prompt-audit", "/doctor prompt-audit covers AGENTS.md",
     "audit covers your CLAUDE.md, CLAUDE.local.md, and AGENTS.md files", "/doctor prompt-audit (v2.1.283+; covers AGENTS.md"),
    ("not-read", "AGENTS.override.md is never read", "AGENTS.override.md", "AGENTS.override.md"),
    ("windows-symlink", "on Windows use the @AGENTS.md import, not a symlink",
     "use the @AGENTS.md import instead", "use the @AGENTS.md import if anyone clones on Windows"),
)
# Constants that must equal the documented 200-line ceiling (scripts beside this file).
CEILINGS = (("agents-md.py", r"^CEILING_LINES = (\d+)"), ("repo-doctor.py", r"^ENTRY_LEAN_LINES = (\d+)"))


def norm(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text).replace("`", "").replace("&quot;", '"').replace("&#x27;", "'")
    return re.sub(r"\s+", " ", text)


def offline() -> list[dict]:
    proto = norm(PROTOCOL.read_text(encoding="utf-8"))
    rows = [{"id": fid, "claim": claim, "ok": norm(phrase) in proto}
            for fid, claim, _, phrase in FACTS]
    for name, pat in CEILINGS:
        m = re.search(pat, (HERE / name).read_text(encoding="utf-8"), re.M)
        rows.append({"id": f"ceiling-{name}", "claim": f"{name} uses the 200-line ceiling",
                     "ok": bool(m) and m.group(1) == "200"})
    return rows


def live() -> list[dict] | None:
    for url in URLS:
        print(f"check-memory-docs: fetching {url}", file=sys.stderr)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-freshness"})
            with urllib.request.urlopen(req, timeout=20) as r:
                page = norm(r.read().decode("utf-8", errors="replace"))
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            print(f"check-memory-docs: {url}: {exc}", file=sys.stderr)
            continue
        if "AGENTS.md" in page:
            return [{"id": fid, "claim": claim, "ok": norm(phrase).lower() in page.lower()}
                    for fid, claim, phrase, _ in FACTS]
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Check the Claude Code memory facts encoded in agents-md-protocol.md.",
        epilog="EXAMPLES:\n  check-memory-docs.py --offline\n  check-memory-docs.py --live --json\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="protocol + script constants (default)")
    mode.add_argument("--live", action="store_true", help="the official docs page (network)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    rows = live() if args.live else offline()
    if rows is None:
        print("check-memory-docs: docs page unreachable; skipped (advisory)", file=sys.stderr)
        return 7
    drift = [r for r in rows if not r["ok"]]
    if args.json:
        print(json.dumps({"data": rows, "meta": {"mode": "live" if args.live else "offline",
                                                 "drift": len(drift), "schema": SCHEMA}}, indent=2))
    else:
        for r in rows:
            print(f"{'ok   ' if r['ok'] else 'DRIFT'}  {r['id']}: {r['claim']}")
    return 10 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
