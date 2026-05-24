#!/usr/bin/env python3
"""Match on-disk installed packages against an IOC exposure catalog.

Answers the post-advisory question: "an advisory named package X@Y — do we
have it installed right now, and where?" Cross-platform (works on Windows,
unlike Perplexity's Bumblebee, whose exposure-catalog JSON format this borrows).
Reads npm lockfiles and Python installed metadata; no package-manager execution,
no network, no source reads.

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


def die(msg, code) -> NoReturn:
    log(f"ERROR: {msg}")
    sys.exit(code)


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
            log(f"[warn] root does not exist: {base}")
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
        doc = json.loads(path.read_text(encoding="utf-8"))
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


REQ_RE = re.compile(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([A-Za-z0-9_.\-]+)")


def parse_requirements(path: Path, components):
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
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


def collect(roots):
    components = []
    for dirpath, filenames in walk(roots):
        for fn in filenames:
            full = dirpath / fn
            if fn in ("package-lock.json", "npm-shrinkwrap.json", ".package-lock.json"):
                parse_npm_lock(full, components)
            elif fn.startswith("requirements") and fn.endswith(".txt"):
                parse_requirements(full, components)
            elif fn == "METADATA" and dirpath.name.endswith(".dist-info"):
                parse_dist_info(full, components)
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
    args = ap.parse_args()

    roots = args.root or ["."]
    index, schema_ver, n_entries = load_catalog(Path(args.catalog).expanduser())
    log(f"=== exposure-check: {n_entries} IOC entries (schema {schema_ver}), "
        f"roots: {', '.join(roots)} ===")

    components = collect(roots)
    findings = []
    for c in components:
        bucket = index.get((c["ecosystem"], c["name"].lower()))
        if bucket and c["version"] in bucket:
            e = bucket[c["version"]]
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
            log(f"  [EXPOSED] {f['ecosystem']} {f['name']}@{f['version']} "
                f"({f['severity']}, {f['ioc_id']}) - {f['source']}")

    if findings:
        log(f"EXPOSED: {len(findings)} installed package(s) match the IOC catalog. "
            f"Treat as incident: isolate, rotate creds, remove the package.")
        sys.exit(EXIT_EXPOSED)
    log(f"Clean: 0 of {len(components)} scanned components match the catalog.")
    sys.exit(EXIT_OK)


if __name__ == "__main__":
    main()
