#!/usr/bin/env python3
"""Staleness verifier for package-manager-ops: the release tables and tool majors the skill
encodes (and pm-audit.py reads at run time) must stay current and named in the prose.

Node and PHP support windows, npm/pnpm/Yarn/Composer majors, Corepack's unbundling and
Volta's status all move under the prose without anyone noticing (SKILL-RESOURCE-PROTOCOL.md
§7). A stale end-of-life table is worse than none: pm-audit would call a dead runtime
supported. Two modes guard it:

  --offline (default, safe for PR CI): structural consistency, no network.
    * assets/package-manager-facts.json parses; dates are ISO and ordered
      (lts < maintenance < end; initial < active_end <= security_end)
    * every package prose token and dated fact is named in SKILL.md / references/*.md
    * SKILL.md carries a dated "as of <year>" currency note
    * the data tables pm-audit reads: legacy_packages, composer.lines + feature_floors,
      craft.majors, eol_soon_days (types, ISO dates, ordering, ids, "see" targets)
  --live (scheduled freshness.yml, never a PR gate):
    * npm packages: latest dist-tag major vs documented_major
    * Composer: getcomposer.org/versions stable major, the 1.x end-of-life date and the
      2.x lines in composer.lines; GitHub repos: latest release major
    * Node: nodejs/Release schedule.json end dates, released lines, LTS codenames
    * PHP: php.net's first-party branches.php JSON vs the table (the old supported-versions
      HTML scrape is only a fallback when the JSON is unavailable, never when it is gone)
    * endoflife.date v1: PHP and Node end-of-life dates cross-checked; a disagreement is drift
    * text_watch: each status page still contains its phrase (e.g. Volta "unmaintained")
    Gone (404/410), changed, or answering in a new format (a timestamp where a date was) is
    DRIFT; transient failure is UNAVAILABLE (exit 7). A malformed catalogue is exit 4.
    Unknown new keys in an upstream answer (Node's schedule.json gained `alpha`) are ignored.
    --cache-dir keeps each body with its Last-Modified and revalidates with
    If-Modified-Since, so a 304 costs the source almost nothing.

Usage:   check-pm-facts.py [--offline | --live] [--facts FILE] [--skill DIR] [--json] [--timeout S]
                          [--cache-dir DIR]
Input:   argv flags only (no stdin). GITHUB_TOKEN (optional) raises the GitHub API limit.
Output:  stdout = findings (plain rows, or a --json envelope). Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 ok, 2 usage, 3 facts/skill missing, 4 facts unparseable,
         7 source unreachable (live, advisory - never a real failure),
         10 drift (offline: uncited token / bad dates / missing note; live: source disagrees)

Examples:
  bash scripts/run-python.sh scripts/check-pm-facts.py --offline     # PR CI: catalogue <-> prose
  bash scripts/run-python.sh scripts/check-pm-facts.py --live        # weekly: did Node/PHP/npm move?
  bash scripts/run-python.sh scripts/check-pm-facts.py --live --json | jq '.data[]'
  bash scripts/run-python.sh scripts/check-pm-facts.py --live --cache-dir .cache/pm-facts
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

EX_OK, EX_USAGE, EX_NOTFOUND, EX_UNPARSEABLE, EX_UNAVAILABLE, EX_DRIFT = 0, 2, 3, 4, 7, 10
SCHEMA = "claude-mods.package-manager-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_FACTS = HERE.parent / "assets" / "package-manager-facts.json"
DEFAULT_SKILL = HERE.parent
REGISTRIES = ("npm", "composer", "github")
LEGACY_ECOSYSTEMS = ("npm", "composer")
EOL_CROSSCHECK_DAYS = 730
NPM = "https://registry.npmjs.org"
COMPOSER_VERSIONS = "https://getcomposer.org/versions"
GITHUB = "https://api.github.com/repos"
NODE_SCHEDULE = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
PHP_BRANCHES = "https://www.php.net/releases/branches.php"
PHP_SUPPORTED = "https://www.php.net/supported-versions.php"
PHP_EOL = "https://www.php.net/eol.php"
EOL_DATE = "https://endoflife.date/api/v1/products"
CURRENCY_RE = re.compile(r"as of 20\d\d")
UA = "claude-mods-package-manager-ops-check/1"


class Term:
    """Minimal ANSI helper. Honors FORCE_COLOR / NO_COLOR / TERM_ASCII and the
    bound stream's TTY + encoding so piped data stays plain ASCII."""

    _C = {"green": "\033[32m", "red": "\033[31m", "dim": "\033[2m", "off": "\033[0m"}

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

    def mark(self, ok):
        g = ("+" if self.ascii else "✓") if ok else ("x" if self.ascii else "✗")
        return self.c("green" if ok else "red", g)


def _iso(s) -> dt.date:
    return dt.date.fromisoformat(str(s))


def _iso_or_none(s):
    """An upstream date, or None when it is not YYYY-MM-DD (the source changed its format:
    the caller reports that as drift instead of crashing on it)."""
    try:
        return dt.date.fromisoformat(str(s))
    except ValueError:
        return None


