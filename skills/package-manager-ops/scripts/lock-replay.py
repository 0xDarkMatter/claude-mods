#!/usr/bin/env python3
"""Replay the other side of a composer.lock merge conflict as composer commands.

Usage:   lock-replay.py [--side theirs|ours] [--json] CONFLICTED_LOCK
         lock-replay.py [--side theirs|ours] [--json] --ours FILE --theirs FILE
Input:   a composer.lock holding git conflict markers (<<<<<<< ======= >>>>>>>, diff3
         `|||||||` base sections tolerated), or two lock files. Never modified.
Output:  stdout = one command per line, data only:
           composer require [--dev] vendor/pkg:<version>   (added or version-changed)
           composer remove  [--dev] vendor/pkg             (present only on the other side)
         --json: {"data": [{"action","package","version","dev","command"}...], "meta": {...}}
         with schema claude-mods.package-manager-ops.lock-replay/v1.
Stderr:  how many packages each side holds, the verdict line, errors.
Exit:    0 nothing to replay, 2 usage, 3 input file missing, 4 input unparseable,
         10 commands printed

The rule this makes scriptable: never hand-merge a lockfile. Resolve the conflict by taking
ONE side's composer.lock (git checkout --ours|--theirs composer.lock), then run the printed
commands to re-apply the other side's package changes - composer regenerates the lock, its
content-hash and transitive pins correctly. `--side` names the side being replayed:
`theirs` (default) prints what takes OURS to THEIRS, `ours` the reverse.

Only top-level lock entries are compared (transitive packages follow from the requires);
the printed list can therefore include transitive packages that were never in composer.json
- review it, and drop those, before running.

Examples:
  bash scripts/run-python.sh scripts/lock-replay.py composer.lock
  bash scripts/run-python.sh scripts/lock-replay.py --side ours composer.lock
  bash scripts/run-python.sh scripts/lock-replay.py --ours a/composer.lock --theirs b/composer.lock --json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EX_OK, EX_USAGE, EX_NOTFOUND, EX_UNPARSEABLE, EX_FINDINGS = 0, 2, 3, 4, 10
SCHEMA = "claude-mods.package-manager-ops.lock-replay/v1"
# Conflict markers are exactly seven characters at column 0 (git's own rule). Anything
# looser would eat a package description that happens to start with "=======".
MARK = re.compile(r"^(<{7}|\|{7}|={7}|>{7})(?: .*)?$")
# Fallback line scanner (used when a side is not valid JSON on its own). composer writes a
# package's `name` then `version` first, straight after the item's opening brace; the
# item brace's indent is learned per section, so a nested `{` (authors, support) never
# counts as a new package.
NAME = re.compile(r'^\s+"name":\s*"([^"]+)"')
VERSION = re.compile(r'^\s+"version":\s*"([^"]+)"')
SECTION = re.compile(r'^\s*"(packages|packages-dev)":')
OPEN = re.compile(r'^(\s*)\{\s*$')


def safe_streams():
    """WHY: stdout is data and must be UTF-8 even when piped on a cp1252 Windows console,
    and LF-only: text-mode CRLF would leave a stray CR on every printed command, which
    breaks `bash` and `$(...)` consumers on Windows."""
    for stream, kw in ((sys.stdout, {"encoding": "utf-8", "errors": "backslashreplace", "newline": "\n"}),
                       (sys.stderr, {"errors": "backslashreplace"})):
        reconfigure = getattr(stream, "reconfigure", None)
        try:
            if reconfigure:
                reconfigure(**kw)
        except ValueError:
            pass


def split_sides(text: str):
    """Return (ours_text, theirs_text); the diff3 base section is dropped. Raises
    ValueError on a marker sequence that does not close."""
    ours, theirs, state = [], [], "plain"
    # (current state, marker char) -> next state; any other marker is malformed.
    step = {("plain", "<"): "ours", ("ours", "|"): "base", ("ours", "="): "theirs",
            ("base", "="): "theirs", ("theirs", ">"): "plain"}
    for line in text.splitlines():
        m = MARK.match(line.rstrip(chr(13)))
        if m:
            nxt = step.get((state, m.group(1)[0]))
            if nxt is None:
                raise ValueError(f"unexpected conflict marker {line[:7]!r} inside a {state} section")
            state = nxt
        elif state in ("plain", "ours"):
            ours.append(line)
            if state == "plain":
                theirs.append(line)
        elif state == "theirs":
            theirs.append(line)
    if state != "plain":
        raise ValueError("conflict markers never close (truncated file?)")
    return "\n".join(ours) + "\n", "\n".join(theirs) + "\n"


def packages(text: str) -> dict:
    """{(name, dev): version}. JSON first; a side that is not valid JSON on its own (a
    conflict hunk can cut an object in half) falls back to the line scanner."""
    out = {}
    try:
        doc = json.loads(text)
        for key, dev in (("packages", False), ("packages-dev", True)):
            for pkg in doc.get(key, []) or []:
                out[(pkg["name"], dev)] = str(pkg.get("version", ""))
        return out
    except (ValueError, KeyError, TypeError, AttributeError):
        out = {}
    dev, name, item_indent = False, None, None
    for line in text.splitlines():
        sm = SECTION.match(line)
        if sm:
            dev, name, item_indent = sm.group(1) == "packages-dev", None, None
            continue
        om = OPEN.match(line)
        if om and item_indent is None:
            item_indent = om.group(1)
        if om and om.group(1) == item_indent:
            name = None
            continue
        nm = NAME.match(line)
        if nm and name is None:
            name = nm.group(1)
            continue
        vm = VERSION.match(line)
        if vm and name:
            out[(name, dev)] = vm.group(1)
            name = ""
    return out


def plan(base: dict, target: dict) -> list:
    """Commands that turn `base`'s package set into `target`'s."""
    rows = []
    for (name, dev), ver in sorted(target.items()):
        if base.get((name, dev)) != ver:
            flag = " --dev" if dev else ""
            rows.append({"action": "require", "package": name, "version": ver, "dev": dev,
                         "command": f"composer require{flag} {name}:{ver}"})
    for (name, dev) in sorted(base):
        if (name, dev) not in target and (name, not dev) not in target:
            flag = " --dev" if dev else ""
            rows.append({"action": "remove", "package": name, "version": base[(name, dev)], "dev": dev,
                         "command": f"composer remove{flag} {name}"})
    return rows


def main(argv: list) -> int:
    safe_streams()
    p = argparse.ArgumentParser(
        prog="lock-replay.py",
        description="Print the composer commands that replay the other side of a composer.lock conflict (read-only).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/lock-replay.py composer.lock\n"
               "  bash scripts/run-python.sh scripts/lock-replay.py --ours a.lock --theirs b.lock --json\n\n"
               "Exit: 0 nothing to replay, 2 usage, 3/4 input missing/unparseable, 10 commands printed",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("lock", nargs="?", help="composer.lock containing conflict markers")
    p.add_argument("--ours", metavar="FILE", help="our side's composer.lock (with --theirs)")
    p.add_argument("--theirs", metavar="FILE", help="their side's composer.lock (with --ours)")
    p.add_argument("--side", choices=("theirs", "ours"), default="theirs",
                   help="which side's package set to reproduce (default theirs)")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    pair = bool(args.ours) + bool(args.theirs)
    if pair == 1 or (pair == 2 and args.lock) or (pair == 0 and not args.lock):
        print("error: give a conflicted composer.lock, or both --ours and --theirs", file=sys.stderr)
        return EX_USAGE
    try:
        if args.lock:
            texts = split_sides(Path(args.lock).read_text(encoding="utf-8-sig"))
            if texts[0] == texts[1]:
                print(f"lock-replay: no conflict markers in {args.lock}", file=sys.stderr)
        else:
            texts = (Path(args.ours).read_text(encoding="utf-8-sig"),
                     Path(args.theirs).read_text(encoding="utf-8-sig"))
    except OSError as exc:
        print(f"error: cannot read input: {exc}", file=sys.stderr)
        return EX_NOTFOUND
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EX_UNPARSEABLE
    ours, theirs = packages(texts[0]), packages(texts[1])
    if not ours and not theirs:
        print("error: no packages found on either side - is this a composer.lock?", file=sys.stderr)
        return EX_UNPARSEABLE
    print(f"lock-replay: ours {len(ours)} package(s), theirs {len(theirs)} package(s)", file=sys.stderr)
    rows = plan(ours, theirs) if args.side == "theirs" else plan(theirs, ours)
    if args.json:
        print(json.dumps({"data": rows, "meta": {"schema": SCHEMA, "side": args.side, "count": len(rows)}}, indent=2))
    else:
        for r in rows:
            print(r["command"])
    if rows:
        print(f"lock-replay: {len(rows)} command(s) to replay side '{args.side}' on top of the other lock", file=sys.stderr)
        return EX_FINDINGS
    print("lock-replay: nothing to replay", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
