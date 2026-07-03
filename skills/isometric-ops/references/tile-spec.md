# The Tile Spec — the misaligned-tile vaccine

A **tile spec** is the written contract that every asset in a set must satisfy. It is the
single most effective defence against the most expensive and most common isometric bug:
tiles that were each drawn "isometric" but do not align when placed on a grid, because
each artist (or each AI generation) silently chose a slightly different angle, tile
height, anchor, or elevation step.

Write the spec **first** — before a single tile is drawn, rendered, or generated. Then
every downstream step (hand-drawing, Blender pre-render, AI generation, procurement) is
measured against it, and `scripts/tile-validate.py` mechanically enforces the parts a
machine can check.

> Boundary: this file owns the **spec discipline** — what to pin and why. The *numbers*
> you pin come from [`projection-math.md`](projection-math.md) (angles, ratios,
> transforms). The *runtime placement* rules — anchor-at-feet, y-sort draw order — are
> derived in [`coordinates-depth.md`](coordinates-depth.md). The *aesthetic* rules —
> three-tone plane shading, one light direction, palette ramps — live in
> [`style-guide.md`](style-guide.md). This file references those; it does not restate
> their derivations.

---

## Why an unspecified set drifts (the failure mode)

Every field below has a default that "looks fine" in isolation and breaks a set in
aggregate:

| Left unspecified | What each contributor picks | Aggregate failure |
|---|---|---|
| Projection / angle | 30° here, 26.565° there, "eyeballed 27°" elsewhere | Grid lines that don't meet; visible seams; roofs that miss walls |
| Tile W×H | 64×32 and 66×33 and 64×31 | Sub-pixel gaps and 1px overlaps that tile into moiré seams |
| Unit elevation (px/z) | 8px per step vs 16px | Stacked blocks float or intersect; stairs don't land on floors |
| Anchor position | center vs feet vs top-left | y-sort ordering flips; objects clip through each other |
| Footprint grammar | ambiguous 2×2 vs 2×1 | Multi-tile props overlap neighbours or leave holes |
| Bleed / transparent margin | trimmed tight vs padded | Atlas bleed artifacts; halos on scaled sprites |
| Light direction | top-left here, top-right there | Set reads as lit by many suns; no visual cohesion |

The vaccine is a spec that pins all of them, plus a validator that fails the build when a
tile violates the machine-checkable subset.

---

## What a tile spec MUST pin

Every field is mandatory. "Obvious" defaults are exactly what drift, so state them
explicitly even when they feel redundant.

### 1. Projection + exact angle (the first decision)

Name the projection and its exact ground-axis angle to at least 3 decimal places. Do not
write "isometric" unqualified — that word is the ambiguity this document exists to kill.

| Projection | Ground-axis angle | Use when |
|---|---|---|
| True isometric | **30°** (axes 120° apart; cube tilt 35.264°) | Vector/web illustration where clean pixel tessellation is not required |
| 2:1 dimetric (commonly called "isometric" in games) | **26.565°** (= arctan 1/2) | Game tiles / pixel art — integer 2px:1px steps tile cleanly |
| Pixel-neat 1:2 (obelisk-style primitives) | **26.565°** stepping, drawn as a 2px-across / 1px-up dot pattern | Programmatic pixel primitives on a canvas |

