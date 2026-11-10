#!/usr/bin/env python3
"""Staleness verifier for shadcn-ops: the pinned CLI and the facts the skill states must
stay stated (offline) and true upstream (live).

shadcn-ops pins one CLI release (assets/shadcn-facts.json cli.version) instead of running
@latest, so the pin itself is the fact that rots: shadcn ships several releases a month,
and the reference pages also lean on the majors of TanStack Table, Recharts, Tailwind CSS,
React and Zod (SKILL-RESOURCE-PROTOCOL.md section 7). Two modes:

  --offline (default, safe for PR CI): no network.
    * the catalog parses; the pin is an exact x.y.z whose major matches cli.major, and it
      had already passed the cooldown when it was recorded (published + cooldown <= as_of)
    * SKILL.md carries "Versions verified YYYY-MM-DD" equal to as_of
    * SKILL.md's allowed-tools pre-approves only read-only shadcn commands (info, docs, view,
      search, add --dry-run) on a local runner or a global shadcn: no shadcn@ at all (a
      versioned runner downloads), no dlx, no write command
    * SKILL.md's allowed-tools has no unversioned npx/bunx/npm exec shadcn (they fetch the
      newest release when no local copy exists) unless it says --no / --no-install
    * no fenced code block (``` or ~~~) in SKILL.md or references/ runs shadcn at anything
      but the pin (no @latest, no tag or range, no retired shadcn-ui, no unversioned
      pnpm/yarn dlx)
    * every prose token is still stated, its catalog value matching on digit boundaries
      (max_pin_age_days 6 is not "older than 60 days"); every CLI command and migration in
      the catalog is named in its reference; assets/mcp.json.example never runs an
      unpinned shadcn
  --live (scheduled freshness job, never a PR gate):
    * npm: the pin exists, is not deprecated, was published on cli.published and has no
      install lifecycle scripts; no newer major; the pin is not older than
      policy.max_pin_age_days while a newer release has passed the cooldown; the latest
      release has not gained install scripts
    * npm: each ecosystem package's latest major still equals the recorded one
    * the shadcn on PATH (or --shadcn-bin), when it is the pinned version: --help commands,
      `migrate --list` and init's --base/--template values equal the catalog. A different
      version there reports "unavailable" for those rows (install the pin to compare).

Sources: https://registry.npmjs.org/shadcn (full document, for dist-tags and times),
https://registry.npmjs.org/<package>/latest, and the CLI's own --help output.

Usage:   check-shadcn-facts.py [--offline | --live] [--catalog FILE] [--skill DIR]
                               [--fixtures DIR] [--shadcn-bin PATH] [--today YYYY-MM-DD]
                               [--json] [--timeout S] [-q]
Input:   argv flags only. --fixtures (live only) reads npm-shadcn.json,
         npm-latest-<name>.json (scope "@" dropped, "/" as "__"), version.txt, help.txt,
         init-help.txt and migrate-list.txt from DIR instead of the network and the CLI.
Output:  stdout = findings (check<TAB>status<TAB>detail rows, or the --json envelope,
         schema claude-mods.shadcn-ops.facts/v1). Data only. Exits 3 and 4 print the
         {error:{code,message}} envelope under --json.
Stderr:  the verdict line, errors.
Exit:    0 ok, 2 usage, 3 catalog/skill missing, 4 catalog unparseable or missing a key,
         7 a source was unreachable (live, advisory - never a real failure), 10 drift

Examples:
  check-shadcn-facts.py --offline                       # PR CI: catalog <-> prose <-> allowed-tools
  check-shadcn-facts.py --live                          # weekly: npm and the pinned CLI's --help
  check-shadcn-facts.py --live --shadcn-bin "$(command -v shadcn)" --json | jq '.data[]'
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

EX_OK, EX_USAGE, EX_NOTFOUND, EX_UNPARSEABLE, EX_UNAVAILABLE, EX_DRIFT = 0, 2, 3, 4, 7, 10
SCHEMA = "claude-mods.shadcn-ops.facts/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "assets" / "shadcn-facts.json"
DEFAULT_SKILL = HERE.parent
REGISTRY = "https://registry.npmjs.org"
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
EXACT_RE = re.compile(r"^\d+\.\d+\.\d+$")
NOTE_RE = re.compile(r"Versions verified (\d{4}-\d{2}-\d{2})")
# shadcn@<spec> and the retired shadcn-ui@<spec>; the spec stops at Markdown punctuation and
# TRAILING is stripped, so "shadcn@4.23.0." reads as the pin.
SPEC_RE = re.compile(r"(?<![\w/@.-])(shadcn(?:-ui)?)@([^\s\"'`),;*\]]+)")
TRAILING = ".,:;*])"
DLX_RE = re.compile(r"\b(?:pnpm\s+dlx|pnpx|pnx|yarn\s+dlx)\s+(?:-{1,2}\S+\s+)*shadcn(?:-ui)?(?![@\w-])")
# Runners that use a local copy when there is one and fetch the newest release when not.
LOCAL_FIRST_RE = re.compile(r"\b(?:npx|bunx|bun\s+x|npm\s+exec)\s+((?:-{1,2}\S+\s+)*)shadcn(?:-ui)?(?![@\w-])")
NO_FETCH_RE = re.compile(r"(?:^|\s)--no(?:-install)?(?=\s|$)")
FENCE_RE = re.compile(r"\s*(`{3,}|~{3,})(.*)$")
# The only shadcn grants allowed-tools may carry: a runner that never downloads, then a
# read-only verb. Writes (add, init, apply, migrate, eject) and downloads must prompt; hard
# rules 3, 5 and 6 rely on that prompt, so a wider grant is drift.
GRANT_RE = re.compile(r"Bash\(([^)]*)\)")
READONLY_GRANT_RE = re.compile(
    r"^(?:pnpm exec shadcn|npx --no shadcn|yarn run shadcn|bunx --no-install shadcn|shadcn)"
    r" (?:info|docs|view|search|add --dry-run) \*$")
LIFECYCLE = ("preinstall", "install", "postinstall")


class Unavailable(Exception):
    pass


class Drift(Exception):
    pass


class Fatal(Exception):
    """A catalog or skill problem that stops the run: (protocol code, exit code, message)."""

    def __init__(self, code: str, rc: int, msg: str):
        super().__init__(msg)
        self.code, self.rc = code, rc


# === Catalog ===

def lookup(cat: dict, dotted: str):
    node = cat
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(dotted)
        node = node[part]
    return node


def load_catalog(path: Path) -> dict:
    """The parsed catalog; raises Fatal (3 missing, 4 unparseable or missing a key) - every
    key the checks read is validated here, so a bad catalog is never a traceback (exit 1)."""
    if not path.is_file():
        raise Fatal("NOT_FOUND", EX_NOTFOUND, f"facts catalog not found: {path}")
    try:
        cat = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(cat, dict) or cat.get("schema") != SCHEMA:
            raise ValueError(f"schema must be {SCHEMA!r}")
        for dotted in ("as_of", "cli.published"):
            if not ISO_RE.match(str(lookup(cat, dotted))):
                raise ValueError(f"{dotted} must be YYYY-MM-DD")
        if not EXACT_RE.match(str(lookup(cat, "cli.version"))):
            raise ValueError("cli.version must be an exact x.y.z (never a tag or range)")
        if not str(lookup(cat, "cli.major")).isdigit():
            raise ValueError("cli.major must be a major number")
        if not isinstance(lookup(cat, "cli.install_scripts"), bool):
            raise ValueError("cli.install_scripts must be true or false")
        for dotted in ("policy.cooldown_days", "policy.max_pin_age_days"):
            if not isinstance(lookup(cat, dotted), int) or lookup(cat, dotted) < 1:
                raise ValueError(f"{dotted} must be a positive integer")
        for key in ("commands", "migrations", "templates", "style_names", "legacy_styles", "dist_tags"):
            v = cat.get(key)
            if not isinstance(v, list) or not v or not all(isinstance(x, str) and x for x in v):
                raise ValueError(f"{key} must be a non-empty list of names")
        for key in ("bases", "ecosystem"):
            if not isinstance(cat.get(key), dict) or not cat[key]:
                raise ValueError(f"{key} must be a non-empty object")
        if not all(str(v).isdigit() for v in cat["ecosystem"].values()):
            raise ValueError("ecosystem values must be major numbers")
        if cat.get("default_base") not in cat["bases"]:
            raise ValueError("default_base must be one of bases")
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
        raise Fatal("VALIDATION", EX_UNPARSEABLE, f"could not parse catalog {path}: missing {exc}")
    except (json.JSONDecodeError, TypeError, ValueError, AttributeError) as exc:
        raise Fatal("VALIDATION", EX_UNPARSEABLE, f"could not parse catalog {path}: {exc}")


def row(check: str, status: str, detail: str) -> dict:
    return {"check": check, "status": status, "detail": detail}


def days(a: str, b: str) -> int:
    return (dt.date.fromisoformat(b) - dt.date.fromisoformat(a)).days


# === Offline ===

def fenced_lines(text: str):
    """Lines inside fenced code blocks: ``` or ~~~ fences (CommonMark), each closed only by
    a bare run of the same character at least as long as the opener."""
    fence = None
    for no, line in enumerate(text.splitlines(), 1):
        m = FENCE_RE.match(line)
        if m:
            run = m.group(1)
            if fence is None:
                fence = (run[0], len(run))
                continue
            if run[0] == fence[0] and len(run) >= fence[1] and not m.group(2).strip():
                fence = None
                continue
        if fence:
            yield no, line


def off_pin(text: str, pin: str) -> list[str]:
    """Every shadcn@<spec> in text that is not the pin, and every shadcn-ui@ (retired)."""
    bad = []
    for pkg, spec in SPEC_RE.findall(text):
        spec = spec.rstrip(TRAILING)
        if pkg == "shadcn-ui" or spec != pin:
            bad.append(f"{pkg}@{spec}")
    return bad


def stated(value: str, token: str) -> bool:
    """value appears in token on digit boundaries: 6 is not in "60 days", 4.23 not in 4.23.0."""
    return re.search(rf"(?<!\d)(?<!\d\.){re.escape(value)}(?!\.?\d)", token) is not None


def check_offline(cat: dict, skill_dir: Path) -> list[dict]:
    doc = skill_dir / "SKILL.md"
    if not doc.is_file():
        raise Fatal("NOT_FOUND", EX_NOTFOUND, f"SKILL.md not found under {skill_dir}")
    skill_md = doc.read_text(encoding="utf-8", errors="replace")
    refs = {p.name: p.read_text(encoding="utf-8", errors="replace") for p in sorted((skill_dir / "references").glob("*.md"))}
    corpus = "\n".join([skill_md, *refs.values()])
    pin, out = cat["cli"]["version"], []

    out.append(row("pin-major", "ok" if pin.split(".")[0] == str(cat["cli"]["major"]) else "drift",
                   f"cli.version {pin} vs cli.major {cat['cli']['major']}"))
    age = days(cat["cli"]["published"], cat["as_of"])
    out.append(row("pin-cooled", "ok" if age >= cat["policy"]["cooldown_days"] else "drift",
                   f"{pin} was {age} day(s) old on {cat['as_of']} (cooldown {cat['policy']['cooldown_days']})"))

    m = NOTE_RE.search(skill_md)
    out.append(row("currency-note", "ok" if m and m.group(1) == cat["as_of"] else "drift",
                   f"SKILL.md says verified {m.group(1)}, catalog as_of {cat['as_of']}" if m
                   else "SKILL.md has no 'Versions verified YYYY-MM-DD' note"))

    fm = re.match(r"^---\n(.*?)\n---", skill_md.replace("\r\n", "\n"), re.S)
    at = re.search(r"^allowed-tools:\s*(.+)$", fm.group(1), re.M) if fm else None
    if not at:
        out.append(row("allowed-tools", "drift", "SKILL.md frontmatter has no allowed-tools line"))
    else:
        specs = [f"{p}@{s.rstrip(TRAILING)}" for p, s in SPEC_RE.findall(at.group(1))]
        fetching = [m.group(0) for m in LOCAL_FIRST_RE.finditer(at.group(1)) if not NO_FETCH_RE.search(m.group(1))]
        grants = [g.strip() for g in GRANT_RE.findall(at.group(1))
                  if "shadcn" in g and not g.strip().startswith("bash ")]
        wide = [g for g in grants if not READONLY_GRANT_RE.match(g)]
        if "@latest" in at.group(1) or specs or DLX_RE.search(at.group(1)) or fetching:
            out.append(row("allowed-tools", "drift", f"allowed-tools pre-approves a shadcn download: "
                                                     f"{specs or fetching or '@latest/dlx'}"))
        elif wide:
            out.append(row("allowed-tools", "drift", f"allowed-tools pre-approves a shadcn write or unknown form: {wide}"))
        elif not grants:
            out.append(row("allowed-tools", "drift", "allowed-tools grants no read-only shadcn command"))
        else:
            out.append(row("allowed-tools", "ok", f"{len(grants)} read-only grant(s), no download"))

    stray = []
    for name, text in [("SKILL.md", skill_md), *refs.items()]:
        for no, line in fenced_lines(text):
            if off_pin(line, pin) or DLX_RE.search(line):
                stray.append(f"{name}:{no}")
    out.append(row("code-blocks", "drift" if stray else "ok",
                   f"unpinned shadcn in code blocks: {', '.join(stray)}" if stray else "every fenced shadcn run is the pin or a local runner"))

    for t in cat["prose_tokens"]:
        value = str(lookup(cat, t["value_of"]))
        if not stated(value, t["token"]):
            out.append(row(f"token:{t['key']}", "drift", f"token {t['token']!r} no longer contains {t['value_of']} = {value!r}"))
        elif t["token"] not in corpus:
            out.append(row(f"token:{t['key']}", "drift", f"{t['token']!r} no longer stated in the skill prose"))
        else:
            out.append(row(f"token:{t['key']}", "ok", f"{t['token']!r} stated"))

    cli_ref = refs.get("cli-and-pinning.md", "")
    missing = [c for c in cat["commands"] if f"`{c}" not in cli_ref]
    out.append(row("commands-documented", "drift" if missing else "ok",
                   f"cli-and-pinning.md does not name: {missing}" if missing else f"{len(cat['commands'])} commands named"))
    mig_ref = refs.get("migrations-and-eject.md", "")
    missing = [m_ for m_ in cat["migrations"] if f"migrate {m_}" not in mig_ref]
    out.append(row("migrations-documented", "drift" if missing else "ok",
                   f"migrations-and-eject.md does not show: {missing}" if missing else f"{len(cat['migrations'])} migrations shown"))

    ex = skill_dir / "assets" / "mcp.json.example"
    try:
        servers = json.loads(ex.read_text(encoding="utf-8")).get("mcpServers", {})
        cmdlines = [" ".join([s.get("command", "")] + list(s.get("args", []))) for s in servers.values()]
        bad = [c for c in cmdlines if "@latest" in c or off_pin(c, pin) or DLX_RE.search(c)]
        out.append(row("mcp-example", "drift" if bad or not cmdlines else "ok",
                       f"unpinned: {bad}" if bad else ("no servers" if not cmdlines else f"{len(cmdlines)} pinned server(s)")))
    except (OSError, json.JSONDecodeError, AttributeError, TypeError) as exc:
        out.append(row("mcp-example", "drift", f"assets/mcp.json.example unreadable: {exc}"))
    return out


