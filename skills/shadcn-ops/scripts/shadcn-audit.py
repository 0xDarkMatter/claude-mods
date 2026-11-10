#!/usr/bin/env python3
"""Read-only audit of a shadcn/ui project: config, aliases, Tailwind and React lines,
the CLI pin, unpinned CLI use, and third-party registries.

Checks (finding ids):
  config-missing-field     components.json lacks a field the CLI requires
  style-unknown            style is not a known <base>-<style> or legacy name
  style-deprecated         style "default" (retired; new projects use a base-prefixed style)
  css-missing              tailwind.css names a file that does not exist
  tailwind-config-missing  tailwind.config names a file that does not exist
  tailwind-mismatch        components.json and the installed Tailwind disagree on v3 vs v4
                           (a v4 CSS file that loads the config with @config is fine)
  alias-unresolved         an alias matches no paths in the tsconfig.json (else jsconfig.json)
                           the CLI reads, following `extends`, nor package.json imports or a
                           workspace package (the CLI writes files that imports cannot find).
                           tsconfig.app.json is never read: the CLI does not read it either
  alias-missing            an alias resolves into a folder tree that does not exist
                           (components/ui/lib/hooks: the alias's parent folder is missing;
                           utils: the file is missing)
  shadcn-css-orphan        CSS imports "shadcn/tailwind.css" but no package.json declares
                           shadcn (the build cannot resolve the import)
  cli-not-installed        shadcn is not a project dependency, so CLI runs use a global or
                           downloaded copy (low when a sibling workspace declares it)
  cli-range-open           shadcn is declared as a dist-tag or wildcard (latest, *, x)
  cli-unlocked             shadcn is a range with no lockfile to fix the version
  cli-old-major            the project's shadcn is an older major than the skill's pin
  unpinned-cli             shadcn@latest, a dist-tag or range, or an unversioned dlx run, in
                           package.json scripts, README, AGENTS.md or CLAUDE.md
  unpinned-mcp             an MCP config (.mcp.json, .cursor/, .vscode/; JSON with comments
                           allowed) runs an unpinned shadcn
  third-party-registry     components.json configures a registry other than the built-in one
  registry-insecure-url    a registry URL is plain http:// (not localhost)
  registry-literal-secret  a registry header, param, URL query or URL password carries a
                           literal credential (the value is never printed)
  react-pre-19             React 18 or older with v4-era components (they take ref as a prop)
  monorepo-mismatch        style, iconLibrary or baseColor differ from the workspace an alias
                           points into (the monorepo docs require them to match)

Messages name fields, never config values that can carry a credential: an MCP finding
prints only the unpinned runner, and dependency specs and URLs are shown with userinfo
and query strings blanked.

The install root is the nearest folder with a lockfile that really locks the project: its
own package folder, or a workspace root whose patterns list it; the walk never crosses the
git root (.git dir or file). The package manager a fix names comes from package.json
"packageManager" first, then that lockfile, then npm - the same precedence as
shadcn-cmd.sh.

It never runs the shadcn CLI, a package manager or git, and never writes a file.

Usage:   shadcn-audit.py [DIR] [--json] [--ignore ID]... [--facts FILE] [-q]
         shadcn-audit.py --checks          # list every check id
Input:   DIR (default .) holding components.json; reads package.json files, lockfiles,
         tsconfig/jsconfig, the global CSS file, README/AGENTS.md/CLAUDE.md and MCP configs.
Output:  stdout = one TSV row per finding (severity, id, file[:line], message, fix), or the
         --json envelope {data:[...], meta:{count, schema, project, skipped}}
         (schema claude-mods.shadcn-ops.audit/v1). Data only.
Stderr:  the project summary line (style, base, Tailwind, React, CLI pin), notes, errors.
Exit:    0 clean, 2 usage, 3 no components.json in DIR (monorepo workspaces are named), or
         it is not a shadcn components.json (none of style, tailwind, aliases or a shadcn
         $schema), 4 components.json or the facts file is not valid JSON, or the facts file
         lacks a key the audit reads, 10 findings

Examples:
  shadcn-audit.py .
  shadcn-audit.py apps/web --json | jq -r '.data[] | "\\(.severity)\\t\\(.id)\\t\\(.file)"'
  shadcn-audit.py --ignore third-party-registry .
  shadcn-audit.py --json . | jq '.meta.project'
"""
# Sections: constants | JSON helpers | workspaces and the install root | tsconfig paths |
# alias resolution | lockfiles | the audit | main.
# One file by choice, not constraint (~1,100 lines): each script in this folder is a
# self-contained CLI with its contract in the docstring above. A sibling module WOULD import
# (run-python.sh runs the script by path, without -I), so splitting is allowed: do it by
# section when one passes ~300 lines, and keep this map and the "# === <section> ==="
# markers in step either way.
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

EX_OK, EX_USAGE, EX_NOTFOUND, EX_INVALID, EX_FINDINGS = 0, 2, 3, 4, 10
SCHEMA = "claude-mods.shadcn-ops.audit/v1"
HERE = Path(__file__).resolve().parent
DEFAULT_FACTS = HERE.parent / "assets" / "shadcn-facts.json"

