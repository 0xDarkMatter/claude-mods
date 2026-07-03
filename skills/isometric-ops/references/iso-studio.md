# iso-studio — the Scene Composer App Manual

**iso-studio** is a zero-dependency, no-build isometric scene composer bundled with this
skill at `assets/iso-studio/` — exactly two runtime files, `index.html` (the entire app:
canvas, state, math, render, input, palettes, IO, all in one `<script>`) and `server.mjs`
(a Node-stdlib static file server, no npm install). It stages assets on a snap-to-grid
isometric canvas, sorts them automatically by depth, and exports PNGs, SVGs, and scene
JSON — plus a **blockout mode** that renders procedural grey volumes and exports
depth/lineart conditioning maps for the AI pipeline. This file documents what the app
**is**, verified against its source at `assets/iso-studio/index.html`: every hotkey,
palette, snap mode, and export option below is read from the running code, not the
original design brief.

For the coordinate math the app implements (tile↔screen, depth-sort doctrine,
anchor-at-feet), see [`coordinates-depth.md`](coordinates-depth.md) — iso-studio's `MATH`
section is a direct port of those formulas and is required to agree with them. For the
projection decision itself, see [`projection-math.md`](projection-math.md). For the
ControlNet workflow iso-studio's blockout export feeds, see
[`ai-generation.md`](ai-generation.md) §4.

---

## Contents

