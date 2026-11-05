#!/usr/bin/env python3
"""Scan files or stdin for hidden / direction-altering Unicode used in prompt injection.

Usage: scan-hidden-unicode.py [OPTIONS] [PATH ...]

Input:   file/dir paths as argv, or content on stdin with --stdin
Output:  stdout = findings (TSV by default, JSON envelope with --json)
Stderr:  human-readable progress, per-file summary, errors
Exit:    0 clean - every requested file was read and scanned, nothing found
         2 usage, 4 validation
         3 not-found - a requested path is missing, or a walk matched no files
         5 precondition - catalog missing, or a file could not be read
         10 INDICATOR_FOUND (dangerous codepoints, or a file that is not UTF-8)
         Precedence 10 > 5 > 3; files not scanned are named on stderr (even with
         --quiet) and in meta.unscanned, so a partial run never reads as clean.

A file that is not valid UTF-8 is a FINDING (band non-utf8-encoding, high), not
a skip: the bytes a UTF-8 review sees are not the bytes an encoding-sniffing
loader reads, which is an evasion in itself. It is still decoded (UTF-16/32 by
BOM, else UTF-8 with replacement) and scanned, so its codepoints are named too.

Examples:
  scan-hidden-unicode.py CLAUDE.md AGENTS.md
  scan-hidden-unicode.py --json . | jq '.data[]'
  rg -l . | xargs scan-hidden-unicode.py         # scan a file list
  cat suspicious.md | scan-hidden-unicode.py --stdin
  scan-hidden-unicode.py --strict docs/         # also flag medium/low + homoglyphs
"""
from __future__ import annotations

import argparse
import codecs
import json
import re
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

# Split ONLY on CRLF / CR / LF. Never use str.splitlines(): it also breaks on VT,
# FF, FS-RS, NEL, U+2028 and U+2029 and drops them, so the line-break bands that
# forge structure would never reach classify(), and every later finding's line
# number would drift from what an editor shows.
LINE_BREAK = re.compile(r"\r\n|\r|\n")
LINE_BREAK_BYTES = re.compile(rb"\r\n|\r|\n")

# BOMs of a deliberate non-UTF-8 Unicode encoding. UTF-32 first: the UTF-32-LE BOM
# begins with the UTF-16-LE one.
UNICODE_BOMS = (
    (codecs.BOM_UTF32_LE, "utf-32-le", "UTF-32-LE"),
    (codecs.BOM_UTF32_BE, "utf-32-be", "UTF-32-BE"),
    (codecs.BOM_UTF16_LE, "utf-16-le", "UTF-16-LE"),
    (codecs.BOM_UTF16_BE, "utf-16-be", "UTF-16-BE"),
)

# Why not-UTF-8 is a finding rather than "could not scan": the scanner did run and
# learned something true about the content. Instruction files are UTF-8, and one
# that isn't shows a UTF-8 review (and every UTF-8-only check) different bytes than
# a BOM-sniffing loader reads - that gap is the evasion this tool exists to close.
# High, not critical: legacy Latin-1 or Notepad UTF-16 files are legitimate too,
# so it fails the default scan (exit 10) without being "never legitimate".
NON_UTF8_BAND = "non-utf8-encoding"


