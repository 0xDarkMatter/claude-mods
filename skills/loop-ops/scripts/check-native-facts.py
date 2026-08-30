#!/usr/bin/env python3
"""Staleness verifier for loop-ops' native-scheduling facts.

references/native-scheduling.md encodes a fast-moving external surface: the native
scheduling primitives (CronCreate / the scheduled-tasks MCP / cloud routines) and
their hard limits. Those limits are load-bearing - loop-doctor refuses a config on
them - and they are exactly the kind of fact that rots invisibly
(SKILL-RESOURCE-PROTOCOL.md §7). Two modes guard it:

  --offline (default, safe for PR CI): internal consistency, no network.
    * the host vocabulary is ONE set across all four places it appears:
      assets/loop.config.template.yaml, scripts/loop-scaffold.sh (--host),
      scripts/loop-doctor.sh (its case arms), references/native-scheduling.md
    * native-scheduling.md carries its "Verified <date>" stamp
    * every load-bearing limit loop-doctor enforces is still stated in the prose
      (the 1-hour cloud floor, the 7-day session-cron expiry)
  --live (scheduled freshness.yml, never a PR gate): fetch the three upstream doc
    pages and check the numbers we encode still appear in them. A changed number
    upstream is real drift; an unreachable docs host is advisory, not a failure.

Usage:   check-native-facts.py [--offline | --live] [--skill DIR] [--json] [--timeout S]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 in sync, 2 usage, 3 a required file is missing, 4 unparseable,
         7 docs unreachable (live, advisory - never a real failure),
         10 drift found

Examples:
  check-native-facts.py --offline              # PR CI: host vocabulary + limits are one set
  check-native-facts.py --live                 # weekly: our numbers vs the published docs
  check-native-facts.py --offline --json | jq '.data[]'
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNREACHABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.loop-ops.native-facts/v1"

# The canonical host vocabulary. Every file below must agree with exactly this set -
# a host added in one place and forgotten in another is the drift this catches.
HOSTS = {"local", "session-cron", "desktop-task", "cloud-routine", "external"}

# Limits loop-doctor actually enforces, so the prose that justifies them must state
# them. (needle, where it must appear, why it matters)
LIMITS = [
    ("1 hour", "cloud-routine minimum interval"),
    ("7 days", "session-cron recurring-task expiry"),
]

# Live checks: (url, [(needle, label)]). Needles are the published numbers we encode.
LIVE_PAGES = [
    ("https://code.claude.com/docs/en/routines", [
        ("minimum interval is one hour", "cloud routine >=1h floor"),
    ]),
    ("https://code.claude.com/docs/en/scheduled-tasks", [
        ("expire 7 days", "session-cron 7-day expiry"),
        ("50 scheduled tasks", "50-task-per-session cap"),
    ]),
    ("https://code.claude.com/docs/en/desktop-scheduled-tasks", [
        ("scheduled-tasks", "desktop task on-disk location"),
    ]),
]


class Term:
    """Minimal stderr styling; honours TERM_ASCII=1 and a non-tty stderr."""

    def __init__(self) -> None:
        import os

        self.plain = os.environ.get("TERM_ASCII") == "1" or not sys.stderr.isatty()

    def say(self, msg: str) -> None:
        print(msg, file=sys.stderr)


class Finding:
    def __init__(self, state: str, check: str, detail: str) -> None:
        self.state, self.check, self.detail = state, check, detail

    def as_dict(self) -> dict:
        return {"state": self.state, "check": self.check, "detail": self.detail}


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise FileNotFoundError(str(exc)) from exc


def hosts_in_template(text: str) -> set:
    """Hosts named in the `host:` block's inline comments."""
    block = re.search(r"^host:.*?(?=\n[a-z_]+:)", text, re.M | re.S)
    if not block:
        return set()
    return {h for h in HOSTS if re.search(r"\b" + re.escape(h) + r"\b", block.group(0))}


def hosts_in_scaffold(text: str) -> set:
    """Hosts accepted by loop-scaffold's --host validation case arm."""
    arm = re.search(r"case \"\$HOST\" in\n\s*([a-z|\-]+)\)", text)
    if not arm:
        return set()
    return set(arm.group(1).split("|"))


def hosts_in_doctor(text: str) -> set:
    """Hosts loop-doctor recognises in its host-coherence case arm."""
    arm = re.search(r"case \"\$HOST\" in\n\s*([a-z|\-]+)\) row ok \"host\"", text)
    if not arm:
        return set()
    return set(arm.group(1).split("|"))


