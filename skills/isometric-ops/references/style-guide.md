# Isometric Style Guide

The craft doctrine for isometric illustration and game-asset sets: how to shade a plane,
build a palette, hold a consistent scale, compose a diamond, cut away a wall, and label a
diagram — so a set of 200 tiles drawn over six months by three different hands still
reads as one object. This file is the **reviewer's rubric**: everything in it maps onto
the consistency checklist at the bottom, and that checklist is what an art lead runs
against a batch before it ships.

Projection math lives in
[`projection-math.md`](projection-math.md) and
[`coordinates-depth.md`](coordinates-depth.md) — this file assumes you've already made
the projection decision (true isometric vs 2:1 dimetric vs pixel-neat 1:2; see
`projection-math.md`'s decision table) and covers only what happens *after* the geometry
is correct: light, colour, scale, composition, type, and review discipline.

> **Terminology reminder.** "2:1 dimetric (commonly called isometric in games)" is the
> correct term for game-tile work; true isometric (30°/120°) is what most illustration
> and CSS/SVG work uses. This guide's shading and palette doctrine applies to both — the
> difference is geometric, not aesthetic.

---

## 1. Three-tone plane shading

The single highest-leverage rule in isometric illustration: **every visible plane of an
object gets exactly one flat tone, and the three tones are fixed by which plane they're
on, not by which object they belong to.**

| Plane | Tone | Why |
|---|---|---|
| Top | **Lightest** | Receives the most simulated light in a top-down/three-quarter lighting model; reads as "closest to the light source" |
| Left *or* right (pick one, per your fixed light direction) | **Mid** | The plane roughly perpendicular to the light |
| Right *or* left (the other of the pair) | **Darkest** | The plane facing away from the light |

Rules that make this work at scale:

1. **Pick ONE light direction for the entire asset set and never change it.** If light
   comes from the upper-left, the left plane is always mid-tone and the right plane is
   always dark, on every single asset — a barrel, a building, a tree, a UI card. Mixing
   light directions within one scene is the single fastest way to make a set look
   amateurish; the eye detects inconsistent shading before it detects almost anything
   else.
2. **Flat tones, not gradients, per plane.** A gradient across a single flat plane
   implies a light source close enough to fall off within the object's own dimensions —
   wrong for the parallel, infinitely-distant light that isometric/axonometric
   projection assumes. Reserve gradients for large environmental surfaces (sky, distant
   fog) or intentional ambient-occlusion accents at contact edges, not for the core
   three-tone system.
3. **Soft, long shadows cast along the plane angles, not the light-source azimuth
   naively.** A cast shadow in an isometric scene should itself be drawn as a flat shape
   on the ground plane, skewed along the same axis family as the ground grid (i.e. its
   silhouette follows the 30°/150° or dimetric-equivalent lines), not a raster drop
   shadow with a blur radius. Keep shadow opacity low (typically 15–30%) and shadow hue
   a darkened, desaturated version of the ground tone — never pure black — to avoid
   muddying the palette.
4. **Ambient occlusion, not new light sources.** Contact shadows where two planes meet
   (an object sitting on a tile, a window recessed into a wall) darken the *receiving*
   surface slightly at the seam. This is a fourth, narrow tonal step, not a fourth
   light — keep it inside the same ramp (see §2) as the plane it's darkening.
5. **Cel/hard shading, not smooth PBR shading**, is the default for the illustrative iso
   style this guide targets. If you are pre-rendering from Blender/three.js with real
   lighting (see `blender-prerender.md`, `threejs-orthographic.md`), match the *result*
   to this same three-tone read even though the underlying render is continuous —
   flatten in post if the renderer's falloff is too soft, or use a toon/cel shader.

**Verification test**: pick any two objects in the set at random. Do their top planes
match in relative lightness? Do their left planes match each other, and their right
planes match each other? If an artist has to check which way "the sun" is pointing for a
specific asset, the doctrine has already broken down — it should be a fixed, memorised
constant for the whole project, ideally written into the tile spec
(`tile-spec.md`'s "light direction" field).

---

## 2. Palette grammar

### The three-ladder pattern

Don't "pick five colours." Design three **ramps** (ladders of 3–6 perceptually-even
steps each):

| Ladder | Purpose | Example use |
|---|---|---|
| **Light/tonal ladder** | The neutral-to-near-neutral steps that carry the three-tone shading (top/mid/dark) for any given hue | Applied per-material: a red barrel's top/left/right are three steps down the *red* material's own tonal ladder, not three unrelated colours |
| **Material ladder** | One ramp per distinct material/surface type in the set (wood, stone, metal, foliage, water, fabric) | Keeps "all the wood" visually related across 50 different props even though each prop's exact hue varies slightly |
| **Accent ladder** | A small, tightly-controlled set of high-saturation colours reserved for focal points — UI highlights, quest markers, glowing windows, signage | Used sparingly; if everything is an accent, nothing is |

This is the resolution to "design a light ladder, a material ladder, and one accent
ladder so the three planes of the object remain readable under repetition" — the winning
pattern over ad hoc colour picking, because it scales: a new prop doesn't need a new
colour decision, it needs a material-ladder lookup plus the fixed top/mid/dark tonal
offset.

### Perceptual ramps: cross-reference, don't restate

Generate each ladder as a **perceptually uniform ramp in OKLCH** (equal lightness steps,
controlled chroma, held hue) rather than naive RGB/HSL interpolation, which produces
muddy or unevenly-spaced midtones. Full OKLCH mechanics, the `oklch()` CSS syntax,
gamut/P3 handling, and ramp-generation recipes are owned by
[`color-ops`](../../color-ops/SKILL.md) — **use it directly** rather than duplicating
color science here. The isometric-specific rule this guide adds on top:

- Derive the three-tone shading steps (top/mid/dark) as **fixed lightness deltas within
  one hue's OKLCH ramp**, not as independently chosen colours. A typical delta is
  top = base L, mid = base L − 0.12–0.18, dark = base L − 0.25–0.35, with a small hue
  shift toward blue/violet on the darkest step (cool shadows read as more natural than
  simply-darkened same-hue shadows).
- Keep chroma (`C`) roughly constant or very slightly reduced on the dark step — dropping
  chroma too far reads as "grey," dropping it too little reads as "neon shadow."

### Ready-made presets

Eight ready-to-use three-tone JSON presets (`kenney-prototype-grey`,
`pastel-dollhouse`, `industrial-muted`, `cyberpunk-teal-violet`, `blueprint`,
`earthy-game`, `mono-ink`, `brand-neutral`) ship at
[`../assets/palettes/three-tone-presets.json`](../assets/palettes/three-tone-presets.json).
Each preset supplies `{name, description, ink, top, left, right, shadow, accent, bg}` as
hex values already satisfying the top-lightest → left-mid → right-dark ordering (or its
mirror, for a right-side light source) — load one as a starting ramp instead of
hand-tuning from scratch, then adjust the accent ladder to the project's brand colours.

### Limited palettes read better than large ones

A 6–10 hue palette (each with its own 3–6 step ramp) reads as more intentional and more
"designed" than a 30-hue palette, and it is dramatically easier to keep three-tone
discipline over. If the source material (a brand kit, a licensed IP) hands you a large
palette, the job is to *map* it down onto ladders — decide which brand colours become
material ladders, which become the single accent ladder, and resist using every provided
swatch just because it exists.

---

## 3. Scale grammar

**One fixed reference: "one human figure = N tiles/units tall."** Pick this number once,
document it in the tile spec (`tile-spec.md`), and derive every other object's scale
from it — a doorway is slightly taller than the reference human, a car is roughly
0.6–0.8 human-widths wide, a two-storey building is ~2.2–2.5 human-heights including
roofline. This is the isometric-art equivalent of an architectural scale figure, and
skipping it is how asset packs end up with a "dollhouse door next to a cathedral-sized
barrel."

Rules:

1. **No mixed-scale objects sharing one scene without deliberate intent.** If a
   composition genuinely needs a "hero" object rendered larger than strict scale would
   allow (a stylised oversized moon, a exaggerated hero prop), that is a *composition*
   decision made once and clearly, not scale drift creeping in prop-by-prop across a
   production run.
2. **Footprint grammar ties into scale grammar.** An object's footprint (1×1, 2×1, 2×2
   tiles — see `tile-spec.md`) should be consistent with its human-scale height: a 2×2
   footprint building reads as roughly building-sized *because* the human reference
   makes the tile module legible, not because the artist eyeballed it.
