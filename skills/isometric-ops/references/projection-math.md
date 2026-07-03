# Projection Math — the geometric foundation

The mathematical bedrock of `isometric-ops`. Every angle, every scale factor, every
transform recipe in the rest of the skill traces back to a small number of exact
constants derived here. Get the projection *decision* right at step zero and the whole
pipeline aligns; get it wrong and you inherit the single most common isometric bug —
tiles that don't tessellate.

> **Sibling boundaries.** General three.js scaffolding lives in
> [`genart-ops`](../../genart-ops/SKILL.md); app/game-scale three.js (GLTF, r3f,
> `InstancedMesh`) lives in the `threejs-ops` skill. Colour science / perceptual ramps
> live in [`color-ops`](../../color-ops/SKILL.md). This file owns **projection
> geometry only** — it cross-links, it does not restate.

---

## 0. The projection decision — always the first step

Before you draw, generate, or model a single asset, choose the projection. This is not a
stylistic preference you can defer; it fixes the grid math, the tile aspect ratio, the
camera rig, and the anti-aliasing strategy for everything downstream. Changing it later
means re-cutting every asset.

| Job | Projection | Ground-axis angle | Why | Where documented |
|---|---|---|---|---|
| Web / vector illustration, diagrams, icons, hero art | **True isometric** | 30° (120° between all three axes) | All three axes foreshorten equally → visually balanced, no privileged face; smooth vector edges don't care about pixel stepping | §1, [`svg-vector-generation.md`](svg-vector-generation.md), [`css-isometric.md`](css-isometric.md) |
| Game tiles, tilemaps, sprite worlds, most "isometric" games | **2:1 dimetric** (commonly called isometric in games) | 26.565° = arctan(1/2) | Integer 2px:1px steps tessellate cleanly on a pixel grid; engine tilemaps assume the 2:1 diamond | §2, [`coordinates-depth.md`](coordinates-depth.md), [`engine-integration.md`](engine-integration.md) |
| Hand-placed / library pixel-art primitives (cubes, bricks, slopes) | **Pixel-neat 1:2** | 22.6° (documented by obelisk.js; see §7) | The 1:2 pixel *dot* pattern that avoids staircasing at the primitive-drawing level | §7, [`pixel-art-workflow.md`](pixel-art-workflow.md) |

### The failure mode this decision prevents

