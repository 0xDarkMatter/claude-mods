#!/usr/bin/env python3
"""Read-only package-manager audit of one repo root: lockfiles, Node/PHP pins, npx use, legacy tools.

Usage:   pm-audit.py [--json] [--no-docs] [--as-of YYYY-MM-DD] [--facts FILE] [--limit N] PATH
Input:   argv only. PATH is a repo root. Root manifests only: workspaces and nested
         packages are not walked (doc/script files ARE walked for npx use).
Output:  stdout = one TSV row per finding: severity, id, file[:line], message, fix.
         --json: {"data": [finding...], "meta": {...}} with schema
         claude-mods.package-manager-ops.pm-audit/v1. Data only.
Stderr:  header, notes (informational - never findings), verdict line, errors.
Exit:    0 clean, 2 usage, 3 PATH or facts missing, 4 facts unparseable,
         10 findings (data[] non-empty)

What it checks (finding ids - SKILL.md and references/diagnostics.md explain each):
  js.manifest.invalid  php.manifest.invalid
  js.lockfile.conflict  js.lockfile.missing  js.lockfile.stale  js.lockfile.v1
  js.lockfile.shrinkwrap  js.pnpm.field-ignored
  js.packagemanager.mismatch  js.node.unpinned  js.node.eol  node.pin.disagree
  ddev.node.unpinned  ddev.php.unpinned  php.require.missing  php.platform.unset
  php.pin.disagree  php.eol  php.lockfile.missing  php.lockfile.stale
  npx.unpinned  npx.native-cli  legacy.bower  legacy.node-sass
  registry.token.committed  registry.authjson.committed

It never prints a secret: a committed token is reported as file:line only.

Why one file: the skill folder must run when copied alone into another plugin, launched
through scripts/run-python.sh with nothing on sys.path, so this stays a single stdlib
module. Jump by section marker instead of splitting it:
  === version ranges ===   npm semver + Composer constraint intervals (admits())
  === small readers ===    JSON/JSONC, a block-mapping YAML subset, markdown code lines
  === the audit ===        Audit: js, node_pins, php, npx, legacy, secrets
  main()                   argv, output envelope, exit codes

Examples:
  bash scripts/run-python.sh scripts/pm-audit.py .
  bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[].id'
  bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2026-10-05 path/to/repo
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

EX_OK, EX_USAGE, EX_NOTFOUND, EX_UNPARSEABLE, EX_FINDINGS = 0, 2, 3, 4, 10
SCHEMA = "claude-mods.package-manager-ops.pm-audit/v1"
FACTS_SCHEMA = "claude-mods.package-manager-ops.facts/v1"
DEFAULT_FACTS = Path(__file__).resolve().parent.parent / "assets" / "package-manager-facts.json"

# Lockfile -> manager. Two of these at one root is always a conflict: each manager
# resolves from its own file and ignores the others, so they drift apart silently.
JS_LOCKFILES = {
    "package-lock.json": "npm",
    "npm-shrinkwrap.json": "npm",
    "yarn.lock": "yarn",
    "pnpm-lock.yaml": "pnpm",
    "bun.lock": "bun",
    "bun.lockb": "bun",
    "deno.lock": "deno",
}
DEP_TYPES = ("dependencies", "devDependencies", "optionalDependencies")
# Specs that never appear verbatim as yarn/pnpm lock keys; skip rather than guess.
LOCAL_SPEC = re.compile(r"^(workspace:|file:|link:|portal:|patch:|exec:|git[+:]|github:|https?:)")
COMPOSER_PLATFORM = re.compile(r"^(php(-64bit|-ipv6|-zts|-debug)?|hhvm|ext-.+|lib-.+|composer(-plugin-api|-runtime-api)?)$", re.I)
EXACT_SEMVER = re.compile(r"^v?\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$")
# Directories never worth walking for npx usage: dependencies, build output, VCS.
SKIP_DIRS = {".git", "node_modules", "vendor", "bower_components", ".yarn", ".pnpm-store",
             "dist", "build", "coverage", ".cache", ".next", ".nuxt", "storage", "cpresources",
             "db_snapshots", ".idea", ".vscode"}
DOC_SUFFIXES = {".md", ".markdown", ".sh", ".bash", ".ps1", ".yml", ".yaml", ".mk"}
DOC_NAMES = {"makefile", "justfile", "dockerfile", "procfile"}
MAX_DOC_BYTES = 512 * 1024
# npx-family launchers. Group 1 = launcher, group 2 = the rest of the command line.
# In markdown only code (fenced blocks, inline `spans`) is scanned, so prose such as
# "npx is handy" is never read as a command.
LAUNCHER = re.compile(r"(?:^|[\s;&|(`'\"$])(npx|pnpx|pnx|bunx|bun\s+x|pnpm\s+dlx|yarn\s+dlx|npm\s+exec)\s+([^\n;&|`]*)")
FLAG_WITH_VALUE = {"-p", "--package", "-c", "--call", "-w", "--workspace", "--cache", "--userconfig"}


# =============================================================================
# === version ranges (npm semver + Composer constraints) ===
# Just enough to answer "does this range admit some version inside [lo, hi)?".
# Versions are (major, minor, patch) tuples; every comparator becomes a half-open
# interval [lo, hi). Unknown syntax returns None so callers skip rather than accuse.
# npm grammar: https://github.com/npm/node-semver#ranges
# Composer grammar: https://getcomposer.org/doc/articles/versions.md
# The one dialect difference that matters: Composer ~1.2 means >=1.2 <2.0, npm ~1.2
# means >=1.2.0 <1.3.0.
# =============================================================================
INF = (10**9, 0, 0)
PARTIAL = re.compile(r"^v?(\d+|[xX*])(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?(?:[-+][0-9A-Za-z.+-]*)?$")


def _partial(s: str):
    """'8.2' -> ([8, 2], 2 given parts); wildcard parts end the partial."""
    m = PARTIAL.match(s.strip())
    if not m:
        return None
    parts = []
    for g in m.groups():
        if g is None or g in ("x", "X", "*"):
            break
        parts.append(int(g))
    return parts


def _floor(parts):
    return tuple(parts + [0] * (3 - len(parts)))


def _bump(parts):
    """Smallest version above every version matching the partial: 8 -> 9.0.0, 8.2 -> 8.3.0."""
    if not parts:
        return INF
    p = list(parts)
    p[-1] += 1
    return _floor(p)


def _comparator(tok: str, dialect: str):
    m = re.match(r"^(>=|<=|>|<|==|=|\^|~>|~|!=)?\s*(.+)$", tok)
    if not m:
        return None
    op, ver = m.group(1) or "", m.group(2)
    ver = ver.split("@")[0]  # Composer stability flag: ^8.2@dev
    parts = _partial(ver)
    if parts is None:
        return None
    if op == "!=":
        return ((0, 0, 0), INF)
    full = len(parts) == 3
    if op in ("", "=", "=="):
        return (_floor(parts), _bump(parts) if not full else (parts[0], parts[1], parts[2] + 1)) if parts else ((0, 0, 0), INF)
    if op == ">=":
        return (_floor(parts), INF)
    if op == ">":
        return (_bump(parts) if not full else (parts[0], parts[1], parts[2] + 1), INF)
    if op == "<":
        return ((0, 0, 0), _floor(parts))
    if op == "<=":
        return ((0, 0, 0), _bump(parts) if not full else (parts[0], parts[1], parts[2] + 1))
    if op == "^":
        if not parts:
            return ((0, 0, 0), INF)
        lo = _floor(parts)
        nz = next((i for i, v in enumerate(parts) if v != 0), None)
        if nz is None:  # ^0, ^0.0, ^0.0.0
            return (lo, _bump(parts))
        return (lo, _bump(parts[: nz + 1]))
    if op in ("~", "~>"):
        if not parts:
            return ((0, 0, 0), INF)
        lo = _floor(parts)
        if dialect == "composer" and len(parts) == 2:
            return (lo, _bump(parts[:1]))  # ~8.2 -> <9.0.0
        return (lo, _bump(parts[:2]) if len(parts) >= 2 else _bump(parts[:1]))
    return None


def parse_range(spec: str, dialect: str = "npm"):
    """Range string -> list of AND-sets, each a list of (lo, hi) intervals. None if unparseable."""
    if spec is None:
        return None
    spec = str(spec).strip()
    if spec in ("", "*", "x", "latest"):
        return [[((0, 0, 0), INF)]]
    alts = re.split(r"\s*\|\|?\s*", spec) if dialect == "composer" else re.split(r"\s*\|\|\s*", spec)
    out = []
    for alt in alts:
        alt = alt.strip()
        hyph = re.match(r"^(\S+)\s+-\s+(\S+)$", alt)
        if hyph:
            a, b = _partial(hyph.group(1)), _partial(hyph.group(2))
            if a is None or b is None:
                return None
            hi = (b[0], b[1], b[2] + 1) if len(b) == 3 else _bump(b)
            out.append([(_floor(a), hi)])
            continue
        alt = re.sub(r"(>=|<=|>|<|==|=|\^|~>|~|!=)\s+", r"\1", alt)  # ">= 8.2" -> ">=8.2"
        toks = [t for t in re.split(r"[\s,]+", alt) if t]
        if not toks:
            out.append([((0, 0, 0), INF)])
            continue
        ivs = []
        for t in toks:
            iv = _comparator(t, dialect)
            if iv is None:
                return None
            ivs.append(iv)
        out.append(ivs)
    return out


def admits(spec: str, lo, hi, dialect: str = "npm"):
    """True/False: does the range admit any version in [lo, hi)? None if unparseable."""
    sets = parse_range(spec, dialect)
    if sets is None:
        return None
    for ivs in sets:
        a = max([lo] + [iv[0] for iv in ivs])
        b = min([hi] + [iv[1] for iv in ivs])
        if a < b:
            return True
    return False


# =============================================================================
# === small readers ===
# =============================================================================
def read_text(p: Path) -> str | None:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def read_json(p: Path):
    t = read_text(p)
    if t is None:
        return None
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        return None


def read_jsonc(p: Path):
    """bun.lock is JSON with trailing commas."""
    t = read_text(p)
    if t is None:
        return None
    try:
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", t))
    except json.JSONDecodeError:
        return None


def mini_yaml(text: str) -> dict:
    """Block-mapping subset of YAML: nested `key: value` by indentation. Sequences and
    flow collections are kept as raw strings. Enough for pnpm-lock importers and
    .ddev/config.yaml scalars; not a general parser."""
    root: dict = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith(("#", "- ")) or raw.strip() == "-":
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        m = re.match(r"^\s*('[^']*'|\"[^\"]*\"|[^:#][^:]*?)\s*:(?:\s+(.*))?$", raw)
        if not m:
            continue
        key = m.group(1).strip().strip("'\"")
        val = (m.group(2) or "").strip()
        nested = val == "" or val.startswith("#")  # `key:` alone opens a block; `key: ""` is a value
        if val and not val.startswith(("{", "[")):
            val = re.sub(r"\s+#.*$", "", val).strip().strip("'\"")
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1] if stack else root
        if nested:
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = val
    return root


def code_lines(text: str, markdown: bool):
    """Yield (line_no, text) worth scanning: every line of a script, but only fenced
    code and inline code spans of a markdown file."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        if not markdown:
            yield n, line
            continue
        s = line.lstrip()
        if fence is None and s.startswith(("```", "~~~")):
            fence = s[:3]
            continue
        if fence is not None:
            if s.startswith(fence):
                fence = None
            else:
                yield n, line
            continue
        spans = re.findall(r"`([^`]+)`", line)
        if spans:
            yield n, " ; ".join(spans)


