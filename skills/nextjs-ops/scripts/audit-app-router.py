#!/usr/bin/env python3
"""Static hazard scan of a Next.js App Router tree: boundary, caching, runtime.

The App Router's expensive mistakes are the quiet ones. A sync `cookies()` still
type-checks, a `'use client'` file reading a non-public env var compiles fine and
ships an empty string, a `'use cache'` scope that reads request data can pass
`next build` and only fail under `next start`, and a Server Action with no auth
check is a public POST endpoint that looks like a function call. This scans for
the mechanically-detectable members of that family so an agent finds them before
production does, rather than re-deriving the same twelve greps every task.

It is a linter, not a compiler: it reads text, so it reports where to look, not
proof of a bug. `review` findings are prompts for judgement by design.

Usage:   audit-app-router.py [OPTIONS] <PATH>
Input:   PATH = a Next.js project root (app/ or src/app/ auto-detected) or any
         directory/file to scan. No stdin.
Version: rules are gated on the project's Next.js major, read from
         node_modules/next or package.json. Six of them describe breakages that
         did not exist before 15/16, so running them unversioned against an
         older app would flag correct code. Override with --assume-major when
         the version cannot be read (scanning a bare subdirectory).
Output:  stdout = findings, one TSV row per finding
         (severity<TAB>rule<TAB>file:line<TAB>detail), or a --json envelope.
         Data only.
Stderr:  the verdict line, notices, errors.
Exit:    0 no findings at or above --min-severity, 2 usage, 3 path not found,
         10 findings present (the domain signal - not an error)

Examples:
  audit-app-router.py .
  audit-app-router.py --min-severity error src/app
  audit-app-router.py --json . | jq '.data[] | select(.severity=="error")'
  audit-app-router.py --rules sync-request-api,client-secret-env .
  audit-app-router.py --assume-major 15 ./legacy-app
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_FINDINGS = 10

SCHEMA = "claude-mods.nextjs-ops.app-audit/v1"

SEVERITIES = ("review", "warn", "error")  # ascending
SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}

CODE_SUFFIXES = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}
SKIP_DIRS = {"node_modules", ".next", ".git", "dist", "build", "out", ".turbo", "coverage"}

# Every rule the scanner knows: (severity, min_major, why). Kept as data so
# --help, --rules validation, version gating and the JSON meta all read from one
# place.
#
# min_major is the Next.js major at which the rule first became true. This skill's
# central instruction is "establish the version before answering a caching
# question", and a linter that ignores its own advice is worse than no linter: run
# unversioned against a Next.js 14 app, six of these rules would flag correct code.
# 0 means the rule is version-independent.
RULES: dict[str, tuple[str, int, str]] = {
    "sync-request-api": ("error", 15, "cookies()/headers()/draftMode() are async since Next.js 15 - must be awaited"),
    "sync-params-prop": ("error", 15, "params/searchParams are Promises since Next.js 15 - type as Promise and await"),
    "request-api-in-use-cache": ("error", 15, "request APIs inside a 'use cache' scope throw next-request-in-use-cache"),
    "client-secret-env": ("error", 0, "non-NEXT_PUBLIC_ env var in a 'use client' module is replaced with an empty string"),
    "client-imports-server-only": ("error", 0, "'use client' module importing server-only fails the build"),
    "parallel-route-no-default": ("error", 16, "parallel route slot without default.js fails the build since Next.js 16"),
    "nondeterministic-in-use-cache": ("warn", 15, "Math.random/Date.now/randomUUID in a cached scope freeze one value for all users"),
    "middleware-file": ("warn", 16, "middleware.ts is deprecated since Next.js 16 - rename to proxy.ts"),
    "edge-runtime-segment": ("warn", 16, "runtime='edge' is the deprecated path; Node.js is the default and has no API gaps"),
    "revalidate-tag-single-arg": ("warn", 16, "revalidateTag(tag) single-arg form is deprecated - pass a cacheLife profile or use updateTag"),
    "images-domains-config": ("warn", 0, "images.domains is deprecated - use images.remotePatterns"),
    "action-without-auth": ("review", 0, "'use server' module with no visible auth check - actions are public POST endpoints"),
}

# The major this skill documents; used when the project's version can't be read.
ASSUMED_MAJOR = 16


# --- patterns ---------------------------------------------------------------
DIRECTIVE_RE = re.compile(r"""^\s*['"](use (?:client|server|cache(?::\s*\w+)?))['"]\s*;?\s*$""")
# An awaited/thenned call is fine; a bare one is the bug. Also tolerate
# `cookies` passed as a value (no parens), which this deliberately misses.
SYNC_REQ_RE = re.compile(r"(?<![.\w])(cookies|headers|draftMode)\s*\(\s*\)")
AWAITED_RE = re.compile(r"(await|\.then|use)\s*\(?\s*$")
PARAMS_SYNC_TYPE_RE = re.compile(r"\b(params|searchParams)\s*:\s*\{")
PARAMS_SYNC_DESTRUCTURE_RE = re.compile(r"=\s*(?:props\.)?(params|searchParams)\s*[;,)\n]")
REQ_API_CALL_RE = re.compile(r"(?<![.\w])(cookies|headers)\s*\(\s*\)")
NONDET_RE = re.compile(r"(Math\.random\s*\(|Date\.now\s*\(|new Date\s*\(\s*\)|crypto\.randomUUID\s*\()")
CLIENT_ENV_RE = re.compile(r"process\.env\.([A-Za-z_][A-Za-z0-9_]*)")
SERVER_ONLY_IMPORT_RE = re.compile(
    r"""(?:from\s*|require\s*\(\s*|import\s+)['"]server-only['"]"""
)
EDGE_RUNTIME_RE = re.compile(r"""export\s+const\s+runtime\s*=\s*['"]edge['"]""")
IMAGES_DOMAINS_RE = re.compile(r"^\s*domains\s*:\s*\[")
EXPORT_ASYNC_RE = re.compile(r"export\s+(?:default\s+)?async\s+function\s")
# Single-argument revalidateTag: one balanced-free argument, no comma at depth 0.
REVALIDATE_TAG_RE = re.compile(r"revalidateTag\s*\(([^()]*)\)")
AUTH_TOKEN_RE = re.compile(
    r"\b(auth|getSession|getServerSession|currentUser|getUser|requireUser|session|"
    r"unauthorized|forbidden|verifySession|assertAuthorized|withAuth|getToken)\b",
    re.IGNORECASE,
)


