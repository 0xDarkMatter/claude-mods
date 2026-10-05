#!/usr/bin/env python3
"""agents-md - create, audit/upgrade and survey AGENTS.md files against the protocol.

Usage:   agents-md.py scaffold [--repo PATH] [--facts FILE] [--archetype A] [--write] [--json]
         agents-md.py audit    [--repo PATH] [--facts FILE] [--diff] [--no-parents] [--json]
         agents-md.py survey   (--org OWNER | --remote OWNER/NAME) [--limit N]
                               [--include-archived] [--json]
Input:   scaffold/audit: a local checkout. Facts come from repo-scan.py (beside this
         script) unless --facts names a saved `repo-scan.py --json` output.
         survey: GitHub through the `gh` CLI, GET requests only.
Output:  scaffold: the AGENTS.md draft (markdown) on stdout, or the --json envelope
           claude-mods.repo-doctor.agents-md-scaffold/v1. --write creates <repo>/AGENTS.md
           and prints nothing.
         audit: a findings report, or --json (claude-mods.repo-doctor.agents-md-audit/v1).
           --diff prints ONLY a git-apply-able patch (empty when there is nothing to add).
         survey: one aligned row per repo, or --json
           (claude-mods.repo-doctor.agents-md-survey/v1).
Stderr:  progress, summaries, legends, warnings, errors
Exit:    0 ok (audit/survey: no warn or crit finding), 1 error (repo-scan failed),
         2 usage, 3 repo path not found, 5 precondition (AGENTS.md already exists for
         --write; gh not installed), 7 GitHub unavailable (unauthenticated, offline,
         rate-limited), 10 findings (audit: any warn/crit; survey: any repo with an issue)

Safety:  scaffold --write only CREATES AGENTS.md (tmp + rename) and refuses when one
         exists. There is deliberately no --force: overwriting is how an owner's
         landmines get lost. audit --diff prints a patch and never writes; the patch
         never deletes or moves the Landmines section. survey uses `gh repo list` and
         `gh api <path>` (GET) only, clones nothing and writes nothing.
Test hook: AGENTS_MD_GH overrides the gh executable (a .py path runs under this Python).

Examples:
  agents-md.py scaffold --repo path/to/site > AGENTS.draft.md
  agents-md.py scaffold --repo path/to/site --write
  agents-md.py audit --repo path/to/site
  agents-md.py audit --repo path/to/site --diff > agents-md.patch && git apply agents-md.patch
  agents-md.py survey --org my-org --json | jq '.data[] | select(.shadowed)'

Protocol: references/agents-md-protocol.md (repo-doctor skill). Facts contract:
scripts/repo-scan.py (schema claude-mods.repo-doctor.repo-scan/v1).
"""
# Deliberately one file: scaffold, audit and survey share one section grammar
# (SECTION_RULES) and one CLAUDE.md classifier; split copies would drift apart, and the
# skill is ported as a folder. Do not split it. tests/run.sh copies the scripts folder
# alone into a temp dir and runs every subcommand (the gate for that invariant).
#
# Section map (grep "=== NAME ==="):
#   CONSTANTS     thresholds, section grammar, schemas
#   MARKDOWN      fence-aware heading parser, section coverage, doc analysis
#   SHADOWING     CLAUDE.md classification (import / symlink / prose pointer / standalone)
#   FACTS         running repo-scan.py, rendering facts into draft sections
#   SCAFFOLD      archetype choice, template fill, --write
#   AUDIT         findings, dead commands, staleness, split plan, the --diff patch
#   SURVEY        gh plumbing (GET only), per-repo remote analysis, table
#   CLI           argument parsing and dispatch

from __future__ import annotations

import argparse
import base64
import difflib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

# === CONSTANTS ===

HERE = Path(__file__).resolve().parent
SCAN = HERE / "repo-scan.py"
TEMPLATES = HERE.parent / "assets" / "agents-md"
SCHEMA_SCAFFOLD = "claude-mods.repo-doctor.agents-md-scaffold/v1"
SCHEMA_AUDIT = "claude-mods.repo-doctor.agents-md-audit/v1"
SCHEMA_SURVEY = "claude-mods.repo-doctor.agents-md-survey/v1"
TARGET_LINES = 150      # house target (rules/agentic-quality.md)
CEILING_LINES = 200     # Claude Code memory docs: "target under 200 lines per CLAUDE.md file"
FRESH_COMMITS = 15      # same threshold as repo-doctor.py's entry_docs dimension
MIN_MOVE_LINES = 10     # sections shorter than this are not worth a split move
EX_OK, EX_ERR, EX_USAGE, EX_NOTFOUND, EX_PRECOND, EX_UNAVAIL, EX_FINDINGS = 0, 1, 2, 3, 5, 7, 10

# Section grammar: the first rule whose pattern matches a ## or ### heading names it.
# Order matters ("Testing gotchas" is a landmine section, not a commands section).
SECTION_RULES = (
    ("landmines", r"landmine|gotcha|pitfall|footgun|hazard|trap|caveat|warning|known issue|"
                  r"sharp edge|watch out|beware|danger|don'?t"),
    ("deploy", r"deploy|release|shipping|hosting|ci ?/ ?cd|pipeline|production|infrastructure"),
    ("commands", r"command|script|build|test|running|\brun\b|develop|workflow|task|"
                 r"quick ?(start|reference)|usage|\bcheck|cli\b|make|just"),
    ("structure", r"structure|layout|director|folder|architecture|\bmap\b|key (files|paths)|"
                  r"codebase|where|ownership|organi[sz]ation|modules|packages"),
    ("conventions", r"convention|style|standard|guideline|rules?\b|naming|pattern|coding|practice"),
    ("overview", r"overview|about|introduction|purpose|what (this|it) is"),
)
SETUP_HEADING = re.compile(r"(?i)^(install(ation|ing)?|set ?up|getting started|prerequisites?|"
                           r"requirements|onboarding|first[- ]time|local (dev(elopment)? )?setup)\b")
REQUIRED_WARN = ("commands", "landmines")
SECTION_ORDER = ("overview", "commands", "landmines", "deploy", "structure", "conventions")
TODO_OWNER = "TODO(owner)"
UNTESTED = "[untested]"
DRAFT_MARK = "DRAFT generated by repo-doctor"
CLAUDE_FILES = ("CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md")
SKIP_DIRS = {".git", "node_modules", "vendor", ".venv", "venv", "dist", "build"}

# Package-manager and Composer built-ins: a bare `yarn <x>` / `composer <x>` with one of
# these names is the tool's own command, never a missing script.
YARN_BUILTINS = {"install", "add", "remove", "upgrade", "up", "dlx", "why", "info", "init",
                 "set", "config", "workspace", "workspaces", "cache", "global", "link",
                 "unlink", "pack", "publish", "version", "exec", "node", "plugin",
                 "constraints", "dedupe", "explain", "npm", "patch", "rebuild", "run",
                 "create", "bin", "outdated", "audit", "login", "logout", "list", "help"}
PNPM_BUILTINS = {"install", "i", "add", "remove", "rm", "update", "up", "exec", "dlx",
                 "create", "init", "link", "unlink", "list", "ls", "outdated", "prune",
                 "publish", "rebuild", "root", "store", "why", "import", "audit", "env",
                 "setup", "fetch", "patch", "deploy", "pack", "licenses", "config", "run",
                 "server", "help", "start", "test", "t"}
COMPOSER_BUILTINS = {"install", "i", "update", "u", "upgrade", "require", "r", "remove", "rm",
                     "dump-autoload", "dumpautoload", "du", "show", "info", "outdated",
                     "validate", "diagnose", "config", "create-project", "init", "global",
                     "exec", "run-script", "run", "why", "depends", "why-not", "prohibits",
                     "audit", "check-platform-reqs", "clear-cache", "clearcache", "cc",
                     "self-update", "selfupdate", "search", "status", "licenses", "fund",
                     "archive", "reinstall", "bump", "browse", "home", "suggests", "list",
                     "help", "about", "repository"}
INLINE_RUNNERS = re.compile(r"^(ddev\s+(composer|npm|yarn|pnpm)\s+|npm\s+(run|run-script|test|t)\b|"
                            r"(yarn|pnpm|bun)\s+\S|composer\s+\S|make\s+\S|just\s+\S)")
NEGATION = re.compile(r"(?i)\b(never|don'?t|do not|removed|deprecated|instead of|no longer|"
                      r"was renamed|used to)\b")


def eecho(msg: str) -> None:
    print(msg, file=sys.stderr)


