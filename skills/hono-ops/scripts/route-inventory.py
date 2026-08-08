#!/usr/bin/env python3
"""List a Hono app's routes, middleware, and mounts from TypeScript source; lint registration order.

Usage:   route-inventory.py [OPTIONS] PATH
Input:   PATH — a .ts/.tsx file or a source directory (scanned recursively;
         node_modules, dist, build, and dot-directories are skipped)
Output:  stdout, data only.
         Default: TSV rows  kind<TAB>method<TAB>path<TAB>app<TAB>file:line
         --json:  {"data": [...], "meta": {"count": N, "schema":
                  "claude-mods.hono-ops.route-inventory/v1"}}
         --check: findings only (same TSV/JSON shape, kind=finding)
Stderr:  headers, progress, warnings, errors
Exit:    0 ok/clean, 2 usage, 3 path not found, 10 --check produced findings
         (confirm each is deliberate)

Notes:   Pure-regex static analysis (no TypeScript compiler API required — the
         native TS 7 toolchain ships none). Per-file: `app.route()` mounts are
         listed but sub-app files are not expanded into their mount prefix.
         The --check linter runs three registration-order lints (Hono matches
         in registration order; each finding carries an `issue` field in
         --json): `bypass` — a route registered before a middleware whose
         pattern covers it silently skips that middleware; `duplicate` — the
         same (method, path) registered twice, second is dead; `shadowed` — a
         route after an earlier broader same-method route can never match. A
         bypass is either the #1 Hono ordering bug or a deliberate pre-auth
         exception; the linter's job is to make you say which.

Examples:
  route-inventory.py src/
  route-inventory.py --json src/ | jq '.data[] | select(.kind=="mount")'
  route-inventory.py --check src/            # exit 10 = order findings
  route-inventory.py --check --json src/index.ts
"""

import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA = "claude-mods.hono-ops.route-inventory/v1"
METHODS = ("get", "post", "put", "patch", "delete", "options", "all")
SKIP_DIRS = {"node_modules", "dist", "build", "coverage"}

# Statement-style: `app.get(` / `export const x = app.route(` etc.
STMT_RE = re.compile(
    r"^\s*(?:export\s+)?(?:const\s+\w+\s*=\s*)?(?:await\s+)?"
    r"(?P<app>[A-Za-z_$][\w$]*)\.(?P<verb>get|post|put|patch|delete|options|all|on|use|route|onError|notFound)\s*\("
)
# Chained-style continuation: `  .get('/x', ...)`
CHAIN_RE = re.compile(r"^\s*\.(?P<verb>get|post|put|patch|delete|options|all|on|use|route)\s*\(")
# `const app = new Hono<...>()` — anchors chained-call attribution to the right app var.
NEW_APP_RE = re.compile(r"^\s*(?:export\s+)?(?:const|let|var)\s+(?P<app>[A-Za-z_$][\w$]*)\s*=\s*new\s+Hono\b")


def string_args(line: str, start: int, max_args: int = 2) -> list[str]:
    """Return up to max_args leading string-literal arguments after position `start`.

    Stops at the first argument that is not a plain string literal (template
    literals and identifiers end the scan — we only trust what we can read).
    """
    out: list[str] = []
    i = start
    n = len(line)
    while len(out) < max_args:
        while i < n and line[i] in " \t":
            i += 1
        if i >= n or line[i] not in "'\"":
            break
        quote = line[i]
        j = i + 1
        buf = []
        while j < n and line[j] != quote:
            if line[j] == "\\" and j + 1 < n:
                buf.append(line[j + 1])
                j += 2
                continue
            buf.append(line[j])
            j += 1
        if j >= n:  # unterminated on this line — bail
            break
        out.append("".join(buf))
        i = j + 1
        while i < n and line[i] in " \t":
            i += 1
        if i < n and line[i] == ",":
            i += 1
        else:
            break
    return out


def pattern_to_regex(pattern: str) -> re.Pattern:
    """Compile a Hono path pattern ('*', '/api/*', '/x/:id') to a full-match regex."""
    if pattern in ("", "*", "/*"):
        return re.compile(r".*")
    esc = re.escape(pattern)
    esc = esc.replace(r"\*", ".*")
    esc = re.sub(r"\\:[A-Za-z_][\w]*", r"[^/]+", esc)
    return re.compile(esc + r"$")


def scan_file(path: Path, root: Path) -> list[dict]:
    entries: list[dict] = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        print(f"warning: unreadable {path}: {e}", file=sys.stderr)
        return entries
    rel = path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)
    last_app = "(chained)"
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith(("//", "*", "/*")):
            continue
        new_app = NEW_APP_RE.match(line)
        if new_app:
            last_app = new_app.group("app")
            continue
        m = STMT_RE.match(line)
        chained = False
        if not m:
            m = CHAIN_RE.match(line)
            chained = bool(m)
            if not m:
                continue
        verb = m.group("verb")
        app = m.group("app") if not chained else last_app
        if not chained:
            last_app = app
        args = string_args(line, m.end())
        if verb == "on":
            method = args[0].upper() if args else "?"
            route_path = args[1] if len(args) > 1 else "?"
            kind = "route"
        elif verb in METHODS:
            method, route_path, kind = verb.upper(), (args[0] if args else "?"), "route"
        elif verb == "use":
            method, route_path, kind = "*", (args[0] if args else "*"), "middleware"
        elif verb == "route":
            method, route_path, kind = "-", (args[0] if args else "?"), "mount"
        else:  # onError / notFound
            method, route_path, kind = "-", "-", verb
        entries.append({
            "kind": kind, "method": method, "path": route_path,
            "app": app, "file": rel, "line": lineno,
        })
    return entries


