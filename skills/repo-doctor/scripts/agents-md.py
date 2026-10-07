#!/usr/bin/env python3
"""agents-md - create, audit/upgrade and survey AGENTS.md files against the protocol.

Usage:   agents-md.py scaffold [--repo PATH] [--facts FILE]
                               [--archetype A | --dir FOLDER | --architecture] [--write] [--json]
         agents-md.py audit    [--repo PATH] [--facts FILE] [--diff | --explain ID] [--no-parents]
                               [--json]
         agents-md.py explain  [--repo PATH] FOLDER [--tool ID|all] [--json]
         agents-md.py survey   (--org OWNER | --remote OWNER/NAME) [--limit N]
                               [--include-archived] [--json]
Input:   scaffold/audit: a local checkout. Facts come from repo-scan.py (beside this
         script) unless --facts names a saved `repo-scan.py --json` output.
         survey: GitHub through the `gh` CLI, GET requests only.
Output:  scaffold: the AGENTS.md draft (markdown) on stdout, or the --json envelope
           claude-mods.repo-doctor.agents-md-scaffold/v1. --write creates <repo>/AGENTS.md
           and prints nothing. --dir drafts <repo>/<FOLDER>/AGENTS.md instead: a nested
           doc holding only what the root AGENTS.md doesn't say. --architecture drafts
           ARCHITECTURE.md (entry points and codemap named from facts, never linked).
         audit: a findings report, or --json (claude-mods.repo-doctor.agents-md-audit/v1),
           whose data.docs[] has one record per tracked AGENTS.md (root and nested).
           --explain ID prints one finding's rule, its source and this repo's evidence.
           --diff prints ONLY a git-apply-able patch (empty when there is nothing to add).
         survey: one aligned row per repo, or --json
           (claude-mods.repo-doctor.agents-md-survey/v1).
         explain: the files each tool loads for work in FOLDER, in order, with the reason
           and size, or --json (claude-mods.repo-doctor.agents-md-explain/v1). Repo files
           only: user-scope files (~/.claude, ~/.codex) are per-machine and left out.
Stderr:  progress, summaries, legends, warnings, errors
Exit:    0 ok (audit/survey: no warn or crit finding), 1 error (repo-scan failed),
         2 usage, 3 repo path (or --dir folder) not found, 5 precondition (AGENTS.md already exists for
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
  agents-md.py scaffold --repo path/to/monorepo --dir packages/engine --write
  agents-md.py scaffold --repo path/to/monorepo --architecture > ARCHITECTURE.md
  agents-md.py audit --repo path/to/site
  agents-md.py audit --repo path/to/site --diff > agents-md.patch && git apply agents-md.patch
  agents-md.py survey --org my-org --json | jq '.data[] | select(.shadowed)'
  agents-md.py explain packages/engine --tool all

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
#   SCAFFOLD      archetype choice, template fill, nested --dir and --architecture drafts,
#                 --write
#   EXPLAIN       per-tool load engine (tool-profiles.json): files, reasons, sizes, caps
#   FINDINGS      the id registry behind audit --explain
#   AUDIT         findings, dead commands, staleness, nested docs and root pointers,
#                 trigger pointers, split plan, the ruled-out record, the --diff patch
#   SURVEY        gh plumbing (GET only), per-repo remote analysis, table
#   CLI           argument parsing and dispatch

from __future__ import annotations

import argparse
import base64
import difflib
import fnmatch
import json
import os
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
from datetime import date
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
# The line budget assumes wrapped prose. A file that reaches the same context cost in
# fewer, longer lines is over the same budget, so size is checked too: 80 characters a
# line. repo-doctor.py's ENTRY_LEAN_CHARS must match (check-memory-docs.py gates it).
CHARS_PER_LINE = 80
TARGET_CHARS = TARGET_LINES * CHARS_PER_LINE     # 12,000
CEILING_CHARS = 16000                            # CEILING_LINES * CHARS_PER_LINE
LONG_LINE_CHARS = 500   # one such line costs what six or more wrapped lines do
FRESH_COMMITS = 15      # same threshold as repo-doctor.py's entry_docs dimension
MIN_MOVE_LINES = 10     # sections shorter than this are not worth a split move
POINTER_CHARS = 120     # what a moved section leaves behind: heading, blank, link line, blank
# A nested AGENTS.md is paid for by every tool that loads it, and some load them all, so
# its budget is a fifth of the root's. repo-doctor.py's NESTED_* constants must match.
NESTED_TARGET_LINES = 40
NESTED_CEILING_LINES = 60
NESTED_CEILING_CHARS = NESTED_CEILING_LINES * CHARS_PER_LINE   # 4,800
# What Claude Code loads for work in one folder: a root at its ceiling plus one nested doc
# at its ceiling. A deeper chain than that is paid for on every task in the folder.
LOAD_CEILING_CHARS = CEILING_CHARS + NESTED_CEILING_CHARS       # 20,800
SCHEMA_EXPLAIN = "claude-mods.repo-doctor.agents-md-explain/v1"
# ARCHITECTURE.md (spec N6): the root is recommended; docs/ is accepted when it holds a
# codemap. It has the root entry doc's budget, and its staleness is layout drift, never age.
ARCH_FILES = ("ARCHITECTURE.md", "docs/ARCHITECTURE.md")
ARCH_POINTER = "Read [{path}]({up}{path}) before adding a module or moving code between packages."
# The layout fingerprint closes the draft: sha1 of the sorted layout (repo-scan
# data.architecture.layout_fingerprint) and the folders it covered, so the audit can name
# what was added or removed. Grammar: <!-- layout: <40 hex> (...) <folder/> ... -->
LAYOUT_RE = re.compile(r"<!--\s*layout:\s*([0-9a-f]{40})(.*?)-->", re.S)
CODE_EXTS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".go", ".rs", ".php", ".rb", ".java",
             ".kt", ".cs", ".c", ".h", ".cpp", ".hpp", ".swift", ".scala", ".vue", ".svelte", ".sh")
# Other tools' loading rules change fast, so they live only in this file, each fact with
# a source and a verified date behind check-tool-profiles.py --live. Never hard-code a
# tool's behaviour in this script.
PROFILES = TEMPLATES / "tool-profiles.json"
EX_OK, EX_ERR, EX_USAGE, EX_NOTFOUND, EX_PRECOND, EX_UNAVAIL, EX_FINDINGS = 0, 1, 2, 3, 5, 7, 10

# Section grammar: the first rule whose pattern matches a ## or ### heading names it.
# Order matters ("Testing gotchas" is a landmine section, not a commands section).
SECTION_RULES = (
    ("landmines", r"landmine|gotcha|pitfall|footgun|hazard|trap|caveat|warning|known issue|"
                  r"sharp edge|watch out|beware|danger|don'?t"),
    ("deploy", r"deploy|release|shipping|hosting|ci ?/ ?cd|pipeline|production|infrastructure"),
    # Not "quick reference": that heading holds tips as often as commands, and Commands
    # sections never move in a split, so a wrong match pins prose in place.
    ("commands", r"command|script|build|test|running|\brun\b|develop|workflow|task|"
                 r"quick ?start|usage|\bcheck|cli\b|make|just"),
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
    widths = [len(l) for l in lines]
    longest = max(range(len(widths)), key=lambda i: widths[i]) if widths else 0
    return {"lines": len(lines), "chars": sum(widths) + len(widths),   # LF-equivalent size
            "long_lines": sum(w > LONG_LINE_CHARS for w in widths),
            "longest_line": {"line": longest + 1, "chars": widths[longest] if widths else 0},
            "sections": cover, "landmine_items": items,
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


# A CLAUDE.md-family file whose non-blank lines mostly repeat AGENTS.md is a copy (what
# Claude Code's `/import` writes). Its fix is the import plus the lines that differ:
# prepending the import to the copy would load the same text twice.
COPY_RATIO = 0.6
COPY_MIN_LINES = 3


def is_agents_import(line: str) -> bool:
    s = line.strip()
    return s.startswith("@") and s.endswith("AGENTS.md")


def split_copy(text: str, agents_text: str) -> tuple[int, list[str]]:
    """(lines repeated from AGENTS.md, the other lines in order, blank runs collapsed).
    Import lines count as neither and are dropped from the kept lines."""
    agents = {l.strip() for l in agents_text.splitlines() if l.strip()}
    repeated, kept = 0, []
    for line in text.splitlines():
        s = line.strip()
        if s and s in agents:
            repeated += 1
        elif s and is_agents_import(s):
            continue
        elif s or (kept and kept[-1].strip()):
            kept.append(line)
    while kept and not kept[-1].strip():
        kept.pop()
    return repeated, kept


def is_copy(text: str, agents_text: str) -> bool:
    repeated, kept = split_copy(text, agents_text)
    others = sum(1 for l in kept if l.strip())
    return repeated >= COPY_MIN_LINES and repeated >= COPY_RATIO * (repeated + others)


def import_with_deltas(text: str, agents_text: str, imp: str) -> str:
    eol = "\r\n" if "\r\n" in text else "\n"
    _, kept = split_copy(text, agents_text)
    return imp + eol + (eol + eol.join(kept) + eol if kept else "")


SHADOW_MSG = {
    "copy": "{f} repeats AGENTS.md, so Claude Code reads this copy instead and the two drift "
            "apart (Claude Code's `/import` writes such a file). Replace it with `{imp}` plus "
            "only the lines that differ",
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


def load_facts(repo: Path, facts_file: str | None, only: str | None = None,
               dirs: list[str] | None = None) -> dict | None:
    """repo-scan facts; dirs adds folders to data.manifests_by_dir (repo-scan --dir)."""
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
    for d in dirs or []:
        cmd += ["--dir", d]
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
    for t in tests:
        # Suites found by convention (repo-scan _convention_tests): offer the runner only
        # at the top of a tests/ folder, where it plausibly runs everything.
        fw, cfg = t["framework"], t["config"]
        if fw == "Shell scripts" and t.get("runners") and re.match(r"^(tests?|spec)/[^/]+\.sh$", cfg) \
                and cfg.lower() not in declared:
            out.append(("Tests", f"bash {cfg}", cfg, "shell test runner"))
        elif fw == "go test" and "go test" not in declared:
            out.append(("Tests", "go test ./...", cfg, "Go tests"))
        elif fw == "cargo test" and "cargo test" not in declared:
            out.append(("Tests", "cargo test", cfg, "Rust tests"))
    for name, key, prog in (("makefile", "targets", "make"), ("justfile", "recipes", "just")):
        block = m.get(name) or {}
        # A just recipe named "default" lists the others by convention; `just` alone runs it.
        for t in [t for t in block.get(key, []) if not t.get("alias_of")
                  and not (prog == "just" and t["name"] == "default")][:8]:
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
    return "\n".join(["Every command below is declared in the repo but was not run by the generator.",
                      f"Run each once, then delete its `{UNTESTED}` tag.", ""] + command_block(entries))


def command_block(entries: list[tuple[str, str, str, str]]) -> list[str]:
    """A fenced bash block, one command per line, grouped, each citing its source."""
    width = min(max(len(c[1]) for c in entries) + 2, 40)
    lines = ["```bash"]
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
    return lines


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

    def order(a: dict) -> tuple:
        return rank.get(a["kind"], 9), -a["files"], a["path"]
    # Areas holding 5% or more of the files always get a row, whatever their kind: a
    # kind-first cut once dropped a 1,367-file folder and kept a one-file one.
    total = sum(a["files"] for a in areas) or 1
    major = [a for a in areas if a["files"] * 20 >= total]
    rest = sorted((a for a in areas if a not in major), key=order)
    rows = ["| Path | What lives there |", "|---|---|"]
    for a in sorted((major + rest)[:max(12, len(major))], key=order):
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
    # Without a web manifest, only a real static-site marker (repo-scan STATIC_SITE_FILES)
    # earns static-site; tooling, script and infra repos get the generic archetype.
    return "static-site" if m.get("static_site") else "generic"


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


def glob_member(d: str, glob: str) -> bool:
    """Workspace globs match one path segment per `*`; `**` matches any depth."""
    parts, gparts = d.strip("/").split("/"), glob.strip("/").split("/")
    if "**" in gparts:
        return fnmatch.fnmatchcase(d.strip("/"), glob.strip("/").replace("**", "*"))
    return len(parts) == len(gparts) and all(fnmatch.fnmatchcase(a, b) for a, b in zip(parts, gparts))


def workspace_runner(f: dict, d: str, pkg: dict) -> str | None:
    """The root-runnable prefix for a workspace member's scripts, else None. npm takes
    the folder; pnpm, yarn and bun take the member's package name."""
    m = f.get("manifests") or {}
    if not any(glob_member(d, g) for w in m.get("workspaces") or [] for g in w.get("globs", [])):
        return None
    pm = ((m.get("package_json") or {}).get("package_manager") or {}).get("name", "npm")
    if pm == "npm":
        return f"npm -w {d.rstrip('/')} run"
    name = pkg.get("name")
    return {"pnpm": f"pnpm --filter {name}", "yarn": f"yarn workspace {name}",
            "bun": f"bun run --filter {name}"}.get(pm) if name else None