3. **Re-check scale after AI generation or upscaling.** Generative pipelines
   (`ai-generation.md`) are especially prone to scale drift between otherwise
   style-matched outputs — a "cozy cottage" and "cozy cottage, larger" prompt pair can
   produce wildly different implied scales. Composite a new asset next to a known-good
   reference object before accepting it into a set.
4. **State the scale grammar in the tile spec once per asset set**, not per asset — it
   is a project-wide constant, like the light direction.

---

## 4. Composition

### Diamond flow

Isometric scenes compose naturally along the **diamond** — the rotated-square silhouette
that the ground plane traces in true iso, or the flatter rhombus a 2:1 dimetric ground
plane traces. Strong isometric compositions work *with* this shape rather than fighting
it:

- Anchor the primary subject near the diamond's centre or along one of its two long
  diagonals (the natural "read" lines an eye follows in an isometric image), not in a
  corner.
- Let secondary elements recede toward the diamond's points, naturally creating depth
  without needing perspective convergence (which true iso and dimetric explicitly don't
  have — see `projection-math.md`).
- For scenes built from a tile grid, keep the *occupied* footprint roughly
  diamond-shaped or centred, even if the canvas itself is a wider rectangle — an
  isometric scene cropped to a hard rectangle around a diamond-shaped layout reads as
  more deliberate than one that fills the rectangle edge-to-edge with tiles.

