#!/usr/bin/env python3
# Isometric projection math CLI: constants, coordinate transforms, grids, recipes.
#
# Usage:   iso-math.py <subcommand> [OPTIONS]
# Input:   argv only (no stdin). Numbers are floats; tile sizes are positive ints.
# Output:  stdout = data only. Plain text by default; JSON under --json
#          (envelope: {"data": ..., "meta": {"count", "schema"}}). grid-svg emits SVG.
# Stderr:  headers, warnings, errors, and the human line for --json errors.
# Exit:    0 ok, 2 usage (bad/missing/unknown args), 4 validation (bad values), 10 unused.
#
# Subcommands:
#   constants [--projection true|dimetric21|pixel] [--json]
#   to-screen X Y [Z] --tile-w N --tile-h N [--elev-step N] [--json]
#   to-tile   SX SY --tile-w N --tile-h N [--json]
#   grid-svg  --projection P --tile-w N --extent N [--stroke COLOR] [--tile-h N]
#   transforms --target T [--projection P] [--json]
#
# Examples:
#   iso-math.py constants --projection true --json | jq '.data'
#   iso-math.py to-screen 3 5 --tile-w 64 --tile-h 32
#   iso-math.py to-tile -64 128 --tile-w 64 --tile-h 32 --json | jq '.data'
#   iso-math.py grid-svg --projection dimetric21 --tile-w 64 --extent 8 > grid.svg
#   iso-math.py transforms --target css-3d
#
# All figures match skills/isometric-ops references and the canonical constants table
# to >= 4 decimal places. Derivations are computed from first principles here, not
# hard-coded, so the numbers cannot drift from their mathematical definitions.
#
# Sources (see references/projection-math.md for full citations):
#   - Wikipedia, "Isometric projection" / "Isometric video game graphics"
#     https://en.wikipedia.org/wiki/Isometric_projection
#   - Pikuma, "Isometric Projection in Game Development"
#     https://pikuma.com/blog/isometric-projection-in-games
#   - yal.cc, "Understanding isometric grids"  https://yal.cc/understanding-isometric-grids/
#   - obelisk.js README (pixel-neat 22.6 deg)  https://github.com/nosir/obelisk.js

