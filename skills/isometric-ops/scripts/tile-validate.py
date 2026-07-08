# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow>=10.0"]
# ///
"""QA gate for isometric tile assets — dimension, alpha-halo, edge-bleed, anchor, palette checks.

Usage:   uv run tile-validate.py [OPTIONS] <TILE.png> [<TILE2.png> ...]
Input:   one or more raster tile files (PNG/WebP/etc — anything Pillow opens with an
         alpha channel expected); a directory is NOT expanded automatically (pass a
         glob from the shell, e.g. `uv run tile-validate.py tiles/*.png`).
Output:  stdout = data only — one PASS/FAIL line per file (plain mode), or the
         --json envelope (schema claude-mods.isometric-ops.tile_validate/v1).
Stderr:  progress, per-check narration, warnings, errors.
Exit:    0 all files clean
         2 usage (bad/missing args, conflicting flags)
         3 not-found (an input file does not exist)
         4 validation (an input file exists but is not a readable image)
         5 precondition (Pillow not installed / can't be imported)
         10 domain signal — at least one file has at least one violation

Checks (each individually toggleable with --skip-<name>; see --help):
  dimension   Tile W×H are each an exact multiple of --tile-w/--tile-h (the tile
              module). Skipped automatically if --tile-w/--tile-h not given.
  halo        % of semi-transparent pixels (0 < alpha < 255) exceeds --halo-threshold
              (default 0.5% of total pixels). Classic AI-generation edge fringe.
  bleed       Any opaque pixel (alpha > --bleed-alpha, default 0) sits on the
              outermost row/column of the canvas — the sprite has no transparent
              margin and will visibly clip against neighbouring tiles/UI chrome.
  anchor      Heuristic: the lowest (max-y) row containing an opaque pixel should be
              roughly horizontally centered — sprites are anchored at the visual feet
              (see references/tile-spec.md), and an off-center foot row usually means
              the source asset was cropped or padded asymmetrically. Reported as an
              offset percentage from center; flagged past --anchor-tolerance (default
              15% of width).
  colors      Distinct RGBA color count exceeds --max-colors (only run if set).

Examples:
  uv run tile-validate.py tiles/grass_n.png
  uv run tile-validate.py --tile-w 64 --tile-h 32 tiles/*.png
  uv run tile-validate.py --max-colors 32 --json tiles/*.png | jq '.data[] | select(.violations | length > 0)'
  uv run tile-validate.py --skip-anchor --halo-threshold 1.0 wall_tiles/*.png
  uv run tile-validate.py --json tiles/crate.png | jq -r '.data[0].violations[].check'

Notes:
  - Run via `uv run` so the PEP 723 block above resolves Pillow automatically. On
    Windows, avoid the Microsoft Store `python3` stub (it exits 49 doing nothing) —
    `uv run` or a real `python`/`py` on PATH both work.
  - The dimension check only fires when --tile-w AND --tile-h are both supplied,
    since not every asset in a set is a full ground tile (props/overlays vary).
  - This script performs read-only inspection; it never rewrites the input file.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Semantic exit codes (SKILL-RESOURCE-PROTOCOL.md §5).
EX_OK = 0
EX_USAGE = 2
EX_NOT_FOUND = 3
EX_VALIDATION = 4
EX_PRECONDITION = 5
EX_DOMAIN = 10

SCHEMA = "claude-mods.isometric-ops.tile_validate/v1"

DEFAULT_HALO_THRESHOLD_PCT = 0.5   # % of total pixels allowed to be semi-transparent
DEFAULT_BLEED_ALPHA = 0            # any alpha strictly greater than this on the border = bleed
DEFAULT_ANCHOR_TOLERANCE_PCT = 15.0  # % of width the lowest-opaque-row centroid may drift


def eprint(*args: Any, **kwargs: Any) -> None:
    print(*args, file=sys.stderr, **kwargs)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="tile-validate.py",
        description=(
            "QA gate for isometric tile assets: dimension conformance, alpha-halo, "
            "edge-bleed, anchor-at-feet heuristic, and palette-size checks."
        ),
        epilog=(
            "Examples:\n"
            "  uv run tile-validate.py tiles/grass_n.png\n"
            "  uv run tile-validate.py --tile-w 64 --tile-h 32 tiles/*.png\n"
            "  uv run tile-validate.py --max-colors 32 --json tiles/*.png | "
            "jq '.data[] | select(.violations | length > 0)'\n"
            "  uv run tile-validate.py --skip-anchor --halo-threshold 1.0 wall_tiles/*.png\n"
            "  uv run tile-validate.py --json tiles/crate.png | "
            "jq -r '.data[0].violations[].check'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("files", nargs="*", metavar="TILE", help="one or more image files to validate")
    p.add_argument("--tile-w", type=int, default=None, metavar="N", help="expected tile-module width in px (dimension check)")
    p.add_argument("--tile-h", type=int, default=None, metavar="N", help="expected tile-module height in px (dimension check)")
    p.add_argument(
        "--halo-threshold", type=float, default=DEFAULT_HALO_THRESHOLD_PCT, metavar="PCT",
        help=f"max %% of semi-transparent pixels before flagging halo (default {DEFAULT_HALO_THRESHOLD_PCT})",
    )
    p.add_argument(
        "--bleed-alpha", type=int, default=DEFAULT_BLEED_ALPHA, metavar="N",
        help=f"alpha value (0-255) above which a border pixel counts as bleed (default {DEFAULT_BLEED_ALPHA})",
    )
    p.add_argument(
        "--anchor-tolerance", type=float, default=DEFAULT_ANCHOR_TOLERANCE_PCT, metavar="PCT",
        help=f"max %% horizontal drift of the foot-row centroid from center (default {DEFAULT_ANCHOR_TOLERANCE_PCT})",
    )
    p.add_argument("--max-colors", type=int, default=None, metavar="N", help="flag if distinct RGBA color count exceeds N (unset = skip)")
    p.add_argument("--skip-dimension", action="store_true", help="skip the dimension-conformance check")
    p.add_argument("--skip-halo", action="store_true", help="skip the alpha-halo check")
    p.add_argument("--skip-bleed", action="store_true", help="skip the edge-bleed check")
    p.add_argument("--skip-anchor", action="store_true", help="skip the anchor-at-feet heuristic")
    p.add_argument("--json", action="store_true", help="emit the --json envelope to stdout instead of plain lines")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress per-check stderr narration (still reports violations)")
    return p


def load_image(path: Path):
    """Open path as RGBA. Raises FileNotFoundError / PIL.UnidentifiedImageError-family."""
    from PIL import Image  # deferred: exit 5 with a clean message if this import fails

    img = Image.open(path)
    img.load()  # force decode now so corrupt files fail here, not later mid-check
    return img.convert("RGBA")


def check_dimension(img, tile_w: int | None, tile_h: int | None) -> list[dict[str, Any]]:
    if tile_w is None or tile_h is None:
        return []
    w, h = img.size
    violations = []
    if w % tile_w != 0 or h % tile_h != 0:
        violations.append({
            "check": "dimension",
            "message": f"{w}x{h} is not an exact multiple of the {tile_w}x{tile_h} tile module",
            "detail": {"width": w, "height": h, "tile_w": tile_w, "tile_h": tile_h},
        })
    return violations


def check_halo(img, threshold_pct: float) -> list[dict[str, Any]]:
    alpha = img.getchannel("A")
    total = alpha.width * alpha.height
    if total == 0:
        return []
    histogram = alpha.histogram()  # 256 buckets, index = alpha value
    semi_transparent = sum(histogram[1:255])  # exclude fully transparent (0) and fully opaque (255)
    pct = (semi_transparent / total) * 100.0
    if pct > threshold_pct:
        return [{
            "check": "halo",
            "message": f"{pct:.2f}% of pixels are semi-transparent (threshold {threshold_pct}%) — likely AI-generation edge fringe",
            "detail": {"semi_transparent_pct": round(pct, 4), "threshold_pct": threshold_pct, "semi_transparent_pixels": semi_transparent, "total_pixels": total},
        }]
    return []


def check_bleed(img, bleed_alpha: int) -> list[dict[str, Any]]:
    alpha = img.getchannel("A")
    w, h = alpha.size
    if w == 0 or h == 0:
        return []
    px = alpha.load()
    bleeding_pixels = 0
    edge_coords = set()
    for x in range(w):
        for y in (0, h - 1):
            if px[x, y] > bleed_alpha:
                bleeding_pixels += 1
                edge_coords.add((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if px[x, y] > bleed_alpha:
                bleeding_pixels += 1
                edge_coords.add((x, y))
    if edge_coords:
        return [{
            "check": "bleed",
            "message": f"{len(edge_coords)} border pixel(s) exceed alpha {bleed_alpha} — no transparent margin, will clip against neighbours",
            "detail": {"bleeding_border_pixels": len(edge_coords), "bleed_alpha_threshold": bleed_alpha},
        }]
    return []


def check_anchor(img, tolerance_pct: float) -> list[dict[str, Any]]:
    alpha = img.getchannel("A")
    w, h = alpha.size
    if w == 0 or h == 0:
        return []
    px = alpha.load()
    # Find the lowest (max-y) row containing at least one opaque-ish pixel (alpha > 0),
    # then compute that row's opaque-pixel horizontal centroid vs. the canvas center.
    foot_y = None
    for y in range(h - 1, -1, -1):
        if any(px[x, y] > 0 for x in range(w)):
            foot_y = y
            break
    if foot_y is None:
        return []  # fully transparent image — nothing to anchor-check
    opaque_xs = [x for x in range(w) if px[x, foot_y] > 0]
    if not opaque_xs:
        return []
    centroid_x = sum(opaque_xs) / len(opaque_xs)
    canvas_center_x = w / 2.0
    drift_pct = (abs(centroid_x - canvas_center_x) / w) * 100.0
    if drift_pct > tolerance_pct:
        return [{
            "check": "anchor",
            "message": f"foot-row centroid drifts {drift_pct:.1f}% of width from center (tolerance {tolerance_pct}%) — asset may be asymmetrically cropped/padded",
            "detail": {
                "foot_row_y": foot_y,
                "centroid_x": round(centroid_x, 2),
                "canvas_center_x": canvas_center_x,
                "drift_pct": round(drift_pct, 2),
                "tolerance_pct": tolerance_pct,
            },
        }]
    return []


def check_colors(img, max_colors: int | None) -> list[dict[str, Any]]:
    if max_colors is None:
        return []
    w, h = img.size
    # getcolors returns None if distinct-color count exceeds maxcolors; use total
    # pixel count as the ceiling so we always get an exact count back.
    colors = img.getcolors(maxcolors=w * h)
    count = len(colors) if colors is not None else w * h
    if count > max_colors:
        return [{
            "check": "colors",
            "message": f"{count} distinct RGBA colors exceeds --max-colors {max_colors}",
            "detail": {"distinct_colors": count, "max_colors": max_colors},
        }]
    return []


def validate_file(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    record: dict[str, Any] = {"file": str(path), "ok": False, "violations": [], "error": None}

    if not path.exists():
        record["error"] = {"code": "NOT_FOUND", "message": f"file does not exist: {path}"}
        return record
    if not path.is_file():
        record["error"] = {"code": "NOT_FOUND", "message": f"not a regular file: {path}"}
        return record

    try:
        img = load_image(path)
    except Exception as exc:  # noqa: BLE001 - any Pillow/OS decode failure funnels to VALIDATION
        record["error"] = {"code": "VALIDATION", "message": f"could not open as an image: {exc}"}
        return record

    record["width"], record["height"] = img.size

    violations: list[dict[str, Any]] = []
    if not args.skip_dimension:
        violations += check_dimension(img, args.tile_w, args.tile_h)
    if not args.skip_halo:
        violations += check_halo(img, args.halo_threshold)
    if not args.skip_bleed:
        violations += check_bleed(img, args.bleed_alpha)
    if not args.skip_anchor:
        violations += check_anchor(img, args.anchor_tolerance)
    violations += check_colors(img, args.max_colors)

    record["violations"] = violations
    record["ok"] = len(violations) == 0
    return record


def emit_plain(records: list[dict[str, Any]], quiet: bool) -> None:
    for rec in records:
        if rec["error"] is not None:
            print(f"ERROR\t{rec['file']}\t{rec['error']['code']}: {rec['error']['message']}")
            continue
        if rec["ok"]:
            print(f"PASS\t{rec['file']}\t{rec['width']}x{rec['height']}")
        else:
            print(f"FAIL\t{rec['file']}\t{len(rec['violations'])} violation(s)")
            for v in rec["violations"]:
                print(f"  - {v['check']}: {v['message']}")


def emit_json(records: list[dict[str, Any]], had_domain_hit: bool, had_hard_error: bool) -> None:
    payload = {
        "data": records,
        "meta": {
            "count": len(records),
            "schema": SCHEMA,
            "clean": not had_domain_hit and not had_hard_error,
        },
    }
    print(json.dumps(payload))


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.files:
        eprint("ERROR: no input files given (try --help)")
        return EX_USAGE

    if (args.tile_w is None) != (args.tile_h is None):
        eprint("ERROR: --tile-w and --tile-h must be given together")
        return EX_USAGE
    if args.tile_w is not None and args.tile_w <= 0:
        eprint("ERROR: --tile-w must be a positive integer")
        return EX_USAGE
    if args.tile_h is not None and args.tile_h <= 0:
        eprint("ERROR: --tile-h must be a positive integer")
        return EX_USAGE
    if args.halo_threshold < 0:
        eprint("ERROR: --halo-threshold must be >= 0")
        return EX_USAGE
    if args.anchor_tolerance < 0:
        eprint("ERROR: --anchor-tolerance must be >= 0")
        return EX_USAGE
    if args.bleed_alpha < 0 or args.bleed_alpha > 255:
        eprint("ERROR: --bleed-alpha must be in [0, 255]")
        return EX_USAGE
    if args.max_colors is not None and args.max_colors <= 0:
        eprint("ERROR: --max-colors must be a positive integer")
        return EX_USAGE

    try:
        import PIL  # noqa: F401
    except ImportError:
        eprint("ERROR: Pillow is not installed. Run this script via `uv run tile-validate.py ...`")
        eprint("       so the PEP 723 inline metadata resolves it automatically, or:")
        eprint("       uv pip install pillow")
        return EX_PRECONDITION

    if not args.quiet:
        eprint(f"tile-validate: checking {len(args.files)} file(s)...")

    records: list[dict[str, Any]] = []
    any_not_found = False
    any_validation_error = False
    for raw_path in args.files:
        path = Path(raw_path)
        if not args.quiet:
            eprint(f"  {path}")
        rec = validate_file(path, args)
        records.append(rec)
        if rec["error"] is not None:
            if rec["error"]["code"] == "NOT_FOUND":
                any_not_found = True
            else:
                any_validation_error = True

    had_domain_hit = any(rec["error"] is None and not rec["ok"] for rec in records)
    had_hard_error = any_not_found or any_validation_error

    if args.json:
        emit_json(records, had_domain_hit, had_hard_error)
    else:
        emit_plain(records, args.quiet)

    if any_not_found:
        eprint(f"ERROR: {sum(1 for r in records if r['error'] and r['error']['code'] == 'NOT_FOUND')} input file(s) not found")
        return EX_NOT_FOUND
    if any_validation_error:
        eprint(f"ERROR: {sum(1 for r in records if r['error'] and r['error']['code'] == 'VALIDATION')} input file(s) failed to open as images")
        return EX_VALIDATION
    if had_domain_hit:
        if not args.quiet:
            eprint(f"tile-validate: {sum(1 for r in records if not r['ok'])} of {len(records)} file(s) have violations")
        return EX_DOMAIN

    if not args.quiet:
        eprint(f"tile-validate: all {len(records)} file(s) clean")
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
