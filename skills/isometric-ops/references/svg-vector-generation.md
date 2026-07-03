# SVG & Programmatic Vector Generation for Isometric Assets

Scope: libraries and hand-rolled techniques for producing isometric artwork as **vector
code** — SVG paths, CSS-driven DOM transforms, and diagram-editor primitives — rather
than pixel/raster output. This file is the library survey and the export pipeline; the
underlying plane matrices and angle derivations live in
[`projection-math.md`](projection-math.md) — link to them, don't restate them here.

For pixel-canvas (non-vector) isometric drawing, see
[`pixel-art-workflow.md`](pixel-art-workflow.md). For 3D-scene-to-sprite rendering, see
[`threejs-orthographic.md`](threejs-orthographic.md) (three.js) and
[`blender-prerender.md`](blender-prerender.md) (Blender). For DOM/CSS-only isometric
layout (no SVG), see [`css-isometric.md`](css-isometric.md).

**Projection first.** Every library below defaults to **true isometric** (30° ground
axes, 120° separation) unless stated otherwise — none of them natively emit **2:1
dimetric (commonly called isometric in games)** tile art. If your target is a tile
engine, generate the SVG at true-iso proportions for illustration use, or drive the
affine matrices yourself with the 2:1 dimetric constants from `projection-math.md` —
do not expect these libraries to produce game-tile-aligned output out of the box.

---

## 1. Decision table — which vector tool for which job

| Need | Tool | Why |
|---|---|---|
| Clean SVG isometric shapes, typed API, engineering/diagram precision | **`@elchininet/isometric`** | Actively maintained, TypeScript, SVG-native, Apache-2.0 |
| Declarative "just add data attributes to HTML" transforms | **`isometric-css`** | Zero imperative code; reads `data-*` attrs, applies CSS transforms at load |
| Diagramming/editor tool (nodes, links, interactive graphs) rendered in iso | **JointJS** | Full diagramming library; iso is a technique applied on top, not a primitive |
| Retro pixel-neat primitives (bricks, cubes, slopes) on `<canvas>` | **obelisk.js** | Still referenced for its exact pixel-neat renderer; **10 years stale — decoration only** |
| Simple "hello cube" canvas demos, lighting-shaded primitives | **Isomer.js** | Friendliest API for teaching/prototyping; **10 years stale — decoration only** |
| Hand-rolled control over every path/curve | **Raw SVG + the plane matrices** | No dependency; full control; more code to own |

The two "classic" libraries (obelisk.js, Isomer.js) and the modern pair
(`@elchininet/isometric`, `isometric-css`) solve different problems — the modern pair is
vector/DOM output for illustration and UI; the classic pair is pixel-canvas rendering.
Pick based on **output medium** (SVG/DOM vs `<canvas>` pixels) first, maintenance status
second.

---

## 2. `@elchininet/isometric` — SVG-native isometric library