def nested_commands(f: dict, d: str, root_text: str) -> tuple[str, list, bool]:
    """(the Commands body, its entries, whether they run from the root). A command the
    root already names is left out: the nested doc carries deltas only."""
    mb = dict(((f.get("manifests_by_dir") or {}).get(d)) or {})
    pkg = mb.get("package_json") or {}
    prefix = workspace_runner(f, d, pkg) if pkg and not pkg.get("error") else None
    rooted = []
    if prefix:
        for s in sorted(pkg.get("scripts", []), key=lambda s: _script_order(s["name"]))[:12]:
            rooted.append(("Scripts", f"{prefix} {s['name']}", s["source"], s["command"]))
        mb.pop("package_json")
    tests = [t for t in f.get("tests") or [] if str(t.get("config", "")).startswith(d)]
    local = [e for e in command_entries({"manifests": mb, "tests": tests})
             if not (prefix and e[0] == "Dependencies")]   # a workspace installs from the root
    rooted = [e for e in rooted if e[1] not in root_text]
    local = [e for e in local if e[1] not in root_text]
    if not rooted and not local:
        return (f"- [ ] {TODO_OWNER}: which commands build and test `{d}`? Its own manifest "
                "declares none the root doesn't already list.", [], False)
    out = [f"Declared in `{d}`; not run by the generator.",
           f"Run each once, then delete its `{UNTESTED}` tag."]
    if rooted:
        out += ["", "Run from the repo root:", ""] + command_block(rooted)
    if local:
        out += ["", f"Run from `{d}`:", ""] + command_block(local)
    return "\n".join(out), rooted + local, bool(rooted)


def render_nested(f: dict, d: str, root_rel: str | None, root_text: str) -> tuple[str, dict]:
    """The nested draft and its --json extras. d ends in "/"."""
    tmpl = (TEMPLATES / "nested.md").read_text(encoding="utf-8")
    tmpl = re.sub(r"(?s)\A\s*<!--.*?-->\s*", "", tmpl, count=1)
    mb = (f.get("manifests_by_dir") or {}).get(d) or {}
    pkg = mb.get("package_json") or {}
    rec = next((r for r in (f.get("nesting") or {}).get("recommend") or [] if r["dir"] == d), None)
    why = ("repo-scan recommends this folder: " + ", ".join(f"{s['kind']} ({s['detail']})" for s in rec["signals"])
           if rec else "repo-scan does not recommend nesting here; confirm the folder has its own contract")
    note = "\n".join([f"<!-- {DRAFT_MARK} agents-md.py scaffold --dir from repo-scan facts."]
                     + textwrap.wrap(why + ".", 84, initial_indent="     ", subsequent_indent="     ")
                     + [f"     Before committing: answer or delete each {TODO_OWNER}, run each command once",
                        f"     and drop its {UNTESTED} tag, then delete this comment. -->"])
    depth = d.count("/")
    scope = f"Applies to `{d}` and below" + (
        f"; extends the root [AGENTS.md]({'../' * depth}{root_rel})." if root_rel else ".")
    desc = next(((v.get("description"), v.get("path")) for v in (mb.get(k) or {} for k in
                 ("package_json", "composer_json", "python")) if isinstance(v.get("description"), str)
                 and v["description"].strip()), None)
    overview = (f"{str(desc[0]).strip()} (description from `{desc[1]}`)" if desc else
                f"{TODO_OWNER}: one line on what `{d}` is for, beyond what the root says.")
    commands, entries, rooted = nested_commands(f, d, root_text)
    cands = [c for c in f.get("candidates") or [] if c.get("paths") and c["kind"] != "workspaces"
             and all(x.startswith(d) for x in c["paths"])]
    cands = uncovered_candidates(root_text, cands)
    lm = [f"- [ ] {TODO_OWNER}: {c['question']} Evidence: "
          f"{', '.join(dict.fromkeys(cite(e) for e in c['evidence'][:3]))}." for c in cands[:8]]
    landmines = "\n".join(lm) if lm else (
        f"- [ ] {TODO_OWNER}: what breaks non-obviously in `{d}` that the root's Landmines don't "
        "cover? Delete this section if nothing does.")
    title = pkg.get("name") or d.rstrip("/")
    for k, v in {"TITLE": title, "DRAFT_NOTE": note, "SCOPE": scope, "OVERVIEW": overview,
                 "COMMANDS": commands, "LANDMINES": landmines}.items():
        tmpl = tmpl.replace("{{" + k + "}}", v)
    # Deltas only: a line the root already carries word for word is dropped (headings,
    # fences and short lines stay, since they repeat by nature).
    root_lines = {l.strip() for l in root_text.splitlines()}
    keep = [l for l in tmpl.splitlines() if len(l.strip()) < 12 or l.lstrip().startswith(("#", "```"))
            or l.strip() not in root_lines]
    draft = re.sub(r"\n{3,}", "\n\n", "\n".join(keep)).strip() + "\n"
    return draft, {"workspace_form": rooted, "signals": rec["signals"] if rec else [],
                   "commands": [{"group": g, "command": c, "source": s, "note": n} for g, c, s, n in entries],
                   "candidates": cands}


def create_file(dest: Path, text: str) -> int:
    """Create dest (tmp + rename), never overwrite: EX_OK, or EX_PRECOND on a lost race."""
    fd, tmp = tempfile.mkstemp(dir=str(dest.parent), prefix=f".{dest.name}.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    if dest.exists():   # lost a race: someone created it meanwhile
        os.unlink(tmp)
        eecho(f"agents-md: {dest} appeared during the scaffold; not overwritten")
        return EX_PRECOND
    os.replace(tmp, dest)
    eecho(f"agents-md: created {dest}")
    return EX_OK


def inside_repo(repo: Path, rel: str) -> bool:
    """rel names a folder inside repo: not absolute, no drive, no .., and it resolves there."""
    if not rel or rel.startswith("/") or re.match(r"^[A-Za-z]:", rel) or ".." in rel.split("/"):
        return False
    try:
        (repo / rel).resolve().relative_to(repo.resolve())
    except ValueError:
        return False
    return (repo / rel).is_dir()


def scaffold_nested(args, repo: Path) -> int:
    d = args.dir.replace("\\", "/").strip("/")
    if not inside_repo(repo, d):
        eecho(f"agents-md: --dir {args.dir!r} is not a folder inside {repo}")
        return EX_NOTFOUND
    d += "/"
    dest = repo / d / "AGENTS.md"
    if args.write and dest.exists():
        eecho(f"agents-md: {dest} already exists; scaffold never overwrites. Upgrade it with audit --diff")
        return EX_PRECOND
    f = load_facts(repo, args.facts, None, [d])
    if f is None:
        return EX_ERR
    f["candidates"] = open_candidates(repo, f.get("candidates") or [])
    root_rel = next((r for r in ("AGENTS.md", ".claude/AGENTS.md") if (repo / r).is_file()), None)
    root_text = read_raw(repo / root_rel) if root_rel else ""
    if not root_rel:
        eecho("agents-md: the repo has no root AGENTS.md; write that first (a nested doc holds deltas only)")
    draft, extra = render_nested(f, d, root_rel, root_text)
    n, chars = draft.count("\n"), len(draft)
    eecho(f"agents-md: nested draft for {d}, {n} lines, {draft.count(TODO_OWNER)} {TODO_OWNER} question(s)")
    if n > NESTED_CEILING_LINES or chars > NESTED_CEILING_CHARS:
        eecho(f"agents-md: over the nested ceiling ({NESTED_CEILING_LINES} lines / {NESTED_CEILING_CHARS:,} "
              "characters): move detail to a linked doc")
    elif n > NESTED_TARGET_LINES:
        eecho(f"agents-md: over the {NESTED_TARGET_LINES}-line nested target; prune before committing")
    for name in CLAUDE_FILES:
        p = repo / d / name
        if p.exists() and not p.is_symlink() and classify_claude(read_raw(p), name) != "imports":
            eecho(f"agents-md: {d}{name} will shadow {d}AGENTS.md in Claude Code; add "
                  f"`{import_line(name)}` to it")
    if args.write:
        return create_file(dest, draft)
    if args.json:
        emit_json({"data": {"dir": d, "lines": n, "chars": chars, "owner_questions": draft.count(TODO_OWNER),
                            **extra, "draft": draft}, "meta": {"schema": SCHEMA_SCAFFOLD}})
    else:
        sys.stdout.write(draft)
    return EX_OK


def render_architecture(f: dict, repo_name: str) -> str:
    """The ARCHITECTURE.md draft. Facts fill entry points, codemap rows, boundaries and
    seeded invariant questions, all named and never linked; the rest are owner questions."""
    tmpl = (TEMPLATES / "architecture.md").read_text(encoding="utf-8")
    tmpl = re.sub(r"(?s)\A\s*<!--.*?-->\s*", "", tmpl, count=1)
    a = f.get("architecture") or {}
    why = ("repo-scan finds it warranted: " + "; ".join(a.get("reasons") or [])) if a.get("warranted") \
        else "repo-scan does not find it warranted; a short Structure section may do"
    note = "\n".join([f"<!-- {DRAFT_MARK} agents-md.py scaffold --architecture from repo-scan facts."]
                     + textwrap.wrap(why + ".", 84, initial_indent="     ", subsequent_indent="     ")
                     + [f"     Answer or delete each {TODO_OWNER}, then delete this comment. -->"])
    # One line per file: a file can be a manifest main, an export and an index at once.
    # Declared entries (a manifest names them) outrank inferred ones (index.*, cmd/).
    rank = ("manifest-main", "manifest-bin", "manifest-exports", "cmd", "dunder-main", "index")
    # A farm's members (same-shaped siblings, repo-scan nesting.farms) share one line:
    # `tools/*/src/index.ts`, not nine.
    farms = [x["parent"] for x in (f.get("nesting") or {}).get("farms") or []]

    def farm_name(name: str) -> str:
        parent = next((fp for fp in farms if name.startswith(fp) and name.count("/") > fp.count("/")), None)
        return parent + "*/" + name[len(parent):].split("/", 1)[1] if parent else name
    grouped: dict[str, list[dict]] = {}
    for e in sorted(a.get("entry_points") or [], key=lambda e: (rank.index(e["kind"]) if e["kind"] in rank
                                                               else len(rank), e["name"])):
        bucket = grouped.setdefault(farm_name(e["name"]), [])
        if e["kind"] not in [x["kind"] for x in bucket]:
            bucket.append(e)
    rows = []
    for name, es in list(grouped.items())[:12]:
        src = None if "*" in name else next((e["source"] for e in es if e["source"].split(":")[0] != name), None)
        rows.append(f"- `{name}` ({', '.join(e['kind'] for e in es)}" + (f"; {cite(src)})" if src else ")"))
    entry = "\n".join(rows) or (
        f"- [ ] {TODO_OWNER}: Where does execution start? No manifest main, bin or exports, index or "
        "cmd/ entry was found.")
    mbd = f.get("manifests_by_dir") or {}
    names = {d: (m.get("package_json") or {}).get("name") or (m.get("composer_json") or {}).get("name")
             for d, m in mbd.items()}
    codemap = "\n".join(f"- `{d}`" + (f" ({names[d]})" if names.get(d) else "")
                        + f": {TODO_OWNER} what lives here; its key modules and types, by name."
                        for d in a.get("layout") or []) or f"- [ ] {TODO_OWNER}: one line per area."
    member = {v: d for d, v in names.items() if v}
    bounds = []
    for d, m in sorted(mbd.items()):
        pkg = m.get("package_json") or {}
        for dep in pkg.get("dependencies", []):
            if member.get(dep) not in (None, d):
                bounds.append(f"- `{d}` depends on `{member[dep]}` ({dep}; {cite(pkg.get('path') or d + 'package.json')})")
    boundaries = "\n".join(bounds) or (f"- [ ] {TODO_OWNER}: Which packages may depend on which? No "
                                       "workspace-to-workspace dependency was found in the manifests.")
    inv = []
    for g in f.get("gates") or []:
        scope = g.get("scope") or ""
        cfg = g["config"] if g["config"].startswith(scope) else scope + g["config"]
        inv.append(f"- [ ] {TODO_OWNER}: {g['tool']} enforces rules from `{cfg}`. State each as an "
                   "Architecture Invariant and name this gate.")
    for c in [c for c in f.get("candidates") or [] if c["kind"] == "coupling"][:4]:
        inv.append(f"- [ ] {TODO_OWNER}: " + " and ".join(f"`{x}`" for x in c["paths"][:3])
                   + f" change together ({cite(c['evidence'][0])}). Is that an invariant?")
    invariants = "\n".join(inv[:8]) or (f"- [ ] {TODO_OWNER}: Which rules hold across the codebase, "
                                        "especially absences (the engine never imports the UI)?")
    layout = a.get("layout") or []
    fp = "\n".join([f"<!-- layout: {a.get('layout_fingerprint') or '0' * 40} (repo-doctor: the folders this "
                    "codemap covers;", "     agents-md.py audit names any added or removed)"]
                   + textwrap.wrap(" ".join(layout), 84, initial_indent="     ", subsequent_indent="     ")) + " -->"
    for k, v in {"TITLE": repo_name, "DRAFT_NOTE": note, "ENTRY_POINTS": entry, "CODEMAP": codemap,
                 "BOUNDARIES": boundaries, "INVARIANTS": invariants, "FINGERPRINT": fp}.items():
        tmpl = tmpl.replace("{{" + k + "}}", v)
    return re.sub(r"\n{3,}", "\n\n", tmpl).strip() + "\n"


def scaffold_architecture(args, repo: Path) -> int:
    dest = repo / "ARCHITECTURE.md"
    if args.write and dest.exists():
        eecho(f"agents-md: {dest} already exists; scaffold never overwrites. agents-md.py audit checks it")
        return EX_PRECOND
    f = load_facts(repo, args.facts)
    if f is None:
        return EX_ERR
    f["candidates"] = open_candidates(repo, f.get("candidates") or [])
    a = f.get("architecture") or {}
    if not a.get("warranted"):
        eecho("agents-md: the scan does not find ARCHITECTURE.md warranted (fewer than 2 nesting "
              "recommendations, 4 contracted areas or 3 workspace members); a Structure section may do")
    if (repo / "docs/ARCHITECTURE.md").is_file():
        eecho("agents-md: docs/ARCHITECTURE.md exists; the root location is the recommended one")
    draft = render_architecture(f, repo.name)
    n = draft.count("\n")
    eecho(f"agents-md: ARCHITECTURE.md draft, {n} lines, {draft.count(TODO_OWNER)} {TODO_OWNER} question(s)")
    if n > CEILING_LINES or len(draft) > CEILING_CHARS:
        eecho(f"agents-md: over the {CEILING_LINES}-line / {CEILING_CHARS:,}-character budget; prune the codemap")
    if args.write:
        return create_file(dest, draft)
    if args.json:
        emit_json({"data": {"path": "ARCHITECTURE.md", "lines": n, "chars": len(draft),
                            "warranted": bool(a.get("warranted")), "reasons": a.get("reasons") or [],
                            "entry_points": a.get("entry_points") or [],
                            "layout_fingerprint": a.get("layout_fingerprint"),
                            "owner_questions": draft.count(TODO_OWNER), "draft": draft},
                   "meta": {"schema": SCHEMA_SCAFFOLD}})
    else:
        sys.stdout.write(draft)
    return EX_OK


def open_candidates(repo: Path, cands: list[dict]) -> list[dict]:
    """Candidates the ruled-out record doesn't answer: a draft and its interview never
    re-ask what the owner already ruled out."""
    if not (repo / RULED_OUT).is_file():
        return cands
    entries, _ = parse_ruled_out(read_raw(repo / RULED_OUT))
    return apply_ruled_out(cands, entries, date.today().isoformat())[0]


def scaffold_questions(f: dict) -> list[dict]:
    """The draft's owner questions for the interview (spec Lane C). A guided question is one
    the facts can answer: it carries a recommended answer and its source, for the owner to
    accept in a word. An assisted one needs the owner and carries only its evidence. Ask
    only the assisted ones; confirm the guided ones."""
    m = f.get("manifests") or {}
    qs: list[dict] = []

    def q(qid: str, text: str, evidence: list[str], rec: tuple[str, str] | None = None) -> None:
        item = {"id": qid, "question": text, "answerable": "guided" if rec else "assisted", "evidence": evidence}
        if rec:
            item["recommended"] = {"answer": rec[0], "source": rec[1]}
        qs.append(item)
    desc = next(((d.strip(), path) for key, path in (("package_json", "package.json"), ("composer_json", "composer.json"),
                                                      ("python", "pyproject.toml"))
                 for d in [(m.get(key) or {}).get("description")] if isinstance(d, str) and d.strip()), None)
    q("overview", "In 2-4 lines: what is this repo, what does it produce, and who consumes it?",
      [desc[1]] if desc else [], desc)
    if not command_entries(f):
        q("commands", "Which commands run, test and check this repo?", [])
    ci = [(st["run"].strip().splitlines()[0], st["source"]) for wf in (f.get("ci") or {}).get("workflows", [])
          for job in wf.get("jobs", []) for st in job.get("steps", []) if (st.get("run") or "").strip()
          and re.search(r"(?i)\b(test|lint|check|phpstan|phpunit|pytest|vitest|jest|tsc|eslint|ruff|mypy)\b",
                        st["run"])]
    if not has_check(f):
        q("check-command", "There is no single check command. Which command must pass before a commit?",
          [s for _, s in ci], ("; ".join(dict.fromkeys(c for c, _ in ci)) + " (what CI runs)", ci[0][1]) if ci else None)
    dep = f.get("deploy") or {}
    steps = dep.get("ci_deploy_steps") or []
    branches = sorted({b for s in steps for b in s.get("push_branches", [])})
    if steps:
        rec = None
        if branches:
            rec = (", ".join(f"`{b}`" for b in branches) + " deploys on push. A merge to it is a deploy, so "
                   "agents never merge to it", steps[0]["source"])
        q("deploy-branch", "Which branch deploys, and may an agent ever merge to it?", [s["source"] for s in steps], rec)
    elif not dep.get("appspec") and not dep.get("surfaces"):
        q("deploy-how", "How does this ship, and who may trigger it?", [])
    dd = (f.get("ddev") or {}).get("config") or {}
    if dd and m.get("package_json"):
        nv = dd.get("nodejs_version")
        q("ddev-node", "Do the Node scripts run on the host or inside DDEV (`ddev npm ...`)?",
          [nv["source"]] if nv else [], ("inside DDEV: `ddev npm ...`", nv["source"]) if nv else None)
    py = m.get("python") or {}
    if py and not py.get("manager"):
        q("python-deps", "How are the Python dependencies installed? No lockfile or manager config was found.", [])
    envs = [e for e in f.get("env") or [] if e["names"]]
    if envs:
        q("env-vars", "Which environment variables must be set for local work, and where do the values come from?",
          [e["path"] for e in envs])
    for w in (m.get("workspaces") or [])[:1]:
        rec = [r["dir"] for r in (f.get("nesting") or {}).get("recommend") or []]
        q("nesting", "Does any package need its own nested AGENTS.md?", [w["source"]],
          (("yes: " + ", ".join(f"`{d}`" for d in rec) + " (agents-md.py scaffold --dir)") if rec
           else "no: no package has its own contract yet", "repo-scan nesting") if (f.get("nesting") is not None) else None)
    gates = f.get("gates") or []
    q("conventions", "Which repo-specific invariants and naming rules does a reviewer always enforce?",
      [g["source"] for g in gates],
      ("the rules these gates enforce: " + ", ".join(dict.fromkeys(g["tool"] for g in gates)), gates[0]["source"])
      if gates else None)
    for c in f.get("candidates") or []:
        if c["kind"] != "workspaces" and c.get("paths"):
            q(f"landmine:{c['kind']}:{c['paths'][0]}", c["question"], list(c.get("evidence") or []))
    return qs


def cmd_scaffold(args) -> int:
    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"agents-md: not a directory: {repo}")
        return EX_NOTFOUND
    if args.dir:
        return scaffold_nested(args, repo)
    if args.architecture:
        return scaffold_architecture(args, repo)
    if args.write and ((repo / "AGENTS.md").exists() or (repo / ".claude/AGENTS.md").exists()):
        eecho(f"agents-md: {repo / 'AGENTS.md'} already exists; scaffold never overwrites "
              "(an owner's landmines live there). Upgrade it instead: agents-md.py audit --diff")
        return EX_PRECOND
    f = load_facts(repo, args.facts)
    if f is None:
        return EX_ERR
    f["candidates"] = open_candidates(repo, f.get("candidates") or [])
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
        return create_file(repo / "AGENTS.md", draft)
    if args.json:
        qs = scaffold_questions(f)
        emit_json({"data": {"archetype": arch, "lines": n, "owner_questions": draft.count(TODO_OWNER),
                            "questions": qs, "guided": sum(x["answerable"] == "guided" for x in qs),
                            "assisted": sum(x["answerable"] == "assisted" for x in qs),
                            "commands": [{"group": g, "command": c, "source": s, "note": t}
                                         for g, c, s, t in command_entries(f)],
                            "candidates": f.get("candidates") or [], "draft": draft},
                   "meta": {"schema": SCHEMA_SCAFFOLD}})
    else:
        sys.stdout.write(draft)
    return EX_OK


