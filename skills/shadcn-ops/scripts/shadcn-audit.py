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
  alias-unresolved         an alias matches no tsconfig/jsconfig paths, package.json
                           imports or workspace package (the CLI writes files that imports
                           cannot find)
  alias-missing            an alias resolves into a folder tree that does not exist
                           (components/ui/lib/hooks: the alias's parent folder is missing;
                           utils: the file is missing)
  shadcn-css-orphan        CSS imports "shadcn/tailwind.css" but no package.json declares
                           shadcn (the build cannot resolve the import)
  cli-not-installed        shadcn is not a dependency, so every run downloads a CLI
  cli-range-open           shadcn is declared as a dist-tag or wildcard (latest, *, x)
  cli-unlocked             shadcn is a range with no lockfile to fix the version
  cli-old-major            the project's shadcn is an older major than the skill's pin
  unpinned-cli             shadcn@latest, a dist-tag or range, or an unversioned dlx run, in
                           package.json scripts, README, AGENTS.md or CLAUDE.md
  unpinned-mcp             an MCP config (.mcp.json, .cursor/, .vscode/) runs an unpinned shadcn
  third-party-registry     components.json configures a registry other than the built-in one
  registry-insecure-url    a registry URL is plain http:// (not localhost)
  registry-literal-secret  a registry header, param or URL query carries a literal credential
                           (the value is never printed)
  react-pre-19             React 18 or older with v4-era components (they take ref as a prop)
  monorepo-mismatch        style, iconLibrary or baseColor differ from the workspace an alias
                           points into (the monorepo docs require them to match)

It never runs the shadcn CLI, a package manager or git, and never writes a file.

Usage:   shadcn-audit.py [DIR] [--json] [--ignore ID]... [--facts FILE] [-q]
         shadcn-audit.py --checks          # list every check id
Input:   DIR (default .) holding components.json; reads package.json files, lockfiles,
         tsconfig/jsconfig, the global CSS file, README/AGENTS.md/CLAUDE.md and MCP configs.
Output:  stdout = one TSV row per finding (severity, id, file[:line], message, fix), or the
         --json envelope {data:[...], meta:{count, schema, project, skipped}}
         (schema claude-mods.shadcn-ops.audit/v1). Data only.
Stderr:  the project summary line (style, base, Tailwind, React, CLI pin), notes, errors.
Exit:    0 clean, 2 usage, 3 no components.json in DIR (monorepo workspaces are named),
         4 components.json or the facts file is not valid JSON, 10 findings

Examples:
  shadcn-audit.py .
  shadcn-audit.py apps/web --json | jq -r '.data[] | "\\(.severity)\\t\\(.id)\\t\\(.file)"'
  shadcn-audit.py --ignore third-party-registry .
  shadcn-audit.py --json . | jq '.meta.project'
