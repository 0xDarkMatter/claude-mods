# Coordinates & Depth Sorting

The runtime math of an isometric world: converting between the logical **tile grid**
(cartesian, integer `x`/`y`) and the **screen** (pixels), picking the tile under the
cursor, and drawing everything back-to-front so near objects occlude far ones. This is
the code that runs every frame — get it right once and the whole map behaves; get the
anchor or the sort key wrong and sprites clip through each other for the rest of the
project.

> **Scope.** This file owns the coordinate transforms and depth-sorting doctrine for
> **tile-based** isometric worlds (the 2:1 dimetric family — commonly called
> isometric in games — and true-iso grids). The *projection geometry* (why 2:1,
> the exact angles, the plane matrices) lives in
> [`projection-math.md`](projection-math.md); the *asset spec* that pins tile W×H,
> anchor, and elevation-per-step lives in [`tile-spec.md`](tile-spec.md); engine-native
> tilemap nodes (Godot `TileMapLayer` Y-Sort, Unity `sortingOrder`) live in
> [`engine-integration.md`](engine-integration.md). Everything here is the raw math
> those wrappers hide.

All formulas below are parametrized by `tileW` and `tileH` (the on-screen width and
height of a single ground diamond in pixels). For **2:1 dimetric** `tileW = 2·tileH`
(e.g. 64×32, 128×64), which is what almost every tiled game uses. The formulas are
general — they hold for any `tileW:tileH` ratio, including true-iso grids where the
ratio follows `tan 30° = 0.57735` rather than exactly 0.5.

**Terminology note.** Throughout, "2:1 dimetric (commonly called isometric in games)"
is the 26.565° projection at a 2px:1px pixel step. After this first mention it is
"2:1 dimetric". See [`projection-math.md`](projection-math.md) for why the game-standard
projection is dimetric, not isometric.

---

## Contents