### Focal density and negative space

- One clear focal point per composition — the tallest structure, the brightest accent
  colour, the most detailed prop. Everything else is support.
- Isometric illustrations tolerate, and usually benefit from, **generous negative
  space** (background/sky/void) around a tightly detailed focal cluster — this is the
  opposite instinct from "fill every tile," and it's why a lot of professional isometric
  work (icon sets, hero illustrations) reads as more premium than tile-packed game
  screenshots. For dense game maps this rule relaxes (see §5 for the different
  discipline that applies once a map exceeds a single-screen composition), but even
  there, vary local density — cluster detail, leave breathing room, avoid uniform
  coverage.
- Detail density should correlate with visual importance, not be uniform: the focal
  object gets the most surface detail (trim, texture, small props); background/support
  objects are simpler silhouettes in the same three-tone system.

### Cutaway conventions

Cutaway (interior-reveal) compositions — "room with the front wall removed" — are one of
the most common isometric illustration formats and have their own small rule set:

1. **Clean wall removal, never a jagged/torn edge**, unless the piece is deliberately
   stylised as damage. The convention is a perfectly flat cut, as if a wall simply isn't
   there — not a broken-off fragment.
2. **Uniform wall thickness** across every cut wall in the scene. Varying thickness
   between the left-cut wall and the back-cut wall (if both are shown) breaks the
   illusion that this is one consistent piece of architecture.
3. **Show the cut edge as a thin, distinctly-toned strip** (often the material ladder's
   darkest or a dedicated neutral) so the cut reads intentionally rather than looking
   like a rendering error.
4. **Interior lighting stays consistent with the fixed light direction** (§1) even
   though the "camera" is notionally inside a room that wouldn't naturally receive
   exterior light — isometric cutaways are a diagram convention, not a physical
   simulation, and audiences accept the convention as long as it's applied uniformly.
5. Furniture and props inside a cutaway follow the same scale grammar (§3) as exterior
   objects — a cutaway is not licence to eyeball interior scale independently.

---

## 5. Typography and labelling

For isometric diagrams, dashboards, and annotated illustrations (as opposed to pure game
tile art, where in-engine UI systems typically own type rendering):

- **Inter** — a tall-x-height, UI-oriented variable neo-grotesque — is the default
  choice for dense labels, data callouts, and captions layered over an isometric scene;
  it holds up at small sizes and pairs cleanly with the flat, geometric character of
  isometric illustration. (rsms.me/inter)
- **Space Grotesk** — a more characterful geometric grotesk — is the better choice for
  hero headings, product branding, or a more editorial/sci-fi voice, where a slightly
  more stylised letterform is wanted without sacrificing legibility.
  (fonts.floriankarsten.com/space-grotesk)
- Both ship as free, open-source variable fonts under the SIL Open Font License —
  no licensing friction for commercial isometric diagram or product work.
- **Never rotate or skew text into the isometric plane.** Labels, annotations, and
  callouts should always sit flat/horizontal in screen space (with a leader line or
  simple background chip connecting them to the isometric element they describe), even
  when everything else in the scene is projected. Text skewed into a 30° or dimetric
  plane becomes measurably harder to read and gains nothing — this is a hard rule, not
  a style choice.
- Reserve the accent ladder (§2) for label backgrounds/chips and connector lines, so
  annotation layers visually belong to the same palette system as the illustration
  itself rather than looking bolted on.
- Keep label density low relative to the composition's focal density (§4) — an
  over-labelled isometric diagram competes with itself.

---

## 6. Consistency checklist (the reviewer's rubric)

Run this against any batch before it ships. Every "no" is a named, fixable defect —
this is deliberately phrased so it can be read one item at a time against a sheet of
thumbnails.

- [ ] **Projection**: every asset in the batch uses the same projection and exact angle
      declared in the tile spec (no true-iso pieces mixed into a 2:1 dimetric set or
      vice versa — see `projection-math.md` §mislabel table for how this happens).
- [ ] **Light direction**: is the light direction identical across every asset (same
      plane is always lightest, same plane always mid, same plane always darkest)?
