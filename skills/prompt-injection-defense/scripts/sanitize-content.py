#!/usr/bin/env python3
"""Strip hidden / direction-altering Unicode from untrusted content before it enters context.

Usage: sanitize-content.py [OPTIONS] [FILE]

Input:   FILE as argv, or content on stdin (default)
Output:  stdout = SANITIZED CONTENT (this is a filter; the cleaned text is the product)
Stderr:  removal report (human by default; JSON with --json), progress, errors
Exit:    0 ok (even if nothing removed), 2 usage, 3 not-found, 5 missing-catalog

Strip levels (default: standard):
  minimal     bidi overrides + tag-block only        (never touches emoji/multilingual)
  standard    + zero-width, word-joiner, isolates,    (preserves emoji + legit ZWNJ/ZWJ)
              marks, mid-file BOM, VS-supplement
  aggressive  + ZWNJ, PUA, variation selectors        (MAY alter emoji / icon-fonts /
                                                        Persian-Arabic-Indic text)

Examples:
  cat fetched-page.md | sanitize-content.py > clean.md
  sanitize-content.py untrusted.md --strip-level minimal -o clean.md
  curl -s https://r.jina.ai/URL | sanitize-content.py --json 2> report.json
  sanitize-content.py --nfkc --strip-level aggressive notes.txt
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_PRECONDITION = 5

STRIP_ORDER = {"minimal": 0, "standard": 1, "aggressive": 2, "never": 99}
DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "assets" / "dangerous-codepoints.json"


def die(message: str, code: str, exit_code: int, as_json: bool):
    if as_json:
        print(json.dumps({"error": {"code": code, "message": message}}), file=sys.stderr)
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(exit_code)


def parse_cp(token: str) -> int:
    return int(token.replace("U+", "").replace("u+", ""), 16)


def load_bands(path: Path, as_json: bool) -> list[dict]:
    if not path.exists():
        die(f"codepoint catalog not found: {path}", "MISSING_DEPENDENCY", EXIT_PRECONDITION, as_json)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        die(f"catalog unreadable: {e}", "VALIDATION_ERROR", EXIT_VALIDATION, as_json)
        return []
    bands = []
    for b in raw.get("bands", []):
        bands.append({
            "id": b["id"], "start": parse_cp(b["start"]), "end": parse_cp(b["end"]),
            "strip_level": b.get("strip_level", "standard"),
        })
    return bands


def build_strip_index(bands: list[dict], level: str) -> list[dict]:
    """Bands whose strip_level is at-or-below the chosen level (never-bands excluded)."""
    cap = STRIP_ORDER[level]
    return [b for b in bands if b["strip_level"] != "never" and STRIP_ORDER[b["strip_level"]] <= cap]


def band_for(cp: int, strip_bands: list[dict]) -> dict | None:
    for b in strip_bands:
        if b["start"] <= cp <= b["end"]:
            return b
    return None


def sanitize(text: str, strip_bands: list[dict], nfkc: bool) -> tuple[str, dict]:
    out_chars = []
    removed: dict[str, int] = {}
    for i, ch in enumerate(text):
        cp = ord(ch)
        if cp < 0x80:
            out_chars.append(ch)
            continue
        # Preserve a leading BOM (legitimate only at absolute file start).
        if cp == 0xFEFF and i == 0:
            out_chars.append(ch)
            continue
        b = band_for(cp, strip_bands)
        if b is None:
            out_chars.append(ch)
        else:
            removed[b["id"]] = removed.get(b["id"], 0) + 1
    cleaned = "".join(out_chars)
    if nfkc:
        cleaned = unicodedata.normalize("NFKC", cleaned)
    return cleaned, removed


def main() -> int:
    ap = argparse.ArgumentParser(prog="sanitize-content.py", add_help=False)
    ap.add_argument("file", nargs="?", help="input file (default: stdin)")
    ap.add_argument("--strip-level", choices=["minimal", "standard", "aggressive"],
                    default="standard", help="how much to remove (default: standard)")
    ap.add_argument("--nfkc", action="store_true",
                    help="also apply NFKC normalization (collapses confusables; alters ligatures/full-width)")
    ap.add_argument("-o", "--output", metavar="PATH", help="write cleaned content here instead of stdout")
    ap.add_argument("--catalog", metavar="PATH", help="override codepoint catalog path")
    ap.add_argument("--json", action="store_true", help="emit removal report as JSON to stderr")
    ap.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr report")
    ap.add_argument("-h", "--help", action="store_true", help="show this help and exit")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return EXIT_OK

    as_json = args.json
    bands = load_bands(Path(args.catalog) if args.catalog else DEFAULT_CATALOG, as_json)
    strip_bands = build_strip_index(bands, args.strip_level)

    if args.file:
        p = Path(args.file)
        if not p.exists():
            die(f"input not found: {args.file}", "NOT_FOUND", EXIT_NOT_FOUND, as_json)
        try:
            # Read bytes + decode (not read_text) so the newline layer never rewrites
            # CRLF -> LF: a sanitizer must be byte-faithful except for removed codepoints.
            text = p.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            die(f"input is not valid UTF-8: {args.file}", "VALIDATION_ERROR", EXIT_VALIDATION, as_json)
            return EXIT_VALIDATION
    else:
        text = sys.stdin.buffer.read().decode("utf-8", errors="replace")

    cleaned, removed = sanitize(text, strip_bands, args.nfkc)

    # stdout / -o is the sanitized content (this is a filter). Write BYTES, not text,
    # so the platform newline layer never rewrites \n -> \r\n (which breaks idempotency
    # and pipe-faithfulness). UTF-8 in, UTF-8 out, byte-for-byte except removed codepoints.
    blob = cleaned.encode("utf-8")
    if args.output:
        out = Path(args.output)
        tmp = out.with_suffix(out.suffix + ".tmp")
        tmp.write_bytes(blob)
        tmp.replace(out)
    else:
        sys.stdout.buffer.write(blob)
        sys.stdout.buffer.flush()

    total = sum(removed.values())
    if not args.quiet:
        if as_json:
            print(json.dumps({
                "data": {"removed_by_band": removed, "nfkc": args.nfkc, "strip_level": args.strip_level},
                "meta": {"removed_total": total, "schema": "claude-mods.prompt-injection.sanitize/v1"},
            }), file=sys.stderr)
        elif total:
            detail = ", ".join(f"{k}={v}" for k, v in sorted(removed.items()))
            print(f"[INFO] removed {total} hidden codepoint(s) [{args.strip_level}]: {detail}",
                  file=sys.stderr)
        else:
            print(f"[INFO] clean: nothing removed [{args.strip_level}]", file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