> obelisk.js reports **22.6°** for its 1:2 pixel-dot pattern (its README describes "lines
> with 1:2 pixel dot arrangement, leading to an angle of 22.6 degrees"). That is the
> pixel-stepping figure the library states for its projection, not the geometric ground-axis
> angle. The geometric ground-axis angle of a true 2px:1px step is
> `arctan(1/2) = 26.565°` — pin **26.565°** for the tiling grid. See
> [`projection-math.md`](projection-math.md) for the derivation and the contested-fact
> resolution.

**Rule: W = 2·H for any 2:1 dimetric set.** If your tile is 64 wide it must be 32 tall.
A spec that lists `128×64`, `64×32` is internally consistent; one that lists `64×30` is
already broken.

### 2. Tile dimensions — W × H

Exact integer pixels. For 2:1 dimetric, W must be even and H = W/2 (so the diamond's
half-steps land on whole pixels). Canonical modules: **64×32, 128×64, 256×128** (and
their halves 32×16). Pick **one** base module for a set and derive multi-tile footprints
from it — never mix 64×32 and 48×24 in the same set.

### 3. Unit elevation — pixels per z-step

How many vertical pixels one unit of height (one "level" / one z-step) occupies. This is
independent of tile W×H and is the field most often forgotten. A common convention ties
it to the tile: for a 64×32 tile, a full-height cube face is often the tile height
(**32px**) or half of it — but **state the number**, do not imply it. If a character is
one z-step tall and a wall is three, `unit_elevation_px × 3` must be an exact pixel count.

### 4. Anchor position

The pixel (or fractional coordinate) within the sprite that maps to the tile's logical
grid cell. **Anchor at the visual feet** — the bottom of the ground contact, horizontally
centered on the tile diamond — never the image center. Center anchors break y-sort depth
ordering; the *why* is in
[`coordinates-depth.md`](coordinates-depth.md#8-the-anchor-at-feet-rule-and-why-center-anchors-break-sorting).
Pin it as one of:

- a named convention: `bottom-center` (feet), or
- explicit offset: `anchor = (W/2, H_full − footprint_bottom_px)` in image pixels, or
- a normalized pivot: the value depends entirely on which corner is the origin, and
  engines disagree — so **state the origin next to the value**. For the feet
  (bottom-center) the pivot is `(0.5, 0.0)` with a **bottom-left** origin (Unity's
  normalized-pivot convention, where `SpriteAlignment.BottomCenter = (0.5, 0)`), or
  `(0.5, 1.0)` with a **top-left** origin. Never write a bare `(0.5, 1.0)`: under a
  bottom-left origin that is the *top-center* (the head), the exact inverted anchor this
  document exists to prevent.

### 5. Footprint grammar

The set of allowed ground footprints, in tile units, and how each maps to anchor + draw
order. Enumerate them:

- `1×1` — single-cell props, floor tiles.
- `2×1` / `1×2` — walls, fences, benches (occupies two cells along one axis).
- `2×2`, `3×3`, `N×M` — buildings, large machinery.

For any footprint larger than `1×1`, the spec must say the sprite is depth-sorted by its
**AABB in iso space**, not by a single anchor point (single-point sorting mis-orders
large sprites against small ones straddling them — see
[`coordinates-depth.md`](coordinates-depth.md#9-multi-tile-and-oversized-sprites--aabb-in-iso-space)).
State the reference corner the footprint grows from (conventionally the back/top cell of
the diamond).

### 6. Transparent margin / bleed rules

Two separate rules, both required:

- **Transparent margin**: how much empty transparent space is allowed around the art.
  Prefer **trim-to-content** (zero margin) for atlas packing efficiency, with the anchor
  expressed relative to the trimmed bounds. If a fixed canvas is required (e.g. for
  fixed-cell engines), state the exact canvas size and that the art is anchored, not
  centered.
- **Edge bleed**: whether opaque pixels are permitted to touch the outermost rows/columns.
  For trim-to-content tiles this is expected; for fixed-canvas tiles opaque pixels on the
  outer edge signal the art is clipped. State which regime applies. When packed by
  [`sheet-pack.py`](../scripts/sheet-pack.py), use its `--padding N` to add a gutter so
  bilinear filtering never samples a neighbour.

### 7. Palette tokens

Reference a named palette (a preset from
[`assets/palettes/three-tone-presets.json`](../assets/palettes/three-tone-presets.json)
or a project token set) and the **maximum colour count** per tile. A pinned `max_colors`
is both an aesthetic guardrail and a machine check: AI-generated tiles routinely smuggle
in hundreds of near-duplicate colours and anti-aliased fringes. Palette ramp construction
(perceptual OKLCH ladders) is [`color-ops`](../../color-ops/SKILL.md) territory; the
three-tone plane assignment (top lightest → sides mid/dark) is in
[`style-guide.md`](style-guide.md).

### 8. Light direction

**One** fixed light direction for the entire set (e.g. "sun from upper-left, ~45°
azimuth"), and which plane is therefore the top (lightest), the lit side (mid), and the
shadow side (dark). This is a spec field, not a per-tile choice — a set lit by
inconsistent light directions reads as incoherent no matter how good each tile is. The
shading doctrine is in [`style-guide.md`](style-guide.md).

### 9. Output format

Pin the delivery format and bit depth: **PNG-32 (RGBA, 8-bit/channel)** for raster
tiles; SVG for vector; whether pre-multiplied alpha is expected; colour profile (sRGB,
no embedded ICC unless required). If multiple resolutions ship (`@1x/@2x/@4x`), state the
base and that higher tiers are exact integer multiples rendered — **not upscaled** — from
the base.

### 10. Naming convention

A strict, greppable filename grammar. The recommended default:

```
name_direction_variant.png
```

- `name` — asset id in `kebab-or-snake` (be consistent), e.g. `crate`, `wall-brick`.
- `direction` — one of a fixed enum for directional sprites: `n e s w ne nw se sw`
  (or `0 1 2 3 4 5 6 7` if numeric), matching the Blender/three.js rotation order in
  [`blender-prerender.md`](blender-prerender.md) / [`threejs-orthographic.md`](threejs-orthographic.md).
  Omit for non-directional tiles, or use `_flat`.
- `variant` — palette/state/damage variant, e.g. `snow`, `lit`, `broken`.

Examples: `crate_se_default.png`, `wall-brick_flat_mossy.png`,
`hero_ne_walk-03.png`. A machine-parseable name lets `sheet-pack.py` group frames and
lets tooling reason about direction sets without a manifest.

### 11. Scale grammar

The set's *human-scale reference*: **one human figure = N tiles tall** (and, if relevant,
occupies a `1×1` footprint). Every other object's size is stated relative to this. A door
is "1.2 humans tall"; a truck is "3 tiles long, 1.5 humans tall". Without a scale grammar,
a set accumulates mixed-scale objects (a chair as tall as a car) that no amount of correct
projection can rescue.

---

## The fill-in TEMPLATE (copy verbatim)

Copy this block into `TILE-SPEC.md` at the root of any tileset and fill every field. Keep
it in the repo next to the art; it is the contract the whole set is measured against.

```markdown
# Tile Spec — <SET NAME>

version: 1.0
last-updated: YYYY-MM-DD
owner: <name / team>

## Projection
projection:        2:1 dimetric   # true-iso | 2:1-dimetric | pixel-1:2
ground_angle_deg:  26.565         # 30 (true iso) | 26.565 (2:1 dimetric)
notes:             "commonly called isometric in games; it is dimetric"

## Grid module
tile_w_px:         64
tile_h_px:         32             # MUST equal tile_w_px / 2 for 2:1 dimetric
unit_elevation_px: 16             # vertical px per z-step (height level)

## Anchor
anchor:            bottom-center  # feet, horizontally centered on the diamond
pivot_normalized:  [0.5, 0.0]     # (x,y) with pivot_origin below: feet = 0.0 y
pivot_origin:      bottom-left    # bottom-left | top-left  (engines disagree)
                                  # bottom-left → feet = [0.5, 0.0] (Unity BottomCenter);
                                  # top-left    → feet = [0.5, 1.0]

## Footprints (tile units)
footprints:        [1x1, 2x1, 2x2]
large_sort:        aabb-iso       # >1x1 sorted by iso-space AABB, not a point
footprint_anchor:  back-cell      # reference cell footprints grow from

## Margins & bleed
margin:            trim-to-content # trim | fixed-canvas
edge_bleed:        allowed         # allowed (trimmed) | forbidden (fixed canvas)
atlas_padding_px:  2               # gutter added by sheet-pack --padding

## Palette & light
palette_ref:       industrial-muted   # preset id or project token set
max_colors:        24                  # per-tile hard cap
light_direction:   upper-left-45       # ONE direction for the whole set
plane_order:       top>light-side>shadow-side

## Output
format:            PNG-32          # RGBA 8-bit/channel, sRGB, straight alpha
resolutions:       ["@1x", "@2x"]  # @2x is an exact 2x render, not upscaled

## Naming
name_grammar:      name_direction_variant.png
directions:        [n, e, s, w, ne, nw, se, sw]   # or "flat" if non-directional
variants:          [default, snow, night]

## Scale grammar
human_tiles_tall:  3               # one human figure = N tiles tall
scale_notes:       "door 1.2 humans; truck 3 tiles long x 1.5 humans tall"
```

The block is intentionally YAML-in-Markdown: human-readable in a diff, and trivially
parseable if you want to feed it to a linter. Keep comments — they carry the *why* that
stops the next contributor re-litigating a field.

---

## How the spec feeds `tile-validate.py`

Each machine-checkable spec line maps to a check in
[`scripts/tile-validate.py`](../scripts/tile-validate.py). The validator is the
enforcement arm of this document: it turns "the spec says 64×32" into a build-failing
assertion. It exits `0` when a tile conforms and `10` when it finds violations (per the
Resource Protocol), so it drops into CI as a gate.

| Spec field | Validator flag / check | Violation condition |
|---|---|---|
| `tile_w_px` / `tile_h_px` | `--tile-w N --tile-h N` dimension conformance | Image dimensions not equal to (or an exact multiple of) the tile module |
| `tile_h_px = tile_w_px/2` | implied by the two flags above | W ≠ 2·H for a 2:1 dimetric set |
| `max_colors` | `--max-colors N` | Distinct colour count exceeds N |
| `edge_bleed: forbidden` | edge-bleed check | Opaque pixels on the outermost rows/columns of a fixed-canvas tile |
| `margin` / halo hygiene | alpha-halo detection | % of semi-transparent (`0 < a < 255`) pixels above threshold — the AI-fringe signal |
| `anchor: bottom-center` | anchor heuristic | Lowest opaque row not roughly horizontally centered on the tile |

Fields the validator **cannot** check mechanically — projection angle intent, light
direction, palette *choice* (vs count), scale grammar, footprint semantics — remain
human-review items. The spec still pins them so a reviewer has a concrete rubric; see the
consistency checklist in [`style-guide.md`](style-guide.md).

### Wiring it into a build

```bash
# Validate every tile in a set against the spec's numbers, machine-readable output.
uv run scripts/tile-validate.py tiles/*.png \
  --tile-w 64 --tile-h 32 --max-colors 24 --json
# exit 0 = all conform ; exit 10 = at least one violation (fails CI)
```

Then pack the validated tiles into an atlas whose frame names and padding honour the same
spec:

```bash
uv run scripts/sheet-pack.py tiles/ --out atlas.png \
  --trim --padding 2 --pot
```

The `name_direction_variant.png` grammar (spec field 10) is what lets `sheet-pack.py`
produce a deterministic, name-sorted atlas whose frame keys are meaningful to the engine
importer described in [`engine-integration.md`](engine-integration.md).

---

## Spec review checklist (before a set is "locked")

1. Projection named with an **exact** angle to ≥3 decimals; the word "isometric" is
   never used unqualified.
2. `tile_h_px == tile_w_px / 2` for every 2:1 dimetric module (or angles/scales
   consistent for true iso).
3. `unit_elevation_px` stated and consistent — a 3-high wall is exactly `3 ×
   unit_elevation_px`.
4. Anchor is at the feet and identical across the set; pivot origin (bottom-left vs
   top-left) stated.
5. Every allowed footprint enumerated; large sprites flagged for AABB-iso sorting.
6. Margin/bleed regime chosen; atlas padding stated.
7. One palette preset, one `max_colors`, one light direction for the whole set.
8. Output format + resolution tiers pinned; higher tiers are rendered, not upscaled.
9. Filename grammar fixed and greppable; direction enum matches the render rig.
10. Scale grammar pins `human = N tiles`; no mixed-scale objects.
11. `tile-validate.py` runs green in CI against the pinned numbers.

---

## Sources

- Terminology, 2:1-vs-true distinction, and the alignment-bug rationale — Wikipedia
  *"Isometric video game graphics"* and *"Isometric projection"*
  (<https://en.wikipedia.org/wiki/Isometric_video_game_graphics>,
  <https://en.wikipedia.org/wiki/Isometric_projection>); Gustavo Pezzi, *"Isometric
  Projection in Game Development"*, Pikuma
  (<https://pikuma.com/blog/isometric-projection-in-games>).
- Anchor-at-feet and Y-sort depth ordering — Godot 4 `TileMapLayer` / Y-Sort docs; Envato
  Tuts+ *"Isometric Depth Sorting for Moving Platforms"*.
- Atlas bleed / padding rationale — texture-atlas bilinear-sampling practice (Kenney
  tileset conventions; general sprite-packing guidance).
- Constants (30°, 26.565°, 2:1 module) are pinned by this skill's canonical table; the
  derivations live in [`projection-math.md`](projection-math.md).
