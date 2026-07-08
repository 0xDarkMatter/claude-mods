#!/usr/bin/env python3
"""Conformance linter for Architecture Decision Records.

Validates every ADR-*.md in --dir against the canonical protocol: required
frontmatter (present + well-typed), the `# ADR-NNN: Title` line matching the
filename, the BLUF `## Decision (one sentence)` right after the title, the fixed
core section order, no duplicate numbers, and — the high-value cross-file check —
supersession bidirectionality.

Usage:   adr-lint.py [--dir DIR] [--repo-root DIR] [--strict] [--json]
Input:   argv flags only (no stdin).
Output:  stdout = findings (plain table, or --json envelope). Data only.
Stderr:  headers, the yq/PyYAML fallback notice, errors.
Exit:    0 conformant, 2 usage, 3 dir not found, 4 a file's frontmatter
         unparseable, 10 findings present (errors; or warnings too under --strict)

Beyond format/order/duplicate/supersession-bidirectionality, also checks:
lifecycle consistency (status vs superseded-by), and — when a touches: entry is a
literal filesystem path — whether it still resolves under --repo-root (a stale
discovery surface), reported as a warning.

Prefers PyYAML for frontmatter; falls back to a minimal parser when it is absent
(announced on stderr). The supersession cross-check is the one most worth running.

Examples:
  adr-lint.py
  adr-lint.py --dir docs/decisions --strict
  adr-lint.py --json | jq '.data[] | select(.severity=="error")'
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (term.sh is bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline with matching keys/glyphs).

    Honors FORCE_COLOR / NO_COLOR / TERM_ASCII (+ legacy FLEET_ASCII). Color tracks
    the bound stream's TTY so piped data stays plain; ASCII mode swaps every glyph
    for its registered proxy (✓✗▲—? -> +x!-?)."""

    _C = {
        "green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
        "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m",
    }
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stdout):
        # ASCII fallback: explicit env, OR the bound stream can't encode UTF (e.g. a
        # Windows cp1252 pipe) — mirrors term.sh's non-UTF-locale rule and prevents a
        # UnicodeEncodeError when a glyph hits a legacy codec.
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (
            os.environ.get("TERM_ASCII") == "1"
            or os.environ.get("FLEET_ASCII") == "1"
            or "utf" not in enc
        )
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None
              or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        if not self.color:
            return text
        return f"{self._C.get(name, '')}{text}{self._C['off']}"

    def mark(self, state):
        glyph = (self._ASCII if self.ascii else self._GLYPH).get(state, "." )
        return self.c(self._MARK_COLOR.get(state, ""), glyph)


EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_FINDINGS = 10

VALID_STATUS = {"proposed", "accepted", "superseded", "deprecated"}
IN_FORCE_STATUS = {"proposed", "accepted"}
LIST_FIELDS = ("supersedes", "superseded-by")
REQUIRED_FIELDS = ("status", "date", "supersedes", "superseded-by", "touches")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ADR_ID_RE = re.compile(r"^ADR-\d+$")
FILENAME_RE = re.compile(r"^ADR-(\d+)-.+\.md$")
TITLE_RE = re.compile(r"^# ADR-(\d+):\s+\S")
GLOB_CHARS_RE = re.compile(r"[*?\[]")
EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
CORE_SECTIONS = [
    "## Decision",  # may be "## Decision (one sentence)"
    "## Context",
    "## Alternatives considered",
    "## Consequences",
    "## See also",
]

try:
    import yaml  # type: ignore

    _HAVE_YAML = True
except Exception:  # pragma: no cover - environment dependent
    yaml = None  # type: ignore
    _HAVE_YAML = False


class FrontmatterError(Exception):
    """Frontmatter block is absent or structurally unparseable."""


