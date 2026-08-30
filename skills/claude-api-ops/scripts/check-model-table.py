#!/usr/bin/env python3
"""Staleness verifier for the claude-api-ops model + cache-minimum tables.

Guards the two fast-moving fact tables in this skill against silent drift:
  - the "Current Models" table in SKILL.md (ids, pricing, context, output)
  - the per-model prompt-cache minimum table in references/caching-and-cost.md

Two modes (protocol SKILL-RESOURCE-PROTOCOL.md §7):
  --offline (default): parse both tables, assert internal consistency. No network.
                       Exit 4 (VALIDATION) on a malformed/contradictory row.
  --live:              curl the Anthropic Models API and compare its model-id set
                       against the documented ids. Advisory only.

Live-mode scope limit: the Models API returns model IDs but NOT pricing, context,
or output limits. --live therefore verifies model-ID existence/coverage ONLY:
  - a documented id absent from the live list  -> DRIFT (retired/typo)
  - a live id newer than anything documented    -> DRIFT (table lacks a new model)
Pricing/context/output drift is out of scope for --live (the API can't confirm it);
--offline guards their well-formedness, and the SKILL.md "Live Documentation" links
remain the human cross-check for pricing.

Usage:   check-model-table.py [--offline | --live] [--json] [--skill-dir DIR] [-q]
Input:   reads SKILL.md and references/caching-and-cost.md (resolved relative to
         this script, or --skill-dir)
Output:  stdout = data only (JSON envelope under --json, else a plain summary)
Stderr:  headers, progress, notes, errors
Exit:    0 ok/consistent, 2 usage, 3 not-found, 4 validation (malformed/contradictory),
         5 missing-dep (curl, --live only), 7 unavailable (no key / API unreachable),
         10 drift (live id-set disagrees with the table)

Examples:
  check-model-table.py --offline
  check-model-table.py --offline --json | python -m json.tool
  ANTHROPIC_API_KEY=sk-... check-model-table.py --live
  check-model-table.py --live   # exits 7 (advisory) when the key is unset
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

# Windows consoles default to cp1252; force UTF-8 so em-dashes/§ in notes don't
# raise UnicodeEncodeError or print mojibake (matches the repo's standard fix).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass

class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (term.sh is bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline with matching keys/glyphs).
    Honors FORCE_COLOR / NO_COLOR / TERM_ASCII; color tracks the bound stream's TTY,
    and glyphs fall back to ASCII on TERM_ASCII or a non-UTF stream encoding."""

    _C = {"green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
          "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (os.environ.get("TERM_ASCII") == "1"
                      or os.environ.get("FLEET_ASCII") == "1" or "utf" not in enc)
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, state):
        return self.c(self._MARK_COLOR.get(state, ""),
                      (self._ASCII if self.ascii else self._GLYPH).get(state, "."))

    def hdr(self, text):
        return self.c("cyan", f"=== {text} ===")


TERM = Term(sys.stderr)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_MISSING_DEP = 5
EXIT_UNAVAILABLE = 7
EXIT_DRIFT = 10

SCHEMA = "claude-mods.claude-api-ops.model-table/v1"
MODELS_API = "https://api.anthropic.com/v1/models?limit=1000"
ANTHROPIC_VERSION = "2023-06-01"