def decode_for_scan(raw: bytes) -> tuple[str, dict | None]:
    """(text, None) for UTF-8; else (best-effort text, a non-utf8-encoding finding).

    The best-effort text is still scanned, so a UTF-16 file's hidden codepoints are
    named as well: decode by BOM when there is one, else UTF-8 with U+FFFD for each
    bad byte (U+FFFD is in no band, so replacements don't double-report).
    """
    try:
        return raw.decode("utf-8"), None
    except UnicodeDecodeError as e:
        bad_at = e.start

    def finding(line: int, col: int, why: str) -> dict:
        return {"type": "encoding", "line": line, "col": col, "codepoint": "", "char_name": "",
                "band": NON_UTF8_BAND, "severity": "high", "context": why}

    for bom, codec, label in UNICODE_BOMS:
        if raw.startswith(bom):
            return (raw[len(bom):].decode(codec, errors="replace"),
                    finding(1, 1, f"not UTF-8: {label} (BOM); decoded as {label} and scanned"))
    prefix = raw[:bad_at]                      # valid UTF-8 up to the first bad byte
    line = len(LINE_BREAK_BYTES.findall(prefix)) + 1
    line_start = max(prefix.rfind(b"\n"), prefix.rfind(b"\r")) + 1
    col = len(prefix[line_start:].decode("utf-8")) + 1
    return (raw.decode("utf-8", errors="replace"),
            finding(line, col, f"not UTF-8: invalid byte 0x{raw[bad_at]:02X}; "
                               "decoded with replacement and scanned - re-save as UTF-8"))


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
            # A band is one start/end span, or a 'ranges' list of [start, end] spans
            # for a concept the code chart splits (C1 around NEL, the Mongolian FVS
            # around MVS). Each span becomes its own entry carrying the band's id.
            for start, end in b.get("ranges") or [(b["start"], b["end"])]:
                bands.append({
                    "id": b["id"],
                    "name": b["name"],
                    "start": parse_cp(start),
                    "end": parse_cp(end),
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
    """--strict heuristic: a single word mixing confusable scripts (e.g. Latin + Cyrillic '<U+0430>dmin')."""
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
    for lineno, line in enumerate(LINE_BREAK.split(text), start=1):
        for col, ch in enumerate(line, start=1):
            cp = ord(ch)
            # Printable ASCII (0x20-0x7E) is never dangerous. Every other C0 control
            # and DEL falls through to the catalog, which bands them all except TAB
            # (CR/LF never get here: LINE_BREAK consumed them). Keep the bound at
            # < 0x7F - widening this fast path is how controls go unscanned.
            if 0x20 <= cp < 0x7F:
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
                # Control codes (VT, FF, NEL...) have no character name in the UCD.
                cname = "<control>" if unicodedata.category(ch) == "Cc" else "<unnamed>"
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


def iter_target_files(paths: list[str], includes: list[str]) -> tuple[list[Path], list[str]]:
    """(files to scan, directories whose walk matched nothing)."""
    out: list[Path] = []
    empty_walks: list[str] = []
    seen: set[Path] = set()

    def add(p: Path):
        rp = p.resolve()
        if rp not in seen and rp.is_file():
            seen.add(rp)
            out.append(p)

    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            matched = 0   # counted before dedupe: `. docs/` must not call docs/ empty
            for f in sorted(p.rglob("*")):
                if not f.is_file():
                    continue
                if f.name in INSTRUCTION_NAMES or any(f.match(g) for g in includes):
                    matched += 1
                    add(f)
            if not matched:
                empty_walks.append(raw)
        else:
            add(p)  # explicit file: scan regardless of extension
    return out, empty_walks


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
    # Everything asked for but not scanned: {"file", "reason", "code"}. Reported on
    # stderr whatever --quiet says, and it forbids exit 0 - a run that skipped a
    # file it could not decode or read once exited 0, even with zero files scanned.
    unscanned: list[dict] = []

    def scan_bytes(raw: bytes, label: str) -> None:
        text, enc = decode_for_scan(raw)
        if enc:
            enc["file"] = label
            all_findings.append(enc)
        for f in scan_text(text, bands, args.strict, whitelist):
            f["file"] = label
            all_findings.append(f)

    if args.stdin:
        scanned = 1
        scan_bytes(sys.stdin.buffer.read(), "<stdin>")
    else:
        if not args.paths:
            die("no paths given (and --stdin not set)", "USAGE", EXIT_USAGE, as_json)
        targets, empty_walks = iter_target_files(args.paths, includes)
        missing = [p for p in args.paths if not Path(p).exists()]
        if not targets:
            reason = (f"path not found: {missing[0]}" if missing else
                      f"nothing to scan: no file under {', '.join(args.paths)} matched {includes}")
            die(reason, "NOT_FOUND", EXIT_NOT_FOUND, as_json,
                details={"missing": missing, "empty_walks": empty_walks})
        unscanned += [{"file": p, "reason": "not found", "code": EXIT_NOT_FOUND} for p in missing]
        unscanned += [{"file": p, "reason": f"no file matched {includes}", "code": EXIT_NOT_FOUND}
                      for p in empty_walks]
        for path in targets:
            try:
                raw = path.read_bytes()
            except OSError as e:
                unscanned.append({"file": str(path), "reason": f"unreadable: {e.strerror or e}",
                                  "code": EXIT_PRECONDITION})
                continue
            scanned += 1
            scan_bytes(raw, str(path))

    # ---- output ------------------------------------------------------------
    worst = max((SEVERITY_ORDER[f["severity"]] for f in all_findings), default=0)
    failed = bool(all_findings)

    if as_json:
        print(json.dumps({
            "data": all_findings,
            "meta": {
                "count": len(all_findings),
                "files_scanned": scanned,
                "unscanned": [{"file": u["file"], "reason": u["reason"]} for u in unscanned],
                "complete": not unscanned,
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

    if unscanned:
        log("ERROR", f"{len(unscanned)} requested path(s) NOT scanned - not checked, not clean:")
        for u in unscanned:
            log("ERROR", f"  {u['file']}: {u['reason']}")
    if failed:
        log("ERROR",
            f"{len(all_findings)} hidden-unicode finding(s) across {scanned} file(s); "
            f"worst severity = {next((k for k,v in SEVERITY_ORDER.items() if v==worst),'?')}", args.quiet)
        return EXIT_INDICATOR
    if unscanned:
        return max(u["code"] for u in unscanned)   # 5 (unreadable) outranks 3 (not found)
    log("INFO", f"clean: no hidden-unicode indicators in {scanned} file(s)", args.quiet)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