def rel(root: Path, p: Path) -> str:
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return p.as_posix()


# =============================================================================
# === the audit ===
# =============================================================================
class Audit:
    def __init__(self, root: Path, facts: dict, as_of: dt.date, docs: bool, limit: int):
        self.root, self.facts, self.as_of, self.docs, self.limit = root, facts, as_of, docs, limit
        self.findings: list[dict] = []
        self.notes: list[dict] = []
        self.meta: dict = {"managers": [], "lockfiles": [], "node_pins": {}, "php_pins": {}}
        self.pkg = read_json(root / "package.json") if (root / "package.json").is_file() else None
        self.composer = read_json(root / "composer.json") if (root / "composer.json").is_file() else None
        self.ddev = self._read_ddev()

    def add(self, sev, fid, file, msg, fix, line=None):
        self.findings.append({"id": fid, "severity": sev, "file": file, "line": line,
                              "message": msg, "fix": fix})

    def note(self, nid, file, msg):
        self.notes.append({"id": nid, "file": file, "message": msg})

    # ---- DDEV: config.yaml, then config.*.yaml in name order (later files win) ----
    def _read_ddev(self):
        d = self.root / ".ddev"
        base = d / "config.yaml"
        if not base.is_file():
            return None
        merged: dict = {}
        for f in [base] + sorted(p for p in d.glob("config.*.yaml") if p.name != "config.yaml"):
            merged.update(mini_yaml(read_text(f) or ""))
        return merged

    def run(self):
        self.js()
        self.node_pins()
        self.php()
        self.npx()
        self.legacy()
        self.secrets()
        return self

    # ---- JS managers and lockfiles ----
    def js(self):
        present = [n for n in JS_LOCKFILES if (self.root / n).is_file()]
        self.meta["lockfiles"] = present + (["composer.lock"] if (self.root / "composer.lock").is_file() else [])
        managers = sorted({JS_LOCKFILES[n] for n in present})
        if self.composer is not None:
            managers.append("composer")
        self.meta["managers"] = managers
        if self.pkg is None:
            if (self.root / "package.json").is_file():
                self.add("error", "js.manifest.invalid", "package.json", "package.json is not valid JSON",
                         "fix the JSON before any install")
            return
        if len(present) > 1:
            self.add("error", "js.lockfile.conflict", ", ".join(present),
                     f"{len(present)} JS lockfiles at the root ({', '.join(present)}); each manager reads only its own",
                     "pick one manager, delete the other lockfile(s), reinstall with that manager, commit")
        if "npm-shrinkwrap.json" in present and "package-lock.json" not in present:
            self.add("warn", "js.lockfile.shrinkwrap", "npm-shrinkwrap.json",
                     "npm 12 no longer reads npm-shrinkwrap.json, so `npm ci` finds no lockfile",
                     "rename it to package-lock.json (applications) and commit")
        uses_pnpm = "pnpm-lock.yaml" in present or str(self.pkg.get("packageManager", "")).startswith("pnpm@")
        if uses_pnpm and isinstance(self.pkg.get("pnpm"), dict) and self.pkg["pnpm"]:
            self.add("warn", "js.pnpm.field-ignored", "package.json",
                     "package.json has a `pnpm` field (" + ", ".join(sorted(self.pkg["pnpm"])[:5])
                     + ") - pnpm 11+ no longer reads it, so those settings are silently dropped",
                     "move the settings into pnpm-workspace.yaml (references/scripts-and-workspaces.md)")
        has_deps = any(self.pkg.get(t) for t in DEP_TYPES)
        if not present and has_deps:
            self.add("warn", "js.lockfile.missing", "package.json",
                     "dependencies declared but no lockfile committed - every install resolves fresh",
                     "run the chosen manager's install once and commit its lockfile")
        pm = str(self.pkg.get("packageManager") or "")
        pm_name, _, pm_ver = pm.partition("@")
        if not pm:
            self.note("js.packagemanager.unset", "package.json",
                      "no packageManager field - nothing declares which manager (and version) this repo expects")
        elif present:
            owned = [n for n in present if JS_LOCKFILES[n] == pm_name]
            if not owned:
                self.add("error", "js.packagemanager.mismatch", "package.json",
                         f"packageManager says {pm} but the lockfile is {', '.join(present)}",
                         "make packageManager name the manager whose lockfile you keep")
        yarn_lock = self.root / "yarn.lock"
        flavour = None
        if yarn_lock.is_file():
            head = (read_text(yarn_lock) or "")[:2000]
            flavour = "berry" if "__metadata:" in head else "classic"
            if flavour == "classic":
                self.note("js.yarn.classic", "yarn.lock",
                          "Yarn 1 (classic) lockfile - Yarn 1 takes security fixes only; plan a move to npm or Yarn 4 (references/legacy-exits.md)")
            ym = re.match(r"\d+", pm_ver) if pm_name == "yarn" else None
            if ym:
                major = int(ym.group(0))
                if (major >= 2) != (flavour == "berry"):
                    self.add("error", "js.packagemanager.mismatch", "package.json",
                             f"packageManager pins yarn@{pm_ver} but yarn.lock is in Yarn {'1' if flavour == 'classic' else '2+'} format",
                             "install once with the pinned Yarn to convert the lockfile, or fix the pin")
        for n in present:
            self._lock_consistency(n, flavour)

    def _declared(self):
        out = {}
        if not self.pkg:
            return out
        for t in DEP_TYPES:
            for name, spec in (self.pkg.get(t) or {}).items():
                out[name] = (t, str(spec))
        return out

    def _lock_consistency(self, name: str, flavour):
        declared = self._declared()
        p = self.root / name
        missing, changed, extra = [], [], []
        if name in ("package-lock.json", "npm-shrinkwrap.json"):
            lock = read_json(p)
            if not isinstance(lock, dict):
                self.add("error", "js.lockfile.stale", name, "lockfile is not valid JSON", "regenerate it")
                return
            ver = lock.get("lockfileVersion", 1)
            if ver == 1:
                self.add("warn", "js.lockfile.v1", name,
                         "lockfileVersion 1 (written by npm 6 or older) - the toolchain that maintains this repo predates npm 7",
                         "install with a current npm and commit the upgraded lockfile (references/legacy-exits.md)")
                names = set((lock.get("dependencies") or {}).keys())
                missing = [n for n in declared if n not in names]
            else:
                rootpkg = (lock.get("packages") or {}).get("")
                if not isinstance(rootpkg, dict):
                    return
                locked = {}
                for t in DEP_TYPES:
                    for n, s in (rootpkg.get(t) or {}).items():
                        locked[n] = str(s)
                missing = [n for n in declared if n not in locked]
                changed = [n for n in declared if n in locked and locked[n] != declared[n][1]]
                extra = [n for n in locked if n not in declared]
        elif name == "yarn.lock":
            keys = set()
            for line in (read_text(p) or "").splitlines():
                if line and not line[0].isspace() and not line.startswith("#") and line.rstrip().endswith(":"):
                    for k in line.rstrip()[:-1].split(","):
                        keys.add(k.strip().strip('"'))
            for n, (_, spec) in declared.items():
                if LOCAL_SPEC.match(spec):
                    continue
                if f"{n}@{spec}" not in keys and f"{n}@npm:{spec}" not in keys:
                    missing.append(n)
        elif name == "pnpm-lock.yaml":
            doc = mini_yaml(read_text(p) or "")
            imp = (doc.get("importers") or {}).get(".") if isinstance(doc.get("importers"), dict) else doc
            if not isinstance(imp, dict):
                return
            locked = {}
            for t in DEP_TYPES:
                for n, v in (imp.get(t) or {}).items() if isinstance(imp.get(t), dict) else []:
                    locked[n] = v.get("specifier") if isinstance(v, dict) else None
            missing = [n for n in declared if n not in locked]
            changed = [n for n in declared if locked.get(n) not in (None, declared[n][1]) and n in locked]
            extra = [n for n in locked if n not in declared]
        elif name == "bun.lock":
            lock = read_jsonc(p)
            ws = ((lock or {}).get("workspaces") or {}).get("")
            if not isinstance(ws, dict):
                return
            locked = {}
            for t in DEP_TYPES:
                for n, s in (ws.get(t) or {}).items():
                    locked[n] = str(s)
            missing = [n for n in declared if n not in locked]
            changed = [n for n in declared if n in locked and locked[n] != declared[n][1]]
            extra = [n for n in locked if n not in declared]
        elif name == "bun.lockb":
            self.note("js.lockfile.binary", name, "binary bun.lockb cannot be checked; Bun now writes a text bun.lock")
            return
        else:
            return
        if missing or changed or extra:
            parts = []
            if missing:
                parts.append("not in lockfile: " + ", ".join(sorted(missing)[:8]))
            if changed:
                parts.append("range changed: " + ", ".join(sorted(changed)[:8]))
            if extra:
                parts.append("in lockfile but not package.json: " + ", ".join(sorted(extra)[:8]))
            self.add("warn", "js.lockfile.stale", name,
                     f"{name} disagrees with package.json ({'; '.join(parts)}) - a frozen install will fail",
                     "run a normal install with the repo's manager on a dev machine, review the lock diff, commit")

    # ---- Node version pins ----
    def node_pins(self):
        if self.pkg is None:
            return
        node = self.facts.get("node", {})
        codenames = {k.lower(): v for k, v in (node.get("lts_codenames") or {}).items()}
        exact: dict[str, int] = {}
        ranges: dict[str, str] = {}

        def exact_from(src: str, raw: str):
            v = raw.strip().splitlines()[0].strip() if raw.strip() else ""
            low = v.lower()
            if low.startswith("lts/"):
                cn = low[4:]
                if cn in codenames:
                    exact[src] = int(codenames[cn])
                else:
                    self.note("js.node.floating", src, f"'{v}' floats to whatever LTS is newest - not a pin")
                return
            if src.startswith(".ddev") and low in ("auto", "engine"):
                return  # DDEV reads .node-version/.nvmrc/engines itself: agrees by construction
            if low in ("node", "stable", "latest", "current", "lts", "auto", "system"):
                self.note("js.node.floating", src, f"'{v}' is an alias, not a version pin")
                return
            m = re.match(r"^v?(\d+)", v)
            if m:
                exact[src] = int(m.group(1))

        for f in (".nvmrc", ".node-version"):
            t = read_text(self.root / f) if (self.root / f).is_file() else None
            if t is not None:
                exact_from(f, t)
        tv = read_text(self.root / ".tool-versions") if (self.root / ".tool-versions").is_file() else None
        if tv:
            m = re.search(r"^\s*nodejs\s+(\S+)", tv, re.M)
            if m:
                exact_from(".tool-versions", m.group(1))
        for f in ("mise.toml", ".mise.toml"):
            mt = read_text(self.root / f) if (self.root / f).is_file() else None
            if mt:
                m = re.search(r"^\s*node\s*=\s*[\"']([^\"']+)[\"']", mt, re.M)
                if m:
                    exact_from(f, m.group(1))
        volta = self.pkg.get("volta")
        if isinstance(volta, dict) and volta.get("node"):
            exact_from("package.json volta.node", str(volta["node"]))
        eng = (self.pkg.get("engines") or {}).get("node") if isinstance(self.pkg.get("engines"), dict) else None
        if eng:
            ranges["package.json engines.node"] = str(eng)
        dev = self.pkg.get("devEngines")
        rt = dev.get("runtime") if isinstance(dev, dict) else None
        for r in (rt if isinstance(rt, list) else [rt] if isinstance(rt, dict) else []):
            if isinstance(r, dict) and str(r.get("name", "")).lower() == "node" and r.get("version"):
                ranges["package.json devEngines.runtime"] = str(r["version"])
        if self.ddev is not None:
            nv = self.ddev.get("nodejs_version")
            if isinstance(nv, str) and nv:
                exact_from(".ddev/config.yaml nodejs_version", nv)
            else:
                self.add("warn", "ddev.node.unpinned", ".ddev/config.yaml",
                         "no nodejs_version - the container runs DDEV's default Node, which moves with DDEV upgrades",
                         "set nodejs_version to the same major as .nvmrc (references/version-pinning.md)")
        self.meta["node_pins"] = {**{k: str(v) for k, v in exact.items()}, **ranges}

        if not exact and not ranges:
            self.add("warn", "js.node.unpinned", "package.json",
                     "no Node version pin (.nvmrc, .node-version, engines.node, devEngines, volta, .tool-versions)",
                     "add .nvmrc with the production major and engines.node to match")
            return
        if eng and not re.search(r"^\s*engine-strict\s*=\s*true\b", read_text(self.root / ".npmrc") or "", re.M):
            self.note("js.engines.unenforced", "package.json",
                      "engines.node is advisory to npm unless .npmrc sets engine-strict=true")

        problems = []
        majors = sorted(set(exact.values()))
        if len(majors) > 1:
            problems.append("exact pins differ: " + ", ".join(f"{k}={v}" for k, v in exact.items()))
        for src, spec in ranges.items():
            for esrc, major in exact.items():
                ok = admits(spec, (major, 0, 0), (major + 1, 0, 0))
                if ok is False:
                    problems.append(f"{src} '{spec}' excludes {esrc}={major}")
        if not exact and len(ranges) > 1:
            specs = list(ranges.items())
            for i in range(len(specs)):
                for j in range(i + 1, len(specs)):
                    joint = [m for m in range(0, 60) if admits(specs[i][1], (m, 0, 0), (m + 1, 0, 0))
                             and admits(specs[j][1], (m, 0, 0), (m + 1, 0, 0))]
                    if not joint:
                        problems.append(f"{specs[i][0]} and {specs[j][0]} share no Node major")
        if problems:
            self.add("warn", "node.pin.disagree", ", ".join(sorted(set(list(exact) + list(ranges)))),
                     "Node pins disagree - " + "; ".join(problems),
                     "choose the production Node major and make every pin say it")

        eol = node.get("releases") or {}

        # Unknown majors (a future line, a typo) are never called end-of-life.
        ends = {int(k): dt.date.fromisoformat(v["end"]) for k, v in eol.items()
                if k.isdigit() and isinstance(v, dict) and v.get("end")}
        dead = [(s, m) for s, m in exact.items() if m in ends and ends[m] < self.as_of]
        if dead:
            self.add("warn", "js.node.eol", dead[0][0],
                     "end-of-life Node pinned: " + ", ".join(f"{s}={m} (EOL {ends[m]})" for s, m in dead),
                     "move to a supported LTS major (references/version-pinning.md)")
        elif not exact:
            supported = [m for m, end in ends.items() if end >= self.as_of]
            for src, spec in ranges.items():
                if supported and not any(admits(spec, (m, 0, 0), (m + 1, 0, 0)) for m in supported):
                    self.add("warn", "js.node.eol", src, f"{src} '{spec}' admits no supported Node release",
                             "widen or move the range to a supported LTS major")

    # ---- Composer / PHP ----
    def php(self):
        c = self.composer
        if c is None:
            if (self.root / "composer.json").is_file():
                self.add("error", "php.manifest.invalid", "composer.json", "composer.json is not valid JSON",
                         "fix the JSON; `composer validate` shows where")
            return
        is_lib = str(c.get("type", "project")) not in ("project", "")
        req = c.get("require") or {}
        req_dev = c.get("require-dev") or {}
        pkgs = [n for n in list(req) + list(req_dev) if not COMPOSER_PLATFORM.match(n)]
        lock_p = self.root / "composer.lock"
        lock = read_json(lock_p) if lock_p.is_file() else None
        if not lock_p.is_file():
            if pkgs and not is_lib:
                self.add("warn", "php.lockfile.missing", "composer.json",
                         "composer.json has packages but no composer.lock - `composer install` resolves fresh every time",
                         "run `composer update` once (in DDEV: `ddev composer update`) and commit composer.lock")
        elif not isinstance(lock, dict):
            self.add("error", "php.lockfile.stale", "composer.lock", "composer.lock is not valid JSON",
                     "regenerate it with `composer update --lock`")
        else:
            locked = {str(p.get("name", "")).lower() for p in (lock.get("packages") or []) + (lock.get("packages-dev") or [])}
            missing = sorted(n for n in pkgs if n.lower() not in locked)
            if missing:
                self.add("warn", "php.lockfile.stale", "composer.lock",
                         "composer.json requires packages missing from composer.lock: " + ", ".join(missing[:8]),
                         "run `composer update <package>` for the new requirement and commit composer.lock")
        php_req = req.get("php")
        if not php_req:
            self.add("warn", "php.require.missing", "composer.json",
                     "no require.php - nothing stops installing on a PHP the code cannot run on",
                     'add "php": "^<production major.minor>" to require')
        platform = ((c.get("config") or {}).get("platform") or {}).get("php") if isinstance(c.get("config"), dict) else None
        if not platform and not is_lib:
            self.add("warn", "php.platform.unset", "composer.json",
                     "no config.platform.php - `composer update` resolves for whatever PHP runs it, not production",
                     'set config.platform.php to the production PHP version, e.g. "8.3.0" (references/version-pinning.md)')
        exact: dict[str, tuple] = {}

        def put(src, v):
            """Record a major.minor pin; False when v is not version-shaped."""
            m = re.match(r"^(\d+)\.(\d+)", str(v or "").strip())
            if m:
                exact[src] = (int(m.group(1)), int(m.group(2)))
            return bool(m)

        put("composer.json config.platform.php", platform)
        if isinstance(lock, dict):
            po = (lock.get("platform-overrides") or {}).get("php") if isinstance(lock.get("platform-overrides"), dict) else None
            put("composer.lock platform-overrides.php", po)
        if self.ddev is not None:
            pv = self.ddev.get("php_version")
            if not put(".ddev/config.yaml php_version", pv) and not pv:
                self.add("warn", "ddev.php.unpinned", ".ddev/config.yaml",
                         "no php_version - the container runs DDEV's default PHP, which moves with DDEV upgrades",
                         "set php_version to the production PHP major.minor")
        self.meta["php_pins"] = {**{k: f"{v[0]}.{v[1]}" for k, v in exact.items()},
                                 **({"composer.json require.php": str(php_req)} if php_req else {})}
        problems = []
        if len(set(exact.values())) > 1:
            problems.append("exact pins differ: " + ", ".join(f"{k}={v[0]}.{v[1]}" for k, v in exact.items()))
        if php_req:
            for src, (a, b) in exact.items():
                if admits(str(php_req), (a, b, 0), (a, b + 1, 0), "composer") is False:
                    problems.append(f"require.php '{php_req}' excludes {src}={a}.{b}")
        if problems:
            self.add("warn", "php.pin.disagree", ", ".join(sorted(set(exact) | ({"composer.json require.php"} if php_req else set()))),
                     "PHP pins disagree - " + "; ".join(problems),
                     "set DDEV php_version and config.platform.php to production PHP; make require.php admit it")
        rel_tbl = (self.facts.get("php") or {}).get("releases") or {}

        # Unknown branches (8.6 before the table learns it) are never called end-of-life.
        ends = {tuple(map(int, k.split("."))): dt.date.fromisoformat(v["security_end"])
                for k, v in rel_tbl.items()
                if re.match(r"^\d+\.\d+$", k) and isinstance(v, dict) and v.get("security_end")}
        dead = [(s, v) for s, v in exact.items() if v in ends and ends[v] < self.as_of]
        if dead:
            self.add("warn", "php.eol", dead[0][0],
                     "end-of-life PHP: " + ", ".join(f"{s}={v[0]}.{v[1]} (security support ended {ends[v]})" for s, v in dead),
                     "plan the PHP upgrade: `composer why-not php <target>` lists the blockers (references/legacy-exits.md)")
        elif not exact and php_req:
            live = [v for v, end in ends.items() if end >= self.as_of]
            if live and not any(admits(str(php_req), (a, b, 0), (a, b + 1, 0), "composer") for a, b in live):
                self.add("warn", "php.eol", "composer.json", f"require.php '{php_req}' admits no supported PHP release",
                         "raise the constraint to a supported PHP (references/legacy-exits.md)")

    # ---- npx / dlx / exec ----
    def npx(self):
        native = {n.lower() for n in (self.facts.get("native_cli_names") or {}).get("names", [])}
        declared = set(self._declared()) if self.pkg else set()
        # An unreadable package.json hides which bins are local; guessing "remote" would
        # turn one js.manifest.invalid into a cascade of false npx.unpinned findings.
        locals_unknown = self.pkg is None and (self.root / "package.json").is_file()
        seen: set = set()

        def inspect(file: str, line_no, text: str, in_script: bool):
            for m in LAUNCHER.finditer(text):
                launcher = re.sub(r"\s+", " ", m.group(1))
                toks = m.group(2).split()
                pkg, i = None, 0
                while i < len(toks):
                    t = toks[i]
                    if t == "--":
                        i += 1
                        continue
                    if t in ("-p", "--package"):
                        pkg = toks[i + 1] if i + 1 < len(toks) else None
                        break
                    if t.startswith("--package="):
                        pkg = t.split("=", 1)[1]
                        break
                    if t in FLAG_WITH_VALUE:
                        i += 2
                        continue
                    if t.startswith("-"):
                        i += 1
                        continue
                    pkg = t
                    break
                if not pkg:
                    continue
                pkg = pkg.strip("'\"`),")
                if not re.match(r"^(@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*(@\S+)?$", pkg, re.I):
                    continue  # prose like "npx is..." or a placeholder
                at = pkg.rfind("@")
                base, ver = (pkg[:at], pkg[at + 1:]) if at > 0 else (pkg, "")
                # Dedupe on the full spec: a pinned `x@1.2.3` must not hide a later bare `x`.
                key = (file, pkg.lower())
                if key in seen:
                    continue
                seen.add(key)
                if base.lower() in native:
                    self.add("error", "npx.native-cli", file,
                             f"`{launcher} {pkg}` routes a native CLI through the npm registry - the npm name is not the tool's official channel",
                             f"install {base} from its own channel (winget/brew/apt/cargo) and call it directly",
                             line_no)
                    continue
                if EXACT_SEMVER.match(ver) or locals_unknown:
                    continue
                if base in declared:
                    if in_script:
                        self.note("npx.redundant", file, f"`{launcher} {base}` in a script: {base} is a local dependency; npm run already puts node_modules/.bin on PATH")
                    continue
                if len([f for f in self.findings if f["id"] == "npx.unpinned"]) >= self.limit:
                    continue
                self.add("warn", "npx.unpinned", file,
                         f"`{launcher} {pkg}` fetches and runs an unpinned package from the registry",
                         f"add {base} as a devDependency, or pin it: {launcher} {base}@<exact version>",
                         line_no)

        if self.pkg:
            for name, cmd in (self.pkg.get("scripts") or {}).items():
                inspect(f"package.json scripts.{name}", None, str(cmd), True)
        if not self.docs:
            return
        scanned = 0
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in sorted(filenames):
                p = Path(dirpath) / fn
                if p.suffix.lower() not in DOC_SUFFIXES and fn.lower() not in DOC_NAMES \
                        and not fn.lower().startswith(("dockerfile", "readme")):
                    continue
                try:
                    if p.stat().st_size > MAX_DOC_BYTES:
                        continue
                except OSError:
                    continue
                text = read_text(p)
                if text is None:
                    continue
                scanned += 1
                md = p.suffix.lower() in (".md", ".markdown") or fn.lower().startswith("readme")
                for n, line in code_lines(text, md):
                    if re.search(r"npx|dlx|bunx|bun x|npm exec", line):
                        inspect(rel(self.root, p), n, line, False)
        self.meta["files_scanned"] = scanned

    # ---- legacy tools ----
    def legacy(self):
        for f in ("bower.json", ".bowerrc"):
            if (self.root / f).is_file():
                self.add("warn", "legacy.bower", f, "Bower manifest - Bower is a legacy front-end manager",
                         "move each Bower package to npm (references/legacy-exits.md)")
                break
        if self.pkg and "node-sass" in self._declared():
            self.add("warn", "legacy.node-sass", "package.json",
                     "node-sass is deprecated and does not build on current Node",
                     "replace with sass (Dart Sass); sass-loader picks it up (references/legacy-exits.md)")

    # ---- committed registry credentials (values never printed) ----
    def secrets(self):
        for f, pat in ((".npmrc", r"(_authToken|_auth|_password)\s*=\s*(\S+)"),
                       (".yarnrc.yml", r"(npmAuthToken|npmAuthIdent)\s*:\s*(\S+)")):
            t = read_text(self.root / f) if (self.root / f).is_file() else None
            for n, line in enumerate((t or "").splitlines(), 1):
                if line.lstrip().startswith(("#", ";")):
                    continue
                m = re.search(pat, line)
                if m and not m.group(2).strip("'\"").startswith("${"):
                    self.add("error", "registry.token.committed", f, f"literal {m.group(1)} on line {n} (value not shown)",
                             "revoke the token, replace it with an env reference like ${NPM_TOKEN}", n)
        if (self.root / "auth.json").is_file():
            ignored = re.search(r"^/?auth\.json\s*$", read_text(self.root / ".gitignore") or "", re.M)
            if ignored:
                self.note("registry.authjson.ignored", "auth.json", "auth.json present but gitignored (good)")
            else:
                self.add("error", "registry.authjson.committed", "auth.json",
                         "Composer auth.json at the repo root and not gitignored",
                         "revoke the credentials, gitignore auth.json, use COMPOSER_AUTH in CI")


