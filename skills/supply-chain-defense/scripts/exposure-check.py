#!/usr/bin/env python3
"""Match on-disk installed packages against an IOC exposure catalog.

Answers the post-advisory question: "an advisory named package X@Y — do we
have it installed right now, and where?" Cross-platform (works on Windows,
unlike Perplexity's Bumblebee, whose exposure-catalog JSON format this borrows).
Reads lockfiles + installed metadata across npm (package-lock / pnpm-lock /
yarn.lock), PyPI, Composer, Cargo, Go, and RubyGems, plus installed editor
extensions; no package-manager execution, no network, no source reads.

Usage: exposure-check.py [--catalog PATH] [--root DIR]... [--json] [--findings-only]

Input:   --root dirs (default: cwd); --catalog file or dir of *.json
         (default: bundled assets/exposure-catalog.json)
Output:  stdout = findings (or all components), NDJSON-ish JSON with --json
Stderr:  progress, summary, errors
Exit:    0 no exposure, 2 usage, 3 catalog-not-found, 4 invalid-catalog,
         10 EXPOSURE FOUND (>=1 installed package matches the catalog)

Examples:
  exposure-check.py --root ~/code
  exposure-check.py --root . --json | jq '.data.findings[]'
  exposure-check.py --catalog ./my-iocs.json --root /srv/app --findings-only
"""
import argparse, json, os, re, sys
from pathlib import Path
from typing import NoReturn

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_INVALID, EXIT_EXPOSED = 0, 2, 3, 4, 10
SKIP_DIRS = {".git", ".hg", ".svn", "worktrees"}
DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "assets" / "exposure-catalog.json"


def log(msg): print(msg, file=sys.stderr)


class Term:
    """Inline ANSI helper mirroring skills/_lib/term.sh (bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline). Lazy properties so it
    reflects a later stream reconfigure(); honors FORCE_COLOR / NO_COLOR /
    TERM_ASCII and falls back to ASCII glyphs on a non-UTF stream encoding."""

    _C = {"green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
          "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _G = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "unknown": "?"}
    _A = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "unknown": "?"}
    _MC = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim", "unknown": "yellow"}

    def __init__(self, stream): self.s = stream

    @property
    def ascii(self):
        enc = (getattr(self.s, "encoding", "") or "").lower()
        return (os.environ.get("TERM_ASCII") == "1" or os.environ.get("FLEET_ASCII") == "1"
                or "utf" not in enc)

    @property
    def color(self):
        if os.environ.get("FORCE_COLOR"):
            return True
        if (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
                or not getattr(self.s, "isatty", lambda: False)()):
            return False
        return True

    def c(self, n, t):
        return f"{self._C.get(n, '')}{t}{self._C['off']}" if self.color else t

    def mark(self, st):
        return self.c(self._MC.get(st, ""), (self._A if self.ascii else self._G).get(st, "."))


TERM = Term(sys.stderr)


def die(msg, code) -> NoReturn:
    log(f"ERROR: {msg}")
    sys.exit(code)


def read_text_tolerant(path: Path) -> str:
    # Lockfiles/manifests written by PowerShell `>` redirects arrive UTF-16 with
    # a BOM; a strict utf-8 read aborts the whole sweep on the first such file.
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def load_catalog(path: Path):
    files = []
    if path.is_dir():
        files = sorted(path.glob("*.json"))
    elif path.is_file():
        files = [path]
    if not files:
        die(f"catalog not found: {path}", EXIT_NOT_FOUND)
    entries, ver = [], None
    for f in files:
        doc = {}
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            die(f"invalid catalog {f}: {e}", EXIT_INVALID)
        if ver is None:
            ver = doc.get("schema_version")
        elif doc.get("schema_version") != ver:
            die(f"schema_version mismatch across catalogs: {f}", EXIT_INVALID)
        entries.extend(doc.get("entries", []))
    # index: (ecosystem, lowercased package name) -> {version: entry}
    index = {}
    for e in entries:
        key = (e.get("ecosystem", ""), str(e.get("package", "")).lower())
        index.setdefault(key, {})
        for v in e.get("versions", []):
            index[key][str(v)] = e
    return index, ver, len(entries)


def walk(roots):
    for root in roots:
        base = Path(root).expanduser()
        if not base.exists():
            log(TERM.c("orange", f"[warn] root does not exist: {base}"))
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            yield Path(dirpath), filenames


def add(components, ecosystem, name, version, source):
    if name and version:
        components.append({"ecosystem": ecosystem, "name": str(name),
                           "version": str(version), "source": str(source)})


