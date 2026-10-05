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
  --live (scheduled freshness.yml, never a PR gate):
    * npm packages: latest dist-tag major vs documented_major
    * Composer: getcomposer.org/versions stable major and the 1.x end-of-life date;
      GitHub repos: latest release major
    * Node: nodejs/Release schedule.json end dates, released lines, LTS codenames
    * PHP: php.net supported-versions + eol pages vs the security_end table
    * text_watch: each status page still contains its phrase (e.g. Volta "unmaintained")
    Gone (404) or changed is DRIFT; transient failure is UNAVAILABLE (exit 7).

Usage:   check-pm-facts.py [--offline | --live] [--facts FILE] [--skill DIR] [--json] [--timeout S]
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
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
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
NPM = "https://registry.npmjs.org"
COMPOSER_VERSIONS = "https://getcomposer.org/versions"
GITHUB = "https://api.github.com/repos"
NODE_SCHEDULE = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
PHP_SUPPORTED = "https://www.php.net/supported-versions.php"
PHP_EOL = "https://www.php.net/eol.php"
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


def load_facts(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalogue not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("schema") != SCHEMA:
            raise ValueError(f"schema {data.get('schema')!r} != {SCHEMA!r}")
        pk = data.get("packages")
        if not isinstance(pk, dict) or not [k for k in pk if k != "_comment"]:
            raise ValueError("'packages' must be a non-empty object")
        for name, info in pk.items():
            if name == "_comment":
                continue
            if not isinstance(info, dict) or not isinstance(info.get("documented_major"), int):
                raise ValueError(f"package {name!r} needs an integer documented_major")
            if info.get("registry") not in REGISTRIES:
                raise ValueError(f"package {name!r} registry must be one of {REGISTRIES}")
            if not isinstance(info.get("prose"), list) or not info["prose"]:
                raise ValueError(f"package {name!r} missing prose tokens")
        if not isinstance((data.get("node") or {}).get("releases"), dict):
            raise ValueError("node.releases must be an object")
        if not isinstance((data.get("php") or {}).get("releases"), dict):
            raise ValueError("php.releases must be an object")
        names = (data.get("native_cli_names") or {}).get("names")
        if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
            raise ValueError("native_cli_names.names must be a list of strings")
        return data
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"error: could not parse facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def read_corpus(skill_dir: Path) -> tuple[str, str]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        print(f"error: SKILL.md not found under {skill_dir}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    parts = [skill_md] + [r.read_text(encoding="utf-8", errors="replace")
                          for r in sorted((skill_dir / "references").glob("*.md"))]
    return skill_md, "\n".join(parts)


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
    node = facts["node"]
    for major, rel in node["releases"].items():
        try:
            seq = [_iso(rel[k]) for k in ("lts", "maintenance", "end") if k in rel]
            if "end" not in rel:
                bad(f"node {major}", "missing 'end' date")
            elif seq != sorted(seq):
                bad(f"node {major}", "dates out of order (want lts < maintenance < end)")
        except ValueError as exc:
            bad(f"node {major}", f"non-ISO date: {exc}")
    for cn, major in (node.get("lts_codenames") or {}).items():
        if str(major) not in node["releases"]:
            bad(f"node codename {cn}", f"maps to {major}, which has no releases entry")
    for ver, rel in facts["php"]["releases"].items():
        try:
            seq = [_iso(rel[k]) for k in ("initial", "active_end", "security_end") if k in rel]
            if "security_end" not in rel:
                bad(f"php {ver}", "missing 'security_end' date")
            elif seq != sorted(seq):
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
    return out


# =============================================================================
# === live probes ===
# =============================================================================
def fetch(url: str, timeout: float, accept: str = "application/json") -> tuple[str, Any]:
    """Return (ok|notfound|unavailable, body-text-or-status)."""
    headers = {"User-Agent": UA, "Accept": accept}
    if url.startswith(GITHUB) and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as resp:
            return ("ok", resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
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


def live_package(name: str, info: dict, timeout: float) -> tuple[str, int | None, str]:
    reg = info["registry"]
    if reg == "npm":
        status, body = fetch_json(f"{NPM}/{urllib.parse.quote(name, safe='@')}/latest", timeout)
        ver = body.get("version") if status == "ok" and isinstance(body, dict) else None
    elif reg == "composer":
        status, body = fetch_json(COMPOSER_VERSIONS, timeout)
        ver = (body.get("stable") or [{}])[0].get("version") if status == "ok" and isinstance(body, dict) else None
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
        if not m:
            continue
        major = m.group(1)
        if int(major) < 10:
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


def live_php(facts: dict, timeout: float) -> tuple[list, list]:
    drift, unreach = [], []
    s1, sup = fetch(PHP_SUPPORTED, timeout, "text/html")
    s2, eol = fetch(PHP_EOL, timeout, "text/html")
    if s1 != "ok" or s2 != "ok":
        unreach.append({"subject": "php.net", "issue": f"supported={s1}:{sup if s1 != 'ok' else ''} eol={s2}:{eol if s2 != 'ok' else ''}"})
        return drift, unreach
    live: dict[str, str] = {}
    # supported-versions: <tr class="security|stable"> ... version=8.4">8.4</a> ... 3 date cells
    for row in re.findall(r'<tr class="(?:security|stable)">(.*?)</tr>', sup, re.S):
        v = re.search(r"version=(\d+\.\d+)", row)
        dates = [d for d in (_php_date(x) for x in re.findall(r"<td>\s*(\d{1,2} [A-Z][a-z]{2} \d{4})\s*</td>", row)) if d]
        if v and len(dates) >= 3:
            live[v.group(1)] = dates[2]
    for v, d in re.findall(r"<td>(\d+\.\d+)</td>\s*<td>\s*(\d{1,2} [A-Z][a-z]{2} \d{4})", eol):
        iso = _php_date(d)
        if iso:
            live.setdefault(v, iso)
    if len(live) < 5:
        unreach.append({"subject": "php.net", "issue": f"page layout changed? parsed only {len(live)} branch(es)"})
        return drift, unreach
    mine = facts["php"]["releases"]
    for v, end in mine.items():
        if v in live and live[v] != end["security_end"]:
            drift.append({"subject": f"php {v}", "issue": f"security_end {end['security_end']} != php.net {live[v]}"})
        elif v not in live:
            drift.append({"subject": f"php {v}", "issue": "branch not found on php.net supported/eol pages"})
    oldest = min((tuple(map(int, v.split("."))) for v in mine), default=(0, 0))
    for v in live:
        if tuple(map(int, v.split("."))) > oldest and v not in mine:
            drift.append({"subject": f"php {v}", "issue": "branch on php.net missing from facts php.releases"})
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
        one = (body.get("1") or [{}])[0] if status == "ok" and isinstance(body, dict) else None
        if one is None:
            unreach.append({"subject": "composer v1", "issue": f"{COMPOSER_VERSIONS}: {body}"})
        elif not one.get("eol") or one.get("maintenance-until") != v1_end:
            drift.append({"subject": "composer v1", "issue": f"getcomposer.org says eol={one.get('eol')} "
                          f"maintenance-until={one.get('maintenance-until')}, facts say {v1_end}"})
    for d, u in (live_node(facts, timeout, today), live_php(facts, timeout)):
        drift += d
        unreach += u
    for key, w in (facts.get("text_watch") or {}).items():
        if key == "_comment":
            continue
        status, body = fetch(w["url"], timeout, "text/plain, text/html")
        if status == "notfound":
            drift.append({"subject": key, "issue": f"{w['url']} is gone (404)"})
        elif status != "ok":
            unreach.append({"subject": key, "issue": f"{w['url']}: {body}"})
        elif w["contains"].lower() not in body.lower():
            drift.append({"subject": key, "issue": f"page no longer says {w['contains']!r} - status changed, re-read it"})
    return drift, unreach


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-pm-facts.py",
        description="Verify package-manager-ops' release tables and tool majors stay named (offline) "
                    "and current against nodejs.org, php.net, npm, Composer and GitHub (live).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/check-pm-facts.py --offline\n"
               "  bash scripts/run-python.sh scripts/check-pm-facts.py --live --json | jq '.data[]'",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="release tables + majors vs primary sources")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalogue JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/)")
    p.add_argument("--timeout", type=float, default=15.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

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
