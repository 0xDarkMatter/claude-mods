# Pixel-Art Isometric Workflow

Hand-authoring isometric pixel art for game tilesets: the pixel-stepping discipline,
the Aseprite toolchain, outline/dithering/seam craft, and how to measure curved shapes
in a projection that has none. This file owns the **pixel-art production workflow**;
the projection math it depends on lives in
[`projection-math.md`](projection-math.md) and [`coordinates-depth.md`](coordinates-depth.md) —
link to those rather than re-deriving angles here.

Source: SRC-A pixel-art section (`compass_artifact_wf-75a0e032-3465-48c7-84ea-e104bae213c2_text_markdown.md`).

---

## 1. Projection discipline: commit to 2:1 dimetric, not true isometric

Pixel-art tilesets are drawn in **2:1 dimetric (commonly called isometric in games)** —
never true 30° isometric. This is the first decision (see
[`projection-math.md` §1, the projection decision table](projection-math.md)) and it is
non-negotiable for pixel art specifically, for a reason true-iso vector work doesn't
have: **integer pixel stepping**.

- Ground-axis angle: **26.565°** (arctan(1/2), not 30°).
- Tile aspect: **2:1** — a tile that is 64px wide is 32px tall; 128px wide is 64px tall.
- Why: a line that steps **2 pixels across, 1 pixel up** repeated N times lands on an
  exact integer pixel every step. A line at true iso's 30° (tan 30° ≈ 0.57735 px up per
  px across) never lands on an integer pixel boundary — it drifts, forcing anti-aliased
  or blurry diagonal edges at every single tile seam. At pixel-art resolutions (a 64×32
  or 128×64 tile) that drift is visible immediately as a staircase that doesn't repeat
  cleanly, edge fringing between adjacent tiles, or a seam that "shivers" when the
  camera pans one pixel.
- This is why SimCity 2000, Diablo II, and Age of Empires all standardized on 2:1 rather
  than true isometric — it was chosen for exactly this alignment property (and it ran
  fast on 1990s hardware doing only integer pixel math), not because anyone mistook it
  for true isometric.