def parse_npm_lock(path: Path, components):
    try:
        doc = json.loads(read_text_tolerant(path))
    except (json.JSONDecodeError, OSError):
        return
    # lockfileVersion 2/3: packages{} keyed by "node_modules/<name>"
    for pkgpath, meta in (doc.get("packages") or {}).items():
        if not pkgpath:
            continue  # root package entry ""
        name = pkgpath.split("node_modules/")[-1]
        add(components, "npm", name, meta.get("version"), path)
    # lockfileVersion 1: dependencies{} (recursive)
    def walk_deps(deps):
        for name, meta in (deps or {}).items():
            add(components, "npm", name, meta.get("version"), path)
            walk_deps(meta.get("dependencies"))
    walk_deps(doc.get("dependencies"))


# pnpm-lock.yaml package keys: "/axios@1.14.1:", "axios@1.14.1:", "/@vue/cli@5.0.8(...)"
PNPM_RE = re.compile(r"^\s+'?/?(@?[A-Za-z0-9][\w.-]*(?:/[\w.-]+)?)@([0-9][\w.\-]*)")


def parse_pnpm_lock(path: Path, components):  # pnpm-lock.yaml (regex; no YAML dep)
    seen = set()
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            m = PNPM_RE.match(line)
            if m and (m.group(1), m.group(2)) not in seen:
                seen.add((m.group(1), m.group(2)))
                add(components, "npm", m.group(1), m.group(2), path)
    except OSError:
        pass


BUN_RE = re.compile(r'"(@?[A-Za-z0-9][\w.-]*(?:/[\w.-]+)?)@([0-9][\w.\-+]*)"')


def parse_bun_lock(path: Path, components):  # bun.lock (text/JSONC) — regex name@version
    seen = set()
    try:
        for m in BUN_RE.finditer(path.read_text(encoding="utf-8", errors="replace")):
            if (m.group(1), m.group(2)) not in seen:
                seen.add((m.group(1), m.group(2)))
                add(components, "npm", m.group(1), m.group(2), path)
    except OSError:
        pass


def parse_yarn_lock(path: Path, components):  # yarn.lock (classic + Berry)
    name = None; seen = set()
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line and not line[0].isspace() and line.rstrip().endswith(":"):
                first = line.strip()[:-1].split(",")[0].strip().strip('"')
                if first.startswith("__") or "@" not in first:
                    name = None
                elif first.startswith("@"):
                    name = "@" + first[1:].split("@")[0]          # @scope/pkg
                else:
                    name = first.split("@")[0]
            elif name:
                m = re.match(r'\s+version[:\s]+"?([0-9][^"\s]*)"?', line)
                if m and (name, m.group(1)) not in seen:
                    seen.add((name, m.group(1)))
                    add(components, "npm", name, m.group(1), path)
                    name = None
    except OSError:
        pass