def load_facts(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts file not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("schema") != FACTS_SCHEMA:
            raise ValueError(f"schema {data.get('schema')!r} != {FACTS_SCHEMA!r}")
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"error: could not parse facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="pm-audit.py",
        description="Read-only package-manager audit of a repo root (lockfiles, Node/PHP pins, npx, legacy tools).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py .\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[].id'\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2026-10-05 path/to/repo\n\n"
               "Exit: 0 clean, 2 usage, 3 path/facts missing, 4 facts unparseable, 10 findings",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("path", help="repo root to audit")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    p.add_argument("--no-docs", action="store_true", help="skip the npx scan of docs and scripts (package.json scripts still checked)")
    p.add_argument("--as-of", default=None, help="date for end-of-life checks (default: today, UTC)")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalogue JSON (EOL tables, native CLI names)")
    p.add_argument("--limit", type=int, default=50, help="max npx.unpinned findings to report (default 50)")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    try:
        as_of = dt.date.fromisoformat(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc).date()
    except ValueError:
        print(f"error: --as-of wants YYYY-MM-DD, got {args.as_of!r}", file=sys.stderr)
        return EX_USAGE
    if args.limit < 1:
        print("error: --limit must be >= 1", file=sys.stderr)
        return EX_USAGE
    root = Path(args.path).expanduser()
    if not root.is_dir():
        msg = f"not a directory: {args.path}"
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg, "details": {}}}))
        print(f"error: {msg}", file=sys.stderr)
        return EX_NOTFOUND
    root = root.resolve()
    facts = load_facts(Path(args.facts))
    a = Audit(root, facts, as_of, not args.no_docs, args.limit).run()
    sev_rank = {"error": 0, "warn": 1}
    a.findings.sort(key=lambda f: (sev_rank.get(f["severity"], 2), f["id"], f["file"]))
    print(f"pm-audit: {root.name} (as of {as_of.isoformat()})", file=sys.stderr)
    if args.json:
        print(json.dumps({"data": a.findings,
                          "meta": {"schema": SCHEMA, "root": root.name, "as_of": as_of.isoformat(),
                                   "count": len(a.findings), "notes": a.notes, **a.meta}}, indent=2))
    else:
        for f in a.findings:
            loc = f["file"] + (f":{f['line']}" if f.get("line") else "")
            print("\t".join([f["severity"], f["id"], loc, f["message"], f["fix"]]))
    for n in a.notes:
        print(f"  note  {n['id']}  {n['file']}: {n['message']}", file=sys.stderr)
    managers = ", ".join(a.meta["managers"]) or "none"
    if a.findings:
        print(f"pm-audit: {len(a.findings)} finding(s); managers: {managers}", file=sys.stderr)
        return EX_FINDINGS
    print(f"pm-audit: clean; managers: {managers}", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