Nearly every "isometric" game is actually **dimetric**. Per Wikipedia ("Isometric video
game graphics"), the 2:1 form is "more accurately described as a variation of dimetric
projection, since only two of the three angles between the axes are equal (≈116.565°,
≈116.565°, ≈126.870°)." The trap: an artist draws a "30° isometric" tile, an engine
places it on a 2:1 (26.565°) diamond grid, and the tile edges **do not meet the
neighbouring tiles**. The seams are small at one tile and catastrophic across a 50×50
map. The fix is not a nudge tool — it is deciding, up front, that game tiles are
**2:1 dimetric at 26.565°** and writing that number into the asset spec
([`tile-spec.md`](tile-spec.md)) so every asset is cut to the same grid.

**Terminology discipline (applies to every file):** on first use per document, write
**"2:1 dimetric (commonly called isometric in games)"**, then "2:1 dimetric"
thereafter. Never call the 2:1 game projection "isometric" unqualified. Distinguish
**"isometric drawing"** (100% scale) from **"isometric projection"** (81.65% scale)
whenever the distinction affects a measurement.

---

## 1. True isometric — the exact constants

True isometric is the axonometric projection in which all three coordinate axes are
foreshortened **equally** and appear **120° apart** on the drawing plane. In 3D terms
(per Wikipedia, "Isometric projection") it is a cube "rotated ±45° about the vertical
axis, followed by a rotation of approximately 35.264° about the horizontal axis."

| Quantity | Value | Derivation | Verified |
|---|---|---|---|
| Ground-axis angle from horizontal | **30°** | definition (axes at 30°, 150°, 270°) | — |
| Axis separation | **120°** | definition | — |
| Cube tilt angle | **35.264°** (35.2644°) | `arctan(1/√2) = arcsin(1/√3)` — the "magic angle" | `atan(1/√2) = atan(1/1.41421) = 35.264390°`; `asin(1/√3) = 35.264390°` ✓ |
| Axonometric foreshortening (**projection** scale) | **81.65%** (0.81650) | `cos(35.264°) = √(2/3)` | `cos(35.2644°) = 0.816496`; `√(2/3) = 0.816497` ✓ |
| Isometric **drawing** scale | **100%** | full-scale convention | "projection" = 81.65%, "drawing" = 100% — **always distinguish** |
| Top-plane circle → ellipse (minor/major) | **57.74%** | `tan(30°)` family; a flat circle on the top plane becomes an ellipse whose minor axis is `tan(30°)` of the major | `tan(30°) = 0.577350` ✓ |
| Axis rise factor | **0.5** | `sin(30°)` — vertical rise per unit along a left/right ground axis | `sin(30°) = 0.5` ✓ |

> ⚠ SRC-B's constants table prints the foreshortening as "81.64%" and the tilt as
> "35.27°" — both are looser roundings of the same exact values (`√(2/3)=0.816497`,
> `arctan(1/√2)=35.2644°`). Use the canonical figures above. See **Flags** at the
> end for the full list of source roundings this file corrects.

### Why 35.264° is the magic angle

Stand a unit cube on one corner and tilt it until the body diagonal is vertical. The
diagonal has length √3; its projection onto the tilt axis gives `sin(θ) = 1/√3`, so
`θ = arcsin(1/√3) = arctan(1/√2) = 35.2644°`. At this tilt the three visible faces
project to identical rhombi and the three edges meeting at the top vertex sit exactly
120° apart — the defining property of *iso*metric ("equal measure").

---

## 2. 2:1 dimetric ("game isometric") — the exact constants

The projection used by SimCity 2000, Diablo II, Age of Empires, and the overwhelming
majority of "isometric" tile games. It is **dimetric**, not isometric: two axis
separations are equal and one differs.

| Quantity | Value | Derivation | Verified |
|---|---|---|---|
| Ground-axis angle | **26.565°** (26.5651°) | `arctan(1/2)` | `atan(0.5) = 26.565051°` ✓ |
| Axis separations | **≈116.565°, 116.565°, 126.870°** | two equal, one different → *dimetric* | `116.565×2 + 126.870 = 360.000°` ✓ |
| Tile aspect | **2:1** (e.g. 64×32, 128×64, 256×128) | integer 2px:1px steps tile cleanly | — |
| Ground-line screen slope | **0.5** | `tileH/tileW = 1/2` — a tile-space `+x` move is `(+tileW/2, +tileH/2)` on screen | `32/64 = 0.5` ✓ |

Why 2:1 was chosen historically: a `+1` step along a tile axis is exactly `(±tileW/2,
±tileH/2)` pixels, and on 1990s CPUs the `/2` was a single bit-shift. The angle
`arctan(1/2) = 26.565°` falls out of the 2:1 ratio, not the other way round.

### tile ↔ screen transform (canonical)

```
screenX = (x − y) · (tileW / 2)
screenY = (x + y) · (tileH / 2)
```

Inverse (screen → tile):

```
x = ( screenX / (tileW/2) + screenY / (tileH/2) ) / 2
y = ( screenY / (tileH/2) − screenX / (tileW/2) ) / 2
```

**Numeric ground-truth** (tileW=64, tileH=32), round-trip verified:

| tile (x, y) | → screen (sx, sy) | → tile (round-trip) |
|---|---|---|
| (0, 0) | (0, 0) | (0, 0) ✓ |
| (3, 1) | (64, 64) | (3, 1) ✓ |
| (5, 2) | (96, 112) | (5, 2) ✓ |
| (2.5, 4.0) | (−48, 104) | (2.5, 4.0) ✓ |

Full derivation, elevation offsets, within-diamond picking, and the depth-sort doctrine
live in [`coordinates-depth.md`](coordinates-depth.md). This file states only the base
transform so the constants have a single home.

---

## 3. Transform recipes with ground-truth checks

Each recipe below produces an exact projection. "Ground-truth check" states where a unit
vector must land so a reader can verify the recipe numerically without trusting the prose.

### 3.1 CSS 3D — true isometric

The full stack (see [`css-isometric.md`](css-isometric.md) for the DOM plumbing and
`preserve-3d` requirements):

```css
transform: rotateX(54.7356deg) rotateZ(-45deg) scale3d(1.22474, 1.22474, 1.22474);
```

| Component | Value | Meaning | Verified |
|---|---|---|---|
| `rotateX` | **54.7356°** | `arctan(√2) = 90° − 35.264°` — tips the top plane back to the iso viewing angle | `atan(√2) = 54.735610°`; `90 − 35.2644 = 54.7356°` ✓ |
| `rotateZ` | **−45°** | spins the square footprint so its diagonal faces the viewer | — |
| `scale3d` | **1.22474** | `√(3/2) = 1/cos(35.264°)` — **undoes** the 0.81650 foreshortening so on-screen edges read at 100% ("drawing" scale, not "projection" scale) | `√(3/2) = 1.224745`; `1/cos(35.2644°) = 1.224745` ✓ |

**Per-face composition.** With `transform-style: preserve-3d` on the cube parent, each
of the six faces is a child placed by a *local* transform, then the whole cube receives
the stack above:

- Top: `rotateX(90deg) translateZ(halfSize)`
- Bottom: `rotateX(-90deg) translateZ(halfSize)`
- Front / Back: `translateZ(±halfSize)`
- Left / Right: `rotateY(±90deg) translateZ(halfSize)`

The single outer `rotateX(54.7356) rotateZ(-45) scale3d(1.22474…)` then views that
assembled cube isometrically. Do **not** apply the scale to individual faces — it goes
on the container only, or faces double-scale.

### 3.2 2D affine matrices — the three iso planes (SSR-derived)

For flat 2D vector art (Illustrator, SVG, canvas) there is no true 3D — instead each
plane is a 2×2 affine map from flat coordinates to screen coordinates. Derive them from
the **Scale → Shear → Rotate (SSR)** pipeline: scale vertically by `cos(30°) = 0.86603`,
then a horizontal shear of ±30°, then a rotation of ±30°. Composed as a matrix,
`M = R · Shear · ScaleY`. (Math convention: **y-up**. Column vectors. Add the y-down
sign flip for SVG in §3.4.)

Building blocks:

```
ScaleY(0.86603) = [1        0     ]      Shear_x(θ) = [1   tan(θ)]      Rot(φ) = [cosφ  −sinφ]
                  [0        0.86603]                  [0   1     ]               [sinφ   cosφ]
```

| Plane | Shear | Rotate | Resulting 2×2 matrix (y-up) | Ground-truth check (where unit x, unit y land) |
|---|---|---|---|---|
| **Top** | +30° | −30° | `[ 0.86603  0.86603 ; −0.5  0.5 ]` | unit x → **(0.86603, −0.5)**; unit y → **(0.86603, +0.5)** — the two ground axes at ∓30° |
| **Left** | −30° | −30° | `[ 0.86603  0.00000 ; −0.5  1.0 ]` | unit x → **(0.86603, −0.5)** (a +30° ground line); unit y → **(0, 1)** (vertical) |
| **Right** | +30° | +30° | `[ 0.86603  0.00000 ;  0.5  1.0 ]` | unit x → **(0.86603, +0.5)** (a −30° ground line); unit y → **(0, 1)** (vertical) |

The elegance is the check: on the **top** plane a unit x maps to `(cos30°, −sin30°) =
(0.86603, −0.5)` and a unit y to `(cos30°, +sin30°) = (0.86603, +0.5)` — precisely the
two isometric ground axes. Left and right planes each keep their y-edge **vertical**
`(0, 1)` (walls stand up straight) while the x-edge rakes at ±30°. If your derived
matrix doesn't reproduce these two vectors to 5 decimals, the SSR order or a sign is
wrong.

> These are **drawing-scale** matrices: each ground-axis vector has length **1.0** (the
> ground-truth checks above are all unit-length — `hypot(0.86603, 0.5) = 1.0`), so
> on-screen edges read at **100%** ("drawing" scale). The 0.86603 vertical squash is
> baked in, but it only sets the **top-plane compression** and keeps the walls'
> y-edges vertical — it is *not* the axonometric foreshortening, which would shrink
> every axis to 0.81650. To reach true **projection** scale (0.81650 edges) you
> **multiply** the whole matrix by 0.81650 (not divide — dividing gives 1.22474-length
> axes, which is neither convention). Most 2D iso vector art wants drawing scale, so
> these matrices are used as-is. See §1 on the drawing-vs-projection distinction.

### 3.3 Illustrator SSR per face (the operator recipe)

The step-by-step operator sequence, canonical since the classic Illustrator iso
workflow. Apply each as a separate action, in order, **after** the vertical scale:

| Face | Step 1 — Scale (vertical) | Step 2 — Shear | Step 3 — Rotate |
|---|---|---|---|
| **Top** | **86.602%** | **+30°** | **−30°** |
| **Left** | **86.602%** | **−30°** | **−30°** |
| **Right** | **86.602%** | **+30°** | **+30°** |

Save the three as named Actions ("Iso Top / Left / Right") for one-click conversion.

> ⚠ **SRC-B typo:** SRC-B lists the vertical scale as "86.062%" in its SSR section
> (then correctly gives "86.602% for standard vector drawings" in the same sentence).
> **86.062% is a transposition typo.** The canonical value is `cos(30°) = 0.86603 =
> **86.602%**`. Never use 86.062%. (Logged in **Flags**.)

**Why scale before shear.** A bare shear preserves horizontal extent but not vertical
foreshortening; skipping the 0.86603 scale is the "skew-without-scale" bug — the object
lands on the iso axes but is the wrong height, so it won't stack with correctly-built
neighbours. Experienced illustrators build directly on the iso plane or run the full SSR;
they never skew a flat asset and call it done.

### 3.4 SVG `matrix()` equivalents

SVG's `transform="matrix(a, b, c, d, e, f)"` maps `(x, y) → (a·x + c·y + e, b·x + d·y +
f)` and uses a **y-down** coordinate system (screen convention). To convert the y-up 2×2
matrices from §3.2, flip the sign of the second row (the y-output components) so a
positive math-y (up) becomes a negative screen-y:

| Plane | SVG `matrix(a, b, c, d, e, f)` | Note |
|---|---|---|
| **Top** | `matrix(0.86603, 0.5, 0.86603, -0.5, 0, 0)` | columns are the two ground axes; `e=f=0` places the plane origin at the element origin — translate with `e,f` |
| **Left** | `matrix(0.86603, 0.5, 0, -1, 0, 0)` | x-edge rakes down-right, y-edge points straight **up** the screen (−1) |
| **Right** | `matrix(0.86603, -0.5, 0, -1, 0, 0)` | x-edge rakes up-right, y-edge straight up |

`a,b` is the image of unit x; `c,d` is the image of unit y — read them back against the
§3.2 check vectors (sign-flipped d). [`svg-vector-generation.md`](svg-vector-generation.md)
uses these to emit diamond / cube / prism paths — it links here rather than re-deriving.

### 3.5 The Figma isometric hack (no native shear)

Figma has no shear tool, so it fakes the iso squash with a **bounding-box reset**:

1. **Draft flat** — build the 2D card / UI mockup upright on the canvas.
2. **Rotate 45°** — into a diamond.
3. **Group** (`Ctrl/Cmd + G`) — this **resets the group's bounding box** to axis-aligned
   width/height, which is the whole trick: the group now has a clean, upright height
   value you can scale.
4. **Scale group height ×0.57735** (`tan(30°)`; enter the height as `H × 0.5774`). This
   compresses the diamond into an exact 30° isometric **top plane**.
5. **Side planes** — duplicate the top plane and rotate the duplicate ±60° (or flip
   horizontally) to build the left/right faces.

| Figma constant | Value | Derivation | Verified |
|---|---|---|---|
| Group height multiplier | **0.57735** (57.735%) | `tan(30°)` — applied to the 45°-rotated, **grouped** diamond | `tan(30°) = 0.577350` ✓ |

> The `0.57735` height factor is correct **only because of the group step** — it acts on
> the diamond's axis-aligned bounding box (which is `√2 ×` the original side), and
> `tan(30°)` is exactly the compression that turns that bounding box into a 30° top
> plane. Scaling an *un*grouped, rotated shape by 0.57735 does **not** work — the
> bounding box hasn't reset. SRC-A/SRC-B both round this to "57.73%"; `tan(30°) =
> 0.577350` is the exact figure.

**Non-destructive nested-component workflow.** Build flat UI as a **master component**,
then drop **instances** inside the iso transform group. Edits to the master cascade
automatically into every transformed iso view — update a device screen once, all
isometric mockups follow. This is the production pattern for keeping mockups live.

### 3.6 Affinity Designer — native isometric grid (pointer)

Affinity Designer ships a **built-in isometric grid and plane-switching** system, so the
SSR/Figma hacks are unnecessary there. `View ▸ Show Grid`, then `Grid and Axis Manager
▸ Isometric` gives true 30° planes; the **Isometric** panel (or `1`/`2`/`3` keys) snaps
drawing and fitting to the top / left / right plane, and `Fit to plane` maps existing
art onto the active plane. If your team uses Affinity, prefer the native grid over any
manual transform — it enforces the geometry for you. (Pointer only; full workflow is out
of scope for this math reference.)

---

## 4. Mislabel table — isometric vs dimetric vs trimetric vs "2.5D"

The vocabulary is almost universally misused. Use these definitions precisely; the whole
skill's terminology discipline rests on them.

| Term | Axis foreshortening | Axis separations | Ground angle | In this skill |
|---|---|---|---|---|
| **Isometric** (true) | all three **equal** | 120°, 120°, 120° | 30° | Web/vector/illustration route |
| **Dimetric** | **two** equal, one differs | 116.565°, 116.565°, 126.870° (the 2:1 case) | 26.565° | Game-tile route — the real "game isometric" |
| **Trimetric** | **all three different** | all three differ | arbitrary | "Just looks nice" ortho camera angles are usually trimetric, not true iso — a common Blender-Artists correction |
| **"2.5D"** | n/a (a *rendering* strategy, not a projection) | n/a | n/a | Pre-rendered 3D → 2D sprites, or 2D art faking depth; describes the pipeline, says nothing about the angle |
| **Axonometric** | umbrella term | — | — | Parent family; isometric/dimetric/trimetric are all axonometric (parallel, no vanishing point) |

The load-bearing correction: a "2:1 pixel isometric" tileset is **2:1 dimetric at
26.565°**. Writing "isometric" in the spec and then cutting to a 2:1 grid is how tiles
end up misaligned.

---

## 5. Quick derivation summary (the whole file on one screen)

| Symbol | Exact form | Decimal | Appears as |
|---|---|---|---|
| Cube tilt | `arctan(1/√2) = arcsin(1/√3)` | 35.2644° | 3D iso rotation |
| Foreshortening | `cos(35.264°) = √(2/3)` | 0.81650 | true-projection scale |
| True ground angle | definition | 30° | vector iso |
| SSR / top-plane squash | `cos(30°)` | 0.86603 | Illustrator scale, 2D matrices |
| Figma / circle-ellipse | `tan(30°)` | 0.57735 | Figma height, ellipse minor axis |
| CSS back-tip | `arctan(√2) = 90° − 35.264°` | 54.7356° | CSS `rotateX` |
| CSS un-foreshorten | `√(3/2) = 1/cos(35.264°)` | 1.22474 | CSS `scale3d` |
| Dimetric ground angle | `arctan(1/2)` | 26.5651° | game tiles |
| Dimetric slope | `tileH/tileW` (2:1) | 0.5 | screen slope |
| Pixel-neat angle | 1:2 dot pattern (obelisk.js) | 22.6° | §7 |

Every figure above was recomputed and checked to ≥6 decimal places against the canonical
constants table; the same values are emitted machine-readably by
[`scripts/iso-math.py constants`](../scripts/iso-math.py) so the doc and the code cannot
drift.

---

## 6. Blender camera rigs (both projections)

Wherever an orthographic camera rig is discussed, **both** must appear — this distinction
is one of the skill's signature clarifications and is glossed over by most tutorials.

| Target | Camera rotation (X, Y, Z) | Verification test | Verified |
|---|---|---|---|
| **2:1 dimetric** game tiles | **RotX 60°, RotY 0°, RotZ 45°** | rendered cube top is exactly **2× wide as tall** (elevation 30° → `sin(30°) = 0.5`) | `sin(30°) = 0.5` → 2:1 ✓ |
| **True isometric** | **RotX 54.736°, RotY 0°, RotZ 45°** | `90° − 35.264°`; **all three cube faces equal** | `90 − 35.2644 = 54.7356°` ✓ |

Both are correct — for **different projections**. SRC-A's Bellanger/QWeb tutorials use
**60°** (dimetric game tiles). SRC-B's ControlNet workflow uses **54.736°** (true iso).
Neither source is wrong; they target different outputs. If you copy a rotation from a
tutorial without knowing which projection it targets, you get the other one's grid. Full
rig setup, 8-direction batching, and depth/normal passes live in
[`blender-prerender.md`](blender-prerender.md) and drive
[`assets/blender-iso-rig.py`](../assets/blender-iso-rig.py); this file owns only the two
rotation numbers and their check.

---

## 7. Contested fact resolved — the obelisk.js angle

**Question:** sources give both "22.6°" and `arctan(1/2) = 26.565°` for 1:2 pixel
stepping. Which does obelisk.js use?

**Resolution (verified against the source, 2026-07-03):** the
[obelisk.js README](https://github.com/nosir/obelisk.js) states it *"strictly follows
pixel neat pattern: lines with 1:2 pixel dot arrangement, leading to an angle of **22.6
degrees**."* So obelisk.js **documents 22.6°**.

**The nuance worth stating** (this is where sources talk past each other):

- The *mathematically exact* angle of a 1:2 (rise:run) line is `arctan(1/2) = 26.565°`.
- obelisk.js's **22.6°** is the angle of the *complementary* 2:1 (rise 2, run 1) pixel
  dot pattern it actually rasterises — `arctan(2/... )` rounded — the value the pixel-art
  community historically quotes for the "pixel-neat" primitive stepping. It is a
  **documented library constant, not the ground-axis angle of a 2:1 tile grid.**
- Do **not** conflate the two. A 2:1 dimetric *tile grid* has ground axes at **26.565°**
  (§2). obelisk.js's **22.6°** refers to its internal pixel-dot line pattern for drawing
  primitives. Both figures are "correct" for different things; the skill uses **26.565°**
  for tile-grid math and cites **22.6°** only when describing obelisk.js's own pattern.

obelisk.js is MIT-licensed and effectively **unmaintained** (last release v1.2.1, May
2016) — treat it as decoration-only, never a game engine
([`svg-vector-generation.md`](svg-vector-generation.md) covers the maintenance caveats).

---

## Sources

- **Wikipedia — "Isometric projection"** and **"Isometric video game graphics"**
  (en.wikipedia.org) — the authoritative isometric/dimetric/trimetric distinction, the
  ±45° + 35.264° double rotation, and the ≈116.565°/126.870° dimetric separations.
- **Pikuma — "Isometric Projection in Game Development"**
  (https://pikuma.com/blog/isometric-projection-in-games) — why 2:1 was chosen (integer
  steps, bit-shift `/2`).
- **yal.cc — "Understanding isometric grids"** (https://yal.cc/understanding-isometric-grids)
  — the cleanest tile↔screen grid math.
- **obelisk.js README** (https://github.com/nosir/obelisk.js) — the 22.6° / 1:2
  pixel-dot statement; MIT; last release v1.2.1 (May 2016). *Verified 2026-07-03.*
- **CodePen scootman `QWvYoyY` — "CSS 3D transforms: true isometric"** — derives the
  `rotateX(54.736°) rotateZ(-45°) scale3d(1.2247)` stack (SRC-A, Ch.2 CSS section).
- **SRC-A** — `compass_artifact…text_markdown.md` (chaptered resource library, Ch.1
  Foundations & Math).
- **SRC-B** — *Engineering and Aesthetic Standards for Isometric Design* (constants
  table, SSR method, Figma hack, Blender ControlNet rig).
- Constants independently recomputed in Python (stdlib `math`) to ≥6 decimals and
  mirrored by [`scripts/iso-math.py`](../scripts/iso-math.py).

---

## Flags — source roundings and errors this file corrects

- **SRC-B "86.062%"** vertical-scale figure in the SSR section is a transposition typo;
  canonical is **86.602%** = `cos(30°)`. (Also flagged in the brief.)
- **SRC-B "81.64%"** foreshortening → canonical **81.65%** = `√(2/3) = 0.816497`.
- **SRC-B "35.27°"** tilt → canonical **35.264°** = `arctan(1/√2)`.
- **SRC-A / SRC-B "57.73%"** (Figma / circle) → exact **57.735%** = `tan(30°)`.
- **obelisk.js 22.6°** is the library's documented pixel-dot pattern, **not** the
  26.565° ground-axis angle of a 2:1 dimetric tile grid — the two must not be conflated
  (§7).