# === EXPLAIN ===
# One engine answers "what does tool T load for work in folder F", for the explain
# subcommand and for audit's data.load[]. A tool's rules come from its profile in
# tool-profiles.json (contract 1.2 in docs/plans/REPO-DOCTOR-ABC-2026-10.md). F is a
# working folder: the repo root is the launch folder, so the root's files are ancestors;
# a tool that reads subfolders on demand loads F's chain as nested-on-read, and a tool
# that reads root-to-cwd (Codex) is taken as launched in F.

# `@path` imports. Not after a word character, backtick or @, so mail addresses and
# `@x` spans never count; code spans and fences are stripped before matching.
IMPORT_RE = re.compile(r"(?<![\w`@])@((?:\.{1,2}/|~/|[\w-])[\w./~-]*)")


def load_profiles() -> list[dict] | None:
    try:
        return json.loads(PROFILES.read_text(encoding="utf-8"))["profiles"]
    except (OSError, ValueError, KeyError):
        return None


def import_targets(text: str) -> list[str]:
    out, fence = [], False
    for line in text.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if not fence:
            out += [m.rstrip(".,;:") for m in IMPORT_RE.findall(re.sub(r"`[^`]*`", "", line))]
    return out


def frontmatter(text: str) -> dict:
    """Lower-cased keys of a leading --- block: scalars, [a, b] lists and - item lists."""
    m = re.match(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text.replace("\r\n", "\n"), re.S)
    out: dict = {}
    key = None
    for line in (m.group(1).splitlines() if m else []):
        kv = re.match(r"^([\w-]+)\s*:\s*(.*)$", line)
        if kv:
            key, val = kv.group(1).lower(), kv.group(2).strip()
            if val.startswith("[") and val.endswith("]"):
                out[key] = [v.strip().strip("'\"") for v in val[1:-1].split(",") if v.strip()]
            else:
                out[key] = val.strip("'\"") if val else []
        elif key and isinstance(out.get(key), list) and re.match(r"^\s*-\s+", line):
            out[key].append(re.sub(r"^\s*-\s+", "", line).strip().strip("'\""))
    return out


def as_globs(v) -> list[str]:
    if isinstance(v, list):
        return [x for x in v if x]
    return [x.strip() for x in str(v or "").split(",") if x.strip()]


def rule_mode(fm: dict, rs: dict) -> str:
    """always | glob | description | manual for one rule file under a frontmatter rule set."""
    v = {k: str(x).lower() for k, x in fm.items() if not isinstance(x, list)}
    if v.get("alwaysapply") == "true" or v.get("inclusion") == "always" or v.get("trigger") in ("always_on", "always"):
        return "always"
    key = (rs.get("scope_key") or "").lower()
    if (key and fm.get(key)) or fm.get("globs") or v.get("inclusion") == "filematch" or v.get("trigger") == "glob":
        return "glob"
    if not fm and rs.get("always_when_scope_missing"):
        return "always"
    if fm.get("description") or v.get("inclusion") == "auto" or v.get("trigger") == "model_decision":
        return "description"
    return "manual"


def glob_reaches(pattern: str, folder: str) -> bool:
    """Whether a scope glob can match files in folder: its literal prefix and the folder
    must nest one way or the other ("**/*.ts" reaches everywhere)."""
    lit = re.split(r"[*?\[{]", pattern.lstrip("./"), maxsplit=1)[0]
    return folder.startswith(lit) or lit.startswith(folder)


def chain_dirs(folder: str) -> list[str]:
    parts = [x for x in folder.split("/") if x]
    return [""] + ["/".join(parts[:i]) + "/" for i in range(1, len(parts) + 1)]


def entry_files_in(repo: Path, d: str, prof: dict) -> list[tuple[str, bool]]:
    """(path, fallback?) for the entry files the profile reads in folder d."""
    names = prof.get("entry_files") or []
    has = [n for n in names if (repo / (d + n)).is_file()]
    if prof.get("per_dir") == "first-match":
        first = next((n for n in prof.get("first_match_order") or names if (repo / (d + n)).is_file()), None)
        return [(d + first, first not in ("AGENTS.md", "AGENTS.override.md"))] if first else []
    if prof.get("per_dir") == "claude-md-shadows-agents-md":
        agents = ("AGENTS.md", ".claude/AGENTS.md")
        claude = [n for n in has if n not in agents]
        return [(d + n, False) for n in (claude or [n for n in has if n in agents])]
    return [(d + n, False) for n in has]


def explain_tool(repo: Path, folder: str, prof: dict, nested: list[str]) -> dict:
    """Contract 1.3's per-tool record, plus notes (cycles, user-scope imports) and
    reachable (rules that load only on request, never counted)."""
    files: list[dict] = []
    notes: list[str] = []
    reachable: list[dict] = []
    seen: set[str] = set()
    imp = prof.get("imports") or None

    def add(rel: str, reason: str, always: bool, depth: int = 0, stack: tuple = ()) -> None:
        if rel in seen:
            return
        seen.add(rel)
        text = read_raw(repo / rel)
        files.append({"path": rel, "reason": reason, "bytes": len(text.encode("utf-8")),
                      "chars": len(text.replace("\r\n", "\n")),
                      "lines": len(text.splitlines()), "always_loaded": always})
        if not imp or depth >= int(imp.get("max_depth") or 0):
            return
        for target in import_targets(text):
            if target.startswith("~/"):
                notes.append(f"{rel} imports {target}: a user-scope file, left out")
                continue
            dest = posixpath.normpath(posixpath.join(posixpath.dirname(rel), target))
            if dest.startswith("../") or target.startswith("/") or not (repo / dest).is_file():
                continue
            if dest in stack + (rel,):
                notes.append("import cycle: " + " -> ".join(stack + (rel, dest)))
                continue
            add(dest, "import", always, depth + 1, stack + (rel,))

    sub = prof.get("subdirs")
    for i, d in enumerate(chain_dirs(folder)):
        if i and (sub == "never" or prof.get("ancestors") == "none"):
            break
        reason, always = ("ancestor", True) if i == 0 or sub in ("launch-path-only", "always") \
            else ("nested-on-read", False)
        for rel, fallback in entry_files_in(repo, d, prof):
            add(rel, "fallback" if fallback else reason, always)
    if sub == "always" and prof.get("ancestors") != "none":
        for n in nested:
            for rel, _ in entry_files_in(repo, os.path.dirname(n) + "/", prof):
                add(rel, "always-nested", True)
    for rs in prof.get("rule_sets") or []:
        for path in sorted(repo.glob(rs["glob"])):
            if not path.is_file():
                continue
            rel = path.relative_to(repo).as_posix()
            fm = frontmatter(read_raw(path))
            mode = rs.get("mode")
            if mode == "frontmatter":
                mode = rule_mode(fm, rs)
            elif mode == "scoped":
                key = (rs.get("scope_key") or "").lower()
                mode = "glob" if key and fm.get(key) else ("always" if rs.get("always_when_scope_missing") else "manual")
            if mode == "always":
                add(rel, "always-rule", True)
            elif mode == "glob":
                key = (rs.get("scope_key") or "globs").lower()
                if any(glob_reaches(g, folder) for g in as_globs(fm.get(key) or fm.get("globs"))):
                    add(rel, "glob", False)
            else:
                reachable.append({"path": rel, "mode": mode})
    chars = sum(x["chars"] for x in files)
    always_chars = sum(x["chars"] for x in files if x["always_loaded"])
    totals = {"bytes": sum(x["bytes"] for x in files), "chars": chars, "est_tokens": round(chars / 3.6),
              "always_chars": always_chars, "on_demand_chars": chars - always_chars}
    caps_hit = []
    for cap in prof.get("caps") or []:
        if cap.get("scope") == "chain":
            if cap.get("bytes") and totals["bytes"] > cap["bytes"]:
                caps_hit.append({"scope": "chain", "limit": f"{cap['bytes']} bytes", "source": cap.get("source")})
            continue
        for x in files:
            for unit, field in (("lines", "lines"), ("characters", "chars"), ("bytes", "bytes")):
                lim = cap.get(field)
                if lim and x[field] > lim:
                    caps_hit.append({"scope": "file", "limit": f"{lim} {unit}", "source": cap.get("source"),
                                     "path": x["path"], "behaviour": cap.get("behaviour")})
    return {"tool": prof["id"], "name": prof.get("name", prof["id"]), "files": files, "totals": totals,
            "caps_hit": caps_hit, "notes": list(dict.fromkeys(notes)), "reachable": reachable}