**Package:** [`@elchininet/isometric`](https://www.npmjs.com/package/@elchininet/isometric)
on npm · source at [github.com/elchininet/isometric](https://github.com/elchininet/isometric).
Verified live against the npm registry (2026-07): **version 4.0.0, license Apache-2.0**,
written in TypeScript, ships both CJS (`index.js`) and ESM (`esm/index.js`) builds plus
a Node-specific entry point (`./node`, needs `jsdom` as a peer dependency for
server-side SVG generation without a browser DOM). This resolves the brief's contested
fact #2 — earlier survey material (SRC-A) lists a separately-named "Isometric.js" (46
GitHub stars, TS, SVG, last major update Dec 2021) as a *different*, less-maintained
project; do not confuse the two. `@elchininet/isometric` is the actively maintained one
and the one this skill recommends.

### What it models

The library's core abstraction is an **isometric canvas** onto which you place
**planes** (the visible faces of a 3D-looking object) built from **paths** — sequences
of moves in one of three plane orientations (top, right, left — matching the three
visible faces of a cube under true isometric projection). It does the projection math
internally so you author in a simple 2D-per-plane coordinate space and the library
emits the correctly transformed SVG.

### Basic usage pattern

```javascript
import {
  IsometricCanvas,
  IsometricGroup,
  IsometricPlane,
  PLANES
} from '@elchininet/isometric';

const canvas = new IsometricCanvas({
  container: '#scene',
  backgroundColor: '#F0F0F0',
  scale: 60
});

const cubeGroup = new IsometricGroup({ planes: 'TopLeftRight' });

const top = new IsometricPlane({
  planeView: PLANES.TOP,
  height: 1, width: 1,
  fillColor: '#EDC951',
  strokeColor: '#000000',
  strokeWidth: 2
});
const left = new IsometricPlane({
  planeView: PLANES.LEFT,
  height: 1, width: 1,
  fillColor: '#CC333F',
  strokeColor: '#000000',
  strokeWidth: 2
});
const right = new IsometricPlane({
  planeView: PLANES.RIGHT,
  height: 1, width: 1,
  fillColor: '#00A0B0',
  strokeColor: '#000000',
  strokeWidth: 2
});

cubeGroup.addChildren(top, left, right);
canvas.addChild(cubeGroup);
```

This produces a shaded cube face-set consistent with the **three-tone plane doctrine**
(top lightest, one side mid, one side dark — see [`style-guide.md`](style-guide.md)):
assign the top plane your lightest tone, one side plane your mid tone, and the
remaining side plane your darkest tone, matching a single fixed light direction across
every asset in a set.

### When to choose it

- You need SVG output that stays **editable** (paths, not baked pixels) for a design
  system, icon set, or diagram tool.
- You're generating isometric charts/dashboards/explainer graphics programmatically
  (data-driven SVG, e.g. rendering a warehouse layout from a JSON manifest).
- You want engineering-drawing precision — the library targets exactly this use case
  (its own description: "optimized for engineering drawings and responsive vector
  design systems").
- You're building **within a modern JS/TS toolchain** (bundler-friendly ESM export) and
  want a typed API rather than raw path arithmetic.

### When *not* to choose it

- Game tile art at 2:1 dimetric proportions — the library's projection is true
  isometric; retargeting it to 2:1 dimetric means overriding its internal scale
  parameters in ways the library isn't designed around. Use the raw affine matrices
  from `projection-math.md` instead, or bake pixel art per `pixel-art-workflow.md`.
- Photorealistic or heavily styled illustration — this is a geometric-primitive
  library, not a rendering engine. Pair it with hand-tuned fills/gradients or fall back
  to Blender/AI pipelines (`blender-prerender.md`, `ai-generation.md`) for that register.

---

## 3. Hand-rolled SVG — diamond, cube, and prism path recipes

When you need output the libraries above don't give you directly (custom curves,
non-cube footprints, tight file-size budgets, zero runtime dependency), construct the
paths yourself from the plane matrices already derived in `projection-math.md` §
"2D affine matrices for top/left/right planes." Do not re-derive those matrices here —
this section only shows how to turn them into `<path>` data.

### The three-plane decomposition

Any iso "box" (tile, cube, wall segment, prop) decomposes into up to three visible
rhombus/parallelogram faces: **top**, **left**, **right**. Each face is a unit square
in local plane space, mapped to screen space by the corresponding 2×2 matrix from
`projection-math.md`. For a unit cube at true isometric scale (100% "drawing" scale,
not the 81.65% "projection" foreshortening — see `projection-math.md` for that
distinction), the screen-space vertices work out to the classic hexagon-of-three-
rhombi silhouette.

### Diamond (single ground tile, top face only)

The ground-plane diamond used for a single game tile is the **top** plane transform
applied to a unit square, at whichever tile aspect you've chosen:

```
true isometric (illustration):  vertices at (0,0) (0.5, 0.2887) (0, 0.5774) (-0.5, 0.2887)
2:1 dimetric (game tile, tileW×tileH): vertices at (0,0) (tileW/2, tileH/2) (0, tileH) (-tileW/2, tileH/2)
```

As an SVG path (2:1 dimetric, `tileW=64`, `tileH=32`, origin at the top vertex):

```xml
<path d="M 0,0 L 32,16 L 0,32 L -32,16 Z" fill="#8B9A46" stroke="#000" stroke-width="1"/>
```

Generate this programmatically rather than by hand for any real tile set — see
`scripts/iso-math.py grid-svg` in this skill, which emits exactly this path shape at
any `--tile-w`/`--projection` combination and is the canonical ground truth to match
against.

### Cube / prism (three-plane box)

A cube of edge length `s` at true isometric drawing scale, with the top vertex at the
origin and axes matching the 30°/120° layout from `projection-math.md`:

```xml
<g id="cube">
  <!-- top face -->
  <path d="M 0,0 L 43.3,25 L 0,50 L -43.3,25 Z" fill="var(--tone-top)"/>
  <!-- left face -->
  <path d="M -43.3,25 L 0,50 L 0,100 L -43.3,75 Z" fill="var(--tone-left)"/>
  <!-- right face -->
  <path d="M 43.3,25 L 0,50 L 0,100 L 43.3,75 Z" fill="var(--tone-right)"/>
</g>
```

(`43.3 ≈ 50·cos(30°)`; this is the top-plane transform from `projection-math.md`
applied to a unit square scaled by `s=50`.) For an elongated **prism** (a wall, a
crate that's taller than it is wide), keep the top-face rhombus fixed and extend the
vertical run of the left/right faces by the extra height — the top-face math never
changes, only the height term in the side-face paths.

**Verification discipline:** whenever you hand-author a path like the above, check it
against `scripts/iso-math.py transforms --target svg-top` (and `svg-left`/`svg-right`)
for the numeric matrix, and against a unit-square round trip — the check vectors in
`projection-math.md` exist precisely so a hand-written path can be verified rather than
eyeballed.

### `matrix()` vs raw path coordinates

Two equally valid authoring styles:

1. **Bake the transform into path coordinates** (as above) — portable, no `transform`
   attribute needed, easiest to hand-edit vertex-by-vertex.
2. **Draw in local unit-square space, apply `transform="matrix(a,b,c,d,e,f)"`** using
   the exact matrix values from `projection-math.md`'s SVG `matrix()` equivalents —
   better when you're programmatically instancing many copies of the same base shape
   (stamp a `<use>` reference and vary only the matrix's translation terms).

Prefer (2) for anything you're generating in bulk (a tileset, a repeated prop); prefer
(1) for one-off hand-authored illustrations you'll hand-tune afterward.

---

## 4. `isometric-css` — declarative HTML-attribute transforms

**Package:** [`isometric-css` (elchininet/isometric-css)](https://github.com/elchininet/isometric-css)
— by the same author as `@elchininet/isometric`, but a different tool solving a
different problem: instead of generating SVG programmatically, it reads **declarative
HTML `data-*` attributes** on existing DOM elements and applies the CSS 2D/3D
transforms (`skew`, `scale`, `rotate`) needed to make them render isometrically, with
no imperative JavaScript required at the call site.

### When to choose it over the CSS recipes in `css-isometric.md`

`css-isometric.md` documents the *raw* CSS transform recipes (the `rotate/skewX/scaleY`
family and the `preserve-3d` stack) that you write and maintain by hand.
`isometric-css` is worth adding as a dependency when:

- You have **many** DOM elements needing the same class of iso transform and want a
  single declarative convention (`data-isometric="left"` etc.) instead of hand-copied
  CSS classes per element.
- You want the library to keep the transform math correct as you iterate on markup,
  rather than re-deriving `skewX`/`scaleY` values by hand each time.
- The project is markup-heavy (a marketing site, a component library) rather than
  canvas/SVG-heavy.

Skip it — and just write the CSS directly per `css-isometric.md` — for a handful of
one-off tiles/cards, or when you need tight control over exact transform-origin and
stacking-context behaviour that a declarative layer would obscure.

---

## 5. JointJS — isometric diagrams in a full diagramming library

[JointJS](https://www.jointjs.com/) is a general-purpose **diagramming and node-link
graph library**, not an isometric-specific tool — but it ships a documented technique
for rendering its diagrams in isometric perspective, described in the JointJS blog
post ["Isometric diagrams"](https://www.jointjs.com/blog/isometric-diagrams)
(verified live, 2026-07). The approach: JointJS elements are laid out on a normal 2D
canvas, then an isometric transform is applied to the SVG group containing the
diagram, exploiting the same top/left/right plane math as everything else in this
file — JointJS's contribution is the interactive diagram-editing layer (draggable
nodes, routed links, custom cell views) on top.

### When to choose it

Choose JointJS specifically when the deliverable is an **editable diagram/tool**
rather than static artwork — e.g. an internal warehouse-layout editor, a network
topology visualizer rendered in iso, a floor-plan tool where users drag rooms around
and the tool keeps the isometric perspective consistent. JointJS is dual-licensed
(open-source core plus a commercial Pro tier for advanced diagramming features) —
check current licensing at [jointjs.com](https://www.jointjs.com/) before committing a
production build to it.

Do **not** reach for JointJS just to draw static isometric illustrations or game
tiles — it's a full diagramming framework with a proportionally large footprint; the
plane matrices plus raw SVG (§3) or `@elchininet/isometric` (§2) are lighter and more
direct for that job.

---

## 6. Maintenance caveats — obelisk.js and Isomer.js

Both **obelisk.js** ([github.com/nosir/obelisk.js](https://github.com/nosir/obelisk.js))
and **Isomer.js** ([jdan.github.io/isomer](https://jdan.github.io/isomer/)) are
**roughly a decade stale** — obelisk.js's README still documents its "1.2.0 Release"
CommonJS rewrite as the newest news, and Isomer.js's last meaningful activity predates
most of the modern TypeScript tooling ecosystem. Both remain MIT-licensed and both
still work (they're small, dependency-light, and the isometric math they implement
doesn't change), which is why they still show up in tutorials and demos.

**Rule for this skill: decoration only, never games.** Acceptable uses:

- A one-off explainer graphic, a blog-post demo, a teaching example, a nostalgia
  effect (the well-known [jasonlong/isometric-contributions](https://github.com/jasonlong/isometric-contributions)
  browser extension, which renders a GitHub contribution graph as an interactive iso
  pixel model, is exactly this register).
- Server-side pixel rendering via `node-canvas` for a static, rarely-regenerated asset.

Unacceptable uses:

- Any shipping game or interactive tileset — an unmaintained rendering core is a
  liability the moment you need a new browser API, a security patch, or a performance
  fix that will never come. Use engine-native tilemaps (Godot 4 `TileMapLayer`, Unity,
  Phaser 3's isometric plugin) per [`engine-integration.md`](engine-integration.md), or
  hand-roll the transform yourself (§3 above, or `coordinates-depth.md`) with a
  dependency you actually control.
- Anything expected to receive ongoing feature work — there is no upstream to send a
  PR to that will plausibly get merged.

### obelisk.js's pixel-neat angle — resolving the ~22.6° vs 26.565° confusion

The brief's contested fact #1: sources disagree between "22.6°" and arctan(1/2) =
26.565° for obelisk.js's pixel stepping. **Verified against the obelisk.js README
directly** (github.com/nosir/obelisk.js, 2026-07): the library states its own angle as
**22.6°**, derived from its literal "1:2 pixel dot arrangement" — i.e. the actual
measured slope produced by its pixel-level line-rasterization algorithm, not the ideal
geometric ratio. This is numerically distinct from — and should not be conflated with —
the **26.565°** (`arctan(1/2)`) ground-truth angle used everywhere else in this skill
for "2:1 dimetric" tile geometry (see the canonical constants table in
`projection-math.md`). The obelisk.js README asserts 22.6° as the outcome of its
pixel-dot algorithm without publishing the exact derivation; treat that figure as
empirically/implementation-specific to the library's rasterizer rather than a value
you can re-derive from a clean arctan ratio the way 26.565° (`arctan(1/2)`) or 35.264°
(`arctan(1/√2)`) can be. **When citing an angle for 2:1 dimetric tile design, use
26.565° (the canonical figure).** Cite obelisk.js's 22.6° only when
specifically discussing obelisk.js's own rendering behavior, and always attribute it
to the library's README, not to "2:1 isometric" generally — conflating the two is
exactly the kind of mislabeling this skill exists to prevent.

---

## 7. Export & optimisation order

SVG produced by any of the above — or exported from Illustrator/Affinity/Figma per the
plane-matrix and SSR techniques in `projection-math.md` — degrades in one predictable
way if you skip steps: **"compressed but still bloated"**, where a cleanup pass shrinks
file size somewhat but the underlying path data stays fragmented (hundreds of tiny
segments instead of a few clean curves), because the artwork itself was never
simplified before export.

**The canonical order** (do not compress before you simplify):

1. **Simplify paths in the authoring tool** — reduce anchor points, merge redundant
   sub-paths, flatten unnecessary groups, *before* exporting. This is the step that
   actually removes path fragmentation; no downstream optimiser can undo poor
   authoring-time path hygiene.
2. **Export SVG** (or PNG, if you're producing a raster derivative alongside).
3. **Run [SVGO](https://github.com/svg/svgo)** (CLI/Node, MIT license — current major
   version 4.x as of 2026-07, verified against the npm registry) — the canonical
   automated SVG optimiser: strips editor metadata, collapses redundant groups,
   rounds coordinate precision, merges paths where safe. Or use
   **[SVGOMG](https://jakearchibald.github.io/svgomg/)**, the browser GUI built on the
   same SVGO engine, for one-off files or visually verifying the optimisation's effect
   before committing to a build-pipeline config.
4. **Compress raster derivatives** (any PNG/WebP/AVIF exports generated alongside or
   from the SVG) with a dedicated raster optimiser — ImageOptim (macOS, lossless,
   bundles SVG tooling too) or Tinify/TinyPNG (API-backed, cross-platform, good for
   CI pipelines) — SVGO does not touch raster data.
5. **Validate in-browser/devtools** — confirm the optimised SVG still renders
   identically (no clipped viewBox, no dropped `fill`/`stroke` inheritance from a
   collapsed group) and check the actual delivered byte size, not just "SVGO ran
   successfully."

This order preserves editability the longest (you still have clean, simplified source
paths if you need to revisit the artwork) and is the one order that reliably avoids
the bloated-after-compression failure mode. Skipping step 1 — running SVGO directly on
an unsimplified export — is the single most common cause of "why is this icon still
40KB after I ran SVGO."

For a config starting point, run SVGO with its default preset first and only add
custom plugin overrides (e.g. disabling `removeViewBox` if you rely on implicit
sizing, or `convertPathData`'s precision setting for very small icon grids) once you've
confirmed the default output visually.

---

## Related references in this skill

- [`projection-math.md`](projection-math.md) — the plane matrices, angle derivations,
  and numeric ground-truth checks that every recipe in this file builds on.
- [`css-isometric.md`](css-isometric.md) — DOM/CSS-only isometric layout (the sibling
  of `isometric-css` §4, for hand-rolled recipes).
- [`coordinates-depth.md`](coordinates-depth.md) — cart↔iso coordinate transforms and
  depth-sort doctrine, for when your SVG output represents a *scene* (multiple tiles/
  props) rather than a single illustration.
- [`pixel-art-workflow.md`](pixel-art-workflow.md) — the raster/pixel-canvas sibling
  workflow for 2:1 dimetric pixel art (obelisk.js's actual home turf, done properly).
- [`style-guide.md`](style-guide.md) — the three-tone plane-shading doctrine referenced
  in §2's cube example.
