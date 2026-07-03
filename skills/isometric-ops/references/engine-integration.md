# Engine Integration — Godot, Unity, Phaser, PixiJS, and Tiled

How to wire isometric/dimetric tile art into the engines and frameworks that actually
ship games. This file assumes the **projection decision** is already made (see
[projection-math.md](projection-math.md)) and the tileset already exists (see
[tile-spec.md](tile-spec.md), [pixel-art-workflow.md](pixel-art-workflow.md), or
[blender-prerender.md](blender-prerender.md)). It owns the *integration* delta only —
camera/tilemap/depth-sort configuration per engine — not asset creation.

> Terminology reminder: the tile grids described here are almost always **2:1 dimetric
> (commonly called isometric in games)** — see
> [projection-math.md](projection-math.md#mislabel-table) for the full disambiguation.
> Everywhere below that says "isometric" in a menu label or API name (Godot's
> `Tile Shape = Isometric`, Unity's "Isometric Tilemap") is the engine vendor's own
> (loose) terminology, not a claim that the math is true 30° isometric.

---

## 1. Godot 4 — `TileMapLayer`

Godot 4.3+ uses the `TileMapLayer` node (the pre-4.3 single `TileMap` node with multiple
layers was deprecated in 4.3 and is scheduled for removal in a future 4.x release —
verify against the version pinned in your project; if you're still on 4.0–4.2, the same
tile-set configuration applies to the legacy `TileMap` node's per-layer settings).

### TileSet configuration

1. Create or select a `TileSet` resource on your `TileMapLayer`.
2. In the TileSet inspector: **Tile Shape → Isometric**.
3. **Tile Layout → Diamond Down.** (Godot offers `Diamond Down` and `Diamond Right`;
   `Diamond Down` is the conventional choice — it matches the "top point, then widen
   left/right, then bottom point" diamond most 2:1 dimetric art assumes. `Diamond Right`
   rotates the same math 90° and is used for isometric layouts read top-to-bottom in
   the opposite screen direction.)
4. **Tile Size** — set to your tile module in pixels, e.g. **32×16** or **64×32** (the
   canonical 2:1 aspect from [projection-math.md](projection-math.md)). This is the
   *bounding box* of one diamond tile, not the sprite canvas size — oversized props
   (a tree, a building) still get authored on a larger canvas and placed via the
   TileMapLayer's per-cell offset/Y-sort, not by inflating the base tile size.
5. Godot computes the diamond hit-test and cell↔pixel mapping internally once
   `Tile Shape = Isometric` is set — you do not hand-write the `screenX/screenY`
   transform from [coordinates-depth.md](coordinates-depth.md) for placement; that
   transform is still what you reach for in a custom minimap, a non-Godot picking
   overlay, or when reasoning about layout before art exists.

### Y-Sort (draw order)

- Enable **Y Sort Enabled** on the `TileMapLayer` (or on the parent `Node2D`/`CanvasItem`
  that groups your tiles with dynamic sprites — characters, props that move between
  cells). Godot then reorders draw calls every frame by each node's *effective* Y
  position (global Y plus any `Y Sort Origin` offset you set per-node), not by tile
  index.
- **Anchor at the visual feet, never the sprite center.** This is the same doctrine as
  [coordinates-depth.md](coordinates-depth.md#anchor-at-feet): if a sprite's origin is
  its geometric center, a tall object (a tower, a tree) will Y-sort using a point that
  sits *above* where it visually touches the ground, and it will draw in front of
  objects that are actually nearer to camera. Set each `Sprite2D`'s offset/pivot so
  `(0,0)` in local space lands at the bottom-center visual contact point, or set
  `Y Sort Origin` explicitly to compensate.
- Y-Sort inside a `TileMapLayer` sorts *between tiles on that layer and other Y-sorted
  CanvasItems in the same Y-sort group* — it does not reach across separate, non-Y-sorted
  layers. Ground, props, and overlay layers still need an explicit z-index/layer order
  for the *layer* stacking (per [tile-spec.md](tile-spec.md)'s `layer` field:
  `ground | props | overlay`); Y-Sort resolves ordering *within* the dynamic layer.

### Reference

- Godot 4 docs: `https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html`
- Y-Sort: `https://docs.godotengine.org/en/stable/classes/class_canvasitem.html#class-canvasitem-property-y-sort-enabled`
- Stephan Bester, "Isometric tiles for a pixel art game in Godot 4.3" (Medium) — worked
  TileMapLayer + Diamond Down walkthrough (cited via SRC-A ch.3).
- Free practice tileset: `depth-strider/practice-iso-tiles` on itch.io, ships a
  step-by-step Godot 4.3 setup guide (cited via SRC-A ch.3).

---

## 2. Unity — orthographic camera + Tilemap checklist

Unity's Tilemap has isometric support (`Tilemap → Isometric` / `Isometric Z as Y`
grid types), but the camera and rendering settings around it are the part teams
consistently get wrong. Checklist, in the order you'll hit the problems:

| # | Setting | Value | Why |
|---|---|---|---|
| 1 | Camera → **Projection** | `Orthographic` | No perspective foreshortening; matches the flat-scale iso convention. |
| 2 | Coordinate plane | Build the map on the **XZ plane**, Y = up | Unity's own constants (`Vector3.up`, physics, lighting) assume Y-up. A 2D-style XY map fights the engine at every turn once you add real 3D lighting/shadows/physics. Convert 2D `(x, y)` tile data to `(x, 0, y)` world positions. |
| 3 | Camera → **Near Clipping Plane** | large negative, e.g. **−1000** to **−100000** | Orthographic cameras default to a `0.1` near-plane tuned for perspective cameras. Panning an iso camera with a small near-plane clips geometry that's technically "behind" the camera's z but still meant to render (a common symptom: buildings vanish when the camera pans past their origin). |
| 4 | `Edit → Project Settings → Quality` → **Shadow Projection** | `Close Fit` (not `Stable Fit`) | `Stable Fit` computes shadow cascades from the near/far clip planes. Once #3 pushes the near plane to a large negative number, `Stable Fit` produces wildly oversized/broken cascades. `Close Fit` recomputes tightly around visible geometry each frame instead. |
| 5 | Shadow cascades | **Disable** (`No Cascades`), and raise **Shadow Distance** to a large value (e.g. `10000`) | Cascades are a perspective-camera optimization (higher detail near camera, coarser far away) that doesn't map cleanly onto an orthographic view; disabling them plus a large shadow distance avoids shadows popping/clipping at cascade boundaries as the camera pans. |
| 6 | PBR / lighting | Verify the camera's **actual 3D world position**, not just its 2D-looking framing | Unity's PBR pipeline (specular, reflections) computes off the camera's real spatial position. If you built the rig by eyeballing a "looks isometric" angle without confirming the true 3D transform, reflections and specular highlights will look subtly wrong even though the silhouette reads as iso. Confirm in the Scene view that camera position/rotation match your intended rig (see the dual dimetric/true-iso rig table in [blender-prerender.md](blender-prerender.md) — the same two rotations apply to a live 3D Unity camera, not just a Blender render camera). |
| 7 | Draw order | `SpriteRenderer.sortingOrder`, driven by the same **(x+y) ascending** key from [coordinates-depth.md](coordinates-depth.md#draw-order) | Unity does not auto-sort by depth for 2D sprites; you compute `sortingOrder` (or `sortingLayer` + an order-in-layer) per the y-sort doctrine and assign it every frame an object moves. For moving platforms / multi-floor stacks, this is exactly the AABB-in-iso-space case in coordinates-depth.md, not a single-point sort. |

Kenney's free tilesets (see [asset-sourcing.md](asset-sourcing.md)) ship Unity-ready
samples alongside Tiled `.tmx` samples, useful as a known-good starting rig to diff
your own project's settings against.

Source: SRC-B "Setting Up an Orthographic Camera in Unity"; Envato Tuts+
"Isometric Depth Sorting for Moving Platforms" (SRC-A ch.2, sortingOrder treatment).

---

## 3. Phaser 3

Two paths, pick based on how much of the iso math you want Phaser to own for you:

### 3a. Isometric plugin

A community plugin family exists under the "Phaser 3 isometric/axonometric plugin"
name — `koreezgames/phaser3-isometric-plugin` is the commonly-cited example — providing
an `IsoSprite` game object, iso physics (`Arcade`-style AABB in iso space), and
cart↔iso projection helpers wired into the Phaser API (`this.add.isoSprite(...)`,
`this.iso.projector`). Its lineage traces to the Phaser-2-era
`lewster32/phaser-plugin-isometric`, the original `IsoSprite`/isometric-physics plugin
that the Phaser 3 forks in this space adapted forward. **Verify the plugin's current
npm/GitHub status before depending on it in a new project** — this is exactly the kind
of small-community plugin that can go quiet; check last-publish date and open issues,
not just star count. As of this writing (July 2026), `koreezgames/phaser3-isometric-plugin`
itself was last pushed 2018-11-07 (per the GitHub API) — nearly eight years stale despite
sporadic metadata updates since — so treat the whole "Phaser 3 isometric plugin" family
as dormant/unmaintained rather than active, and expect to patch or fork rather than
pull `latest`. If you adopt one anyway, pin an exact commit, not a version range.

### 3b. Manual cart↔iso (no plugin)

The lower-risk long-term choice for a production game: keep tiles as ordinary Phaser
`Image`/`Sprite` objects on a standard (non-isometric) Phaser scene, and do the
projection yourself using the exact transforms in
[coordinates-depth.md](coordinates-depth.md):

```js
// Tile (x, y[, z]) -> screen position, using the canonical 2:1 dimetric transform.
function tileToScreen(x, y, z = 0, tileW = 64, tileH = 32, elevStep = 16) {
  return {
    screenX: (x - y) * (tileW / 2),
    screenY: (x + y) * (tileH / 2) - z * elevStep,
  };
}
```

Set each sprite's `depth` (Phaser's explicit render-order property, distinct from
scene z-position) to the `(x + y)` y-sort key each frame an object moves, exactly per
[coordinates-depth.md](coordinates-depth.md#draw-order):

```js
sprite.setDepth(tileX + tileY);
```

Manual picking (screen→tile, for mouse/touch input) uses the inverse transform from the
same reference, including its within-diamond correction for the ambiguous
2×2-screen-tile overlap region.

Reference: Generalist Programmer, "Phaser Isometric Game Tutorial (2026)" — covers
cart→iso transform, tile rendering, depth sorting, mouse picking, and A* movement on
top of manual placement (cited via SRC-A ch.3).

---

## 4. PixiJS — Traviso.js and manual approaches

PixiJS has no first-party isometric mode; the ecosystem answer is **Traviso.js**, an
open-source isometric engine built on top of PixiJS (path-finding, tile-based scene
management, object placement — a fuller "engine" layer than the Phaser plugin above).
As with the Phaser plugin, check Traviso's current maintenance status before adopting it
for new work; it is a smaller, single-maintainer-style project historically, not a
Foundation-backed package.

For anything Traviso doesn't cover, or if you'd rather not add the dependency, PixiJS is
low-level enough that the manual approach in §3b (plain sprites + the
[coordinates-depth.md](coordinates-depth.md) transforms + `sprite.zIndex` with
`container.sortableChildren = true` for the y-sort key) applies directly — PixiJS's
`zIndex`/`sortableChildren` mechanism is the direct analogue of Phaser's `setDepth`.

Source: SRC-A ch.2/ch.3 (Traviso.js, 197 GitHub stars at time of source research; PixiJS
iso game repos under the GitHub `isometric` topic).

---

## 5. Tiled as interchange format

[Tiled](https://www.mapeditor.org/) is the de facto interchange format when a tileset
or level needs to move between tools/engines rather than live natively in one editor:

- Tiled supports an **Isometric** map orientation (menu name; the same "commonly called
  isometric" caveat applies — set your map's tile width/height to the 2:1 module, e.g.
  64×32, to get the dimetric grid) and a **Staggered**/**Hexagonal** family for other
  grid types, which this skill does not cover.
- Export path: author the tile layout in Tiled (`.tmx`/`.tsx`, or the JSON map format),
  then import into Godot (native Tiled-map importer plugins exist in the Asset Library),
  Unity (Tiled import packages, or hand-roll a `.tmj`→`Tilemap` loader), or a custom web
  renderer (the JSON format is a straightforward parse — object layers, tile layers, and
  properties all serialize cleanly).
- Kenney's free tile packs (see [asset-sourcing.md](asset-sourcing.md)) ship **both**
  Tiled and engine-native (Unity) samples for the same tileset — a good way to confirm
  your own Tiled export pipeline against a known-good reference before trusting it on
  original art.
- Tiled is the right interchange point specifically when: (a) level design happens in a
  tool separate from the target engine, (b) the same tileset needs to ship to more than
  one engine, or (c) you want a human-editable map format under version control that
  isn't a binary engine scene file.

---

## 6. Importing `sheet-pack.py` atlases — anchor/pivot mapping

[`scripts/sheet-pack.py`](../scripts/sheet-pack.py) packs a directory of tiles into one
spritesheet PNG plus a JSON atlas. The real schema (see that script's docstring/`--help`
for the authoritative version — this mirrors the TexturePacker/Phaser "hash" atlas
family, not a flat rect) is nested per frame:

```json
{
  "meta": { "...": "..." },
  "frames": {
    "<name>": {
      "frame":            {"x": 0, "y": 0, "w": 0, "h": 0},
      "sourceSize":       {"w": 0, "h": 0},
      "spriteSourceSize": {"x": 0, "y": 0, "w": 0, "h": 0},
      "sourceW": 0,
      "sourceH": 0,
      "trimmed": false,
      "rotated": false
    }
  }
}
```

`frame` is the packed rectangle (post-trim, if `--trim` was used). `sourceSize` is the
original untrimmed image dimensions. `spriteSourceSize` is where the trimmed frame sits
inside that original canvas — its `x`/`y` is the trim *offset* from the untrimmed
top-left. `sourceW`/`sourceH` are flat duplicates of `sourceSize.w`/`sourceSize.h`,
provided for importers that don't want to descend into the nested object — they alone
cannot recover the trim offset, only `spriteSourceSize` can.

Getting sprites to sit correctly once imported into an engine is entirely an
**anchor/pivot mapping** problem: the atlas records each frame's trimmed pixel rect, but
the engine needs to know *where in that rect the tile's logical anchor point is* — which,
per the [tile-spec.md](tile-spec.md) discipline, is the visual-feet point, not the frame
center.

General mapping recipe, engine-agnostic:

1. Author every source tile with its anchor at a **known, fixed offset** from the image
   bottom — e.g. "anchor = bottom-center of the untrimmed canvas" — and record that
   offset once in the tile spec, not per-tile.
2. When `--trim` removes transparent margin, recover the anchor position in the
   *trimmed* frame as:
   `anchor_in_frame = anchor_in_source − spriteSourceSize.{x,y}`
   (`spriteSourceSize.x`/`.y` is exactly the trim offset the packer cropped from the
   untrimmed top-left; `sourceW`/`sourceH` tell you the original canvas size but not
   which corner was trimmed from, so use `spriteSourceSize` for the offset itself, not
   the flat `sourceW`/`sourceH` aliases).
3. Feed that per-frame anchor into the engine's own pivot/origin field:
   - **Godot**: `Sprite2D.offset` (in local pixels, or normalize and use `centered =
     false` with an explicit offset).
   - **Unity**: `Sprite.pivot` (normalized 0–1 within the sprite rect) when slicing the
     packed PNG in the Sprite Editor — set pivot mode to "Custom" and enter the
     normalized coordinate.
   - **Phaser**: `Sprite.setOrigin(x, y)` (normalized 0–1).
   - **PixiJS**: `Sprite.anchor.set(x, y)` (normalized 0–1).
4. Verify by placing one test sprite at a known tile coordinate and confirming its feet
   land exactly on the tile-grid line the engine draws for debug/grid overlays — a
   half-pixel anchor error is invisible on a single sprite and only shows up as
   accumulated seam drift once dozens of tiles are placed, so check this once per new
   tileset before mass-placing.

If every tile in a set shares the same canvas size and anchor convention (the
[tile-spec.md](tile-spec.md) template enforces this), steps 1–3 reduce to one constant
offset applied uniformly at import time rather than a per-tile lookup.

---

## Related references

- [projection-math.md](projection-math.md) — the projection decision and mislabel table
  referenced throughout this file.
- [coordinates-depth.md](coordinates-depth.md) — the cart↔iso transforms and y-sort
  doctrine every engine integration ultimately reduces to.
- [tile-spec.md](tile-spec.md) — the anchor/footprint/naming discipline that makes
  atlas import (§6) a one-time constant instead of per-tile guesswork.
- [asset-sourcing.md](asset-sourcing.md) — Kenney and other CC0 packs used above as
  known-good reference rigs for Unity/Tiled.
- `scripts/sheet-pack.py` — produces the atlas format consumed in §6.
- `threejs-ops` skill — for a real-time 3D engine target instead of a 2D
  tile engine; see [threejs-orthographic.md](threejs-orthographic.md) for the iso-camera
  delta this skill owns on top of that sibling skill's general three.js scaffolding.
