#!/usr/bin/env python3
"""Staleness verifier for sandbox-ops: the provider facts and CLI flags it states must stay true.

sandbox-ops quotes prices, lifetimes, plan limits, auth rules and CLI flags for several
hosted-sandbox providers. Their docs move often, so these drift silently
(SKILL-RESOURCE-PROTOCOL.md section 7). Two catalogues hold the facts:
  assets/facts-boat.json       boat.dev, the deep profile: facts on https://docs.boat.dev/
                               <page>.md plus the CLI flags the recipes rely on
  assets/facts-providers.json  one entry per other provider: its card, its own
                               `verified` date, its docs pages (url + title line), facts

  --offline (default, PR CI, no network):
    * each catalogue parses; every fact names a declared page, a pattern and skill_text
    * boat: the prose (SKILL.md + references/*.md) states every fact and names every flag,
      and SKILL.md's "Facts verified YYYY-MM-DD" equals the catalogue's `verified`
    * other providers: the card states every fact's skill_text, and the card's
      "Facts verified YYYY-MM-DD" equals that provider's `verified`
    (whitespace-insensitive throughout: prose wraps)
  --live (scheduled freshness.yml, never a PR gate):
    * each fact's pattern (a regex) is found on its docs page
    * boat's flags appear in the docs CLI reference and, when a boat CLI is installed
      (--boat, BOAT_BIN or `boat` on PATH), in `boat --no-update help <sub>`
    A page that cannot be fetched, or that lost its title line, is UNAVAILABLE (7),
    never drift: only a reachable, recognisable page that disagrees is drift (10).

Usage:   check-sandbox-facts.py [--offline | --live] [--provider NAME] [--skill DIR]
                                [--catalog FILE] [--providers-catalog FILE]
                                [--fixtures DIR] [--boat PATH] [--timeout S] [--json]
Input:   argv flags only (no stdin). --provider is boat, e2b, modal, vercel, daytona, fly
         or all (default). --fixtures DIR reads <provider>/<page>.md (and boat's
         cli-help-<sub>.txt, sub "top" = top-level help) from DIR instead of the network
         and the CLI, so the live logic is testable offline; an explicit --boat still
         reads the real CLI's help.
Output:  stdout = findings (plain rows "<STATUS>\t<provider>:<check>\t<detail>", or a
         --json envelope, schema claude-mods.sandbox-ops.sandbox-facts/v1). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalogue/skill/card missing, 4 catalogue malformed,
         7 a source unreachable or unrecognisable (live, advisory),
         10 drift (offline: prose/catalogue disagree; live: a provider's docs disagree)

Examples:
  check-sandbox-facts.py --offline                         # PR CI, every provider
  check-sandbox-facts.py --live --provider e2b             # one provider's docs
  check-sandbox-facts.py --live --fixtures tests/fixtures/live
  check-sandbox-facts.py --live --json | jq '.data[] | select(.status=="drift")'
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
DEFAULT_CATALOG = HERE.parent / "assets" / "facts-boat.json"
DEFAULT_PROVIDERS = HERE.parent / "assets" / "facts-providers.json"
DEFAULT_SKILL = HERE.parent
SCHEMA = "claude-mods.sandbox-ops.sandbox-facts/v1"
PROVIDERS = ("boat", "e2b", "modal", "vercel", "daytona", "fly")
# \s+ because prose wraps: "Facts\nverified" must still count.
VERIFIED_RE = re.compile(r"Facts\s+verified\s+(\d{4}-\d{2}-\d{2})")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ID_RE = re.compile(r"^[a-z0-9-]+$")
FLAG_RE = re.compile(r"^--[a-z][a-z0-9-]*$")
# Subcommands whose help the boat CLI half reads. "top" is `boat help` itself.
SUBS = {"top", "new", "exec", "delete", "list", "extend", "ssh", "scp", "run", "push", "info", "usage", "limits"}
UA = "claude-mods-sandbox-ops-check/1"


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
    print(f"check-sandbox-facts: {msg}", file=sys.stderr)
    raise SystemExit(code)


def squash(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def check_facts(facts, pages, where: str) -> None:
    """Shared fact-list validation; raises ValueError on a malformed entry."""
    if not isinstance(facts, list) or not facts:
        raise ValueError(f"{where}: 'facts' must be a non-empty array")
    seen = set()
    for f in facts:
        for key in ("id", "page", "pattern", "skill_text"):
            if not isinstance(f.get(key), str) or not f[key]:
                raise ValueError(f"{where}: fact missing {key}: {f!r}")
        if f["id"] in seen:
            raise ValueError(f"{where}: duplicate fact id {f['id']}")
        seen.add(f["id"])
        if f["page"] not in pages:
            raise ValueError(f"{where}: fact {f['id']} names undeclared page {f['page']!r}")
        re.compile(f["pattern"])


def load_json(path: Path) -> dict:
    if not path.is_file():
        fail(EX_NOTFOUND, f"catalogue not found: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(EX_MALFORMED, f"catalogue {path} is malformed: {exc}")
    return {}  # unreachable


def load_boat(path: Path) -> dict:
    cat = load_json(path)
    try:
        if not DATE_RE.match(str(cat.get("verified", ""))):
            raise ValueError("'verified' must be YYYY-MM-DD")
        pages = cat["pages"]
        if not isinstance(pages, dict) or not pages:
            raise ValueError("'pages' must be a non-empty object of page -> title line")
        for page, title in pages.items():
            if not ID_RE.match(page) or not str(title).startswith("# "):
                raise ValueError(f"bad page entry {page!r}: {title!r}")
        check_facts(cat["facts"], pages, "boat")
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
    except (KeyError, TypeError, ValueError, re.error) as exc:
        fail(EX_MALFORMED, f"catalogue {path} is malformed: {exc}")
    return {}  # unreachable


def load_providers(path: Path) -> dict:
    cat = load_json(path)
    try:
        provs = cat["providers"]
        if not isinstance(provs, dict) or not provs:
            raise ValueError("'providers' must be a non-empty object")
        for name, p in provs.items():
            if name not in PROVIDERS or name == "boat":
                raise ValueError(f"unknown provider {name!r}")
            if not DATE_RE.match(str(p.get("verified", ""))):
                raise ValueError(f"{name}: 'verified' must be YYYY-MM-DD")
            if not isinstance(p.get("card"), str) or "/" in p["card"]:
                raise ValueError(f"{name}: 'card' must be a file name under references/")
            pages = p["pages"]
            if not isinstance(pages, dict) or not pages:
                raise ValueError(f"{name}: 'pages' must be a non-empty object")
            for page, spec in pages.items():
                if (not ID_RE.match(page) or not isinstance(spec, dict)
                        or not str(spec.get("url", "")).startswith("https://")
                        or not str(spec.get("title", "")).strip()):
                    raise ValueError(f"{name}: bad page entry {page!r}: {spec!r}")
            check_facts(p["facts"], pages, name)
        return cat
    except (KeyError, TypeError, ValueError, re.error) as exc:
        fail(EX_MALFORMED, f"catalogue {path} is malformed: {exc}")
    return {}  # unreachable


def row(provider: str, check: str, status: str, detail: str) -> dict:
    return {"provider": provider, "check": check, "status": status, "detail": detail}


# === OFFLINE ===

def boat_offline(cat: dict, skill_dir: Path) -> list[dict]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        fail(EX_NOTFOUND, f"SKILL.md not found under {skill_dir}")
    skill_md = doc.read_text(encoding="utf-8")
    corpus = squash("\n".join([skill_md] + [p.read_text(encoding="utf-8")
                    for p in sorted((skill_dir / "references").glob("*.md"))]))
    rows = []
    for f in cat["facts"]:
        if squash(f["skill_text"]) not in corpus:
            rows.append(row("boat", f"fact:{f['id']}", "drift",
                            f"skill prose no longer states {f['skill_text']!r}"))
    for sub, names in cat["flags"].items():
        for n in names:
            # a flag counts as named only as a whole word: --all must not match --allow
            if not re.search(re.escape(n) + r"(?![a-z0-9-])", corpus):
                rows.append(row("boat", f"flag:{sub}:{n}", "drift",
                                "skill prose no longer names this flag"))
    m = VERIFIED_RE.search(skill_md)
    if not m or m.group(1) != cat["verified"]:
        rows.append(row("boat", "verified-date", "drift",
                        f"SKILL.md states {m.group(1) if m else 'no date'}, "
                        f"catalogue says {cat['verified']}"))
    return rows


def provider_offline(name: str, p: dict, skill_dir: Path) -> list[dict]:
    card = skill_dir / "references" / p["card"]
    if not card.is_file():
        fail(EX_NOTFOUND, f"{name}: card not found: {card}")
    text = card.read_text(encoding="utf-8")
    body = squash(text)
    rows = []
    for f in p["facts"]:
        if squash(f["skill_text"]) not in body:
            rows.append(row(name, f"fact:{f['id']}", "drift",
                            f"{p['card']} no longer states {f['skill_text']!r}"))
    m = VERIFIED_RE.search(text)
    if not m or m.group(1) != p["verified"]:
        rows.append(row(name, "verified-date", "drift",
                        f"{p['card']} states {m.group(1) if m else 'no date'}, "
                        f"catalogue says {p['verified']}"))
    return rows


# === LIVE ===

def fetch(url: str, fixture: Path | None, timeout: float) -> tuple[str | None, str]:
    if fixture is not None:
        return (fixture.read_text(encoding="utf-8"), str(fixture)) if fixture.is_file() \
            else (None, f"no fixture {fixture.name}")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", "replace"), url
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return None, f"{url}: {getattr(exc, 'reason', exc)}"


def live_pages(name: str, pages: dict, fixtures: Path | None, timeout: float) -> tuple[list[dict], dict]:
    """pages: page -> (url, title line). A page missing its title line is unavailable."""
    rows, texts = [], {}
    for page, (url, title) in pages.items():
        fx = fixtures / name / f"{page}.md" if fixtures is not None else None
        text, src = fetch(url, fx, timeout)
        if text is not None and not any(line.strip() == title for line in text.splitlines()):
            rows.append(row(name, f"page:{page}", "unavailable",
                            f"{src} has no {title!r} line: moved or reshaped, re-read it"))
            text = None
        elif text is None:
            rows.append(row(name, f"page:{page}", "unavailable", src))
        texts[page] = text
    return rows, texts


def live_facts(name: str, facts: list, texts: dict) -> list[dict]:
    return [row(name, f"fact:{f['id']}", "drift",
                f"docs page {f['page']} no longer matches /{f['pattern']}/")
            for f in facts
            if texts.get(f["page"]) is not None and not re.search(f["pattern"], texts[f["page"]])]


def find_boat(explicit: str | None) -> str | None:
    cand = explicit or os.environ.get("BOAT_BIN") or shutil.which("boat")
    return cand if cand and Path(cand).is_file() else None


def cli_help(sub: str, boat: str | None, fixtures: Path | None, timeout: float) -> tuple[str | None, str]:
    """Returns (text, source); text None = unavailable. Never runs anything but `help`."""
    if fixtures is not None:
        p = fixtures / "boat" / f"cli-help-{sub}.txt"
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


def boat_live(cat: dict, fixtures: Path | None, boat: str | None, timeout: float,
              cli_fixtures: Path | None) -> tuple[list[dict], str]:
    base = cat.get("docs_base", "https://docs.boat.dev/").rstrip("/")
    pages = {page: (f"{base}/{page}.md", title) for page, title in cat["pages"].items()}
    rows, texts = live_pages("boat", pages, fixtures, timeout)
    rows += live_facts("boat", cat["facts"], texts)
    ref = texts.get("cli-reference")
    cli_state = "skipped"
    for sub, names in cat["flags"].items():
        for n in names:
            if ref is not None and not re.search(re.escape(n) + r"(?![a-z0-9-])", ref):
                rows.append(row("boat", f"flag:{sub}:{n}", "drift",
                                "flag missing from the docs CLI reference"))
        text, src = cli_help(sub, boat, cli_fixtures, timeout)
        if text is None:
            if src != "skipped":
                rows.append(row("boat", f"cli:{sub}", "unavailable", src))
                cli_state = "unavailable"
            continue
        cli_state = "checked" if cli_state == "skipped" else cli_state
        for n in names:
            if not re.search(re.escape(n) + r"(?![a-z0-9-])", text):
                rows.append(row("boat", f"cli:{sub}:{n}", "drift", f"flag missing from `{src}`"))
    return rows, cli_state


def provider_live(name: str, p: dict, fixtures: Path | None, timeout: float) -> list[dict]:
    pages = {page: (spec["url"], spec["title"].strip()) for page, spec in p["pages"].items()}
    rows, texts = live_pages(name, pages, fixtures, timeout)
    return rows + live_facts(name, p["facts"], texts)


# === MAIN ===

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="check-sandbox-facts.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="catalogue vs prose, no network (default)")
    mode.add_argument("--live", action="store_true", help="catalogue vs the providers' docs (and boat's CLI help)")
    ap.add_argument("--provider", default="all", choices=PROVIDERS + ("all",), help="which provider (default all)")
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="boat facts catalogue JSON")
    ap.add_argument("--providers-catalog", default=str(DEFAULT_PROVIDERS), help="other providers' facts JSON")
    ap.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    ap.add_argument("--fixtures", help="live: read recorded pages from DIR/<provider>/ instead of the network")
    ap.add_argument("--boat", help="live: path to the boat CLI (default BOAT_BIN, then PATH)")
    ap.add_argument("--timeout", type=float, default=15.0, help="live: per-request timeout seconds")
    ap.add_argument("--json", action="store_true", help="emit a JSON envelope on stdout")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    wanted = PROVIDERS if args.provider == "all" else (args.provider,)
    boat_cat = load_boat(Path(args.catalog)) if "boat" in wanted else None
    others = [w for w in wanted if w != "boat"]
    prov_cat = load_providers(Path(args.providers_catalog))["providers"] if others else {}
    for w in others:
        if w not in prov_cat:
            fail(EX_NOTFOUND, f"{w}: no entry in {args.providers_catalog}")

    t = Term(sys.stderr)
    skill = Path(args.skill)
    rows: list[dict] = []
    cli_state = None
    if args.live:
        fixtures = Path(args.fixtures) if args.fixtures else None
        if fixtures is not None and not fixtures.is_dir():
            fail(EX_NOTFOUND, f"fixtures directory not found: {fixtures}")
        if boat_cat is not None:
            # An explicit --boat wins over recorded CLI help, so recorded pages can be
            # checked together with the real CLI.
            boat = find_boat(args.boat)
            if args.boat and boat is None:
                fail(EX_NOTFOUND, f"boat CLI not found: {args.boat}")
            r, cli_state = boat_live(boat_cat, fixtures, boat, args.timeout,
                                     None if args.boat else fixtures)
            rows += r
        for w in others:
            rows += provider_live(w, prov_cat[w], fixtures, args.timeout)
    else:
        if boat_cat is not None:
            rows += boat_offline(boat_cat, skill)
        for w in others:
            rows += provider_offline(w, prov_cat[w], skill)

    drift = [r for r in rows if r["status"] == "drift"]
    unavailable = [r for r in rows if r["status"] == "unavailable"]
    nfacts = (len(boat_cat["facts"]) if boat_cat else 0) + sum(len(prov_cat[w]["facts"]) for w in others)
    nflags = sum(len(v) for v in boat_cat["flags"].values()) if boat_cat else 0
    verified = {}
    if boat_cat:
        verified["boat"] = boat_cat["verified"]
    verified.update({w: prov_cat[w]["verified"] for w in others})

    if args.json:
        meta = {"mode": "live" if args.live else "offline", "providers": list(wanted),
                "verified": verified, "facts": nfacts, "flags": nflags,
                "drift": len(drift), "unavailable": len(unavailable),
                "consistent": not rows, "schema": SCHEMA}
        if args.live and cli_state is not None:
            meta["cli"] = cli_state
        print(json.dumps({"data": rows, "meta": meta}, indent=2))
    else:
        for r in rows:
            print(f"{r['status'].upper()}\t{r['provider']}:{r['check']}\t{r['detail']}")

    label = f"sandbox-facts/{'live' if args.live else 'offline'}"
    counted = f"{len(wanted)} provider(s), {nfacts} facts, {nflags} flags"
    if drift:
        print(f"{t.mark('drift')} {label}: {len(drift)} drift finding(s) in {counted}", file=sys.stderr)
        return EX_DRIFT
    if unavailable:
        print(f"{t.mark('warn')} {label}: {len(unavailable)} source(s) unavailable "
              f"{t.c('dim', '(advisory - retry next run)')}", file=sys.stderr)
        return EX_UNAVAILABLE
    extra = f" {t.c('dim', '(boat CLI: ' + cli_state + ')')}" if cli_state else ""
    print(f"{t.mark('ok')} {label}: {counted} current{extra}", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