"""
from __future__ import annotations

import argparse
import json
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
# The local runner a fix should name, per lockfile. Keep in step with shadcn-cmd.sh's
# project prefixes: a fix that says `pnpm exec shadcn` in an npm project is wrong advice.
LOCAL_RUNNER = {
    "pnpm-lock.yaml": "pnpm exec shadcn", "yarn.lock": "yarn run shadcn",
    "bun.lock": "bunx --no-install shadcn", "bun.lockb": "bunx --no-install shadcn",
    "package-lock.json": "npx --no shadcn", "npm-shrinkwrap.json": "npx --no shadcn",
}
EXACT_RE = re.compile(r"^\d+\.\d+\.\d+$")
# `shadcn@<spec>` not preceded by a name character (so @shadcn/button and foo-shadcn@ stay out).
SPEC_RE = re.compile(r"(?<![\w/@.-])(shadcn(?:-ui)?)@([^\s\"'`),;]+)")
# Runners that always fetch: an unversioned name there is the newest release, local copy or not.
ALWAYS_FETCH_RE = re.compile(r"\b(?:pnpm\s+dlx|pnpx|pnx|yarn\s+dlx)\s+(?:-{1,2}\S+\s+)*(shadcn(?:-ui)?)(?![@\w-])")
# Runners that prefer a local bin: unversioned is a finding only when the repo does not declare shadcn.
LOCAL_FIRST_RE = re.compile(r"\b(npx|bunx|bun\s+x|npm\s+exec)\s+((?:-{1,2}\S+\s+)*)(shadcn(?:-ui)?)(?![@\w-])")
DOC_FILES = ("readme.md", "readme.mdx", "agents.md", "claude.md", ".claude/claude.md")  # lower-cased
MCP_FILES = (".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json")
SENSITIVE_RE = re.compile(r"auth|token|secret|key|password|cookie|session", re.I)
ENV_REF_RE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
PROBE = "__shadcn_audit_probe__"


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
    except (OSError, json.JSONDecodeError):
        return None


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


# === Project layout ===

def walk_up(start: Path, stop: Path | None):
    d = start
    while True:
        yield d
        if stop is not None and d == stop:
            return
        if d.parent == d:
            return
        d = d.parent


def find_lockdir(start: Path) -> tuple[Path | None, str]:
    for d in walk_up(start, None):
        for lf in LOCKFILES:
            if (d / lf).is_file():
                return d, lf
    return None, ""


def package_root(path: Path, stop: Path | None) -> Path | None:
    for d in walk_up(path if path.is_dir() else path.parent, stop):
        if (d / "package.json").is_file():
            return d
    return None


def workspace_packages(root: Path | None) -> dict[str, Path]:
    """name -> folder for the monorepo's workspace packages (simple dir/* and exact patterns)."""
    if root is None:
        return {}
    patterns: list[str] = []
    ws = root / "pnpm-workspace.yaml"
    if ws.is_file():
        for line in ws.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"\s*-\s*['\"]?([^'\"#]+?)['\"]?\s*$", line)
            if m and not m.group(1).startswith("!"):
                patterns.append(m.group(1).strip())
    pj = load_json(root / "package.json") or {}
    w = pj.get("workspaces")
    if isinstance(w, dict):
        w = w.get("packages")
    if isinstance(w, list):
        patterns += [p for p in w if isinstance(p, str) and not p.startswith("!")]
    found: dict[str, Path] = {}
    for pat in patterns:
        pat = pat.rstrip("/")
        dirs = sorted((root / pat[:-2]).glob("*")) if pat.endswith("/*") else [root / pat]
        for d in dirs:
            j = load_json(d / "package.json") if d.is_dir() else None
            if isinstance(j, dict) and isinstance(j.get("name"), str):
                found[j["name"]] = d
    return found


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


def ts_mappings(project: Path) -> list[tuple[str, list[str], Path]]:
    """(pattern, targets, base dir) from tsconfig.json, tsconfig.app.json, jsconfig.json (+ extends)."""
    maps = []
    for name in ("tsconfig.json", "tsconfig.app.json", "jsconfig.json"):
        cfg_path, paths, paths_dir, base_url, base_dir = project / name, None, None, None, None
        for _ in range(4):  # the file and up to three relative `extends`
            cfg = load_jsonc(cfg_path) if cfg_path.is_file() else None
            if not isinstance(cfg, dict):
                break
            co = cfg.get("compilerOptions") if isinstance(cfg.get("compilerOptions"), dict) else {}
            if paths is None and isinstance(co.get("paths"), dict):
                paths, paths_dir = co["paths"], cfg_path.parent
            if base_url is None and isinstance(co.get("baseUrl"), str):
                base_url, base_dir = co["baseUrl"], cfg_path.parent
            ext = cfg.get("extends")
            if not (isinstance(ext, str) and ext.startswith(".")):
                break
            cfg_path = (cfg_path.parent / ext)
            if cfg_path.suffix != ".json":
                cfg_path = cfg_path.with_name(cfg_path.name + ".json")
        if paths:
            root = (base_dir / base_url) if base_url is not None else paths_dir
            for pat, targets in paths.items():
                if isinstance(targets, list):
                    maps.append((pat, [t for t in targets if isinstance(t, str)], root))
    return maps