def split_frontmatter(text: str) -> tuple[str, str]:
    """Return (frontmatter_text, body_text). Raises FrontmatterError if absent."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise FrontmatterError("no opening '---' frontmatter fence")
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1 :])
    raise FrontmatterError("no closing '---' frontmatter fence")


def parse_frontmatter(fm_text: str) -> dict:
    """Parse the frontmatter block to a dict. PyYAML if present, else minimal."""
    _yaml = yaml  # local alias narrows cleanly (module global won't)
    if _yaml is not None:
        try:
            data = _yaml.safe_load(fm_text)
        except Exception as exc:  # malformed YAML
            raise FrontmatterError(f"YAML parse error: {exc}") from exc
        if data is None:
            return {}
        if not isinstance(data, dict):
            raise FrontmatterError("frontmatter is not a mapping")
        return data
    return _minimal_parse(fm_text)


def _minimal_parse(fm_text: str) -> dict:
    """Tiny frontmatter parser for `key: scalar` and `key: [a, b]` / block lists."""
    out: dict = {}
    lines = fm_text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        m = re.match(r"^(\S[^:]*):\s*(.*)$", raw)
        if not m:
            i += 1
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        if val == "":
            # Possible block list: subsequent "  - item" lines.
            items = []
            j = i + 1
            while j < len(lines) and re.match(r"^\s*-\s+", lines[j]):
                item = re.sub(r"^\s*-\s+", "", lines[j]).strip()
                item = item.strip("\"'")
                items.append(item)
                j += 1
            if items:
                out[key] = items
                i = j
                continue
            out[key] = ""
            i += 1
            continue
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            out[key] = (
                [x.strip().strip("\"'") for x in inner.split(",") if x.strip()]
                if inner
                else []
            )
        else:
            out[key] = val.strip("\"'")
        i += 1
    return out


def as_list(value) -> list | None:
    """Return value as a list, or None if it is not list-typed."""
    if isinstance(value, list):
        return value
    return None


def is_literal_path(entry: str) -> bool:
    """True if a touches: entry is a literal filesystem path we can check on disk.

    A literal path contains a '/' or a file extension; is NOT a glob (no * ? [);
    and is NOT a config-key (no `file:key` colon segment — but a Windows drive
    letter `C:` at position 1 doesn't count as a marker).
    """
    s = entry.strip()
    if not s:
        return False
    if GLOB_CHARS_RE.search(s):
        return False
    if s.find(":") > 1:  # config-key marker (drive letters live at index 1)
        return False
    return ("/" in s) or bool(EXT_RE.search(s))


def find_title(body: str):
    """Return (line_number_in_body, match) for the first ADR title, or (None, None)."""
    for idx, line in enumerate(body.splitlines()):
        m = TITLE_RE.match(line.strip())
        if m:
            return idx, m
    return None, None


def section_sequence(body: str) -> list[str]:
    """Ordered list of the core `## ` headings that appear (normalised)."""
    seen = []
    for line in body.splitlines():
        s = line.strip()
        if not s.startswith("## "):
            continue
        for canon in CORE_SECTIONS:
            if s == canon or s.startswith(canon + " "):
                seen.append(canon)
                break
    return seen


def lint_dir(adr_dir: Path, repo_root: Path | None = None) -> tuple[list[dict], bool]:
    """Return (findings, any_unparseable)."""
    findings: list[dict] = []
    any_unparseable = False

    files = sorted(
        p for p in adr_dir.glob("ADR-*.md") if FILENAME_RE.match(p.name)
    )

    # number -> list of filenames (duplicate detection)
    by_number: dict[str, list[str]] = {}
    # adr-id -> parsed record (for supersession cross-check)
    records: dict[str, dict] = {}

    def add(file: str, severity: str, message: str) -> None:
        findings.append({"file": file, "severity": severity, "message": message})

    for path in files:
        name = path.name
        fn_match = FILENAME_RE.match(name)
        if fn_match is None:
            continue  # files are pre-filtered to ADR-NNN-*.md; defensive guard
        fm_num = fn_match.group(1)
        adr_id = f"ADR-{fm_num}"
        by_number.setdefault(fm_num, []).append(name)

        try:
            text = path.read_text(encoding="utf-8")
        except Exception as exc:
            add(name, "error", f"could not read file: {exc}")
            any_unparseable = True
            continue

        try:
            fm_text, body = split_frontmatter(text)
            fm = parse_frontmatter(fm_text)
        except FrontmatterError as exc:
            add(name, "error", f"unparseable frontmatter: {exc}")
            any_unparseable = True
            continue

        records[adr_id] = {"file": name, "fm": fm, "number": fm_num}

        # ── required frontmatter present + typed ──
        for field in REQUIRED_FIELDS:
            if field not in fm:
                add(name, "error", f"missing required frontmatter field: {field}")

        status = fm.get("status")
        if status is not None and status not in VALID_STATUS:
            add(
                name,
                "error",
                f"status '{status}' not in {sorted(VALID_STATUS)}",
            )

        date = fm.get("date")
        if date is not None and not DATE_RE.match(str(date)):
            add(name, "error", f"date '{date}' is not YYYY-MM-DD")

        for field in LIST_FIELDS:
            if field in fm and as_list(fm[field]) is None:
                add(name, "error", f"{field} must be a YAML list (got {type(fm[field]).__name__})")

        if "touches" in fm and as_list(fm["touches"]) is None:
            add(name, "warning", "touches should be a YAML list of paths/globs/keys")

        # ── title line + filename agreement ──
        t_idx, t_match = find_title(body)
        if t_match is None:
            add(name, "error", "missing '# ADR-NNN: Title' line after frontmatter")
        else:
            title_num = t_match.group(1)
            if title_num != fm_num:
                add(
                    name,
                    "error",
                    f"title number ADR-{title_num} != filename number ADR-{fm_num}",
                )

        # ── BLUF: '## Decision (one sentence)' right after the title ──
        if t_match is not None and t_idx is not None:
            body_lines = body.splitlines()
            nxt = None
            for line in body_lines[t_idx + 1 :]:
                if line.strip():
                    nxt = line.strip()
                    break
            if nxt != "## Decision (one sentence)":
                add(
                    name,
                    "error",
                    "first section after title must be '## Decision (one sentence)' (BLUF)",
                )

        # ── core section order ──
        seq = section_sequence(body)
        present = [s for s in CORE_SECTIONS if s in seq]
        # Filter the observed sequence down to core headings only, dedup-first-occurrence.
        observed = []
        for s in seq:
            if s in present and s not in observed:
                observed.append(s)
        expected_order = [s for s in CORE_SECTIONS if s in observed]
        if observed != expected_order:
            add(
                name,
                "error",
                f"core sections out of order: {observed} (expected {expected_order})",
            )

        # ── lifecycle consistency (status vs superseded-by) ──
        # Complements the bidirectionality cross-check below: these are local,
        # single-record contradictions and never double-report with it.
        superseded_by_here = as_list(fm.get("superseded-by")) or []
        has_successor = len(superseded_by_here) > 0
        if status == "superseded" and not has_successor:
            add(
                name,
                "error",
                "status is 'superseded' but superseded-by is empty "
                "(a superseded ADR must name its successor in superseded-by)",
            )
        elif status == "deprecated" and has_successor:
            add(
                name,
                "error",
                "status is 'deprecated' but superseded-by is non-empty "
                "(deprecated means nothing replaces it; if something does, use 'superseded')",
            )
        elif status in IN_FORCE_STATUS and has_successor:
            add(
                name,
                "error",
                f"status is '{status}' (in force) but superseded-by is non-empty "
                "(an in-force ADR cannot list a superseded-by)",
            )

        # ── stale touches: a literal path that no longer exists (warning) ──
        if repo_root is not None:
            touches_here = as_list(fm.get("touches")) or []
            for entry in touches_here:
                if not isinstance(entry, str) or not is_literal_path(entry):
                    continue
                target = (repo_root / entry).resolve()
                if not target.exists():
                    add(
                        name,
                        "warning",
                        f"touches path no longer exists: {entry} "
                        "(discovery surface may be stale)",
                    )

    # ── duplicate numbers (error) / gaps (warning) ──
    for num, names in sorted(by_number.items()):
        if len(names) > 1:
            for n in names:
                add(n, "error", f"duplicate ADR number {num} (also: {[x for x in names if x != n]})")
    if by_number:
        nums = sorted(int(n) for n in by_number)
        full = set(range(min(nums), max(nums) + 1))
        missing = sorted(full - set(nums))
        for gap in missing:
            add(
                f"ADR-{gap:03d}",
                "warning",
                f"number {gap:03d} is missing — a gap in the sequence (numbers are normally contiguous)",
            )

    # ── supersession bidirectionality (the high-value cross-file check) ──
    for adr_id, rec in records.items():
        fm = rec["fm"]
        name = rec["file"]
        supersedes = as_list(fm.get("supersedes")) or []
        for target in supersedes:
            if not isinstance(target, str) or not ADR_ID_RE.match(target):
                add(name, "error", f"supersedes entry '{target}' is not a valid ADR-NNN id")
                continue
            other = records.get(target)
            if other is None:
                add(name, "error", f"supersedes {target}, but no such record exists")
                continue
            o_fm = other["fm"]
            o_by = as_list(o_fm.get("superseded-by")) or []
            if adr_id not in o_by:
                add(
                    other["file"],
                    "error",
                    f"{target} is superseded by {adr_id} but its superseded-by does not list {adr_id}",
                )
            if o_fm.get("status") != "superseded":
                add(
                    other["file"],
                    "error",
                    f"{target} is superseded by {adr_id} but its status is '{o_fm.get('status')}', not 'superseded'",
                )

        superseded_by = as_list(fm.get("superseded-by")) or []
        for target in superseded_by:
            if not isinstance(target, str) or not ADR_ID_RE.match(target):
                add(name, "error", f"superseded-by entry '{target}' is not a valid ADR-NNN id")
                continue
            other = records.get(target)
            if other is None:
                add(name, "error", f"superseded-by {target}, but no such record exists")
                continue
            o_sup = as_list(other["fm"].get("supersedes")) or []
            if adr_id not in o_sup:
                add(
                    other["file"],
                    "error",
                    f"{target} claims to supersede nothing back to {adr_id} (its supersedes omits {adr_id})",
                )

    return findings, any_unparseable


def resolve_repo_root(explicit: str | None) -> Path | None:
    """Resolve the repo root for touches-path checks.

    Explicit --repo-root wins (must be a directory). Otherwise try `git
    rev-parse --show-toplevel`; fall back to cwd. Returns None only if an
    explicit path was given but is not a directory (caller treats as usage).
    """
    if explicit is not None:
        p = Path(explicit)
        return p if p.is_dir() else None
    import subprocess  # local: only needed when no explicit root

    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="adr-lint.py",
        description="Conformance linter for Architecture Decision Records.",
        add_help=True,
    )
    parser.add_argument("--dir", default="docs/adr", help="ADR directory (default: docs/adr)")
    parser.add_argument(
        "--repo-root",
        default=None,
        help="repo root for resolving literal touches: paths "
        "(default: git toplevel if in a git repo, else cwd)",
    )
    parser.add_argument(
        "--strict", action="store_true", help="count warnings toward the exit-10 signal"
    )
    parser.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        # argparse exits 2 on usage error already; normalise non-zero to EX_USAGE.
        return EX_USAGE if exc.code not in (0, None) else (exc.code or EX_OK)

    if not _HAVE_YAML:
        print("note: PyYAML not found — using built-in minimal frontmatter parser.", file=sys.stderr)

    adr_dir = Path(args.dir)
    if not adr_dir.is_dir():
        print(f"error: ADR directory not found: {adr_dir}", file=sys.stderr)
        return EX_NOTFOUND

    repo_root = resolve_repo_root(args.repo_root)
    if args.repo_root is not None and repo_root is None:
        print(f"error: --repo-root is not a directory: {args.repo_root}", file=sys.stderr)
        return EX_USAGE

    findings, any_unparseable = lint_dir(adr_dir, repo_root)

    errors = [f for f in findings if f["severity"] == "error"]
    warnings = [f for f in findings if f["severity"] == "warning"]

    if args.json:
        envelope = {
            "data": findings,
            "meta": {
                "count": len(findings),
                "errors": len(errors),
                "warnings": len(warnings),
                "dir": str(adr_dir),
                "schema": "claude-mods.adr-ops.lint/v1",
            },
        }
        print(json.dumps(envelope, indent=2))
    else:
        tout = Term(sys.stdout)
        terr = Term(sys.stderr)
        for f in findings:
            sev = f["severity"]
            if tout.color:
                state = "bad" if sev == "error" else "warn"
                col = "red" if sev == "error" else "orange"
                print(f"{tout.mark(state)} {tout.c(col, f'{sev.upper():7}')} {f['file']}: {f['message']}")
            else:
                # Plain stream stays byte-identical to the legacy data format.
                print(f"{sev.upper():7} {f['file']}: {f['message']}")
        print(
            f"--- {terr.c('red', str(len(errors)))} error(s), "
            f"{terr.c('orange', str(len(warnings)))} warning(s) across {args.dir}",
            file=sys.stderr,
        )

    if any_unparseable:
        return EX_UNPARSEABLE
    if errors or (args.strict and warnings):
        return EX_FINDINGS
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