def cmd_explain(args) -> int:
    repo = Path(args.repo).resolve()
    folder = args.folder.replace("\\", "/").strip("/")
    folder = "" if folder in ("", ".") else folder + "/"
    if not repo.is_dir() or (folder and not inside_repo(repo, folder.rstrip("/"))):
        eecho(f"agents-md: not a folder inside the repo: {args.folder}")
        return EX_NOTFOUND
    profiles = load_profiles()
    if profiles is None:
        eecho(f"agents-md: cannot read {PROFILES}")
        return EX_ERR
    ids = [x["id"] for x in profiles]
    if args.tool != "all" and args.tool not in ids:
        eecho(f"agents-md: unknown --tool {args.tool!r} (known: {', '.join(ids)}, all)")
        return EX_USAGE
    nested = nested_doc_paths(repo)
    chosen = profiles if args.tool == "all" else [x for x in profiles if x["id"] == args.tool]
    tools = [explain_tool(repo, folder, x, nested) for x in chosen]
    if args.json:
        emit_json({"data": {"dir": folder or "./", "tools": tools},
                   "meta": {"schema": SCHEMA_EXPLAIN, "excluded": "user-scope files"}})
        return EX_OK
    print(f"explain {folder or './'} (repo files only; user-scope files such as ~/.claude are per-machine)")
    for x in tools:
        print(f"{x['name']}")
        if not x["files"]:
            print("  (loads no repo file here)")
        width = max([len(f["path"]) for f in x["files"]] + [10])
        for n, f in enumerate(x["files"], 1):
            print(f"  {n}. {f['path']:<{width}}  {f['reason']:<15} {f['chars']:>7,} chars  "
                  f"{'always' if f['always_loaded'] else 'on demand'}")
        tt = x["totals"]
        print(f"  total {tt['chars']:,} chars (~{tt['est_tokens']:,} tokens): {tt['always_chars']:,} always, "
              f"{tt['on_demand_chars']:,} on demand")
        for c in x["caps_hit"]:
            print(f"  cap: {c.get('path', 'chain')} over {c['limit']} ({c['source']})")
        for r in x["reachable"]:
            print(f"  reachable on request: {r['path']} ({r['mode']})")
        for note in x["notes"]:
            print(f"  note: {note}")
    return EX_OK


def load_findings(repo: Path, rel: str | None, nested: list[str]) -> tuple[list[dict], list[dict]]:
    """audit's view of the engine: (findings, data.load[]) for the root and each nested folder."""
    profiles = load_profiles()
    if not profiles:
        return [{"id": "tool-profiles-missing", "severity": "info", "path": str(PROFILES.name),
                 "msg": "tool-profiles.json is missing beside this script; load checks skipped"}], []
    by_id = {x["id"]: x for x in profiles}
    folders = [""] + [os.path.dirname(n) + "/" for n in nested]
    finds, load, cycles = [], [], {}
    doc_of = {"": rel or "AGENTS.md", **{os.path.dirname(n) + "/": n for n in nested}}
    codex = by_id.get("codex")
    codex_cap = next((c["bytes"] for c in (codex or {}).get("caps", []) if c.get("scope") == "chain"
                      and c.get("bytes")), None)
    for fo in folders:
        cc = explain_tool(repo, fo, by_id["claude-code"], nested) if "claude-code" in by_id else None
        cx = explain_tool(repo, fo, codex, nested) if codex else None
        load.append({"dir": fo or "./", "claude_code_chars": cc["totals"]["chars"] if cc else None,
                     "claude_code_always_chars": cc["totals"]["always_chars"] if cc else None,
                     "codex_bytes": cx["totals"]["bytes"] if cx else None,
                     "files": [x["path"] for x in cc["files"]] if cc else []})
        for note in (cc or {}).get("notes", []):
            if note.startswith("import cycle"):
                cycles.setdefault(note, fo)
        if cc and cc["totals"]["chars"] > LOAD_CEILING_CHARS:
            finds.append({"id": "load-over-budget", "severity": "warn", "path": doc_of[fo],
                          "msg": f"Claude Code loads {cc['totals']['chars']:,} characters for work in "
                                 f"{fo or 'the root'} (over {LOAD_CEILING_CHARS:,}: a root at its ceiling plus one "
                                 "nested doc). `agents-md.py explain` shows the files"})
        if fo and cx and codex_cap and cx["totals"]["bytes"] > codex_cap:
            finds.append({"id": "root-starves-nested", "severity": "warn", "path": doc_of[fo],
                          "msg": f"the Codex chain to {fo} is {cx['totals']['bytes']:,} bytes, over its "
                                 f"{codex_cap:,}-byte cap: Codex drops the deepest files first, so "
                                 f"{doc_of[fo]} goes first"})
    if nested and rel and codex_cap:
        root_bytes = len(read_raw(repo / rel).encode("utf-8"))
        if root_bytes > codex_cap // 2:
            finds.append({"id": "root-starves-nested", "severity": "warn", "path": rel,
                          "msg": f"{rel} alone is {root_bytes:,} bytes, over half of Codex's {codex_cap:,}-byte "
                                 "budget, leaving little for the nested docs below it"})
    for note in cycles:
        finds.append({"id": "import-cycle", "severity": "info", "path": rel or "AGENTS.md",
                      "msg": f"{note}: the loader stops there, but one of the imports is redundant"})
    seen = set()
    for prof in profiles:
        if not prof.get("targets_when") or not any((repo / x.rstrip("/")).exists() for x in prof["targets_when"]):
            continue
        for fo in folders:
            for c in explain_tool(repo, fo, prof, nested)["caps_hit"]:
                key = (prof["id"], c.get("path"), c["limit"])
                if c["scope"] != "file" or key in seen:
                    continue
                seen.add(key)
                finds.append({"id": "tool-cap", "severity": "info", "path": c["path"],
                              "msg": f"{c['path']} is over {prof['name']}'s {c['limit']} cap ({c['behaviour']}; "
                                     f"source: {c['source']}). The repo targets {prof['name']}"})
    return finds, load


# === FINDINGS ===
# Every finding id the audit can emit: (severity, the rule, where it comes from). audit
# --explain <id> prints the entry plus this repo's evidence. An id added to the audit
# without an entry here explains as "no entry"; keep them in step.
PROTO = "references/agents-md-protocol.md"
SPEC = "docs/plans/NESTED-ENTRY-DOCS-2026-10.md"
FINDING_DOCS = {
    "missing-agents-md": ("crit", "The repo has no AGENTS.md, so every agent session starts blind.", f"{PROTO} section 1"),
    "missing-section-": ("warn", "A protocol section is missing. Commands and Landmines are required; Deploy is "
                         "required when the repo has deploy config; the rest are info.", f"{PROTO} section 1"),
    "empty-landmines": ("warn", "The Landmines section lists no item.", f"{PROTO} section 1"),
    "uncovered-candidates": ("info", "Landmine candidates from the repo scan name files the owning doc never "
                             "mentions. Answer each as a landmine or rule it out in docs/agents/ruled-out.md.",
                             f"{PROTO} section 1"),
    "landmine-belongs-nested": ("info", "A root landmine names only paths inside one nested doc's folder. Move it "
                                "by hand; the patch never moves a landmine.", f"{PROTO} section 6"),
    "human-setup-prose": ("info", "Human setup steps belong in README.md, not in the agent entry doc.", f"{PROTO} section 2"),
    "over-ceiling": ("warn", "Over 200 lines or 16,000 characters: Claude Code's documented target, because longer "
                     "files cost context and adherence.", f"{PROTO} section 3"),
    "over-target": ("info", "Under the ceiling, over the 150-line / 12,000-character house target.", f"{PROTO} section 3"),
    "long-lines": ("info", "Lines over 500 characters each cost what several wrapped lines do.", f"{PROTO} section 3"),
    "split-insufficient": ("info", "Moving every movable section still leaves the doc over target; the bulk sits in "
                           "sections the patch never moves.", f"{PROTO} section 3"),
    "bare-pointer": ("info", "A pointer that never says when to read its target. Name a path trigger or a task "
                     "trigger.", f"{PROTO} section 3"),
    "shadowed-": ("crit", "A CLAUDE.md that doesn't import AGENTS.md hides it from Claude Code: standalone, a prose "
                  "pointer, a symlink checked out as text, or a copy.", f"{PROTO} section 4"),
    "shadowed-by-parent": ("warn", "A CLAUDE.md above the repo makes Claude Code read CLAUDE.md files instead of "
                           "AGENTS.md.", f"{PROTO} section 4"),
    "shadowed-by-claude-local": ("warn", "A personal CLAUDE.local.md stops AGENTS.md loading for its owner.",
                                 f"{PROTO} section 4"),
    "claude-local-committed": ("crit", "A committed CLAUDE.local.md shadows AGENTS.md for everyone.", f"{PROTO} section 4"),
    "claude-imports": ("info", "CLAUDE.md imports AGENTS.md: fine, provided it holds only Claude-only deltas.",
                       f"{PROTO} section 4"),
    "claude-imports-duplicate": ("warn", "CLAUDE.md imports AGENTS.md and also repeats it, so the text loads twice.",
                                 f"{PROTO} section 4"),
    "claude-symlink": ("info", "A CLAUDE.md symlink works on macOS and Linux, but a Windows clone without "
                       "core.symlinks gets a one-line text file.", f"{PROTO} section 4"),
    "dead-command": ("warn", "A command the doc presents as runnable that the repo's manifests can't run.",
                     f"{PROTO} section 5"),
    "dead-path": ("warn", "A backticked path git once tracked and the tree no longer has. The annotation names the "
                  "rename history found.", f"{PROTO} section 5"),
    "stale": ("warn", "Over 15 commits since the doc was last touched. Staleness is counted in commits, not days.",
              f"{PROTO} section 5"),
    "owner-todos": ("warn", "TODO(owner) questions from the scaffold are unanswered.", f"{PROTO} section 8"),
    "draft-header": ("warn", "The scaffold's DRAFT comment is still at the top.", f"{PROTO} section 8"),
    "untested-commands": ("info", "Commands still carry the scaffold's [untested] tag: run each once, then drop it.",
                          f"{PROTO} section 8"),
    "generated-entry-doc": ("info", "The entry doc is generated (ruler, rulesync or a Source header). Fixes go to "
                            "its source; the next sync overwrites hand edits.", f"{SPEC} N8"),
    "nested-over-budget": ("warn", "A nested AGENTS.md over 60 lines or 4,800 characters (info past 40 lines). Some "
                           "tools load every nested doc on every task.", f"{PROTO} section 6"),
    "nested-unlinked": ("warn", "The root never names this nested doc; for tools that read only the root it is "
                        "unreachable.", f"{PROTO} section 6"),
    "nested-no-scope": ("info", "The nested doc never names its own folder, so loaded alone it can't say where it "
                        "applies.", f"{PROTO} section 6"),
    "nested-restates-root": ("info", "Three or more long lines repeat the root; concatenating tools pay twice.",
                             f"{PROTO} section 6"),
    "nested-dead-command": ("warn", "A command neither the folder's manifest nor the root's can run.", f"{PROTO} section 6"),
    "nested-stale": ("warn", "Over 15 commits to the folder itself since its doc was last touched.", f"{PROTO} section 6"),
    "nested-shadowed": ("warn", "A subfolder's own CLAUDE.md makes Claude Code skip that folder's AGENTS.md.",
                        f"{PROTO} section 6"),
    "ruled-out-stale": ("info", "A docs/agents/ruled-out.md line matches no current candidate; delete it.", f"{PROTO} section 1"),
    "ruled-out-lapsed": ("info", "The evidence grew past the line's @count, so the question is open again.",
                         f"{PROTO} section 1"),
    "ruled-out-expired": ("info", "The line's until date has passed, so the question is open again.", f"{PROTO} section 1"),
    "ruled-out-proposed": ("info", "An agent's proposed line; an owner removes (proposed) to accept it.", f"{PROTO} section 1"),
    "ruled-out-unparsed": ("info", "A line that looks like a ruled-out entry but doesn't parse.", f"{PROTO} section 1"),
    "architecture-warranted": ("info", "ARCHITECTURE.md is warranted (nesting, contracted areas or workspace members) "
                               "and missing.", f"{PROTO} section 10"),
    "architecture-unlinked": ("info", "The root never points to ARCHITECTURE.md; --diff adds the line.", f"{PROTO} section 10"),
    "architecture-location": ("info", "docs/ARCHITECTURE.md works, but the root is where readers look.", f"{PROTO} section 10"),
    "architecture-over-budget": ("warn", "ARCHITECTURE.md past the root entry doc's 200-line / 16,000-character "
                                 "budget.", f"{PROTO} section 10"),
    "architecture-stale-name": ("warn", "A codemap or entry-point path that no longer exists, with the rename git "
                                "history shows.", f"{PROTO} section 10"),
    "architecture-stale-layout": ("warn", "The layout fingerprint no longer matches the folders; the codemap misses "
                                  "what was added or removed.", f"{PROTO} section 10"),
    "architecture-stale-marker": ("info", "An explicit staleness marker (outdated, TODO: document, FIXME).",
                                  f"{PROTO} section 10"),
    "architecture-links-code": ("info", "Links to source files or line anchors rot; name the symbol instead.",
                                f"{PROTO} section 10"),
    "invariant-ungated": ("info", "A prose invariant (\"X never imports Y\", \"only X touches Y\") no detected gate "
                          "covers. Every invariant has a gate.", "references/monorepo-structure.md"),
    "load-over-budget": ("warn", "Claude Code loads over 20,800 characters for work in one folder.", f"{PROTO} section 11"),
    "root-starves-nested": ("warn", "The Codex chain to a folder passes its 32 KiB cap (it drops the deepest files "
                            "first), or the root alone takes over half of it.", f"{PROTO} section 11"),
    "import-cycle": ("info", "Two files import each other; the loader stops, but one import is redundant.",
                     f"{PROTO} section 11"),
    "tool-cap": ("info", "A file over the cap of a tool the repo visibly targets.", f"{PROTO} section 11"),
    "tool-profiles-missing": ("info", "assets/agents-md/tool-profiles.json is missing, so load checks are skipped.",
                              f"{PROTO} section 11"),
}