def read_raw(path: Path) -> str:
    """File text with line endings intact. Path.read_text() turns CRLF into LF, so a
    patch built from it would never match a CRLF file on disk."""
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def emit_json(obj: dict) -> None:
    print(json.dumps(obj, indent=2))


# === MARKDOWN ===


def headings(lines: list[str]) -> list[tuple[int, int, str]]:
    """(0-based index, level, text) for ATX headings outside fenced code."""
    out, fence = [], False
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        m = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if m and not fence:
            out.append((i, len(m.group(1)), m.group(2)))
    return out


def section_key(title: str) -> str | None:
    t = title.lower()
    for key, pat in SECTION_RULES:
        if re.search(pat, t):
            return key
    return None


def h2_sections(lines: list[str]) -> list[dict]:
    """Top-level (##) sections with [start, end) line ranges; start is the heading."""
    hs = [h for h in headings(lines) if h[1] == 2]
    out = []
    for n, (i, _, title) in enumerate(hs):
        end = hs[n + 1][0] if n + 1 < len(hs) else len(lines)
        out.append({"start": i, "end": end, "title": title, "key": section_key(title)})
    return out


def has_overview(lines: list[str]) -> bool:
    hs = headings(lines)
    first_h2 = next((i for i, lvl, _ in hs if lvl == 2), len(lines))
    in_comment = False
    for line in lines[:first_h2]:
        s = line.strip()
        if "<!--" in s:
            in_comment = "-->" not in s
            continue
        if in_comment:
            in_comment = "-->" not in s
            continue
        if s and not s.startswith("#") and not s.startswith(("[![", "![")) and TODO_OWNER not in s:
            return True
    return False


def analyze_doc(text: str) -> dict:
    """Section coverage and draft markers; shared by audit (local) and survey (remote)."""
    lines = text.splitlines()
    cover = {k: False for k in SECTION_ORDER}
    cover["overview"] = has_overview(lines)
    for _, lvl, title in headings(lines):
        if lvl in (2, 3):
            key = section_key(title)
            if key:
                cover[key] = True
    items, hs = 0, headings(lines)
    for n, (i, lvl, title) in enumerate(hs):   # ## or ### landmine blocks alike
        if lvl not in (2, 3) or section_key(title) != "landmines":
            continue
        end = next((j for j, l2, _ in hs[n + 1:] if l2 <= lvl), len(lines))
        for line in lines[i + 1: end]:
            if re.match(r"^\s*(\d+[.)]|[-*+])\s+\S", line) and TODO_OWNER not in line:
                items += 1
    return {"lines": len(lines), "sections": cover, "landmine_items": items,
            "owner_todos": text.count(TODO_OWNER), "untested": text.count(UNTESTED),
            "draft_header": DRAFT_MARK in text,
            "setup_headings": [t for _, lvl, t in headings(lines)
                               if lvl in (2, 3) and SETUP_HEADING.match(t)]}


def coverage_letters(sections: dict) -> str:
    letters = {"overview": "O", "commands": "C", "landmines": "L", "deploy": "D",
               "structure": "S", "conventions": "V"}
    return "".join(letters[k] if sections.get(k) else "-" for k in SECTION_ORDER)