def _finding(r: dict, issue: str, detail: str) -> dict:
    return {"kind": "finding", "issue": issue, "method": r["method"], "path": r["path"],
            "app": r["app"], "file": r["file"], "line": r["line"], "detail": detail}


def check_order(entries: list[dict]) -> list[dict]:
    """Three lints per (file, app) group, all consequences of Hono matching in
    registration order:
      bypass    - a route/mount registered BEFORE a middleware whose pattern
                  covers it (the middleware silently never runs for it)
      duplicate - the exact same (method, path) route registered twice
                  (the second registration is dead - first match wins)
      shadowed  - a route registered AFTER an earlier same-method (or ALL)
                  route whose broader pattern covers its path (dead route)
    Mounts are excluded from duplicate/shadowed: two sub-apps on one base path
    is a legitimate Hono pattern (matching falls through across mounts)."""
    findings: list[dict] = []
    by_file_app: dict[tuple, list[dict]] = {}
    for e in entries:
        by_file_app.setdefault((e["file"], e["app"]), []).append(e)
    for group in by_file_app.values():
        middlewares = [e for e in group if e["kind"] == "middleware" and e["path"] != "?"]
        covered = [e for e in group if e["kind"] in ("route", "mount") and e["path"] not in ("?", "-")]
        routes = [e for e in group if e["kind"] == "route" and e["path"] not in ("?", "-")]

        for mw in middlewares:
            rx = pattern_to_regex(mw["path"])
            for r in covered:
                if r["line"] < mw["line"] and rx.match(r["path"]):
                    findings.append(_finding(r, "bypass",
                        f"registered before middleware use('{mw['path']}') at "
                        f"{mw['file']}:{mw['line']} - this {r['kind']} bypasses it"))

        seen: dict[tuple, dict] = {}
        for r in routes:
            key = (r["method"], r["path"])
            if key in seen:
                first = seen[key]
                findings.append(_finding(r, "duplicate",
                    f"duplicate of {first['method']} {first['path']} at "
                    f"{first['file']}:{first['line']} - this registration is dead (first match wins)"))
            else:
                seen[key] = r

        for later in routes:
            for earlier in routes:
                if earlier["line"] >= later["line"] or earlier["path"] == later["path"]:
                    continue
                if earlier["method"] != later["method"] and earlier["method"] != "ALL":
                    continue
                if ("*" in earlier["path"] or ":" in earlier["path"]) \
                        and pattern_to_regex(earlier["path"]).match(later["path"]):
                    findings.append(_finding(later, "shadowed",
                        f"shadowed by earlier {earlier['method']} '{earlier['path']}' at "
                        f"{earlier['file']}:{earlier['line']} - this route can never match"))
                    break
    findings.sort(key=lambda f: (f["file"], f["line"]))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="route-inventory.py",
        description="List a Hono app's routes/middleware/mounts; lint registration order.",
        epilog=(
            "Examples:\n"
            "  route-inventory.py src/\n"
            "  route-inventory.py --json src/ | jq '.data[]'\n"
            "  route-inventory.py --check src/    # exit 10 on findings\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("path", help="Hono TypeScript source file or directory")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope instead of TSV")
    ap.add_argument("--check", action="store_true",
                    help="middleware-order lint: report routes a later middleware would have covered (exit 10)")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        # argparse exits 2 on usage errors and 0 on --help; preserve both.
        return int(e.code or 0)

    target = Path(args.path)
    if not target.exists():
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": f"path not found: {target}", "details": {}}}))
        print(f"error: path not found: {target}", file=sys.stderr)
        return 3

    root = target if target.is_dir() else target.parent
    files = (
        sorted(
            p for p in target.rglob("*")
            if p.suffix in (".ts", ".tsx")
            and not any(part in SKIP_DIRS or part.startswith(".") for part in p.parts)
        )
        if target.is_dir() else [target]
    )

    entries: list[dict] = []
    for f in files:
        entries.extend(scan_file(f, root))
    print(f"scanned {len(files)} file(s), {len(entries)} registration(s)", file=sys.stderr)

    rows = check_order(entries) if args.check else entries
    if args.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "schema": SCHEMA}}, indent=2))
    else:
        for r in rows:
            loc = f"{r['file']}:{r['line']}"
            tail = f"\t{r['detail']}" if "detail" in r else ""
            print(f"{r['kind']}\t{r['method']}\t{r['path']}\t{r['app']}\t{loc}{tail}")

    if args.check and rows:
        issues = ", ".join(f"{n} {k}" for k, n in sorted(
            (k, sum(1 for r in rows if r.get("issue") == k)) for k in {r.get("issue") for r in rows}))
        print(f"{len(rows)} finding(s) ({issues}) - confirm each is deliberate", file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    sys.exit(main())
