#!/usr/bin/env python3
"""Staleness verifier for docker-ops (and kubernetes-ops): the container-tooling facts the
skills state must stay stated (offline) and true upstream (live).

The skills pin advice to facts that move: Compose's major (it jumped from v2 to v5), the WSL
line and whether it can compact a disk, Podman's major, Lima and Colima, the Kubernetes
minor, Helm's major and Gateway API's minor. They also pin the trivy-action commit (its
tags were force-pushed in March 2026, so only a SHA pin is safe), the oldest supported
Node.js, Python, PHP and Go lines (docker-audit.py's base-eol check reads these), and the
Docker Desktop release that stopped compacting its WSL disk. All of them live once, in
assets/docker-facts.json. Two modes:

  --offline (default, safe for PR CI): no network.
    * the catalog parses and is internally consistent (each release's line is a prefix of
      its tag; every prose token contains the catalog value it states)
    * every prose token is still stated in its skill's SKILL.md or references/*.md (tokens
      marked "skill": "kubernetes-ops" are looked up in the sibling kubernetes-ops folder,
      and skipped with a notice when that folder is not there)
    * SKILL.md carries a "Versions verified YYYY-MM-DD" note equal to as_of
  --live (scheduled freshness job, never a PR gate):
    * the newest stable GitHub release of each tracked project vs its catalog line (a newer
      major or minor, as the entry's `track` says, is drift; trivy-action drifts on any new tag)
    * endoflife.date: the oldest supported Node.js, Python, PHP and Go lines today
    * Docker Desktop's release notes: a release after the one that disabled WSL disk
      compaction that mentions compaction again is drift (disk-reclaim.md must change)

Sources: https://api.github.com/repos/<repo>/releases, https://endoflife.date/api/<product>.json,
https://raw.githubusercontent.com/docker/docs/main/content/manuals/desktop/release-notes.md.
GITHUB_TOKEN, when set, is sent to api.github.com only (never printed).

Usage:   check-docker-facts.py [--offline | --live] [--catalog FILE] [--skill DIR]
                               [--fixtures DIR] [--today YYYY-MM-DD] [--json] [--timeout S] [-q]
Input:   argv flags only (no stdin). --fixtures (live only) reads releases-<key>.json,
         eol-<product>.json and desktop-release-notes.md from DIR instead of the network.
Output:  stdout = findings (check<TAB>status<TAB>detail rows, or the --json envelope,
         schema claude-mods.docker-ops.facts/v1). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable,
         7 a source was unreachable (live, advisory - never a real failure),
         10 drift (offline: catalog/prose disagree; live: upstream moved)

Examples:
  check-docker-facts.py --offline                      # PR CI: catalog <-> prose consistency
  check-docker-facts.py --live                         # weekly: did a tool or an EOL floor move?
  check-docker-facts.py --offline --json | jq '.data[] | select(.status != "ok")'
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

SCHEMA = "claude-mods.docker-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "docker-facts.json"
DEFAULT_SKILL = HERE.parent

RELEASES_URL = "https://api.github.com/repos/{repo}/releases?per_page=40"
EOL_URL = "https://endoflife.date/api/{product}.json"
DESKTOP_NOTES_URL = "https://raw.githubusercontent.com/docker/docs/main/content/manuals/desktop/release-notes.md"
EOL_PRODUCTS = {"node": "nodejs", "python": "python", "php": "php", "golang": "go"}
TRACKS = ("major", "minor", "tag")

AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOTE_RE = re.compile(r"Versions verified (\d{4}-\d{2}-\d{2})")
SEMVER_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


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
        for name in EOL_PRODUCTS:
            if not re.match(r"^\d+(\.\d+)?$", str(lookup(cat, f"eol_floor.{name}"))):
                raise ValueError(f"eol_floor.{name} must look like 22 or 3.10")
        for key, rel in lookup(cat, "releases").items():
            for k in ("repo", "tag", "line", "track"):
                if not isinstance(rel.get(k), str) or not rel[k]:
                    raise ValueError(f"releases.{key}.{k} must be a non-empty string")
            if rel["track"] not in TRACKS:
                raise ValueError(f"releases.{key}.track must be one of {', '.join(TRACKS)}")
            if not rel["tag"].lstrip("v").startswith(rel["line"].lstrip("v")):
                raise ValueError(f"releases.{key}.line {rel['line']!r} is not a prefix of its tag {rel['tag']!r}")
        if not re.match(r"^[0-9a-f]{40}$", str(lookup(cat, "releases.trivy_action.sha"))):
            raise ValueError("releases.trivy_action.sha must be a full 40-hex commit SHA")
        lookup(cat, "desktop.compaction_disabled_in")
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
        print(f"error: facts catalog {path} lacks {exc.args[0]}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)
    except (json.JSONDecodeError, ValueError, AttributeError) as exc:
        print(f"error: facts catalog {path} is malformed: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


# === Offline ===

def skill_text(skill: Path) -> str:
    parts = [(skill / "SKILL.md").read_text(encoding="utf-8")]
    for ref in sorted((skill / "references").glob("*.md")):
        parts.append(ref.read_text(encoding="utf-8"))
    return "\n".join(parts)


def offline(cat: dict, skill: Path, rows: list):
    texts = {"docker-ops": skill_text(skill)}
    sibling = skill.parent / "kubernetes-ops"
    if (sibling / "SKILL.md").is_file():
        texts["kubernetes-ops"] = skill_text(sibling)
    for t in cat["prose_tokens"]:
        value = str(lookup(cat, t["value_of"]))
        owner = t.get("skill", "docker-ops")
        if value.lstrip("v") not in t["token"]:
            rows.append((f"token:{t['key']}", "drift", f"token {t['token']!r} does not contain {t['value_of']} = {value!r}"))
        elif owner not in texts:
            rows.append((f"token:{t['key']}", "skipped", f"{owner} is not beside this skill"))
        elif t["token"] not in texts[owner]:
            rows.append((f"token:{t['key']}", "drift", f"{owner} no longer states {t['token']!r}"))
        else:
            rows.append((f"token:{t['key']}", "ok", f"{owner} states {t['token']!r}"))
    m = NOTE_RE.search((skill / "SKILL.md").read_text(encoding="utf-8"))
    if not m:
        rows.append(("versions-note", "drift", 'SKILL.md has no "Versions verified YYYY-MM-DD" note'))
    elif m.group(1) != cat["as_of"]:
        rows.append(("versions-note", "drift", f"SKILL.md says verified {m.group(1)}, the catalog says {cat['as_of']}"))
    else:
        rows.append(("versions-note", "ok", f"verified {m.group(1)}"))


# === Live ===

class Source:
    def __init__(self, timeout: float, fixtures: Path | None):
        self.timeout, self.fixtures = timeout, fixtures

    def text(self, url: str, fixture: str) -> str:
        if self.fixtures:
            p = self.fixtures / fixture
            if not p.is_file():
                raise Unavailable(f"fixture {fixture} missing")
            return p.read_text(encoding="utf-8")
        headers = {"User-Agent": "claude-mods-check-docker-facts"}
        if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=self.timeout) as r:
                return r.read().decode("utf-8")
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise Unavailable(f"{url}: {getattr(exc, 'reason', exc)}")

    def json(self, url: str, fixture: str):
        try:
            return json.loads(self.text(url, fixture))
        except ValueError:
            raise Unavailable(f"{url}: unreadable JSON")


def version_of(tag: str):
    m = SEMVER_RE.search(tag)
    return tuple(int(x or 0) for x in m.groups()) if m else None


def newest_stable(releases) -> str | None:
    best, best_tag = None, None
    for r in releases if isinstance(releases, list) else []:
        if r.get("draft") or r.get("prerelease"):
            continue
        tag = str(r.get("tag_name", ""))
        if re.search(r"-(alpha|beta|rc)", tag, re.I):
            continue
        v = version_of(tag)
        if v and (best is None or v > best):
            best, best_tag = v, tag
    return best_tag


def line_of(tag: str, track: str) -> str:
    v = version_of(tag)
    if not v or track == "tag":
        return tag
    return str(v[0]) if track == "major" else f"{v[0]}.{v[1]}"


def eol_floor(cycles, today: dt.date) -> str | None:
    live = []
    for c in cycles if isinstance(cycles, list) else []:
        eol = c.get("eol")
        alive = eol is False or (isinstance(eol, str) and eol > today.isoformat())
        if alive and version_of(str(c.get("cycle", "")) + ".0") or (alive and str(c.get("cycle", "")).isdigit()):
            live.append(str(c["cycle"]))
    if not live:
        return None
    return min(live, key=lambda s: tuple(int(x) for x in s.split(".")))


def live(cat: dict, src: Source, today: dt.date, rows: list):
    for key, rel in cat["releases"].items():
        try:
            newest = newest_stable(src.json(RELEASES_URL.format(repo=rel["repo"]), f"releases-{key}.json"))
        except Unavailable as exc:
            rows.append((f"release:{key}", "unavailable", str(exc)))
            continue
        if not newest:
            rows.append((f"release:{key}", "unavailable", f"{rel['repo']} lists no stable release"))
            continue
        have, now = rel["line"], line_of(newest, rel["track"])
        newer = (version_of(now + ".0.0") or ()) > (version_of(have + ".0.0") or ()) if rel["track"] != "tag" \
            else (version_of(newest) or ()) > (version_of(rel["tag"]) or ())
        if newer:
            rows.append((f"release:{key}", "drift", f"{rel['repo']} is at {newest}; the catalog tracks {have} "
                         f"({rel['track']}); re-verify the prose and bump releases.{key}"))
        else:
            rows.append((f"release:{key}", "ok", f"{rel['repo']} newest stable {newest} (tracks {have})"))
    for name, product in EOL_PRODUCTS.items():
        try:
            floor = eol_floor(src.json(EOL_URL.format(product=product), f"eol-{product}.json"), today)
        except Unavailable as exc:
            rows.append((f"eol:{name}", "unavailable", str(exc)))
            continue
        have = cat["eol_floor"][name]
        if floor is None:
            rows.append((f"eol:{name}", "unavailable", f"endoflife.date lists no supported {product} line"))
        elif floor != have:
            rows.append((f"eol:{name}", "drift", f"the oldest supported {product} line is now {floor}; the catalog says {have}"))
        else:
            rows.append((f"eol:{name}", "ok", f"oldest supported {product} line {floor}"))
    try:
        notes = src.text(DESKTOP_NOTES_URL, "desktop-release-notes.md")
    except Unavailable as exc:
        rows.append(("desktop:compaction", "unavailable", str(exc)))
        return
    since = cat["desktop"]["compaction_disabled_in"]
    m = re.search(rf"^##\s+{re.escape(since)}(\.0)?\b", notes, re.M)
    if not m:
        rows.append(("desktop:compaction", "unavailable", f"no '## {since}' heading in the release notes"))
        return
    newer = notes[:m.start()]
    heads = re.findall(r"^##\s+(\d+\.\d+\.\d+)", newer, re.M)
    hit = re.search(r"^.*compact.*$", newer, re.M | re.I)
    if hit:
        rows.append(("desktop:compaction", "drift", f"a release after {since} mentions compaction "
                     f"({hit.group(0).strip()[:120]!r}); re-check references/disk-reclaim.md"))
    else:
        latest = heads[0] if heads else since
        rows.append(("desktop:compaction", "ok", f"no release from {since} to {latest} mentions compaction"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="check-docker-facts.py", description=(__doc__ or "").split("\n\n", 1)[0],
        epilog="EXAMPLES:\n  check-docker-facts.py --offline\n  check-docker-facts.py --live\n"
               "  check-docker-facts.py --offline --json",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="catalog <-> prose consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="compare the catalog with upstream")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--skill", type=Path, default=DEFAULT_SKILL, help="the docker-ops skill folder")
    ap.add_argument("--fixtures", type=Path, help="live mode: read sources from this directory")
    ap.add_argument("--today", help="date for the EOL comparison (YYYY-MM-DD; default today)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("-q", "--quiet", action="store_true")
    opts = ap.parse_args(argv)
    if opts.fixtures and not opts.live:
        print("error: --fixtures needs --live", file=sys.stderr)
        return EX_USAGE
    try:
        today = dt.date.fromisoformat(opts.today) if opts.today else dt.date.today()
    except ValueError:
        print(f"error: --today {opts.today!r} is not YYYY-MM-DD", file=sys.stderr)
        return EX_USAGE
    if not (opts.skill / "SKILL.md").is_file():
        print(f"error: no SKILL.md in {opts.skill}", file=sys.stderr)
        return EX_NOTFOUND
    cat = load_catalog(opts.catalog)
    rows: list = []
    if opts.live:
        live(cat, Source(opts.timeout, opts.fixtures), today, rows)
    else:
        offline(cat, opts.skill, rows)
    if opts.json:
        print(json.dumps({"data": [{"check": c, "status": s, "detail": d} for c, s, d in rows],
                          "meta": {"count": len(rows), "schema": SCHEMA, "mode": "live" if opts.live else "offline",
                                   "as_of": cat["as_of"]}}, indent=2))
    else:
        for c, s, d in rows:
            print(f"{c}\t{s}\t{d}")
    drift = [r for r in rows if r[1] == "drift"]
    unavailable = [r for r in rows if r[1] == "unavailable"]
    if not opts.quiet:
        mode_name = "live" if opts.live else "offline"
        if drift:
            print(f"check-docker-facts ({mode_name}): {len(drift)} drift", file=sys.stderr)
        elif unavailable:
            print(f"check-docker-facts ({mode_name}): no drift, {len(unavailable)} source(s) unreachable", file=sys.stderr)
        else:
            print(f"check-docker-facts ({mode_name}): consistent ({len(rows)} checks)", file=sys.stderr)
    if drift:
        return EX_DRIFT
    if unavailable:
        return EX_UNAVAILABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