- [ ] **Tone count**: does every object stick to the three flat tones per plane
      (plus contact AO where relevant), with no stray gradients simulating a second
      light source?
- [ ] **Palette discipline**: does every colour used trace back to one of the defined
      ladders (light/tonal, material, accent)? Any off-ladder colours are either a
      missing ladder entry or a mistake.
- [ ] **Scale grammar**: does every object's size make sense against the fixed
      "N tiles = one human" reference? Spot-check by compositing a suspect asset next
      to a known-good reference object.
- [ ] **Anchor/footprint**: does every sprite's anchor sit at the visual feet (see
      `coordinates-depth.md`'s anchor-at-feet rule), and does its declared footprint
      (1×1, 2×1, 2×2…) match its actual silhouette?
- [ ] **Edge/alpha hygiene**: no semi-transparent halo fringe, no edge-bleed opaque
      pixels at the tile boundary (mechanically checkable — see `tile-validate.py` and
      `ai-refinement.md`'s edge-halo cleanup section for AI-generated tiles).
- [ ] **Composition**: does the piece have one clear focal point, and is detail density
      concentrated there rather than spread uniformly?
- [ ] **Cutaway integrity** (if applicable): clean wall removal, uniform wall thickness,
      consistent interior lighting.
- [ ] **Typography** (if applicable): labels flat in screen space, not skewed into the
      isometric plane; label density restrained.
- [ ] **Naming/spec conformance**: filenames and metadata match the tile spec's naming
      convention (`name_direction_variant.png`) and every spec field is actually
      satisfied, not just declared.

A batch that passes every line here is what "one object drawn by three different hands
over six months" looks like when the system worked.

---

## 7. Inspiration canon

Study these when calibrating a new project's style, not to copy directly but to see the
range of what disciplined three-tone, fixed-light isometric work can look like:

| Artist / studio | Known for | Reference |
|---|---|---|
| **Peter Tarka** | Bold-colour Cinema 4D isometric work for Apple, Nike, Google — a strong example of confident, limited-palette, high-production-value commercial iso illustration | petertarka.com |
| **eBoy** | Pioneers of pixel-isometric art ("Pixoramas") — dense, saturated, mega-city compositions built from a rigorous pixel-iso grid; a foundational reference for pixel-art iso specifically | eboy.com |
| **Rod Hunt** | Detailed isometric maps and pixel-influenced illustration, strong sense of narrative density within a diamond composition | rodhunt.com |
| **SLYNYRD (Arne / the Pixelblog series)** | The most current, technically rigorous modern pixel-iso tutorial series (Pixelblog 4, 41, 54 — 2:1 dimetric discipline, Aseprite workflow); see `pixel-art-workflow.md` for the technical detail this canon entry points to | slynyrd.com |
| **r/isometric** | Community showcase and critique — useful for range-finding "what does professional vs hobbyist iso work look like" across many hands and styles, and for spotting common failure modes in the wild | reddit.com/r/isometric |

Additional working artists worth a look when researching a specific niche: **Marcelo
Colmenero** (@isometricpixelart), **Totto Renna / Supertotto**, **Gustavo Zambelli /
zamax** (Dribbble), and **Jude Buffum** — via the curated list "26 Best Isometric
Artists" (Huntlancer) if a broader survey is needed. Dribbble and Behance remain the
highest-volume public showcases for isometric work generally; useful for portfolio
benchmarking, less useful for technical problem-solving (use tool-specific
communities/docs for that — Adobe Community, the Affinity forum, project GitHub repos).

---

## Sources

- Engineering and Aesthetic Standards for Isometric Design (SRC-B) — three-tone shading
  terminology, AI prompt "three-tone shading" keyword usage, fonts/colour-system survey
  distilled into the three-ladder pattern.
- compass_artifact isometric resource library (SRC-A) — artist canon (Peter Tarka, Rod
  Hunt, eBoy, SLYNYRD Pixelblog, curated artist lists), r/isometric and
  Dribbble/Behance community pointers.
- Isometric Design Resource Library (SRC-C, converted PDF) — fonts/colour/grid resource
  table (Inter, Space Grotesk, SIL Open Font License terms), the "design a light ladder,
  a material ladder, and one accent ladder" palette doctrine, and the canonical learning
  sequence "grid logic → primitive solids → plane switching → material and shadow
  logic → scene composition → typography and annotations → export discipline."
- [color-ops SKILL.md](../../color-ops/SKILL.md) — OKLCH mechanics, perceptual ramp
  generation, gamut handling (cross-linked, not restated here).
- [rsms.me/inter](https://rsms.me/inter/) — Inter font family and license.
- [fonts.floriankarsten.com/space-grotesk](https://fonts.floriankarsten.com/space-grotesk) — Space Grotesk font family and license.