def _shape(data) -> None:
    """Raise ValueError naming the first part of the catalogue whose type is wrong. Every
    field the offline and live checks read is checked here, so a bad catalogue is exit 4
    with a message, never a TypeError traceback halfway through a check."""
    def strs(v):
        return isinstance(v, list) and all(isinstance(x, str) and x for x in v)
    if not isinstance(data, dict):
        raise ValueError(f"top level is {type(data).__name__}, not an object")
    if data.get("schema") != SCHEMA:
        raise ValueError(f"schema {data.get('schema')!r} != {SCHEMA!r}")
    pk = data.get("packages")
    if not isinstance(pk, dict) or not [k for k in pk if k != "_comment"]:
        raise ValueError("'packages' must be a non-empty object")
    for name, info in pk.items():
        if name == "_comment":
            continue
        if not isinstance(info, dict) or not isinstance(info.get("documented_major"), int) \
                or isinstance(info.get("documented_major"), bool):
            raise ValueError(f"package {name!r} needs an integer documented_major")
        if info.get("registry") not in REGISTRIES:
            raise ValueError(f"package {name!r} registry must be one of {REGISTRIES}")
        if not strs(info.get("prose")) or not info["prose"]:
            raise ValueError(f"package {name!r} needs a non-empty list of string prose tokens")
    for section, fields in (("node", ("lts", "maintenance", "end")), ("php", ("initial", "active_end", "security_end"))):
        sec = data.get(section)
        rel = sec.get("releases") if isinstance(sec, dict) else None
        if not isinstance(rel, dict):
            raise ValueError(f"{section}.releases must be an object")
        for ver, entry in rel.items():
            if ver == "_comment":
                continue
            if not re.match(r"^\d+$" if section == "node" else r"^\d+\.\d+$", ver):
                raise ValueError(f"{section}.releases key {ver!r} is not a {'major' if section == 'node' else 'major.minor'}")
            if not isinstance(entry, dict) or not all(isinstance(entry[f], str) for f in fields if f in entry):
                raise ValueError(f"{section}.releases[{ver!r}] must be an object of date strings")
    codes = data["node"].get("lts_codenames", {})
    if not isinstance(codes, dict) or not all(isinstance(v, int) for k, v in codes.items() if k != "_comment"):
        raise ValueError("node.lts_codenames must map names to integer majors")
    cli = data.get("native_cli_names")
    if not (isinstance(cli, dict) and strs(cli.get("names"))):
        raise ValueError("native_cli_names.names must be a list of strings")
    for key in ("dated_facts", "text_watch", "composer", "craft"):
        if key in data and not isinstance(data[key], dict):
            raise ValueError(f"{key} must be an object")
    # Container types only: the contents (dates, ids, ordering) are --offline findings (exit 10).
    # A wrong container is exit 4 so the live checks can index these without a TypeError.
    if "legacy_packages" in data and not isinstance(data["legacy_packages"], list):
        raise ValueError("legacy_packages must be a list")
    comp = data.get("composer") or {}
    for key in ("lines", "feature_floors"):
        if key in comp and not isinstance(comp[key], dict):
            raise ValueError(f"composer.{key} must be an object")
    if "majors" in (data.get("craft") or {}) and not isinstance(data["craft"]["majors"], dict):
        raise ValueError("craft.majors must be an object")