1. [Launch](#1-launch)
2. [Workspace tour](#2-workspace-tour)
3. [Projection and snap configuration](#3-projection-and-snap-configuration)
4. [Importing assets](#4-importing-assets)
5. [Placing and editing instances](#5-placing-and-editing-instances)
6. [Tint](#6-tint)
7. [Hotkey reference](#7-hotkey-reference)
8. [Scene JSON — save, load, schema](#8-scene-json--save-load-schema)
9. [Exports](#9-exports)
10. [Signature workflow: blockout → depth/lineart → ControlNet](#10-signature-workflow-blockout--depthlineart--controlnet)
11. [Known limits](#11-known-limits)

---

## 1. Launch

Node stdlib only — no `npm install`, no build step:

```
node assets/iso-studio/server.mjs        # then open http://localhost:4323
PORT=8080 node assets/iso-studio/server.mjs
```

`server.mjs` serves its own directory as the app root, with one exception: requests to
`/palettes/*` resolve one directory up, to `assets/palettes/`, so the app can `fetch()`
the shared [`three-tone-presets.json`](../assets/palettes/three-tone-presets.json)
without a copy living inside `iso-studio/`. A path-traversal guard confirms every
resolved path stays inside its serving root before reading it. Every response is sent
with `cache-control: no-store`, so editing `index.html` and reloading the browser always
picks up the change — there is no build step to forget to re-run.

Opening `index.html` directly via `file://` also works for basic editing, but the
preset fetch will fail silently (CORS blocks `fetch()` on `file://`) and the app falls
back to three built-in presets (`kenney-prototype-grey`, `blueprint`, `earthy-game`) —
run it through `server.mjs` to get the full 8-preset library.

Pattern precedent: `tools/svg-brand-tuner/` — the same zero-dependency, single-`<script>`
philosophy, scaled up to a full canvas editor.

---

## 2. Workspace tour

Three-column layout, no chrome beyond a 1px border and the accent colour:

| Region | Contents |
|---|---|
| **Left rail — asset tray** | Header, a thumbnail grid of imported assets (checkerboard-backed so transparency is visible), an "Import image…" file button, and a hint pointing at `?` for the hotkey legend. Click a thumbnail to arm it for click-to-place; the `×` badge (visible on hover) removes the asset and every instance that references it. |
| **Center — stage** | The `<canvas>` itself, a monospace status badge (top-left: active projection, tile size, snap mode, zoom %, hovered tile coordinate), and a floating zoom control (top-right: `−` / current % / `+`, click the % to reset to 100%). |
| **Right rail — docked palettes** | Five `<details>` accordions, all open by default: **Grid**, **Blockout**, **Inspector**, **Scene**, **Export**. Each is independently collapsible; the aesthetic (quiet neutral palette, one accent colour `#3d7f99`, no gradients, 1px borders) is shared with `tools/svg-brand-tuner`. |

The whole app is built on `Manrope, "Manrope", Inter, system-ui, -apple-system,
sans-serif` with **no Google Fonts `<link>` and no embedded font data-URI** — it degrades
to Inter or the OS UI font when Manrope isn't installed locally, and stays fully
offline-capable either way. Numeric readouts (tile coordinates, zoom %, the status badge)
use `font-variant-numeric: tabular-nums` so digits don't jitter as they change.

---

## 3. Projection and snap configuration

The **Grid** palette is the projection decision made concrete, per
[`projection-math.md`](projection-math.md) §1 — decide before you place anything:

| Field | Behaviour |
|---|---|
| **Projection** | `2:1 dimetric (game iso)` (default), `true isometric`, or `custom angle`. Switching type re-derives Tile H immediately via `applyProjectionConstraints()`. |
| **Tile W (px)** | Free for all three types; default 64. |
| **Tile H (px)** | **Locked** (disabled input) for `dimetric21` (forced to `tileW / 2`) and for `true` (forced to `round(tileW × 0.57735) / 100`, i.e. `tan 30°`). Only editable when Projection = `custom`. |
| **Ground angle (°)** | Hidden unless Projection = `custom`; free-typed 1–89°, default 26.565. For the two built-in types the angle is fixed metadata (26.565 or 30) and not user-editable — it isn't load-bearing for custom, either: the app doesn't derive tileW/tileH from `angleDeg` for `custom`, they're independent free fields. |
| **Extent X / Extent Y** | Grid width/depth in tiles, advisory (editor viewport bound, not a hard clamp on instance coordinates) — same contract as `scene-schema.json`'s `grid.extentX/extentY`. |
| **Snap** | A segmented control: `full` / `half` / `quarter` / `free`. Internally `SNAP_STEPS = { full: 1, half: 0.5, quarter: 0.25, free: 0 }`; `free` (step 0) disables snapping entirely and instances keep continuous fractional tile coordinates. |
| **Show grid + axes** | Toggles the diamond grid lines and the two coloured axis rays (red-ish `+x`, green-ish `+y`) from the origin. Rendering-only — has no effect on placement or export. |

A hint line under the controls restates the active projection's contract in one sentence
(e.g. "Tile H is locked to W/2 for clean 2px:1px stepping").

---

## 4. Importing assets

Three import paths, all landing in the asset tray as a new library entry:

1. **Drag-drop** — drop an image file anywhere on the app (`dragover`/`drop` are
   intercepted app-wide, not just over the tray). Files are filtered to `image/*`; a
   dropped URL (`text/uri-list`, e.g. an image dragged from a browser tab) is accepted
   too when no files are present.
2. **Clipboard paste** — `Ctrl+V` anywhere reads `image/*` items off `clipboardData`.
3. **File picker** — the "Import image…" button in the tray footer, `accept="image/*"`,
   `multiple` (import several at once).

Every path reads the file to a **data URI** (`FileReader.readAsDataURL`), not a file
path reference — this is deliberate: it makes a saved scene JSON self-contained (the
`asset.src` field is the image itself, not a link that can go stale), at the cost of
larger scene files. PNG, SVG, and WebP all work identically; the app does not
special-case SVG for placement (SVG assets get the same raster-style `<image>` treatment
on the canvas — SVG-specific handling only reappears at **export**, see §9).

**Anchor + footprint editing.** Every newly-imported asset gets the schema default
anchor `{x: 0.5, y: 1}` (bottom-centre) and footprint `{w: 1, h: 1}`. These are **asset
properties**, not instance properties — editing them in the Inspector's "Asset defaults"
block (§5) changes every placed instance of that asset at once. This is why anchor lives
on the asset, not the instance: a directional sprite sheet's eight frames should all
share one anchor rule.

**Why anchor-at-feet matters.** The anchor is the image-space point (normalized 0–1)
that lands on the instance's tile origin. iso-studio's depth sort and its screen
placement both key off this point — an anchor at the image center instead of the visual
feet will place the sprite correctly on screen but sort it *wrong* relative to
neighbours, because the sort key is derived from the tile the object's feet stand on,
not its visual bulk. See [`coordinates-depth.md`](coordinates-depth.md) §8, "The
anchor-at-feet rule (and why center anchors break sorting)," for the full lamppost/crate
worked example — iso-studio is a direct implementation of that doctrine, not just an
illustration of it.

---

## 5. Placing and editing instances

**Placement.** Click an armed tray thumbnail or Blockout primitive button, then click a
tile on the stage (`placeFromTray` / `placePrimitive`). The app **stays armed** after
placing — click again to place another copy — until you press `Esc` or arm something
else (arming is mutually exclusive: picking a tray asset disarms any armed primitive and
vice versa).

**Selection.**
- Click an instance to select it (replacing the current selection); `Shift`+click adds
  or removes it from a multi-selection.
- Click empty canvas and drag to **marquee-select** — any instance whose world-space
  bounding box intersects the marquee rectangle is added (or unioned with the existing
  selection if `Shift` is held at drag-start).
- Hit-testing walks instances **front-to-back** (reverse draw order) so the topmost
  instance under the cursor wins, using each instance's world AABB (`instBounds` /
  `primBounds`) — not per-pixel alpha.

**Moving.** Dragging a selected instance translates the pointer's world-pixel delta into
a tile-space delta via the inverse transform, then snaps every selected instance's tile
coordinate independently through the active snap step. The entire drag — from
pointer-down to pointer-up — is coalesced into **one** undo entry, not one per
intermediate frame.

**Nudging.** Arrow keys move the selection **1 whole tile**; `Shift`+arrow moves it by
one **screen pixel**, translated into a fractional tile delta via the same inverse
transform used for dragging. Rapid consecutive nudges of the *same* selection within
1.2 seconds merge into a single undo entry (`applyNudge`'s coalescing check), so tapping
an arrow key ten times to line something up produces one undo step, not ten.

**Flip.** `F` mirrors the selection horizontally (`flipX`). Flipping mirrors the anchor
point too (`ancX = (1 - anchor.x) × drawW` when `flipX` is set) so a flipped sprite still
anchors correctly at its feet. **Flipping a blockout ramp reverses its slope axis**
(rises along `−x` instead of `+x`); box, slab, and cylinder are procedurally symmetric,
so flipping them has no visual effect (see [Known limits](#11-known-limits)).

**Layers.** Every instance carries a `layer` of `ground` / `props` / `overlay`
(`LAYER_ORDER = {ground:0, props:1, overlay:2}`), set per-instance in the Inspector.
Newly placed instances (from tray or blockout) default to `props`.

**zBias.** `[` / `]` decrement/increment the selection's `zBias` by 1 — a manual
tiebreaker for the rare case two instances land on the same `(x+y, elevation, layer)`
key. Also editable numerically in the Inspector.

**Duplicate / delete.** `Ctrl+D` duplicates the selection, offsetting each copy by
`+1, +1` tile and wrapping the whole batch (however many instances are selected) in a
single undo step (`withBatch`). `Delete`/`Backspace` removes the selection.

**Undo/redo.** `Ctrl+Z` undoes, `Ctrl+Y` (or `Ctrl+Shift+Z`) redoes. History is a
command-pattern stack (`H.undo`/`H.redo`) capped at **100 entries** (the v2 spec called
for "≥50 steps" — the shipped limit is double that). Every mutation funnels through a
single `dispatch(type, payload)` entry point that computes an inverse *before* applying
the command, so every `COMMANDS` entry (add/remove/update instance or asset, set
projection/grid/canvas/palette) is automatically undoable — there is no separate
"remember to make this undoable" step for new mutation types, only the requirement to
extend `makeInverse` alongside `COMMANDS` when adding a new mutation kind.

**Selection details apply to multiple instances at once** for most Inspector fields
(tile X/Y, elevation, zBias, scale, layer, flipX all iterate `selectionInsts()`), but
footprint and anchor are **asset-level** fields — editing them in the Inspector always
edits the asset of the *first* selected instance, affecting every instance of that
asset scene-wide, not just the current selection.

---

## 6. Tint

Two independent tint layers, both implemented as a luminance→3-stop-ramp remap (the
`tools/svg-brand-tuner` `feComponentTransfer` technique, ported to canvas pixel
manipulation for raster assets and to a native SVG `<filter>` for vector export):

- **Scene tint** (Scene palette, "Scene tint (three-tone)" dropdown) — recolours every
  untinted instance in the scene through a preset's `ink → left → top` ramp. Presets
  load at boot from
  [`assets/palettes/three-tone-presets.json`](../assets/palettes/three-tone-presets.json)
  via `fetch("../palettes/three-tone-presets.json")`; if that fetch fails (no server,
  `file://`, moved file) the app falls back to three built-in copies
  (`kenney-prototype-grey`, `blueprint`, `earthy-game`) baked into `index.html` itself.
- **Per-instance tint** (Inspector, "Tint" colour swatch + "Clear tint" button) —
  overrides the scene tint for that instance only, building a synthetic 3-stop ramp by
  mixing the chosen hex toward black (62%) and white (72%). "Clear tint" reverts the
  instance to the scene tint (or native colours if no scene tint is set).

For raster assets, tinted bitmaps are cached per `assetId + ramp` in a `Map` bounded at
64 entries (cleared wholesale, not LRU-evicted, once exceeded) so the render hot path
never re-runs the luminance remap per frame. Blockout primitives don't need this cache —
their three-tone fills are computed directly from the active ramp on every draw call via
`effTones()`, since they're flat colour fills, not bitmaps.

---

## 7. Hotkey reference

Extracted verbatim from the in-app legend (press **`?`** to open it; `Esc` or the
backdrop click closes it):

| Input | Action |
|---|---|
| `Space`+drag | Pan the canvas |
| Middle-drag | Pan the canvas |
| Wheel | Zoom toward cursor (steps ×1.1 per notch, clamped 15%–800%) |
| Click | Select instance / place from tray or blockout |
| Drag | Move selection (snaps) / marquee-select |
| `Shift`+click | Add / remove from selection |
| Arrows | Nudge 1 tile |
| `Shift`+arrows | Nudge 1 pixel |
| `Ctrl`+`D` | Duplicate selection |
| `Ctrl`+`Z` | Undo |
| `Ctrl`+`Y` | Redo (also `Ctrl`+`Shift`+`Z`) |
| `F` | Flip selection horizontally |
| `Del` / `Backspace` | Delete selection |
| `[` / `]` | zBias down / up |
| `Esc` | Deselect / cancel placement |
| `?` | This legend |

All keyboard handling is suppressed while focus is inside an `<input>`, `<select>`, or
`<textarea>` (typing a tile coordinate into the Inspector won't accidentally trigger
`F` or `Del`) — except `Space`, which is only checked for pan-arming when not typing.

---

## 8. Scene JSON — save, load, schema

Scene files conform to [`assets/scene-schema.json`](../assets/scene-schema.json)
version `"1.0"` (draft-07 JSON Schema). iso-studio round-trips its **entire** in-memory
model through this format:

**Root fields** — `version` (fixed `"1.0"`), `meta` (`name`, `generator` — the app
stamps `"iso-studio 0.2.0"`, `modified` timestamp), `projection`
(`type`/`tileW`/`tileH`/`unitElevation`, plus `angleDeg` **only** when `type: "custom"`),
`grid` (`extentX`/`extentY`/`snap`/`visible`), `assets[]`, `instances[]`, `palette?`
(the active scene-tint preset name, omitted when none is set), `canvas`
(`bg`/`checkerboard`/optional `width`/`height`).

**`assets[]`** — each entry: `id`, `name`, `src` (a data URI for every asset iso-studio
itself imports — see §4), `anchor {x,y}`, `footprint {w,h}`, and `sourceW`/`sourceH`
when known. This mirrors the schema's `definitions.asset` exactly.

**`instances[]`** — each entry carries `id`, **either** `assetId` **or** `primitive`
(never both — the app writes whichever the instance has), `tile {x,y}`, `elevation`,
`layer`, `zBias`, `flipX`, `scale`, and conditionally `tint` / `opacity` (only written
when they differ from the default, keeping saved files lean). The `primitive` object
(`kind`, `w`, `h`, `height`) is the schema's `2026-07-03` extension — a scene with only
`assetId` instances is still valid under the same `"1.0"` version, and iso-studio treats
that extension as backward-compatible in both directions: `loadScene()` accepts files
with or without any `primitive` instances.

**Loading** (`loadScene()`) validates minimally but deliberately: it requires an object
with a `version` string starting `"1."` and a `projection` object, rejecting anything
else with a thrown, user-visible alert (`"Invalid scene JSON: …"`). It does **not**
run full JSON-Schema validation against `scene-schema.json` — it reconstructs the model
field-by-field with sane defaults for anything missing (e.g. a missing `grid` becomes
the default 16×16/full/visible grid), so a hand-edited or partially-authored scene file
loads best-effort rather than hard-failing on an incomplete document. Loading always:
re-hydrates every asset's `_img` (a fresh `Image()` per asset, `src` re-assigned so the
browser re-decodes it), clears both undo stacks (a loaded scene starts fresh history),
clears the current selection and any armed tray/blockout pick, and re-centers the
camera on the new content.

**Saving** (`btnSaveScene`) serializes the current model to pretty-printed JSON
(`JSON.stringify(..., null, 2)`) and downloads it as `<scene-name-or-"scene">.json` via
an in-memory Blob URL (no server round-trip — the whole save/load cycle is client-side).

---

## 9. Exports

All exports live under the **Export** palette and share a common **framing** step
(`exportFrame()`): if the Scene palette's Canvas W/H are both set, that fixed size wins
and content is centered within it; otherwise the export tightly crops to the world-space
bounding box of every placed instance (`contentBounds()`) — "Blank canvas size =
crop-to-content on export," per the Scene palette's own hint text.

| Export | Sizes | Notes |
|---|---|---|
| **PNG** | 1×, 2×, 4× | Transparent by default; honours an opaque scene background colour (the editor checkerboard itself is never baked in). Draws the full depth-sorted instance list through the same `drawInstance` path the live canvas uses. |
| **Depth map** | 1×, 2×, 4× | See §10 — near = white, far = black, ControlNet-conditioning grade. |
| **Lineart** | 1×, 2×, 4× | See §10 — black edges on white, ControlNet-conditioning grade. |
| **SVG** | single button, no scale options | **Gated** — see the eligibility rule below. |
| **Scene JSON** | — | Save/Load, §8. |

**SVG eligibility rule.** The "Export SVG" button is disabled unless **every** placed
instance qualifies: `svgEligible()` requires `S.instances.length > 0` and each instance
to be either a blockout `primitive` (always vector — emitted as native `<path>`/
`<polygon>`/`<ellipse>`) **or** a raster asset whose `src` starts with
`data:image/svg` — i.e., every non-primitive instance's *source asset* must literally be
an SVG. One PNG anywhere in the scene disables the button scene-wide; the disabled
button's `title` attribute explains why ("the scene contains raster (non-SVG) assets…")
so the constraint is discoverable without reading this doc. When eligible, export
composes vector primitives and tinted `<image>` references (tint becomes a native SVG
`<filter>` via `triToneFilterSvg`, deduplicated per unique ramp) into one self-contained
`.svg` file.

---

## 10. Signature workflow: blockout → depth + lineart export → ControlNet conditioning

This is the app's headline feature and the reason blockout mode exists at all: **stage a
scene's massing in iso-studio, export two conditioning maps, and hand them to a
ControlNet-based image generator** — the lightweight, web-native alternative to building
the same conditioning pair in Blender (full workflow:
[`blender-prerender.md`](blender-prerender.md) §3; the AI side:
[`ai-generation.md`](ai-generation.md) §4).

**Step 1 — Block out the scene.** Open the **Blockout** palette. Pick a primitive kind
— `box` (full rectangular volume), `slab` (thin box, default height 0.25 — a floor
plate), `ramp` (wedge rising along `+x` from `elevation` to `elevation + height`), or
`cylinder` (elliptical-cap volume inscribed in the footprint). Set Footprint W/H (tiles)
and Height (z-units), then click the grid to place; the tool stays armed for rapid
massing (`Esc` disarms). Every primitive renders with the same three-tone shading
convention as the rest of the skill — top lightest, one side mid, one side dark
(`PRIM_TONES`: top `#d8d6d0`, left `#a8a6a0`, right `#706e6a`) — and participates in the
normal depth sort and Inspector editing (footprint/height are per-instance for
primitives, unlike an asset's footprint which is shared across all its instances).

**Step 2 — Export the depth map.** Export palette → "Depth map (ControlNet, near =
white)" → pick 1×/2×/4×. The renderer fills the frame black, then for each instance
computes a **normalized depth value** from its primary sort key
(`(depthKey[0] − min) / span` across the scene, where `depthKey[0]` is the `(x+y)`
frontmost-cell sum) and maps it to a flat grey `rgb(g,g,g)` with `g = 48 + 207 × norm` —
nearer instances (larger `x+y`) render lighter, farther instances darker, and the floor
is kept off pure black (`g ≥ 48`) so geometry stays distinguishable from the background.
Image-sourced instances are flattened to a same-shape silhouette in that grey
(`silhouetteOf`); primitives are filled flat with no per-face shading and no stroke
(`mode: "flat"` — see [Known limits](#11-known-limits) on why this is massing-grade, not
per-face depth).

**Step 3 — Export the lineart map.** Export palette → "Lineart (ControlNet, black on
white)" → pick 1×/2×/4×. The frame starts white; primitives render white-filled with a
black stroke in normal painter's order, which gives correct hidden-line removal for free
(a nearer opaque primitive's white fill simply paints over a farther one's stroke).
Image-sourced instances get an outline by drawing eight 1px-offset black silhouettes
around each instance (approximating a dilate) and then re-drawing a white silhouette on
top, leaving just the outline ring.

**Step 4 — Feed both maps into ControlNet.** Load the depth PNG into a **Depth**
ControlNet unit and the lineart PNG into a **Lineart** (or **Canny/MLSD**, depending on
how hard-edged your primitives are) unit, per the parameters and prompt doctrine in
[`ai-generation.md`](ai-generation.md) §4 (Euler, ~15 steps, 768², CFG 7). Because both
maps come from the exact same scene and export frame, they stay in registration with
each other automatically — there's no separate camera-alignment step to get wrong, which
is the whole reason this route is lighter than the Blender depth+normal pipeline (no
normal pass, no camera rig to keep motionless between two renders — just re-click Export
twice).

**Step 5 — Generate, refine, vectorize.** Continue the AI pipeline as documented in
[`ai-generation.md`](ai-generation.md) §§4–5 and
[`ai-refinement.md`](ai-refinement.md) — upscale in the creative camp at
resemblance-high/creativity-low, vectorize if the deliverable needs to scale, and
re-import the finished art back into iso-studio as a tray asset to replace the blockout
stand-in at its exact tile position.

---

## 11. Known limits

Read this before treating any export as more precise than it is.

- **Depth export is per-instance flat grey, not per-face.** Every instance — image or
  primitive — gets exactly **one** grey value derived from its scene-level sort key. A
  primitive's three visible faces (top/left/right) are *not* individually shaded by
  distance in the depth pass the way `blender-prerender.md`'s true Z-pass shades every
  polygon by its own camera-space depth. This is a **massing-grade** depth cue (which
  object is in front of which) suitable for ControlNet's depth conditioning at
  scene-composition scale, not a per-pixel depth map with correct intra-object gradient.
  Don't expect a box's near corner to render lighter than its far corner.
- **Elevation IS folded into the depth export (as of v0.2), but only there.** The depth
  export normalizes on `depthScalar(inst)` = `depthKey(inst)[0] + elevation ×
  unitZ/(2·halfH)` — a raised block sits nearer the ortho camera, so higher reads whiter
  (one z-step counts half a tile-step of depth at the default 64×32 / `unitZ` 16). The
  *paint sort* is deliberately unchanged: `elevation` remains the secondary tiebreaker
  after `(x+y)` per [`coordinates-depth.md`](coordinates-depth.md) §7's doctrine (`z`
  breaks ties, never blended into the sort key). The scalar is still per-instance flat —
  don't read the depth export as a per-pixel elevation map.
- **`flipX` mirrors a ramp's slope; it is a no-op on the symmetric primitives.** A
  flipped **ramp** reverses its slope axis (rises along `−x`, tall edge at the `x = tx`
  side) consistently across canvas, depth, lineart, and SVG export — all four paths
  consume the same `primShape` geometry. **Box, slab, and cylinder** are left/right
  symmetric by construction, so flipping them changes nothing on screen or in export
  (the stored flag still round-trips through scene JSON). For image-sourced instances,
  flip mirrors both the sprite and its anchor.
- **SVG export is all-or-nothing per scene**, not per-instance — one PNG-sourced asset
  anywhere in the placed instances disables the SVG button for the whole scene (§9). To
  get an SVG export, every *placed* asset (not just every imported one — an unused PNG
  sitting in the tray doesn't block it) must be SVG-sourced.
- **Loading a scene does not validate against `scene-schema.json`.** `loadScene()` checks
  only `version` (must start `"1."`) and the presence of `projection`, then reconstructs
  the model field-by-field with defaults for anything absent. A structurally-invalid
  scene (wrong types, out-of-range values) can load without a schema-validation error and
  fail more confusingly later (e.g. at render or export) — validate scenes generated by
  external tooling against the schema *before* handing them to iso-studio if you need a
  hard guarantee.
- **The tint bitmap cache is a blunt 64-entry cap**, cleared entirely (not LRU-evicted)
  once exceeded — a scene that cycles through many asset+ramp combinations will
  periodically re-run the luminance remap for everything currently on screen. Not a
  correctness issue, just a performance one on very large, heavily-retinted scenes.

---

## Related

[`coordinates-depth.md`](coordinates-depth.md) (the math iso-studio implements) ·
[`projection-math.md`](projection-math.md) (the projection decision) ·
[`ai-generation.md`](ai-generation.md) §4 (the ControlNet workflow this app's blockout
mode feeds) · [`blender-prerender.md`](blender-prerender.md) §3 (the heavier,
Blender-based alternative to the same depth/normal conditioning idea) ·
[`style-guide.md`](style-guide.md) (the three-tone shading doctrine blockout primitives
follow) · [`../assets/scene-schema.json`](../assets/scene-schema.json) (the schema scene
files conform to) · [`../assets/palettes/three-tone-presets.json`](../assets/palettes/three-tone-presets.json)
(the tint preset library).