Write the exact angle and tile module into the asset spec before drawing a single
pixel — see [`tile-spec.md`](tile-spec.md). Every downstream tool in this file
(Aseprite's guide, Easymetric, the seam checks) assumes 2:1 unless you deliberately
choose a different integer ratio (4:1, 3:1 — rarer, steeper "true-iso-flavored" pixel
looks used by some strategy games, at the cost of taller sprite sheets).

### Why 30° lines staircase (the failure mode, concretely)

Draw a diagonal edge at true-iso's 30° in a pixel grid: the ideal line has slope
tan(30°) ≈ 0.57735 px vertical per px horizontal — an irrational, non-repeating ratio
in pixel space. Rasterizing it forces a **non-periodic** stair pattern: some steps are
1px, others 2px, with no small repeating unit. Two tiles butted edge-to-edge each
rasterize their shared boundary independently and the results don't match pixel-for-
pixel, so you get a hairline gap or overlap at the seam. At 2:1 (slope exactly 0.5),
the stair pattern is **2-across-1-up repeating forever** — deterministic, so every tile
drawn to the same module rasterizes its diagonal identically and seams close perfectly.

---

## 2. Aseprite workflow

[Aseprite](https://www.aseprite.org/) is the de facto standard pixel-art editor for
isometric tile production. Three techniques, in order of how most artists actually work:

### 2.1 Shift-pencil 2:1 live preview

Hold **Shift** while using the Pencil tool in Aseprite: this activates a live straight-
line preview constrained to common angle steps, and at pixel-art zoom the 2:1 diagonal
(2px across, 1px up) is one of the snap angles. Draw the diamond tile outline this way
first — it guarantees the top-plane diamond corners land on exact 2:1 boundaries before
you commit any interior pixels. This is the fastest, zero-plugin way to get a
pixel-perfect diamond and is the technique documented in SLYNYRD's Pixelblog 54.

### 2.2 Guide layers

Set up a dedicated **guide layer** (a normal layer marked non-exporting, or Aseprite's
reference-layer feature) containing:

- The full tile diamond outline at the target tile module (e.g. 64×32).
- A center cross-hair at the tile's screen-space center, matching the anchor convention
  from [`tile-spec.md`](tile-spec.md) (feet/base anchor, not visual center).
- Optionally, elevation gridlines if the tile is a multi-z-step object (a wall, a tree)
  so each z-step aligns to the same 1px-per-step-up cadence as the ground diamond.

Keep the guide layer at low opacity, lock it, and duplicate it into every new tile
document so every artist on a set draws against the identical grid — this is the
single highest-leverage habit for tile-seam consistency across a team.

### 2.3 Aseprite isometric guideline Lua script

Rokugatsua's **Aseprite isometric guideline script** (Lua, community blog) auto-
generates a 2:1 four-corner-pixel guide layer procedurally, parameterized by tile
width — faster than hand-drawing the guide layer above for a new tile module, and
guarantees the corners are computed (not eyeballed) at the exact 2px:1px ratio. Load
it via Aseprite's **File → Scripts → Open Scripts Folder**, drop the `.lua` file in,
then run it from the Scripts menu; it will prompt for tile width and draw the guide
onto a new layer in the active sprite.

### 2.4 Easymetric plugin (Oroshibu)

**Easymetric (Oroshibu)** is a purpose-built Aseprite plugin for isometric pixel art
production, going well beyond a guide layer. ⚠ Unverified as a shipped, linkable
product — public signals (an 80.lv writeup and Oroshibu's own mid-2025 social posts)
describe it as still in development ("easy isometric pixel art is still coming...
soon") as of the source date. Do not link to a specific product page until you have
verified a real release exists: check Oroshibu's itch.io profile
(itch.io/profile/oroshibu) or an official announcement for a live listing, and
date-stamp the check.

- **Colored and textured drawing modes** — paint directly onto iso-projected cube
  faces (top/left/right) with automatic perspective-correct placement, rather than
  manually shearing pixels by hand.
- **Auto-outline generation** — traces a consistent single-pixel outline around drawn
  shapes (see outline rules, §3 below) instead of hand-placing every border pixel.
- **Per-layer geometry** — each layer can represent a distinct 3D volume (a block, a
  slope, a step), composited by the plugin into the final iso projection, which keeps
  complex multi-part tiles (buildings, staircases) editable as separate pieces.
- **Dithering support** — built-in dither patterns for shading transitions that respect
  the pixel grid (see §3).
- **Animation support** — for animated tile elements (flags, water, machinery) within
  the iso projection.
- **`.obj` export** — exports the constructed geometry as a 3D mesh, useful for
  round-tripping into Blender for a pre-render pass (see
  [`blender-prerender.md`](blender-prerender.md)) or for generating a normal/depth map
  reference without hand-building the geometry twice.

Easymetric is the highest-leverage single tool for teams producing more than a handful
of iso pixel tiles — it replaces most of the manual shear/rotate/guide-layer discipline
below with a purpose-built editor, at the cost of a plugin dependency and its own
learning curve.

---

## 3. Outline, anti-aliasing, and dithering rules

Iso pixel art has its own house style conventions, distinct from general pixel art,
because tiles must remain legible and seam-clean at small sizes and must composite
against a checkerboard/other tiles without visible fringing:

- **Single-pixel outline.** Outline every silhouette edge with exactly 1px of a single
  dark ink color (see the three-tone doctrine and `ink` token in
  [`style-guide.md`](style-guide.md)). Do not vary outline weight — a 2px outline reads
  as a rendering error at tile scale, not a style choice, once tiles are laid out in a
  grid together.
- **No blanket anti-aliasing.** Full-shape anti-aliasing (soft edges everywhere) blurs
  tile-to-tile seams and defeats the alpha-halo checks in `tile-validate.py` (see
  [`ai-refinement.md`](ai-refinement.md) for the halo-detection rationale — the same
  check flags hand-drawn AA fringe, not just AI output). Instead use **selective
  anti-aliasing**: a small number of hand-placed intermediate-tone pixels only at
  shallow-angle curves (a shoulder on a rounded silhouette, a curb corner) where a
  strict 1px stairstep would look worse than a single blended pixel. Never anti-alias
  along the tile's own diamond boundary — that edge must stay a hard, opaque, exactly-
  2:1 stair so it tiles seamlessly against its neighbor.
- **Dithering** for shading transitions (not gradients): use an ordered dither pattern
  (checkerboard or Bayer-style, at the pixel-art scale a simple 2x1/1x2 alternating
  pattern) to transition between two flat shade tones on a plane, rather than
  introducing a third intermediate color that would blow the palette budget (see
  `--max-colors` in [`tile-validate.py`](../scripts/tile-validate.py) and the palette
  grammar in [`style-guide.md`](style-guide.md)). Dither only within a single plane's
  tone band (e.g. within the "top" tone), never across the top/left/right plane
  boundary — that boundary must stay a hard edge or the three-tone read collapses.

### Tile-seam hygiene

- Every tile's outer diamond boundary pixels must be **bit-identical in shape** across
  every tile in the set that shares that footprint — copy the guide-layer boundary,
  never redraw it freehand per tile.
- Decorative overhang (a roof lip, a canopy) that extends past the tile's own diamond
  footprint into a neighboring tile's visual space is allowed **only** if every
  neighboring tile in the set is drawn to tolerate that overhang (documented in the
  tile spec's footprint grammar — see [`tile-spec.md`](tile-spec.md)). An un-agreed
  overhang is a common cause of z-fighting/occlusion bugs at map-assembly time, not a
  drawing error — catch it at spec time, not QA time.
- Run [`tile-validate.py`](../scripts/tile-validate.py) (edge-bleed + alpha-halo checks)
  on every exported tile before it enters the atlas — the same script gates both
  hand-drawn and AI-generated tiles for exactly this class of seam defect.

---

## 4. Measuring iso shapes: circles, spheres, and the skew-to-plane trick

True circles and spheres have no direct isometric or dimetric equivalent — a circle
lying flat on the ground plane projects to an **ellipse**, and getting that ellipse's
proportions wrong is one of the most common "this looks almost right but off" pixel-art
errors. Canonical treatment: **Angus Coolan** — isometric measurement
(anguscoolan.com; Coolan is also an artist on the game *Unpacking*) — covers measuring
circles, spheres, and the skew-to-plane technique below.

- **Circle → ellipse (ground plane, 2:1 dimetric).** A circle of diameter D lying flat
  on the ground plane projects to an ellipse whose **major axis stays D** (along the
  plane's unconstrained direction) and whose **minor axis is D × the plane's foreshortening
  factor**. At 2:1 dimetric's 26.565° ground angle, the ground plane's vertical
  foreshortening is exactly the tile ratio itself: **minor:major = 1:2**, i.e. a circle
  drawn on the ground reads as an ellipse exactly half as tall as it is wide — the same
  2:1 ratio as the tile diamond itself, which is a convenient rule of thumb for
  freehand drawing (whatever grid you used for the tile diamond also frames the
  ellipse). At true isometric's 30°/tan(30°) family, the minor:major ratio is 57.74%
  (see the canonical constants table in
  [`projection-math.md`](projection-math.md#full-constants-tables) — same tan(30°)
  family as the Figma-hack height scale and the top-plane-circle constant).
- **Spheres.** A sphere projects to a **true circle** in *screen* space regardless of
  projection (a sphere has no "up" axis to foreshorten against) — this is the one
  isometric shape that does NOT need the ellipse correction. The trap is shading it:
  the sphere's highlight and terminator (light/shadow boundary) must still be drawn
  consistent with the single fixed light direction used across the whole set (see
  [`style-guide.md`](style-guide.md)'s three-tone doctrine), which is an ellipse-shaped
  highlight placement on the sphere's screen-circle, not a circular one, because the
  *light's* projection onto the sphere is still subject to the scene's projection
  geometry even though the sphere's silhouette isn't.
- **Skew-to-plane trick.** To draw any circular/curved detail (a window, a wheel, a
  dial) sitting flush on one of the three cube planes (top/left/right): draw the shape
  as an *undistorted* circle/curve in a separate, unrotated working layer, then apply
  that plane's exact affine transform (shear + scale + rotate — the same matrices
  documented per-plane in [`projection-math.md`](projection-math.md), e.g. the
  Illustrator SSR per-face recipe or the 2D affine matrices section) to paste it onto
  the target plane. Drawing the curve freehand directly in iso space at pixel-art
  resolution is unreliable past ~8–10px in diameter; transforming a correct circle is
  not. At small pixel sizes, snap the transformed result back onto the pixel grid by
  hand afterward — an automated transform will almost always leave a few
  anti-aliased edge pixels that need manual cleanup to match the outline rules in §3.

---

## 5. Canon and further reading

- **SLYNYRD "Pixelblog 54 — More Isometric Pixels"** (Jan 2025) — the canonical modern
  iso pixel-art blog post; documents the Aseprite Shift-pencil 2:1 preview technique
  (§2.1 above) plus tile composition and shading craft.
- **SLYNYRD Pixelblog 41** and **Pixelblog 4** — earlier entries in the same series,
  covering foundational iso pixel-art technique and tile anatomy.
- **Lospec "Pixel Art Isometric Tutorials"** — a curated, tagged index of roughly 30
  community tutorials covering buildings, rooms, vehicles, animals, and interiors in
  isometric pixel art; use as a technique-lookup index rather than a single linear
  tutorial.
- **Angus Coolan** (anguscoolan.com) — isometric shape-measurement reference (§4).

## Related references in this skill

- [`projection-math.md`](projection-math.md) — the constants and transform matrices
  this file assumes (2:1 dimetric definition, per-plane affine matrices, the
  tan(30°)/57.74% family used in the ellipse-ratio derivation above).
- [`coordinates-depth.md`](coordinates-depth.md) — tile↔screen transforms, draw-order
  and y-sort doctrine, and the anchor-at-feet rule referenced in §3's tile-seam
  discussion.
- [`tile-spec.md`](tile-spec.md) — the asset-spec template that pins projection,
  tile module, anchor, and footprint grammar before any pixel-art production begins.
- [`style-guide.md`](style-guide.md) — three-tone plane shading, palette-ramp grammar,
  and the `ink` token referenced in §3's outline rule.
- [`blender-prerender.md`](blender-prerender.md) — the 3D pre-render alternative to
  hand-drawn pixel art, including consuming Easymetric's `.obj` export.
- [`ai-refinement.md`](ai-refinement.md) — the alpha-halo/edge-bleed checks shared with
  hand-drawn tile QA.
- [`../scripts/tile-validate.py`](../scripts/tile-validate.py) — automated QA gate for
  dimension conformance, alpha-halo, edge-bleed, and palette-size checks against tiles
  produced by this workflow.