1. [Coordinate systems and conventions](#1-coordinate-systems-and-conventions)
2. [Tile → screen (the forward transform)](#2-tile--screen-the-forward-transform)
3. [Screen → tile (the inverse transform)](#3-screen--tile-the-inverse-transform)
4. [Worked numeric examples (64×32)](#4-worked-numeric-examples-6432)
5. [Elevation (the z axis)](#5-elevation-the-z-axis)
6. [Picking — the within-diamond test](#6-picking--the-within-diamond-test)
7. [Depth sorting doctrine](#7-depth-sorting-doctrine)
8. [The anchor-at-feet rule (and why center anchors break sorting)](#8-the-anchor-at-feet-rule-and-why-center-anchors-break-sorting)
9. [Multi-tile and oversized sprites — AABB in iso space](#9-multi-tile-and-oversized-sprites--aabb-in-iso-space)
10. [Moving platforms and multi-floor](#10-moving-platforms-and-multi-floor)
11. [Performance thresholds](#11-performance-thresholds)
12. [Reference snippets (pseudocode, JS, Python)](#12-reference-snippets-pseudocode-js-python)
13. [Sources](#13-sources)

---

## 1. Coordinate systems and conventions

Three coordinate frames are in play. Confusing them is the single most common source of
"my tiles are off by a diamond" bugs.

| Frame | Symbols | Units | Origin | Description |
|---|---|---|---|---|
| **Tile / grid** (cartesian) | `x`, `y` | tiles (integer or fractional) | tile `(0,0)` | The logical world. `x` increases toward the lower-right screen edge, `y` toward the lower-left. This is where game logic, pathfinding (A\*), and the map array live. |
| **Screen** | `screenX`, `screenY` | pixels | a chosen anchor pixel | Where you actually `drawImage`. **y-down**, matching every 2D canvas / DOM / engine viewport. |
| **Elevation** | `z` | z-steps (integer) | ground plane `z=0` | Height above the ground diamond. Lifts a sprite straight up the screen and is a **tie-breaker** in the sort key — never a horizontal offset. |

**Fixed conventions used in this file (state yours explicitly in your tile-spec):**

- **y-down screen space.** `screenY` grows downward. This is universal for canvas/DOM/
  engine viewports; the formulas below assume it. (Three.js/WebGL use y-up world space —
  that world is handled in [`threejs-orthographic.md`](threejs-orthographic.md), not here.)
- **Diamond-down tile layout.** Tile `(0,0)`'s top vertex sits at the screen origin;
  `+x` runs down-right, `+y` runs down-left. This matches Godot's *Diamond Down* layout
  and the canonical `(x−y, x+y)` transform.
- **Anchor at the visual feet.** The reference point of every sprite is the bottom of its
  ground contact, not its center. §8 explains why this is load-bearing.
- **Half-dimensions.** Because every term divides `tileW` and `tileH` by 2, precompute
  `halfW = tileW/2`, `halfH = tileH/2` once. For 64×32 that's `halfW=32, halfH=16`.

---

## 2. Tile → screen (the forward transform)

The canonical transform. A unit step in tile `x` moves half a tile right and half a
tile down; a unit step in tile `y` moves half a tile left and half a tile down. That is
exactly the diamond lattice.

```
screenX = (x − y) · tileW / 2
screenY = (x + y) · tileH / 2
```

Equivalently, with `halfW = tileW/2` and `halfH = tileH/2`:

```
screenX = (x − y) · halfW
screenY = (x + y) · halfH
```

**Ground-truth check.** Substitute the basis tiles at 64×32 (`halfW=32, halfH=16`):

| Tile `(x,y)` | `screenX = (x−y)·32` | `screenY = (x+y)·16` | Meaning |
|---|---|---|---|
| `(0,0)` | `0` | `0` | origin (top vertex of tile 0,0) |
| `(1,0)` | `+32` | `+16` | one step down-**right** ✓ |
| `(0,1)` | `−32` | `+16` | one step down-**left** ✓ |
| `(1,1)` | `0` | `+32` | straight down one full tile ✓ |

The `(1,0)` and `(0,1)` rows are the two ground-axis basis vectors: `(+halfW, +halfH)`
and `(−halfW, +halfH)`. Their slope magnitude is `halfH/halfW = tileH/tileW`. For a 2:1
tile that is `16/32 = 0.5` — the defining 2px-across : 1px-up pixel step. For a true-iso
grid it is `tan 30° = 0.57735`. That single ratio is the projection fingerprint; a grid
SVG's line slope must match it (see the `assets/grids/` verification in the skill).

This transform positions the tile's **origin vertex**. To draw a diamond *sprite* whose
image is `tileW × tileH`, blit its top-left corner at `(screenX − halfW, screenY)` so the
diamond's top vertex lands on `(screenX, screenY)` — or, more robustly, anchor by the
sprite's declared anchor point (§8) rather than a corner.

---

## 3. Screen → tile (the inverse transform)

Inverting the 2×2 system above (used for mouse picking, drag-drop, click-to-move):

```
x = ( screenX / (tileW/2) + screenY / (tileH/2) ) / 2
y = ( screenY / (tileH/2) − screenX / (tileW/2) ) / 2
```

With half-dimensions:

```
x = ( screenX/halfW + screenY/halfH ) / 2
y = ( screenY/halfH − screenX/halfW ) / 2
```

**Derivation (so you can re-derive it, not memorise it).** The forward map is a linear
system:

```
screenX = halfW·x − halfW·y
screenY = halfH·x + halfH·y
```

Divide the first by `halfW` and the second by `halfH`:

```
u = screenX/halfW = x − y
v = screenY/halfH = x + y
```

Then `x = (u + v)/2` and `y = (v − u)/2`. Substituting `u` and `v` back gives the
boxed formulas. The determinant of the forward matrix is `halfW·halfH − (−halfW·halfH)
= 2·halfW·halfH ≠ 0`, so the inverse always exists for a non-degenerate tile.

The result is **fractional** `x`, `y`. To get the integer tile you must `floor` — but a
naive floor of a fractional tile coordinate is *not* the same as the diamond the cursor
is inside near the diamond edges. §6 gives the correct within-diamond picking test.

**Numeric sanity check (must round-trip):** feed any `(x,y)` through §2 then §3 and you
must recover `(x,y)` exactly. Verified below.

---

## 4. Worked numeric examples (64×32)

`tileW=64, tileH=32 → halfW=32, halfH=16`. Forward then inverse; the inverse recovers the
original tile exactly (this is the round-trip the `iso-math.py to-screen` / `to-tile`
subcommands assert, and what the JS/Python snippets in §12 reproduce):

| Tile in | `to-screen` | `to-tile` back | Round-trip |
|---|---|---|---|
| `(0,0)` | `(0, 0)` | `(0, 0)` | ✓ |
| `(1,0)` | `(32, 16)` | `(1, 0)` | ✓ |
| `(0,1)` | `(−32, 16)` | `(0, 1)` | ✓ |
| `(3,2)` | `(32, 80)` | `(3, 2)` | ✓ |
| `(5,5)` | `(0, 160)` | `(5, 5)` | ✓ |
| `(10,7)` | `(96, 272)` | `(10, 7)` | ✓ |

**A non-integer pick.** Screen point `(48, 8)` at 64×32:

```
x = (48/32 + 8/16)/2 = (1.5 + 0.5)/2 = 1.0
y = (8/16 − 48/32)/2 = (0.5 − 1.5)/2 = −0.5
```

→ tile `(1.0, −0.5)`. The *integer* `x = 1.0` is the boundary signal here: in the
unit-square `(fx,fy)` space of §6 an integer coordinate lands exactly on a diamond
*edge*. The `y = −0.5` is the opposite — a mid-diamond value (its remainder `0.5` is the
diamond *center* on that axis, as far from an edge as you can get). So the cursor sits on
the shared edge between tiles `(0,−1)` and `(1,−1)` (both diamonds meet along `x = 1.0`),
and `floor(1.0, −0.5)` resolves it to `(1,−1)` — a correct, unambiguous pick.

The subtlety §6 warns about is not *this* clean case but the **float-noise** one: when a
computed coordinate should be an exact integer edge value but arrives as `0.9999997` or
`1.0000004`, `floor` can flip it to the wrong side of the seam — the off-by-one-diamond
picking bug. Snap near-integer results (or use §6's remainder test) before flooring at
the seams; don't trust raw floating-point equality on a boundary.

CLI equivalent (see `scripts/iso-math.py`):

```
iso-math.py to-screen 3 2 --tile-w 64 --tile-h 32     # → 32  80
iso-math.py to-tile   32 80 --tile-w 64 --tile-h 32   # → 3   2
```

---

## 5. Elevation (the z axis)

Elevation lifts a sprite **straight up the screen** — a pure vertical (`−screenY`)
offset. It is never a horizontal shift, because moving up in the world does not change
which ground tile you stand on.

Let `unitZ` be the pixels-per-z-step your tile-spec pins (a per-set constant — e.g. a
64×32 dungeon commonly uses `unitZ = 16`, i.e. one z-step = the tile's half-height, so a
wall block reads as one tile tall). Then:

```
screenX = (x − y) · halfW
screenY = (x + y) · halfH − z · unitZ        // subtract: up is −y in y-down space
```

`unitZ` belongs in the **spec**, not the code — it defines how tall a "floor" reads and
must be identical across every asset in a set or stacked blocks won't line up. Pin it in
[`tile-spec.md`](tile-spec.md).

**Elevation and sorting.** `z` does *not* enter the primary `(x+y)` sort key — two tiles
at the same `(x+y)` but different height still occupy the same screen column band, and
the higher one must draw *after* (on top of) the lower. So `z` is the **second** sort key
(§7). A common mistake is to fold `z` into the depth key as `x + y + z`; that makes a
tall object on a near tile incorrectly sort behind a short object on a far tile.

---

## 6. Picking — the within-diamond test

Reverse-projecting a screen point (§3) gives fractional tile coordinates. Turning those
into "which diamond is the cursor in" needs care at the diamond edges, where a plain
`floor` picks the wrong tile ~half the time along the seams. Two robust methods:

### Method A — floor + local-remainder test (analytic, exact)

Work in the tile's local diamond space. For screen point `(sx, sy)`:

```
// fractional tile coords
fx = ( sx/halfW + sy/halfH ) / 2
fy = ( sy/halfH − sx/halfW ) / 2

// candidate integer tile
tx = floor(fx)
ty = floor(fy)
```

Because the inverse transform maps the diamond onto the unit square in `(fx,fy)` space,
`floor` on both axes lands you in the correct diamond directly — the diamond's four
edges become the unit-square's four sides. This is the elegance of doing the test *after*
the inverse transform rather than in raw screen space: **no per-corner edge test is
needed.** The remainders `fx − tx` and `fy − ty` further tell you *where inside* the
diamond the cursor sits (useful for sub-tile snapping: `< 0.5 / ≥ 0.5` quadrants).

> This is why the inverse transform is written as the full linear solve and not an
> ad-hoc "divide screenX by tileW" — only the correct `/2` averaging step makes `floor`
> land in the right diamond.

### Method B — color / ID pick map (robust, O(1), art-tolerant)

For irregularly shaped or overlapping tiles where the math test is ambiguous, render an
off-screen buffer where each tile is filled with a unique color encoding its `(x,y)`
(or a monotonic tile ID). Read back the single pixel under the cursor and decode. This
sidesteps all edge math and handles non-diamond footprints, at the cost of a second
render target. Standard technique for editors and complex maps.

**Elevation-aware picking.** If tiles have height, the topmost *visible* surface under
the cursor may be an elevated tile, not the ground tile the math returns. Resolve by
casting from the cursor and testing candidate tiles from high `z` down, or use Method B
against the composited (post-elevation) frame.

---

## 7. Depth sorting doctrine

Isometric rendering is **painter's algorithm**: draw far things first, near things last,
so near occludes far. The whole game hinges on the sort key.

### The canonical sort key

Draw order key, in priority:

1. **`(x + y)` ascending** — the primary depth. Larger `x+y` is nearer the camera
   (lower on screen) and draws later (on top). This is the diagonal "wavefront" that
   sweeps from the back corner to the front corner.
2. **elevation `z` ascending** — tie-breaker for same-column stacks; the higher object
   draws after (over) the lower.
3. **explicit `layer` then `zBias`** — a manual override for authored exceptions
   (a decal that must sit over its tile, a bridge deck over the river beneath it). Keep
   `layer` coarse (`ground < props < overlay`) and `zBias` a small integer nudge.

```
sortKey = (x + y, z, layer, zBias)
```

Sort ascending on this tuple; render in that order.

### The nested-loop shortcut (regular grids only)

When every sprite occupies exactly one tile and nothing overlaps tile boundaries, you do
**not** need to sort at all — a back-to-front nested loop emits tiles in `(x+y)`-ascending
order for free:

```
for sum in 0 .. (W-1)+(H-1):          // each diagonal wavefront
    for x in max(0, sum-(H-1)) .. min(sum, W-1):
        y = sum - x
        draw(tile[x][y])
```

or the simpler double loop that also produces correct order for a full rectangular map:

```
for y in 0 .. H-1:
    for x in 0 .. W-1:
        draw(tile[x][y])            // each tile precedes both its front neighbours
```

The double loop works by a **local** invariant, not a global one. Its `(x+y)` sequence is
*not* monotone: a 3×3 map visits sums `[0,1,2, 1,2,3, 2,3,4]`, which drops at every row
boundary (2→1, 3→2). What makes it a correct painter's order is that every tile is drawn
*before* both of its front (nearer-camera) neighbours — the tile at `(x,y)` is emitted
before `(x+1,y)` (later in the same row) and before `(x,y+1)` (the next row), and those
two are the only tiles a static, non-overlapping single-tile grid can occlude it. Because
each tile precedes everything that can draw over it, the order is correct even though the
row-major traversal is *not* a global `(x+y)`-ascending sort. It is the cheapest correct
order for a static single-tile grid, and only for that case. **The moment you add
free-moving actors, multi-tile props, or elevation, this neighbour-adjacency guarantee
no longer holds — fall back to an explicit `(x+y, z, layer, zBias)` sort on the tuple
above.** (yal.cc, Packt.)

### Stability

Use a **stable** sort so equal-key sprites keep a deterministic order (insertion order,
or add the entity id as a final tuple element). An unstable sort makes coplanar sprites
flicker their z-order frame to frame.

---

## 8. The anchor-at-feet rule (and why center anchors break sorting)

**Rule: the sprite's anchor (its `(x,y)` reference point and its screen blit origin) is
the bottom of its ground contact — its visual feet — never its center.**

This is not a stylistic choice; it is what makes the depth sort correct. The sort key
uses the tile the object *stands on*. Depth is determined by where an object touches the
ground, because that is what decides whether it is in front of or behind another object.

**Why center anchors break it.** Consider a tall lamppost and a short crate, both drawn
with center anchors. The lamppost's center is high on screen (its bulk is above the
ground), so a center-based `screenY` sort places it *behind* the crate even when the
lamppost stands on a nearer tile. Result: the crate incorrectly draws over the base of
the lamppost, or the character walks and their head-height center makes them pop in front
of / behind objects at the wrong moment. Anchoring at the feet ties the sort to ground
contact, which is the only surface that determines occlusion.

**Consequences to encode in the tile-spec** (see [`tile-spec.md`](tile-spec.md)):

- The anchor is a named point in the sprite (e.g. `anchor = {x: halfW, y: spriteHeight −
  footOffset}`), pinned per asset, consistent across a set.
- Tall sprites (walls, trees) extend *upward* from the anchor into transparent margin;
  the transparent pixels above the feet do not affect the anchor.
- When you blit, subtract the anchor from the computed screen position:
  `blitX = screenX − anchor.x; blitY = screenY − anchor.y`.
- A "tile" and a "character" share the same anchor discipline so they sort against each
  other correctly.

If a sprite genuinely has no single ground-contact point (a floating platform), give it
an explicit `layer`/`zBias` and treat its *logical* footprint tile as the anchor
(§9–§10).

---

## 9. Multi-tile and oversized sprites — AABB in iso space

A single `(x+y)` scalar sorts *point* objects correctly. It fails for objects that cover
**more than one tile** (a 2×2 house, a 3×1 bridge, a long train car), because such an
object has no single `(x+y)` — it spans a range, and it can be simultaneously in front of
one neighbour and behind another.

**Doctrine: sort large sprites by their axis-aligned bounding box (AABB) in iso/tile
space, comparing overlaps, not by a single point.** (jwopitz "Absolute Isometric Depth
Sorting"; mazebert forum.)

Two workable strategies:

### Strategy 1 — decompose into per-tile cells

Treat a `W×H`-footprint object as its `W·H` component tiles for sorting purposes; draw
the whole sprite when its **frontmost** cell (max `x+y`, i.e. the ground cell nearest the
camera) comes up in the sort. This keeps the single-key sort but pins the object's draw
slot to its nearest ground contact. Cheap and correct for convex, axis-aligned
footprints — the common case (buildings, crates, floors).

### Strategy 2 — topological (pairwise) sort with iso-AABB overlap

When footprints interleave (an L-shaped wall partly in front of and partly behind a
column), a total order on a scalar key does not exist. Build a directed graph: for each
pair of sprites whose iso-space AABBs overlap in screen projection, add an edge "A must
draw before B" using the standard behind/in-front test:

```
A is behind B  if   A.maxTileX ≤ B.minTileX
                or  A.maxTileY ≤ B.minTileY
                or  A.maxZ     ≤ B.minZ
```

(each condition means A is entirely on the far side of B along one axis). Then
**topological-sort** the graph to get a valid draw order. This is the general,
always-correct method (used by Unity/Unreal iso plugins and Tiled-based renderers) and
degrades to the scalar sort when no footprints overlap. It is O(n²) in the pair test —
restrict it to sprites whose screen AABBs actually intersect (broad-phase first), or
cluster by grid region, to keep it cheap.

**Choosing:** use Strategy 1 by default (nearly all game props are convex axis-aligned
footprints); reach for Strategy 2 only where sprites genuinely interlock and Strategy 1
shows visible z-errors.

---

## 10. Moving platforms and multi-floor

Moving and stacked-floor elements are where naive `(x+y)` sorting visibly fails, because
a moving actor's `z`/floor changes its correct draw slot mid-motion. (Envato Tuts+
"Isometric Depth Sorting for Moving Platforms" is the definitive treatment.)

- **Moving actors on a moving platform.** Sort the platform and its rider together as a
  group, or re-parent the rider's logical tile to the platform's tile each frame so the
  shared sort key moves with them. A rider sorted independently against the world will
  pop through the platform edge as it moves.
- **Multi-floor / stacked buildings.** Add the floor index into the elevation term:
  `z = floorIndex · floorHeightSteps + localZ`. The `z` tie-breaker (§7) then keeps upper
  floors over lower ones. For a cutaway building (walls removed to see inside), authored
  `layer`/`zBias` overrides handle the "wall is in front but must be drawn transparent or
  omitted" cases — a rendering decision, not a sort decision (see cutaway conventions in
  [`style-guide.md`](style-guide.md)).
- **Bridges / overpasses.** The classic ambiguity: something can pass *over* one tile and
  *under* another. Model the bridge deck as an elevated multi-tile sprite (§9) with its
  own `z`; actors on the deck inherit the deck's `z`, actors beneath keep `z=0`. The
  standard sort then resolves both without special cases.
- **Engine reality.** In Godot 4, `Y-Sort` on a `TileMapLayer`/`Node2D` does the `(x+y)`
  ordering automatically off the node's `y` position (anchor at feet still required); in
  Unity it's `sortingOrder`. See [`engine-integration.md`](engine-integration.md) — this
  file is the math those features implement, for when you render manually or need to
  understand/override the engine's choice.

---

## 11. Performance thresholds

Small maps can brute-force everything. Past a size threshold, three techniques become
**non-negotiable**:

| Threshold | Technique | Why |
|---|---|---|
| **> ~50×50 tiles** | **Viewport culling** | Never transform/sort/draw tiles outside the visible frustum. Compute the visible tile-coordinate window from the camera's screen rect via the inverse transform (§3) on the four viewport corners, then iterate only that `(x,y)` range. Turns O(map) per frame into O(screen). |
| **> ~50×50 tiles** | **Chunking** | Partition the map into fixed chunks (e.g. 16×16 tiles). Cull, sort, and (optionally) pre-render each chunk to its own canvas/texture; redraw a chunk only when its contents change. Static ground chunks then blit as a single image. |
| **Many small sprites** | **Batching / texture atlas** | Every distinct source image is a draw-call/state-change; thousands of individual tile images tank the framerate. Pack all tiles into one **texture atlas** (a single sheet + a `{name → x,y,w,h}` map — see `scripts/sheet-pack.py`) so the whole visible set draws from one texture with minimal state changes. This is the single biggest win for tile-heavy scenes. |

**Atlas rationale in one line:** the GPU is fast at drawing many quads from *one*
texture and slow at *switching* textures — an atlas converts N texture binds into 1.
Pack with [`scripts/sheet-pack.py`](../scripts/sheet-pack.py); it emits the atlas PNG +
JSON the renderer indexes by frame name.

**Depth-sort cost at scale.** Sorting every sprite every frame is O(n log n); at 50×50+
that's wasteful when most tiles don't move. Sort only the *dynamic* layer (actors,
moving props) against a pre-sorted static ground, or maintain the sorted order
incrementally (only re-insert sprites that moved this frame). Combined with culling, you
sort dozens of movers, not thousands of tiles.

---

## 12. Reference snippets (pseudocode, JS, Python)

All three implementations below produce **identical** results and agree with the
canonical transforms in §2–§3 and with `scripts/iso-math.py` (`to-screen` / `to-tile`).
Copy the one matching your stack.

### Pseudocode (language-agnostic core)

```
halfW = tileW / 2
halfH = tileH / 2

function tileToScreen(x, y, z):
    screenX = (x - y) * halfW
    screenY = (x + y) * halfH - z * unitZ    // z: up is -y (y-down screen)
    return (screenX, screenY)

function screenToTile(screenX, screenY):     // ground plane (z = 0)
    x = (screenX / halfW + screenY / halfH) / 2
    y = (screenY / halfH - screenX / halfW) / 2
    return (x, y)                             // fractional; floor for the diamond

function pickTile(screenX, screenY):
    (fx, fy) = screenToTile(screenX, screenY)
    return (floor(fx), floor(fy))            // floor lands in the correct diamond (§6)

function depthKey(sprite):                    // ascending sort; stable
    return (sprite.x + sprite.y, sprite.z, sprite.layer, sprite.zBias)
```

### JavaScript

```javascript
// Isometric coordinate + depth utilities.
// Parametrized by tile pixel dimensions; 2:1 dimetric uses tileW = 2*tileH.
// Screen space is y-down (canvas/DOM). Agrees with scripts/iso-math.py.

function makeIso(tileW, tileH, unitZ = tileH / 2) {
  const halfW = tileW / 2;
  const halfH = tileH / 2;

  return {
    // tile (x,y,z) -> screen pixels; anchor subtraction is the caller's job (§8)
    tileToScreen(x, y, z = 0) {
      return {
        x: (x - y) * halfW,
        y: (x + y) * halfH - z * unitZ, // up is -y in y-down space
      };
    },

    // screen pixels -> fractional tile on the ground plane (z = 0)
    screenToTile(sx, sy) {
      return {
        x: (sx / halfW + sy / halfH) / 2,
        y: (sy / halfH - sx / halfW) / 2,
      };
    },

    // screen pixels -> integer tile under the point (within-diamond, §6 Method A)
    pickTile(sx, sy) {
      const t = this.screenToTile(sx, sy);
      return { x: Math.floor(t.x), y: Math.floor(t.y) };
    },
  };
}

// Depth sort: (x+y) asc, then z, then layer, then zBias. Stable via id fallback.
function sortByDepth(sprites) {
  return sprites
    .map((s, i) => [s, i])
    .sort((a, b) => {
      const [A, ia] = a, [B, ib] = b;
      return (A.x + A.y) - (B.x + B.y)
          || (A.z || 0)  - (B.z || 0)
          || (A.layer || 0) - (B.layer || 0)
          || (A.zBias || 0) - (B.zBias || 0)
          || ia - ib;              // stable tie-break
    })
    .map(([s]) => s);
}

// --- round-trip check (matches §4 table) ---
// const iso = makeIso(64, 32);
// iso.tileToScreen(3, 2);        // { x: 32, y: 80 }
// iso.screenToTile(32, 80);      // { x: 3, y: 2 }
```

### Python

```python
# Isometric coordinate + depth utilities (pure stdlib).
# Parametrized by tile pixel dimensions; 2:1 dimetric uses tile_w = 2*tile_h.
# Screen space is y-down. Agrees with scripts/iso-math.py to-screen / to-tile.
import math


def tile_to_screen(x, y, tile_w, tile_h, z=0, unit_z=None):
    """Tile (x, y, z) -> (screen_x, screen_y) in pixels. Up is -y (y-down)."""
    half_w, half_h = tile_w / 2, tile_h / 2
    if unit_z is None:
        unit_z = half_h
    screen_x = (x - y) * half_w
    screen_y = (x + y) * half_h - z * unit_z
    return screen_x, screen_y


def screen_to_tile(screen_x, screen_y, tile_w, tile_h):
    """Screen pixels -> fractional tile on the ground plane (z = 0)."""
    half_w, half_h = tile_w / 2, tile_h / 2
    x = (screen_x / half_w + screen_y / half_h) / 2
    y = (screen_y / half_h - screen_x / half_w) / 2
    return x, y


def pick_tile(screen_x, screen_y, tile_w, tile_h):
    """Screen pixels -> integer tile under the point (within-diamond, §6)."""
    fx, fy = screen_to_tile(screen_x, screen_y, tile_w, tile_h)
    return math.floor(fx), math.floor(fy)


def depth_key(sprite):
    """Ascending sort key: (x+y, z, layer, zBias). Use with a stable sort."""
    return (
        sprite["x"] + sprite["y"],
        sprite.get("z", 0),
        sprite.get("layer", 0),
        sprite.get("zBias", 0),
    )


# sprites.sort(key=depth_key)  # list.sort is stable -> coplanar order preserved

# --- round-trip check (matches §4 table) ---
# tile_to_screen(3, 2, 64, 32)   -> (32.0, 80.0)
# screen_to_tile(32, 80, 64, 32) -> (3.0, 2.0)
```

Python's `list.sort` / `sorted` are guaranteed stable, so `depth_key` needs no explicit
id tie-break; the JS `Array.prototype.sort` is stable in modern engines (ES2019+) but the
snippet adds the index tie-break belt-and-braces so coplanar sprites never flicker.

---

## 13. Sources

- **yal.cc — "Understanding isometric grids"** — the cleanest short treatment of the
  grid math and the nested-loop draw order. <https://yal.cc/understanding-isometric-grids/>
- **Pikuma — "Isometric Projection in Game Development"** (Gustavo Pezzi) — why 2:1 was
  chosen (integer steps, bit-shift `/2`) and the cart↔iso transform.
  <https://pikuma.com/blog/isometric-projection-in-games>
- **gamedevfaqs.com — "Converting Isometric Tile Coordinates To Screen Coordinates"** —
  `iso_to_screen(x,y,tw,th) = ((x−y)·tw/2, (x+y)·th/2)`, layered draw order, y-sort.
- **Packt — "Going Isometric"** — the classic `x_iso = x_cart − y_cart; y_iso =
  (x_cart + y_cart)/2` and its inverse, with an IsoHelper class.
- **Envato Tuts+ — "Isometric Depth Sorting for Moving Platforms"** — the definitive
  treatment of depth sorting with moving / multi-floor elements (Unity `sortingOrder`).
- **jwopitz — "Absolute Isometric Depth Sorting"** and **mazebert forum — "Isometric
  depth sorting"** — AABB-in-iso-space approaches for stacked / large sprites.
- **Kari Vierimaa — "Demystifying Isometric Projection in 2D Games (with Python!)"**
  (Medium) — Python transforms, good on the dimetric reality.
- Cross-references within this skill: [`projection-math.md`](projection-math.md)
  (angles, plane matrices, the projection decision), [`tile-spec.md`](tile-spec.md)
  (anchor / `unitZ` / footprint discipline), [`engine-integration.md`](engine-integration.md)
  (Godot Y-Sort, Unity `sortingOrder`), [`threejs-orthographic.md`](threejs-orthographic.md)
  (y-up world space, `scripts/sheet-pack.py` atlas consumption),
  [`style-guide.md`](style-guide.md) (cutaway conventions), and `scripts/iso-math.py`
  (the `to-screen` / `to-tile` CLI these snippets mirror).

> **Terminology reminder for citing files:** this doc's transforms are dimensionally
> identical for true-iso and 2:1 dimetric grids — only the `tileW:tileH` ratio differs
> (0.57735 vs 0.5). The *projection* choice is made first, in
> [`projection-math.md`](projection-math.md); the math here is downstream of it.