def resolve_spec(spec: str, project: Path, workspaces: dict[str, Path]) -> list[Path]:
    """Candidate filesystem paths for an import specifier, in resolution order."""
    out: list[Path] = []
    for pat, targets, root in ts_mappings(project):
        star = match(pat, spec)
        if star is not None:
            out += [(root / t.replace("*", star)) for t in targets]
    pj = load_json(project / "package.json") or {}
    if spec.startswith("#") and isinstance(pj.get("imports"), dict):
        for pat, t in pj["imports"].items():
            star = match(pat, spec)
            tgt = first_target(t)
            if star is not None and tgt:
                out.append(project / tgt.replace("*", star))
    for name in sorted(workspaces, key=len, reverse=True):
        if spec == name or spec.startswith(name + "/"):
            pdir, sub = workspaces[name], spec[len(name):].lstrip("/")
            exports = (load_json(pdir / "package.json") or {}).get("exports")
            if isinstance(exports, dict):
                for pat, t in exports.items():
                    star = match(pat, "./" + sub)
                    tgt = first_target(t)
                    if star is not None and tgt:
                        out.append(pdir / tgt.replace("*", star))
            out += [pdir / sub, pdir / "src" / sub]
            break
    return out


def resolve_alias(alias: str, kind: str, project: Path, workspaces: dict[str, Path]):
    """(path or None). kind 'dir' resolves the folder an alias stands for; 'file' a module."""
    if kind == "dir":
        for cand in resolve_spec(alias + "/" + PROBE, project, workspaces):
            s = str(cand)
            if PROBE in s:
                return Path(s[:s.index(PROBE)].rstrip("/\\"))
        return None
    cands = resolve_spec(alias, project, workspaces)
    for c in cands:
        for ext in ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.js"):
            p = Path(str(c) + ext)
            if p.is_file():
                return p
    return cands[0] if cands else None


