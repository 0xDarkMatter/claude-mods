#!/usr/bin/env python3
"""Scan files or stdin for hidden / direction-altering Unicode used in prompt injection.

Usage: scan-hidden-unicode.py [OPTIONS] [PATH ...]

Input:   file/dir paths as argv, or content on stdin with --stdin
Output:  stdout = findings (TSV by default, JSON envelope with --json)
Stderr:  human-readable progress, per-file summary, errors
Exit:    0 clean, 2 usage, 3 not-found, 4 validation, 5 missing-catalog,
         10 INDICATOR_FOUND (dangerous codepoints present)

Examples:
  scan-hidden-unicode.py CLAUDE.md AGENTS.md
  scan-hidden-unicode.py --json . | jq '.data[]'
  rg -l . | scan-hidden-unicode.py -            # scan a file list (paths on argv)
  cat suspicious.md | scan-hidden-unicode.py --stdin
  scan-hidden-unicode.py --strict docs/         # also flag medium/low + homoglyphs
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

# Windows console is cp1252 by default; force UTF-8 so U+XXXX names never crash --help.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_PRECONDITION = 5
EXIT_INDICATOR = 10  # tool-specific: dangerous codepoints found

SEVERITY_ORDER = {"benign": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

# Files always scanned when walking a directory, regardless of --include globs.
INSTRUCTION_NAMES = {
    "CLAUDE.md", "AGENTS.md", "GEMINI.md", "COPILOT.md", "CURSOR.md", "WARP.md",
    ".cursorrules", ".windsurfrules", ".clinerules", "SKILL.md",
}
DEFAULT_INCLUDE = ["*.md", "*.mdc", "*.txt", "*.json"]
DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "assets" / "dangerous-codepoints.json"

# Scripts treated as a confusable risk when mixed within one token (--strict only).
CONFUSABLE_SCRIPTS = ("LATIN", "CYRILLIC", "GREEK", "ARMENIAN")


def log(level: str, msg: str, quiet: bool = False) -> None:
    if quiet and level == "INFO":
        return
    print(f"[{level}] {msg}", file=sys.stderr)


def die(message: str, code: str, exit_code: int, as_json: bool, details: dict | None = None):
    if as_json:
        obj = {"error": {"code": code, "message": message}}
        if details:
            obj["error"]["details"] = details
        print(json.dumps(obj))
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(exit_code)


def parse_cp(token: str) -> int:
    """'U+202E' / '202E' -> int."""
    return int(token.replace("U+", "").replace("u+", ""), 16)


def load_catalog(path: Path, as_json: bool) -> list[dict]:
    if not path.exists():
        die(f"codepoint catalog not found: {path}", "MISSING_DEPENDENCY", EXIT_PRECONDITION,
            as_json, details={"expected": str(path)})
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        die(f"catalog unreadable: {e}", "VALIDATION_ERROR", EXIT_VALIDATION, as_json)
    bands = []
    for b in raw.get("bands", []):
        try:
            bands.append({
                "id": b["id"],
                "name": b["name"],
                "start": parse_cp(b["start"]),
                "end": parse_cp(b["end"]),
                "severity": b["severity"],
                "strip_level": b.get("strip_level", "standard"),
            })
        except (KeyError, ValueError) as e:
            die(f"malformed band in catalog: {e}", "VALIDATION_ERROR", EXIT_VALIDATION, as_json)
    # Sort so smaller/more-specific bands match before the broad PUA ranges.
    bands.sort(key=lambda x: (x["end"] - x["start"], x["start"]))
    return bands


def classify(cp: int, bands: list[dict]) -> dict | None:
    for b in bands:
        if b["start"] <= cp <= b["end"]:
            return b
    return None


def script_of(ch: str) -> str | None:
    """Heuristic script family from the Unicode name prefix (LATIN/CYRILLIC/GREEK...)."""
    if not ch.isalpha():
        return None
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return None
    return name.split(" ", 1)[0]


def find_mixed_script_tokens(text: str, lineno: int) -> list[dict]:
    """--strict heuristic: a single word mixing confusable scripts (e.g. Latin + Cyrillic 'аdmin')."""
    findings = []
    col = 0
    token = ""
    token_col = 0
    scripts: set[str] = set()

    def flush():
        nonlocal token, scripts
        confusable = {s for s in scripts if s in CONFUSABLE_SCRIPTS}
        if len(confusable) >= 2 and len(token) >= 2:
            findings.append({
                "type": "mixed-script",
                "line": lineno, "col": token_col + 1,
                "codepoint": "", "char_name": "",
                "band": "homoglyph", "severity": "high",
                "context": f"token '{token}' mixes scripts: {'+'.join(sorted(confusable))}",
            })
        token = ""
        scripts = set()

    for ch in text:
        col += 1
        s = script_of(ch)
        if ch.isalpha() and s:
            if not token:
                token_col = col - 1
            token += ch
            scripts.add(s)
        else:
            flush()
    flush()
    return findings


def scan_text(text: str, bands: list[dict], strict: bool, whitelist: bool) -> list[dict]:
    findings: list[dict] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for col, ch in enumerate(line, start=1):
            cp = ord(ch)
            if cp < 0x80:
                continue
            band = classify(cp, bands)
            if band is None:
                continue
            sev = band["severity"]
            # Emoji whitelist: VS16 + ZWJ are load-bearing in emoji; never flag unless asked.
            if whitelist and sev == "benign":
                continue
            # BOM is legitimate only at absolute file start (line 1 col 1).
            if band["id"] == "bom-zwnbsp" and lineno == 1 and col == 1:
                continue
            # Default fails on critical+high; --strict adds medium+low+benign.
            min_sev = "benign" if strict else "high"
            if SEVERITY_ORDER[sev] < SEVERITY_ORDER[min_sev]:
                continue
            try:
                cname = unicodedata.name(ch)
            except ValueError:
                cname = "<unnamed>"
            findings.append({
                "type": "codepoint",
                "line": lineno, "col": col,
                "codepoint": f"U+{cp:04X}", "char_name": cname,
                "band": band["id"], "severity": sev,
                "context": band["name"],
            })
        if strict:
            findings.extend(find_mixed_script_tokens(line, lineno))
    return findings


def iter_target_files(paths: list[str], includes: list[str]) -> list[Path]:
    out: list[Path] = []
    seen: set[Path] = set()

    def add(p: Path):
        rp = p.resolve()
        if rp not in seen and rp.is_file():
            seen.add(rp)
            out.append(p)

    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if not f.is_file():
                    continue
                if f.name in INSTRUCTION_NAMES or any(f.match(g) for g in includes):
                    add(f)
        else:
            add(p)  # explicit file: scan regardless of extension
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="scan-hidden-unicode.py", add_help=False,
        description="Scan files or stdin for hidden / direction-altering Unicode (prompt injection).")
    ap.add_argument("paths", nargs="*", help="files or directories to scan")
    ap.add_argument("--stdin", action="store_true", help="read content from stdin instead of paths")
    ap.add_argument("--strict", action="store_true",
                    help="also flag medium/low bands + mixed-script homoglyph tokens")
    ap.add_argument("--no-emoji-whitelist", action="store_true",
                    help="flag VS16/ZWJ too (noisy: hits every emoji)")
    ap.add_argument("--include", action="append", metavar="GLOB",
                    help=f"filename glob when walking dirs (repeatable; default {DEFAULT_INCLUDE})")
    ap.add_argument("--catalog", metavar="PATH", help="override codepoint catalog path")
    ap.add_argument("--json", action="store_true", help="machine-readable output to stdout")
    ap.add_argument("-q", "--quiet", action="store_true", help="suppress INFO stderr")
    ap.add_argument("-h", "--help", action="store_true", help="show this help and exit")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return EXIT_OK

    as_json = args.json
    includes = args.include or DEFAULT_INCLUDE
    catalog_path = Path(args.catalog) if args.catalog else DEFAULT_CATALOG
    bands = load_catalog(catalog_path, as_json)
    whitelist = not args.no_emoji_whitelist

    all_findings: list[dict] = []
    scanned = 0

    if args.stdin:
        data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        scanned = 1
        for f in scan_text(data, bands, args.strict, whitelist):
            f["file"] = "<stdin>"
            all_findings.append(f)
    else:
        if not args.paths:
            die("no paths given (and --stdin not set)", "USAGE", EXIT_USAGE, as_json)
        targets = iter_target_files(args.paths, includes)
        missing = [p for p in args.paths if not Path(p).exists()]
        if missing and not targets:
            die(f"path not found: {missing[0]}", "NOT_FOUND", EXIT_NOT_FOUND, as_json,
                details={"missing": missing})
        for path in targets:
            try:
                data = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                log("WARN", f"skip non-UTF-8 file: {path}", args.quiet)
                continue
            except OSError as e:
                log("WARN", f"skip unreadable file: {path} ({e})", args.quiet)
                continue
            scanned += 1
            for f in scan_text(data, bands, args.strict, whitelist):
                f["file"] = str(path)
                all_findings.append(f)

    # ---- output ------------------------------------------------------------
    worst = max((SEVERITY_ORDER[f["severity"]] for f in all_findings), default=0)
    failed = bool(all_findings)

    if as_json:
        print(json.dumps({
            "data": all_findings,
            "meta": {
                "count": len(all_findings),
                "files_scanned": scanned,
                "strict": args.strict,
                "worst_severity": next((k for k, v in SEVERITY_ORDER.items() if v == worst), "benign"),
                "schema": "claude-mods.prompt-injection.scan/v1",
            },
        }))
    else:
        for f in all_findings:
            # TSV: file  line  col  codepoint  severity  band  context
            print(f"{f['file']}\t{f['line']}\t{f['col']}\t{f['codepoint']}\t"
                  f"{f['severity']}\t{f['band']}\t{f['context']}")

    if failed:
        log("ERROR",
            f"{len(all_findings)} hidden-unicode finding(s) across {scanned} file(s); "
            f"worst severity = {next((k for k,v in SEVERITY_ORDER.items() if v==worst),'?')}", args.quiet)
        return EXIT_INDICATOR
    log("INFO", f"clean: no hidden-unicode indicators in {scanned} file(s)", args.quiet)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