def finding_doc(fid: str) -> tuple[str, str, str] | None:
    """The registry entry for an id; prefixed families (missing-section-*, shadowed-*) share one."""
    if fid in FINDING_DOCS:
        return FINDING_DOCS[fid]
    return next((v for k, v in FINDING_DOCS.items() if k.endswith("-") and fid.startswith(k)), None)


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
        agents_text = read_raw(repo / agents_rel) if (repo / agents_rel).is_file() else ""
        if kind in ("standalone", "pointer-prose") and name != "CLAUDE.local.md" \
                and is_copy(text, agents_text):
            kind = "copy"
        if kind == "imports" and is_copy(text, agents_text):
            finds.append({"id": "claude-imports-duplicate", "severity": "warn", "path": name,
                          "msg": f"{name} imports AGENTS.md and also repeats it, so the same text "
                                 "loads twice. Keep the import and only the Claude-only lines"})
            edits[name] = (text, import_with_deltas(text, agents_text, imp))
        elif kind == "imports":
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
            elif kind == "copy":
                edits[name] = (text, import_with_deltas(text, agents_text, imp))
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


# --- nested entry docs ------------------------------------------------------------
# Every tracked <folder>/AGENTS.md is audited against its own folder (spec N3 in
# docs/plans/NESTED-ENTRY-DOCS-2026-10.md). A nested doc carries deltas only, so it is
# judged on its budget, on a root pointer that reaches it, on a scope line that holds
# when it loads alone, and on commits to its own folder, never the repo's.


def nested_doc_paths(repo: Path) -> list[str]:
    """Tracked <folder>/AGENTS.md files below the root, skipping dependency trees and .claude/."""
    out = []
    for rel in sorted((git(repo, "ls-files", "*AGENTS.md") or "").splitlines()):
        d = os.path.dirname(rel)
        if d and rel == f"{d}/AGENTS.md" and not re.search(r"(^|/)(node_modules|vendor|\.claude)(/|$)", d) \
                and (repo / rel).is_file():   # a sparse checkout leaves tracked files off disk
            out.append(rel)
    return out


def norm_line(line: str) -> str:
    return re.sub(r"\s+", " ", line.strip().lower())


def subtree_staleness(repo: Path, rel: str, d: str) -> int | None:
    """Commits touching d/ since rel was last touched (repo-wide commits say nothing about a package)."""
    last = git(repo, "rev-list", "-1", "HEAD", "--", rel)
    if not last:
        return None
    n = git(repo, "rev-list", "--count", f"{last}..HEAD", "--", d + "/")
    return int(n) if n and n.isdigit() else None


def audit_nested(repo: Path, nested: list[str], f: dict, root_rel: str | None,
                 root_text: str) -> tuple[list[dict], list[dict], list[str]]:
    """(findings, one data.docs record per nested doc, folders the root never points to)."""
    finds, docs, unlinked = [], [], []
    root_long = {norm_line(l) for l in root_text.splitlines() if len(l.strip()) >= 40}
    for rel in nested:
        d = os.path.dirname(rel)
        text = read_raw(repo / rel)
        lines = text.splitlines()
        n, chars = len(lines), len(text.replace("\r\n", "\n"))

        def add(fid: str, sev: str, msg: str, line: int | None = None) -> None:
            finds.append({"id": fid, "severity": sev, "path": f"{rel}:{line}" if line else rel, "msg": msg})
        if n > NESTED_CEILING_LINES or chars > NESTED_CEILING_CHARS:
            add("nested-over-budget", "warn",
                f"{n} lines and {chars:,} characters, over the nested ceiling ({NESTED_CEILING_LINES} lines / "
                f"{NESTED_CEILING_CHARS:,} characters): some tools load every nested AGENTS.md on every "
                "task. Keep the deltas; move detail to a linked doc")
        elif n > NESTED_TARGET_LINES:
            add("nested-over-budget", "info", f"{n} lines, over the {NESTED_TARGET_LINES}-line nested target")
        if root_rel and not re.search(r"(?<![\w.-])" + re.escape(rel) + r"(?![\w-])", root_text):
            unlinked.append(d)
            add("nested-unlinked", "warn",
                f"{root_rel} never names {rel}. Tools that read only the root (Codex below the launch "
                "folder, Jules) never reach it; --diff adds a pointer")
        if not re.search(r"(?<![\w.-])(?:\./)?" + re.escape(d) + r"/|`(?:\./)?" + re.escape(d) + "`", text):
            add("nested-no-scope", "info",
                f"{rel} never names `{d}/`, so loaded alone it can't say where it applies. Open with "
                f"\"Applies to `{d}/` and below\"")
        repeats = [i for i, l in enumerate(lines) if len(l.strip()) >= 40 and norm_line(l) in root_long]
        if len(repeats) >= 3:
            add("nested-restates-root", "info",
                f"{len(repeats)} lines repeat the root AGENTS.md (first: line {repeats[0] + 1}); a tool "
                "that concatenates both pays for them twice", repeats[0] + 1)
        own = {"manifests": (f.get("manifests_by_dir") or {}).get(d + "/") or {}}
        for i, cmd, _ in command_refs(lines):
            # Dead only when neither the folder nor the root can run it: a nested doc may
            # name either, and a package script must never be judged against the root.
            why = check_command(cmd, own, repo / d)
            if why and check_command(cmd, f, repo):
                add("nested-dead-command", "warn", f"`{cmd}`: {why} (checked against `{d}/` and the root)", i + 1)
        since = subtree_staleness(repo, rel, d)
        if since is not None and since > FRESH_COMMITS:
            add("nested-stale", "warn",
                f"{since} commits have touched `{d}/` since {rel} was last touched: verify its claims, "
                "then touch it in the fixing commit")
        docs.append({"path": rel, "kind": "nested", "lines": n, "chars": chars, "commits_since": since})
    return finds, docs, unlinked


# A prose invariant: "X never imports Y" or "only X touches Y" (spec N7). Every invariant
# should have a gate (references/monorepo-structure.md); one without is reported so the
# rule gets a check before it rots.
INVARIANT_RE = re.compile(r"(?i)\b(?:never|must not|may not|cannot|can't|does not|doesn't|do not|don't)\s+"
                          r"(?:imports?|depends? on|calls?|uses?|references?|requires?|reads?|writes?)\b"
                          r"|\bonly\s.{1,60}?\b(?:touch(?:es)?|imports?|writes?|reads?|calls?|access(?:es)?|owns?)\b")


def gate_covers(paths: list[str], gates: list[dict], repo: Path | None = None) -> bool:
    """A boundary checker covers an invariant when it is repo-wide, or its scope holds
    every folder the invariant names: a db/ gate checks db's imports, not ui's. An
    invariant test (a check script) checks only what it names, so it covers an invariant
    only when its text names every folder; one link checker gates nothing else."""
    for g in gates:
        scope = g.get("scope") or ""
        if g.get("tool") == "invariant test":
            body = read_raw(repo / (scope + g["config"])) if repo and (repo / (scope + g["config"])).is_file() else ""
            if paths and all(x.rstrip("/") + "/" in body for x in paths):
                return True
            continue
        if not scope or (paths and all((x.rstrip("/") + "/").startswith(scope) for x in paths)):
            return True
    return False


def ungated(doc: str, lines: list[tuple[int, str]], gates: list[dict], repo: Path | None = None) -> list[dict]:
    out = []
    for i, line in lines:
        if not INVARIANT_RE.search(line):
            continue
        paths = named_paths(line)
        if (paths and not gate_covers(paths, gates, repo)) or (not paths and not gates):
            shown = re.sub(r"\s+", " ", line.strip())[:90]
            out.append({"id": "invariant-ungated", "severity": "info", "path": f"{doc}:{i + 1}",
                        "msg": f"an invariant with no gate: \"{shown}\". Prose rules rot; add a check "
                               "(dependency-cruiser, import-linter, a scripts/check-* test) and run it from "
                               "the check entry point"})
    return out


def owner_dir(paths: list[str], nested_dirs: list[str]) -> str | None:
    """The deepest nested-doc folder holding every path, or None (the root owns it)."""
    if not paths:
        return None
    inside = [d for d in nested_dirs if all(p.startswith(d + "/") for p in paths)]
    return max(inside, key=len) if inside else None


def landmine_items(lines: list[str]) -> list[tuple[int, str]]:
    """(0-based line, text with continuation lines) for each top-level item of a
    Landmines section."""
    out = []
    for s in h2_sections(lines):
        if s["key"] != "landmines":
            continue
        cur = None
        for i in range(s["start"] + 1, s["end"]):
            line = lines[i]
            if re.match(r"^(\d+\.|[-*])\s+", line):
                if cur:
                    out.append(cur)
                cur = (i, line)
            elif cur and line.strip() and line[:1] in (" ", "\t"):
                cur = (cur[0], cur[1] + " " + line.strip())
            elif cur and not line.strip():
                out.append(cur)
                cur = None
        if cur:
            out.append(cur)
    return out


def named_paths(text: str) -> list[str]:
    """Repo paths a line names in code spans or links (a span with a space is a command)."""
    found = [a or b for a, b in re.findall(r"`([^`\s]+)`|\]\(([^)\s#]+)\)", text)]
    return [x.rstrip("/") for x in found if "/" in x and not re.match(r"^(\w+:|\.\./|/)", x)]


def arch_path(repo: Path) -> str | None:
    if (repo / ARCH_FILES[0]).is_file():
        return ARCH_FILES[0]
    alt = repo / ARCH_FILES[1]
    if alt.is_file() and re.search(r"(?im)^#{2,3}\s+code ?map", read_raw(alt)):
        return ARCH_FILES[1]
    return None


def rename_pairs(repo: Path) -> list[tuple[str, str]]:
    """(old, new) for every rename in recent history, newest first."""
    out = git(repo, "log", "-M", "--diff-filter=R", "--name-status", "--format=", "-n", "2000") or ""
    return [(x[1], x[2]) for x in (line.split("\t") for line in out.splitlines())
            if len(x) == 3 and x[0].startswith("R")]


def renamed_to(path: str, pairs: list[tuple[str, str]]) -> str | None:
    """Where a vanished file or folder went, from rename history (a folder from its files)."""
    p = path.rstrip("/")
    for old, new in pairs:
        if old == p:
            return new + ("/" if path.endswith("/") else "")
        if old.startswith(p + "/"):
            rest = old[len(p) + 1:]
            if new.endswith("/" + rest):
                return new[:-len(rest) - 1] + "/"
    return None


def arch_tokens(lines: list[str]) -> list[tuple[int, str]]:
    """(0-based line, path) for backticked paths in the codemap and entry-point sections
    (the whole doc when it has neither). Package names (@scope/x) and globs are skipped."""
    hs = headings(lines)
    spans = []
    for n, (i, lvl, title) in enumerate(hs):
        if re.search(r"(?i)code ?map|entry ?points?", title):
            end = next((j for j, l2, _ in hs[n + 1:] if l2 <= lvl), len(lines))
            spans.append((i, end))
    spans = spans or [(0, len(lines))]
    out = []
    for a, b in spans:
        for i in range(a, b):
            for tok in re.findall(r"`([^`\s]+)`", lines[i]):
                tok = re.sub(r":\d+$", "", tok)
                if re.search(r"[*?<>{}$@]|://", tok) or tok.startswith("-"):
                    continue
                if "/" in tok or re.search(r"\.\w{1,6}$", tok):
                    out.append((i, tok))
    return out