def locked_shadcn(lockdir: Path | None, lockfile: str) -> str:
    if lockdir is None:
        return ""
    path = lockdir / lockfile
    try:
        text = path.read_text(encoding="utf-8", errors="replace") if lockfile != "bun.lockb" else ""
    except OSError:
        return ""
    if lockfile in ("package-lock.json", "npm-shrinkwrap.json"):
        j = load_json(path) or {}
        v = ((j.get("packages") or {}).get("node_modules/shadcn") or {}).get("version") \
            or ((j.get("dependencies") or {}).get("shadcn") or {}).get("version")
        return str(v or "")
    pats = {
        "pnpm-lock.yaml": r"(?m)^\s+/?'?shadcn@(\d+\.\d+\.\d+)",
        "yarn.lock": r"(?m)^\"?shadcn@[^\n]*:\n\s+version:?\s+\"?(\d+\.\d+\.\d+)",
        "bun.lock": r"\"shadcn@(\d+\.\d+\.\d+)\"",
    }
    m = re.search(pats.get(lockfile, r"$^"), text)
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
        lockdir, lockfile = find_lockdir(p)
        chain = [d for d in walk_up(p, lockdir) if (d / "package.json").is_file()] if lockdir else \
            ([p] if (p / "package.json").is_file() else [])
        deps: dict[str, str] = {}
        for d in reversed(chain):  # nearest package.json wins
            j = load_json(d / "package.json") or {}
            for field in ("dependencies", "devDependencies"):
                if isinstance(j.get(field), dict):
                    deps.update({k: str(v) for k, v in j[field].items()})
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
        elif tw_major == 4 and config_val:
            self.add("low", "tailwind-mismatch", "components.json", line_of(cj, '"config"'),
                     f"Tailwind v4 project but tailwind.config is {config_val!r}",
                     'set it to "" (the docs: leave it blank for v4) so theme edits go to @theme inline')

        # --- aliases ---
        resolved: dict[str, Path] = {}
        for key in ("components", "ui", "lib", "hooks", "utils"):
            val = aliases.get(key)
            if not isinstance(val, str) or not val:
                continue
            kind = "file" if key == "utils" else "dir"
            target = resolve_alias(val, kind, p, workspaces)
            ln = line_of(cj, f'"{key}"')
            if target is None:
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
        declared = ""
        for d in decl_roots:
            j = load_json(d / "package.json") or {}
            spec = (j.get("devDependencies") or {}).get("shadcn") or (j.get("dependencies") or {}).get("shadcn")
            if spec:
                declared = str(spec)
                break
        locked = ""
        for d in decl_roots:
            j = load_json(d / "node_modules" / "shadcn" / "package.json") or {}
            if j.get("version"):
                locked = str(j["version"])
                break
        locked = locked or locked_shadcn(lockdir, lockfile)
        if lockfile == "bun.lockb" and not locked:
            self.skipped.append({"check": "shadcn_locked", "reason": "bun.lockb is binary; run `bun install --save-text-lockfile` to get bun.lock"})
        pin_major = int(facts["cli"]["major"])
        css_imports_shadcn = bool(re.search(r"""@import\s+["']shadcn/tailwind\.css["']""", css_text))
        if not declared:
            if css_imports_shadcn:
                self.add("high", "shadcn-css-orphan", self.rel(css_path), line_of(css_path, "shadcn/tailwind.css"),
                         'imports "shadcn/tailwind.css" but no package.json declares shadcn; the build cannot resolve it',
                         f"<pm> add -D -E shadcn@{pin}, or run `shadcn eject` to inline the file (irreversible)")
            else:
                self.add("medium", "cli-not-installed", "package.json", None,
                         "shadcn is not a dependency, so every CLI run downloads one",
                         f"<pm> add -D -E shadcn@{pin} and run it with the local runner (scripts/shadcn-cmd.sh)")
        else:
            if declared.strip() in ("*", "x", "") or declared.strip() in self.facts["dist_tags"]:
                self.add("medium", "cli-range-open", "package.json", None,
                         f'shadcn is declared as "{declared}", so every lock refresh takes the newest release',
                         f"pin it: shadcn@{pin}")
            elif not EXACT_RE.match(declared) and lockdir is None:
                self.add("medium", "cli-unlocked", "package.json", None,
                         f'shadcn is "{declared}" with no lockfile, so each install may resolve a different version',
                         "commit a lockfile, or pin the exact version")
            have = major_of(locked or declared)
            if have is not None and have < pin_major:
                self.add("low", "cli-old-major", "package.json", None,
                         f"the project's shadcn is {locked or declared}; the skill documents {pin_major}.x "
                         "(apply, preset, eject, docs and info --json need it)",
                         "upgrade the devDependency in its own commit (references/cli-and-pinning.md)")

        # --- unpinned CLI in scripts, docs and MCP configs ---
        def unpinned_in(text: str) -> list[str]:
            hits = []
            for m in SPEC_RE.finditer(text):
                if m.group(1) == "shadcn-ui" or not EXACT_RE.match(m.group(2)):
                    hits.append(m.group(0))
            for m in ALWAYS_FETCH_RE.finditer(text):
                hits.append(m.group(0))
            for m in LOCAL_FIRST_RE.finditer(text):
                flags = m.group(2) or ""
                if m.group(3) == "shadcn-ui" or (not declared and not re.search(r"--no(-install)?\b", flags)):
                    hits.append(m.group(0))
            return hits

        pj_path = p / "package.json"
        pj = load_json(pj_path) or {}
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
                             f"document the project's runner ({LOCAL_RUNNER.get(lockfile, '<pm> exec shadcn')} ...) "
                             f"or shadcn@{pin}")
        for rel in MCP_FILES:
            f = p / rel
            j = load_json(f) if f.is_file() else None
            if not isinstance(j, dict):
                continue
            servers = j.get("mcpServers") or j.get("servers") or {}
            for sname_, conf in (servers.items() if isinstance(servers, dict) else []):
                if not isinstance(conf, dict):
                    continue
                cmdline = " ".join([str(conf.get("command", ""))] + [str(a) for a in conf.get("args") or []])
                if "shadcn" in cmdline and unpinned_in(cmdline):
                    self.add("medium", "unpinned-mcp", rel, line_of(f, f'"{sname_}"'),
                             f'MCP server "{sname_}" runs {cmdline.strip()!r} in every session',
                             "remove it (references/mcp.md), or pin it as in assets/mcp.json.example")

        # --- third-party registries ---
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
            for k, v in parse_qsl(parts.query):
                if SENSITIVE_RE.search(k) and v and not ENV_REF_RE.search(v):
                    literal.append(f"URL query {k}")
            if isinstance(conf, dict):
                for field in ("headers", "params"):
                    for k, v in (conf.get(field) or {}).items() if isinstance(conf.get(field), dict) else []:
                        rest = re.sub(r"\b(Bearer|Basic|Token)\b", "", ENV_REF_RE.sub("", str(v))).strip()
                        if SENSITIVE_RE.search(str(k)) and rest:
                            literal.append(f"{field}.{k}")
            if literal:
                self.add("high", "registry-literal-secret", "components.json", ln,
                         f"{ns} carries a literal credential in {', '.join(literal)} (value not shown)",
                         "rotate it, then reference an environment variable: ${REGISTRY_TOKEN} (kept in .env.local, never committed)")

        # --- React line ---
        react_v = (load_json(p / "node_modules" / "react" / "package.json") or {}).get("version") or deps.get("react", "")
        react_major = major_of(react_v) if react_v and not str(react_v).startswith(("latest", "*")) else None
        # A legacy style (new-york/default) on Tailwind v3 is the React 18 track and stays fine.
        modern = tw_major == 4 or (style not in facts["legacy_styles"] and base in facts["bases"])
        if react_major is not None and react_major < 19 and modern:
            self.add("medium", "react-pre-19", "package.json", None,
                     f"React {react_v} with v4-era components, which take ref as a plain prop (React 19); on 18 refs never reach the DOM",
                     "upgrade React to 19 first, or stay on the v3/new-york components (references/migrations-and-eject.md)")

        # --- monorepo: the workspace an alias points into must agree ---
        seen: set[Path] = set()
        for key, path in resolved.items():
            r = package_root(path, lockdir or p)
            if r is None or r.resolve() == p.resolve() or r in seen or not (r / "components.json").is_file():
                continue
            seen.add(r)
            other = load_json(r / "components.json") or {}
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
            "react": str(react_v) or None, "shadcn_declared": declared or None, "shadcn_locked": locked or None,
            "pin": pin, "package_manager_lockfile": lockfile or None,
            "registries": sorted(regs), "rsc": cfg.get("rsc"), "iconLibrary": cfg.get("iconLibrary"),
        })


def monorepo_hint(p: Path) -> list[str]:
    hits = []
    for pat in ("apps/*/components.json", "packages/*/components.json"):
        hits += [x.parent.relative_to(p).as_posix() for x in sorted(p.glob(pat))]
    return hits


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
    project = Path(args.dir)
    if not project.is_dir():
        return error("NOT_FOUND", f"directory not found: {project}", EX_NOTFOUND)
    facts = load_json(Path(args.facts))
    if not (isinstance(facts, dict) and isinstance(facts.get("cli"), dict) and EXACT_RE.match(str(facts["cli"].get("version", "")))):
        return error("VALIDATION", f"facts catalog missing or invalid: {args.facts}", EX_INVALID)
    cj = project / "components.json"
    if not cj.is_file():
        hint = monorepo_hint(project)
        extra = f"; this looks like a monorepo root - audit each workspace: {', '.join(hint)}" if hint else ""
        return error("NOT_FOUND", f"no components.json in {project}{extra}", EX_NOTFOUND)
    cfg = load_json(cj)
    if not isinstance(cfg, dict):
        return error("VALIDATION", f"{cj} is not valid JSON", EX_INVALID)

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