# --- Cache-economics constants (offline cross-file tripwire) -----------------
# These numbers are stated in more than one file, so a future edit can desync
# them silently. This table is the single source of truth: each entry names the
# canonical value, a regex that must match in EVERY listed file, and why.
# Changing a real-world value means changing it here AND in every listed file --
# that is the point: a one-file edit trips this check instead of rotting.
#
# Deliberately offline-only. A --live parse of the docs page would be brittle
# (prose/format churn -> spurious exit 10), and SKILL-RESOURCE-PROTOCOL.md §7 is
# explicit that a gate which cries wolf is a gate everyone learns to ignore.
# The human cross-check stays the "Live Documentation" link in SKILL.md.
CACHE_CONSTANTS = [
    {
        "key": "cache_read_multiplier",
        "value": "0.1x base input",
        "pattern": r"0\.1\s*[x×]",
        "files": ["SKILL.md", "references/caching-and-cost.md",
                  "references/context-engineering.md", "references/compaction.md"],
    },
    {
        "key": "cache_write_5m_multiplier",
        "value": "1.25x base input",
        "pattern": r"1\.25\s*[x×]",
        "files": ["references/caching-and-cost.md", "references/compaction.md"],
    },
    {
        "key": "cache_write_1h_multiplier",
        "value": "2x base input",
        # Anchored to the TTL in either order so a bare "2x" elsewhere can't
        # satisfy it. Note "2×" (U+00D7) has no trailing \b -- don't add one.
        "pattern": (r"(?<![\d.])2\s*[x×][^\n]{0,40}1-hour"
                    r"|1-hour[^\n]{0,40}(?<![\d.])2\s*[x×]"),
        "files": ["references/caching-and-cost.md", "references/compaction.md"],
    },
    {
        "key": "max_breakpoints",
        "value": "4 cache_control breakpoints per request",
        "pattern": r"\*\*4\*\*\s*`?cache_control`?\s*breakpoints",
        "files": ["references/caching-and-cost.md"],
    },
    {
        "key": "lookback_blocks",
        "value": "20-block backward lookback per breakpoint",
        "pattern": r"\b20\b[^.\n]{0,48}\bblock",
        "files": ["references/caching-and-cost.md",
                  "references/context-engineering.md"],
    },
    {
        "key": "context_management_beta",
        "value": "context-management-2025-06-27 beta header",
        "pattern": r"context-management-2025-06-27",
        "files": ["SKILL.md", "references/compaction.md"],
    },
]

# Docs whose facts were verified on a date must SAY so, so staleness is visible
# to a reader rather than only to this script.
DATE_STAMPED_DOCS = ["references/context-engineering.md", "references/compaction.md"]
DATE_STAMP_RE = re.compile(r"verified[^\n]{0,80}?(\d{4}-\d{2}-\d{2})", re.I)

# A well-formed alias id: claude-<word>-<digit>... and NO date suffix.
# Accepts claude-opus-4-8, claude-fable-5, claude-sonnet-4-6, claude-haiku-4-5.
ID_RE = re.compile(r"^claude-[a-z]+-\d+(?:-\d+)?$")
# A date suffix looks like an 8-digit run (e.g. -20251114).
DATE_SUFFIX_RE = re.compile(r"-\d{8}$")


def note(msg: str, quiet: bool) -> None:
    if not quiet:
        print(msg, file=sys.stderr)


def fail_validation(message: str, details: dict, json_mode: bool) -> NoReturn:
    if json_mode:
        print(json.dumps({"error": {"code": "VALIDATION", "message": message,
                                    "details": details}}))
    print(f"{TERM.mark('bad')} ERROR: {message}", file=sys.stderr)
    for k, v in details.items():
        print(f"  {k}: {v}", file=sys.stderr)
    sys.exit(EXIT_VALIDATION)


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def split_row(line: str) -> list[str]:
    """Split a markdown table row into trimmed cells (drops outer pipes)."""
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    return cells


def is_separator(cells: list[str]) -> bool:
    return all(re.fullmatch(r":?-{2,}:?", c or "") for c in cells) and bool(cells)


