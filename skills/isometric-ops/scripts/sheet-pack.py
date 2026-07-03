# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10.0"]
# ///
"""Pack a directory of tile/sprite PNGs into one spritesheet + a JSON atlas.

Deterministic, name-sorted shelf packer for isometric tile/sprite sets. Reads
every image directly under a directory (non-recursive), optionally trims
transparent margins per-sprite, pads each cell, optionally rounds the sheet to
power-of-two dimensions, and writes one PNG sheet plus one JSON atlas describing
where each source frame landed. Pair with tile-validate.py (QA before packing)
and engine-integration.md (importing the atlas into Godot/Unity/Phaser/Tiled).

Usage:   uv run sheet-pack.py <tiles-dir> [OPTIONS]
Input:   argv positional <tiles-dir>: a directory of *.png (and other Pillow-
         readable raster) tiles, read non-recursively, name-sorted (POSIX
         collation on the filename, ties broken by filename).
Output:  stdout = the two written paths (one per line), or the --json envelope
         (schema claude-mods.isometric-ops.sheet-pack/v1) when --json is set.
         The atlas JSON itself is written to disk, not printed.
Stderr:  progress (frame count, sheet size), warnings, errors.
Exit:    0 ok, 2 usage, 3 not found, 4 validation (unreadable/empty/oversized
          input), 5 missing dependency (Pillow unavailable).

Atlas schema (written to <out>.json, mirrors the TexturePacker/Phaser "hash"
family so it drops into most 2D engines with minimal remapping):

    {
      "meta": {
        "schema": "claude-mods.isometric-ops.sheet-pack/v1",
        "image": "<sheet filename>",
        "size": {"w": <int>, "h": <int>},
        "padding": <int>,
        "trimmed": <bool>,
        "pot": <bool>,
        "scale": 1,
        "app": "isometric-ops/sheet-pack.py",
        "generated_at": "<ISO-8601 Z>"
      },
      "frames": {
        "<name>": {
          "frame":     {"x": <int>, "y": <int>, "w": <int>, "h": <int>},
          "sourceSize": {"w": <int>, "h": <int>},
          "spriteSourceSize": {"x": <int>, "y": <int>, "w": <int>, "h": <int>},
          "sourceW": <int>,
          "sourceH": <int>,
          "trimmed": <bool>,
          "rotated": false
        },
        ...
      }
    }

  "frame" is the rectangle within the packed sheet (post-trim if --trim was
  used). "sourceSize" is the original untrimmed image dimensions. "spriteSourceSize"
  is where the trimmed frame sits inside that original canvas (x, y = offset of
  the trim box from the untrimmed top-left) — this is what lets an engine restore
  the original anchor/pivot after trimming (see engine-integration.md, "anchor/pivot
  mapping" under "importing sheet-pack.py atlases"). "sourceW"/"sourceH" are flat
  duplicates of "sourceSize.w"/"sourceSize.h" (same untrimmed dimensions), provided
  directly on the frame object for importers that don't want to descend into the
  nested "sourceSize" object — prefer "spriteSourceSize" when you need the trim
  *offset* (its x/y), since "sourceW"/"sourceH" alone cannot recover that. "name" is
  the source filename without its extension; keep names engine-safe (no spaces, one
  extension) — this script does not rewrite them.

Examples:
  uv run sheet-pack.py tiles/ --out atlas
  uv run sheet-pack.py tiles/ --trim --padding 2 --pot --out dist/tileset
  uv run sheet-pack.py tiles/ --json | jq -r '.data.sheet'
  uv run sheet-pack.py tiles/ --max-width 2048 --out atlas --force
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn

SCHEMA = "claude-mods.isometric-ops.sheet-pack/v1"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_MISSING_DEP = 5

# Pillow-readable raster extensions we'll consider "tiles" for packing.
# (Vector .svg is deliberately excluded — rasterize first; see
# svg-vector-generation.md for the export step.)
RASTER_EXTS = {".png", ".bmp", ".tga", ".tif", ".tiff", ".webp"}


def err(json_mode: bool, code: str, message: str, exit_code: int) -> NoReturn:
    """Print a structured error (stdout, --json only) + human line (stderr), then exit."""
    if json_mode:
        print(json.dumps({"error": {"code": code, "message": message, "details": {}}}))
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(exit_code)


def load_pillow(json_mode: bool):
    try:
        from PIL import Image  # noqa: PLC0415
    except ImportError:
        err(
            json_mode,
            "MISSING_DEPENDENCY",
            "Pillow is required. This script declares it via PEP 723 inline "
            "metadata — run it with `uv run sheet-pack.py ...` (uv installs "
            "Pillow into an ephemeral env automatically). Do not invoke with "
            "a bare `python`/`python3` that lacks Pillow.",
            EXIT_MISSING_DEP,
        )
    return Image


def discover_tiles(tiles_dir: Path) -> list[Path]:
    """Non-recursive, name-sorted (by stem) list of raster files directly in tiles_dir."""
    files = [
        p
        for p in tiles_dir.iterdir()
        if p.is_file() and p.suffix.lower() in RASTER_EXTS
    ]
    # Deterministic order: sort by filename stem (case-insensitive), then full
    # name as a tiebreaker so e.g. "Tile2" vs "tile2" is still stable.
    return sorted(files, key=lambda p: (p.stem.lower(), p.name))


def bbox_alpha(img) -> tuple[int, int, int, int] | None:
    """Bounding box of non-fully-transparent pixels, or None if the image has no alpha."""
    if img.mode != "RGBA":
        return None
    alpha = img.split()[-1]
    return alpha.getbbox()


def next_pot(n: int) -> int:
    """Smallest power of two >= n (minimum 1)."""
    if n <= 1:
        return 1
    return 1 << (n - 1).bit_length()


def pack_shelves(
    frames: list[dict[str, Any]], padding: int, max_width: int
) -> tuple[int, int]:
    """Simple deterministic shelf (row) packer.

    Frames are placed left-to-right in name-sorted order, wrapping to a new
    shelf when the running row width would exceed max_width. Shelf height is
    the tallest frame placed on that shelf. This is intentionally NOT a
    bin-packing optimizer (no MaxRects/skyline) — isometric tile/sprite sets
    are near-uniform in size, so a shelf packer is simple, fully deterministic
    (stable atlas diffs across builds), and wastes negligible space for that
    shape of input. Mutates each frame dict in place, adding "x"/"y".
    Returns the (width, height) of the packed sheet before any POT rounding.
    """
    x = padding
    y = padding
    shelf_h = 0
    sheet_w = padding
    for f in frames:
        w, h = f["_pack_w"], f["_pack_h"]
        if x + w + padding > max_width and x > padding:
            # New shelf.
            x = padding
            y += shelf_h + padding
            shelf_h = 0
        f["x"] = x
        f["y"] = y
        x += w + padding
        shelf_h = max(shelf_h, h)
        sheet_w = max(sheet_w, x)
    sheet_h = y + shelf_h + padding
    return sheet_w, sheet_h


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="sheet-pack.py",
        description=(
            "Pack a directory of tile/sprite PNGs into one spritesheet PNG + "
            "a JSON atlas (frames keyed by filename stem)."
        ),
        epilog=(
            "Examples:\n"
            "  uv run sheet-pack.py tiles/ --out atlas\n"
            "  uv run sheet-pack.py tiles/ --trim --padding 2 --pot --out dist/tileset\n"
            "  uv run sheet-pack.py tiles/ --json | jq -r '.data.sheet'\n"
            "  uv run sheet-pack.py tiles/ --max-width 2048 --out atlas --force\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("tiles_dir", help="directory of tile/sprite images (non-recursive)")
    ap.add_argument(
        "--out",
        default="atlas",
        help="output basename, no extension (writes <out>.png + <out>.json); default 'atlas'",
    )
    ap.add_argument(
        "--trim",
        action="store_true",
        help="crop each sprite to its non-transparent bounding box before packing "
        "(RGBA sources only; opaque/no-alpha sources are packed uncropped)",
    )
    ap.add_argument(
        "--padding",
        type=int,
        default=1,
        metavar="N",
        help="pixels of empty space between packed frames (default 1)",
    )
    ap.add_argument(
        "--pot",
        action="store_true",
        help="round the final sheet width and height up to the next power of two",
    )
    ap.add_argument(
        "--max-width",
        type=int,
        default=4096,
        metavar="N",
        help="shelf-wrap width budget in px before rounding/POT (default 4096)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="overwrite <out>.png/<out>.json if they already exist",
    )
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    args = ap.parse_args()

    if args.padding < 0:
        err(args.json, "USAGE", "--padding must be >= 0", EXIT_USAGE)
    if args.max_width < 1:
        err(args.json, "USAGE", "--max-width must be >= 1", EXIT_USAGE)
    if not args.out or any(c in args.out for c in ('"', "\x00")):
        err(args.json, "USAGE", "--out must be a non-empty, safe basename", EXIT_USAGE)

    tiles_dir = Path(args.tiles_dir)
    if not tiles_dir.is_dir():
        err(args.json, "NOT_FOUND", f"not a directory: {tiles_dir}", EXIT_NOT_FOUND)

    out_base = Path(args.out).resolve()
    sheet_path = out_base.with_suffix(".png")
    atlas_path = out_base.with_suffix(".json")
    if not args.force:
        for p in (sheet_path, atlas_path):
            if p.exists():
                err(
                    args.json,
                    "VALIDATION",
                    f"{p} already exists (pass --force to overwrite)",
                    EXIT_VALIDATION,
                )

    Image = load_pillow(args.json)

    sources = discover_tiles(tiles_dir)
    if not sources:
        err(
            args.json,
            "VALIDATION",
            f"no raster tiles found directly in {tiles_dir} "
            f"(looked for: {', '.join(sorted(RASTER_EXTS))})",
            EXIT_VALIDATION,
        )

    print(f"packing {len(sources)} tile(s) from {tiles_dir}...", file=sys.stderr)

    frames: list[dict[str, Any]] = []
    opened: list[Any] = []
    try:
        for src in sources:
            try:
                img = Image.open(src)
                img.load()
            except Exception as exc:  # noqa: BLE001 - surface as a validation error, not a crash
                err(
                    args.json,
                    "VALIDATION",
                    f"unreadable image: {src} ({exc})",
                    EXIT_VALIDATION,
                )
            if img.mode not in ("RGBA", "RGB", "P", "LA", "L"):
                img = img.convert("RGBA")
            if img.mode != "RGBA":
                img = img.convert("RGBA")
            opened.append(img)

            source_w, source_h = img.size
            trim_box = bbox_alpha(img) if args.trim else None
            trimmed = trim_box is not None and trim_box != (0, 0, source_w, source_h)
            if trim_box is None:
                trim_box = (0, 0, source_w, source_h)
            tx0, ty0, tx1, ty1 = trim_box
            frame_w, frame_h = max(1, tx1 - tx0), max(1, ty1 - ty0)

            frames.append(
                {
                    "name": src.stem,
                    "_img": img,
                    "_crop": trim_box,
                    "_pack_w": frame_w,
                    "_pack_h": frame_h,
                    "sourceSize": {"w": source_w, "h": source_h},
                    "spriteSourceSize": {
                        "x": tx0,
                        "y": ty0,
                        "w": frame_w,
                        "h": frame_h,
                    },
                    "trimmed": trimmed,
                    "rotated": False,
                }
            )

        # Guard against duplicate stems silently clobbering atlas entries
        # (e.g. "crate.png" and "crate.PNG" in the same directory).
        seen: dict[str, Path] = {}
        for f, src in zip(frames, sources):
            if f["name"] in seen:
                err(
                    args.json,
                    "VALIDATION",
                    f"duplicate frame name '{f['name']}' from {seen[f['name']]} and {src} "
                    "(filenames must be unique ignoring extension)",
                    EXIT_VALIDATION,
                )
            seen[f["name"]] = src

        sheet_w, sheet_h = pack_shelves(frames, args.padding, args.max_width)
        if args.pot:
            sheet_w, sheet_h = next_pot(sheet_w), next_pot(sheet_h)

        if sheet_w > 16384 or sheet_h > 16384:
            err(
                args.json,
                "VALIDATION",
                f"packed sheet would be {sheet_w}x{sheet_h}px, over the 16384px safety "
                "ceiling (most GPUs cap texture dims there) — split the tile set or "
                "raise --max-width to pack fewer shelves is not the fix; reduce input "
                "count/size instead",
                EXIT_VALIDATION,
            )

        sheet = Image.new("RGBA", (sheet_w, sheet_h), (0, 0, 0, 0))
        for f in frames:
            crop = f["_img"].crop(f["_crop"])
            sheet.paste(crop, (f["x"], f["y"]), crop)

        sheet_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_sheet = sheet_path.with_suffix(sheet_path.suffix + ".tmp")
        sheet.save(tmp_sheet, format="PNG")
        tmp_sheet.replace(sheet_path)
    finally:
        for img in opened:
            try:
                img.close()
            except Exception:  # noqa: BLE001 - best-effort cleanup
                pass

    atlas_frames = {}
    for f in frames:
        atlas_frames[f["name"]] = {
            "frame": {"x": f["x"], "y": f["y"], "w": f["_pack_w"], "h": f["_pack_h"]},
            "sourceSize": f["sourceSize"],
            "spriteSourceSize": f["spriteSourceSize"],
            # Flat aliases of sourceSize.w/h so importers can read frame.sourceW/
            # frame.sourceH directly (see the schema docstring above for why
            # spriteSourceSize is still needed for trim-offset recovery).
            "sourceW": f["sourceSize"]["w"],
            "sourceH": f["sourceSize"]["h"],
            "trimmed": f["trimmed"],
            "rotated": f["rotated"],
        }

    atlas = {
        "meta": {
            "schema": SCHEMA,
            "image": sheet_path.name,
            "size": {"w": sheet_w, "h": sheet_h},
            "padding": args.padding,
            "trimmed": bool(args.trim),
            "pot": bool(args.pot),
            "scale": 1,
            "app": "isometric-ops/sheet-pack.py",
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "frames": atlas_frames,
    }
    tmp_atlas = atlas_path.with_suffix(atlas_path.suffix + ".tmp")
    tmp_atlas.write_text(json.dumps(atlas, indent=2) + "\n", encoding="utf-8")
    tmp_atlas.replace(atlas_path)

    print(
        f"packed {len(frames)} frame(s) into {sheet_w}x{sheet_h} sheet "
        f"({'trimmed, ' if args.trim else ''}padding={args.padding}"
        f"{', pot' if args.pot else ''})",
        file=sys.stderr,
    )

    data = {
        "sheet": str(sheet_path),
        "atlas": str(atlas_path),
        "frame_count": len(frames),
        "size": {"w": sheet_w, "h": sheet_h},
    }
    if args.json:
        print(json.dumps({"data": data, "meta": {"schema": SCHEMA}}, indent=2))
    else:
        print(sheet_path)
        print(atlas_path)

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
