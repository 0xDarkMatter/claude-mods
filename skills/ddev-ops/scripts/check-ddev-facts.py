#!/usr/bin/env python3
"""Staleness verifier for ddev-ops: the DDEV facts the skill states must stay stated
(offline) and true upstream (live).

ddev-ops pins advice to facts that move: the current release line, DDEV's default PHP,
database and Node.js versions, the PHP range it ships, which commands are built in (a
project command with the same name shadows one), and the PHP and Node.js end-of-life
floors. They live once in assets/ddev-facts.json, which audit-ddev-config.py reads, and
they rot silently (SKILL-RESOURCE-PROTOCOL.md section 7) - DDEV v1.25.0 moved the PHP
default from 8.3 to 8.4 without touching any project. Two modes:

  --offline (default, safe for PR CI): no network.
    * the catalog parses and is internally consistent (release.minor matches the tag;
      every prose token contains the catalog value it states)
    * every prose token is still stated in SKILL.md or references/*.md
    * SKILL.md carries a "Versions verified YYYY-MM-DD" note equal to as_of
  --live (scheduled freshness job, never a PR gate):
    * newest stable DDEV release vs release.minor (a new minor or major is drift)
    * docs config page at that release: default php_version / database / nodejs_version
      and the php_version range
    * built-in command names at that release (global_dotddev_assets/commands/<service>)
    * endoflife.date: oldest PHP and Node.js lines still supported today

Sources: https://api.github.com/repos/ddev/ddev/releases,
https://raw.githubusercontent.com/ddev/ddev/<tag>/docs/content/users/configuration/config.md,
https://api.github.com/repos/ddev/ddev/contents/pkg/ddevapp/global_dotddev_assets/commands/<service>,
https://endoflife.date/api/php.json and nodejs.json. GITHUB_TOKEN, when set, is sent to
api.github.com only (never printed) to lift the anonymous rate limit.

Usage:   check-ddev-facts.py [--offline | --live] [--catalog FILE] [--skill DIR]
                             [--fixtures DIR] [--today YYYY-MM-DD] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin). --fixtures (live only) reads releases.json,
         config.md, commands-{web,host,db}.json, eol-php.json and eol-nodejs.json from
         DIR instead of the network - how tests exercise the live comparisons offline.
Output:  stdout = findings (check<TAB>status<TAB>detail rows, or the --json envelope,
         schema claude-mods.ddev-ops.facts/v1). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 a source was unreachable (live, advisory - never a real failure),
         10 drift (offline: catalog/prose disagree; live: upstream moved)

Examples:
  check-ddev-facts.py --offline                      # PR CI: catalog <-> prose consistency
  check-ddev-facts.py --live                         # weekly: did DDEV or an EOL floor move?
  check-ddev-facts.py --offline --json | jq '.data[] | select(.status != "ok")'
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_DRIFT = 10

SCHEMA = "claude-mods.ddev-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "ddev-facts.json"
DEFAULT_SKILL = HERE.parent

RELEASES_URL = "https://api.github.com/repos/ddev/ddev/releases?per_page=30"
CONFIG_DOC_URL = "https://raw.githubusercontent.com/ddev/ddev/{tag}/docs/content/users/configuration/config.md"
COMMANDS_URL = ("https://api.github.com/repos/ddev/ddev/contents/pkg/ddevapp/"
                "global_dotddev_assets/commands/{svc}?ref={tag}")
EOL_URL = "https://endoflife.date/api/{product}.json"
SERVICES = ("web", "host", "db")

AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOTE_RE = re.compile(r"Versions verified (\d{4}-\d{2}-\d{2})")
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


class Unavailable(Exception):
    pass


# === Catalog ===

def lookup(cat: dict, dotted: str):
    node = cat
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(dotted)
        node = node[part]
    return node


def load_catalog(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalog not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        cat = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(cat, dict) or cat.get("schema") != SCHEMA:
            raise ValueError(f"schema must be {SCHEMA!r}")
        if not AS_OF_RE.match(str(cat.get("as_of", ""))):
            raise ValueError(f"as_of must be YYYY-MM-DD, got {cat.get('as_of')!r}")
        if not TAG_RE.match(str(lookup(cat, "release.tag"))):
            raise ValueError("release.tag must look like v1.2.3")
        for dotted in ("release.minor", "defaults.php_version", "defaults.database", "defaults.nodejs_version",
                       "php_range.min", "php_range.max", "eol_floor.php", "eol_floor.nodejs"):
            if not isinstance(lookup(cat, dotted), str) or not lookup(cat, dotted):
                raise ValueError(f"{dotted} must be a non-empty string")
        for name, major in cat["node_codenames"].items():
            if not str(major).isdigit():
                raise ValueError(f"node_codenames.{name} must be a major number")
        for svc in SERVICES:
            names = lookup(cat, f"builtin_commands.{svc}")
            if not isinstance(names, list) or not names or not all(isinstance(n, str) and n for n in names):
                raise ValueError(f"builtin_commands.{svc} must be a non-empty list of names")
        tokens = cat.get("prose_tokens")
        if not isinstance(tokens, list) or not tokens:
            raise ValueError("prose_tokens must be a non-empty list")
        for t in tokens:
            for k in ("key", "token", "value_of"):
                if not isinstance(t, dict) or not t.get(k):
                    raise ValueError(f"prose token {t!r} missing {k!r}")
            lookup(cat, t["value_of"])
        return cat
    except KeyError as exc:
        print(f"error: could not parse catalog {path}: missing {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)
    except (json.JSONDecodeError, TypeError, ValueError, AttributeError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    parts = [skill_md]
    for ref in sorted((skill_dir / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8", errors="replace"))
    return skill_md, "\n".join(parts)


def row(check: str, status: str, detail: str) -> dict:
    return {"check": check, "status": status, "detail": detail}


def check_offline(cat: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    out: list[dict] = []
    m = NOTE_RE.search(skill_md)
    if not m:
        out.append(row("currency-note", "drift", "SKILL.md has no 'Versions verified YYYY-MM-DD' note"))
    elif m.group(1) != cat["as_of"]:
        out.append(row("currency-note", "drift", f"SKILL.md says verified {m.group(1)}, catalog as_of is {cat['as_of']}"))
    else:
        out.append(row("currency-note", "ok", f"verified {m.group(1)}"))

    tm = TAG_RE.match(cat["release"]["tag"])
    want_minor = f"{tm.group(1)}.{tm.group(2)}" if tm else ""  # load_catalog already rejected a bad tag
    out.append(row("release-minor", "ok" if cat["release"]["minor"] == want_minor else "drift",
                   f"release.minor {cat['release']['minor']!r} vs tag {cat['release']['tag']}"))

    for t in cat["prose_tokens"]:
        value = str(lookup(cat, t["value_of"]))
        if value not in t["token"]:
            out.append(row(f"token:{t['key']}", "drift",
                           f"token {t['token']!r} no longer contains {t['value_of']} = {value!r}"))
        elif t["token"] not in corpus:
            out.append(row(f"token:{t['key']}", "drift", f"{t['token']!r} no longer stated in the skill prose"))
        else:
            out.append(row(f"token:{t['key']}", "ok", f"{t['token']!r} stated"))
    return out


# === Live sources ===

class Sources:
    """Network or fixture-directory reads. Raises Unavailable on any failure."""

    def __init__(self, fixtures: Path | None, timeout: float):
        self.fixtures = fixtures
        self.timeout = timeout

    def _get(self, url: str) -> str:
        headers = {"User-Agent": "claude-mods-ddev-ops-check/1"}
        token = os.environ.get("GITHUB_TOKEN", "")
        if token and url.startswith("https://api.github.com/"):
            headers["Authorization"] = f"Bearer {token}"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=self.timeout) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise Unavailable(f"{url}: {getattr(exc, 'code', '') or exc}")

    def _fixture(self, name: str) -> str:
        if self.fixtures is None:
            raise Unavailable("no fixtures directory")
        path = self.fixtures / name
        if not path.is_file():
            raise Unavailable(f"fixture {name} missing")
        return path.read_text(encoding="utf-8")

    def text(self, fixture: str, url: str) -> str:
        return self._fixture(fixture) if self.fixtures else self._get(url)

    def json(self, fixture: str, url: str):
        raw = self.text(fixture, url)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise Unavailable(f"{fixture}: not JSON")


def vt(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", str(v)))


def latest_stable(releases) -> str:
    tags = [r.get("tag_name", "") for r in releases if isinstance(r, dict)
            and not r.get("prerelease") and not r.get("draft") and TAG_RE.match(str(r.get("tag_name", "")))]
    if not tags:
        raise Unavailable("no stable releases listed")
    return max(tags, key=vt)


def section(doc: str, key: str) -> str:
    m = re.search(rf"^## `{re.escape(key)}`\s*$(.*?)(?=^## |\Z)", doc, re.M | re.S)
    return m.group(1) if m else ""


def doc_facts(doc: str) -> dict:
    facts: dict = {}
    m = re.search(r"\|\s*`([\d.]+)`\s*\|\s*Can be `([\d.]+)` through `([\d.]+)`", section(doc, "php_version"))
    if m:
        facts["php_default"], facts["php_min"], facts["php_max"] = m.groups()
    m = re.search(r"\|\s*`([a-z]+:[\d.]+)`\s*\|", section(doc, "database"))
    if m:
        facts["db_default"] = m.group(1)
    m = re.search(r"\|\s*`(\d+)`\s*\|\s*Default version", section(doc, "nodejs_version"))
    if m:
        facts["node_default"] = m.group(1)
    return facts


def eol_floor(cycles, today: dt.date) -> str:
    live = []
    for c in cycles if isinstance(cycles, list) else []:
        eol = c.get("eol") if isinstance(c, dict) else None
        if eol is False:
            live.append(str(c.get("cycle")))
        elif isinstance(eol, str) and AS_OF_RE.match(eol) and dt.date.fromisoformat(eol) > today:
            live.append(str(c.get("cycle")))
    if not live:
        raise Unavailable("no supported cycles listed")
    return min(live, key=vt)


def check_live(cat: dict, src: Sources, today: dt.date) -> list[dict]:
    out: list[dict] = []
    tag = cat["release"]["tag"]
    try:
        latest = latest_stable(src.json("releases.json", RELEASES_URL))
        cur, new = vt(cat["release"]["tag"]), vt(latest)
        if new[:2] > cur[:2]:
            out.append(row("release", "drift", f"DDEV {latest} shipped; the skill documents {cat['release']['minor']}.x. "
                                               "Re-read its release notes, then update facts and prose"))
        elif new[:2] < cur[:2]:
            out.append(row("release", "drift", f"catalog lists {tag} but the newest stable release is {latest}"))
        else:
            out.append(row("release", "ok", f"newest stable {latest}" + (f" (catalog {tag})" if latest != tag else "")))
        tag = latest
    except Unavailable as exc:
        out.append(row("release", "unavailable", str(exc)))

    try:
        facts = doc_facts(src.text("config.md", CONFIG_DOC_URL.format(tag=tag)))
        pairs = [("php_default", "defaults.php_version"), ("php_min", "php_range.min"), ("php_max", "php_range.max"),
                 ("db_default", "defaults.database"), ("node_default", "defaults.nodejs_version")]
        for fkey, dotted in pairs:
            want = str(lookup(cat, dotted))
            if fkey not in facts:
                out.append(row(f"doc:{fkey}", "drift", f"config docs at {tag} no longer state {fkey} in the expected "
                                                       "table form; re-verify by hand"))
            elif facts[fkey] != want:
                out.append(row(f"doc:{fkey}", "drift", f"docs at {tag} say {facts[fkey]}, catalog {dotted} = {want}"))
            else:
                out.append(row(f"doc:{fkey}", "ok", f"{facts[fkey]}"))
    except Unavailable as exc:
        out.append(row("doc", "unavailable", str(exc)))

    for svc in SERVICES:
        try:
            listing = src.json(f"commands-{svc}.json", COMMANDS_URL.format(svc=svc, tag=tag))
            names = {e["name"] for e in listing if isinstance(e, dict) and e.get("type") == "file"
                     and not str(e.get("name", "")).startswith("README") and not str(e.get("name", "")).endswith(".example")}
            want = set(cat["builtin_commands"][svc])
            if names != want:
                added, gone = sorted(names - want), sorted(want - names)
                out.append(row(f"commands:{svc}", "drift", f"built-in {svc} commands changed at {tag}: "
                                                          f"added {added or '-'}, removed {gone or '-'}"))
            else:
                out.append(row(f"commands:{svc}", "ok", f"{len(names)} built-ins"))
        except Unavailable as exc:
            out.append(row(f"commands:{svc}", "unavailable", str(exc)))

    for product, key in (("php", "php"), ("nodejs", "nodejs")):
        try:
            floor = eol_floor(src.json(f"eol-{product}.json", EOL_URL.format(product=product)), today)
            want = cat["eol_floor"][key]
            out.append(row(f"eol:{product}", "ok" if floor == want else "drift",
                           f"oldest supported {product} line on {today}: {floor}" +
                           ("" if floor == want else f"; catalog eol_floor.{key} = {want}")))
        except Unavailable as exc:
            out.append(row(f"eol:{product}", "unavailable", str(exc)))
    return out


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-ddev-facts.py",
        description="Verify ddev-ops' DDEV facts stay stated (offline) and true upstream (live).",
        epilog=("Examples:\n"
                "  check-ddev-facts.py --offline\n"
                "  check-ddev-facts.py --live\n"
                "  check-ddev-facts.py --offline --json | jq '.data[] | select(.status != \"ok\")'\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="catalog <-> prose consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="compare the catalog with upstream sources")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--fixtures", help="live mode: read sources from this directory instead of the network")
    p.add_argument("--today", help="live mode: date for the EOL floor (YYYY-MM-DD, default today UTC)")
    p.add_argument("--timeout", type=float, default=20.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    if (args.fixtures or args.today) and not args.live:
        print("error: --fixtures and --today apply to --live only", file=sys.stderr)
        return EX_USAGE
    today = dt.datetime.now(dt.timezone.utc).date()
    if args.today:
        try:
            today = dt.date.fromisoformat(args.today)
        except ValueError:
            print(f"error: --today must be YYYY-MM-DD, got {args.today!r}", file=sys.stderr)
            return EX_USAGE
    fixtures = Path(args.fixtures) if args.fixtures else None
    if fixtures is not None and not fixtures.is_dir():
        print(f"error: fixtures directory not found: {fixtures}", file=sys.stderr)
        return EX_NOTFOUND

    cat = load_catalog(Path(args.catalog))
    findings = (check_live(cat, Sources(fixtures, args.timeout), today) if args.live
                else check_offline(cat, Path(args.skill)))
    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]

    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "mode": "live" if args.live else "offline",
                                   "as_of": cat["as_of"], "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")
    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-ddev-facts: {verdict} ({len(findings)} checks, {len(drift)} drift, "
              f"{len(unavailable)} unavailable)", file=sys.stderr)
    if drift:
        return EX_DRIFT
    return EX_UNAVAILABLE if unavailable else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