# === Live sources ===

class Sources:
    """Network/CLI or fixture-directory reads. Raises Unavailable on any failure."""

    def __init__(self, fixtures: Path | None, timeout: float, shadcn_bin: str | None):
        self.fixtures, self.timeout, self.bin = fixtures, timeout, shadcn_bin

    def _fixture(self, name: str) -> str:
        path = self.fixtures / name
        if not path.is_file():
            raise Unavailable(f"fixture {name} missing")
        return path.read_text(encoding="utf-8")

    def npm(self, name: str, latest: bool):
        fixture = f"npm-latest-{name.replace('@', '').replace('/', '__')}.json" if latest else f"npm-{name}.json"
        if self.fixtures is not None:
            raw = self._fixture(fixture)
        else:
            url = f"{REGISTRY}/{name.replace('/', '%2F')}" + ("/latest" if latest else "")
            req = urllib.request.Request(url, headers={"User-Agent": "claude-mods-shadcn-ops-check/1",
                                                       "Accept": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read().decode("utf-8", errors="replace")
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    raise Drift(f"{name} not found on npm (404)")
                raise Unavailable(f"{url}: HTTP {exc.code}")
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                raise Unavailable(f"{url}: {exc}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise Unavailable(f"{fixture}: not JSON")

    def cli(self, fixture: str, args: list[str]) -> str:
        if self.fixtures is not None:
            return self._fixture(fixture)
        if not self.bin:
            raise Unavailable("no shadcn on PATH (install the pin, or pass --shadcn-bin)")
        with tempfile.TemporaryDirectory() as cwd:  # an empty cwd: nothing for the CLI to read or touch
            try:
                proc = subprocess.run([self.bin, *args], cwd=cwd, capture_output=True, text=True,
                                      timeout=self.timeout * 3)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise Unavailable(f"shadcn {' '.join(args)}: {exc}")
        if proc.returncode != 0:
            raise Unavailable(f"shadcn {' '.join(args)} exited {proc.returncode}")
        return proc.stdout


def major(v) -> int:
    m = re.match(r"\s*(\d+)", str(v))
    return int(m.group(1)) if m else -1


def help_commands(text: str) -> set[str]:
    m = re.search(r"^Commands:\s*$(.*?)(?=^\S|\Z)", text, re.M | re.S)
    names = set()
    for line in (m.group(1) if m else "").splitlines():
        tok = line.strip().split(" ", 1)[0]
        if tok:
            names.add(tok.split("|", 1)[0])
    names.discard("help")
    return names


def check_live(cat: dict, src: Sources, today: dt.date) -> list[dict]:
    out: list[dict] = []
    pin, pol = cat["cli"]["version"], cat["policy"]
    today_s = today.isoformat()
    try:
        doc = src.npm("shadcn", latest=False)
        versions, times, tags = doc.get("versions") or {}, doc.get("time") or {}, doc.get("dist-tags") or {}
        latest = str(tags.get("latest", ""))
        if not latest or not isinstance(versions, dict):
            raise Unavailable("npm document has no dist-tags.latest")
        man = versions.get(pin)
        if not isinstance(man, dict):
            out.append(row("npm:pin", "drift", f"shadcn {pin} is not on npm any more (unpublished?)"))
        else:
            if man.get("deprecated"):
                out.append(row("npm:pin", "drift", f"shadcn {pin} is deprecated: {man['deprecated']}"))
            else:
                out.append(row("npm:pin", "ok", f"shadcn {pin} published"))
            scripts = sorted(k for k in (man.get("scripts") or {}) if k in LIFECYCLE)
            want = cat["cli"]["install_scripts"]
            out.append(row("npm:pin-scripts", "ok" if bool(scripts) == want else "drift",
                           f"{pin} install scripts: {scripts or 'none'} (catalog install_scripts={want})"))
            published = str(times.get(pin, ""))[:10]
            out.append(row("npm:pin-published", "ok" if published == cat["cli"]["published"] else "drift",
                           f"npm says {pin} was published {published or '?'}, catalog {cat['cli']['published']}"))
        if major(latest) > major(pin):
            out.append(row("npm:major", "drift", f"shadcn {latest} is a new major past {pin}: re-read the changelog, "
                                                 "then bump the pin (references/cli-and-pinning.md#bumping-the-pin)"))
        else:
            out.append(row("npm:major", "ok", f"latest {latest}"))
        pin_t, lat_t = str(times.get(pin, ""))[:10], str(times.get(latest, ""))[:10]
        if ISO_RE.match(pin_t) and ISO_RE.match(lat_t) and latest != pin:
            stale = days(pin_t, today_s) > pol["max_pin_age_days"]
            cooled = days(lat_t, today_s) >= pol["cooldown_days"]
            if stale and cooled:
                out.append(row("npm:pin-age", "drift", f"pin {pin} is {days(pin_t, today_s)} days old and {latest} "
                                                       f"has passed the {pol['cooldown_days']}-day cooldown: bump the pin"))
            else:
                out.append(row("npm:pin-age", "ok", f"pin {days(pin_t, today_s)} days old; latest {latest} "
                                                    f"{'cooled' if cooled else 'still inside the cooldown'}"))
        else:
            out.append(row("npm:pin-age", "ok", "the pin is the latest release" if latest == pin else "publish times missing"))
        lman = versions.get(latest) if isinstance(versions.get(latest), dict) else {}
        lscripts = sorted(k for k in (lman.get("scripts") or {}) if k in LIFECYCLE)
        out.append(row("npm:latest-scripts", "drift" if lscripts else "ok",
                       f"shadcn {latest} gained install scripts {lscripts}: review before any bump" if lscripts
                       else f"{latest} has no install scripts"))
    except Unavailable as exc:
        out.append(row("npm:shadcn", "unavailable", str(exc)))
    except Drift as exc:
        out.append(row("npm:shadcn", "drift", str(exc)))

    for pkg, want in cat["ecosystem"].items():
        try:
            got = str(src.npm(pkg, latest=True).get("version", ""))
            ok = major(got) == int(want)
            out.append(row(f"npm:{pkg}", "ok" if ok else "drift",
                           f"latest {got}" + ("" if ok else f"; the skill documents major {want} - re-read its "
                                                             "references and the facts, then update both")))
        except Unavailable as exc:
            out.append(row(f"npm:{pkg}", "unavailable", str(exc)))
        except Drift as exc:
            out.append(row(f"npm:{pkg}", "drift", str(exc)))

    try:
        words = src.cli("version.txt", ["--version"]).split()
        ver = words[0] if words else "?"
        if ver != pin:
            raise Unavailable(f"the CLI available is {ver}, not the pin {pin}; install shadcn@{pin} to compare its help")
        got = help_commands(src.cli("help.txt", ["--help"]))
        want = set(cat["commands"])
        out.append(row("cli:commands", "ok" if got == want else "drift",
                       f"{len(got)} commands" if got == want else
                       f"--help added {sorted(got - want) or '-'}, removed {sorted(want - got) or '-'}"))
        mig = set(re.findall(r"^-\s*([\w-]+):", src.cli("migrate-list.txt", ["migrate", "--list"]), re.M))
        wantm = set(cat["migrations"])
        out.append(row("cli:migrations", "ok" if mig == wantm else "drift",
                       f"{len(mig)} migrations" if mig == wantm else
                       f"migrate --list added {sorted(mig - wantm) or '-'}, removed {sorted(wantm - mig) or '-'}"))
        init = " ".join(src.cli("init-help.txt", ["init", "--help"]).split())
        for label, rx, wantv in (("cli:bases", r"--base <base>\s+the component library to use\.\s*\(([^)]*)\)", set(cat["bases"])),
                                 ("cli:templates", r"--template <template>\s+the template to use\.\s*\(([^)]*)\)", set(cat["templates"]))):
            mm = re.search(rx, init)
            if not mm:
                out.append(row(label, "drift", "init --help no longer lists the values in the expected form; re-verify by hand"))
                continue
            gotv = {x.strip() for x in mm.group(1).split(",") if x.strip()}
            out.append(row(label, "ok" if gotv == wantv else "drift",
                           f"{sorted(gotv)}" if gotv == wantv else f"init --help says {sorted(gotv)}, catalog {sorted(wantv)}"))
    except Unavailable as exc:
        out.append(row("cli:help", "unavailable", str(exc)))
    return out


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="check-shadcn-facts.py",
        description="Verify shadcn-ops' pinned CLI and facts stay stated (offline) and true upstream (live).",
        epilog=("Examples:\n  check-shadcn-facts.py --offline\n  check-shadcn-facts.py --live\n"
                "  check-shadcn-facts.py --offline --json | jq '.data[] | select(.status != \"ok\")'\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="catalog <-> prose consistency, no network (default)")
    mode.add_argument("--live", action="store_true", help="compare the catalog with npm and the pinned CLI")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog JSON")
    p.add_argument("--skill", default=str(DEFAULT_SKILL), help="skill directory (SKILL.md + references/ + assets/)")
    p.add_argument("--fixtures", help="live mode: read sources from this directory instead of npm and the CLI")
    p.add_argument("--shadcn-bin", help="live mode: the shadcn executable to ask for --help (default: shadcn on PATH)")
    p.add_argument("--today", help="live mode: date for the age checks (YYYY-MM-DD, default today UTC)")
    p.add_argument("--timeout", type=float, default=20.0, help="per-request timeout seconds (live)")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    if (args.fixtures or args.today or args.shadcn_bin) and not args.live:
        print("error: --fixtures, --today and --shadcn-bin apply to --live only", file=sys.stderr)
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

    try:
        cat = load_catalog(Path(args.catalog))
        if args.live:
            findings = check_live(cat, Sources(fixtures, args.timeout, args.shadcn_bin or shutil.which("shadcn")), today)
        else:
            findings = check_offline(cat, Path(args.skill))
    except Fatal as exc:
        if args.json:
            print(json.dumps({"error": {"code": exc.code, "message": str(exc)}}))
        print(f"error: {exc}", file=sys.stderr)
        return exc.rc
    drift = [f for f in findings if f["status"] == "drift"]
    unavailable = [f for f in findings if f["status"] == "unavailable"]
    if args.json:
        print(json.dumps({"data": findings, "meta": {"count": len(findings), "mode": "live" if args.live else "offline",
                                                     "as_of": cat["as_of"], "pin": cat["cli"]["version"],
                                                     "schema": SCHEMA}}, indent=2))
    else:
        for f in findings:
            print(f"{f['check']}\t{f['status']}\t{f['detail']}")
    if not args.quiet:
        verdict = "DRIFT" if drift else "UNAVAILABLE" if unavailable else "OK"
        print(f"check-shadcn-facts: {verdict} ({len(findings)} checks, {len(drift)} drift, "
              f"{len(unavailable)} unavailable)", file=sys.stderr)
    if drift:
        return EX_DRIFT
    return EX_UNAVAILABLE if unavailable else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
