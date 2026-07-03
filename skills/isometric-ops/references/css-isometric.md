# CSS isometric: 3D transforms and 2D affine tricks

Two unrelated techniques both get called "CSS isometric" and this file covers both,
clearly separated:

1. **The 3D route** — real `transform-style: preserve-3d` with `rotateX`/`rotateY`/
   `translateZ`, composited by the browser's own 3D transform pipeline. Gives you an
   actual rotated cube in space; individual faces can still have their own hover/light
   states, box-shadows, and nested DOM content.
2. **The 2D affine route** — no 3D context at all. `rotate() skewX()/skewY() scaleY()`
   applied to a flat, 2D element fakes the same visual result using pure matrix math.
   Cheaper, has none of the 3D-context gotchas (no `perspective`, no z-fighting), but
   every face needs a *different* 2D recipe and there's no real depth to hang shadows
   or lighting on.

Per the projection decision (see `references/projection-math.md`): both routes below
implement **true isometric projection** (30°/120°, 81.65% axonometric foreshortening
for the 3D route; the SSR-derived 86.602% family for the 2D route). If you actually
need 2:1 dimetric ("game isometric" — commonly called isometric in games) — e.g. to
match pixel-art tile assets 1:1 — swap in the 2:1 dimetric angles from
`references/projection-math.md` (`rotateX(60deg)` derivatives, `2:1` skew ratios) and
say so explicitly; do not call a 2:1 CSS grid "isometric" unqualified.