def parse_model_table(text: str) -> tuple[list[dict], list[str]]:
    """Parse the SKILL.md 'Current Models' table.

    Columns: Model | ID | Context | Max Output | Input $/MTok | Output $/MTok
    Returns one dict per data row.
    """
    lines = text.splitlines()
    # Locate the header row that contains the ID column and a price column.
    start = None
    for i, line in enumerate(lines):
        low = line.lower()
        if line.lstrip().startswith("|") and "id" in low and "context" in low and "output" in low:
            start = i
            break
    if start is None:
        return [], []

    header = split_row(lines[start])
    rows: list[dict] = []
    # Expect a separator row next, then data rows until a non-table line.
    j = start + 1
    if j < len(lines) and is_separator(split_row(lines[j])):
        j += 1
    while j < len(lines):
        line = lines[j]
        if not line.lstrip().startswith("|"):
            break
        cells = split_row(line)
        if is_separator(cells):
            j += 1
            continue
        if len(cells) >= 6:
            rows.append({
                "name": cells[0],
                "id_cell": cells[1],
                "context": cells[2],
                "max_output": cells[3],
                "input_price": cells[4],
                "output_price": cells[5],
            })
        j += 1
    return rows, header


def parse_cache_min_table(text: str) -> list[dict]:
    """Parse the caching-and-cost.md 'Minimum prefix tokens' table.

    Columns: Model | Minimum prefix tokens. The Model cell holds friendly names
    (possibly several comma-separated), not ids.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        low = line.lower()
        if line.lstrip().startswith("|") and "model" in low and "minimum" in low and "prefix" in low:
            start = i
            break
    if start is None:
        return []
    rows: list[dict] = []
    j = start + 1
    if j < len(lines) and is_separator(split_row(lines[j])):
        j += 1
    while j < len(lines):
        line = lines[j]
        if not line.lstrip().startswith("|"):
            break
        cells = split_row(line)
        if is_separator(cells):
            j += 1
            continue
        if len(cells) >= 2:
            rows.append({"names": cells[0], "min_tokens": cells[1]})
        j += 1
    return rows


# ---------------------------------------------------------------------------
# Offline validation
# ---------------------------------------------------------------------------

PRICE_RE = re.compile(r"^\$\d+(?:\.\d+)?$")
SIZE_RE = re.compile(r"^\d+(?:\.\d+)?[KM]$")


def clean_id(id_cell: str) -> str:
    """Strip backtick code fences from an ID cell."""
    return id_cell.strip().strip("`").strip()


def validate_cache_constants(skill_dir: Path, json_mode: bool, quiet: bool) -> list[dict]:
    """Assert every file that states a cache-economics constant states the same one.

    Presence-based on purpose: if an edit changes 0.1x to 0.15x in one file, that
    file stops matching and this trips. Returns one result row per constant.
    """
    rows: list[dict] = []
    for const in CACHE_CONSTANTS:
        rx = re.compile(const["pattern"])
        missing: list[str] = []
        for rel in const["files"]:
            path = skill_dir / rel
            if not path.is_file():
                fail_validation("file referenced by a cache constant is missing",
                                {"constant": const["key"], "file": rel}, json_mode)
            if not rx.search(path.read_text(encoding="utf-8")):
                missing.append(rel)
        if missing:
            fail_validation(
                f"cache constant {const['key']!r} not stated consistently across files",
                {"expected": const["value"],
                 "pattern": const["pattern"],
                 "files_missing_it": ", ".join(missing),
                 "hint": ("either the doc drifted, or the real value changed and "
                          "CACHE_CONSTANTS in this script needs updating too")},
                json_mode)
        rows.append({"key": const["key"], "value": const["value"],
                     "files": const["files"], "consistent": True})
    note(f"  {len(rows)} cache constants consistent across files", quiet)
    return rows


def validate_date_stamps(skill_dir: Path, json_mode: bool, quiet: bool) -> list[dict]:
    """Every fact-heavy doctrine reference must carry a 'verified <ISO date>' stamp."""
    rows: list[dict] = []
    for rel in DATE_STAMPED_DOCS:
        path = skill_dir / rel
        if not path.is_file():
            fail_validation("date-stamped doc is missing", {"file": rel}, json_mode)
        m = DATE_STAMP_RE.search(path.read_text(encoding="utf-8"))
        if not m:
            fail_validation(
                "doc encodes fast-moving facts but carries no verification date",
                {"file": rel,
                 "hint": "add a line like 'Facts verified against ... YYYY-MM-DD'"},
                json_mode)
        rows.append({"file": rel, "verified": m.group(1)})
    note(f"  {len(rows)} doctrine docs carry a verification date", quiet)
    return rows


def validate_cited_references(skill_dir: Path, json_mode: bool, quiet: bool) -> list[str]:
    """Every references/*.md on disk must be cited from SKILL.md, and vice versa.

    SKILL-RESOURCE-PROTOCOL.md §1: an uncited reference is dead weight the router
    never finds; a cited-but-absent one is a broken link.
    """
    skill_text = (skill_dir / "SKILL.md").read_text(encoding="utf-8")
    on_disk = sorted(p.name for p in (skill_dir / "references").glob("*.md"))
    cited = set(re.findall(r"\(references/([A-Za-z0-9._-]+\.md)\)", skill_text))

    uncited = [n for n in on_disk if n not in cited]
    ghosts = sorted(n for n in cited if n not in on_disk)
    if uncited or ghosts:
        fail_validation(
            "SKILL.md and references/ disagree",
            {"on_disk_but_uncited": ", ".join(uncited) or "(none)",
             "cited_but_missing": ", ".join(ghosts) or "(none)"},
            json_mode)
    note(f"  {len(on_disk)} reference files, all cited from SKILL.md", quiet)
    return on_disk


def validate_offline(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    skill_md = skill_dir / "SKILL.md"
    cache_md = skill_dir / "references" / "caching-and-cost.md"
    for p in (skill_md, cache_md):
        if not p.is_file():
            if json_mode:
                print(json.dumps({"error": {"code": "NOT_FOUND",
                                            "message": f"missing file: {p}",
                                            "details": {}}}))
            print(f"ERROR: required file not found: {p}", file=sys.stderr)
            sys.exit(EXIT_NOT_FOUND)

    note(TERM.hdr("offline model-table consistency check"), quiet)

    model_rows, _ = parse_model_table(skill_md.read_text(encoding="utf-8"))
    if not model_rows:
        fail_validation("could not locate a non-empty Current Models table in SKILL.md",
                        {"file": str(skill_md)}, json_mode)

    documented_ids: list[str] = []
    models_out: list[dict] = []
    for row in model_rows:
        mid = clean_id(row["id_cell"])
        problems = []
        if not ID_RE.match(mid):
            problems.append("id does not match claude-[a-z]+-<digits>")
        if DATE_SUFFIX_RE.search(mid):
            problems.append("id carries a date suffix (should be a bare alias)")
        if not PRICE_RE.match(row["input_price"]):
            problems.append(f"input price not numeric: {row['input_price']!r}")
        if not PRICE_RE.match(row["output_price"]):
            problems.append(f"output price not numeric: {row['output_price']!r}")
        if not SIZE_RE.match(row["context"]):
            problems.append(f"context not a size (e.g. 1M/200K): {row['context']!r}")
        if not SIZE_RE.match(row["max_output"]):
            problems.append(f"max output not a size: {row['max_output']!r}")
        if problems:
            fail_validation(f"malformed model row: {row['name']!r}",
                            {"id": mid, "problems": "; ".join(problems)}, json_mode)
        documented_ids.append(mid)
        models_out.append({
            "name": row["name"], "id": mid, "context": row["context"],
            "max_output": row["max_output"],
            "input_price": row["input_price"], "output_price": row["output_price"],
        })

    # No duplicate ids.
    dupes = {x for x in documented_ids if documented_ids.count(x) > 1}
    if dupes:
        fail_validation("duplicate model ids in the table",
                        {"ids": ", ".join(sorted(dupes))}, json_mode)

    # Cache-minimum table.
    cache_rows = parse_cache_min_table(cache_md.read_text(encoding="utf-8"))
    if not cache_rows:
        fail_validation("could not locate the cache-minimum table in caching-and-cost.md",
                        {"file": str(cache_md)}, json_mode)
    for crow in cache_rows:
        if not re.fullmatch(r"\d+", crow["min_tokens"]):
            fail_validation("cache-minimum value is not an integer",
                            {"row": crow["names"], "value": crow["min_tokens"]},
                            json_mode)

    # Cross-file consistency: every model NAME (e.g. "Opus 4.8", "Fable 5",
    # "Sonnet 4.6", "Haiku 4.5") in the model table must appear in the cache
    # table's name set, so the two files agree on the model lineup.
    cache_blob = " ".join(c["names"] for c in cache_rows).lower()
    missing_in_cache: list[str] = []
    for m in models_out:
        # Derive the short family+version token, e.g. "Claude Opus 4.8" -> "opus 4.8".
        short = re.sub(r"^claude\s+", "", m["name"], flags=re.I).strip().lower()
        if short not in cache_blob:
            missing_in_cache.append(m["name"])
    if missing_in_cache:
        fail_validation(
            "model(s) in SKILL.md absent from the cache-minimum table — files contradict",
            {"missing": ", ".join(missing_in_cache),
             "hint": "every documented model needs a prompt-cache minimum row"},
            json_mode)

    note(f"  {len(models_out)} model rows, all well-formed", quiet)
    note(f"  {len(cache_rows)} cache-minimum rows, all integer", quiet)
    note("  cross-file model lineup consistent", quiet)

    # Context-engineering layer: constants stated in several files, verification
    # date stamps, and SKILL.md <-> references/ citation integrity.
    constants = validate_cache_constants(skill_dir, json_mode, quiet)
    stamps = validate_date_stamps(skill_dir, json_mode, quiet)
    refs = validate_cited_references(skill_dir, json_mode, quiet)

    note(f"{TERM.mark('ok')} OK: tables internally consistent.", quiet)

    return {
        "mode": "offline",
        "models": models_out,
        "documented_ids": documented_ids,
        "cache_min_rows": cache_rows,
        "cache_constants": constants,
        "date_stamps": stamps,
        "reference_files": refs,
        "consistent": True,
    }


# ---------------------------------------------------------------------------
# Live validation
# ---------------------------------------------------------------------------

def fetch_live_ids(quiet: bool) -> list[str] | None:
    """Return the live model-id list, or None if unavailable (advisory)."""
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key:
        note("NOTE: ANTHROPIC_API_KEY is unset - skipping live check (advisory).",
             quiet)
        return None
    cmd = [
        "curl", "-fsS", "--max-time", "20",
        "-H", f"x-api-key: {key}",
        "-H", f"anthropic-version: {ANTHROPIC_VERSION}",
        MODELS_API,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as exc:
        note(f"NOTE: Models API call failed ({exc}) — advisory, not a failure.",
             quiet)
        return None
    if proc.returncode != 0:
        note(f"NOTE: Models API unreachable (curl exit {proc.returncode}) — advisory.",
             quiet)
        if proc.stderr.strip():
            note(f"  {proc.stderr.strip().splitlines()[-1]}", quiet)
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        note("NOTE: Models API returned non-JSON — advisory, not a failure.", quiet)
        return None
    data = payload.get("data")
    if not isinstance(data, list):
        note("NOTE: Models API JSON missing 'data' list — advisory.", quiet)
        return None
    return [m.get("id", "") for m in data if isinstance(m, dict) and m.get("id")]


def validate_live(skill_dir: Path, json_mode: bool, quiet: bool) -> dict:
    if not _have("curl"):
        if json_mode:
            print(json.dumps({"error": {"code": "PRECONDITION",
                                         "message": "curl required for --live",
                                         "details": {}}}))
        print("ERROR: curl is required for --live", file=sys.stderr)
        sys.exit(EXIT_MISSING_DEP)

    # Reuse offline parse for the documented id set (also validates well-formedness).
    note(TERM.hdr("live model-id coverage check"), quiet)
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        print(f"ERROR: required file not found: {skill_md}", file=sys.stderr)
        sys.exit(EXIT_NOT_FOUND)
    parsed = parse_model_table(skill_md.read_text(encoding="utf-8"))
    if not parsed or not parsed[0]:
        fail_validation("could not parse the model table for live comparison",
                        {"file": str(skill_md)}, json_mode)
    documented = [clean_id(r["id_cell"]) for r in parsed[0]]

    live = fetch_live_ids(quiet)
    if live is None:
        # Advisory: not a failure. Exit 7.
        if json_mode:
            print(json.dumps({"data": {"mode": "live", "status": "unavailable",
                                       "documented_ids": documented, "live_ids": None},
                              "meta": {"schema": SCHEMA, "status": "unavailable"}}))
        sys.exit(EXIT_UNAVAILABLE)

    live_set = set(live)
    doc_set = set(documented)

    # A documented id absent from the live list = drift (retired/typo).
    missing = sorted(doc_set - live_set)
    # A live id NEWER than anything documented = drift (table lacks a new model).
    # Restrict "newer" to well-formed alias ids so we ignore date-suffixed and
    # snapshot variants the docs intentionally don't list.
    live_alias = {m for m in live_set if ID_RE.match(m) and not DATE_SUFFIX_RE.search(m)}
    new_models = sorted(live_alias - doc_set)

    drift = bool(missing or new_models)
    result = {
        "mode": "live",
        "status": "drift" if drift else "ok",
        "documented_ids": documented,
        "live_ids": sorted(live_set),
        "missing_from_live": missing,
        "new_in_live": new_models,
    }

    if drift:
        if missing:
            note(f"{TERM.mark('bad')} {TERM.c('red', 'DRIFT: documented id(s) absent from live Models API:')}", quiet)
            for m in missing:
                note(f"  {TERM.c('red', '-')} {m}", quiet)
        if new_models:
            note(f"{TERM.mark('bad')} {TERM.c('red', 'DRIFT: live Models API has alias id(s) the table lacks:')}", quiet)
            for m in new_models:
                note(f"  {TERM.c('green', '+')} {m}", quiet)
        if json_mode:
            print(json.dumps({"data": result, "meta": {"schema": SCHEMA,
                                                        "status": "drift"}}))
        else:
            print("DRIFT: model-id table disagrees with the live Models API "
                  f"(missing={missing}, new={new_models})")
        sys.exit(EXIT_DRIFT)

    note("OK: every documented id exists live; no newer alias id missing from the table.",
         quiet)
    return result


def _have(tool: str) -> bool:
    from shutil import which
    return which(tool) is not None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-model-table.py", add_help=True,
        description="Staleness verifier for the claude-api-ops model + cache tables.",
        epilog=(
            "EXAMPLES:\n"
            "  check-model-table.py --offline\n"
            "  check-model-table.py --offline --json | python -m json.tool\n"
            "  ANTHROPIC_API_KEY=sk-... check-model-table.py --live\n"
            "  check-model-table.py --live   # exits 7 (advisory) when key unset\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true",
                      help="parse + assert internal consistency, no network (default)")
    mode.add_argument("--live", action="store_true",
                      help="compare documented ids against the live Models API (advisory)")
    parser.add_argument("--json", action="store_true",
                        help="emit the JSON envelope on stdout")
    parser.add_argument("--skill-dir", default=None,
                        help="skill root (default: parent of this script's dir)")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="suppress stderr progress/notes")
    args = parser.parse_args(argv)

    if args.skill_dir:
        skill_dir = Path(args.skill_dir).resolve()
    else:
        skill_dir = Path(__file__).resolve().parent.parent
    if not skill_dir.is_dir():
        print(f"ERROR: skill dir not found: {skill_dir}", file=sys.stderr)
        return EXIT_NOT_FOUND

    if args.live:
        result = validate_live(skill_dir, args.json, args.quiet)
    else:
        result = validate_offline(skill_dir, args.json, args.quiet)

    if args.json:
        print(json.dumps({"data": result,
                          "meta": {"schema": SCHEMA, "status": "ok"}}))
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(EXIT_USAGE)