def strip_comment(line: str) -> str:
    """Crude single-line comment strip. Good enough to keep `// revalidateTag(x)`
    out of the findings; deliberately does not parse block comments or strings."""
    stripped = line.lstrip()
    if stripped.startswith(("//", "*", "/*")):
        return ""
    idx = line.find("//")
    return line[:idx] if idx >= 0 else line


def file_directives(lines: list[str]) -> set[str]:
    """Module-level directives: those appearing before any real statement."""
    found: set[str] = set()
    for raw in lines[:20]:
        s = raw.strip()
        if not s or s.startswith(("//", "/*", "*")):
            continue
        m = DIRECTIVE_RE.match(raw)
        if m:
            found.add(m.group(1))
            continue
        break  # first non-directive statement ends the prologue
    return found


def any_directive(lines: list[str], prefix: str) -> list[int]:
    """1-indexed line numbers of every directive line starting with `prefix`,
    at module level or inside a function body."""
    out = []
    for i, raw in enumerate(lines, 1):
        m = DIRECTIVE_RE.match(raw)
        if m and m.group(1).startswith(prefix):
            out.append(i)
    return out


def iter_code_files(root: Path):
    if root.is_file():
        if root.suffix in CODE_SUFFIXES:
            yield root
        return
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in CODE_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def rel(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def detect_next_major(root: Path) -> tuple[int | None, str]:
    """Return (major, source). Prefer the *resolved* install over the manifest
    range: `"next": "^15.0.0"` in package.json can be satisfied by 15.5, and only
    node_modules knows which. Falls back to the declared range, then to nothing.
    """
    if root.is_file():
        root = root.parent
    for base in (root, root.parent):
        installed = base / "node_modules" / "next" / "package.json"
        if installed.is_file():
            try:
                ver = str(json.loads(installed.read_text(encoding="utf-8")).get("version", ""))
            except (OSError, json.JSONDecodeError):
                ver = ""
            m = re.match(r"\s*(\d+)", ver)
            if m:
                return int(m.group(1)), f"node_modules ({ver})"
        manifest = base / "package.json"
        if manifest.is_file():
            try:
                pkg = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            for field in ("dependencies", "devDependencies", "peerDependencies"):
                spec = (pkg.get(field) or {}).get("next")
                if not isinstance(spec, str):
                    continue
                # ^16.3.3, ~15.2, >=15 <17, 16.x - take the first number present.
                m = re.search(r"(\d+)", spec)
                if m:
                    return int(m.group(1)), f"package.json ({spec})"
                # "latest"/"canary"/a git URL carry no major we can trust.
                return None, f"package.json ({spec}) - no major to parse"
    return None, "not found"


def scan_file(path: Path, root: Path, in_app_tree: bool) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    lines = text.splitlines()
    where = rel(path, root)
    directives = file_directives(lines)
    is_client = "use client" in directives
    is_server_module = "use server" in directives
    cache_lines = any_directive(lines, "use cache")
    file_level_cache = any(d.startswith("use cache") for d in directives)
    imports_next_headers = "next/headers" in text
    findings: list[dict] = []

    def add(rule: str, line: int, detail: str, severity: str | None = None):
        findings.append({
            "severity": severity or RULES[rule][0],
            "rule": rule,
            "file": where,
            "line": line,
            "detail": detail,
        })

    for n, raw in enumerate(lines, 1):
        line = strip_comment(raw)
        if not line.strip():
            continue

        if imports_next_headers:
            for m in SYNC_REQ_RE.finditer(line):
                before = line[: m.start()]
                if AWAITED_RE.search(before) or "await" in before:
                    continue
                add("sync-request-api", n,
                    f"`{m.group(1)}()` is not awaited - it returns a Promise since Next.js 15")

        if in_app_tree:
            m = PARAMS_SYNC_TYPE_RE.search(line)
            if m and "Promise" not in line:
                add("sync-params-prop", n,
                    f"`{m.group(1)}` typed as a plain object - it is `Promise<...>` since Next.js 15")
            m = PARAMS_SYNC_DESTRUCTURE_RE.search(line)
            if m and "await" not in line:
                add("sync-params-prop", n,
                    f"`{m.group(1)}` destructured without `await`")

        if cache_lines:
            m = REQ_API_CALL_RE.search(line)
            if m and n > cache_lines[0]:
                sev = "error" if file_level_cache else "review"
                scope = "file-level 'use cache'" if file_level_cache else \
                        f"'use cache' at line {cache_lines[0]}"
                add("request-api-in-use-cache", n,
                    f"`{m.group(1)}()` reachable from {scope} - read it outside and pass the value as an argument",
                    severity=sev)
            m = NONDET_RE.search(line)
            if m and n > cache_lines[0] and file_level_cache:
                add("nondeterministic-in-use-cache", n,
                    f"`{m.group(1).strip()}` in a cached scope - one value is frozen into the cache entry for every user")

        if is_client:
            for m in CLIENT_ENV_RE.finditer(line):
                name = m.group(1)
                if name.startswith("NEXT_PUBLIC_") or name in ("NODE_ENV",):
                    continue
                add("client-secret-env", n,
                    f"`process.env.{name}` in a 'use client' module - inlined as an empty string, never the value")
            if SERVER_ONLY_IMPORT_RE.search(line):
                add("client-imports-server-only", n,
                    "'use client' module imports `server-only` - this is a build error by design")

        if EDGE_RUNTIME_RE.search(line):
            add("edge-runtime-segment", n,
                "`runtime = 'edge'` is the deprecated path; the Node.js runtime is the default and has no API gaps")

        for m in REVALIDATE_TAG_RE.finditer(line):
            arg = m.group(1).strip()
            if arg and "," not in arg:
                add("revalidate-tag-single-arg", n,
                    "single-argument `revalidateTag()` is deprecated - pass a cacheLife profile "
                    "(e.g. 'max') for SWR, or `updateTag()` in an action for read-your-writes")

        if path.name.startswith("next.config") and IMAGES_DOMAINS_RE.search(line):
            add("images-domains-config", n,
                "`images.domains` is deprecated - use `images.remotePatterns`")

    # Comments are stripped first: a `// TODO: check auth` note is precisely the
    # case this rule exists to flag, so it must not satisfy the token search.
    code_only = "\n".join(strip_comment(line) for line in lines)
    if is_server_module and EXPORT_ASYNC_RE.search(code_only) and not AUTH_TOKEN_RE.search(code_only):
        add("action-without-auth", 1,
            "'use server' module exports actions but names no auth/session check - "
            "every action is a public POST endpoint reachable without the UI")

    return findings


def scan_project(root: Path, major: int) -> tuple[list[dict], dict]:
    """Scan a project root or subtree. Returns (findings, meta-ish counters).
    `major` gates rules that only became true at a later Next.js version."""
    app_dirs = [d for d in (root / "app", root / "src" / "app") if d.is_dir()]
    findings: list[dict] = []
    files = 0

    for path in iter_code_files(root):
        files += 1
        in_app_tree = any(
            str(path).startswith(str(d)) for d in app_dirs
        ) or ("/app/" in path.as_posix() or path.as_posix().endswith("/app"))
        findings.extend(scan_file(path, root, in_app_tree))

    if root.is_dir():
        # Project-level structural checks: file conventions, not file contents.
        for base in (root, root / "src"):
            for name in ("middleware.ts", "middleware.js", "middleware.tsx"):
                mw = base / name
                if mw.is_file():
                    findings.append({
                        "severity": RULES["middleware-file"][0],
                        "rule": "middleware-file",
                        "file": rel(mw, root),
                        "line": 1,
                        "detail": "middleware.ts is deprecated since Next.js 16 - rename to proxy.ts "
                                  "and rename the export to `proxy` (npx @next/codemod@canary middleware-to-proxy .)",
                    })
        for slot in sorted(root.rglob("@*")):
            if not slot.is_dir() or any(p in SKIP_DIRS for p in slot.parts):
                continue
            if slot.name in ("@types",):
                continue
            if not any((slot / f"default{ext}").is_file() for ext in (".tsx", ".ts", ".jsx", ".js")):
                findings.append({
                    "severity": RULES["parallel-route-no-default"][0],
                    "rule": "parallel-route-no-default",
                    "file": rel(slot, root),
                    "line": 1,
                    "detail": f"parallel route slot `{slot.name}` has no default.js - "
                              "builds fail since Next.js 16; add one returning null or calling notFound()",
                })

    # Version gate, applied once at the end so a rule never has to know it.
    findings = [f for f in findings if major >= RULES[f["rule"]][1]]
    return findings, {"files_scanned": files}


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="audit-app-router.py",
        description="Static hazard scan of a Next.js App Router tree (boundary, caching, runtime).",
        epilog=(
            "Rules (severity, the Next.js major the rule first applies to, why):\n"
            + "".join(f"  {sev:<6} next>={mm:<3} {name:<30} {why}\n"
                      for name, (sev, mm, why) in sorted(RULES.items(), key=lambda kv: (-SEV_RANK[kv[1][0]], kv[0])))
            + "\nExamples:\n"
              "  audit-app-router.py .\n"
              "  audit-app-router.py --min-severity error src/app\n"
              "  audit-app-router.py --json . | jq '.data[] | select(.severity==\"error\")'\n"
              "  audit-app-router.py --rules sync-request-api,client-secret-env .\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("path", help="project root, app directory, or a single file")
    p.add_argument("--min-severity", choices=SEVERITIES, default="review",
                   help="drop findings below this severity (default: review = report all)")
    p.add_argument("--rules", default="",
                   help="comma-separated rule names to run (default: all)")
    p.add_argument("--assume-major", type=int, default=None, metavar="N",
                   help="treat the project as Next.js N.x instead of detecting it "
                        f"(detection falls back to {ASSUMED_MAJOR} when the version cannot be read)")
    p.add_argument("--limit", type=int, default=500,
                   help="maximum findings to emit (default: 500)")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    if args.limit < 1:
        print("error: --limit must be >= 1", file=sys.stderr)
        return EX_USAGE

    selected = set()
    if args.rules.strip():
        for name in args.rules.split(","):
            name = name.strip()
            if not name:
                continue
            if name not in RULES:
                print(f"error: unknown rule {name!r} (see --help for the rule list)", file=sys.stderr)
                return EX_USAGE
            selected.add(name)

    root = Path(args.path)
    if not root.exists():
        print(f"error: path not found: {root}", file=sys.stderr)
        return EX_NOTFOUND
    root = root.resolve()

    if args.assume_major is not None:
        if args.assume_major < 1:
            print("error: --assume-major must be >= 1", file=sys.stderr)
            return EX_USAGE
        major, source = args.assume_major, "--assume-major"
    else:
        detected, source = detect_next_major(root)
        major = detected if detected is not None else ASSUMED_MAJOR
        if detected is None:
            source = f"{source}; assuming {ASSUMED_MAJOR}.x"

    findings, meta = scan_project(root, major)

    floor = SEV_RANK[args.min_severity]
    findings = [f for f in findings if SEV_RANK[f["severity"]] >= floor]
    if selected:
        findings = [f for f in findings if f["rule"] in selected]
    findings.sort(key=lambda f: (-SEV_RANK[f["severity"]], f["file"], f["line"], f["rule"]))
    truncated = len(findings) > args.limit
    findings = findings[: args.limit]

    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"count": len(findings), "files_scanned": meta["files_scanned"],
                     "min_severity": args.min_severity, "truncated": truncated,
                     "next_major": major, "next_major_source": source,
                     "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"{f['severity']}\t{f['rule']}\t{f['file']}:{f['line']}\t{f['detail']}")

    if not args.quiet:
        by_sev = {s: sum(1 for f in findings if f["severity"] == s) for s in SEVERITIES}
        note = " (truncated)" if truncated else ""
        print(
            f"audit-app-router: {len(findings)} finding(s){note} in {meta['files_scanned']} file(s) "
            f"- {by_sev['error']} error, {by_sev['warn']} warn, {by_sev['review']} review "
            f"[next {major}.x via {source}]",
            file=sys.stderr,
        )

    return EX_FINDINGS if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