## Table of contents
- [The 3D route: preserve-3d and the true-iso stack](#the-3d-route-preserve-3d-and-the-true-iso-stack)
- [Per-face cube composition](#per-face-cube-composition)
- [Hover lifts and interaction](#hover-lifts-and-interaction)
- [Codrops-style scrollable iso grids](#codrops-style-scrollable-iso-grids)
- [The 2D affine route for cards and tiles](#the-2d-affine-route-for-cards-and-tiles)
- [Deriving which recipe yields which plane](#deriving-which-recipe-yields-which-plane)
- [When CSS beats canvas/WebGL](#when-css-beats-canvaswebgl)
- [Gotchas](#gotchas)

## The 3D route: preserve-3d and the true-iso stack

The exact true-isometric camera transform, derived and ground-truth-checked in
`references/projection-math.md`:

```css
.iso-true {
  transform: rotateX(54.7356deg) rotateZ(-45deg) scale3d(1.22474, 1.22474, 1.22474);
}
```

- `54.7356deg = atan(√2) = 90° − 35.264°` — tilts the view down onto the cube's
  space-diagonal vertex, the same angle a physical isometric camera would use.
- `-45deg` — spins the cube so two vertical edges disappear behind the front corner,
  leaving exactly three faces visible (top, left, right).
- `scale3d(1.22474, …) = √(3/2) = 1/cos(35.264°)` — **undoes the true-projection
  foreshortening.** A raw isometric camera view flattens depth to 81.65% of its
  original size (`cos(35.264°)`); the `1.22474` scale-up brings 1:1 CSS pixel/unit
  edges back to their nominal size so a 100×100px element still measures 100px along
  each visible edge. Drop the `scale3d` term if you deliberately want the
  foreshortened "camera photograph" look instead of the "isometric drawing" look —
  see the drawing-vs-projection distinction in `references/projection-math.md`.

**`transform-style: preserve-3d` is mandatory on every ancestor of the faces you want
composited in 3D** — not just the rotated container, but every intermediate wrapper
between it and the face elements. The moment one ancestor omits it (or the browser
defaults it back to `flat`, which is the default value), that ancestor flattens its
children into a 2D plane and the whole cube collapses. This single missing property
is the most common reason a "3D CSS isometric" demo renders as a flat rectangle —
verified against Envato Tuts+ "How to Create an Isometric Layout With CSS 3D
Transforms" and the CodePen family deriving this exact stack (search
`scootman "CSS 3D transforms: true isometric"` on CodePen for a live reference).

```css
.scene   { perspective: 1200px; }          /* optional: adds a vanishing point, off by default = orthographic-like */
.iso-true,
.iso-true * { transform-style: preserve-3d; }
```

Note: true isometric projection is itself **orthographic** (parallel projection, no
vanishing point). Setting a CSS `perspective` on an ancestor introduces a *camera*
perspective that competes with the isometric look — for a faithful true-iso render,
omit `perspective` entirely (or set it very large, effectively flattening its effect)
so parallel edges in 3D stay parallel on screen.

## Per-face cube composition

Build a cube (or any box: a tile, a card, a UI panel) from six independently
stylable faces, each a normal DOM element you can put content, gradients, or
`box-shadow` on:

```html
<div class="cube">
  <div class="face top"></div>
  <div class="face front"></div>
  <div class="face right"></div>
</div>
```

```css
.cube {
  position: relative;
  width: 200px; height: 200px;
  transform-style: preserve-3d;
  transform: rotateX(54.7356deg) rotateZ(-45deg) scale3d(1.22474, 1.22474, 1.22474);
}
.face {
  position: absolute;
  width: 200px; height: 200px;
  backface-visibility: hidden;   /* skip rendering faces that end up pointing away */
}
/* Top face: rotate flat into the XZ-plane, then push up by half the cube's depth */
.top   { transform: rotateX(90deg) translateZ(100px); }
/* Front (left-visible) face: sits at its native orientation, pushed toward camera */
.front { transform: translateZ(100px); }
/* Right face: rotate around Y into the YZ-plane, pushed out by half the width */
.right { transform: rotateY(90deg) translateZ(100px); }
```

Only the three faces that end up facing the (post-`rotateX(54.7356) rotateZ(-45)`)
camera are visible — the opposite three faces are either behind the visible ones or
back-face-culled by `backface-visibility: hidden`. This is exactly the "all three
cube faces equal" true-isometric property from the canonical rig table in
`references/projection-math.md` and `references/blender-prerender.md`: because the
tilt is 54.736° (not 60°), the top/front/right faces render as three congruent
rhombi, not a mix of shapes.

For a **2:1 dimetric** cube instead (matching pixel-art game tiles), swap the parent
rotation to `rotateX(60deg) rotateZ(-45deg)` and drop the `scale3d` foreshortening
correction (dimetric game art is normally authored already at drawing scale) — but
say "2:1 dimetric" in your CSS class names and comments, not "isometric", per the
terminology rule.

## Hover lifts and interaction

A `translateZ` bump on hover reads as "lifting the cube toward the camera" because
the parent's `rotateX/rotateZ` already establishes the 3D basis — no extra math
needed, just animate along the face's own local Z:

```css
.cube { transition: transform 200ms ease-out; }
.cube:hover { transform: rotateX(54.7356deg) rotateZ(-45deg)
                          scale3d(1.22474, 1.22474, 1.22474)
                          translateZ(20px); }
```

Because the `translateZ(20px)` is applied *inside* the already-rotated coordinate
system (it's the last term in the same `transform` value, composed after the
rotation), it moves the cube up the isometric camera's viewing axis rather than along
the screen's vertical — the lift reads as "toward the viewer," which is the effect
almost every isometric card/tile hover-state design wants (dashboards, game-tile
pickers, portfolio grids).

## Codrops-style scrollable iso grids

The scrollable "isometric floor" effect (Codrops "Isometric and 3D Grids", built with
Masonry-style layout underneath) is the same `.iso-true` transform applied to a large
flat `<div>` container whose *children* are normal in-flow 2D grid items (CSS Grid or
Masonry). Because `preserve-3d` propagates the parent's rotation to everything below
it, positioning the grid children is still ordinary 2D layout — only the outermost
container carries the isometric transform:

```css
.iso-floor {
  transform-style: preserve-3d;
  transform: rotateX(54.7356deg) rotateZ(-45deg) scale3d(1.22474, 1.22474, 1.22474);
  display: grid;
  grid-template-columns: repeat(auto-fill, 200px);
  gap: 20px;
}
```

Scrolling the page (or a `overflow: auto` ancestor) still works normally because the
3D transform doesn't change the element's layout box for scroll purposes — only its
rendered appearance. This is the pattern behind most "isometric portfolio" and
"isometric dashboard" demos; see also `references/svg-vector-generation.md` for the
SVG-based equivalent used by JointJS-style diagram editors.

## The 2D affine route for cards and tiles

For a single flat card, icon tile, or UI panel where you don't need a real 3D
context (no per-face content, no `perspective`, no hover-into-depth), a pure 2D
`rotate()`/`skew()`/`scale()` composition is cheaper and simpler. This is the
`.iso { transform: rotate(-30deg) skewX(30deg) scaleY(0.866); }` family that shows up
across "CSS isometric card" snippets, and it is mathematically the same **SSR
(Scale → Shear → Rotate)** technique vector tools use — see
`references/projection-math.md` for the exact Illustrator SSR percentages this
mirrors.

**Top-face recipe (verified, exact to true isometric):**

```css
.iso-top {
  transform: rotate(-30deg) skewX(30deg) scaleY(0.86603);
  transform-origin: center;
}
```

Mirror it for the opposite-handed top diamond:

```css
.iso-top-mirror {
  transform: rotate(30deg) skewX(-30deg) scaleY(0.86603);
}
```

**Left/right face recipe (verified, exact — the `skewY` family):**

```css
.iso-left  { transform: skewY(30deg); }
.iso-right { transform: skewY(-30deg); }
```

Composed together (a shared width/height rectangle) these three recipes produce a
correctly-proportioned isometric cube face-set from three separate flat 2D elements —
no `preserve-3d`, no 3D context, no `perspective` needed. This is the "disciplined 2D
transformation rather than full 3D rendering" pattern that a large share of
"isometric" browser work actually is (an observation echoed across the CSS-only iso
tutorial literature — Envato Tuts+, CSS-Tricks, FreeFrontend).

## Deriving which recipe yields which plane

Don't take any of the above on faith — verify it yourself by tracking where the unit
basis vectors land. CSS composes a `transform` list **left to right, each subsequent
function operating in the coordinate system already established by the previous
ones** — equivalent to matrix-multiplying in the *written* order and applying the
product to a column vector: `M = A · B · C`, point `p' = M·p`.

**Top-face check.** For `transform: rotate(-30deg) skewX(30deg) scaleY(0.86603)`,
composing `M = R(−30°) · Skew_x(30°) · Scale(1, 0.86603)` and applying it to the unit
basis vectors (screen coordinates, **y-down**, the CSS/SVG convention):

```
M · (1, 0)ᵀ = (0.8660, −0.5000)
M · (0, 1)ᵀ = (0.8660,  0.5000)
```

Both basis vectors land at the same 0.8660 horizontal run with a ±0.5 vertical rise —
exactly `cos(30°) = 0.86603` horizontal and `sin(30°) = 0.5` vertical, the two edges
of a diamond whose long axis is horizontal: **this is the top-plane rhombus**, the
same 2:1-looking (but exactly √3:1, true-iso) diamond you'd get slicing the top face
off the 3D cube in the previous section. If you re-derive this and get anything other
than `(±0.866, ∓0.5)`-family vectors, the recipe is wrong for true isometric — a
common broken variant is scaling by the visually-similar-but-wrong `0.864` (an
imprecise rounding that has propagated through several popular blog snippets) instead
of the exact `0.86603 = cos(30°)`; the axes then land a fraction of a degree off,
invisible at small sizes but compounding into visible drift on large grids or tiled
assets.

**Left/right-face check.** For `transform: skewY(30deg)`:

```
M · (1, 0)ᵀ = (1, 0.5774)
M · (0, 1)ᵀ = (0, 1)
```

The vertical edge (`(0,1)`) stays exactly vertical — a left-face parallelogram keeps
its true-vertical edges vertical, which is what makes it read as the "side" of a cube
rather than another sloped diamond. The horizontal edge tilts by `atan(0.5774) = 30°`
— matching the top face's 30° edge exactly, so the two faces share a seamless edge
when butted together. `0.5774 = tan(30°) = 0.57735`, the same constant family as the
Figma-hack height scale and the "top-plane circle → ellipse" ratio in
`references/projection-math.md` — not a coincidence; it's the same 30°-shear
identity showing up in every true-iso 2D-affine derivation. `skewY(-30deg)` mirrors
this for the right face (`M · (1,0)ᵀ = (1, −0.5774)`).

Run the numbers yourself before shipping a new recipe variant — any 2D affine
isometric transform must satisfy: (a) the shared edge between adjacent faces has
matching slope in both faces' bases, and (b) the diamond half-angle is exactly 30°
(true iso) or `atan(0.5) = 26.565°` (2:1 dimetric) — never eyeballed values like the
`51deg`/`43deg` "pragmatic dimetric" numbers seen in some minimal snippets (those
approximate the *look* of isometric but do not satisfy either projection's exact
angle and will not tile edge-to-edge with true-projection or 2:1-dimetric assets).

## When CSS beats canvas/WebGL

Prefer the CSS routes (either 3D or 2D-affine) over `<canvas>`/WebGL for:

- **DOM semantics** — each face/tile is a real element; screen readers, `aria-*`
  attributes, and semantic HTML (`<button>`, `<a>`, headings) work unmodified inside
  an isometric-transformed container.
- **Text selection and copy/paste** — text inside a `preserve-3d` face is still
  selectable, searchable (`Ctrl+F`), and copyable; canvas-rendered text is not.
- **SEO** — content is crawlable HTML, not pixels on a canvas or an opaque WebGL
  draw call.
- **Native interaction** — `:hover`, `:focus-visible`, `<input>` elements, form
  controls, and CSS `:has()`/media-query responsiveness all work without
  reimplementing hit-testing.
- **Low element counts** — dozens to a few hundred faces/tiles. CSS 3D transforms are
  GPU-composited per element, which is cheap at DOM scale but does not scale to
  thousands of independently-transformed elements the way an instanced WebGL draw
  call does.

Prefer canvas/WebGL (see `genart-ops` for general three.js scaffolding,
`references/threejs-orthographic.md` for the iso-specific delta) once you need:
hundreds+ of independently-positioned tiles/sprites, per-pixel effects (lighting,
shadows, particle systems), or a real camera/scene graph for a game rather than a
static or lightly-interactive layout.

## Gotchas

- **`transform-origin` defaults to `50% 50%` (center)** — fine for a single rotated
  card, wrong for compositing cube faces around a shared pivot. When building a
  multi-face cube from the 3D route, set an explicit `transform-origin` (or rely on
  the `translateZ` half-extent trick shown above, which sidesteps the issue by
  keeping every face's own origin at its own center and translating outward instead
  of rotating around a shared point).
- **Blurry text after transforms.** Both `skew()` and non-90°-multiple `rotate()`
  put text on a sub-pixel grid, and browsers do not always sub-pixel-hint
  transformed text as crisply as untransformed text. Mitigations: increase source
  font-size and scale down (renders at a higher effective resolution before the
  blur-inducing transform), prefer `font-smooth`/`-webkit-font-smoothing:
  antialiased`, or — for the 2D-affine route — apply the transform to a wrapper
  `<div>` and keep a small counter-rotated/counter-skewed inner element for text
  that must stay perfectly legible (accepting that it will look "flat" against the
  tilted background).
- **Z-fighting and stacking-context surprises.** `preserve-3d` creates a genuine 3D
  rendering context; elements at the *same* Z-depth (e.g. two faces both left at
  `translateZ(0)`) render in DOM/paint order, not a deterministic depth-sort, so
  overlapping same-depth elements can flicker or overlap unpredictably on
  z-fighting-prone edges. Give every face a distinct `translateZ` (even a 1px
  nudge) to force a stable order. Separately, `preserve-3d` **breaks** the moment
  any ancestor introduces `overflow`, `filter`, `opacity < 1`, `will-change`,
  `mask`, `clip-path`, `contain`, or `perspective` on itself (all of these force
  their own new stacking context and flatten `preserve-3d` beneath them per the CSS
  Transforms spec) — a `filter: drop-shadow(...)` added for a shadow effect on a
  cube's wrapper is a common way to silently flatten the whole cube back to 2D.
- **Sub-pixel seams between adjacent faces/tiles.** Because `skewY(30deg)` and its
  siblings produce transcendental (non-integer) pixel offsets, two adjacent tiles
  laid edge-to-edge in the 2D-affine route can show a hairline gap or overlap at
  certain zoom levels due to sub-pixel rounding differences between the two
  elements' independently-computed transform matrices. Mitigations: render tiles
  from a single shared parent transform rather than per-tile transforms where
  possible (fewer independent roundings), nudge overlapping edges by ~0.5–1px via
  `outline`/negative margin as a defeat-device, or move to the 3D `preserve-3d`
  route (a single parent transform, no per-face seam math) once seams become
  visible at your target zoom/DPI.

## Related references

- `references/projection-math.md` — the derivations behind every constant used here
  (30°, 35.264°, 54.7356°, 86.602%, 57.735%, 1.22474), the Illustrator SSR method
  this 2D route mirrors, and the full projection-decision table.
- `references/svg-vector-generation.md` — the SVG `matrix()` equivalent of these same
  plane transforms, for when you need a `<path>`-based asset instead of a
  transformed DOM element.
- `references/coordinates-depth.md` — tile↔screen math and draw-order/y-sort doctrine
  for when CSS tiles become an actual game-like grid rather than a static layout.
- `skills/genart-ops/SKILL.md` — general three.js/creative-coding scaffolding
  (canvas/WebGL route, out of scope here).

## Sources

- Envato Tuts+, "How to Create an Isometric Layout With CSS 3D Transforms" —
  `transform-style: preserve-3d` mandatory-on-children finding.
- CSS-Tricks, `rotateZ()` almanac entry — `rotateX(60deg) rotateZ(-45deg)` dimetric
  variant.
- CodePen, scootman `QWvYoyY`, "CSS 3D transforms: true isometric" — derivation of
  `rotateX(54.736deg) rotateZ(-45deg) scale3D(1.2247)`.
- Codrops, "Isometric and 3D Grids" — scrollable isometric grid pattern.
- FreeFrontend, "8 CSS Isometric Designs" — snippet gallery and the DOM-semantics/
  accessibility argument for CSS over canvas/WebGL.
- 30 Seconds of Code, "Isometric card" — the minimal `rotateX(51deg) rotateZ(43deg)`
  pragmatic-dimetric hover-card recipe (cited here as the "eyeballed angle" anti-
  pattern, not a recommended exact recipe).
- SRC-C (`iso-pdf.md`) — the `.iso { transform: rotate(-30deg) skewX(30deg)
  scaleY(0.866); }` starter snippet and its framing as "disciplined 2D
  transformation rather than full 3D rendering," alongside `isometric-css`
  (see `references/svg-vector-generation.md`), Codrops IsometricGrids, and the
  JointJS SVG guide.
- Canonical constants table (this skill's build brief) — 30°/35.264°/54.7356°/
  86.602%/57.735%/1.22474; the CSS true-iso transform line item verbatim.