def hosts_in_reference(text: str) -> set:
    return {h for h in HOSTS if "`" + h + "`" in text}


def check_offline(skill: Path) -> list:
    findings = []
    tpl = skill / "assets" / "loop.config.template.yaml"
    scaffold = skill / "scripts" / "loop-scaffold.sh"
    doctor = skill / "scripts" / "loop-doctor.sh"
    ref = skill / "references" / "native-scheduling.md"
    for p in (tpl, scaffold, doctor, ref):
        if not p.is_file():
            raise FileNotFoundError(str(p))

    sources = {
        "loop.config.template.yaml": hosts_in_template(read(tpl)),
        "loop-scaffold.sh --host": hosts_in_scaffold(read(scaffold)),
        "loop-doctor.sh host arm": hosts_in_doctor(read(doctor)),
        "native-scheduling.md": hosts_in_reference(read(ref)),
    }
    for where, found in sources.items():
        if not found:
            findings.append(Finding("bad", "hosts", f"{where}: no host vocabulary found (parser or format changed)"))
        elif found != HOSTS:
            missing = sorted(HOSTS - found)
            extra = sorted(found - HOSTS)
            detail = f"{where}: " + ", ".join(
                filter(None, [f"missing {missing}" if missing else "", f"unknown {extra}" if extra else ""])
            )
            findings.append(Finding("bad", "hosts", detail))
        else:
            findings.append(Finding("ok", "hosts", f"{where}: all {len(HOSTS)} hosts"))

    ref_text = read(ref)
    stamp = re.search(r"\*\*Verified (\d{4}-\d{2}-\d{2})\*\*", ref_text)
    if stamp:
        findings.append(Finding("ok", "date-stamp", f"native-scheduling.md verified {stamp.group(1)}"))
    else:
        findings.append(Finding("bad", "date-stamp", "native-scheduling.md has no '**Verified YYYY-MM-DD**' stamp"))

    for needle, why in LIMITS:
        if needle in ref_text:
            findings.append(Finding("ok", "limit", f"{why}: '{needle}' documented"))
        else:
            findings.append(Finding("bad", "limit", f"{why}: '{needle}' not stated - loop-doctor enforces it unexplained"))
    return findings


def check_live(timeout: float) -> list:
    findings = []
    unreachable = 0
    for url, needles in LIVE_PAGES:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-loop-ops-verifier"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            unreachable += 1
            findings.append(Finding("skip", "fetch", f"{url}: unreachable ({exc.__class__.__name__})"))
            continue
        for needle, label in needles:
            if needle.lower() in body.lower():
                findings.append(Finding("ok", "live", f"{label}: still published"))
            else:
                findings.append(Finding("bad", "live", f"{label}: '{needle}' no longer in {url} - re-verify native-scheduling.md"))
    if unreachable == len(LIVE_PAGES):
        findings.append(Finding("skip", "live", "all docs pages unreachable - live check advisory only"))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--skill", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("-h", "--help", action="store_true")
    try:
        args = ap.parse_args()
    except SystemExit:
        return EX_USAGE
    if args.help:
        print(__doc__)
        return EX_OK
    if args.offline and args.live:
        print("error: --offline and --live are mutually exclusive", file=sys.stderr)
        return EX_USAGE

    term = Term()
    skill = Path(args.skill)
    mode = "live" if args.live else "offline"

    try:
        findings = check_offline(skill)
    except FileNotFoundError as exc:
        print(f"error: required file missing: {exc}", file=sys.stderr)
        return EX_NOTFOUND
    except re.error as exc:
        print(f"error: could not parse a source file: {exc}", file=sys.stderr)
        return EX_UNPARSEABLE

    if args.live:
        findings += check_live(args.timeout)

    bad = [f for f in findings if f.state == "bad"]
    skipped = [f for f in findings if f.state == "skip"]

    if args.json:
        print(json.dumps({
            "schema": SCHEMA,
            "mode": mode,
            "in_sync": not bad,
            "data": [f.as_dict() for f in findings],
        }, indent=2))
    else:
        for f in findings:
            print(f"{f.state:<5} {f.check:<12} {f.detail}")

    if bad:
        term.say(f"native-facts: {len(bad)} drift finding(s) - re-verify references/native-scheduling.md")
        return EX_DRIFT
    if args.live and len(skipped) >= len(LIVE_PAGES):
        term.say("native-facts: docs unreachable - live check skipped (advisory)")
        return EX_UNREACHABLE
    term.say(f"native-facts: in sync ({mode})")
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
