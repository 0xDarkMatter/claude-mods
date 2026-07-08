#!/usr/bin/env python3
"""Find which ADRs govern a given path, glob, or config key via `touches:`.

The third leg of the toolkit: adr-lint checks integrity, adr-index gives an
overview, and adr-touching answers the pre-edit question — "is there a decision
record governing the thing I'm about to change?". It reads every ADR's `touches:`
list and reports the records whose discovery surface matches the query.

A query matches a `touches:` entry by any of: exact string equality; fnmatch glob
in EITHER direction (touches `src/**` matches query `src/auth.py`; query `src/*`
matches touches `src/auth.py`); or path-prefix containment (touches `src/auth.py`
is governed by query `src/`; touches `src/` governs query `src/auth.py`).
Config-key entries (`file.yaml:db.host`) match by exact-or-prefix on the whole
string. Pragmatic, not exhaustive.

Usage:   adr-touching.py [--dir DIR] [--json] <path-or-glob-or-key>
Input:   one positional query + argv flags (no stdin).
Output:  stdout = matching ADRs, "number | status | title | matched-entry" rows.
         Data only. --json: {"data":[...],"meta":{...,"schema":
         "claude-mods.adr-ops.touching/v1"}}.
Stderr:  headers, the PyYAML fallback notice, errors.
Exit:    0 NO governing ADR found, 2 usage, 3 dir not found,
         10 at least one governing ADR found (domain signal — a pre-edit hook or
         CI can branch on it: "heads up, ADR-NNN governs this path").

Prefers PyYAML for frontmatter; falls back to a minimal parser when absent
(announced on stderr).

Examples:
  adr-touching.py src/auth.py
  adr-touching.py 'src/**'
  adr-touching.py --dir docs/decisions config.yaml:db.host
  adr-touching.py --json src/ | jq '.data[].number'
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from pathlib import Path


class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (term.sh is bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline with matching keys/glyphs).

    Honors FORCE_COLOR / NO_COLOR / TERM_ASCII (+ legacy FLEET_ASCII). Color tracks
    the bound stream's TTY so piped data stays plain; ASCII mode swaps every glyph
    for its registered proxy (✓✗▲—? -> +x!-?)."""

    _C = {
        "green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
        "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m",
    }
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stdout):
        # ASCII fallback: explicit env, OR the bound stream can't encode UTF (e.g. a
        # Windows cp1252 pipe) — mirrors term.sh's non-UTF-locale rule and prevents a
        # UnicodeEncodeError when a glyph hits a legacy codec.
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (
            os.environ.get("TERM_ASCII") == "1"
            or os.environ.get("FLEET_ASCII") == "1"
            or "utf" not in enc
        )
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None
              or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        if not self.color:
            return text
        return f"{self._C.get(name, '')}{text}{self._C['off']}"

    def mark(self, state):
        glyph = (self._ASCII if self.ascii else self._GLYPH).get(state, ".")
        return self.c(self._MARK_COLOR.get(state, ""), glyph)


EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_FOUND = 10

FILENAME_RE = re.compile(r"^ADR-(\d+)-.+\.md$")
TITLE_RE = re.compile(r"^# ADR-(\d+):\s+(\S.*)$")
GLOB_CHARS_RE = re.compile(r"[*?\[]")

try:
    import yaml  # type: ignore

    _HAVE_YAML = True
except Exception:  # pragma: no cover - environment dependent
    yaml = None  # type: ignore
    _HAVE_YAML = False


class FrontmatterError(Exception):
    """Frontmatter block is absent or structurally unparseable."""


def split_frontmatter(text: str) -> tuple[str, str]:
    """Return (frontmatter_text, body_text). Raises FrontmatterError if absent."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise FrontmatterError("no opening '---' frontmatter fence")
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1 :])
    raise FrontmatterError("no closing '---' frontmatter fence")


def parse_frontmatter(fm_text: str) -> dict:
    """Parse the frontmatter block to a dict. PyYAML if present, else minimal."""
    _yaml = yaml  # local alias narrows cleanly (module global won't)
    if _yaml is not None:
        try:
            data = _yaml.safe_load(fm_text)
        except Exception as exc:  # malformed YAML
            raise FrontmatterError(f"YAML parse error: {exc}") from exc
        if data is None:
            return {}
        if not isinstance(data, dict):
            raise FrontmatterError("frontmatter is not a mapping")
        return data
    return _minimal_parse(fm_text)


def _minimal_parse(fm_text: str) -> dict:
    """Tiny frontmatter parser for `key: scalar` and `key: [a, b]` / block lists."""
    out: dict = {}
    lines = fm_text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        m = re.match(r"^(\S[^:]*):\s*(.*)$", raw)
        if not m:
            i += 1
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        if val == "":
            items = []
            j = i + 1
            while j < len(lines) and re.match(r"^\s*-\s+", lines[j]):
                item = re.sub(r"^\s*-\s+", "", lines[j]).strip()
                item = item.strip("\"'")
                items.append(item)
                j += 1
            if items:
                out[key] = items
                i = j
                continue
            out[key] = ""
            i += 1
            continue
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            out[key] = (
                [x.strip().strip("\"'") for x in inner.split(",") if x.strip()]
                if inner
                else []
            )
        else:
            out[key] = val.strip("\"'")
        i += 1
    return out


def as_list(value) -> list:
    """Return value coerced to a list of strings (best-effort)."""
    if isinstance(value, list):
        return [str(x) for x in value]
    if value is None or value == "":
        return []
    return [str(value)]


def _norm(p: str) -> str:
    """Normalise a path-ish string for comparison: backslashes -> /, no trailing /."""
    s = p.strip().replace("\\", "/")
    while len(s) > 1 and s.endswith("/"):
        s = s[:-1]
    return s


def _is_glob(s: str) -> bool:
    return bool(GLOB_CHARS_RE.search(s))


def _is_config_key(s: str) -> bool:
    """A `file.ext:dotted.key` entry — a colon segment that isn't a drive letter."""
    # Treat any ':' not at position 1 (Windows drive like C:) as a config-key marker.
    idx = s.find(":")
    return idx > 1


