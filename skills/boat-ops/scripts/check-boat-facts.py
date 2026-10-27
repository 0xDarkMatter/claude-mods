#!/usr/bin/env python3
"""Staleness verifier for boat-ops: the boat.dev facts and CLI flags it states must stay true.

boat-ops quotes prices, plan limits, retention periods, security defaults and the CLI
flags its recipes depend on (assets/boat-facts.json). boat ships CLI releases often and
its docs move with them, so these drift silently (SKILL-RESOURCE-PROTOCOL.md section 7).

  --offline (default, PR CI, no network):
    * the catalog parses; every fact names a declared page, a pattern and skill_text
    * the skill prose (SKILL.md + references/*.md) still states every fact's skill_text
      and names every catalogued flag (whitespace-insensitive: prose wraps)
    * SKILL.md's "Facts verified YYYY-MM-DD" equals the catalog's `verified`
  --live (scheduled freshness.yml, never a PR gate):
    * each fact's pattern (a regex) is found on https://docs.boat.dev/<page>.md
    * each flag appears in the docs CLI reference, and, when a boat CLI is installed
      (--boat, BOAT_BIN or `boat` on PATH), in `boat --no-update help <sub>`
    A page that cannot be fetched, or that lost its title line, is UNAVAILABLE (7),
    never drift: only a reachable, recognisable page that disagrees is drift (10).
    With no CLI installed the CLI half is skipped and the docs decide.

Usage:   check-boat-facts.py [--offline | --live] [--catalog FILE] [--skill DIR]
                             [--fixtures DIR] [--boat PATH] [--timeout S] [--json]
Input:   argv flags only (no stdin). --fixtures DIR reads <page>.md and
         cli-help-<sub>.txt (sub "top" = top-level help) from DIR instead of the
         network and the CLI, so the live logic is testable offline; an
         explicit --boat still reads the real CLI's help.
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog malformed,
         7 a source unreachable or unrecognisable (live, advisory),
         10 drift (offline: prose/catalog disagree; live: boat disagrees)

Examples:
  check-boat-facts.py --offline                        # PR CI
  check-boat-facts.py --live                           # weekly drift check
  check-boat-facts.py --live --fixtures tests/fixtures/live
  check-boat-facts.py --live --json | jq '.data[] | select(.status=="drift")'
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_MALFORMED = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "boat-facts.json"
DEFAULT_SKILL = HERE.parent
SCHEMA = "claude-mods.boat-ops.boat-facts/v1"
VERIFIED_RE = re.compile(r"Facts verified (\d{4}-\d{2}-\d{2})")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ID_RE = re.compile(r"^[a-z0-9-]+$")
FLAG_RE = re.compile(r"^--[a-z][a-z0-9-]*$")
# Subcommands whose help the CLI half reads. "top" is `boat help` itself.
SUBS = {"top", "new", "exec", "delete", "list", "extend", "ssh", "scp", "run", "push", "info", "usage", "limits"}


class Term:
    """Minimal ANSI helper (term.sh is bash-only; per TERMINAL-DESIGN.md section 9 the
    Python port is inline). Honours FORCE_COLOR / NO_COLOR / TERM_ASCII and the bound
    stream's TTY and encoding, so piped output stays plain ASCII."""

    _C = {"green": "\033[32m", "red": "\033[31m", "yellow": "\033[33m",
          "dim": "\033[2m", "off": "\033[0m"}

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

    def mark(self, state):
        glyph = {"ok": ("+", "✓"), "drift": ("x", "✗"), "warn": ("!", "!")}[state]
        colour = {"ok": "green", "drift": "red", "warn": "yellow"}[state]
        return self.c(colour, glyph[0] if self.ascii else glyph[1])


def fail(code: int, msg: str) -> None:
    print(f"check-boat-facts: {msg}", file=sys.stderr)
    raise SystemExit(code)