def audit_architecture(repo: Path, f: dict, root_rel: str | None,
                       root_text: str) -> tuple[list[dict], dict | None, bool]:
    """(findings, the data.docs record, whether the root needs a pointer)."""
    a = f.get("architecture") or {}
    ap = arch_path(repo)
    if not ap:
        if a.get("warranted"):
            return [{"id": "architecture-warranted", "severity": "info", "path": root_rel or "AGENTS.md",
                     "msg": "an ARCHITECTURE.md is warranted (" + "; ".join(a.get("reasons") or [])
                            + ") and missing: agents-md.py scaffold --architecture drafts one"}], None, False
        return [], None, False
    finds: list[dict] = []
    text = read_raw(repo / ap)
    lines = text.splitlines()
    size = len(text.replace("\r\n", "\n"))

    def add(fid: str, sev: str, msg: str, line: int | None = None) -> None:
        finds.append({"id": fid, "severity": sev, "path": f"{ap}:{line}" if line else ap, "msg": msg})
    if ap != ARCH_FILES[0]:
        add("architecture-location", "info", f"{ap} works, but the root ARCHITECTURE.md is where readers look")
    if len(lines) > CEILING_LINES or size > CEILING_CHARS:
        add("architecture-over-budget", "warn", f"{len(lines)} lines and {size:,} characters, over the "
            f"{CEILING_LINES}-line / {CEILING_CHARS:,}-character budget: keep only what rarely changes")
    marks = [i for i, l in enumerate(lines) if re.search(r"(?i)\boutdated\b|\bTODO:?\s*document|\bFIXME\b", l)]
    if marks:
        add("architecture-stale-marker", "info", f"{len(marks)} staleness marker(s) (outdated, TODO: document, "
            "FIXME): revisit the section, then remove the marker", marks[0] + 1)
    links = [i for i, l in enumerate(lines) for tgt in re.findall(r"\]\(([^)\s]+)\)", l)
             if re.search(r"#L\d", tgt) or tgt.split("#")[0].lower().endswith(CODE_EXTS)]
    if links:
        add("architecture-links-code", "info", f"{len(links)} link(s) to source files or line anchors, which "
            "rot as code moves: name the file, module or type instead (readers use symbol search)", links[0] + 1)
    tracked = set((git(repo, "ls-files") or "").splitlines())
    dirs = {x.rsplit("/", i)[0] + "/" for x in tracked for i in range(1, x.count("/") + 1)}
    pairs = None
    stale = 0
    for i, tok in arch_tokens(lines):
        if not tracked or tok.rstrip("/") in tracked or tok.rstrip("/") + "/" in dirs or stale >= 8 \
                or not git(repo, "log", "-1", "--format=%H", "--", tok.rstrip("/")):
            continue
        stale += 1
        pairs = rename_pairs(repo) if pairs is None else pairs
        new = renamed_to(tok, pairs)
        add("architecture-stale-name", "warn", f"`{tok}` no longer exists"
            + (f": git history renamed it to `{new}`" if new else ": rename or drop it"), i + 1)
    m = LAYOUT_RE.search(text)
    if m and a.get("layout_fingerprint") and m.group(1) != a["layout_fingerprint"]:
        stored = {x for x in m.group(2).split() if x.endswith("/")}
        cur = set(a.get("layout") or [])
        added, removed = sorted(cur - stored), sorted(stored - cur)
        detail = "; ".join(x for x in (("added " + ", ".join(f"`{d}`" for d in added)) if added else "",
                                       ("removed " + ", ".join(f"`{d}`" for d in removed)) if removed else "") if x)
        add("architecture-stale-layout", "warn", "the folder layout changed since the codemap was written ("
            + (detail or "fingerprint differs") + "). Update the codemap, then the fingerprint "
            "(agents-md.py scaffold --architecture prints a fresh one)", text[:m.start()].count("\n") + 1)
    finds += ungated(ap, [(i, l) for i, l in enumerate(lines) if re.search(r"(?i)architecture invariant", l)],
                     f.get("gates") or [], repo)
    pointer = bool(root_rel) and "ARCHITECTURE.md" not in root_text
    if pointer:
        finds.append({"id": "architecture-unlinked", "severity": "info", "path": root_rel,
                      "msg": f"{root_rel} never points to {ap}; --diff adds the line"})
    doc = {"path": ap, "kind": "architecture", "lines": len(lines), "chars": size,
           "commits_since": staleness(repo, ap)[0]}
    return finds, doc, pointer


def dead_paths(repo: Path, lines: list[str]) -> list[tuple[int, str, str | None]]:
    """(0-based line, path, renamed-to) for backticked paths outside code fences that git
    once tracked and the tree no longer has. A path git never knew (an example, a build
    output) is not dead, so it is never flagged."""
    out, seen, fence, pairs = [], set(), False, None
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        for tok in re.findall(r"`([^`\s]+)`", line):
            tok = re.sub(r":\d+$", "", tok).rstrip(".,;")
            if "/" not in tok or re.search(r"[*?<>{}$@]|://", tok) or tok.startswith(("-", "/", "~", "..")) \
                    or tok in seen or len(seen) >= 30 or (repo / tok).exists():
                continue
            seen.add(tok)
            if not git(repo, "log", "-1", "--format=%H", "--", tok):
                continue
            pairs = rename_pairs(repo) if pairs is None else pairs
            out.append((i, tok, renamed_to(tok, pairs)))
    return out


def retarget(old: str, new: str, src: str) -> str:
    """Apply the old -> new line edits to src, a generator's source that carries old's lines
    (minus its header). A hunk whose lines can't be found in src is dropped, never guessed."""
    o, n, s = old.splitlines(), new.splitlines(), src.splitlines()
    omap = {}
    for tag, i1, i2, j1, _ in difflib.SequenceMatcher(None, o, s, autojunk=False).get_opcodes():
        if tag == "equal":
            omap.update({i1 + k: j1 + k for k in range(i2 - i1)})
    edits = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, o, n, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if i1 < i2:
            idx = [omap.get(k) for k in range(i1, i2)]
            if None in idx or idx != list(range(idx[0], idx[0] + len(idx))):
                continue
            a, b = idx[0], idx[-1] + 1
        elif i1 in omap:
            a = b = omap[i1]
        elif i1 - 1 in omap:
            a = b = omap[i1 - 1] + 1
        elif i1 == len(o):
            a = b = len(s)
        else:
            continue
        edits.append((a, b, n[j1:j2]))
    out = list(s)
    for a, b, rep in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        out[a:b] = rep
    eol = "\r\n" if "\r\n" in src else "\n"
    return eol.join(out) + (eol if src.endswith("\n") else "")


def structure_insert(lines: list[str], add: list[str]) -> list[str]:
    """Append lines at the end of the Structure section, creating it when absent."""
    st = next((s for s in h2_sections(lines) if s["key"] == "structure"), None)
    if not st:
        return lines + ["", "## Structure", ""] + add
    end = st["end"]
    while end > st["start"] + 1 and not lines[end - 1].strip():
        end -= 1
    gap = [""] if lines[end - 1].lstrip().startswith(("|", "<!--")) else []
    return lines[:end] + gap + add + lines[end:]


def add_root_pointers(lines: list[str], unlinked: list[str], root_rel: str) -> list[str]:
    """Point the root at each unlinked nested doc: a row in an existing ## Ownership table,
    else one trigger-bearing line at the end of the Structure section (created if absent)."""
    up = "../" * root_rel.count("/")
    secs = h2_sections(lines)
    own = next((s for s in secs if re.match(r"(?i)ownership\b", s["title"])), None)
    rows = [i for i in range(own["start"] + 1, own["end"]) if lines[i].lstrip().startswith("|")] if own else []
    if len(rows) >= 2:
        header = [c.strip().lower() for c in lines[rows[0]].strip().strip("|").split("|")]
        add = []
        for d in unlinked:
            cells = []
            for j, h in enumerate(header):
                if re.search(r"path|folder|dir", h):
                    cells.append(f"`{d}/`")
                elif re.search(r"agents|doc|entry", h):
                    cells.append(f"[{d}/AGENTS.md]({up}{d}/AGENTS.md)")
                else:
                    cells.append(d.rsplit("/", 1)[-1] if j == 0 else "")
            if not any("AGENTS.md" in c for c in cells):
                cells[-1] = f"[{d}/AGENTS.md]({up}{d}/AGENTS.md)"
            add.append("| " + " | ".join(cells) + " |")
        return lines[:rows[-1] + 1] + add + lines[rows[-1] + 1:]
    return structure_insert(lines, [f"- Before editing `{d}/**`, read [{d}/AGENTS.md]({up}{d}/AGENTS.md)."
                                    for d in unlinked])