CHECK_IDS = (
    "config-missing-field", "style-unknown", "style-deprecated", "css-missing",
    "tailwind-config-missing", "tailwind-mismatch", "alias-unresolved", "alias-missing",
    "shadcn-css-orphan", "cli-not-installed", "cli-range-open", "cli-unlocked", "cli-old-major",
    "unpinned-cli", "unpinned-mcp", "third-party-registry", "registry-insecure-url",
    "registry-literal-secret", "react-pre-19", "monorepo-mismatch",
)
SEV_ORDER = {"high": 0, "medium": 1, "low": 2}
LOCKFILES = ("pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "package-lock.json", "npm-shrinkwrap.json")
LOCK_PM = {"pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "bun.lock": "bun", "bun.lockb": "bun",
           "package-lock.json": "npm", "npm-shrinkwrap.json": "npm"}
# The local runner and the exact-pin install a fix should name, per package manager. Keep the
# runners in step with shadcn-cmd.sh's project prefixes: a fix that says `pnpm exec shadcn`
# in an npm project is wrong advice.
LOCAL_RUNNER = {"pnpm": "pnpm exec shadcn", "yarn": "yarn run shadcn",
                "bun": "bunx --no-install shadcn", "npm": "npx --no shadcn"}
INSTALL = {"pnpm": "pnpm add -D -E", "npm": "npm install -D -E", "yarn": "yarn add -D -E",
           "bun": "bun add -d --exact"}
EXACT_RE = re.compile(r"^\d+\.\d+\.\d+$")
# `shadcn@<spec>` not preceded by a name character (so @shadcn/button and foo-shadcn@ stay out).
# The spec stops at Markdown link/emphasis punctuation; TRAILING strips the rest, so
# "shadcn@4.23.0." and "**shadcn@4.23.0**:" read as the exact pin they are.
SPEC_RE = re.compile(r"(?<![\w/@.-])(?P<pkg>shadcn(?:-ui)?)@(?P<spec>[^\s\"'`),;\]]+)")
TRAILING = ".,:;*])"
# Runners that always fetch: an unversioned name there is the newest release, local copy or not.
ALWAYS_FETCH_RE = re.compile(
    r"\b(?P<runner>pnpm\s+dlx|pnpx|pnx|yarn\s+dlx)\s+(?:-{1,2}\S+\s+)*(?P<pkg>shadcn(?:-ui)?)(?![@\w-])")
# Runners that prefer a local bin: unversioned is a finding only when the repo does not declare shadcn.
LOCAL_FIRST_RE = re.compile(
    r"\b(?P<runner>npx|bunx|bun\s+x|npm\s+exec)\s+(?P<flags>(?:-{1,2}\S+\s+)*)(?P<pkg>shadcn(?:-ui)?)(?![@\w-])")
DOC_FILES = ("readme.md", "readme.mdx", "agents.md", "claude.md", ".claude/claude.md")  # lower-cased
MCP_FILES = (".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json")
SENSITIVE_RE = re.compile(r"auth|token|secret|key|password|cookie|session", re.I)
ENV_REF_RE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")
# Auth scheme words in front of an env reference ("token ${GITHUB_TOKEN}") are not a secret.
SCHEME_RE = re.compile(r"\b(?:bearer|basic|token)\b", re.I)
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
PROBE = "__shadcn_audit_probe__"
WALK_SKIP = {"node_modules"}  # plus every dot folder: never workspace members
WALK_DEPTH = 6


# === JSON helpers ===

def load_jsonc(path: Path):
    """tsconfig-style JSON: strip // and /* */ comments outside strings and trailing commas."""
    try:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return None
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True; out.append(c); i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    cleaned = re.sub(r",(\s*[}\]])", r"\1", "".join(out))
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        return None


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None


def load_obj(path: Path) -> dict:
    j = load_json(path)
    return j if isinstance(j, dict) else {}


def major_of(spec) -> int | None:
    m = re.search(r"\d+", str(spec or ""))
    return int(m.group()) if m else None


def line_of(path: Path, needle: str) -> int | None:
    try:
        for no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if needle in line:
                return no
    except OSError:
        pass
    return None


def redact(s) -> str:
    """A dependency spec or URL with userinfo and the query string blanked: either can carry
    a credential (https://user:token@host/x.tgz, ?token=...), and messages go to logs."""
    s = re.sub(r"(//)[^/@\s]+@", r"\1***@", str(s))
    return re.sub(r"\?[^\s#]*", "?***", s) if "://" in s else s


def dep_spec(pj: dict, name: str) -> str:
    for field in ("devDependencies", "dependencies"):
        deps = pj.get(field)
        if isinstance(deps, dict) and deps.get(name):
            return str(deps[name])
    return ""


# === Workspaces and the install root ===

def walk_up(start: Path, stop: Path | None):
    d = start
    while True:
        yield d
        if stop is not None and d == stop:
            return
        if d.parent == d:
            return
        d = d.parent


def git_root(start: Path) -> Path | None:
    """The nearest folder at or above start holding .git (a folder, or a worktree's file)."""
    for d in walk_up(start, None):
        if (d / ".git").exists():
            return d
    return None


def package_root(path: Path, stop: Path | None) -> Path | None:
    for d in walk_up(path if path.is_dir() else path.parent, stop):
        if (d / "package.json").is_file():
            return d
    return None


def _unquote(s: str) -> str:
    s = s.strip()
    return s[1:-1] if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"" else s


def _no_comment(s: str) -> str:
    return re.sub(r"\s+#.*$", "", s)


def yaml_packages(text: str) -> list[str]:
    """pnpm-workspace.yaml's top-level `packages:` list, block (- 'apps/*') or flow
    (['apps/*', 'packages/*']) style. Other keys' lists (catalog, onlyBuiltDependencies)
    are not workspace globs."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"packages\s*:(.*)$", line)
        if not m:
            continue
        rest = _no_comment(m.group(1)).strip()
        if rest.startswith("["):
            buf, j = rest, i
            while "]" not in buf and j + 1 < len(lines):
                j += 1
                buf += " " + _no_comment(lines[j])
            inner = buf[1:buf.index("]")] if "]" in buf else buf[1:]
            return [x for x in (_unquote(p) for p in inner.split(",")) if x]
        out = []
        for ln in lines[i + 1:]:
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            mm = re.match(r"\s*-\s*(.+)$", ln)
            if mm:
                out.append(_unquote(_no_comment(mm.group(1))))
            elif not ln[0].isspace():
                break  # the next top-level key
        return [x for x in out if x]
    return []


def workspace_globs(root: Path) -> tuple[list[str], list[str]]:
    """(include, exclude) workspace globs of a folder: pnpm-workspace.yaml `packages`, plus
    package.json "workspaces" (a list, or Yarn 1's {packages: [...]}). Empty: not a root."""
    pats: list[str] = []
    ws = root / "pnpm-workspace.yaml"
    if ws.is_file():
        try:
            pats += yaml_packages(ws.read_text(encoding="utf-8-sig", errors="replace"))
        except OSError:
            pass
    w = load_obj(root / "package.json").get("workspaces")
    if isinstance(w, dict):
        w = w.get("packages")
    if isinstance(w, list):
        pats += [p for p in w if isinstance(p, str)]
    norm = lambda p: re.sub(r"^(?:\./)+", "", p.strip()).rstrip("/")  # noqa: E731
    return [norm(p) for p in pats if not p.startswith("!")], [norm(p[1:]) for p in pats if p.startswith("!")]


def glob_re(pattern: str) -> re.Pattern:
    """A workspace glob as a regex over a /-separated relative path: ** spans folders,
    * and ? stay inside one (micromatch semantics, without braces)."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        elif pattern[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile(out + r"\Z")


def lists_member(root: Path, member: Path) -> bool:
    """Does the workspace root `root` list the folder `member` as one of its packages?"""
    try:
        rel = member.relative_to(root).as_posix()
    except ValueError:
        return False
    if rel in ("", "."):
        return False
    inc, exc = workspace_globs(root)
    return any(glob_re(p).match(rel) for p in inc) and not any(glob_re(p).match(rel) for p in exc)


def find_lockdir(start: Path, stop: Path | None, pkg: Path | None) -> tuple[Path | None, str]:
    """The install root: the nearest folder up to `stop` (the git root) whose lockfile really
    locks the project - the project itself, its package folder, or a workspace root listing
    that package. A stray lockfile above (a home folder, a parent checkout) once silenced
    cli-unlocked and picked the package manager for an unrelated project."""
    for d in walk_up(start, stop):
        lf = next((x for x in LOCKFILES if (d / x).is_file()), "")
        if lf and (d == start or d == pkg or (pkg is not None and lists_member(d, pkg))):
            return d, lf
    return None, ""


def _seg_could_match(segs: list[str], parts: list[str]) -> bool:
    """Could a folder below `parts` match the glob segments? (prunes the member walk)"""
    for i, part in enumerate(parts):
        if i >= len(segs):
            return False
        if segs[i] == "**":
            return True
        if not glob_re(segs[i]).match(part):
            return False
    return len(segs) > len(parts)


def workspace_packages(root: Path | None) -> dict[str, Path]:
    """name -> folder for a workspace root's packages. Globs (*, ?, **) are expanded by a
    walk that skips node_modules and dot folders: Path.glob("packages/**") would descend
    into node_modules and map every installed dependency's name to a folder."""
    if root is None:
        return {}
    inc, exc = workspace_globs(root)
    if not inc:
        return {}
    inc_re, exc_re = [glob_re(p) for p in inc], [glob_re(p) for p in exc]
    segs = [p.split("/") for p in inc]
    found: dict[str, Path] = {}

    def walk(folder: Path, parts: list[str]):
        try:
            entries = sorted(os.scandir(folder), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            if e.name in WALK_SKIP or e.name.startswith(".") or not e.is_dir():
                continue
            ps = parts + [e.name]
            rel = "/".join(ps)
            if any(r.match(rel) for r in inc_re) and not any(r.match(rel) for r in exc_re):
                name = load_obj(Path(e.path) / "package.json").get("name")
                if isinstance(name, str) and name not in found:
                    found[name] = Path(e.path)
            if len(ps) < WALK_DEPTH and any(_seg_could_match(s, ps) for s in segs):
                walk(Path(e.path), ps)

    walk(root, [])
    return found


# === tsconfig paths ===

def find_tsconfig(project: Path, stop: Path | None) -> Path | None:
    """The config the shadcn CLI reads: tsconfig-paths' loadConfig takes tsconfig.json, else
    jsconfig.json, from the project folder or the nearest one above (bounded here by the git
    root). It never reads tsconfig.app.json, where Vite projects also keep paths."""
    for d in walk_up(project, stop):
        for name in ("tsconfig.json", "jsconfig.json"):
            if (d / name).is_file():
                return d / name
    return None


def extends_target(spec: str, base: Path, workspaces: dict[str, Path]) -> Path | None:
    """The file an `extends` entry names: a relative path (".json" optional), or a package
    (@scope/name/sub.json, or name -> its package.json "tsconfig" or tsconfig.json) found in a
    node_modules above `base`, else in the monorepo's workspace packages."""
    def first_file(cands):
        return next((c for c in cands if c.is_file()), None)

    if spec.startswith(".") or os.path.isabs(spec):
        c = base / spec
        return first_file([c, Path(str(c) + ".json"), c / "tsconfig.json"])
    parts = spec.split("/")
    n = 2 if spec.startswith("@") else 1
    name, sub = "/".join(parts[:n]), "/".join(parts[n:])
    roots = [d / "node_modules" / name for d in walk_up(base, None)]
    if name in workspaces:
        roots.append(workspaces[name])
    for r in roots:
        if not r.is_dir():
            continue
        if sub:
            hit = first_file([r / sub, Path(str(r / sub) + ".json"), r / sub / "tsconfig.json"])
        else:
            t = load_obj(r / "package.json").get("tsconfig")
            hit = first_file(([r / t] if isinstance(t, str) else []) + [r / "tsconfig.json"])
        if hit:
            return hit
    return None


def ts_options(cfg_path: Path, workspaces: dict[str, Path], stack: tuple = ()) -> dict:
    """compilerOptions.paths and baseUrl after `extends` - a string or (TS 5.0+) a list
    whose later entries win - with the file's own values winning over all. Each value keeps
    the folder of the config that set it: TS resolves both relative to their own file."""
    if cfg_path in stack or len(stack) > 16:
        return {}
    cfg = load_jsonc(cfg_path)
    if not isinstance(cfg, dict):
        return {}
    ext = cfg.get("extends")
    exts = [ext] if isinstance(ext, str) else [e for e in ext if isinstance(e, str)] if isinstance(ext, list) else []
    out: dict = {}
    for e in exts:
        target = extends_target(e, cfg_path.parent, workspaces)
        if target is not None:
            out.update(ts_options(target, workspaces, stack + (cfg_path,)))
    co = cfg.get("compilerOptions") if isinstance(cfg.get("compilerOptions"), dict) else {}
    if isinstance(co.get("paths"), dict):
        out["paths"], out["paths_dir"] = co["paths"], cfg_path.parent
    if isinstance(co.get("baseUrl"), str):
        out["base_url"], out["base_dir"] = co["baseUrl"], cfg_path.parent
    return out


def ts_mappings(cfg_path: Path | None, workspaces: dict[str, Path]) -> list[tuple[str, list[str], Path]]:
    """(pattern, targets, base dir) for every paths entry of one config."""
    if cfg_path is None:
        return []
    o = ts_options(cfg_path, workspaces)
    if not o.get("paths"):
        return []
    root = (o["base_dir"] / o["base_url"]) if "base_url" in o else o["paths_dir"]
    return [(pat, [t for t in targets if isinstance(t, str)], root)
            for pat, targets in o["paths"].items() if isinstance(targets, list)]


# === Alias resolution ===

def match(pattern: str, spec: str):
    """TS paths / package exports matching with at most one '*': the star's text, or None."""
    if "*" not in pattern:
        return "" if pattern == spec else None
    pre, post = pattern.split("*", 1)
    if spec.startswith(pre) and spec.endswith(post) and len(spec) >= len(pre) + len(post):
        return spec[len(pre):len(spec) - len(post)]
    return None


def first_target(t):
    """A package.json exports/imports target: a string, a list, or a condition object."""
    if isinstance(t, str):
        return t
    if isinstance(t, list):
        for x in t:
            r = first_target(x)
            if r:
                return r
    if isinstance(t, dict):
        for k in ("import", "default", "require", "types"):
            if k in t:
                r = first_target(t[k])
                if r:
                    return r
        for v in t.values():
            r = first_target(v)
            if r:
                return r
    return None


def resolve_spec(spec: str, project: Path, workspaces: dict[str, Path], mappings) -> list[Path]:
    """Candidate filesystem paths for an import specifier, in resolution order."""
    out: list[Path] = []
    for pat, targets, root in mappings:
        star = match(pat, spec)
        if star is not None:
            out += [(root / t.replace("*", star)) for t in targets]
    pj = load_obj(project / "package.json")
    if spec.startswith("#") and isinstance(pj.get("imports"), dict):
        for pat, t in pj["imports"].items():
            star = match(pat, spec)
            tgt = first_target(t)
            if star is not None and tgt:
                out.append(project / tgt.replace("*", star))
    for name in sorted(workspaces, key=len, reverse=True):
        if spec == name or spec.startswith(name + "/"):
            pdir, sub = workspaces[name], spec[len(name):].lstrip("/")
            exports = load_obj(pdir / "package.json").get("exports")
            if isinstance(exports, dict):
                for pat, t in exports.items():
                    star = match(pat, "./" + sub)
                    tgt = first_target(t)
                    if star is not None and tgt:
                        out.append(pdir / tgt.replace("*", star))
            out += [pdir / sub, pdir / "src" / sub]
            break
    return out


def resolve_alias(alias: str, kind: str, project: Path, workspaces: dict[str, Path], mappings):
    """(path or None). kind 'dir' resolves the folder an alias stands for; 'file' a module."""
    if kind == "dir":
        for cand in resolve_spec(alias + "/" + PROBE, project, workspaces, mappings):
            s = str(cand)
            if PROBE in s:
                return Path(s[:s.index(PROBE)].rstrip("/\\"))
        return None
    cands = resolve_spec(alias, project, workspaces, mappings)
    for c in cands:
        for ext in ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.js"):
            p = Path(str(c) + ext)
            if p.is_file():
                return p
    return cands[0] if cands else None


# === Lockfiles ===

def _pnpm_importer_version(text: str, importer: str) -> str:
    """The version pnpm-lock.yaml resolved for shadcn in one importer (v6/v9 `importers:`,
    or the top-level dependency sections of a single-project lock)."""
    if re.search(r"(?m)^importers:\s*$", text):
        keys = {importer, f"'{importer}'", f'"{importer}"'}
        block, inside, mine = [], False, False
        for line in text.splitlines():
            if re.match(r"importers:\s*$", line):
                inside = True
                continue
            if not inside:
                continue
            if line and not line[0].isspace():
                break
            m = re.match(r"  (\S.*?):\s*$", line)
            if m:
                if mine:
                    break
                mine = m.group(1) in keys
            elif mine:
                block.append(line)
        body = "\n".join(block)
    else:
        body = re.split(r"(?m)^packages:\s*$", text, 1)[0]
    m = re.search(r"(?m)^\s+shadcn:\s*\n(?:\s+specifier:[^\n]*\n)?\s+version:\s*['\"]?(\d+\.\d+\.\d+)", body) \
        or re.search(r"(?m)^\s+shadcn:\s*['\"]?(\d+\.\d+\.\d+)", body)
    return m.group(1) if m else ""


def _yarn_entry_version(text: str, declared: str) -> str:
    """yarn.lock (classic or Berry): the entry whose key names the declared range."""
    first = ""
    for block in re.split(r"\n(?=\S)", text):
        head = block.split("\n", 1)[0].rstrip().rstrip(":")
        keys = {_unquote(k) for k in head.split(",")}
        if not any(k.startswith("shadcn@") for k in keys):
            continue
        m = re.search(r"(?m)^\s+version:?\s+\"?(\d+\.\d+\.\d+)", block)
        if not m:
            continue
        if declared and (f"shadcn@{declared}" in keys or f"shadcn@npm:{declared}" in keys):
            return m.group(1)
        first = first or m.group(1)
    return first


def locked_shadcn(lockdir: Path | None, lockfile: str, importer: str, declared: str) -> str:
    """The shadcn version the lockfile gives THIS project. A lock can also hold an older
    shadcn some other package depends on (once reported as the project's own), so the
    project's own entry comes first, then an exact declared version, then any entry."""
    if lockdir is None:
        return ""
    path = lockdir / lockfile
    if lockfile in ("package-lock.json", "npm-shrinkwrap.json"):
        j = load_obj(path)
        pk = j.get("packages") if isinstance(j.get("packages"), dict) else {}
        for key in ([f"{importer}/node_modules/shadcn"] if importer != "." else []) + ["node_modules/shadcn"]:
            if isinstance(pk.get(key), dict) and pk[key].get("version"):
                return str(pk[key]["version"])
        dep = (j.get("dependencies") or {}).get("shadcn") if isinstance(j.get("dependencies"), dict) else None
        return str(dep.get("version") or "") if isinstance(dep, dict) else ""
    if lockfile == "bun.lockb":  # binary: reported in meta.skipped instead
        return ""
    try:
        text = path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
    except OSError:
        return ""
    if lockfile == "pnpm-lock.yaml":
        own = _pnpm_importer_version(text, importer)
    elif lockfile == "yarn.lock":
        own = _yarn_entry_version(text, declared)
    else:  # bun.lock: the hoisted "shadcn": ["shadcn@x.y.z", ...] entry is the root's
        m = re.search(r"\"shadcn\":\s*\[\s*\"shadcn@(\d+\.\d+\.\d+)\"", text)
        own = m.group(1) if m else ""
    if own:
        return own
    if EXACT_RE.match(declared):
        return declared
    m = re.search({"pnpm-lock.yaml": r"(?m)^\s+/?'?shadcn@(\d+\.\d+\.\d+)",
                   "bun.lock": r"\"shadcn@(\d+\.\d+\.\d+)\""}.get(lockfile, r"$^"), text)
    return m.group(1) if m else ""


# === The audit ===

class Audit:
    def __init__(self, project: Path, facts: dict, ignore: set[str]):
        self.project, self.facts, self.ignore = project, facts, ignore
        self.findings: list[dict] = []
        self.skipped: list[dict] = []
        self.summary: dict = {}

    def add(self, sev, cid, file, line, message, fix):
        if cid in self.ignore:
            return
        self.findings.append({"severity": sev, "id": cid, "file": file, "line": line,
                              "message": message, "fix": fix})

    def rel(self, p: Path) -> str:
        try:
            return p.resolve().relative_to(self.project.resolve()).as_posix()
        except ValueError:
            return p.as_posix()

    def run(self, cfg: dict):
        p, facts = self.project, self.facts
        cj = p / "components.json"
        pin = facts["cli"]["version"]
        stop = git_root(p)
        pkg = package_root(p, stop)
        lockdir, lockfile = find_lockdir(p, stop, pkg)
        chain = [d for d in walk_up(p, lockdir) if (d / "package.json").is_file()] if lockdir else \
            ([pkg] if pkg is not None else [])
        deps: dict[str, str] = {}
        pm_field = ""
        for d in chain:  # nearest first
            j = load_obj(d / "package.json")
            if not pm_field and isinstance(j.get("packageManager"), str):
                pm_field = j["packageManager"].split("@", 1)[0]
        for d in reversed(chain):  # nearest package.json wins
            j = load_obj(d / "package.json")
            for field in ("dependencies", "devDependencies"):
                if isinstance(j.get(field), dict):
                    deps.update({k: str(v) for k, v in j[field].items()})
        # Same precedence as shadcn-cmd.sh: packageManager, then the lockfile, then npm.
        pm = pm_field if pm_field in LOCAL_RUNNER else LOCK_PM.get(lockfile, "npm")
        runner, install = LOCAL_RUNNER[pm], INSTALL[pm]
        workspaces = workspace_packages(lockdir)

        # --- required fields ---
        tw = cfg.get("tailwind") if isinstance(cfg.get("tailwind"), dict) else {}
        aliases = cfg.get("aliases") if isinstance(cfg.get("aliases"), dict) else {}
        missing = [k for k in ("style", "tailwind", "rsc", "aliases") if k not in cfg]
        missing += [f"tailwind.{k}" for k in ("config", "css", "baseColor", "cssVariables") if "tailwind" in cfg and k not in tw]
        missing += [f"aliases.{k}" for k in ("utils", "components") if "aliases" in cfg and k not in aliases]
        if missing:
            self.add("high", "config-missing-field", "components.json", None,
                     f"missing required field(s): {', '.join(missing)}",
                     "restore them (schema https://ui.shadcn.com/schema.json); the CLI refuses or guesses without them")

        # --- style and base ---
        style = str(cfg.get("style", ""))
        base, _, sname = style.partition("-")
        if style in facts["legacy_styles"]:
            base, sname = "radix", style
            if style == "default":
                self.add("low", "style-deprecated", "components.json", line_of(cj, '"style"'),
                         'style "default" is retired; its components no longer get updates',
                         "keep it, or move to a base-prefixed style with a planned re-add (references/migrations-and-eject.md)")
        elif style and (base not in facts["bases"] or sname not in facts["style_names"]):
            self.add("medium", "style-unknown", "components.json", line_of(cj, '"style"'),
                     f'style "{style}" is not <base>-<style> with base in {sorted(facts["bases"])} '
                     f'and style in {facts["style_names"]}',
                     "fix the typo; style cannot change after init without re-adding components")
            base = base if base in facts["bases"] else "unknown"

        # --- Tailwind line and the CSS file ---
        css_rel = str(tw.get("css", "")) if tw else ""
        css_path = (p / css_rel) if css_rel else None
        css_text = ""
        if css_path is not None:
            if css_path.is_file():
                css_text = css_path.read_text(encoding="utf-8", errors="replace")
            else:
                self.add("high", "css-missing", "components.json", line_of(cj, '"css"'),
                         f"tailwind.css points at {css_rel}, which does not exist",
                         "point it at the global CSS file that imports Tailwind (relative to components.json)")
        tw_dep = major_of(deps.get("tailwindcss")) if deps.get("tailwindcss") else None
        css_v = 4 if re.search(r"""@import\s+["']tailwindcss["']""", css_text) else \
            3 if re.search(r"@tailwind\s+(base|components|utilities)", css_text) else None
        tw_major = tw_dep or css_v
        config_val = str(tw.get("config", "")) if tw else ""
        if config_val and not (p / config_val).is_file():
            self.add("medium", "tailwind-config-missing", "components.json", line_of(cj, '"config"'),
                     f"tailwind.config points at {config_val}, which does not exist",
                     'v3: point it at tailwind.config.js/.ts; v4: set it to ""')
        if tw_major == 3 and not config_val and "tailwind" in cfg:
            self.add("medium", "tailwind-mismatch", "components.json", line_of(cj, '"config"'),
                     'tailwind.config is empty (the v4 setting) but the project runs Tailwind v3',
                     "set tailwind.config to the v3 config file, or upgrade to v4 first (references/migrations-and-eject.md)")
        # v4 may still load a JS config through `@config` in the CSS (Payload's website
        # template does); the CLI then needs tailwind.config, so "" would break it.
        elif tw_major == 4 and config_val and not re.search(r"(?m)^\s*@config\s", css_text):
            self.add("low", "tailwind-mismatch", "components.json", line_of(cj, '"config"'),
                     f"Tailwind v4 project but tailwind.config is {config_val!r} and the CSS has no @config",
                     'set it to "" (the docs: leave it blank for v4) so theme edits go to @theme inline')

        # --- aliases ---
        cfg_path = find_tsconfig(p, stop)
        mappings = ts_mappings(cfg_path, workspaces)
        app_cfg = p / "tsconfig.app.json"
        app_maps = ts_mappings(app_cfg, workspaces) if app_cfg.is_file() and app_cfg != cfg_path else []
        resolved: dict[str, Path] = {}
        for key in ("components", "ui", "lib", "hooks", "utils"):
            val = aliases.get(key)
            if not isinstance(val, str) or not val:
                continue
            kind = "file" if key == "utils" else "dir"
            target = resolve_alias(val, kind, p, workspaces, mappings)
            ln = line_of(cj, f'"{key}"')
            if target is None:
                app_only = resolve_alias(val, kind, p, {}, app_maps) is not None if app_maps else False
                if app_only:
                    self.add("high", "alias-unresolved", "components.json", ln,
                             f'aliases.{key} = "{val}": paths are only in tsconfig.app.json; the CLI reads tsconfig.json',
                             "add the same compilerOptions.paths to tsconfig.json (the shadcn Vite guide sets it in both)")
                else:
                    self.add("high", "alias-unresolved", "components.json", ln,
                             f'aliases.{key} = "{val}" matches no tsconfig/jsconfig paths, package.json imports or workspace package',
                             "add the matching paths entry (both tsconfig.json and tsconfig.app.json in Vite), or fix the alias")
                continue
            resolved[key] = target
            if kind == "file":
                if not target.is_file():
                    self.add("medium", "alias-missing", "components.json", ln,
                             f'aliases.utils = "{val}" resolves to {self.rel(target)}, which does not exist',
                             "restore lib/utils.ts (it exports cn), or fix the alias")
            elif not target.is_dir() and not target.parent.is_dir():
                self.add("high", "alias-missing", "components.json", ln,
                         f'aliases.{key} = "{val}" resolves to {self.rel(target)}, and {self.rel(target.parent)} does not exist either',
                         "the paths mapping and the folder layout disagree (often a src/ prefix); fix whichever is wrong before adding components")
        self.summary["aliases"] = {k: self.rel(v) for k, v in resolved.items()}

        # --- where shadcn may be declared: the package.json chain, plus the workspace that
        #     holds the CSS file and the ones aliases point into (monorepos keep it in packages/ui) ---
        decl_roots = list(chain)
        for path in [css_path] + list(resolved.values()):
            if path is not None:
                r = package_root(path, lockdir or p)
                if r is not None and r not in decl_roots:
                    decl_roots.append(r)
        declared, decl_dir = "", None
        for d in decl_roots:
            spec = dep_spec(load_obj(d / "package.json"), "shadcn")
            if spec:
                declared, decl_dir = spec, d
                break
        locked = ""
        for d in decl_roots:
            v = load_obj(d / "node_modules" / "shadcn" / "package.json").get("version")
            if v:
                locked = str(v)
                break
        if not locked and lockdir is not None and declared:  # else any lock entry is someone else's
            try:
                importer = (decl_dir or p).resolve().relative_to(lockdir.resolve()).as_posix() or "."
            except ValueError:
                importer = "."
            locked = locked_shadcn(lockdir, lockfile, importer, declared)
        if lockfile == "bun.lockb" and not locked:
            self.skipped.append({"check": "shadcn_locked", "reason": "bun.lockb is binary; run `bun install --save-text-lockfile` to get bun.lock"})
        pin_major = int(facts["cli"]["major"])
        css_imports_shadcn = bool(re.search(r"""@import\s+["']shadcn/tailwind\.css["']""", css_text))
        if not declared:
            if css_imports_shadcn:
                self.add("high", "shadcn-css-orphan", self.rel(css_path), line_of(css_path, "shadcn/tailwind.css"),
                         'imports "shadcn/tailwind.css" but no package.json declares shadcn; the build cannot resolve it',
                         f"{install} shadcn@{pin}, or run `shadcn eject` to inline the file (irreversible)")
            else:
                sibling = self.sibling_declaring(workspaces, decl_roots, lockdir, pkg)
                if sibling:
                    where, spec, routes_here, back = sibling
                    how = ("its components.json routes components here" if routes_here
                           else f"`{runner} <command> --cwd {back}`")
                    self.add("low", "cli-not-installed", "package.json", None,
                             f"shadcn is not a dependency of this workspace, but {where} declares it",
                             f"run the CLI from {where} (shadcn {redact(spec)}): {how}; "
                             f"or add it here: {install} shadcn@{pin}")
                else:
                    self.add("medium", "cli-not-installed", "package.json", None,
                             "shadcn is not a project dependency, so CLI runs use a global or downloaded copy "
                             "that can differ from your teammates'",
                             f"{install} shadcn@{pin} and run it with the local runner (scripts/shadcn-cmd.sh)")
        else:
            shown = redact(declared)
            if declared.strip() in ("*", "x", "") or declared.strip() in self.facts["dist_tags"]:
                self.add("medium", "cli-range-open", "package.json", None,
                         f'shadcn is declared as "{shown}", so every lock refresh takes the newest release',
                         f"pin it: shadcn@{pin}")
            elif not EXACT_RE.match(declared) and lockdir is None:
                self.add("medium", "cli-unlocked", "package.json", None,
                         f'shadcn is "{shown}" with no lockfile, so each install may resolve a different version',
                         "commit a lockfile, or pin the exact version")
            have = major_of(locked or declared)
            if have is not None and have < pin_major:
                self.add("low", "cli-old-major", "package.json", None,
                         f"the project's shadcn is {redact(locked or declared)}; the skill documents {pin_major}.x "
                         "(apply, preset, eject, docs and info --json need it)",
                         "upgrade the devDependency in its own commit (references/cli-and-pinning.md)")

        # --- unpinned CLI in scripts, docs and MCP configs ---
        def unpinned_in(text: str) -> list[str]:
            """Each unpinned run, printed as runner + package or package@spec only: the rest
            of the line (flags, env assignments, headers) can carry a credential."""
            hits: list[str] = []
            for m in SPEC_RE.finditer(text):
                spec = m.group("spec").rstrip(TRAILING)
                if m.group("pkg") == "shadcn-ui" or not EXACT_RE.match(spec):
                    hits.append(f"{m.group('pkg')}@{redact(spec)}")
            for m in ALWAYS_FETCH_RE.finditer(text):
                hits.append(f"{' '.join(m.group('runner').split())} {m.group('pkg')}")
            for m in LOCAL_FIRST_RE.finditer(text):
                if m.group("pkg") == "shadcn-ui" or (not declared and not re.search(r"--no(-install)?\b", m.group("flags"))):
                    hits.append(f"{' '.join(m.group('runner').split())} {m.group('pkg')}")
            return list(dict.fromkeys(hits))

        pj_path = p / "package.json"
        pj = load_obj(pj_path)
        for name, cmd in (pj.get("scripts") or {}).items():
            for hit in unpinned_in(str(cmd)):
                self.add("medium", "unpinned-cli", "package.json", line_of(pj_path, f'"{name}"'),
                         f'script "{name}" runs {hit!r}',
                         "call the devDependency (`shadcn ...` inside scripts) or an exact shadcn@x.y.z")
        # Match names from the real listing: on a case-insensitive filesystem README.md and
        # readme.md are one file, and probing both would report every hit twice.
        docs = []
        for folder in (p, p / ".claude"):
            if folder.is_dir():
                for entry in sorted(folder.iterdir()):
                    rel = entry.relative_to(p).as_posix()
                    if entry.is_file() and rel.lower() in DOC_FILES:
                        docs.append((rel, entry))
        for rel, f in docs:
            for no, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                for hit in unpinned_in(line):
                    self.add("medium", "unpinned-cli", rel, no, f"{hit!r} floats to whatever release is newest",
                             f"document the project's runner ({runner} ...) or shadcn@{pin}")
        for rel in MCP_FILES:
            f = p / rel
            j = load_jsonc(f) if f.is_file() else None  # VS Code and Cursor allow comments
            if not isinstance(j, dict):
                continue
            servers = j.get("mcpServers") or j.get("servers") or {}
            for sname_, conf in (servers.items() if isinstance(servers, dict) else []):
                if not isinstance(conf, dict):
                    continue
                args = conf.get("args") if isinstance(conf.get("args"), list) else []
                cmdline = " ".join([str(conf.get("command", ""))] + [str(a) for a in args])
                hits = unpinned_in(cmdline) if "shadcn" in cmdline else []
                if hits:
                    self.add("medium", "unpinned-mcp", rel, line_of(f, f'"{sname_}"'),
                             f'MCP server "{sname_}" runs {", ".join(repr(h) for h in hits)} in every session',
                             "remove it (references/mcp.md), or pin it as in assets/mcp.json.example")

        # --- third-party registries (fields are named, values never printed) ---
        regs = cfg.get("registries") if isinstance(cfg.get("registries"), dict) else {}
        for ns, conf in regs.items():
            url = conf if isinstance(conf, str) else (conf.get("url", "") if isinstance(conf, dict) else "")
            parts = urlsplit(str(url))
            host = parts.hostname or "?"
            ln = line_of(cj, f'"{ns}"')
            self.add("medium", "third-party-registry", "components.json", ln,
                     f"{ns} -> {host}: code from this registry is untrusted until reviewed",
                     f"view, then add --dry-run and --diff each file before any add from {ns} (references/supply-chain-and-registries.md)")
            if parts.scheme == "http" and host not in LOCAL_HOSTS:
                self.add("high", "registry-insecure-url", "components.json", ln,
                         f"{ns} is fetched over plain http from {host}",
                         "use https; anyone on the path can rewrite the code you install")
            literal = []
            if parts.password and not ENV_REF_RE.search(parts.password):
                literal.append("URL password")
            for k, v in parse_qsl(parts.query):
                if SENSITIVE_RE.search(k) and v and not ENV_REF_RE.search(v):
                    literal.append(f"URL query {k}")
            if isinstance(conf, dict):
                for field in ("headers", "params"):
                    for k, v in (conf.get(field) or {}).items() if isinstance(conf.get(field), dict) else []:
                        rest = SCHEME_RE.sub("", ENV_REF_RE.sub("", str(v))).strip()
                        if SENSITIVE_RE.search(str(k)) and rest:
                            literal.append(f"{field}.{k}")
            if literal:
                self.add("high", "registry-literal-secret", "components.json", ln,
                         f"{ns} carries a literal credential in {', '.join(literal)} (value not shown)",
                         "rotate it, then reference an environment variable: ${REGISTRY_TOKEN} (kept in .env.local, never committed)")

        # --- React line ---
        react_v = load_obj(p / "node_modules" / "react" / "package.json").get("version") or deps.get("react", "")
        react_major = major_of(react_v) if react_v and not str(react_v).startswith(("latest", "*")) else None
        # A legacy style (new-york/default) on Tailwind v3 is the React 18 track and stays fine.
        modern = tw_major == 4 or (style not in facts["legacy_styles"] and base in facts["bases"])
        if react_major is not None and react_major < 19 and modern:
            self.add("medium", "react-pre-19", "package.json", None,
                     f"React {redact(react_v)} with v4-era components, which take ref as a plain prop (React 19); on 18 refs never reach the DOM",
                     "upgrade React to 19 first, or stay on the v3/new-york components (references/migrations-and-eject.md)")

        # --- monorepo: the workspace an alias points into must agree ---
        seen: set[Path] = set()
        for key, path in resolved.items():
            r = package_root(path, lockdir or p)
            if r is None or r.resolve() == p.resolve() or r in seen or not (r / "components.json").is_file():
                continue
            seen.add(r)
            other = load_obj(r / "components.json")
            diffs = []
            for label, a, b in (("style", cfg.get("style"), other.get("style")),
                                ("iconLibrary", cfg.get("iconLibrary"), other.get("iconLibrary")),
                                ("tailwind.baseColor", tw.get("baseColor"), (other.get("tailwind") or {}).get("baseColor"))):
                if a != b:
                    diffs.append(f"{label} {a!r} vs {b!r}")
            if diffs:
                self.add("high", "monorepo-mismatch", "components.json", None,
                         f"differs from {self.rel(r / 'components.json')}: {'; '.join(diffs)}",
                         "make style, iconLibrary and baseColor identical in every workspace's components.json")

        self.summary.update({
            "style": style or None, "base": base or None, "tailwind": f"v{tw_major}" if tw_major else "unknown",
            "react": redact(react_v) or None, "shadcn_declared": redact(declared) or None, "shadcn_locked": locked or None,
            "pin": pin, "package_manager": pm, "package_manager_lockfile": lockfile or None,
            "registries": sorted(regs), "rsc": cfg.get("rsc"), "iconLibrary": cfg.get("iconLibrary"),
        })

    def sibling_declaring(self, workspaces: dict[str, Path], mine: list[Path], root: Path | None,
                          pkg: Path | None):
        """(folder relative to the workspace root, spec, routes_here, path back to this
        project) of another workspace that declares shadcn: in a monorepo the CLI usually
        lives in one app (apps/web), not packages/ui. Preferred: a workspace whose
        components.json aliases point into this package (shadcn's monorepo layout: running
        there writes ui files here), then any with a components.json, then any."""
        if root is None:
            return None
        own = {d.resolve() for d in mine}
        name = load_obj(pkg / "package.json").get("name") if pkg is not None else None
        best = None
        for d in sorted(workspaces.values(), key=lambda x: x.as_posix()):
            if d.resolve() in own:
                continue
            spec = dep_spec(load_obj(d / "package.json"), "shadcn")
            if not spec:
                continue
            other = load_obj(d / "components.json")
            vals = [str(v) for v in (other.get("aliases") or {}).values()] if isinstance(other.get("aliases"), dict) else []
            routes = isinstance(name, str) and any(v == name or v.startswith(name + "/") for v in vals)
            rank = 0 if routes else 1 if other else 2
            if best is None or rank < best[0]:
                best = (rank, d, spec, routes)
        if best is None:
            return None
        _, d, spec, routes = best
        try:
            where = d.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            where = d.as_posix()
        try:
            back = Path(os.path.relpath(self.project, d.resolve())).as_posix()
        except ValueError:  # another drive on Windows
            back = self.project.as_posix()
        return where, spec, routes, back


def monorepo_hint(p: Path) -> list[str]:
    hits = []
    for pat in ("apps/*/components.json", "packages/*/components.json"):
        hits += [x.parent.relative_to(p).as_posix() for x in sorted(p.glob(pat))]
    return hits


def facts_problem(facts) -> str | None:
    """Why the facts catalog cannot drive the audit, or None. Every key the audit reads is
    checked here, so a bad catalog is exit 4, never a KeyError traceback (exit 1)."""
    if not isinstance(facts, dict):
        return "missing or not a JSON object"
    cli = facts.get("cli")
    if not isinstance(cli, dict):
        return "cli must be an object"
    if not EXACT_RE.match(str(cli.get("version", ""))):
        return "cli.version must be an exact x.y.z"
    if not str(cli.get("major", "")).isdigit():
        return "cli.major must be a major number"
    for key in ("legacy_styles", "style_names", "dist_tags"):
        v = facts.get(key)
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            return f"{key} must be a list of names"
    if not isinstance(facts.get("bases"), dict) or not facts["bases"]:
        return "bases must be a non-empty object"
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="shadcn-audit.py",
        description="Read-only audit of a shadcn/ui project (components.json, aliases, Tailwind, React, CLI pin, registries).",
        epilog=("Examples:\n  shadcn-audit.py .\n  shadcn-audit.py apps/web --json | jq '.data[]'\n"
                "  shadcn-audit.py --ignore third-party-registry .\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", nargs="?", default=".", help="project folder holding components.json (default .)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope")
    ap.add_argument("--ignore", action="append", default=[], metavar="ID", help="skip a check (repeatable)")
    ap.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalog (default assets/shadcn-facts.json)")
    ap.add_argument("-q", "--quiet", action="store_true", help="no summary line on stderr")
    ap.add_argument("--checks", action="store_true", help="print every check id, one per line, and exit")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    if args.checks:
        print("\n".join(CHECK_IDS))
        return EX_OK

    def error(code: str, msg: str, rc: int) -> int:
        if args.json:
            print(json.dumps({"error": {"code": code, "message": msg}}))
        print(f"shadcn-audit: {msg}", file=sys.stderr)
        return rc

    bad = [i for i in args.ignore if i not in CHECK_IDS]
    if bad:
        return error("USAGE", f"unknown check id(s) for --ignore: {', '.join(bad)}", EX_USAGE)
    shown = Path(args.dir)
    if not shown.is_dir():
        return error("NOT_FOUND", f"directory not found: {shown}", EX_NOTFOUND)
    # Absolute, so the walks up to the git root and the install root see the real parents
    # ("." has no parent to walk to).
    project = shown.resolve()
    facts = load_json(Path(args.facts))
    problem = facts_problem(facts)
    if problem:
        return error("VALIDATION", f"facts catalog {args.facts}: {problem}", EX_INVALID)
    cj = project / "components.json"
    if not cj.is_file():
        hint = monorepo_hint(project)
        extra = f"; this looks like a monorepo root - audit each workspace: {', '.join(hint)}" if hint else ""
        return error("NOT_FOUND", f"no components.json in {shown}{extra}", EX_NOTFOUND)
    cfg = load_json(cj)
    if not isinstance(cfg, dict):
        return error("VALIDATION", f"{shown / 'components.json'} is not valid JSON", EX_INVALID)
    # Other tools use the same file name (design-system manifests, Storybook addons).
    if not (any(k in cfg for k in ("style", "tailwind", "aliases")) or "shadcn" in str(cfg.get("$schema", ""))):
        return error("NOT_FOUND", f"{shown / 'components.json'} is not a shadcn components.json "
                                  "(no style, tailwind, aliases or shadcn $schema)", EX_NOTFOUND)

    audit = Audit(project, facts, set(args.ignore))
    audit.run(cfg)
    rows = sorted(audit.findings, key=lambda f: (SEV_ORDER[f["severity"]], f["id"], f["file"], f["line"] or 0))
    if args.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "schema": SCHEMA,
                                                 "project": audit.summary, "skipped": audit.skipped}}, indent=2))
    else:
        for f in rows:
            where = f"{f['file']}:{f['line']}" if f["line"] else f["file"]
            print(f"{f['severity']}\t{f['id']}\t{where}\t{f['message']}\t{f['fix']}")
    if not args.quiet:
        s = audit.summary
        print(f"shadcn-audit: {s.get('style')} (base {s.get('base')}), Tailwind {s.get('tailwind')}, "
              f"React {s.get('react') or '?'}, shadcn {s.get('shadcn_declared') or 'not declared'}"
              f"{' (locked ' + s['shadcn_locked'] + ')' if s.get('shadcn_locked') else ''}, pin {s.get('pin')} | "
              f"{len(rows)} finding(s)", file=sys.stderr)
    return EX_FINDINGS if rows else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