REQ_RE = re.compile(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([A-Za-z0-9_.\-]+)")


def parse_requirements(path: Path, components):
    try:
        for line in read_text_tolerant(path).splitlines():
            m = REQ_RE.match(line)
            if m:
                add(components, "pypi", m.group(1), m.group(2), path)
    except OSError:
        pass


def parse_dist_info(path: Path, components):  # *.dist-info/METADATA
    name = ver = None
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Name:"):
                name = line.split(":", 1)[1].strip()
            elif line.startswith("Version:"):
                ver = line.split(":", 1)[1].strip()
            if name and ver:
                break
    except OSError:
        return
    add(components, "pypi", name, ver, path)


def parse_composer_lock(path: Path, components):  # composer.lock (JSON)
    try:
        doc = json.loads(read_text_tolerant(path))
    except (json.JSONDecodeError, OSError):
        return
    for key in ("packages", "packages-dev"):
        for meta in (doc.get(key) or []):
            add(components, "composer", meta.get("name"), meta.get("version"), path)


def parse_cargo_lock(path: Path, components):  # Cargo.lock (TOML; needs py3.11+ tomllib)
    try:
        import tomllib
    except ImportError:
        return  # tomllib is 3.11+; skip Cargo on older pythons
    try:
        doc = tomllib.loads(read_text_tolerant(path))
    except Exception:  # OSError or tomllib.TOMLDecodeError
        return
    for pkg in doc.get("package", []):
        add(components, "cargo", pkg.get("name"), pkg.get("version"), path)


def parse_go_sum(path: Path, components):  # go.sum lines: "<module> <version>[/go.mod] <hash>"
    seen = set()
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith("v"):
                mod, ver = parts[0], parts[1].replace("/go.mod", "")
                if (mod, ver) not in seen:
                    seen.add((mod, ver))
                    add(components, "go", mod, ver, path)
    except OSError:
        pass


GEM_RE = re.compile(r"^\s{4}([A-Za-z0-9_.\-]+) \(([^)]+)\)\s*$")


def parse_gemfile_lock(path: Path, components):  # Gemfile.lock GEM/specs section
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            m = GEM_RE.match(line)
            if m:
                add(components, "rubygems", m.group(1), m.group(2), path)
    except OSError:
        pass


# Installed editor extensions live in fixed HOME dirs, not under --root. Each
# extension is a <publisher>.<name>-<version>/package.json. Covers the Nx Console /
# GitHub-breach vector (malicious VS Code extension) that package scanning misses.
EXT_DIRS = [
    "~/.vscode/extensions", "~/.vscode-server/extensions", "~/.vscode-oss/extensions",
    "~/.cursor/extensions", "~/.windsurf/extensions",
]


def collect_editor_extensions():
    comps = []
    # SC_EXT_DIRS (os.pathsep-separated) overrides the defaults — for tests or
    # non-standard install locations.
    dirs = os.environ.get("SC_EXT_DIRS", "").split(os.pathsep) if os.environ.get("SC_EXT_DIRS") else EXT_DIRS
    for d in dirs:
        if not d:
            continue
        base = Path(d).expanduser()
        if not base.is_dir():
            continue
        for pkg in base.glob("*/package.json"):
            try:
                doc = json.loads(pkg.read_text(encoding="utf-8", errors="replace"))
            except (json.JSONDecodeError, OSError):
                continue
            pub, name, ver = doc.get("publisher"), doc.get("name"), doc.get("version")
            if pub and name:
                add(comps, "editor-extension", f"{pub}.{name}", ver, pkg)
    return comps


def collect(roots):
    components = []
    for dirpath, filenames in walk(roots):
        for fn in filenames:
            full = dirpath / fn
            if fn in ("package-lock.json", "npm-shrinkwrap.json", ".package-lock.json"):
                parse_npm_lock(full, components)
            elif fn == "pnpm-lock.yaml":
                parse_pnpm_lock(full, components)
            elif fn == "yarn.lock":
                parse_yarn_lock(full, components)
            elif fn == "bun.lock":
                parse_bun_lock(full, components)
            elif fn.startswith("requirements") and fn.endswith(".txt"):
                parse_requirements(full, components)
            elif fn == "METADATA" and dirpath.name.endswith(".dist-info"):
                parse_dist_info(full, components)
            elif fn == "composer.lock":
                parse_composer_lock(full, components)
            elif fn == "Cargo.lock":
                parse_cargo_lock(full, components)
            elif fn == "go.sum":
                parse_go_sum(full, components)
            elif fn == "Gemfile.lock":
                parse_gemfile_lock(full, components)
    return components


def main():
    # Force UTF-8 on Windows so help text / output never crash on cp1252
    # (the same class of bug GuardDog hits — see references/tooling-landscape.md).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG),
                    help="IOC catalog JSON file or dir of *.json")
    ap.add_argument("--root", action="append", default=[],
                    help="directory to scan (repeatable; default: cwd)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--findings-only", action="store_true",
                    help="emit only matches, not the full component inventory")
    ap.add_argument("--no-extensions", action="store_true",
                    help="skip the installed-editor-extension inventory")
    args = ap.parse_args()

    roots = args.root or ["."]
    index, schema_ver, n_entries = load_catalog(Path(args.catalog).expanduser())
    log(TERM.c("cyan", f"=== exposure-check: {n_entries} IOC entries (schema {schema_ver}), "
                       f"roots: {', '.join(roots)} ==="))

    components = collect(roots)
    if not args.no_extensions:
        components += collect_editor_extensions()
    findings = []
    for c in components:
        bucket = index.get((c["ecosystem"], c["name"].lower()))
        # "*" in a catalog entry's versions flags ANY installed version — the right
        # model for tag-rewrite attacks (Laravel-Lang) where every version is poisoned.
        if bucket and (c["version"] in bucket or "*" in bucket):
            e = bucket.get(c["version"]) or bucket["*"]
            findings.append({**c, "ioc_id": e.get("id"),
                             "severity": e.get("severity", "unknown"),
                             "note": e.get("note", "")})

    if args.json:
        data: dict[str, object] = {"findings": findings}
        if not args.findings_only:
            data["components_scanned"] = len(components)
        print(json.dumps({"data": data, "meta": {
            "exposed": bool(findings), "findings": len(findings),
            "components_scanned": len(components), "ioc_entries": n_entries,
            "schema": "axiom.tool.exposure-check.report/v1"}}))
    else:
        if not args.findings_only:
            for c in components:
                print(f"{c['ecosystem']}\t{c['name']}\t{c['version']}\t{c['source']}")
        for f in findings:
            log(f"  {TERM.mark('bad')} [EXPOSED] {f['ecosystem']} {f['name']}@{f['version']} "
                f"({f['severity']}, {f['ioc_id']}) - {f['source']}")

    if findings:
        log(TERM.c("red", f"EXPOSED: {len(findings)} installed package(s) match the IOC catalog. "
                          f"Treat as incident: isolate, rotate creds, remove the package."))
        sys.exit(EXIT_EXPOSED)
    log(f"{TERM.mark('ok')} {TERM.c('green', f'Clean: 0 of {len(components)} scanned components match the catalog.')}")
    sys.exit(EXIT_OK)


if __name__ == "__main__":
    main()