def squash(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def load_catalog(path: Path) -> dict:
    if not path.is_file():
        fail(EX_NOTFOUND, f"catalog not found: {path}")
    try:
        cat = json.loads(path.read_text(encoding="utf-8"))
        if not DATE_RE.match(str(cat.get("verified", ""))):
            raise ValueError("'verified' must be YYYY-MM-DD")
        pages = cat["pages"]
        if not isinstance(pages, dict) or not pages:
            raise ValueError("'pages' must be a non-empty object of page -> title line")
        for page, title in pages.items():
            if not ID_RE.match(page) or not str(title).startswith("# "):
                raise ValueError(f"bad page entry {page!r}: {title!r}")
        facts = cat["facts"]
        if not isinstance(facts, list) or not facts:
            raise ValueError("'facts' must be a non-empty array")
        seen = set()
        for f in facts:
            for key in ("id", "page", "pattern", "skill_text"):
                if not isinstance(f.get(key), str) or not f[key]:
                    raise ValueError(f"fact missing {key}: {f!r}")
            if f["id"] in seen:
                raise ValueError(f"duplicate fact id {f['id']}")
            seen.add(f["id"])
            if f["page"] not in pages:
                raise ValueError(f"fact {f['id']} names undeclared page {f['page']!r}")
            re.compile(f["pattern"])
        flags = cat["flags"]
        if not isinstance(flags, dict):
            raise ValueError("'flags' must be an object of subcommand -> [flags]")
        for sub, names in flags.items():
            if sub not in SUBS or not isinstance(names, list):
                raise ValueError(f"bad flags entry {sub!r}")
            for n in names:
                if not isinstance(n, str) or not FLAG_RE.match(n):
                    raise ValueError(f"bad flag {n!r} under {sub}")
        return cat
    except (json.JSONDecodeError, KeyError, TypeError, ValueError, re.error) as exc:
        fail(EX_MALFORMED, f"catalog {path} is malformed: {exc}")
    return {}  # unreachable


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        fail(EX_NOTFOUND, f"SKILL.md not found under {skill_dir}")
    skill_md = doc.read_text(encoding="utf-8")
    parts = [skill_md] + [p.read_text(encoding="utf-8")
                          for p in sorted((skill_dir / "references").glob("*.md"))]
    return skill_md, squash("\n".join(parts))


def check_offline(cat: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    rows = []
    for f in cat["facts"]:
        if squash(f["skill_text"]) not in corpus:
            rows.append({"check": f"fact:{f['id']}", "status": "drift",
                         "detail": f"skill prose no longer states {f['skill_text']!r}"})
    for sub, names in cat["flags"].items():
        for n in names:
            # a flag counts as named only as a whole word: --all must not match --allow
            if not re.search(re.escape(n) + r"(?![a-z0-9-])", corpus):
                rows.append({"check": f"flag:{sub}:{n}", "status": "drift",
                             "detail": "skill prose no longer names this flag"})
    m = VERIFIED_RE.search(skill_md)
    if not m or m.group(1) != cat["verified"]:
        rows.append({"check": "verified-date", "status": "drift",
                     "detail": f"SKILL.md states {m.group(1) if m else 'no date'}, "
                               f"catalog says {cat['verified']}"})
    return rows


def fetch_page(cat: dict, page: str, fixtures: Path | None, timeout: float) -> tuple[str | None, str]:
    if fixtures is not None:
        p = fixtures / f"{page}.md"
        return (p.read_text(encoding="utf-8"), str(p)) if p.is_file() else (None, f"no fixture {p.name}")
    url = cat.get("docs_base", "https://docs.boat.dev/").rstrip("/") + f"/{page}.md"
    req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-boat-ops-check/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", "replace"), url
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return None, f"{url}: {getattr(exc, 'reason', exc)}"


def find_boat(explicit: str | None) -> str | None:
    cand = explicit or os.environ.get("BOAT_BIN") or shutil.which("boat")
    return cand if cand and Path(cand).is_file() else None


def cli_help(sub: str, boat: str | None, fixtures: Path | None, timeout: float) -> tuple[str | None, str]:
    """Returns (text, source); text None = unavailable. Never runs anything but `help`."""
    if fixtures is not None:
        p = fixtures / f"cli-help-{sub}.txt"
        return (p.read_text(encoding="utf-8"), str(p)) if p.is_file() else (None, "skipped")
    if boat is None:
        return None, "skipped"
    argv = [boat, "--no-update", "help"] + ([] if sub == "top" else [sub])
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                             env={**os.environ, "BOAT_NO_UPDATE": "1"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"{' '.join(argv)}: {exc}"
    if res.returncode != 0 or "Usage:" not in res.stdout:
        return None, f"{' '.join(argv)}: rc {res.returncode}"
    return res.stdout, " ".join(argv)


def check_live(cat: dict, fixtures: Path | None, boat: str | None, timeout: float,
               cli_fixtures: Path | None) -> tuple[list[dict], str]:
    rows = []
    texts: dict[str, str | None] = {}
    for page, title in cat["pages"].items():
        text, src = fetch_page(cat, page, fixtures, timeout)
        if text is not None and not any(line.strip() == title for line in text.splitlines()):
            rows.append({"check": f"page:{page}", "status": "unavailable",
                         "detail": f"{src} has no {title!r} line: moved or reshaped, re-read it"})
            text = None
        elif text is None:
            rows.append({"check": f"page:{page}", "status": "unavailable", "detail": src})
        texts[page] = text
    for f in cat["facts"]:
        text = texts.get(f["page"])
        if text is not None and not re.search(f["pattern"], text):
            rows.append({"check": f"fact:{f['id']}", "status": "drift",
                         "detail": f"docs page {f['page']} no longer matches /{f['pattern']}/"})
    ref = texts.get("cli-reference")
    cli_state = "skipped"
    for sub, names in cat["flags"].items():
        for n in names:
            if ref is not None and not re.search(re.escape(n) + r"(?![a-z0-9-])", ref):
                rows.append({"check": f"flag:{sub}:{n}", "status": "drift",
                             "detail": "flag missing from the docs CLI reference"})
        text, src = cli_help(sub, boat, cli_fixtures, timeout)
        if text is None:
            if src != "skipped":
                rows.append({"check": f"cli:{sub}", "status": "unavailable", "detail": src})
                cli_state = "unavailable"
            continue
        cli_state = "checked" if cli_state == "skipped" else cli_state
        for n in names:
            if not re.search(re.escape(n) + r"(?![a-z0-9-])", text):
                rows.append({"check": f"cli:{sub}:{n}", "status": "drift",
                             "detail": f"flag missing from `{src}`"})
    return rows, cli_state


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-boat-facts.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="catalog vs prose, no network (default)")
    mode.add_argument("--live", action="store_true", help="catalog vs boat's docs and CLI help")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--fixtures", help="live: read recorded pages and CLI help from this directory")
    p.add_argument("--boat", help="live: path to the boat CLI (default BOAT_BIN, then PATH)")
    p.add_argument("--timeout", type=float, default=15.0, help="live: per-request timeout seconds")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope on stdout")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    cat = load_catalog(Path(args.catalog))
    t = Term(sys.stderr)
    live = args.live
    if live:
        fixtures = Path(args.fixtures) if args.fixtures else None
        if fixtures is not None and not fixtures.is_dir():
            fail(EX_NOTFOUND, f"fixtures directory not found: {fixtures}")
        # An explicit --boat wins over recorded CLI help, so recorded pages can be checked
        # together with the real CLI.
        boat = find_boat(args.boat)
        if args.boat and boat is None:
            fail(EX_NOTFOUND, f"boat CLI not found: {args.boat}")
        rows, cli_state = check_live(cat, fixtures, boat, args.timeout,
                                     None if args.boat else fixtures)
    else:
        rows, cli_state = check_offline(cat, Path(args.skill)), None
    drift = [r for r in rows if r["status"] == "drift"]
    unavailable = [r for r in rows if r["status"] == "unavailable"]

    if args.json:
        meta = {"mode": "live" if live else "offline", "verified": cat["verified"],
                "facts": len(cat["facts"]), "flags": sum(len(v) for v in cat["flags"].values()),
                "drift": len(drift), "unavailable": len(unavailable),
                "consistent": not rows, "schema": SCHEMA}
        if live:
            meta["cli"] = cli_state
        print(json.dumps({"data": rows, "meta": meta}, indent=2))
    else:
        for r in rows:
            print(f"{r['status'].upper()}\t{r['check']}\t{r['detail']}")

    label = "boat-facts/live" if live else "boat-facts/offline"
    counted = f"{len(cat['facts'])} facts, {sum(len(v) for v in cat['flags'].values())} flags"
    if drift:
        print(f"{t.mark('drift')} {label}: {len(drift)} drift finding(s) in {counted}", file=sys.stderr)
        return EX_DRIFT
    if unavailable:
        print(f"{t.mark('warn')} {label}: {len(unavailable)} source(s) unavailable "
              f"{t.c('dim', '(advisory - retry next run)')}", file=sys.stderr)
        return EX_UNAVAILABLE
    extra = f" {t.c('dim', '(boat CLI: ' + cli_state + ')')}" if live else ""
    print(f"{t.mark('ok')} {label}: {counted} current{extra}", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