def slugify(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "section"


def gh_anchor(title: str) -> str:
    return re.sub(r"[^\w\- ]", "", title.lower()).strip().replace(" ", "-")


def path_refs(body: str, repo: Path) -> list[str]:
    """The top-level folder of each backticked path and link in a section, one entry per
    reference. Only folders that exist count, so `origin/main` or a URL path is not one."""
    refs = [r.split("/")[0] for r in re.findall(r"`([\w.\-]+/[\w./\-]*)`|\]\(([\w.\-]+/[^)#\s]*)", body)
            for r in r if r]
    return [r for r in refs if (repo / r).is_dir()]


def path_tops(body: str, repo: Path) -> list[str]:
    """The folders path_refs names, most-named first."""
    refs = path_refs(body, repo)
    return sorted(set(refs), key=lambda d: (-refs.count(d), d))


def pointer_trigger(title: str, body: str, repo: Path) -> str:
    """When to read a moved section: a path trigger when the section names folders, else a
    task trigger from its title. A pointer without one ("see X") never gets read."""
    tops = [t for t in path_tops(body, repo) if t not in ("docs", ".github")][:3]
    if tops:
        named = [f"`{t}/**`" for t in tops]
        return "before editing " + (named[0] if len(named) == 1 else ", ".join(named[:-1]) + " or " + named[-1])
    return f"before work on {title.lower()}"


# A pointer line ("See [X](docs/x.md).") that never says when to read its target. The
# trigger words are searched with link text and code spans removed, so a link titled
# "When to deploy" is not a trigger. "When this topic matters" is the old split wording.
POINTER_LINE = re.compile(r"^\s*(?:[-*]\s+|\d+\.\s+)?(?:see|refer to|moved to|details (?:are )?in|"
                          r"more (?:detail )?in|full [\w ]{1,20} in)\b", re.I)
POINTER_TARGET = re.compile(r"\]\([^)\s]+\)|`[^`\s]*(?:/|\.md)[^`\s]*`")
POINTER_TRIGGER = re.compile(r"\b(?:when|whenever|before|after|while|if|once)\b", re.I)
POINTER_VAGUE = re.compile(r"\bwhen (?:this|the|that) topic matters\b|"
                           r"\b(?:when|if|as) (?:relevant|needed|necessary|appropriate)\b", re.I)


def bare_pointers(lines: list[str]) -> list[int]:
    """0-based indexes of pointer lines with no trigger, outside code fences."""
    out, fence = [], False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence or not POINTER_LINE.match(line) or not POINTER_TARGET.search(line):
            continue
        rest = re.sub(r"`[^`]*`", "", re.sub(r"\[[^\]]*\]\([^)]*\)", "", line))
        if POINTER_VAGUE.search(line) or not POINTER_TRIGGER.search(rest):
            out.append(i)
    return out


def split_plan(lines: list[str], repo: Path, arch_dest: str | None = None) -> list[dict]:
    """Moves until the doc is back under target in lines AND characters. Order: human
    setup prose first (it doesn't belong in AGENTS.md at any size), then the other
    movable sections largest first, then Structure and Conventions (both required and
    short, so they go last). The overview, Commands, Landmines and Deploy never move."""
    total, chars = len(lines), sum(len(l) + 1 for l in lines)
    if total <= CEILING_LINES and chars <= CEILING_CHARS:
        return []

    def size(s: dict) -> tuple[int, int]:
        return s["end"] - s["start"], sum(len(l) + 1 for l in lines[s["start"]: s["end"]])

    def weight(s: dict) -> int:   # in wrapped 80-character lines
        n, c = size(s)
        return max(n, -(-c // CHARS_PER_LINE))

    def tier(s: dict) -> int:
        if SETUP_HEADING.match(s["title"]):
            return 0
        return 2 if s["key"] in ("structure", "conventions") else 1

    def holds_landmines(s: dict) -> bool:
        # A "### Gotchas" under Background is a landmine block too (analyze_doc counts it
        # as Landmines coverage), so its section stays where it is.
        return any(lvl > 2 and section_key(title) == "landmines" for i, lvl, title in headings(lines)
                   if s["start"] < i < s["end"])

    plan = []
    secs = [s for s in h2_sections(lines)
            if s["key"] not in ("commands", "landmines", "deploy", "overview") and not holds_landmines(s)]
    for s in sorted(secs, key=lambda s: (tier(s), -weight(s), s["start"])):
        if total <= TARGET_LINES and chars <= TARGET_CHARS:
            break
        if tier(s) and weight(s) < MIN_MOVE_LINES:
            continue
        n, c = size(s)
        body = "\n".join(lines[s["start"] + 1: s["end"]])
        if SETUP_HEADING.match(s["title"]):
            dest, kind, why = "README.md", "readme", "human setup prose belongs in README"
        elif s["key"] == "structure" and arch_dest:
            dest, kind, why = arch_dest, "architecture", "an overflowing structure map is the codemap"
        else:
            refs = path_refs(body, repo)
            dest, kind, why = f"docs/agents/{slugify(s['title'])}.md", "docs", "detail an agent reads on demand"
            if len(refs) >= 3:
                top, cnt = max(((d, refs.count(d)) for d in set(refs)), key=lambda x: (x[1], x[0]))
                if cnt / len(refs) >= 0.6 and (repo / top).is_dir() and top not in ("docs", ".github") \
                        and not any((repo / top / c).exists() for c in CLAUDE_FILES):
                    dest, kind = f"{top}/AGENTS.md", "nested"
                    why = f"{cnt} of {len(refs)} path references are under {top}/"
        plan.append({"section": s["title"], "start": s["start"], "end": s["end"], "lines": n,
                     "chars": c, "destination": dest, "kind": kind, "why": why})
        total -= n - 3
        chars -= max(0, c - POINTER_CHARS)
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
    if kind == "architecture":
        return (f"# Architecture - {repo_name}\n\n<!-- Started by repo-doctor `agents-md.py audit --diff` with "
                "the Structure section moved from AGENTS.md. agents-md.py scaffold --architecture shows "
                "the full shape. -->\n")
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


# The ruled-out record (contract 1.4 in docs/plans/REPO-DOCTOR-ABC-2026-10.md). One line
# per owner decision that a scan candidate is not a landmine:
#   - [<kind>] `<path-or-glob>` [`<path-or-glob>` ...] @<count>: <reason>[ until YYYY-MM-DD][ (proposed)]
# <count> is the candidate's evidence when it was ruled out (repo-scan's candidate "count").
# The line is honoured only while the current evidence stays at or below it, so a question
# returns when the evidence grows (the ESLint bulk-suppression / PHPStan baseline model).
# Who and when come from git blame on this file, so the line never stores them. A line
# marked (proposed) is an agent's suggestion and is reported, never honoured.
RULED_OUT = "docs/agents/ruled-out.md"
RULED_RE = re.compile(r"^\s*[-*]\s+\[(?P<kind>[\w-]+)\]\s+(?P<paths>(?:`[^`]+`\s*)+)"
                      r"@(?P<count>\d+)\s*:\s*(?P<reason>.+?)\s*$")


def parse_ruled_out(text: str) -> tuple[list[dict], list[int]]:
    """(entries, line numbers that start like an entry but do not parse)."""
    entries, unparsed = [], []
    for n, line in enumerate(text.splitlines(), 1):
        if not re.match(r"^\s*[-*]\s+\[", line):
            continue
        m = RULED_RE.match(line)
        reason = m.group("reason") if m else ""
        proposed = reason.endswith("(proposed)")
        reason = reason[:-len("(proposed)")].rstrip() if proposed else reason
        until = re.search(r"\s*\buntil (\d{4}-\d{2}-\d{2})$", reason)
        reason = reason[:until.start()].rstrip() if until else reason
        if not m or not reason:
            unparsed.append(n)
            continue
        entries.append({"line": n, "kind": m.group("kind"), "patterns": re.findall(r"`([^`]+)`", m.group("paths")),
                        "count": int(m.group("count")), "reason": reason,
                        "until": until.group(1) if until else None, "proposed": proposed})
    return entries, unparsed


def ruled_out_matches(entry: dict, cand: dict) -> bool:
    """Same kind, and every path the candidate names matches one of the line's patterns."""
    paths = cand.get("paths") or []
    return entry["kind"] == cand.get("kind") and bool(paths) and all(
        any(fnmatch.fnmatchcase(p.rstrip("/"), pat.rstrip("/")) for pat in entry["patterns"]) for p in paths)


def apply_ruled_out(cands: list[dict], entries: list[dict], today: str) -> tuple[list[dict], int, list[dict]]:
    """(candidates still open, how many were honoured, findings about the record itself)."""
    finds, honoured = [], set()
    for e in entries:
        where = f"{RULED_OUT}:{e['line']}"
        hits = [i for i, c in enumerate(cands) if ruled_out_matches(e, c)]
        if not hits:
            finds.append({"id": "ruled-out-stale", "severity": "info", "path": where,
                          "msg": "this ruled-out line matches no current candidate: delete it"})
            continue
        if e["proposed"]:
            finds.append({"id": "ruled-out-proposed", "severity": "info", "path": where,
                          "msg": "a proposed ruled-out line: an owner removes '(proposed)' to accept it"})
            continue
        if e["until"] and e["until"] < today:
            finds.append({"id": "ruled-out-expired", "severity": "info", "path": where,
                          "msg": f"this ruled-out line expired on {e['until']}: the question is open again"})
            continue
        for i in hits:
            count = cands[i].get("count")
            if count is not None and count > e["count"]:
                finds.append({"id": "ruled-out-lapsed", "severity": "info", "path": where,
                              "msg": f"the evidence grew from @{e['count']} to {count} since this was ruled "
                                     "out: the question is open again"})
            else:
                honoured.add(i)
    return [c for i, c in enumerate(cands) if i not in honoured], len(honoured), finds


def uncovered_candidates(text: str, cands: list[dict]) -> list[dict]:
    """Candidates whose files the doc never names. A path counts when it appears whole:
    `x.js` is not covered by `src/x.js` or `x.json`; a folder is covered by any file in it."""
    def named(path: str) -> bool:
        p = re.escape(path.rstrip("/"))
        return re.search(r"(?<![\w./-])" + p + r"(?![\w-])", text) is not None
    return [c for c in cands if c.get("paths") and not any(named(p) for p in c["paths"])]


def cmd_audit(args) -> int:
    if args.explain and not finding_doc(args.explain):
        eecho(f"agents-md: no finding {args.explain!r}. Known: " + ", ".join(
            k + ("*" if k.endswith("-") else "") for k in FINDING_DOCS))
        return EX_USAGE
    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"agents-md: not a directory: {repo}")
        return EX_NOTFOUND
    rel = "AGENTS.md" if (repo / "AGENTS.md").is_file() else (
        ".claude/AGENTS.md" if (repo / ".claude/AGENTS.md").is_file() else None)
    nested = nested_doc_paths(repo)
    f = load_facts(repo, args.facts, None if args.facts else
                   "repo,manifests,ddev,deploy,ci,tests,generated,history,outliers,env,architecture,gates,docs",
                   [os.path.dirname(n) + "/" for n in nested])
    if f is None:
        return EX_ERR
    finds: list[dict] = []
    files: dict = {}
    data: dict = {"repo": str(repo), "agents_md": rel}
    docs: list[dict] = []
    if rel is None:
        finds.append({"id": "missing-agents-md", "severity": "crit", "path": "AGENTS.md",
                      "msg": "no AGENTS.md: agents enter blind. Draft one with "
                             "`agents-md.py scaffold --repo <path>` (verified facts only)"})
        c_finds, _ = shadow_findings(repo, "AGENTS.md", args.no_parents)
        finds += [x for x in c_finds if x["id"] in ("shadowed-by-parent", "nested-shadowed")]
        n_finds, docs, _ = audit_nested(repo, nested, f, None, "")
        finds += n_finds
        a_finds, a_doc, _ = audit_architecture(repo, f, None, "")
        finds += a_finds
        docs += [a_doc] if a_doc else []
    else:
        text = read_raw(repo / rel)
        eol = "\r\n" if "\r\n" in text else "\n"
        lines = text.splitlines()
        an = analyze_doc(text)
        data.update({"lines": an["lines"], "chars": an["chars"], "est_tokens": round(an["chars"] / 3.6),
                     "sections": an["sections"], "coverage": coverage_letters(an["sections"])})
        if an["lines"] > CEILING_LINES or an["chars"] > CEILING_CHARS:
            over = (f"{an['lines']} lines, over the {CEILING_LINES}-line ceiling" if an["lines"] > CEILING_LINES
                    else f"{an['chars']:,} characters in {an['lines']} lines, over the {CEILING_CHARS:,}-character "
                         f"ceiling ({CEILING_LINES} lines at {CHARS_PER_LINE} characters)")
            finds.append({"id": "over-ceiling", "severity": "warn", "path": rel,
                          "msg": f"{over}. Claude Code: longer files consume more context and reduce "
                                 "adherence. See the split plan"})
        elif an["lines"] > TARGET_LINES or an["chars"] > TARGET_CHARS:
            finds.append({"id": "over-target", "severity": "info", "path": rel,
                          "msg": f"{an['lines']} lines and {an['chars']:,} characters: under the ceiling, over "
                                 f"the {TARGET_LINES}-line / {TARGET_CHARS:,}-character target"})
        if an["long_lines"]:
            ll = an["longest_line"]
            finds.append({"id": "long-lines", "severity": "info", "path": f"{rel}:{ll['line']}",
                          "msg": f"{an['long_lines']} line(s) over {LONG_LINE_CHARS} characters (longest: "
                                 f"line {ll['line']}, {ll['chars']:,} characters). Each costs what several "
                                 "wrapped lines do: wrap it, or move the detail to a linked doc"})
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
        for i in bare_pointers(lines):
            finds.append({"id": "bare-pointer", "severity": "info", "path": f"{rel}:{i + 1}",
                          "msg": "a pointer that never says when to read its target: name the trigger, "
                                 "as a path (\"before editing `src/engine/**`\") or a task (\"before "
                                 "changing the wire format\")"})
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
        for i, tok, renamed in dead_paths(repo, lines):
            finds.append({"id": "dead-path", "severity": "warn", "path": f"{rel}:{i + 1}",
                          "msg": f"`{tok}` is gone: " + (f"git history renamed it to `{renamed}`" if renamed
                                                          else "git history has it, the tree doesn't")})
            tag = f"agents-md: `{tok}` is gone" + (f"; renamed to `{renamed}`" if renamed else "")
            if tag not in new[i]:
                new[i] = new[i] + f" <!-- {tag} -->"
        since, man = staleness(repo, rel)
        data.update({"commits_since": since, "manifest_commits_since": man})
        if since is not None and since > FRESH_COMMITS:
            finds.append({"id": "stale", "severity": "warn", "path": rel,
                          "msg": f"last touched {since} commits ago ({man or 0} of them changed "
                                 "package.json/composer.json/Makefile/justfile): verify every claim, "
                                 "then touch it in the fixing commit"})
        arch_dest = arch_path(repo) or (ARCH_FILES[0] if (f.get("architecture") or {}).get("warranted") else None)
        plan = split_plan(new, repo, arch_dest)
        data["split_plan"] = [{k: v for k, v in p.items() if k not in ("start", "end")} for p in plan]
        left = an["lines"] - sum(p["lines"] - 3 for p in plan)   # each move leaves 3 lines
        left_chars = an["chars"] - sum(max(0, p["chars"] - POINTER_CHARS) for p in plan)
        if (an["lines"] > CEILING_LINES or an["chars"] > CEILING_CHARS) \
                and (left > TARGET_LINES or left_chars > TARGET_CHARS):
            finds.append({"id": "split-insufficient", "severity": "info", "path": rel,
                          "msg": f"about {left} lines and {left_chars:,} characters remain after moving every "
                                 "movable section: the bulk is in the overview, Commands or Landmines, which "
                                 "the patch never moves. Trim them by hand (long lines first), or move a "
                                 "subsystem's landmines into its nested AGENTS.md"})
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
            elif p["kind"] == "architecture":
                pointer = (f"Moved to the codemap in [{dest}]({dest}); read it before adding a module or "
                           "moving code between packages.")
            elif p["kind"] == "nested":
                pointer = (f"Moved to [{dest}]({dest}), which loads when an agent works under "
                           f"`{dest.rsplit('/', 1)[0]}/`.")
            else:
                body = "\n".join(lines[p["start"] + 1: p["end"]])
                pointer = f"Moved to [{dest}]({dest}); read it {pointer_trigger(p['section'], body, repo)}."
            new[p["start"] + 1: p["end"]] = ["", pointer, ""]
        for dest in {p["destination"] for p in plan}:
            old_d, new_d = files[dest]
            if old_d and "\r\n" in old_d:   # keep a CRLF destination CRLF throughout
                files[dest] = (old_d, new_d.replace("\r\n", "\n").replace("\n", "\r\n"))
        n_finds, n_docs, unlinked = audit_nested(repo, nested, f, rel, text)
        finds += n_finds
        if unlinked:
            new = add_root_pointers(new, unlinked, rel)
        a_finds, a_doc, a_pointer = audit_architecture(repo, f, rel, text)
        finds += a_finds
        if a_pointer and not any(p["kind"] == "architecture" for p in plan):
            new = structure_insert(new, ["- " + ARCH_POINTER.format(up="../" * rel.count("/"), path=a_doc["path"])])
        docs = [{"path": rel, "kind": "root", "lines": an["lines"], "chars": an["chars"],
                 "commits_since": since}] + n_docs + ([a_doc] if a_doc else [])
        stubs = [stub_for(k, f) for k in ("commands", "landmines", "deploy")
                 if any(x["id"] == f"missing-section-{k}" and x["severity"] == "warn" for x in finds)]
        new_text = eol.join(new)
        if stubs:
            new_text = new_text.rstrip("\r\n") + eol + eol + (eol + eol).join(
                s.replace("\n", eol) for s in stubs if s)
        if new_text.rstrip("\r\n") != text.rstrip("\r\n"):
            files[rel] = (text, new_text.rstrip("\r\n") + eol)
        # A generated root is fixed at its source: a Source header's file gets the same
        # edits; a generator folder (.ruler/, .rulesync/) gets none, and neither do the
        # split's destinations, which would duplicate what the next sync puts back.
        for g in f.get("generated_entry_docs") or []:
            src = g.get("source_of_truth")
            single = bool(src) and (repo / src).is_file()
            finds.append({"id": "generated-entry-doc", "severity": "info", "path": g["path"],
                          "msg": f"{g['path']} is generated by {g['generator']} from {src or 'an unnamed source'}: "
                                 "fix the source, because the next sync overwrites this file. "
                                 + ("The patch edits the source." if single else
                                    "The patch leaves it alone.")})
            if g["path"] != rel or rel not in files:
                continue
            old_root, new_root = files.pop(rel)
            if single:
                src_text = read_raw(repo / src)
                fixed = retarget(old_root, new_root, src_text)
                if fixed != src_text:
                    files[src] = (src_text, fixed)
            else:
                for p_ in plan:
                    files.pop(p_["destination"], None)
        c_finds, c_edits = shadow_findings(repo, rel, args.no_parents)
        finds += c_finds
        generated = {g["path"] for g in f.get("generated_entry_docs") or []}
        for name, (old, newc) in c_edits.items():
            if name not in generated:   # the next sync would overwrite a fix to generated output
                files[name] = (old, newc)
        cands = f.get("candidates") or []
        data["ruled_out"] = 0
        if (repo / RULED_OUT).is_file():
            entries, unparsed = parse_ruled_out(read_raw(repo / RULED_OUT))
            cands, data["ruled_out"], r_finds = apply_ruled_out(cands, entries, date.today().isoformat())
            finds += r_finds
            finds += [{"id": "ruled-out-unparsed", "severity": "info", "path": f"{RULED_OUT}:{n}",
                       "msg": "this line looks like a ruled-out entry but does not parse: "
                              "- [kind] `path` @count: reason"} for n in unparsed]
        # Each candidate is asked of the deepest AGENTS.md whose folder holds all of its
        # paths (spec N4); only that doc's text can answer it.
        nested_dirs = [os.path.dirname(n) for n in nested]
        texts = {n: read_raw(repo / n) for n in nested}
        uncovered, by_doc = [], {}
        for c in cands:
            if not c.get("paths"):
                continue
            od = owner_dir(c["paths"], nested_dirs)
            doc = f"{od}/AGENTS.md" if od else rel
            if uncovered_candidates(texts.get(doc, text), [c]):
                uncovered.append({**c, "doc": doc})
                by_doc.setdefault(doc, []).append(c)
        data["uncovered_candidates"] = uncovered
        for doc, cs in sorted(by_doc.items()):
            shown = ", ".join(f"`{c['paths'][0]}`" for c in cs[:5])
            more = f" and {len(cs) - 5} more" if len(cs) > 5 else ""
            finds.append({"id": "uncovered-candidates", "severity": "info", "path": doc,
                          "msg": f"{len(cs)} landmine candidate(s) from the repo scan name files "
                                 f"{doc} never mentions: {shown}{more}. Answer each as a landmine or "
                                 "rule it out (--json lists the questions)"})
        for d in docs:
            d["uncovered"] = len(by_doc.get(d["path"], []))
        prose = [(i, lines[i]) for s in h2_sections(lines) if s["key"] in ("landmines", "conventions")
                 for i in range(s["start"] + 1, s["end"])]
        finds += ungated(rel, prose, f.get("gates") or [], repo)
        for i, item in landmine_items(lines):
            od = owner_dir(named_paths(item), nested_dirs)
            if od:
                finds.append({"id": "landmine-belongs-nested", "severity": "info", "path": f"{rel}:{i + 1}",
                              "msg": f"this landmine names only paths in `{od}/`, so it belongs in "
                                     f"{od}/AGENTS.md. Move it by hand; the patch never moves a landmine"})
    sev_rank = {"crit": 0, "warn": 1, "info": 2}
    finds.sort(key=lambda x: (sev_rank[x["severity"]], x["id"], x["path"]))
    l_finds, data["load"] = load_findings(repo, rel, nested)
    finds += l_finds
    for doc in nested:   # dead paths in nested docs: reported, not patched
        for i, tok, renamed in dead_paths(repo, read_raw(repo / doc).splitlines()):
            finds.append({"id": "dead-path", "severity": "warn", "path": f"{doc}:{i + 1}",
                          "msg": f"`{tok}` is gone: " + (f"git history renamed it to `{renamed}`" if renamed
                                                          else "git history has it, the tree doesn't")})
    finds.sort(key=lambda x: (sev_rank[x["severity"]], x["id"], x["path"]))
    for doc in docs:
        doc["findings"] = [x["id"] for x in finds if x["path"].split(":")[0] == doc["path"]]
    data["docs"] = docs
    data["findings"] = finds
    patch = build_patch(files)
    data["diff"] = patch or None
    bad = any(x["severity"] in ("crit", "warn") for x in finds)
    if args.explain:
        sev, rule, source = finding_doc(args.explain) or ("", "", "")
        ev = [x for x in finds if x["id"] == args.explain]
        if args.json:
            emit_json({"data": {"id": args.explain, "severity": sev, "rule": rule, "source": source,
                                "evidence": ev}, "meta": {"schema": SCHEMA_AUDIT}})
        else:
            print(f"{args.explain} ({sev})\nrule: {rule}\nsource: {source}\nevidence:")
            for x in ev:
                print(f"  {x['path']}: {x['msg']}")
            if not ev:
                print("  none in this repo")
        return EX_OK
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
            head += (f"{data['commits_since']} commits since last touch" if data["commits_since"] is not None
                     else "not committed yet")
            head += f", {data['ruled_out']} ruled out)" if data.get("ruled_out") else ")"
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


# How much each survey issue weighs when ranking the weakest repos. A missing or
# shadowed entry doc is worst: agents enter blind. The roll-up reports the share at the
# bar and the five weakest, never an average, because an average hides the worst repos.
ISSUE_WEIGHT = {"missing": 5, "claude-only": 5, "shadowed": 4, "claude-local-committed": 4, "incomplete": 3,
                "unreadable": 3, "draft": 2, "over-200": 2, "over-size": 2, "flat-monorepo": 2, "stale": 1}


def survey_workspaces(base: list[str], full: str, entries: dict) -> list[str]:
    """Workspace globs from package.json `workspaces` (one more GET) or pnpm-workspace.yaml."""
    globs: list[str] = []
    if "package.json" in entries:
        try:
            ws = json.loads(blob_text(base, full, entries["package.json"]["sha"]) or "{}").get("workspaces")
        except (ValueError, AttributeError):
            ws = None
        globs += ws if isinstance(ws, list) else (ws or {}).get("packages", []) if isinstance(ws, dict) else []
    if "pnpm-workspace.yaml" in entries:
        text = blob_text(base, full, entries["pnpm-workspace.yaml"]["sha"]) or ""
        globs += [m.strip("'\"") for m in re.findall(r"(?m)^\s*-\s*(\S+)", text) if not m.startswith("!")]
    return [g for g in globs if isinstance(g, str)]


def survey_repo(base: list[str], full: str, branch: str | None) -> dict:
    row: dict = {"repo": full, "default_branch": branch, "agents_md": False, "claude_md": [],
                 "shadowed": False, "lines": None, "chars": None, "commits_since": None, "coverage": None,
                 "sections": None, "nested_agents_md": 0, "nested_coverage": None, "architecture_md": None,
                 "issues": [], "status": "ok"}
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
    row["architecture_md"] = next((a for a in ARCH_FILES if a in entries), None)
    globs = survey_workspaces(base, full, entries)
    members = sorted({p[:-len("/package.json")] for p in entries if p.endswith("/package.json")
                      and any(glob_member(p[:-len("/package.json")], g) for g in globs)})
    if members:
        row["nested_coverage"] = f"{sum(1 for m in members if m + '/AGENTS.md' in entries)}/{len(members)}"
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
            row.update(lines=an["lines"], chars=an["chars"], sections=an["sections"],
                       coverage=coverage_letters(an["sections"]))
            if an["lines"] > CEILING_LINES:
                issues.append("over-200")
            elif an["chars"] > CEILING_CHARS:
                issues.append("over-size")   # under 200 lines, but long lines make it as costly
            if not (an["sections"]["commands"] and an["sections"]["landmines"]):
                issues.append("incomplete")
            if members and not row["nested_agents_md"] and (an["lines"] > TARGET_LINES or an["chars"] > TARGET_CHARS):
                issues.append("flat-monorepo")   # workspaces, a root past its target, nothing nested
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
            "over_size": sum(1 for r in rows if "over-size" in r["issues"]),
            "stale": sum(1 for r in rows if "stale" in r["issues"]),
            "incomplete": sum(1 for r in rows if "incomplete" in r["issues"]),
            "unreadable": sum(1 for r in rows if r["status"] == "unreadable"),
            "empty": sum(1 for r in rows if r["status"] == "empty"),
            "flat_monorepo": sum(1 for r in rows if "flat-monorepo" in r["issues"]),
            "architecture_md": sum(1 for r in rows if r["architecture_md"])}
    active = [r for r in rows if r["status"] != "empty"]
    meta["active"] = len(active)
    meta["at_bar"] = sum(1 for r in active if not r["issues"])
    meta["at_bar_share"] = round(meta["at_bar"] / len(active), 3) if active else None
    meta["weakest"] = [r["repo"] for r in sorted((r for r in active if r["issues"]), key=lambda r: (
        -sum(ISSUE_WEIGHT.get(i, 1) for i in r["issues"]), r["repo"]))[:5]]
    if args.json:
        emit_json({"data": rows, "meta": meta})
    else:
        width = max([len(r["repo"]) for r in rows] + [4])
        print(f"{'REPO'.ljust(width)}  AGENTS  CLAUDE  SHADOW  LINES     KB  SINCE  COVER   NEST  ARCH  STATUS")
        for r in rows:
            claude = "+".join("L" if c["path"] == "CLAUDE.local.md" else "C" for c in r["claude_md"]) or "-"
            kb = f"{r['chars'] / 1000:.1f}" if r["chars"] else "-"
            print(f"{r['repo'].ljust(width)}  {'yes' if r['agents_md'] else '-':<6}  {claude:<6}  "
                  f"{'YES' if r['shadowed'] else '-':<6}  {str(r['lines'] or '-'):>5}  {kb:>5}  "
                  f"{str(r['commits_since'] if r['commits_since'] is not None else '-'):>5}  "
                  f"{r['coverage'] or '-':<6}  {r['nested_coverage'] or str(r['nested_agents_md'] or '-'):>4}  "
                  f"{'yes' if r['architecture_md'] else '-':<4}  {r['status']}")
        eecho("coverage letters: O overview, C commands, L landmines, D deploy, S structure, V conventions")
        eecho(f"summary: {meta['repos']} repos, {meta['agents_md_only']} AGENTS.md only, "
              f"{meta['claude_md_only']} CLAUDE.md only, {meta['both']} both, {meta['neither']} neither, "
              f"{meta['shadowed']} shadowed, {meta['over_200_lines']} over 200 lines, "
              f"{meta['over_size']} over 16 KB in fewer lines, {meta['stale']} stale, "
              f"{meta['flat_monorepo']} flat monorepo(s)")
        if active:
            eecho(f"at the bar: {meta['at_bar']}/{meta['active']} active repos ({meta['at_bar_share']:.0%}); "
                  f"weakest: {', '.join(meta['weakest']) or 'none'}")
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
               "  agents-md.py survey --org my-org --json\n"
               "  agents-md.py explain packages/engine --tool all\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sp = sub.add_parser("scaffold", help="draft an AGENTS.md from repo-scan facts")
    sp.add_argument("--repo", default=".")
    sp.add_argument("--facts", help="saved `repo-scan.py --json` output")
    sp.add_argument("--archetype", default="auto",
                    choices=["auto", "php-cms", "node-app", "python-service", "static-site", "generic"])
    sp.add_argument("--dir", help="draft a nested <FOLDER>/AGENTS.md (deltas from the root only)")
    sp.add_argument("--architecture", action="store_true", help="draft ARCHITECTURE.md (matklad's shape)")
    sp.add_argument("--write", action="store_true", help="create the AGENTS.md (never overwrites)")
    sp.add_argument("--json", action="store_true")
    ap_a = sub.add_parser("audit", help="audit an AGENTS.md; --diff proposes an upgrade patch")
    ap_a.add_argument("--repo", default=".")
    ap_a.add_argument("--facts", help="saved `repo-scan.py --json` output")
    ap_a.add_argument("--diff", action="store_true", help="print only a git-apply-able patch")
    ap_a.add_argument("--explain", metavar="FINDING_ID", help="print one finding's rule, source and evidence")
    ap_a.add_argument("--no-parents", action="store_true",
                      help="skip the check for CLAUDE.md files above the repo")
    ap_a.add_argument("--json", action="store_true")
    ap_e = sub.add_parser("explain", help="what each tool loads for work in a folder")
    ap_e.add_argument("--repo", default=".")
    ap_e.add_argument("folder", help="a folder inside the repo (. for the root)")
    ap_e.add_argument("--tool", default="claude-code", help="a tool-profiles.json id, or all")
    ap_e.add_argument("--json", action="store_true")
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
    if args.cmd == "audit" and args.diff and args.explain:
        eecho("agents-md: --explain prints one finding; it does not combine with --diff")
        return EX_USAGE
    if args.cmd == "audit" and args.diff and args.json:
        eecho("agents-md: --diff and --json are mutually exclusive (--json already carries data.diff)")
        return EX_USAGE
    if args.cmd == "scaffold" and args.dir and args.architecture:
        eecho("agents-md: --dir and --architecture draft different files; pick one")
        return EX_USAGE
    if args.cmd == "scaffold" and (args.dir or args.architecture) and args.archetype != "auto":
        eecho("agents-md: --archetype shapes the root draft; a --dir draft has one shape")
        return EX_USAGE
    if args.cmd == "survey" and args.limit < 1:
        eecho("agents-md: --limit must be >= 1")
        return EX_USAGE
    return {"scaffold": cmd_scaffold, "audit": cmd_audit, "survey": cmd_survey,
            "explain": cmd_explain}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
