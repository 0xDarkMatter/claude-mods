#!/usr/bin/env python3
"""repo-doctor — score any repo against the agentic-quality doctrine.

Usage:   repo-doctor.py [--repo PATH] [--json] [--strict] [--top N] [--sample N]
Input:   a git repository (defaults to cwd); no network, no writes — read-only audit
Output:  TTY panel report on stdout by default; --json emits ONLY a JSON envelope
         {"data": {...}, "meta": {"schema": "claude-mods.repo-doctor/v1"}} on stdout
         with per-dimension scores (0-5), letter grade, and a findings list, each
         finding carrying {dim, severity, msg, path}. Severity: crit | warn | info.
Stderr:  progress/warnings only (never data)
Exit:    0 report produced (grade >= B, or --strict not set and repo readable),
         10 --strict and grade below B (CI gate), 2 usage error, 3 not a git repo

Dimensions scored (0-5 each, weighted into the grade):
  entry_docs   AGENTS.md/CLAUDE.md presence, Landmines section, length budget,
               freshness measured in commits-since-touched (never days)
  docs_health  README, docs/ index when >6 files, ghost/missing index entries
  comments     contract blocks on the largest source files; section markers in
               files >400 lines
  structure    monster files (>800 warn, >1500 crit; generated/vendored exempt),
               repo-root junk (media, scratch artifacts)
  enforcement  tests present, CI workflows, single `check` entry point,
               invariant gate scripts (the lint:db pattern)
  doc_pairing  fraction of recent feat/fix commits that touch a *.md in the
               same commit — the as-you-go signature

Examples:
  repo-doctor.py                          # audit the cwd, human panel
  repo-doctor.py --repo X:/DnD/Simulacra  # audit another repo
  repo-doctor.py --json | jq .data.grade  # machine-readable
  repo-doctor.py --strict                 # exit 10 if grade < B (CI gate)
  repo-doctor.py --top 15                 # show 15 findings instead of 10

Doctrine: rules/agentic-quality.md. Rubric + fixes per finding:
references/scoring-rubric.md (sibling of this script's skill).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA = "claude-mods.repo-doctor/v1"

SOURCE_EXTS = {
    ".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".go", ".rs", ".rb",
    ".php", ".java", ".cs", ".c", ".cc", ".cpp", ".h", ".hpp", ".sh", ".ps1",
    ".sql", ".vue", ".svelte", ".html",
}
EXCLUDE_DIRS = {
    ".git", "node_modules", ".venv", "venv", "dist", "build", "out", "vendor",
    "__pycache__", ".next", ".nuxt", "coverage", "target", ".claude",
}
MEDIA_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".mp4", ".mov", ".webm", ".zip",
              ".7z", ".tar", ".gz", ".glb", ".psd"}
SCRATCH_PAT = re.compile(r"^(tmp|temp|scratch|junk|old|copy|test)[-_]", re.I)
GENERATED_PAT = re.compile(r"generated|do not edit|don'?t hand-edit|@generated", re.I)
# Deliberateness signals for justified large files. Extend this list when the
# doctrine adopts another unambiguous way to say that a file must stay whole.
LARGE_FILE_GUARD_SIGNALS = (
    "do not split", "deliberately single-file", "deliberately single file",
    "single-file", "single file", "one file",
)
LARGE_FILE_GUARD_PAT = re.compile(
    "|".join(re.escape(signal) for signal in LARGE_FILE_GUARD_SIGNALS), re.I)
LARGE_FILE_SECTION_PAT = re.compile(
    r"^\s*(?:#|//|;|<!--)\s*===\s+\w[\w .-]*\s+===", re.M)
BOXED_SECTION_PAT = re.compile(
    r"(?m)^\s*#\s*=+\s*$\n^\s*#\s+\w[^\n]*$\n^\s*#\s*=+\s*$")
LANDMINE_PAT = re.compile(r"landmine|gotcha|pitfall|footgun|hazard|trap|don'?t", re.I)
COMMENT_LINE = re.compile(r"^\s*(#|//|/\*|\*|<!--|--|\"\"\"|''')")
SECTION_PAT = re.compile(r"^\s*(#|//|/\*|<!--|--)\s*.{0,8}([=─-]{4,}|SECTION|═{4,})")
FEATFIX_PAT = re.compile(r"^(feat|fix|refactor|perf)\b", re.I)

MONSTER_WARN, MONSTER_CRIT = 800, 1500
ENTRY_LEAN_LINES = 250
FRESH_COMMITS = 15
DOCS_INDEX_THRESHOLD = 6
WEIGHTS = {"entry_docs": 2.0, "docs_health": 1.5, "comments": 2.0,
           "structure": 2.0, "enforcement": 1.5, "doc_pairing": 1.0}


def eecho(msg: str) -> None:
    print(msg, file=sys.stderr)


def git(repo: Path, *args: str) -> str:
    try:
        r = subprocess.run(["git", "-C", str(repo), *args],
                           capture_output=True, text=True, timeout=30,
                           encoding="utf-8", errors="replace")
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def commits_since_touch(repo: Path, rel: str) -> int | None:
    """How many commits landed after this file was last touched. None = untracked."""
    last = git(repo, "rev-list", "-1", "HEAD", "--", rel)
    if not last:
        return None
    n = git(repo, "rev-list", "--count", "HEAD", f"^{last}")
    return int(n) if n.isdigit() else None


def large_file_signals(path: Path) -> tuple[bool, bool]:
    """Return (guard comment, section map) for a deliberately large file."""
    try:
        body = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False, False

    # Phrases only count inside comments/docstrings, never executable strings.
    comment_regions = re.findall(
        r"<!--.*?-->|/\*.*?\*/|'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|"
        r"(?m:^\s*(?:#|//|;).*?$)",
        body,
        flags=re.S,
    )
    has_guard = any(LARGE_FILE_GUARD_PAT.search(region) for region in comment_regions)
    marker_count = (len(LARGE_FILE_SECTION_PAT.findall(body))
                    + len(BOXED_SECTION_PAT.findall(body)))
    has_map = marker_count >= 3
    return has_guard, has_map


def iter_source_files(repo: Path):
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")]
        for f in files:
            p = Path(root) / f
            if p.suffix.lower() in SOURCE_EXTS and ".min." not in f:
                yield p


def head_lines(p: Path, n: int) -> list[str]:
    try:
        with p.open(encoding="utf-8", errors="replace") as fh:
            return [next(fh, "") for _ in range(n)]
    except OSError:
        return []


def count_lines(p: Path) -> int:
    try:
        with p.open("rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def is_generated(p: Path) -> bool:
    return any(GENERATED_PAT.search(l) for l in head_lines(p, 3))


class Audit:
    def __init__(self, repo: Path, sample: int):
        self.repo = repo
        self.sample = sample
        self.findings: list[dict] = []
        self.scores: dict[str, float] = {}
        self.facts: dict = {}

    def add(self, dim: str, severity: str, msg: str, path: str = "") -> None:
        self.findings.append({"dim": dim, "severity": severity,
                              "msg": msg, "path": path})

    # -- dimension: entry docs ------------------------------------------------
    def check_entry_docs(self) -> None:
        score = 0.0
        agents = self.repo / "AGENTS.md"
        claude = self.repo / "CLAUDE.md"
        entry = agents if agents.exists() else (claude if claude.exists() else None)
        self.facts["entry_doc"] = entry.name if entry else None
        if not entry:
            self.add("entry_docs", "crit",
                     "no AGENTS.md or CLAUDE.md — agents enter blind; "
                     "generate one (doc-scanner skill) with a Landmines section")
            self.scores["entry_docs"] = 0
            return
        score += 2
        text = entry.read_text(encoding="utf-8", errors="replace")
        lines = text.count("\n") + 1
        self.facts["entry_doc_lines"] = lines
        if LANDMINE_PAT.search(text):
            score += 1
        else:
            self.add("entry_docs", "warn",
                     f"{entry.name} has no Landmines/gotchas section — the "
                     "highest-value lines for agents are missing", entry.name)
        if lines <= ENTRY_LEAN_LINES:
            score += 1
        else:
            self.add("entry_docs", "warn",
                     f"{entry.name} is {lines} lines (budget ~{ENTRY_LEAN_LINES}) — "
                     "agents pay this token cost every session; push walkthroughs "
                     "into docs/ and link them", entry.name)
        since = commits_since_touch(self.repo, entry.name)
        self.facts["entry_doc_commits_since"] = since
        if since is not None and since <= FRESH_COMMITS:
            score += 1
        elif since is not None:
            self.add("entry_docs", "warn",
                     f"{entry.name} last touched {since} commits ago — verify it "
                     "still describes the code, then touch it in the fixing commit",
                     entry.name)
        if agents.exists() and claude.exists():
            ctext = claude.read_text(encoding="utf-8", errors="replace")
            if len(ctext) > 400 and ctext[:400] in text:
                self.add("entry_docs", "warn",
                         "CLAUDE.md appears to duplicate AGENTS.md — keep deltas "
                         "only, or reduce CLAUDE.md to a pointer", "CLAUDE.md")
            else:
                self.add("entry_docs", "info",
                         "both AGENTS.md and CLAUDE.md present — fine if CLAUDE.md "
                         "is deltas-only (Gather pattern); shared rule changes must "
                         "update both in one commit")
        self.scores["entry_docs"] = score

    # -- dimension: docs health -----------------------------------------------
    def check_docs_health(self) -> None:
        score = 5.0
        if not (self.repo / "README.md").exists():
            score -= 1
            self.add("docs_health", "warn", "no README.md — humans enter blind")
        docs = self.repo / "docs"
        if not docs.is_dir():
            self.facts["docs_md_count"] = 0
            self.scores["docs_health"] = min(score, 4.0)  # small repos: fine, capped
            return
        md = sorted(p for p in docs.rglob("*.md")
                    if not any(part in EXCLUDE_DIRS for part in p.parts))
        self.facts["docs_md_count"] = len(md)
        index = next((docs / n for n in
                      ("00_INDEX.md", "INDEX.md", "PLAN.md") if (docs / n).exists()),
                     None)
        if len(md) > DOCS_INDEX_THRESHOLD and not index:
            score -= 2
            self.add("docs_health", "warn",
                     f"docs/ has {len(md)} files and no index "
                     "(00_INDEX.md / INDEX.md / PLAN.md) — agents hunt instead of "
                     "navigate; add one with a maintenance note", "docs/")
        if index:
            itext = index.read_text(encoding="utf-8", errors="replace")
            # Ghosts: only actual markdown LINK targets count — bare filename
            # mentions in prose/checklists ("removed DASH.md") are history, not
            # references. Mentions still count as "indexed" for the missing check.
            linked = {t.split("#")[0].split("/")[-1] for t in
                      re.findall(r"\]\(([^)#\s]+\.md)[^)]*\)", itext)
                      if not t.startswith("http")}
            mentioned = set(re.findall(r"([A-Za-z0-9_\-]+\.md)", itext))
            ghosts = [t for t in linked
                      if t != index.name and not list(docs.rglob(t))
                      and not (self.repo / t).exists()]
            missing = [p.name for p in md
                       if p.name not in mentioned and p != index
                       and p.parent == docs]
            if ghosts:
                score -= 1
                self.add("docs_health", "warn",
                         f"{index.name} references missing files: "
                         f"{', '.join(ghosts[:5])}", f"docs/{index.name}")
            if len(missing) > 2:
                self.add("docs_health", "info",
                         f"{len(missing)} docs/*.md not mentioned in {index.name}: "
                         f"{', '.join(missing[:5])}…", f"docs/{index.name}")
        self.scores["docs_health"] = max(score, 0)

    # -- dimension: comments ----------------------------------------------------
    def check_comments(self) -> None:
        sized = sorted(((count_lines(p), p) for p in iter_source_files(self.repo)),
                       reverse=True)
        top = [(n, p) for n, p in sized[: self.sample] if n >= 100]
        self.facts["source_files"] = len(sized)
        if not top:
            self.scores["comments"] = 5
            return
        contract_ok = markers_ok = markers_needed = 0
        for n, p in top:
            rel = str(p.relative_to(self.repo)).replace("\\", "/")
            head = head_lines(p, 15)
            # A line counts as comment if it matches a comment prefix OR sits
            # inside an open block comment: Python triple-quoted docstrings and
            # PowerShell <# ... #> blocks carry prose lines with no per-line
            # prefix, but they ARE the contract block.
            in_doc = False
            n_comment = 0
            for l in head:
                quotes = l.count('"""') + l.count("'''")
                opens = quotes % 2 == 1 or ("<#" in l and "#>" not in l)
                closes = "#>" in l and "<#" not in l
                if in_doc or COMMENT_LINE.match(l) or quotes or "<#" in l:
                    n_comment += 1
                if in_doc and (closes or quotes % 2 == 1):
                    in_doc = False
                elif not in_doc and opens:
                    in_doc = True
            has_contract = n_comment >= 3
            if has_contract:
                contract_ok += 1
            else:
                self.add("comments", "warn",
                         f"no contract block: first 15 lines of a {n}-line file "
                         "carry <3 comment lines — open with what/invariants/refs",
                         rel)
            if n > 400 and not is_generated(p):
                markers_needed += 1
                try:
                    body = p.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    body = ""
                if any(SECTION_PAT.match(l) for l in body.splitlines()):
                    markers_ok += 1
                else:
                    self.add("comments", "info",
                             f"{n}-line file has no section markers — add "
                             "`// === SECTION ===` so agents jump, not scroll", rel)
        score = 5 * (contract_ok / len(top))
        if markers_needed:
            score = score * 0.7 + 5 * (markers_ok / markers_needed) * 0.3
        self.facts["contract_block_ratio"] = round(contract_ok / len(top), 2)
        self.scores["comments"] = round(score, 1)

    # -- dimension: structure ---------------------------------------------------
    def check_structure(self) -> None:
        score = 5.0
        monsters = []
        for p in iter_source_files(self.repo):
            n = count_lines(p)
            if n >= MONSTER_WARN and not is_generated(p):
                monsters.append((n, str(p.relative_to(self.repo)).replace("\\", "/")))
        monsters.sort(reverse=True)
        self.facts["monster_files"] = monsters[:10]
        penalties = []
        for n, rel in monsters[:10]:
            has_guard, has_map = large_file_signals(self.repo / rel)
            if has_guard and has_map:
                self.add("structure", "info",
                         f"{n}-line large file with guard comment + section map — "
                         "verify its mechanical gate exists", rel)
                continue
            if has_guard or has_map:
                missing = "section map" if has_guard else "guard comment"
                self.add("structure", "warn",
                         f"{n}-line large file has only half its justification — "
                         f"missing {missing}", rel)
                penalties.append(0.5)
                continue
            penalties.append(1.0 if n >= MONSTER_CRIT else 0.5)
            if n >= MONSTER_CRIT:
                self.add("structure", "crit",
                         f"{n}-line file — split by responsibility (refactor-ops) "
                         "or justify with a guard comment + section map + a "
                         "mechanical gate for the invariant that keeps it whole", rel)
            else:
                self.add("structure", "warn",
                         f"{n}-line file — needs section markers now, a split "
                         "or a written justification before it grows", rel)
        score -= min(3.0, sum(penalties))
        junk = []
        for p in self.repo.iterdir():
            if p.is_file():
                if (p.suffix.lower() in MEDIA_EXTS
                        and p.stat().st_size > 1_000_000) \
                        or SCRATCH_PAT.match(p.name):
                    junk.append(p.name)
        if junk:
            score -= min(2.0, 0.5 * len(junk))
            self.add("structure", "warn",
                     f"repo-root junk ({len(junk)}): {', '.join(junk[:6])} — move "
                     "to docs/screenshots/, dev/, or delete")
        self.scores["structure"] = max(score, 0)

    # -- dimension: enforcement ---------------------------------------------------
    def check_enforcement(self) -> None:
        score = 0.0
        has_tests = any((self.repo / d).is_dir() for d in ("tests", "test")) or \
            bool(list(self.repo.glob("**/*.test.*"))[:1]) or \
            bool(list(self.repo.glob("**/test_*.py"))[:1])
        if has_tests:
            score += 1.5
        else:
            self.add("enforcement", "warn", "no tests found — agents fly blind")
        if (self.repo / ".github" / "workflows").is_dir():
            score += 1
        else:
            self.add("enforcement", "info", "no CI workflows (.github/workflows)")
        check_entry = False
        pkg = self.repo / "package.json"
        if pkg.exists():
            try:
                check_entry = "check" in json.loads(
                    pkg.read_text(encoding="utf-8", errors="replace")
                ).get("scripts", {})
            except (json.JSONDecodeError, OSError):
                pass
        for jf in ("justfile", "Justfile", "Makefile"):
            f = self.repo / jf
            if f.exists() and re.search(r"^check\s*:", f.read_text(
                    encoding="utf-8", errors="replace"), re.M):
                check_entry = True
        if check_entry:
            score += 1.5
        else:
            self.add("enforcement", "warn",
                     "no single `check` entry point (npm run check / just check) — "
                     "if it isn't one command, agents won't run it")
        gates = [p.name for p in (self.repo / "scripts").glob("check-*")] \
            if (self.repo / "scripts").is_dir() else []
        gates += [p.name for p in (self.repo / "tests").glob("*drift*")] \
            if (self.repo / "tests").is_dir() else []
        if gates:
            score += 1
            self.facts["invariant_gates"] = gates[:5]
        else:
            self.add("enforcement", "info",
                     "no invariant gate scripts (scripts/check-*.mjs pattern) — "
                     "prose rules rot; 30-line scripts don't")
        self.scores["enforcement"] = min(score, 5)

    # -- dimension: doc pairing --------------------------------------------------
    def check_doc_pairing(self) -> None:
        raw = git(self.repo, "log", "--no-merges", "-n", "60",
                  "--pretty=%x01%s", "--name-only")
        if not raw:
            self.scores["doc_pairing"] = 2.5
            return
        featfix = paired = 0
        for block in raw.split("\x01"):
            blines = [l for l in block.strip().splitlines() if l.strip()]
            if not blines or not FEATFIX_PAT.match(blines[0]):
                continue
            featfix += 1
            if any(l.strip().lower().endswith(".md") for l in blines[1:]):
                paired += 1
        if featfix == 0:
            self.scores["doc_pairing"] = 2.5
            return
        ratio = paired / featfix
        self.facts["doc_pairing_ratio"] = round(ratio, 2)
        self.facts["featfix_commits_sampled"] = featfix
        self.scores["doc_pairing"] = round(min(5, ratio * 10), 1)  # 50% pairing = 5
        if ratio < 0.15:
            self.add("doc_pairing", "warn",
                     f"only {paired}/{featfix} recent feat/fix commits touched any "
                     "*.md — docs are drifting; pair the doc touch with the feature")

    # -- roll-up -------------------------------------------------------------------
    def run(self) -> dict:
        self.check_entry_docs()
        self.check_docs_health()
        self.check_comments()
        self.check_structure()
        self.check_enforcement()
        self.check_doc_pairing()
        total_w = sum(WEIGHTS.values())
        overall = sum(self.scores[k] * WEIGHTS[k] for k in WEIGHTS) / total_w
        grade = ("A" if overall >= 4.5 else "B" if overall >= 3.5 else
                 "C" if overall >= 2.5 else "D" if overall >= 1.5 else "F")
        sev_rank = {"crit": 0, "warn": 1, "info": 2}
        self.findings.sort(key=lambda f: sev_rank[f["severity"]])
        return {"repo": str(self.repo), "grade": grade,
                "overall": round(overall, 2), "scores": self.scores,
                "facts": self.facts, "findings": self.findings}