"""Isometric projection math: constants, transforms, grids, and CSS/SVG recipes.

Pure stdlib. See the module comment above for the full CLI contract and examples.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any

SCHEMA_PREFIX = "claude-mods.isometric-ops.iso-math"

# Exit codes (per docs/SKILL-RESOURCE-PROTOCOL.md section 5).
EX_OK = 0
EX_USAGE = 2
EX_VALIDATION = 4

# ---------------------------------------------------------------------------
# Canonical geometry, derived from first principles (never hard-coded rounded).
# ---------------------------------------------------------------------------
# True isometric: a cube rotated +/-45 deg about vertical, then tilted about the
# horizontal by the "magic angle" arctan(1/sqrt(2)) = arcsin(1/sqrt(3)) = 35.2644 deg.
TILT_RAD = math.atan(1.0 / math.sqrt(2.0))              # 35.2643896... deg
TILT_DEG = math.degrees(TILT_RAD)
FORESHORTEN = math.cos(TILT_RAD)                        # sqrt(2/3) = 0.816497 (true projection)
CSS_ROTATEX_DEG = math.degrees(math.atan(math.sqrt(2.0)))  # 54.7356 deg = 90 - 35.2644
CSS_SCALE = 1.0 / FORESHORTEN                           # sqrt(3/2) = 1.224745 (undo foreshorten)
SSR_VERTICAL = math.cos(math.radians(30.0))            # 0.866025 = cos(30)
FIGMA_HEIGHT = math.tan(math.radians(30.0))            # 0.577350 = tan(30)
GROUND_AXIS_DEG = 30.0                                  # true-iso ground-axis angle
AXIS_SEPARATION_DEG = 120.0

# 2:1 dimetric ("game isometric"): axis angle arctan(1/2).
DIMETRIC_AXIS_RAD = math.atan(0.5)                      # 26.5651 deg
DIMETRIC_AXIS_DEG = math.degrees(DIMETRIC_AXIS_RAD)

# obelisk.js pixel-neat: its README states a 1:2 pixel-dot arrangement -> 22.6 deg.
# Geometrically arctan(1/2) = 26.565; the 22.6 figure is the library's own stated
# pixel-stepping angle. See references/projection-math.md, contested-fact #1.
OBELISK_STATED_DEG = 22.6


def r(value: float, places: int = 5) -> float:
    """Round for display; keeps output stable and >= 4-decimal accurate."""
    return round(value, places)


# ---------------------------------------------------------------------------
# Output helpers (stream separation: stdout = data, stderr = everything else).
# ---------------------------------------------------------------------------
def warn(msg: str) -> None:
    print(msg, file=sys.stderr)


def emit(data: Any, count: int, name: str, as_json: bool, plain: str) -> int:
    """Emit either the plain data product or the --json envelope, both to stdout."""
    if as_json:
        envelope = {
            "data": data,
            "meta": {"count": count, "schema": f"{SCHEMA_PREFIX}.{name}/v1"},
        }
        print(json.dumps(envelope, indent=2))
    else:
        print(plain)
    return EX_OK


def fail(message: str, code: int, as_json: bool, err_code: str, details: Any = None) -> int:
    """Emit a structured error to stdout (when --json) plus a human line to stderr."""
    if as_json:
        print(json.dumps({"error": {"code": err_code, "message": message,
                                    "details": details or {}}}))
    warn(f"error: {message}")
    return code


def positive_int(raw: str, name: str) -> int:
    val = int(raw)
    if val <= 0:
        raise ValueError(f"{name} must be a positive integer, got {val}")
    return val


# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
def build_constants(projection: str) -> dict[str, Any]:
    true_iso = {
        "projection": "true",
        "label": "true isometric projection",
        "groundAxisAngleDeg": r(GROUND_AXIS_DEG),
        "axisSeparationDeg": r(AXIS_SEPARATION_DEG),
        "cubeTiltDeg": r(TILT_DEG),
        "foreshortenProjection": r(FORESHORTEN),
        "drawingScale": 1.0,
        "ssrVerticalScale": r(SSR_VERTICAL),
        "figmaHeightScale": r(FIGMA_HEIGHT),
        "topCircleMinorOverMajor": r(FIGMA_HEIGHT),
        "cssRotateXDeg": r(CSS_ROTATEX_DEG, 4),
        "cssRotateZDeg": -45.0,
        "cssScale3d": r(CSS_SCALE),
        "derivation": {
            "cubeTiltDeg": "arctan(1/sqrt(2)) = arcsin(1/sqrt(3))",
            "foreshortenProjection": "cos(35.264) = sqrt(2/3)",
            "ssrVerticalScale": "cos(30)",
            "figmaHeightScale": "tan(30)",
            "cssRotateXDeg": "arctan(sqrt(2)) = 90 - 35.264",
            "cssScale3d": "sqrt(3/2) = 1/cos(35.264), undoes foreshortening",
        },
    }
    dimetric = {
        "projection": "dimetric21",
        "label": "2:1 dimetric (commonly called isometric in games)",
        "groundAxisAngleDeg": r(DIMETRIC_AXIS_DEG),
        "axisSeparationsDeg": [116.565, 116.565, 126.870],
        "tileAspect": "2:1",
        "commonTileSizes": ["64x32", "128x64", "32x16"],
        "toScreen": "screenX = (x - y) * tileW/2 ; screenY = (x + y) * tileH/2",
        "toTile": ("x = (screenX/(tileW/2) + screenY/(tileH/2)) / 2 ; "
                   "y = (screenY/(tileH/2) - screenX/(tileW/2)) / 2"),
        "derivation": {
            "groundAxisAngleDeg": "arctan(1/2)",
            "note": ("dimetric, not isometric: only two of the three inter-axis "
                     "angles are equal"),
        },
    }
    pixel = {
        "projection": "pixel",
        "label": "pixel-neat 1:2 stepping (obelisk-style)",
        "obeliskStatedAngleDeg": OBELISK_STATED_DEG,
        "geometricArctanHalfDeg": r(DIMETRIC_AXIS_DEG),
        "pixelStep": "2 px across : 1 px up",
        "note": ("obelisk.js README states 22.6 deg for its 1:2 pixel-dot pattern; "
                 "the pure geometric 1:2 slope is arctan(1/2) = 26.565 deg. Use "
                 "26.565 for math, 22.6 only when matching obelisk output."),
        "reference": "https://github.com/nosir/obelisk.js",
    }
    table = {"true": true_iso, "dimetric21": dimetric, "pixel": pixel}
    if projection == "all":
        return table
    return {projection: table[projection]}


def plain_constants(data: dict[str, Any]) -> str:
    lines: list[str] = []
    for key, block in data.items():
        lines.append(f"[{key}] {block.get('label', '')}")
        for k, v in block.items():
            if k in ("projection", "label", "derivation", "reference", "note"):
                continue
            lines.append(f"  {k} = {v}")
        if "note" in block:
            lines.append(f"  note: {block['note']}")
    return "\n".join(lines)


def cmd_constants(args: argparse.Namespace) -> int:
    projection = args.projection or "all"
    data = build_constants(projection)
    return emit(data, len(data), "constants", args.json, plain_constants(data))


# ---------------------------------------------------------------------------
# to-screen / to-tile  (2:1 dimetric canonical transform, parametrized by tile size)
# ---------------------------------------------------------------------------
def cmd_to_screen(args: argparse.Namespace) -> int:
    tw, th = args.tile_w, args.tile_h
    x, y, z = args.x, args.y, args.z
    screen_x = (x - y) * (tw / 2.0)
    # +z (elevation) lifts the sprite upward on screen (y-down => subtract).
    screen_y = (x + y) * (th / 2.0) - z * args.elev_step
    data = {
        "tile": {"x": x, "y": y, "z": z},
        "screen": {"x": r(screen_x, 4), "y": r(screen_y, 4)},
        "tileW": tw, "tileH": th, "elevStep": args.elev_step,
    }
    plain = f"{r(screen_x, 4)} {r(screen_y, 4)}"
    return emit(data, 1, "to-screen", args.json, plain)


def cmd_to_tile(args: argparse.Namespace) -> int:
    tw, th = args.tile_w, args.tile_h
    sx, sy = args.sx, args.sy
    hx, hy = tw / 2.0, th / 2.0
    tile_x = (sx / hx + sy / hy) / 2.0
    tile_y = (sy / hy - sx / hx) / 2.0
    data = {
        "screen": {"x": sx, "y": sy},
        "tile": {"x": r(tile_x, 6), "y": r(tile_y, 6)},
        "tileRounded": {"x": math.floor(tile_x + 0.5), "y": math.floor(tile_y + 0.5)},
        "tileW": tw, "tileH": th,
    }
    plain = f"{r(tile_x, 6)} {r(tile_y, 6)}"
    return emit(data, 1, "to-tile", args.json, plain)


# ---------------------------------------------------------------------------
# grid-svg
# ---------------------------------------------------------------------------
def cmd_grid_svg(args: argparse.Namespace) -> int:
    tw = args.tile_w
    extent = args.extent
    stroke = args.stroke
    projection = args.projection or "dimetric21"

    if projection == "true":
        # True iso: ground-axis slope tan(30). Half-height derived from tile width so
        # the diamond edges sit at exactly 30 deg from horizontal.
        th = tw * math.tan(math.radians(30.0))
    else:
        # dimetric21 / pixel: 2:1 => half-height = tileW/4 (slope 0.5).
        th = args.tile_h if args.tile_h is not None else tw / 2.0

    hw, hh = tw / 2.0, th / 2.0

    def to_screen(x: float, y: float) -> tuple[float, float]:
        return (x - y) * hw, (x + y) * hh

    # Compute bounds over the full grid so we can translate into positive space.
    corners = [to_screen(x, y) for x in (0, extent) for y in (0, extent)]
    min_x = min(c[0] for c in corners)
    min_y = min(c[1] for c in corners)
    max_x = max(c[0] for c in corners)
    max_y = max(c[1] for c in corners)
    pad = 2.0
    width = (max_x - min_x) + 2 * pad
    height = (max_y - min_y) + 2 * pad
    off_x = -min_x + pad
    off_y = -min_y + pad

    def pt(x: float, y: float) -> tuple[float, float]:
        sx, sy = to_screen(x, y)
        return sx + off_x, sy + off_y

    lines: list[str] = []
    for x in range(extent + 1):
        x0, y0 = pt(x, 0)
        x1, y1 = pt(x, extent)
        lines.append(f'  <line x1="{r(x0,3)}" y1="{r(y0,3)}" '
                     f'x2="{r(x1,3)}" y2="{r(y1,3)}"/>')
    for y in range(extent + 1):
        x0, y0 = pt(0, y)
        x1, y1 = pt(extent, y)
        lines.append(f'  <line x1="{r(x0,3)}" y1="{r(y0,3)}" '
                     f'x2="{r(x1,3)}" y2="{r(y1,3)}"/>')

    slope = hh / hw  # 0.5 dimetric, tan(30) true iso
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{r(width,3)}" height="{r(height,3)}" '
        f'viewBox="0 0 {r(width,3)} {r(height,3)}">\n'
        f'  <!-- isometric-ops grid: projection={projection} tileW={tw} '
        f'extent={extent} axis-slope={r(slope,5)} -->\n'
        f'  <g fill="none" stroke="{stroke}" stroke-width="1" '
        f'stroke-linecap="round">\n'
        + "\n".join(lines)
        + "\n  </g>\n</svg>"
    )
    # SVG is the data product -> stdout. No --json for this subcommand.
    print(svg)
    warn(f"grid-svg: {projection} tileW={tw} extent={extent} axis-slope={r(slope,5)}")
    return EX_OK


# ---------------------------------------------------------------------------
# transforms
# ---------------------------------------------------------------------------
def build_transforms() -> dict[str, dict[str, Any]]:
    rx = r(CSS_ROTATEX_DEG, 4)
    scl = r(CSS_SCALE, 5)
    sv = r(SSR_VERTICAL, 5)      # 0.86603
    figh = r(FIGMA_HEIGHT, 5)    # 0.57735

    # 2D affine plane matrices for the true-iso planes, unit basis mapped to screen
    # (y-down). Derived from projecting world x/y/z onto the iso ground axes at +/-30
    # deg with the 0.86603 vertical (cos 30) foreshortening. matrix(a,b,c,d,e,f) maps
    # (x,y) -> (a*x + c*y + e, b*x + d*y + f).
    cos30 = math.cos(math.radians(30.0))
    sin30 = math.sin(math.radians(30.0))
    # Top plane: world-x -> right-down axis (+30), world-y -> left-down axis (-30).
    top = [r(cos30, 5), r(sin30, 5), r(-cos30, 5), r(sin30, 5), 0.0, 0.0]
    # Left plane (facing left): x along the -30 ground axis, y is vertical.
    left = [r(cos30, 5), r(sin30, 5), 0.0, r(-1.0, 5), 0.0, 0.0]
    # Right plane (facing right): x along the +30 ground axis, y is vertical.
    right = [r(cos30, 5), r(-sin30, 5), 0.0, r(-1.0, 5), 0.0, 0.0]

    return {
        "css-3d": {
            "target": "css-3d",
            "css": (f"transform: rotateX({rx}deg) rotateZ(-45deg) "
                    f"scale3d({scl}, {scl}, {scl});"),
            "requires": "transform-style: preserve-3d on the element and its 3D children",
            "check": ("54.7356 = arctan(sqrt(2)) = 90 - 35.264; "
                      f"{scl} = sqrt(3/2) undoes the 0.81650 foreshortening"),
        },
        "css-top": {
            "target": "css-top",
            "css": f"transform: rotate(-30deg) skewX(30deg) scaleY({sv});",
            "check": "top plane; scaleY = cos(30) = 0.86603",
        },
        "css-left": {
            "target": "css-left",
            "css": f"transform: rotate(30deg) skewX(-30deg) scaleY({sv});",
            "check": "left-facing wall plane; vertical edges stay vertical",
        },
        "css-right": {
            "target": "css-right",
            "css": f"transform: rotate(-30deg) skewX(-30deg) scaleY({sv});",
            "check": "right-facing wall plane; mirror of left about the vertical",
        },
        "svg-top": {
            "target": "svg-top",
            "svg": f"matrix({top[0]} {top[1]} {top[2]} {top[3]} {top[4]} {top[5]})",
            "matrix": top,
            "check": ("unit x -> (cos30, +sin30) = (0.86603, 0.5) screen (y-down); "
                      "unit y -> (-cos30, +sin30) = (-0.86603, 0.5)"),
        },
        "svg-left": {
            "target": "svg-left",
            "svg": f"matrix({left[0]} {left[1]} {left[2]} {left[3]} {left[4]} {left[5]})",
            "matrix": left,
            "check": "unit x -> (0.86603, 0.5); unit y (up) -> (0, -1)",
        },
        "svg-right": {
            "target": "svg-right",
            "svg": (f"matrix({right[0]} {right[1]} {right[2]} "
                    f"{right[3]} {right[4]} {right[5]})"),
            "matrix": right,
            "check": "unit x -> (0.86603, -0.5); unit y (up) -> (0, -1)",
        },
        "illustrator": {
            "target": "illustrator",
            "note": ("SSR after a vertical scale of "
                     f"{sv} (cos 30). SRC-B misprints this once as 86.062 -- that is a "
                     "typo; the canonical value is 86.602%."),
            "top": f"scaleY {sv} -> shear +30 deg -> rotate -30 deg",
            "left": f"scaleY {sv} -> shear -30 deg -> rotate -30 deg",
            "right": f"scaleY {sv} -> shear +30 deg -> rotate +30 deg",
        },
        "figma": {
            "target": "figma",
            "note": ("Figma has no shear tool. Rotate the flat asset 45 deg, group it "
                     "(resets the bounding box to canvas axes), then set the group "
                     f"height to x{figh} (tan 30). Duplicate and rotate +/-60 deg for "
                     "the side planes."),
            "heightScale": figh,
            "sidePlaneRotationDeg": 60.0,
        },
    }


def cmd_transforms(args: argparse.Namespace) -> int:
    table = build_transforms()
    target = args.target
    if target not in table:
        return fail(f"unknown --target '{target}'. Valid: {', '.join(sorted(table))}",
                    EX_USAGE, args.json, "USAGE")
    block = table[target]
    plain_parts = [f"target: {target}"]
    for k in ("css", "svg", "top", "left", "right", "note", "check",
              "requires", "heightScale"):
        if k in block:
            plain_parts.append(f"{k}: {block[k]}")
    return emit(block, 1, "transforms", args.json, "\n".join(plain_parts))


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    epilog = (
        "EXAMPLES:\n"
        "  iso-math.py constants --projection true --json | jq '.data'\n"
        "  iso-math.py to-screen 3 5 --tile-w 64 --tile-h 32\n"
        "  iso-math.py to-screen 3 5 2 --tile-w 64 --tile-h 32 --elev-step 16\n"
        "  iso-math.py to-tile -64 128 --tile-w 64 --tile-h 32 --json\n"
        "  iso-math.py grid-svg --projection dimetric21 --tile-w 64 --extent 8 > g.svg\n"
        "  iso-math.py grid-svg --projection true --tile-w 128 --extent 4 > iso.svg\n"
        "  iso-math.py transforms --target css-3d\n"
        "  iso-math.py transforms --target svg-top --json | jq '.data.matrix'\n"
    )
    p = argparse.ArgumentParser(
        prog="iso-math.py",
        description="Isometric projection math: constants, transforms, grids, recipes.",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = p.add_subparsers(dest="command", metavar="<subcommand>")

    projections = ["true", "dimetric21", "pixel"]

    pc = sub.add_parser("constants", help="Emit the canonical constants table.")
    pc.add_argument("--projection", choices=projections,
                    help="Limit to one projection (default: all).")
    pc.add_argument("--json", action="store_true", help="Emit the JSON envelope.")
    pc.set_defaults(func=cmd_constants)

    ps = sub.add_parser("to-screen", help="tile (x,y[,z]) -> screen (2:1 dimetric).")
    ps.add_argument("x", type=float)
    ps.add_argument("y", type=float)
    ps.add_argument("z", type=float, nargs="?", default=0.0)
    ps.add_argument("--tile-w", type=int, required=True, dest="tile_w")
    ps.add_argument("--tile-h", type=int, required=True, dest="tile_h")
    ps.add_argument("--elev-step", type=float, default=None, dest="elev_step",
                    help="Screen px per z-step (default: tileH/2).")
    ps.add_argument("--json", action="store_true")
    ps.set_defaults(func=cmd_to_screen)

    pt = sub.add_parser("to-tile", help="screen (sx,sy) -> tile (inverse transform).")
    pt.add_argument("sx", type=float)
    pt.add_argument("sy", type=float)
    pt.add_argument("--tile-w", type=int, required=True, dest="tile_w")
    pt.add_argument("--tile-h", type=int, required=True, dest="tile_h")
    pt.add_argument("--json", action="store_true")
    pt.set_defaults(func=cmd_to_tile)

    pg = sub.add_parser("grid-svg", help="Emit an SVG grid for a projection.")
    pg.add_argument("--projection", choices=projections, default="dimetric21")
    pg.add_argument("--tile-w", type=int, required=True, dest="tile_w")
    pg.add_argument("--extent", type=int, required=True,
                    help="Grid size in tiles per axis.")
    pg.add_argument("--tile-h", type=int, default=None, dest="tile_h",
                    help="Override half-height source (dimetric only).")
    pg.add_argument("--stroke", default="#334155", help="Line color (default #334155).")
    pg.set_defaults(func=cmd_grid_svg)

    ptr = sub.add_parser("transforms", help="Emit an exact transform recipe/matrix.")
    ptr.add_argument("--target", required=True,
                     choices=["css-3d", "css-top", "css-left", "css-right",
                              "svg-top", "svg-left", "svg-right",
                              "illustrator", "figma"])
    ptr.add_argument("--projection", choices=projections, default="true")
    ptr.add_argument("--json", action="store_true")
    ptr.set_defaults(func=cmd_transforms)

    return p


def main(argv: list[str]) -> int:
    parser = build_parser()
    # Pre-validate tile-size / extent semantics before argparse type coercion errors
    # leak as tracebacks. argparse handles unknown flags/extra positionals as USAGE.
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:  # argparse already printed usage to stderr.
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    if not getattr(args, "command", None):
        parser.print_help(sys.stderr)
        return EX_USAGE

    as_json = bool(getattr(args, "json", False))

    # Domain validation of numeric inputs (positive tiles, non-negative extent).
    for attr, label in (("tile_w", "--tile-w"), ("tile_h", "--tile-h")):
        val = getattr(args, attr, None)
        if val is not None and val <= 0:
            return fail(f"{label} must be a positive integer, got {val}",
                        EX_VALIDATION, as_json, "VALIDATION")
    if getattr(args, "extent", None) is not None and args.extent <= 0:
        return fail(f"--extent must be a positive integer, got {args.extent}",
                    EX_VALIDATION, as_json, "VALIDATION")

    # Default elevation step for to-screen: half tile height (one z-step = one tile row).
    if getattr(args, "command", None) == "to-screen" and args.elev_step is None:
        args.elev_step = args.tile_h / 2.0

    try:
        return args.func(args)
    except ValueError as exc:
        return fail(str(exc), EX_VALIDATION, as_json, "VALIDATION")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