def _prefix_governs(prefix: str, child: str) -> bool:
    """True if `prefix` is a directory-prefix of `child` (or equal)."""
    prefix = _norm(prefix)
    child = _norm(child)
    if prefix == child:
        return True
    return child.startswith(prefix + "/")


def matches(query: str, entry: str) -> bool:
    """Does `query` select the ADR carrying `touches:` entry `entry`?"""
    q = _norm(query)
    e = _norm(entry)

    if q == e:
        return True

    # Config-key entries: match by exact-or-prefix on the whole string only.
    if _is_config_key(entry) or _is_config_key(query):
        # exact handled above; allow prefix containment either direction
        if e.startswith(q) or q.startswith(e):
            return True
        return False

    # Glob in either direction.
    if _is_glob(entry) and fnmatch.fnmatch(q, e):
        return True
    if _is_glob(query) and fnmatch.fnmatch(e, q):
        return True
    # Recursive-glob convenience: fnmatch treats ** like * (no path awareness),
    # which already lets `src/**` match `src/auth.py`. Nothing more needed.

    # Path-prefix containment in either direction.
    if not _is_glob(entry) and not _is_glob(query):
        if _prefix_governs(query, entry) or _prefix_governs(entry, query):
            return True

    return False


def find_title(body: str) -> str:
    for line in body.splitlines():
        m = TITLE_RE.match(line.strip())
        if m:
            return m.group(2).strip()
    return ""


def scan(adr_dir: Path, query: str) -> list[dict]:
    """Return the list of matching ADR records (sorted by number)."""
    results: list[dict] = []
    files = sorted(p for p in adr_dir.glob("ADR-*.md") if FILENAME_RE.match(p.name))
    for path in files:
        fn = FILENAME_RE.match(path.name)
        if fn is None:
            continue
        number = f"ADR-{fn.group(1)}"
        try:
            text = path.read_text(encoding="utf-8")
            fm_text, body = split_frontmatter(text)
            fm = parse_frontmatter(fm_text)
        except (OSError, FrontmatterError) as exc:
            print(f"warning: skipping {path.name}: {exc}", file=sys.stderr)
            continue
        touches = as_list(fm.get("touches"))
        matched = next((t for t in touches if matches(query, t)), None)
        if matched is not None:
            results.append(
                {
                    "number": number,
                    "status": str(fm.get("status", "")),
                    "title": find_title(body),
                    "matched": matched,
                    "file": path.name,
                }
            )
    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="adr-touching.py",
        description="Find which ADRs govern a path/glob/config-key via touches:.",
        add_help=True,
    )
    parser.add_argument("--dir", default="docs/adr", help="ADR directory (default: docs/adr)")
    parser.add_argument("--json", action="store_true", help="emit a JSON envelope")
    parser.add_argument("query", nargs="?", help="path, glob, or config key to look up")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    if args.query is None or args.query.strip() == "":
        print("error: a path/glob/config-key query is required", file=sys.stderr)
        return EX_USAGE

    if not _HAVE_YAML:
        print("note: PyYAML not found — using built-in minimal frontmatter parser.", file=sys.stderr)

    adr_dir = Path(args.dir)
    if not adr_dir.is_dir():
        print(f"error: ADR directory not found: {adr_dir}", file=sys.stderr)
        return EX_NOTFOUND

    results = scan(adr_dir, args.query)

    if args.json:
        envelope = {
            "data": results,
            "meta": {
                "count": len(results),
                "query": args.query,
                "dir": str(adr_dir),
                "schema": "claude-mods.adr-ops.touching/v1",
            },
        }
        print(json.dumps(envelope, indent=2))
    else:
        tout = Term(sys.stdout)
        terr = Term(sys.stderr)
        status_color = {"accepted": "green", "proposed": "yellow"}
        for r in results:
            if tout.color:
                num = tout.c("cyan", r["number"])
                st = tout.c(status_color.get(r["status"], "dim"), r["status"])
                print(f"{tout.mark('warn')} {num} | {st} | {r['title']} | {r['matched']}")
            else:
                # Plain stream stays byte-identical to the legacy data format.
                print(f"{r['number']} | {r['status']} | {r['title']} | {r['matched']}")
        if results:
            print(
                f"--- {terr.c('orange', str(len(results)))} ADR(s) govern '{args.query}'",
                file=sys.stderr,
            )
        else:
            print(f"--- no ADR governs '{args.query}'", file=sys.stderr)

    return EX_FOUND if results else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