def load_facts(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalogue not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        print(f"error: cannot read facts catalogue {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(text)
        _shape(data)
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"error: could not parse facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    """SKILL.md, and SKILL.md plus every references/*.md file (a directory that happens to
    end in .md is not one). An unreadable file is exit 3 with its name, not a traceback."""
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    files = [doc] + [r for r in sorted((skill_dir / "references").glob("*.md")) if r.is_file()]
    try:
        parts = [f.read_text(encoding="utf-8", errors="replace") for f in files]
    except OSError as exc:
        print(f"error: cannot read {exc.filename or skill_dir}: {exc.strerror or exc}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    return parts[0], "\n".join(parts)


# =============================================================================
# === offline: data tables pm-audit reads (contract C1) ===
# =============================================================================
LEGACY_FIELDS = ("id", "ecosystem", "name", "versions", "reason", "replacement", "see")
LEGACY_ID_RE = re.compile(r"^legacy\.[a-z0-9][a-z0-9.-]*$")
# An npm range as pm-audit's matcher reads it: "*", a bare version, or comparators joined by spaces/||.
RANGE_RE = re.compile(r"^(\*|[<>=~^v0-9.xX*|\s-]+)$")
SEE_REF_RE = re.compile(r"^references/([A-Za-z0-9._-]+\.md)#([a-z0-9-]+)$")
SEE_SKILL_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
COMPOSER_LINE_RE = re.compile(r"^2\.(\d+)$")


def _slug(heading: str) -> str:
    """GitHub's heading anchor: lowercase, punctuation dropped, spaces to hyphens."""
    return re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", heading.strip().lower()))


def _anchors(skill_dir: Path, ref: str):
    f = skill_dir / "references" / ref
    if not f.is_file():
        return None
    text = f.read_text(encoding="utf-8", errors="replace")
    return {_slug(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+?)\s*$", text, re.M)}


def _open_date(v, subject, label, bad):
    """(valid, date|None). None is legal (an open end: the line is current); any other value
    must be a YYYY-MM-DD string."""
    if v is None:
        return True, None
    try:
        if not isinstance(v, str):
            raise ValueError(v)
        return True, _iso(v)
    except ValueError:
        bad(subject, f"{label} {v!r} is not an ISO date or null")
        return False, None


def check_legacy(facts: dict, skill_dir: Path, bad) -> None:
    entries = facts.get("legacy_packages")
    if entries is None:
        bad("legacy_packages", "missing (pm-audit's legacy.* findings read it)")
        return
    seen: set = set()
    for i, e in enumerate(entries):
        who = f"legacy_packages[{i}]"
        if not isinstance(e, dict):
            bad(who, "entry is not an object")
            continue
        who = f"{who} {e.get('name', '?')}"
        holes = [f for f in LEGACY_FIELDS if not isinstance(e.get(f), str) or not e[f].strip()]
        for f in holes:
            bad(who, f"{f} must be a non-empty string")
        if holes:
            continue
        if not LEGACY_ID_RE.match(e["id"]):
            bad(who, f"id {e['id']!r} must look like legacy.<name>")
        if e["ecosystem"] not in LEGACY_ECOSYSTEMS:
            bad(who, f"ecosystem {e['ecosystem']!r} must be one of {LEGACY_ECOSYSTEMS}")
        if not RANGE_RE.match(e["versions"]):
            bad(who, f"versions {e['versions']!r} is not '*' or an npm range")
        key = (e["ecosystem"], e["name"], e["versions"])
        if key in seen:
            bad(who, "duplicate (ecosystem, name, versions)")
        seen.add(key)
        see = e["see"]
        m = SEE_REF_RE.match(see)
        if m:
            anchors = _anchors(skill_dir, m.group(1))
            if anchors is None:
                bad(who, f"see {see!r}: references/{m.group(1)} does not exist")
            elif m.group(2) not in anchors:
                bad(who, f"see {see!r}: no heading with that anchor")
        elif not SEE_SKILL_RE.match(see):
            bad(who, f"see {see!r} must be a skill name or references/<file>.md#anchor")


def check_composer_lines(facts: dict, bad) -> None:
    comp = facts.get("composer") or {}
    lines, floors = comp.get("lines"), comp.get("feature_floors")
    if lines is None:
        bad("composer.lines", "missing (pm-audit's php.composer.eol reads it)")
    else:
        parsed = {}
        for k, v in lines.items():
            m = COMPOSER_LINE_RE.match(k)
            if not m:
                bad(f"composer.lines {k}", "key must be '2.<minor>'")
            elif not isinstance(v, dict) or not isinstance(v.get("lts"), bool) or "end" not in v:
                bad(f"composer.lines {k}", 'must be {"end": date|null, "lts": bool}')
            else:
                valid, d = _open_date(v["end"], f"composer.lines {k}", "end", bad)
                if valid:
                    parsed[int(m.group(1))] = (d, v["lts"])
        if not parsed:
            bad("composer.lines", "no 2.x line listed")
        else:
            top, prev = max(parsed), None
            for minor in sorted(parsed):
                end, lts = parsed[minor]
                if end is None and minor != top:
                    bad(f"composer.lines 2.{minor}", "end is null but a newer line exists")
                if lts or end is None:
                    continue  # an LTS line outlives its successors: out of sequence on purpose
                if prev is not None and end <= prev[1]:
                    bad(f"composer.lines 2.{minor}",
                        f"end {end} is not after 2.{prev[0]}'s {prev[1]} (a line ends when the next ships)")
                prev = (minor, end)
    if floors is None:
        bad("composer.feature_floors", "missing (pm-audit's php.composer.eol reads it)")
        return
    got = {}
    for k in ("security_blocking", "malware_blocking"):
        v = floors.get(k)
        m = COMPOSER_LINE_RE.match(v) if isinstance(v, str) else None
        if not m:
            bad(f"composer.feature_floors {k}", f"{v!r} must be a '2.<minor>' line")
        elif isinstance(lines, dict) and v not in lines:
            bad(f"composer.feature_floors {k}", f"{v} is not a line in composer.lines")
        else:
            got[k] = int(m.group(1))
    if len(got) == 2 and got["security_blocking"] > got["malware_blocking"]:
        bad("composer.feature_floors", "malware_blocking predates security_blocking (it built on it)")


def check_craft(facts: dict, bad) -> None:
    majors = (facts.get("craft") or {}).get("majors")
    if majors is None:
        bad("craft.majors", "missing (pm-audit's php.craft.eol reads it)")
        return
    prev = None
    for k in sorted((k for k in majors if k != "_comment"), key=lambda x: (not x.isdigit(), int(x) if x.isdigit() else 0)):
        v = majors[k]
        if not k.isdigit():
            bad(f"craft.majors {k}", "key must be a major number")
        elif not isinstance(v, dict) or "security_end" not in v:
            bad(f"craft.majors {k}", 'must be {"security_end": date|null}')
        else:
            valid, d = _open_date(v["security_end"], f"craft.majors {k}", "security_end", bad)
            if valid and d is not None:
                if prev is not None and d <= prev[1]:
                    bad(f"craft.majors {k}", f"security_end {d} is not after Craft {prev[0]}'s {prev[1]}")
                prev = (k, d)
    for need in ("3", "4", "5"):
        if need not in majors:
            bad(f"craft.majors {need}", "missing (Craft 3, 4 and 5 are the lines in the wild)")


def check_c1(facts: dict, skill_dir: Path) -> list:
    out: list = []

    def bad(subject, issue):
        out.append({"subject": subject, "issue": issue})

    check_legacy(facts, skill_dir, bad)
    check_composer_lines(facts, bad)
    check_craft(facts, bad)
    days = facts.get("eol_soon_days")
    if not isinstance(days, int) or isinstance(days, bool) or days <= 0:
        bad("eol_soon_days", f"{days!r} must be a positive integer (days)")
    return out


def check_offline(facts: dict, skill_dir: Path) -> list[dict]:
    skill_md, corpus = read_corpus(skill_dir)
    out: list[dict] = []

    def bad(subject, issue):
        out.append({"subject": subject, "issue": issue})

    for name, info in facts["packages"].items():
        if name == "_comment":
            continue
        for token in info["prose"]:
            if token not in corpus:
                bad(name, f"prose token {token!r} not named in skill")
    for key, token in (facts.get("dated_facts") or {}).items():
        if key != "_comment" and str(token) not in corpus:
            bad("(dated fact)", f"{key}={token!r} not stated in skill prose")
    def ordered(rel, fields, strict):
        """True when the dates present follow each other; strict[i] says whether the step
        from fields[i] to fields[i + 1] must be strictly later (an equal pair is a typo:
        no release enters LTS and maintenance on the same day)."""
        got = [(k, _iso(rel[k])) for k in fields if k in rel]
        return all(b > a if strict[fields.index(kb) - 1] else b >= a
                   for (_, a), (kb, b) in zip(got, got[1:]))

    node = facts["node"]
    for major, rel in node["releases"].items():
        if major == "_comment":
            continue
        try:
            if "end" not in rel:
                bad(f"node {major}", "missing 'end' date")
            elif not ordered(rel, ("lts", "maintenance", "end"), (True, True)):
                bad(f"node {major}", "dates out of order (want lts < maintenance < end)")
        except ValueError as exc:
            bad(f"node {major}", f"non-ISO date: {exc}")
    for cn, major in (node.get("lts_codenames") or {}).items():
        if cn != "_comment" and str(major) not in node["releases"]:
            bad(f"node codename {cn}", f"maps to {major}, which has no releases entry")
    for ver, rel in facts["php"]["releases"].items():
        if ver == "_comment":
            continue
        try:
            if "security_end" not in rel:
                bad(f"php {ver}", "missing 'security_end' date")
            elif not ordered(rel, ("initial", "active_end", "security_end"), (True, False)):
                bad(f"php {ver}", "dates out of order (want initial < active_end <= security_end)")
        except ValueError as exc:
            bad(f"php {ver}", f"non-ISO date: {exc}")
    v1_end = (facts.get("composer") or {}).get("v1_maintenance_until")
    if v1_end is not None:
        try:
            _iso(v1_end)
        except ValueError:
            bad("composer v1", f"v1_maintenance_until {v1_end!r} is not an ISO date")
    for key, w in (facts.get("text_watch") or {}).items():
        if key != "_comment" and not (isinstance(w, dict) and str(w.get("url", "")).startswith("https://") and w.get("contains")):
            bad(f"text_watch {key}", "needs an https url and a 'contains' phrase")
    if not CURRENCY_RE.search(skill_md):
        bad("(SKILL.md)", "no dated 'as of <year>' currency note")
    out += check_c1(facts, skill_dir)
    return out


# =============================================================================
# === live probes ===
# =============================================================================
# Set by main() from --cache-dir. Module state on purpose: fetch()'s (url, timeout, accept)
# signature is what tests/run.sh and tests/facts.sh monkeypatch, so the cache cannot ride
# along as a parameter without breaking every stub.
CACHE_DIR: "Path | None" = None


def _cache_path(url: str):
    return CACHE_DIR / (hashlib.sha1(url.encode("utf-8")).hexdigest() + ".json") if CACHE_DIR else None


def _cache_read(url: str):
    path = _cache_path(url)
    try:
        c = json.loads(path.read_text(encoding="utf-8")) if path and path.is_file() else None
    except (OSError, ValueError):
        return None
    return c if isinstance(c, dict) and isinstance(c.get("body"), str) else None


def _cache_write(url: str, body: str, last_modified) -> None:
    path = _cache_path(url)
    if not path or not last_modified:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"url": url, "last_modified": last_modified, "body": body}), encoding="utf-8")
    except OSError:
        pass  # a cache that cannot be written only costs a full fetch next time


def fetch(url: str, timeout: float, accept: str = "application/json") -> tuple[str, Any]:
    """Return (ok|notfound|unavailable, body-text-or-status). Redirects (301/302) are followed
    by urllib. A 404/410 is "notfound": a source the facts depend on that is gone is DRIFT
    to the callers, never "unreachable". With --cache-dir, If-Modified-Since is sent and a
    304 answers from the cached body."""
    headers = {"User-Agent": UA, "Accept": accept}
    if url.startswith(GITHUB) and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    cached = _cache_read(url)
    if cached and cached.get("last_modified"):
        headers["If-Modified-Since"] = cached["last_modified"]
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            _cache_write(url, body, resp.headers.get("Last-Modified") if getattr(resp, "headers", None) else None)
            return ("ok", body)
    except urllib.error.HTTPError as exc:
        if exc.code == 304 and cached:
            return ("ok", cached["body"])
        return ("notfound", exc.code) if exc.code in (404, 410) else ("unavailable", exc.code)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return ("unavailable", str(getattr(exc, "reason", exc)))


def fetch_json(url: str, timeout: float) -> tuple[str, Any]:
    status, body = fetch(url, timeout)
    if status != "ok":
        return status, body
    try:
        return "ok", json.loads(body)
    except json.JSONDecodeError:
        return "unavailable", "unparseable JSON"


def major_of(version: str) -> int | None:
    m = re.match(r"v?(\d+)", str(version).strip())
    return int(m.group(1)) if m else None


def _first(v) -> dict:
    """The first entry of an upstream list when it is an object, else {}: getcomposer.org
    answers {"stable": [{"version": ...}]}, and a reshaped answer must read as "no version"
    rather than crash."""
    return v[0] if isinstance(v, list) and v and isinstance(v[0], dict) else {}


def live_package(name: str, info: dict, timeout: float) -> tuple[str, int | None, str]:
    reg = info["registry"]
    if reg == "npm":
        status, body = fetch_json(f"{NPM}/{urllib.parse.quote(name, safe='@')}/latest", timeout)
        ver = body.get("version") if status == "ok" and isinstance(body, dict) else None
    elif reg == "composer":
        status, body = fetch_json(COMPOSER_VERSIONS, timeout)
        ver = _first(body.get("stable")).get("version") if status == "ok" and isinstance(body, dict) else None
    else:
        status, body = fetch_json(f"{GITHUB}/{name}/releases/latest", timeout)
        ver = body.get("tag_name") if status == "ok" and isinstance(body, dict) else None
    if status != "ok":
        return status, None, str(body)
    return ("ok", major_of(ver), str(ver)) if ver and major_of(ver) is not None else ("unavailable", None, "no version field")


def live_node(facts: dict, timeout: float, today: dt.date) -> tuple[list, list]:
    drift, unreach = [], []
    status, sched = fetch_json(NODE_SCHEDULE, timeout)
    if status != "ok" or not isinstance(sched, dict):
        (drift if status == "notfound" else unreach).append({"subject": "node schedule", "issue": f"{NODE_SCHEDULE}: {sched}"})
        return drift, unreach
    rel = facts["node"]["releases"]
    codes = {k.lower(): v for k, v in (facts["node"].get("lts_codenames") or {}).items()}
    for key, s in sched.items():
        m = re.match(r"^v(\d+)$", key)
        if not m or int(m.group(1)) < 10:
            continue
        major = m.group(1)
        # WHY drift, not a crash: a reshaped schedule.json (a timestamp where a date was, a
        # list where an object was) means the verifier must be re-read against the source.
        if not isinstance(s, dict):
            drift.append({"subject": f"node {major}", "issue": f"schedule.json format changed: entry is {type(s).__name__}"})
            continue
        bad = [k for k in ("start", "lts", "maintenance", "end") if s.get(k) and _iso_or_none(s[k]) is None]
        if bad:
            drift.append({"subject": f"node {major}", "issue": "schedule.json format changed: "
                          + ", ".join(f"{k} {s[k]!r}" for k in bad) + " is not YYYY-MM-DD"})
            continue
        started = s.get("start") and _iso(s["start"]) <= today
        mine = rel.get(major)
        if mine is None:
            if started:
                drift.append({"subject": f"node {major}", "issue": "released line missing from facts node.releases"})
            continue
        for k in ("lts", "maintenance", "end"):
            if k in mine and s.get(k) and str(s[k]) != mine[k]:
                drift.append({"subject": f"node {major}", "issue": f"{k} {mine[k]} != schedule {s[k]}"})
        cn = str(s.get("codename") or "").lower()
        if cn and codes.get(cn) != int(major):
            drift.append({"subject": f"node {major}", "issue": f"codename {s['codename']!r} not in facts lts_codenames"})
    return drift, unreach


def _php_date(s: str) -> str | None:
    try:
        return dt.datetime.strptime(re.sub(r"\s+", " ", s.strip()), "%d %b %Y").date().isoformat()
    except ValueError:
        return None


def _day(v):
    """YYYY-MM-DD from php.net's '2025-11-20T00:00:00+00:00', or None."""
    return v[:10] if isinstance(v, str) and _iso_or_none(v[:10]) else None


def _php_branches(timeout: float):
    """php.net's first-party JSON: [{branch, initial_release, active_support_end,
    security_support_end, ...}]. Returns (status, {branch: {initial, active_end, security_end}})
    or (status, detail). WHY this over the HTML: the supported-versions page is markup meant
    for humans (a class rename blinds the scrape); this is the page's own data feed."""
    status, body = fetch_json(PHP_BRANCHES, timeout)
    if status != "ok":
        return status, body
    if not isinstance(body, list):
        return "drift", f"{PHP_BRANCHES} no longer answers a list ({type(body).__name__})"
    live: dict = {}
    for row in body:
        v = row.get("branch") if isinstance(row, dict) else None
        if isinstance(v, str) and re.match(r"^\d+\.\d+$", v):
            live[v] = {"initial": _day(row.get("initial_release")), "active_end": _day(row.get("active_support_end")),
                       "security_end": _day(row.get("security_support_end"))}
    if len(live) < 5 or not any(e["security_end"] for e in live.values()):
        return "drift", f"{PHP_BRANCHES} format changed: parsed {len(live)} branch(es) with dates"
    return "ok", live


def _php_scrape(timeout: float):
    """Fallback only (branches.php unavailable, not gone): the supported-versions + eol HTML."""
    s1, sup = fetch(PHP_SUPPORTED, timeout, "text/html")
    s2, eol = fetch(PHP_EOL, timeout, "text/html")
    gone = [u for u, s in ((PHP_SUPPORTED, s1), (PHP_EOL, s2)) if s == "notfound"]
    if gone:
        return "notfound", f"{', '.join(gone)} is gone (404) - find the page's new URL"
    if s1 != "ok" or s2 != "ok":
        return "unavailable", f"supported={s1}:{sup if s1 != 'ok' else ''} eol={s2}:{eol if s2 != 'ok' else ''}"
    live: dict = {}
    # supported-versions: <tr class="security|stable"> ... version=8.4">8.4</a> ... 3 date cells
    for row in re.findall(r'<tr class="(?:security|stable)">(.*?)</tr>', sup, re.S):
        v = re.search(r"version=(\d+\.\d+)", row)
        dates = [d for d in (_php_date(x) for x in re.findall(r"<td>\s*(\d{1,2} [A-Z][a-z]{2} \d{4})\s*</td>", row)) if d]
        if v and len(dates) >= 3:
            live[v.group(1)] = {"security_end": dates[2]}
    for v, d in re.findall(r"<td>(\d+\.\d+)</td>\s*<td>\s*(\d{1,2} [A-Z][a-z]{2} \d{4})", eol):
        iso = _php_date(d)
        if iso:
            live.setdefault(v, {"security_end": iso})
    if len(live) < 5:
        return "unavailable", f"page layout changed? parsed only {len(live)} branch(es)"
    return "ok", live


def live_php(facts: dict, timeout: float) -> tuple[list, list]:
    drift, unreach = [], []
    status, live = _php_branches(timeout)
    if status in ("notfound", "drift"):
        # Gone (404/410) or reshaped is drift, as live_node treats schedule.json: the source
        # moved, so the table cannot be checked until the URL/parser is updated. Falling
        # back to the HTML here would hide that the first-party feed is the one that broke.
        issue = f"{PHP_BRANCHES} is gone ({live}) - find the feed's new URL" if status == "notfound" else str(live)
        drift.append({"subject": "php.net", "issue": issue})
        return drift, unreach
    if status != "ok":
        status, live = _php_scrape(timeout)
        if status == "notfound":
            drift.append({"subject": "php.net", "issue": str(live)})
            return drift, unreach
        if status != "ok":
            unreach.append({"subject": "php.net", "issue": f"{PHP_BRANCHES} unavailable; fallback: {live}"})
            return drift, unreach
    mine = {k: v for k, v in facts["php"]["releases"].items() if k != "_comment"}
    for v, entry in mine.items():
        if v not in live:
            drift.append({"subject": f"php {v}", "issue": "branch not found on php.net"})
            continue
        for k in ("initial", "active_end", "security_end"):
            if k in entry and live[v].get(k) and live[v][k] != entry[k]:
                drift.append({"subject": f"php {v}", "issue": f"{k} {entry[k]} != php.net {live[v][k]}"})
    oldest = min((tuple(map(int, v.split("."))) for v in mine), default=(0, 0))
    for v in live:
        if tuple(map(int, v.split("."))) > oldest and v not in mine:
            drift.append({"subject": f"php {v}", "issue": "branch on php.net missing from facts php.releases"})
    return drift, unreach


def live_endoflife(facts: dict, timeout: float, today: dt.date) -> tuple[list, list]:
    """Cross-check PHP and Node end-of-life dates against endoflife.date v1, an independent
    aggregator: the first-party feeds can match the table while the table is what is wrong,
    and a disagreement between two sources is DRIFT for a human to read. Lines that ended more
    than EOL_CROSSCHECK_DAYS ago are skipped: the two sources round long-dead dates differently
    (Node 11: 2019-06-01 vs 2019-06-30), and nothing acts on a line dead for years."""
    drift, unreach = [], []
    for product, table, mine_key in (("php", facts["php"]["releases"], "security_end"),
                                     ("nodejs", facts["node"]["releases"], "end")):
        url = f"{EOL_DATE}/{product}/"
        status, body = fetch_json(url, timeout)
        if status == "notfound":
            drift.append({"subject": f"endoflife.date {product}", "issue": f"{url} is gone (404)"})
            continue
        if status != "ok":
            unreach.append({"subject": f"endoflife.date {product}", "issue": f"{url}: {body}"})
            continue
        rel = (body.get("result") or {}).get("releases") if isinstance(body, dict) else None
        if not isinstance(rel, list):
            drift.append({"subject": f"endoflife.date {product}", "issue": "format changed: result.releases is not a list"})
            continue
        theirs = {r["name"]: r.get("eolFrom") for r in rel if isinstance(r, dict) and isinstance(r.get("name"), str)}
        for ver, entry in table.items():
            if ver == "_comment" or ver not in theirs or not isinstance(theirs[ver], str):
                continue  # a line endoflife.date does not track (or has no end for) is not a disagreement
            ended = _iso_or_none(entry[mine_key])
            if ended and (today - ended).days > EOL_CROSSCHECK_DAYS:
                continue
            if theirs[ver] != entry[mine_key]:
                drift.append({"subject": f"{product} {ver}", "issue": f"{mine_key} {entry[mine_key]} != endoflife.date {theirs[ver]}"})
    return drift, unreach


def live_composer_lines(facts: dict, timeout: float) -> tuple[list, list]:
    """composer.lines vs getcomposer.org/versions. That feed lists only the LTS line and the
    channels, so the check is: each listed 2.x line matches (lts, end), and the stable
    version's own line exists in facts with no end."""
    drift, unreach = [], []
    lines = (facts.get("composer") or {}).get("lines")
    if not lines:
        return drift, unreach
    status, body = fetch_json(COMPOSER_VERSIONS, timeout)
    if status == "notfound":
        return [{"subject": "composer lines", "issue": f"{COMPOSER_VERSIONS} is gone (404)"}], unreach
    if status != "ok" or not isinstance(body, dict):
        return drift, [{"subject": "composer lines", "issue": f"{COMPOSER_VERSIONS}: {body}"}]
    for key, val in body.items():
        if not re.match(r"^2\.\d+$", key):
            continue
        row = _first(val) if isinstance(val, list) else val
        mine = lines.get(key)
        if not isinstance(row, dict):
            continue
        if mine is None:
            drift.append({"subject": f"composer {key}", "issue": "line listed by getcomposer.org missing from composer.lines"})
        elif mine.get("lts") != bool(row.get("lts")) or mine.get("end") != row.get("maintenance-until"):
            drift.append({"subject": f"composer {key}", "issue": f"getcomposer.org says lts={row.get('lts')} "
                          f"maintenance-until={row.get('maintenance-until')}, facts say lts={mine.get('lts')} end={mine.get('end')}"})
    m = re.match(r"^(2\.\d+)\.", str(_first(body.get("stable")).get("version", "")))
    if m and m.group(1) not in lines:
        drift.append({"subject": f"composer {m.group(1)}", "issue": "current stable line missing from composer.lines"})
    elif m and lines[m.group(1)].get("end") is not None:
        drift.append({"subject": f"composer {m.group(1)}", "issue": "current stable line has an end date in composer.lines"})
    return drift, unreach


def check_live(facts: dict, timeout: float) -> tuple[list[dict], list[dict]]:
    today = dt.datetime.now(dt.timezone.utc).date()
    drift, unreach = [], []
    for name, info in facts["packages"].items():
        if name == "_comment":
            continue
        status, live, shown = live_package(name, info, timeout)
        if status == "notfound":
            drift.append({"subject": name, "issue": f"no longer resolves ({shown}) - renamed/removed"})
        elif status != "ok":
            unreach.append({"subject": name, "issue": f"source unreachable: {shown}"})
        elif live > info["documented_major"]:
            drift.append({"subject": name, "issue": f"live major {live} ({shown}) ahead of documented {info['documented_major']}"})
    v1_end = (facts.get("composer") or {}).get("v1_maintenance_until")
    if v1_end:
        status, body = fetch_json(COMPOSER_VERSIONS, timeout)
        one = _first(body.get("1")) if status == "ok" and isinstance(body, dict) else None
        if one is None:
            unreach.append({"subject": "composer v1", "issue": f"{COMPOSER_VERSIONS}: {body}"})
        elif not one.get("eol") or one.get("maintenance-until") != v1_end:
            drift.append({"subject": "composer v1", "issue": f"getcomposer.org says eol={one.get('eol')} "
                          f"maintenance-until={one.get('maintenance-until')}, facts say {v1_end}"})
    for d, u in (live_node(facts, timeout, today), live_php(facts, timeout),
                 live_endoflife(facts, timeout, today), live_composer_lines(facts, timeout)):
        drift += d
        unreach += u
    for key, w in (facts.get("text_watch") or {}).items():
        if key == "_comment":
            continue
        if not (isinstance(w, dict) and isinstance(w.get("url"), str) and isinstance(w.get("contains"), str)):
            drift.append({"subject": key, "issue": "text_watch entry needs a url and a 'contains' phrase"})
            continue
        status, body = fetch(w["url"], timeout, "text/plain, text/html")
        if status == "notfound":
            drift.append({"subject": key, "issue": f"{w['url']} is gone (404)"})
        elif status != "ok":
            unreach.append({"subject": key, "issue": f"{w['url']}: {body}"})
        elif w["contains"].lower() not in body.lower():
            drift.append({"subject": key, "issue": f"page no longer says {w['contains']!r} - status changed, re-read it"})
    return drift, unreach


def safe_streams():
    """WHY: piped stdout on Windows defaults to cp1252, and one non-ASCII prose token in a
    drift row raised UnicodeEncodeError mid-report. stdout is data, so it is UTF-8 always;
    stderr keeps its encoding (Term picks ASCII glyphs from it) but escapes the rest."""
    for stream, kw in ((sys.stdout, {"encoding": "utf-8", "errors": "backslashreplace"}),
                       (sys.stderr, {"errors": "backslashreplace"})):
        reconfigure = getattr(stream, "reconfigure", None)
        try:
            if reconfigure:
                reconfigure(**kw)
        except ValueError:
            pass


def main(argv: list[str]) -> int:
    safe_streams()
    p = argparse.ArgumentParser(
        prog="check-pm-facts.py",
        description="Verify package-manager-ops' release tables and tool majors stay named (offline) "
                    "and current against nodejs.org, php.net, npm, Composer and GitHub (live).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/check-pm-facts.py --offline\n"
               "  bash scripts/run-python.sh scripts/check-pm-facts.py --live --json | jq '.data[]'\n"
               "  bash scripts/run-python.sh scripts/check-pm-facts.py --live --cache-dir .cache/pm-facts\n"
               "Exit: 0 ok, 2 usage, 3 facts/skill missing, 4 facts unparseable, 7 source unreachable, 10 drift",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="release tables + majors vs primary sources")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalogue JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=15.0, help="per-request timeout seconds (live)")
    p.add_argument("--cache-dir", default=None, help="keep fetched bodies here and revalidate with If-Modified-Since (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    # socket timeouts must be finite and positive: 0 means non-blocking (every probe then
    # "fails" at once) and a negative value raises ValueError deep inside urllib.
    if not (math.isfinite(args.timeout) and args.timeout > 0):
        print(f"error: --timeout wants seconds > 0, got {args.timeout}", file=sys.stderr)
        return EX_USAGE

    global CACHE_DIR
    CACHE_DIR = Path(args.cache_dir) if args.cache_dir else None
    facts = load_facts(Path(args.facts))
    t = Term(sys.stderr)
    n_pkgs = len([k for k in facts["packages"] if k != "_comment"])

    if args.live:
        drift, unreach = check_live(facts, args.timeout)
        findings = drift + unreach
        if args.json:
            print(json.dumps({"data": findings,
                              "meta": {"mode": "live", "packages_checked": n_pkgs, "drift": len(drift),
                                       "unreachable": len(unreach), "schema": SCHEMA}}, indent=2))
        else:
            for f in findings:
                print(f"{'DRIFT' if f in drift else 'UNREACH'}  {f['subject']}: {f['issue']}")
        if drift:
            print(f"{t.mark(False)} pm-facts/live: {len(drift)} drifted", file=sys.stderr)
            return EX_DRIFT
        if unreach:
            print(f"{t.mark(False)} pm-facts/live: {len(unreach)} unreachable {t.c('dim', '(advisory - retry next run)')}",
                  file=sys.stderr)
            return EX_UNAVAILABLE
        print(f"{t.mark(True)} pm-facts/live: {n_pkgs} package(s), Node + PHP tables and status pages current",
              file=sys.stderr)
        return EX_OK

    findings = check_offline(facts, Path(args.skill))
    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"mode": "offline", "packages_checked": n_pkgs, "drift": len(findings),
                                   "consistent": not findings, "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"DRIFT  {f['subject']}: {f['issue']}")
    print(f"{t.mark(not findings)} pm-facts/offline: {n_pkgs} package(s), Node + PHP tables checked, "
          f"{len(findings)} inconsistency {t.c('dim', '(catalogue vs skill prose)')}", file=sys.stderr)
    return EX_DRIFT if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