# ---- rendering ------------------------------------------------------------------
def render_panel(result: dict, top: int) -> None:
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    uni = "utf" in enc or "cp65001" in enc
    bar_on, bar_off = ("█", "░") if uni else ("#", ".")
    rail = "│" if uni else "|"
    print(f"repo-doctor {rail} {result['repo']}")
    print(f"grade: {result['grade']}  ({result['overall']}/5)")
    print()
    for dim, sc in result["scores"].items():
        filled = round(sc)
        print(f"  {dim:<12} {bar_on * filled}{bar_off * (5 - filled)}  {sc}/5")
    shown = result["findings"][:top]
    if shown:
        print()
        for f in shown:
            loc = f" [{f['path']}]" if f["path"] else ""
            print(f"  {f['severity'].upper():<5} {f['msg']}{loc}")
    hidden = len(result["findings"]) - len(shown)
    if hidden > 0:
        print(f"  … {hidden} more (use --top {len(result['findings'])} or --json)")
    print()
    print("rubric + per-finding fixes: references/scoring-rubric.md (repo-doctor skill)")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Score a repo against the agentic-quality doctrine "
                    "(rules/agentic-quality.md). Read-only.",
        epilog="EXAMPLES:\n"
               "  repo-doctor.py\n"
               "  repo-doctor.py --repo X:/DnD/Simulacra --json\n"
               "  repo-doctor.py --strict   # CI gate: exit 10 below grade B\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="repo path (default: cwd)")
    ap.add_argument("--json", action="store_true",
                    help="emit JSON envelope on stdout (no panel)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 10 if grade is below B")
    ap.add_argument("--top", type=int, default=10,
                    help="findings to show in the panel (default 10)")
    ap.add_argument("--sample", type=int, default=12,
                    help="largest source files sampled for comment checks")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"repo-doctor: not a directory: {repo}")
        return 2
    if not (repo / ".git").exists():
        eecho(f"repo-doctor: not a git repo: {repo} (init or pass --repo)")
        return 3

    result = Audit(repo, args.sample).run()
    if args.json:
        print(json.dumps({"data": result, "meta": {"schema": SCHEMA}}, indent=2))
    else:
        render_panel(result, args.top)
    if args.strict and result["grade"] not in ("A", "B"):
        return 10
    return 0


if __name__ == "__main__":
    sys.exit(main())