def strip_code(text: str) -> str:
    """Text with fenced blocks and inline code spans removed (imports skip both)."""
    text = re.sub(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*$", "", text)
    return re.sub(r"`[^`\n]*`", "", text)


# === SHADOWING ===
# Claude Code (v2.1.277+) reads AGENTS.md only when no CLAUDE.md, .claude/CLAUDE.md or
# CLAUDE.local.md sits in the working directory or above it, unless that CLAUDE.md
# imports it with an `@path` line (agents-md-protocol.md section 4).


def classify_claude(text: str, rel: str, agents_rel: str = "AGENTS.md") -> str:
    """imports | symlink-text | pointer-prose | standalone, for a CLAUDE.md-family file."""
    body = text.strip()
    if body in ("AGENTS.md", "./AGENTS.md", "../AGENTS.md"):
        return "symlink-text"
    base = os.path.dirname(rel)
    for m in re.finditer(r"(?:^|\s)@([^\s`]+)", strip_code(text)):
        target = os.path.normpath(os.path.join(base, m.group(1))).replace("\\", "/")
        if target == agents_rel:
            return "imports"
    return "pointer-prose" if "AGENTS.md" in strip_code(text) else "standalone"


def import_line(rel: str, agents_rel: str = "AGENTS.md") -> str:
    path = os.path.relpath(agents_rel, os.path.dirname(rel) or ".").replace("\\", "/")
    return "@" + path


SHADOW_MSG = {
    "standalone": "{f} shadows AGENTS.md: with any CLAUDE.md, .claude/CLAUDE.md or "
                  "CLAUDE.local.md present, Claude Code reads the CLAUDE.md files only. "
                  "Put `{imp}` on its first line (keep Claude-only deltas below it) or "
                  "delete it",
    "pointer-prose": "{f} points to AGENTS.md in prose, which loads nothing: Claude Code "
                     "reads the CLAUDE.md only. Replace the sentence with an `{imp}` import",
    "symlink-text": "{f} is a one-line text file reading 'AGENTS.md': a symlink checked "
                    "out without core.symlinks (Windows). It shadows the real AGENTS.md. "
                    "Replace it with an `{imp}` import",
}


# === FACTS ===


def load_facts(repo: Path, facts_file: str | None, only: str | None = None) -> dict | None:
    if facts_file:
        try:
            data = json.loads(Path(facts_file).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            eecho(f"agents-md: cannot read --facts {facts_file}: {exc}")
            return None
        return data.get("data", data)
    cmd = [sys.executable, str(SCAN), "--repo", str(repo), "--json"]
    if only:
        cmd += ["--only", only]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=600, encoding="utf-8",
                           errors="replace")
    except (OSError, subprocess.TimeoutExpired) as exc:
        eecho(f"agents-md: repo-scan failed: {exc}")
        return None
    if r.returncode != 0:
        eecho(f"agents-md: repo-scan exited {r.returncode}: {r.stderr.strip()[-400:]}")
        return None
    try:
        return json.loads(r.stdout)["data"]
    except (json.JSONDecodeError, KeyError):
        eecho("agents-md: repo-scan returned unparsable JSON")
        return None


def cite(source: str) -> str:
    """Render a fact source compactly: git history, a commit, or `path:line`."""
    if source.startswith("cmd: git log"):
        return "git history"
    if source.startswith("git: "):
        return "`" + source[5:].split(" ", 1)[0] + "`"
    if source.startswith("cmd: "):
        return "`" + source[5:] + "`"
    return "`" + source + "`"


def _script_order(name: str) -> tuple:
    pri = ("dev", "start", "serve", "build", "watch", "test", "lint", "check", "typecheck",
           "format", "fix")
    return (pri.index(name) if name in pri else len(pri), name)


def command_entries(f: dict) -> list[tuple[str, str, str, str]]:
    """(group, command, source, note) for every command the facts can back."""
    m = f.get("manifests") or {}
    dd = f.get("ddev") or {}
    ddev = dd.get("config") is not None if dd else False
    out: list[tuple[str, str, str, str]] = []
    if ddev:
        out.append(("Local environment", "ddev start", ".ddev/config.yaml", "DDEV project"))
        for c in [c for c in dd.get("commands", []) if not c.get("ddev_generated")][:6]:
            out.append(("Local environment", f"ddev {c['name']}", c["source"],
                        c.get("description") or f"custom {c['scope']} command"))
    comp = m.get("composer_json") or {}
    if comp and not comp.get("error"):
        pre = "ddev composer" if ddev else "composer"
        if comp.get("lockfile"):
            out.append(("Dependencies", f"{pre} install", "composer.lock", "PHP dependencies"))
        for s in [s for s in comp.get("scripts", []) if s.get("kind") == "script"][:6]:
            out.append(("Scripts", f"{pre} run-script {s['name']}", s["source"], s["command"]))
    pkg = m.get("package_json") or {}
    if pkg and not pkg.get("error"):
        pm = (pkg.get("package_manager") or {}).get("name", "npm")
        pm_src = (pkg.get("package_manager") or {}).get("source", "package.json")
        install = {"npm": "npm ci" if pm_src == "package-lock.json" else "npm install",
                   "yarn": "yarn install", "pnpm": "pnpm install", "bun": "bun install"}.get(pm)
        if install:
            out.append(("Dependencies", install, pm_src, "Node dependencies"))
        run = {"npm": "npm run", "yarn": "yarn run", "pnpm": "pnpm run", "bun": "bun run"}.get(pm, "npm run")
        for s in sorted(pkg.get("scripts", []), key=lambda s: _script_order(s["name"]))[:12]:
            cmd = "npm test" if pm == "npm" and s["name"] == "test" else f"{run} {s['name']}"
            out.append(("Scripts", cmd, s["source"], s["command"]))
    py = m.get("python") or {}
    tests = f.get("tests") or []
    if py:
        mgr = str((py.get("manager") or {}).get("name") or "")
        prefix = {"uv": "uv run ", "poetry": "poetry run ", "pipenv": "pipenv run ",
                  "pdm": "pdm run "}.get(mgr, "")
        if mgr in ("uv", "poetry", "pipenv", "pdm"):
            out.append(("Dependencies", {"uv": "uv sync", "poetry": "poetry install",
                                         "pipenv": "pipenv install", "pdm": "pdm install"}[mgr],
                        py["manager"]["source"], "Python dependencies"))
        for t in tests:
            if t["framework"] == "pytest":
                out.append(("Tests", f"{prefix or 'python -m '}pytest", t["config"], "pytest"))
                break
        for s in py.get("scripts", [])[:4]:
            out.append(("Scripts", f"{prefix}{s['name']}", s["source"], f"console script -> {s['target']}"))
    declared = " ".join(c[1] + " " + c[3] for c in out).lower()
    runners = {"PHPUnit": ("vendor/bin/phpunit", "phpunit"),
               "Codeception": ("vendor/bin/codecept run", "codecept"),
               "Pest": ("vendor/bin/pest", "pest"), "Playwright": ("npx playwright test", "playwright"),
               "Cypress": ("npx cypress run", "cypress"), "Vitest": ("npx vitest run", "vitest"),
               "Jest": ("npx jest", "jest")}
    for t in tests:
        fw, cfg = t["framework"], t["config"]
        exe, binary = runners.get(fw, (None, None))
        # Offer the runner only when no declared script already wraps it.
        if exe and binary and binary not in declared:
            if ddev and exe.startswith("vendor/"):
                exe = "ddev exec " + exe
            out.append(("Tests", exe, cfg, f"{fw} config"))
    for name, key, prog in (("makefile", "targets", "make"), ("justfile", "recipes", "just")):
        block = m.get(name) or {}
        for t in [t for t in block.get(key, []) if not t.get("alias_of")][:8]:
            out.append(("Tasks", f"{prog} {t['name']}", t["source"], f"{prog} target"))
    seen = {c[1] for c in out}
    ci_runs = []
    for wf in (f.get("ci") or {}).get("workflows", []):
        for job in wf.get("jobs", []):
            for st in job.get("steps", []):
                first = (st.get("run") or "").strip().splitlines()[:1]
                if first and re.search(r"(?i)\b(test|lint|check|phpstan|phpunit|codecept|pest|"
                                       r"pytest|vitest|jest|tsc|eslint|stylelint|ecs|rector|"
                                       r"mypy|ruff|playwright|cypress)\b", first[0]) \
                        and first[0] not in seen and len(first[0]) <= 80:
                    seen.add(first[0])
                    ci_runs.append(("What CI runs", first[0], st["source"], f"CI job {job['id']}"))
    return out + ci_runs[:4]


def render_commands(f: dict) -> str:
    entries = command_entries(f)
    if not entries:
        return (f"- [ ] {TODO_OWNER}: no declared scripts were found. Which commands run, "
                "test and check this repo?")
    width = min(max(len(c[1]) for c in entries) + 2, 40)
    lines = ["Every command below is declared in the repo but was not run by the generator.",
             f"Run each once, then delete its `{UNTESTED}` tag.", "", "```bash"]
    group = None
    for g, cmd, source, note in entries:
        if g != group:
            if group is not None:
                lines.append("")
            lines.append(f"# {g}")
            group = g
        note = re.sub(r"\s+", " ", note)[:48]
        pad = cmd.ljust(width) if len(cmd) < width else cmd + "  "
        lines.append(f"{pad}# {note} ({source}) {UNTESTED}")
    lines.append("```")
    return "\n".join(lines)


def has_check(f: dict) -> bool:
    names = set()
    m = f.get("manifests") or {}
    for key in ("package_json", "composer_json"):
        names |= {s["name"] for s in (m.get(key) or {}).get("scripts", [])}
    for key, sub in (("makefile", "targets"), ("justfile", "recipes")):
        names |= {t["name"] for t in (m.get(key) or {}).get(sub, [])}
    return bool(names & {"check", "ci", "verify", "validate", "qa"})


def render_overview(f: dict) -> str:
    m = f.get("manifests") or {}
    lines = []
    desc = None
    for key, path in (("package_json", "package.json"), ("composer_json", "composer.json"),
                      ("python", "pyproject.toml")):
        d = (m.get(key) or {}).get("description")
        if isinstance(d, str) and d.strip():
            desc = (d.strip(), path)
            break
    if desc:
        lines.append(f"{desc[0]} (description from `{desc[1]}`)")
        lines.append(f"{TODO_OWNER}: extend to 2-4 lines: what it produces and who consumes it.")
    else:
        lines.append(f"{TODO_OWNER}: 2-4 lines on what this repo is, what it produces and who consumes it.")
    lines.append("")
    tools = [t for k in ("composer_json", "package_json", "python") for t in (m.get(k) or {}).get("tools", [])]
    stack_names = ("Craft CMS", "Drupal", "Laravel", "Statamic", "WordPress", "Symfony", "Silverstripe",
                   "TYPO3", "Next.js", "Nuxt", "Astro", "SvelteKit", "Eleventy", "Gatsby", "Express",
                   "Fastify", "Hono", "NestJS", "Django", "Flask", "FastAPI", "React", "Vue",
                   "Vite", "Laravel Mix", "webpack", "craft-vite", "Tailwind CSS", "TypeScript")
    stack = [t for t in tools if t["name"] in stack_names]
    if stack:
        lines.append("- Stack: " + ", ".join(f"{t['name']} ({cite(t['source'])})" for t in stack[:8]))
    dd = f.get("ddev") or {}
    cfg = dd.get("config") or {}
    if cfg:
        bits = [f"type `{cfg['type']['value']}`" if "type" in cfg else None,
                f"PHP {cfg['php_version']['value']}" if "php_version" in cfg else None,
                cfg["database"]["value"] if "database" in cfg else None,
                f"Node {cfg['nodejs_version']['value']}" if "nodejs_version" in cfg else None]
        first = next((v["source"] for v in cfg.values()), ".ddev/config.yaml")
        lines.append(f"- Local environment: DDEV ({', '.join(b for b in bits if b)}; {cite(first)})")
    pkg = m.get("package_json") or {}
    if pkg.get("node"):
        pm = pkg.get("package_manager") or {}
        lines.append(f"- Node {pkg['node']['version']} ({cite(pkg['node']['source'])}); package "
                     f"manager {pm.get('name')} ({cite(pm.get('source', 'package.json'))})")
    comp = m.get("composer_json") or {}
    if comp.get("php"):
        lines.append(f"- PHP {comp['php']['constraint']} ({cite(comp['php']['source'])})")
    langs = (f.get("languages") or {}).get("by_language") or []
    total = sum(r["lines"] for r in langs) or 1
    if langs:
        top = ", ".join(f"{r['language']} {round(100 * r['lines'] / total)}%" for r in langs[:4])
        lines.append(f"- Languages: {top} ({(f.get('languages') or {}).get('metric')})")
    return "\n".join(lines).rstrip()


def render_landmines(f: dict) -> str:
    out = []
    for c in f.get("candidates") or []:
        if c["kind"] in ("workspaces",):
            continue
        ev = ", ".join(dict.fromkeys(cite(e) for e in c["evidence"][:3]))
        out.append(f"- [ ] {TODO_OWNER}: {c['question']} Evidence: {ev}.")
    return "\n".join(out[:12])


def render_deploy(f: dict) -> str:
    dep = f.get("deploy") or {}
    lines = []
    spec = dep.get("appspec")
    if spec:
        lines.append(f"Deploys through AWS CodeDeploy (`{spec['path']}`). Hooks:")
        for h in spec["hooks"]:
            cmds = "; ".join(f"`{c['command'][:60]}` ({cite(c['source'])})" for c in h["commands"][:3])
            missing = "" if h["script_exists"] else " (script not found in the repo)"
            lines.append(f"- `{h['event']}` runs `{h['location']}`{missing} ({cite(h['source'])})"
                         + (f": {cmds}" if cmds else ""))
        for fl in spec.get("files", [])[:2]:
            lines.append(f"- Files go to `{fl['destination']}` ({cite(fl['source'])})")
    for s in dep.get("ci_deploy_steps", [])[:3]:
        br = ", ".join(f"`{b}`" for b in s["push_branches"]) or "its configured triggers"
        lines.append(f"- CI job `{s['job']}` in `{s['workflow']}` deploys on push to {br} ({cite(s['source'])})")
    others = [s for s in dep.get("surfaces", []) if s["kind"] != "AWS CodeDeploy"]
    if others:
        lines.append("- Also present: " + ", ".join(f"{s['kind']} (`{s['path']}`)" for s in others[:5]))
    if not lines:
        return (f"No deploy configuration was found in the repo.\n\n- [ ] {TODO_OWNER}: How does "
                "this ship, and who may trigger it?")
    lines.append("")
    lines.append(f"- [ ] {TODO_OWNER}: Which branch deploys, and may an agent ever merge to it? "
                 "(A merge to an auto-deploying branch is a deploy.)")
    return "\n".join(lines)


def render_structure(f: dict) -> str:
    areas = f.get("areas") or []
    if not areas:
        return f"- [ ] {TODO_OWNER}: one line per top-level folder an agent can't guess."
    tests = ", ".join(sorted({t["framework"] for t in f.get("tests") or []}))
    gen = {g["path"]: g for g in (f.get("generated") or {}).get("tracked", [])}
    dd = f.get("ddev") or {}
    rank = {"source": 0, "generated": 1, "tests": 2, "config": 3, "tooling": 4, "ci": 5,
            "docs": 6, "assets": 7}
    rows = ["| Path | What lives there |", "|---|---|"]
    for a in sorted(areas, key=lambda a: (rank.get(a["kind"], 9), -a["files"], a["path"]))[:12]:
        p, n, kind = a["path"], a["files"], a["kind"]
        exts = " ".join(a["top_extensions"])
        if kind == "generated" or p in gen:
            g = gen.get(p, {})
            why = f"declared by {cite(g['declared_by'])}" if g.get("declared_by") else "matches a build-output pattern"
            desc = f"Generated or vendored ({n} files; {why}). Regenerate, don't hand-edit"
        elif p == ".ddev/":
            desc = f"DDEV config and {len(dd.get('commands', []))} custom command(s)"
        elif kind == "tests":
            desc = f"Tests ({tests})" if tests else f"Tests ({n} files)"
        elif kind == "ci":
            desc = f"CI config ({n} files)"
        elif kind == "docs":
            desc = f"Documentation ({n} files)"
        else:
            desc = f"{n} files ({exts}). {TODO_OWNER}: one line"
        rows.append(f"| `{p}` | {desc} |")
    rows.append("")
    rows.append("<!-- Delete rows whose folder name already says it all: Claude Code's /doctor "
                "trims layouts it can derive. -->")
    return "\n".join(rows)


def render_conventions(f: dict) -> str:
    m = f.get("manifests") or {}
    lines = []
    cfgs = m.get("tooling_configs") or []
    lint = [c for c in cfgs if c["tool"] not in ("husky git hook", "TypeScript")]
    if lint:
        lines.append("- Enforced by config: " + ", ".join(f"{c['tool']} (`{c['path']}`)" for c in lint[:8]))
    hooks = [c for c in cfgs if c["tool"] == "husky git hook"]
    if hooks:
        lines.append("- Commits run git hooks: " + ", ".join(f"`{c['path']}`" for c in hooks[:4]))
    ec = {x["key"]: x for x in m.get("editorconfig") or []}
    if ec:
        style = ec.get("indent_style", {}).get("value", "")
        size = ec.get("indent_size", {}).get("value", "")
        first = next(iter(ec.values()))["source"]
        lines.append(f"- Indentation: {size} {style} ({cite(first)})".replace("  ", " "))
    for env in (f.get("env") or [])[:1]:
        names = [n["name"] for n in env["names"]]
        if names:
            more = f" and {len(names) - 12} more" if len(names) > 12 else ""
            lines.append(f"- Environment variables (names from `{env['path']}`): "
                         + ", ".join(f"`{n}`" for n in names[:12]) + more)
    lines.append(f"- [ ] {TODO_OWNER}: repo-specific invariants and naming rules a reviewer always enforces.")
    return "\n".join(lines)


def render_pointers(f: dict) -> str:
    paths = {d["path"] for d in f.get("docs") or []}
    out = []
    if "README.md" in paths:
        out.append("- Human setup and overview: [README.md](README.md)")
    if "CONTRIBUTING.md" in paths:
        out.append("- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)")
    idx = next((p for p in ("docs/00_INDEX.md", "docs/INDEX.md", "docs/README.md") if p in paths), None)
    if idx:
        out.append(f"- Docs index: [{idx}]({idx})")
    adr = next((p for p in paths if re.match(r"^docs/(adr|decisions)/", p)), None)
    if adr:
        out.append(f"- Decisions: `{adr.rsplit('/', 1)[0]}/`")
    for p in sorted(p for p in paths if p.endswith("/AGENTS.md")):
        out.append(f"- Nested entry doc: [{p}]({p})")
    return "## Pointers\n\n" + "\n".join(out) if out else ""


def render_questions(f: dict) -> str:
    m = f.get("manifests") or {}
    qs = []
    if (f.get("ddev") or {}).get("config") is not None and m.get("package_json"):
        qs.append("Do the Node scripts run on the host or inside DDEV (`ddev npm ...`)?")
    if not has_check(f):
        qs.append("There is no single `check` command (typecheck + lint + tests). Which "
                  "command must pass before a commit?")
    py = m.get("python") or {}
    if py and not py.get("manager"):
        qs.append("How are the Python dependencies installed? No lockfile or manager config was found.")
    if any(e["names"] for e in f.get("env") or []):
        qs.append("Which environment variables must be set for local work, and where do the values come from?")
    for w in (m.get("workspaces") or [])[:1]:
        qs.append(f"The repo declares workspaces ({', '.join(w['globs'][:4]) or w['tool']}; "
                  f"{cite(w['source'])}). Does any package need its own nested AGENTS.md?")
    if not qs:
        return ""
    return ("## Open questions (delete this section once answered)\n\n"
            + "\n".join(f"- [ ] {TODO_OWNER}: {q}" for q in qs))


# === SCAFFOLD ===


def choose_archetype(f: dict) -> str:
    m = f.get("manifests") or {}
    if m.get("composer_json") or ((f.get("ddev") or {}).get("config") is not None and not m.get("python")):
        return "php-cms"
    if m.get("python"):
        return "python-service"
    pkg = m.get("package_json") or {}
    if pkg:
        tools = {t["name"] for t in pkg.get("tools", [])}
        server = {"Next.js", "Nuxt", "Express", "Fastify", "Hono", "NestJS", "SvelteKit", "React", "Vue"}
        if tools & {"Eleventy", "Gatsby"} and not tools & server:
            return "static-site"
        return "node-app"
    return "static-site"


def render_draft(f: dict, archetype: str) -> str:
    tmpl = (TEMPLATES / f"{archetype}.md").read_text(encoding="utf-8")
    tmpl = re.sub(r"(?s)\A\s*<!--.*?-->\s*", "", tmpl, count=1)  # the template's own header
    title = (f.get("repo") or {}).get("name") or "this repo"
    note = (f"<!-- {DRAFT_MARK} agents-md.py scaffold (archetype: {archetype}) from repo-scan\n"
            "     facts. Every fact cites its source and nothing was executed. Before committing:\n"
            f"     answer or delete each {TODO_OWNER}, run each command once and drop its {UNTESTED}\n"
            "     tag, then delete this comment. Protocol: repo-doctor references/agents-md-protocol.md -->")
    slots = {"TITLE": title, "DRAFT_NOTE": note, "OVERVIEW": render_overview(f),
             "COMMANDS": render_commands(f), "LANDMINES": render_landmines(f),
             "DEPLOY": render_deploy(f), "STRUCTURE": render_structure(f),
             "CONVENTIONS": render_conventions(f), "POINTERS": render_pointers(f),
             "QUESTIONS": render_questions(f)}
    for k, v in slots.items():
        tmpl = tmpl.replace("{{" + k + "}}", v)
    tmpl = re.sub(r"\n{3,}", "\n\n", tmpl).strip() + "\n"
    return tmpl


def cmd_scaffold(args) -> int:
    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"agents-md: not a directory: {repo}")
        return EX_NOTFOUND
    if args.write and (repo / "AGENTS.md").exists():
        eecho(f"agents-md: {repo / 'AGENTS.md'} already exists; scaffold never overwrites "
              "(an owner's landmines live there). Upgrade it instead: agents-md.py audit --diff")
        return EX_PRECOND
    f = load_facts(repo, args.facts)
    if f is None:
        return EX_ERR
    arch = args.archetype if args.archetype != "auto" else choose_archetype(f)
    draft = render_draft(f, arch)
    n = draft.count("\n")
    eecho(f"agents-md: scaffold draft, archetype {arch}, {n} lines, "
          f"{draft.count(TODO_OWNER)} {TODO_OWNER} question(s)")
    if n > TARGET_LINES:
        eecho(f"agents-md: the draft is over the {TARGET_LINES}-line target; answer and prune before committing")
    for name in CLAUDE_FILES:
        p = repo / name
        if p.exists() and not p.is_symlink():
            kind = classify_claude(read_raw(p), name)
            if kind != "imports":
                eecho(f"agents-md: {name} will shadow the new AGENTS.md; add `{import_line(name)}` "
                      "to it (agents-md.py audit --diff proposes this)")
    if args.write:
        dest = repo / "AGENTS.md"
        fd, tmp = tempfile.mkstemp(dir=str(repo), prefix=".AGENTS.md.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(draft)
        if dest.exists():   # lost a race: someone created it meanwhile
            os.unlink(tmp)
            eecho(f"agents-md: {dest} appeared during the scaffold; not overwritten")
            return EX_PRECOND
        os.replace(tmp, dest)
        eecho(f"agents-md: created {dest}")
        return EX_OK
    if args.json:
        emit_json({"data": {"archetype": arch, "lines": n, "owner_questions": draft.count(TODO_OWNER),
                            "commands": [{"group": g, "command": c, "source": s, "note": t}
                                         for g, c, s, t in command_entries(f)],
                            "candidates": f.get("candidates") or [], "draft": draft},
                   "meta": {"schema": SCHEMA_SCAFFOLD}})
    else:
        sys.stdout.write(draft)
    return EX_OK


# === AUDIT ===


def git(repo: Path, *args: str) -> str | None:
    try:
        r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, timeout=60,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def command_refs(lines: list[str]) -> list[tuple[int, str, bool]]:
    """(0-based line, command text, in_fence) for code the doc presents as runnable."""
    out, fence = [], False
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            s = line.strip()
            if s and not s.startswith("#") and not NEGATION.search(line):
                out.append((i, re.sub(r"^\$\s+", "", s.split(" #", 1)[0].strip()), True))
        elif not NEGATION.search(line):
            # In prose, a code span is a command only when it starts with a package or task
            # runner; `scripts/x.sh` or `bash x.sh` in a sentence is usually a mention.
            for m in re.finditer(r"`([^`\n]+)`", line):
                span = m.group(1).strip()
                if INLINE_RUNNERS.match(span):
                    out.append((i, span, False))
    return out


def check_command(cmd: str, f: dict, repo: Path) -> str | None:
    """Why a referenced command can't exist in this repo, or None (exists / unverifiable)."""
    m = f.get("manifests") or {}
    pkg = m.get("package_json") or {}
    scripts = {s["name"] for s in pkg.get("scripts", [])}
    deps = set(pkg.get("dependencies", []))
    comp = {s["name"] for s in (m.get("composer_json") or {}).get("scripts", [])}
    for seg in re.split(r"&&|\|\||;|\|", cmd):
        try:
            tok = shlex.split(seg)
        except ValueError:
            continue
        while tok and re.match(r"^[A-Z_][A-Z0-9_]*=", tok[0]):
            tok = tok[1:]
        if tok[:1] == ["sudo"]:
            tok = tok[1:]
        if tok[:2] == ["ddev", "exec"]:
            tok = tok[2:]
        elif tok[:1] == ["ddev"] and len(tok) > 1 and tok[1] in ("composer", "npm", "yarn", "pnpm"):
            tok = tok[1:]
        if not tok:
            continue
        if tok[0] == "cd":
            return None   # later segments run elsewhere: unverifiable
        if any(t.startswith(("--prefix", "--workspace", "--filter", "--cwd", "--dir")) or t in ("-w", "-C", "-r")
               for t in tok):
            continue
        prog, rest = tok[0], [t for t in tok[1:] if not t.startswith("-")]
        name = None
        if prog == "npm" and rest[:1] in (["run"], ["run-script"]) and len(rest) > 1:
            name = rest[1]
        elif prog == "npm" and rest[:1] in (["test"], ["t"]):
            name = "test"
        elif prog in ("yarn", "pnpm", "bun") and rest[:1] == ["run"] and len(rest) > 1:
            name = rest[1]
        elif prog in ("yarn", "pnpm") and rest and rest[0] not in (YARN_BUILTINS if prog == "yarn" else PNPM_BUILTINS):
            # The bare form also runs dependency binaries, so only a name that is neither a
            # script nor a dependency is provably dead.
            if not pkg:
                return f"`{prog}` command but no package.json"
            if rest[0] not in scripts and rest[0] not in deps:
                return f'no "{rest[0]}" script or dependency in package.json'
            continue
        if name is not None:
            if not pkg:
                return f"`{prog}` command but no package.json"
            if name not in scripts:
                return f'no "{name}" script in package.json'
            continue
        if prog == "composer" and rest:
            target = rest[1] if rest[0] in ("run-script", "run") and len(rest) > 1 else (
                None if rest[0] in COMPOSER_BUILTINS else rest[0])
            if target and target not in comp:
                return f'no "{target}" script in composer.json'
            continue
        for tool, key, sub in (("make", "makefile", "targets"), ("just", "justfile", "recipes")):
            if prog == tool and rest:
                block = m.get(key)
                if not block:
                    return f"`{tool} {rest[0]}` but no {'Makefile' if tool == 'make' else 'justfile'}"
                names = {t["name"] for t in block.get(sub, [])}
                if rest[0] not in names and "=" not in rest[0]:
                    return f'no "{rest[0]}" target in {block["path"]}'
        path = None
        if prog in ("bash", "sh", "zsh", "python", "python3", "node", "php", "pwsh", "uv") and rest:
            cand = rest[1] if prog == "uv" and rest[0] == "run" and len(rest) > 1 else (None if prog == "uv" else rest[0])
            path = cand
        elif prog.startswith("./") or re.match(r"^[\w.-]+/[\w./-]+\.(sh|py|ps1)$", prog):
            path = prog   # an executable path run directly (a bare .js/.php is a file mention)
        if path and not re.search(r"[$*?{}~<>]|^/|^[A-Za-z]:|://", path) \
                and re.search(r"/|\.(sh|py|js|mjs|php|ps1)$", path) and not (repo / path).exists():
            return f"`{path}` does not exist"
    return None


def staleness(repo: Path, rel: str) -> tuple[int | None, int | None]:
    last = git(repo, "rev-list", "-1", "HEAD", "--", rel)
    if not last:
        return None, None
    n = git(repo, "rev-list", "--count", "HEAD", f"^{last}")
    k = git(repo, "rev-list", "--count", f"{last}..HEAD", "--", "package.json", "composer.json",
            "Makefile", "justfile")
    return (int(n) if n and n.isdigit() else None, int(k) if k and k.isdigit() else None)


def shadow_findings(repo: Path, agents_rel: str, no_parents: bool) -> tuple[list[dict], dict]:
    finds, edits = [], {}
    tracked = set((git(repo, "ls-files", "--", *CLAUDE_FILES) or "").splitlines())
    for name in CLAUDE_FILES:
        p = repo / name
        if not p.exists() and not p.is_symlink():
            continue
        imp = import_line(name, agents_rel)
        if p.is_symlink():
            finds.append({"id": "claude-symlink", "severity": "info", "path": name,
                          "msg": f"{name} is a symlink: fine on macOS/Linux, but a Windows clone "
                                 f"without core.symlinks gets a one-line text file that shadows "
                                 f"AGENTS.md. Prefer an `{imp}` import"})
            continue
        text = read_raw(p)
        kind = classify_claude(text, name, agents_rel)
        if kind == "imports":
            finds.append({"id": "claude-imports", "severity": "info", "path": name,
                          "msg": f"{name} imports AGENTS.md: fine, provided it holds Claude-only deltas"})
        elif name == "CLAUDE.local.md":
            finds.append({"id": "shadowed-by-claude-local", "severity": "warn", "path": name,
                          "msg": "CLAUDE.local.md stops AGENTS.md loading for you (it is personal and "
                                 "usually gitignored, so nobody else sees why). Set Project "
                                 "instructions to claude-md-and-agents-md in your user settings, or "
                                 "delete it"})
            if name in tracked:
                finds.append({"id": "claude-local-committed", "severity": "crit", "path": name,
                              "msg": "CLAUDE.local.md is committed, so it shadows AGENTS.md for "
                                     "everyone: untrack it and add it to .gitignore"})
        else:
            finds.append({"id": f"shadowed-{kind}", "severity": "crit", "path": name,
                          "msg": SHADOW_MSG[kind].format(f=name, imp=imp)})
            if kind == "symlink-text":
                edits[name] = (text, imp + "\n")
            else:
                eol = "\r\n" if "\r\n" in text else "\n"
                edits[name] = (text, imp + eol + eol + text)
    if not no_parents:
        stop = None
        parts = repo.parts
        for i in range(len(parts) - 1):
            if parts[i] == ".claude" and parts[i + 1] == "worktrees":
                stop = Path(*parts[:i])   # a lane under <main>/.claude/worktrees: don't walk past it
        home = Path.home().resolve()
        for anc in repo.parents:
            if stop is not None and (anc == stop or stop in anc.parents or anc in stop.parents):
                break
            for name in CLAUDE_FILES:
                p = anc / name
                if anc == home and name == ".claude/CLAUDE.md":
                    continue   # the user-level file never counts
                if p.is_file():
                    finds.append({"id": "shadowed-by-parent", "severity": "warn", "path": str(p),
                                  "msg": f"{p} sits above this repo, so Claude Code reads CLAUDE.md "
                                         "files instead of AGENTS.md in any session started here"})
    for nested in sorted((git(repo, "ls-files", "*AGENTS.md") or "").splitlines()):
        d = os.path.dirname(nested)
        if not d or d == ".claude" or re.search(r"(^|/)(node_modules|vendor)/", nested):
            continue
        for name in CLAUDE_FILES:
            p = repo / d / name
            if p.is_file() and classify_claude(read_raw(p),
                                               f"{d}/{name}", nested) != "imports":
                finds.append({"id": "nested-shadowed", "severity": "warn", "path": f"{d}/{name}",
                              "msg": f"{d}/{name} shadows {nested}: Claude Code skips a "
                                     "subdirectory's AGENTS.md where it has its own CLAUDE.md"})
    return finds, edits


def slugify(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "section"


def gh_anchor(title: str) -> str:
    return re.sub(r"[^\w\- ]", "", title.lower()).strip().replace(" ", "-")


def split_plan(lines: list[str], repo: Path) -> list[dict]:
    """Moves for the largest movable ## sections until the doc is back under target."""
    total = len(lines)
    if total <= CEILING_LINES:
        return []
    plan = []
    secs = [s for s in h2_sections(lines)
            if s["key"] not in ("commands", "landmines", "deploy", "overview")]
    for s in sorted(secs, key=lambda s: (-(s["end"] - s["start"]), s["start"])):
        size = s["end"] - s["start"]
        if total <= TARGET_LINES or size < MIN_MOVE_LINES:
            break
        body = "\n".join(lines[s["start"] + 1: s["end"]])
        if SETUP_HEADING.match(s["title"]):
            dest, kind, why = "README.md", "readme", "human setup prose belongs in README"
        else:
            refs = [r.split("/")[0] for r in re.findall(r"`([\w.\-]+/[\w./\-]*)`|\]\(([\w.\-]+/[^)#\s]*)", body)
                    for r in r if r]
            dest, kind, why = f"docs/agents/{slugify(s['title'])}.md", "docs", "detail an agent reads on demand"
            if len(refs) >= 3:
                top, cnt = max(((d, refs.count(d)) for d in set(refs)), key=lambda x: (x[1], x[0]))
                if cnt / len(refs) >= 0.6 and (repo / top).is_dir() and top not in ("docs", ".github") \
                        and not any((repo / top / c).exists() for c in CLAUDE_FILES):
                    dest, kind = f"{top}/AGENTS.md", "nested"
                    why = f"{cnt} of {len(refs)} path references are under {top}/"
        plan.append({"section": s["title"], "start": s["start"], "end": s["end"], "lines": size,
                     "destination": dest, "kind": kind, "why": why})
        total -= size - 3
    plan.sort(key=lambda p: p["start"])
    return plan


def move_header(kind: str, dest: str, title: str, repo_name: str) -> str:
    """Opening text for a destination file the split creates."""
    if kind == "nested":
        d = dest.rsplit("/", 1)[0]
        return (f"# Agent Instructions - {d}/\n\n<!-- Nested entry doc: Claude Code loads it when it "
                f"reads a file under {d}/ (unless that folder has its own CLAUDE.md). Deltas and "
                "local landmines only; the root AGENTS.md links here. -->\n")
    if kind == "docs":
        return (f"# {title}\n\n<!-- Moved out of AGENTS.md by repo-doctor `agents-md.py audit "
                "--diff`; AGENTS.md links here. -->\n")
    return f"# {repo_name}\n"


def stub_for(key: str, f: dict) -> str:
    if key == "commands":
        return "## Commands\n\n" + render_commands(f)
    if key == "landmines":
        body = render_landmines(f) or f"- [ ] {TODO_OWNER}: what breaks non-obviously here?"
        return ("## Landmines\n\n<!-- Mandatory. Turn each confirmed TODO(owner) into a numbered "
                "landmine: what breaks, why, and the procedure. -->\n\n" + body)
    if key == "deploy":
        return "## Deploy\n\n" + render_deploy(f)
    return ""


def build_patch(files: dict[str, tuple[str | None, str]]) -> str:
    """Unified diff (git apply-able) for {path: (old text or None, new text)}."""
    out = []
    for path in sorted(files):
        old, new = files[path]
        if old == new:
            continue
        a = (old or "").splitlines(keepends=True)
        b = new.splitlines(keepends=True)
        body = list(difflib.unified_diff(a, b, "/dev/null" if old is None else f"a/{path}",
                                         f"b/{path}", n=3))
        if not body:
            continue
        out.append(f"diff --git a/{path} b/{path}\n")
        if old is None:
            out.append("new file mode 100644\n")
        for line in body:
            out.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(out)


def cmd_audit(args) -> int:
    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"agents-md: not a directory: {repo}")
        return EX_NOTFOUND
    rel = "AGENTS.md" if (repo / "AGENTS.md").is_file() else (
        ".claude/AGENTS.md" if (repo / ".claude/AGENTS.md").is_file() else None)
    f = load_facts(repo, args.facts, None if args.facts else
                   "repo,manifests,ddev,deploy,ci,tests,generated,history,outliers,env")
    if f is None:
        return EX_ERR
    finds: list[dict] = []
    files: dict = {}
    data: dict = {"repo": str(repo), "agents_md": rel}
    if rel is None:
        finds.append({"id": "missing-agents-md", "severity": "crit", "path": "AGENTS.md",
                      "msg": "no AGENTS.md: agents enter blind. Draft one with "
                             "`agents-md.py scaffold --repo <path>` (verified facts only)"})
        c_finds, _ = shadow_findings(repo, "AGENTS.md", args.no_parents)
        finds += [x for x in c_finds if x["id"] == "shadowed-by-parent"]
    else:
        text = read_raw(repo / rel)
        eol = "\r\n" if "\r\n" in text else "\n"
        lines = text.splitlines()
        an = analyze_doc(text)
        data.update({"lines": an["lines"], "sections": an["sections"],
                     "coverage": coverage_letters(an["sections"])})
        if an["lines"] > CEILING_LINES:
            finds.append({"id": "over-ceiling", "severity": "warn", "path": rel,
                          "msg": f"{an['lines']} lines, over the {CEILING_LINES}-line ceiling (Claude Code: "
                                 "longer files consume more context and reduce adherence). See the split plan"})
        elif an["lines"] > TARGET_LINES:
            finds.append({"id": "over-target", "severity": "info", "path": rel,
                          "msg": f"{an['lines']} lines: under the {CEILING_LINES} ceiling, over the "
                                 f"{TARGET_LINES}-line target"})
        deploys = bool((f.get("deploy") or {}).get("appspec") or (f.get("deploy") or {}).get("ci_deploy_steps")
                       or (f.get("deploy") or {}).get("surfaces"))
        for key in SECTION_ORDER:
            if an["sections"][key]:
                continue
            sev = "warn" if key in REQUIRED_WARN or (key == "deploy" and deploys) else (
                None if key == "deploy" else "info")
            if sev:
                finds.append({"id": f"missing-section-{key}", "severity": sev, "path": rel,
                              "msg": f"no {key} section" + (" (mandatory)" if key == "landmines" else "")
                              + (" although the repo has deploy config" if key == "deploy" else "")})
        if an["sections"]["landmines"] and an["landmine_items"] == 0:
            finds.append({"id": "empty-landmines", "severity": "warn", "path": rel,
                          "msg": "the Landmines section has no entries (only prompts or prose)"})
        if an["owner_todos"]:
            finds.append({"id": "owner-todos", "severity": "warn", "path": rel,
                          "msg": f"{an['owner_todos']} unanswered {TODO_OWNER} question(s): the draft isn't finished"})
        if an["draft_header"]:
            finds.append({"id": "draft-header", "severity": "warn", "path": rel,
                          "msg": "the scaffold's DRAFT comment is still at the top"})
        if an["untested"]:
            finds.append({"id": "untested-commands", "severity": "info", "path": rel,
                          "msg": f"{an['untested']} command(s) still tagged {UNTESTED}"})
        for h in an["setup_headings"]:
            finds.append({"id": "human-setup-prose", "severity": "info", "path": rel,
                          "msg": f'"{h}" reads like human setup prose: it belongs in README.md'})
        new = list(lines)
        for i, cmd, fenced in command_refs(lines):
            why = check_command(cmd, f, repo)
            if not why:
                continue
            finds.append({"id": "dead-command", "severity": "warn", "path": f"{rel}:{i + 1}",
                          "msg": f"`{cmd}`: {why}"})
            tag = f"agents-md: {why}"
            if tag not in new[i]:
                new[i] = new[i] + (f"  # {tag}" if fenced else f" <!-- {tag} -->")
        since, man = staleness(repo, rel)
        data.update({"commits_since": since, "manifest_commits_since": man})
        if since is not None and since > FRESH_COMMITS:
            finds.append({"id": "stale", "severity": "warn", "path": rel,
                          "msg": f"last touched {since} commits ago ({man or 0} of them changed "
                                 "package.json/composer.json/Makefile/justfile): verify every claim, "
                                 "then touch it in the fixing commit"})
        plan = split_plan(new, repo)
        data["split_plan"] = [{k: v for k, v in p.items() if k not in ("start", "end")} for p in plan]
        left = an["lines"] - sum(p["lines"] - 3 for p in plan)   # each move leaves 3 lines
        if an["lines"] > CEILING_LINES and left > TARGET_LINES:
            finds.append({"id": "split-insufficient", "severity": "info", "path": rel,
                          "msg": f"about {left} lines remain after moving every movable section: the "
                                 "bulk is in Commands or Landmines, which the patch never moves. Trim "
                                 "them by hand, or move a subsystem's landmines into its nested AGENTS.md"})
        # Pass 1, document order: append each moved body to its destination file.
        # Pass 2, bottom-up: replace each moved section's body in AGENTS.md with a link,
        # so earlier line ranges stay valid. The heading line always stays behind.
        for p in plan:
            body = "\n".join(new[p["start"] + 1: p["end"]]).strip("\n")
            title, dest = p["section"], p["destination"]
            if dest not in files:
                old = read_raw(repo / dest) \
                    if (repo / dest).is_file() else None
                files[dest] = (old, old if old is not None else move_header(p["kind"], dest, title, repo.name))
            current = files[dest][1]
            if p["kind"] == "docs" and current.rstrip("\n").endswith("-->") and f"# {title}\n" in current:
                files[dest] = (files[dest][0], current.rstrip("\n") + "\n\n" + body + "\n")
            else:
                files[dest] = (files[dest][0], current.rstrip("\n") + f"\n\n## {title}\n\n{body}\n")
        for p in reversed(plan):
            dest = p["destination"]
            if p["kind"] == "readme":
                pointer = f"Human setup steps: [README.md](README.md#{gh_anchor(p['section'])})."
            elif p["kind"] == "nested":
                pointer = (f"Moved to [{dest}]({dest}), which loads when an agent works under "
                           f"`{dest.rsplit('/', 1)[0]}/`.")
            else:
                pointer = f"Moved to [{dest}]({dest}); read it when this topic matters."
            new[p["start"] + 1: p["end"]] = ["", pointer, ""]
        for dest in {p["destination"] for p in plan}:
            old_d, new_d = files[dest]
            if old_d and "\r\n" in old_d:   # keep a CRLF destination CRLF throughout
                files[dest] = (old_d, new_d.replace("\r\n", "\n").replace("\n", "\r\n"))
        stubs = [stub_for(k, f) for k in ("commands", "landmines", "deploy")
                 if any(x["id"] == f"missing-section-{k}" and x["severity"] == "warn" for x in finds)]
        new_text = eol.join(new)
        if stubs:
            new_text = new_text.rstrip("\r\n") + eol + eol + (eol + eol).join(
                s.replace("\n", eol) for s in stubs if s)
        if new_text.rstrip("\r\n") != text.rstrip("\r\n"):
            files[rel] = (text, new_text.rstrip("\r\n") + eol)
        c_finds, c_edits = shadow_findings(repo, rel, args.no_parents)
        finds += c_finds
        for name, (old, newc) in c_edits.items():
            files[name] = (old, newc)
    sev_rank = {"crit": 0, "warn": 1, "info": 2}
    finds.sort(key=lambda x: (sev_rank[x["severity"]], x["id"], x["path"]))
    data["findings"] = finds
    patch = build_patch(files)
    data["diff"] = patch or None
    bad = any(x["severity"] in ("crit", "warn") for x in finds)
    if args.diff:
        sys.stdout.buffer.write(patch.encode("utf-8"))
        sys.stdout.flush()
        eecho(f"agents-md: {len(finds)} finding(s); patch touches {patch.count('diff --git')} file(s)")
    elif args.json:
        emit_json({"data": data, "meta": {"schema": SCHEMA_AUDIT, "findings": len(finds),
                                          "crit": sum(x["severity"] == "crit" for x in finds),
                                          "warn": sum(x["severity"] == "warn" for x in finds)}})
    else:
        head = f"agents-md audit: {rel or 'no AGENTS.md'}"
        if rel:
            head += f" ({data['lines']} lines, coverage {data['coverage']}, "
            head += (f"{data['commits_since']} commits since last touch)" if data["commits_since"] is not None
                     else "not committed yet)")
        print(head)
        for x in finds:
            print(f"  {x['severity'].upper():<5} {x['msg']} [{x['path']}]")
        for p in data.get("split_plan") or []:
            print(f"  SPLIT {p['section']!r} ({p['lines']} lines) -> {p['destination']}: {p['why']}")
        if patch:
            print("  patch: agents-md.py audit --diff > agents-md.patch && git apply agents-md.patch")
    return EX_FINDINGS if bad else EX_OK


# === SURVEY ===


class GhUnavailable(Exception):
    pass


def gh_base() -> list[str] | None:
    override = os.environ.get("AGENTS_MD_GH")
    if override:
        return [sys.executable, override] if override.endswith(".py") else [override]
    exe = shutil.which("gh")
    return [exe] if exe else None


def gh_run(base: list[str], args: list[str]) -> tuple[int, str]:
    # GET only, by construction: no -X/--method, no -f/-F/--input (those switch gh api to POST).
    try:
        r = subprocess.run(base + args, capture_output=True, timeout=60, encoding="utf-8",
                           errors="replace")
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError as exc:
        raise GhUnavailable(str(exc))
    return r.returncode, r.stdout


def gh_api(base: list[str], path: str):
    rc, out = gh_run(base, ["api", path])
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def blob_text(base: list[str], full: str, sha: str) -> str | None:
    b = gh_api(base, f"repos/{full}/git/blobs/{sha}")
    if not isinstance(b, dict) or "content" not in b:
        return None
    try:
        return base64.b64decode(b["content"]).decode("utf-8", errors="replace")
    except (ValueError, TypeError):
        return None


def survey_repo(base: list[str], full: str, branch: str | None) -> dict:
    row: dict = {"repo": full, "default_branch": branch, "agents_md": False, "claude_md": [],
                 "shadowed": False, "lines": None, "commits_since": None, "coverage": None,
                 "sections": None, "nested_agents_md": 0, "issues": [], "status": "ok"}
    if not branch:
        row.update(status="empty", issues=[])
        return row
    tree = gh_api(base, f"repos/{full}/git/trees/{quote(branch, safe='')}?recursive=1")
    if not isinstance(tree, dict) or "tree" not in tree:
        row.update(status="unreadable", issues=["unreadable"])
        return row
    entries = {e["path"]: e for e in tree["tree"] if isinstance(e, dict) and "path" in e}
    row["tree_truncated"] = bool(tree.get("truncated"))
    rel = "AGENTS.md" if "AGENTS.md" in entries else (".claude/AGENTS.md" if ".claude/AGENTS.md" in entries else None)
    row["agents_md"] = rel is not None
    row["nested_agents_md"] = sum(1 for p in entries if p.endswith("/AGENTS.md") and not p.startswith(".claude/")
                                  and not re.search(r"(^|/)(node_modules|vendor)/", p))
    kinds = {}
    for name in CLAUDE_FILES:
        e = entries.get(name)
        if not e:
            continue
        txt = blob_text(base, full, e["sha"]) or ""
        kinds[name] = "symlink" if e.get("mode") == "120000" else classify_claude(txt, name, rel or "AGENTS.md")
    row["claude_md"] = [{"path": k, "kind": v} for k, v in kinds.items()]
    issues = []
    if rel:
        text = blob_text(base, full, entries[rel]["sha"])
        if text is None:
            issues.append("unreadable")
        else:
            an = analyze_doc(text)
            row.update(lines=an["lines"], sections=an["sections"], coverage=coverage_letters(an["sections"]))
            if an["lines"] > CEILING_LINES:
                issues.append("over-200")
            if not (an["sections"]["commands"] and an["sections"]["landmines"]):
                issues.append("incomplete")
            if an["owner_todos"] or an["draft_header"]:
                issues.append("draft")
        commits = gh_api(base, f"repos/{full}/commits?sha={quote(branch, safe='')}&path={quote(rel)}&per_page=1")
        if isinstance(commits, list) and commits and isinstance(commits[0], dict):
            cmp = gh_api(base, f"repos/{full}/compare/{commits[0]['sha']}...{quote(branch, safe='')}")
            if isinstance(cmp, dict) and isinstance(cmp.get("ahead_by"), int):
                row["commits_since"] = cmp["ahead_by"]
                if cmp["ahead_by"] > FRESH_COMMITS:
                    issues.append("stale")
        shadow = [k for k, v in kinds.items() if v not in ("imports", "symlink")]
        row["shadowed"] = bool(shadow)
        if shadow:
            issues.insert(0, "shadowed")
    else:
        issues.append("claude-only" if kinds else "missing")
    if "CLAUDE.local.md" in kinds:
        issues.append("claude-local-committed")
    row["issues"] = issues
    row["status"] = ",".join(issues) if issues else "ok"
    return row


def cmd_survey(args) -> int:
    if bool(args.org) == bool(args.remote):
        eecho("agents-md: survey needs exactly one of --org OWNER or --remote OWNER/NAME")
        return EX_USAGE
    if args.org and not re.match(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", args.org):
        eecho(f"agents-md: invalid owner {args.org!r}")
        return EX_USAGE
    if args.remote and not re.match(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$", args.remote):
        eecho(f"agents-md: invalid OWNER/NAME {args.remote!r}")
        return EX_USAGE
    base = gh_base()
    if not base:
        eecho("agents-md: gh not installed (https://cli.github.com)")
        return EX_PRECOND
    try:
        if args.org:
            listing = ["repo", "list", args.org, "--limit", str(args.limit),
                       "--json", "nameWithOwner,defaultBranchRef,isArchived"]
            if not args.include_archived:
                listing.append("--no-archived")
            rc, out = gh_run(base, listing)
            if rc != 0:
                eecho(f"agents-md: gh repo list {args.org} failed (not authenticated, offline or rate-limited?)")
                return EX_UNAVAIL
            try:
                repos = [(r["nameWithOwner"], (r.get("defaultBranchRef") or {}).get("name"))
                         for r in json.loads(out)]
            except (json.JSONDecodeError, KeyError, TypeError):
                eecho("agents-md: gh repo list returned unparsable JSON")
                return EX_UNAVAIL
        else:
            info = gh_api(base, f"repos/{args.remote}")
            if not isinstance(info, dict):
                eecho(f"agents-md: cannot read {args.remote} (not found, not authenticated or offline)")
                return EX_UNAVAIL
            repos = [(args.remote, info.get("default_branch"))]
        rows = []
        for i, (full, branch) in enumerate(sorted(repos), 1):
            eecho(f"agents-md: [{i}/{len(repos)}] {full}")
            rows.append(survey_repo(base, full, branch))
    except GhUnavailable as exc:
        eecho(f"agents-md: cannot run gh: {exc}")
        return EX_UNAVAIL
    has_a = [r for r in rows if r["agents_md"]]
    meta = {"schema": SCHEMA_SURVEY, "owner": args.org or args.remote.split("/")[0],
            "repos": len(rows),
            "agents_md_only": sum(1 for r in has_a if not r["claude_md"]),
            "claude_md_only": sum(1 for r in rows if not r["agents_md"] and r["claude_md"]),
            "both": sum(1 for r in has_a if r["claude_md"]),
            "neither": sum(1 for r in rows if "missing" in r["issues"]),
            "shadowed": sum(1 for r in rows if r["shadowed"]),
            "over_200_lines": sum(1 for r in rows if "over-200" in r["issues"]),
            "stale": sum(1 for r in rows if "stale" in r["issues"]),
            "incomplete": sum(1 for r in rows if "incomplete" in r["issues"]),
            "unreadable": sum(1 for r in rows if r["status"] == "unreadable"),
            "empty": sum(1 for r in rows if r["status"] == "empty")}
    if args.json:
        emit_json({"data": rows, "meta": meta})
    else:
        width = max([len(r["repo"]) for r in rows] + [4])
        print(f"{'REPO'.ljust(width)}  AGENTS  CLAUDE  SHADOW  LINES  SINCE  COVER   STATUS")
        for r in rows:
            claude = "+".join("L" if c["path"] == "CLAUDE.local.md" else "C" for c in r["claude_md"]) or "-"
            print(f"{r['repo'].ljust(width)}  {'yes' if r['agents_md'] else '-':<6}  {claude:<6}  "
                  f"{'YES' if r['shadowed'] else '-':<6}  {str(r['lines'] or '-'):>5}  "
                  f"{str(r['commits_since'] if r['commits_since'] is not None else '-'):>5}  "
                  f"{r['coverage'] or '-':<6}  {r['status']}")
        eecho("coverage letters: O overview, C commands, L landmines, D deploy, S structure, V conventions")
        eecho(f"summary: {meta['repos']} repos, {meta['agents_md_only']} AGENTS.md only, "
              f"{meta['claude_md_only']} CLAUDE.md only, {meta['both']} both, {meta['neither']} neither, "
              f"{meta['shadowed']} shadowed, {meta['over_200_lines']} over 200 lines, {meta['stale']} stale")
    flagged = any(r["issues"] and r["status"] != "empty" for r in rows)
    return EX_FINDINGS if flagged else EX_OK


# === CLI ===


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser(
        description="Create, audit/upgrade and survey AGENTS.md files (repo-doctor protocol).",
        epilog="EXAMPLES:\n"
               "  agents-md.py scaffold --repo path/to/site > AGENTS.draft.md\n"
               "  agents-md.py audit --repo path/to/site --diff > agents-md.patch\n"
               "  agents-md.py survey --org my-org --json\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sp = sub.add_parser("scaffold", help="draft an AGENTS.md from repo-scan facts")
    sp.add_argument("--repo", default=".")
    sp.add_argument("--facts", help="saved `repo-scan.py --json` output")
    sp.add_argument("--archetype", default="auto",
                    choices=["auto", "php-cms", "node-app", "python-service", "static-site"])
    sp.add_argument("--write", action="store_true", help="create <repo>/AGENTS.md (never overwrites)")
    sp.add_argument("--json", action="store_true")
    ap_a = sub.add_parser("audit", help="audit an AGENTS.md; --diff proposes an upgrade patch")
    ap_a.add_argument("--repo", default=".")
    ap_a.add_argument("--facts", help="saved `repo-scan.py --json` output")
    ap_a.add_argument("--diff", action="store_true", help="print only a git-apply-able patch")
    ap_a.add_argument("--no-parents", action="store_true",
                      help="skip the check for CLAUDE.md files above the repo")
    ap_a.add_argument("--json", action="store_true")
    ap_s = sub.add_parser("survey", help="read-only org survey through gh api")
    ap_s.add_argument("--org", help="GitHub owner (org or user)")
    ap_s.add_argument("--remote", help="survey a single OWNER/NAME")
    ap_s.add_argument("--limit", type=int, default=200)
    ap_s.add_argument("--include-archived", action="store_true")
    ap_s.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if args.cmd is None:
        ap.print_help()
        return EX_USAGE
    if args.cmd == "audit" and args.diff and args.json:
        eecho("agents-md: --diff and --json are mutually exclusive (--json already carries data.diff)")
        return EX_USAGE
    if args.cmd == "survey" and args.limit < 1:
        eecho("agents-md: --limit must be >= 1")
        return EX_USAGE
    return {"scaffold": cmd_scaffold, "audit": cmd_audit, "survey": cmd_survey}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
