---
name: isometric-ops
description: "Create, refine, compose, and export isometric illustrative assets for websites and games. Covers projection math (true isometric 30° vs 2:1 dimetric vs pixel 1:2), SVG/CSS/three.js generation, pixel-art workflow, Blender pre-render rigs, engine tilemaps (Godot/Unity/Phaser), AI generation with ControlNet structure control, asset sourcing and licences, and the companion iso-studio scene composer (standalone app: snap-to-grid staging, y-sort, blockout-to-ControlNet export). Use for: isometric, dimetric, axonometric, isometric illustration, isometric icon, isometric city, isometric room, isometric map, iso grid, isometric tiles, 2:1 tiles, tile spec, tileset, tilemap, y-sort, depth sorting, orthographic camera, SSR method, scale shear rotate, isometric CSS, isometric SVG, iso-studio, snap to grid, sprite sheet, spritesheet, atlas packing, isometric pixel art, Aseprite isometric, Blender isometric render, isometric AI generation, isometric LoRA, ControlNet isometric, isometric asset pack, Kenney isometric, isometric export."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "genart-ops, threejs-ops, color-ops, frontend-design, playwright-ops"
---

# Isometric Operations

Create, refine, compose, and export isometric illustrative assets for websites and
games — end to end. This skill covers the exact projection math, the vector/CSS/SVG and
three.js generation routes, the pixel-art and Blender pre-render pipelines, engine
tilemap integration, the AI-generation-with-structure-control workflow, asset sourcing
with licence discipline, and the companion **iso-studio** scene composer (a standalone
app that grew out of this skill). Every constant is
derived and machine-checked; every workflow is runnable; every claim is sourced in its
reference file.

> **Boundary — what this skill does NOT own.** General three.js / creative-coding
> scaffolding lives in [`genart-ops`](../genart-ops/SKILL.md); app- and game-scale
> three.js (GLTF pipeline, react-three-fiber, `InstancedMesh`) lives in the `threejs-ops`
> skill. Colour science and perceptual (OKLCH) ramp construction live in
> [`color-ops`](../color-ops/SKILL.md). `isometric-ops` owns **only the isometric delta**
> — it cross-links those siblings, it never restates them. Detail lives in the reference
> files below: this router points, it does not duplicate.

---

## 1. The projection decision — always step zero

Choose the projection **before** you draw, generate, or model anything. This is not a
deferrable stylistic preference: it fixes the grid math, the tile aspect ratio, the
camera rig, and the anti-aliasing strategy for the entire pipeline downstream. Changing
it later means re-cutting every asset.

| Job | Projection | Ground-axis angle | Tile / face rule | Where |
|---|---|---|---|---|
| Web / vector illustration, diagrams, icons, hero art | **True isometric** | **30°** (all three axes 120° apart) | all axes foreshorten equally; smooth vector edges ignore pixel stepping | [`projection-math.md`](references/projection-math.md) §1, [`svg-vector-generation.md`](references/svg-vector-generation.md), [`css-isometric.md`](references/css-isometric.md) |
| Game tiles, tilemaps, sprite worlds, most "isometric" games | **2:1 dimetric** (commonly called isometric in games) | **26.565°** = arctan(1/2) | integer 2px:1px steps tessellate; `tileW = 2·tileH` | [`projection-math.md`](references/projection-math.md) §2, [`coordinates-depth.md`](references/coordinates-depth.md), [`engine-integration.md`](references/engine-integration.md) |
| Hand-placed / library pixel-art primitives (cubes, bricks, slopes) | **Pixel-neat 1:2** | **22.6°** (obelisk.js pixel-dot pattern) | 1:2 pixel dot stepping avoids staircasing at primitive-drawing level | [`projection-math.md`](references/projection-math.md) §7, [`pixel-art-workflow.md`](references/pixel-art-workflow.md) |

**The failure mode this prevents.** Nearly every "isometric" game is actually
**dimetric** (only two of the three axis separations are equal: ≈116.565°, 116.565°,
126.870°). The trap: an artist draws a "30° isometric" tile, the engine places it on a
2:1 (26.565°) diamond grid, and **the tile edges do not meet their neighbours**. Small at
one tile, catastrophic across a 50×50 map. The fix is not a nudge tool — it is deciding,
up front, that game tiles are **2:1 dimetric at 26.565°** and writing that number into
the [tile spec](references/tile-spec.md) so every asset is cut to the same grid.

**Terminology discipline (applies everywhere).** On first use per document write
**"2:1 dimetric (commonly called isometric in games)"**, then "2:1 dimetric" thereafter.
Never call the 2:1 game projection "isometric" unqualified. Distinguish **"isometric
drawing"** (100% scale) from **"isometric projection"** (81.65% = √(2/3) scale) whenever
the distinction affects a measurement.

### Canonical constants (the authority table)

Machine-emitted by [`iso-math.py constants`](scripts/iso-math.py); full derivations and
ground-truth checks in [`projection-math.md`](references/projection-math.md).

| Symbol | Exact form | Value | Appears as |
|---|---|---|---|
| Cube tilt ("magic angle") | `arctan(1/√2) = arcsin(1/√3)` | **35.264°** | 3D iso rotation |
| Foreshortening (projection scale) | `cos(35.264°) = √(2/3)` | **81.65%** (0.81650) | true-projection edge scale |
| Isometric **drawing** scale | full-scale convention | **100%** | vector iso (edges read at 100%) |
| True ground angle | definition | **30°** | vector iso axes |
| SSR / top-plane squash | `cos(30°)` | **86.602%** (0.86603) | Illustrator scale, 2D plane matrices |
| Figma height / circle→ellipse | `tan(30°)` | **57.735%** (0.57735) | Figma hack, ellipse minor axis |
| CSS back-tip | `arctan(√2) = 90° − 35.264°` | **54.7356°** | CSS `rotateX` |
| CSS un-foreshorten | `√(3/2) = 1/cos(35.264°)` | **1.22474** | CSS `scale3d` |
| Dimetric ground angle | `arctan(1/2)` | **26.565°** | game tiles |
| Dimetric screen slope | `tileH/tileW` (2:1) | **0.5** | tile-space `+x` = `(+tileW/2, +tileH/2)` |

> Two Blender ortho-camera rigs, both must appear wherever rigs are discussed: **2:1
> dimetric = RotX 60°, RotY 0°, RotZ 45°** (cube top 2× wide as tall, `sin 30° = 0.5`);
> **true isometric = RotX 54.736°, RotY 0°, RotZ 45°** (all three faces equal). Most
> tutorials use 60/0/45 and mislabel it "isometric" — it is dimetric. See
> [`blender-prerender.md`](references/blender-prerender.md) §1.

---

## 2. Task router — six routes

Each route is a numbered mini-workflow. Follow the links for the exact numbers, code, and
gotchas — the steps here are the spine, the references are the flesh.

### Route A — Illustrate for the web (vector / CSS / SVG)

For diagrams, icons, hero art, marketing scenes → **true isometric (30°)**.

1. **Decide** true iso (§1). Pin the light direction and palette up front
   ([`style-guide.md`](references/style-guide.md)).
2. **Pick the medium.** Live DOM elements you want selectable / accessible / SEO-visible →
   CSS. Static shapes and icon sets → SVG. See the decision tables in
   [`css-isometric.md`](references/css-isometric.md) and
   [`svg-vector-generation.md`](references/svg-vector-generation.md).
3. **CSS route.** 3D: `transform-style: preserve-3d` on the container, per-face children,
   then the outer stack `rotateX(54.7356deg) rotateZ(-45deg) scale3d(1.22474,…)` — the
   scale goes on the container **only** (or faces double-scale). 2D affine for flat cards:
   the `rotate(-30deg) skewX(30deg) scaleY(0.866)` recipe family, derived per plane in
   [`css-isometric.md`](references/css-isometric.md).
4. **SVG route.** Reach for [`@elchininet/isometric`](references/svg-vector-generation.md)
   (SVG-native, planes/paths) or hand-roll diamond/cube/prism paths using the plane
   `matrix()` recipes (Top `matrix(0.86603, 0.5, 0.86603, -0.5, 0, 0)`, etc.). Grab a
   ready grid from [`assets/grids/`](assets/grids/) or emit one with
   `iso-math.py grid-svg`.
5. **Optimise & export.** Simplify paths in-tool → export → SVGO/SVGOMG → raster
   derivatives, **in that order** ([`svg-vector-generation.md`](references/svg-vector-generation.md) §7).
6. **Verify visually.** For map-heavy web work, headless-screenshot checks belong to
   [`playwright-ops`](../playwright-ops/SKILL.md); tie the render back to the
   [style checklist](references/style-guide.md).

### Route B — Build a game tileset (spec → generate → validate → pack → engine)

For tilemaps and sprite worlds → **2:1 dimetric (26.565°)**. This is the discipline route;
skipping the spec is how sets drift.

1. **Write the spec first.** Copy the fill-in template from
   [`tile-spec.md`](references/tile-spec.md) and pin: projection + exact angle, tile W×H
   (`W = 2H`), unit elevation (px per z-step), anchor **at the feet**, footprint grammar
   (1×1, 2×1, 2×2…), transparent margin/bleed, palette tokens, one light direction, output
   format, `name_direction_variant.png` naming, and scale grammar (one human = N tiles).
2. **Generate** the tiles — draw them ([`pixel-art-workflow.md`](references/pixel-art-workflow.md)),
   pre-render from 3D (Route D), or AI-generate (Route C). Every asset obeys the spec's
   numbers.
3. **Validate** each tile against the spec:
   `uv run scripts/tile-validate.py --tile-w 64 --tile-h 32 tiles/*.png` — flags dimension
   drift, alpha halos, edge-bleed, off-centre anchor, palette overflow (exit 10 on any
   violation). Every spec line maps to a check
   ([`tile-spec.md`](references/tile-spec.md) "How the spec feeds tile-validate.py").
4. **Pack** into an atlas:
   `uv run scripts/sheet-pack.py tiles/ --trim --padding 2 --pot` → one sheet PNG + a JSON
   atlas. An atlas turns N texture binds into 1 — the single biggest win for tile-heavy
   scenes ([`coordinates-depth.md`](references/coordinates-depth.md) §11).
5. **Integrate** into the engine — Godot 4 `TileMapLayer` (Shape=Isometric, Layout=Diamond
   Down, Y-Sort on, origin at feet), Unity orthographic checklist, or Phaser/PixiJS manual
   cart↔iso. Atlas anchor/pivot mapping is spelled out in
   [`engine-integration.md`](references/engine-integration.md).
6. **The runtime math** — tile↔screen, picking, and the `(x+y, z, layer, zBias)` depth
   sort with anchor-at-feet — lives in [`coordinates-depth.md`](references/coordinates-depth.md)
   and is mirrored by `iso-math.py to-screen` / `to-tile` (round-trip verified).

### Route C — AI pipeline (generate → control → refine → vectorize)

Fast, but perspective drifts without structure control. Pick the model by what the output
must *be*, then hold the geometry with ControlNet.

1. **Climb the decision ladder** ([`ai-generation.md`](references/ai-generation.md) §1):
   editable vectors → Recraft (vector-native); hero raster → Midjourney `--sref`/`--sw`
   (+ Firefly for brand-safe vector with Content Credentials); local control / tilesets →
   Flux/SDXL + iso LoRA + ControlNet; consistent large sets → a custom-trained model
   (Scenario/Layer) on 10–20 on-style refs.
2. **Prompt** from the ready scaffolds in [`assets/prompt-library.md`](assets/prompt-library.md)
   — subject + projection + material language + simplification rule + lighting rule +
   output intent, plus the universal negative-prompt block (vanishing points, perspective
   distortion, dramatic shadows, text, watermarks). Doctrine in
   [`ai-generation.md`](references/ai-generation.md) §6.
3. **Control the structure.** For anything that must tessellate or hold true perspective,
   condition with ControlNet: depth (massing), MLSD (architecture lines), lineart/canny
   (exact outlines). The gold-standard workflow is Blender blockout → depth + normal pass →
   dual-ControlNet generation ([`ai-generation.md`](references/ai-generation.md) §4;
   blockout export via Route D or iso-studio, Route E).
4. **Refine.** Upscale with the *creative* camp at resemblance-high / creativity-low to
   sharpen edges without inventing perspective-breaking geometry; need >4× → regenerate at
   a higher base instead. Clean AI edge-halos (semi-transparent fringe) mechanically —
   `tile-validate.py` detects them ([`ai-refinement.md`](references/ai-refinement.md)).
5. **Vectorize** if you need scalable output: Recraft (cleanest) → Vectorizer.AI →
   SVGcode/potrace → Illustrator Image Trace + Expand; re-impose the three-tone plane
   system after tracing ([`ai-refinement.md`](references/ai-refinement.md) §4,
   [`style-guide.md`](references/style-guide.md)).
6. **Check licences before delivery** — LoRA and model licences bite (see Route F and the
   gotcha index).

### Route D — Pre-render from 3D (Blender / three.js)

Model once, bake sprites for eight directions. The web-native alternative to Blender is a
three.js scene.

1. **Rig the ortho camera** at the correct rotation for your projection — **both** rigs are
   in [`blender-prerender.md`](references/blender-prerender.md) §1 (60/0/45 dimetric vs
   54.736/0/45 true iso) with the cube-top verification test.
2. **Blender route.** Drive it headless:
   `blender -b -P assets/blender-iso-rig.py -- --projection dimetric21 --directions 8 --out ./sheet`.
   A parented empty spins the model for N-direction batching; transparent film; one render
   per direction. Add `--passes` for the depth + camera-space normal maps that feed
   ControlNet (Route C).
3. **three.js route.** Owns only the iso delta ([`threejs-orthographic.md`](references/threejs-orthographic.md)):
   exact-rotation idiom (`camera.rotation.order='YXZ'; y=-π/4; x=atan(-1/√2)`),
   frustum sizing with the resize-recompute gotcha, pixel-perfect world→CSS-px mapping,
   render-to-target sprite export at 1×/2×/4×, constrained `OrbitControls`, and 8-direction
   sprite baking in the browser. General scene scaffolding → [`genart-ops`](../genart-ops/SKILL.md).
4. **Feed the tileset pipeline.** Baked sprites re-enter Route B at step 3 (validate) → 4
   (pack) → 5 (engine).

### Route E — Compose a scene (iso-studio)

The companion **iso-studio** scene composer (standalone app, local checkout
`X:\Forge\iso-studio`) stages assets on a snap-to-grid isometric canvas with automatic
depth sorting and a blockout-to-ControlNet export path. See §5 below for the launch
command and status.

1. **Launch** the app (§5), pick a projection, set tile width and grid extent.
2. **Import** PNG/SVG/WebP by drag-drop, paste, or file picker; assets land in the tray.
3. **Place & snap** with full / half / quarter / free snap modes; set each asset's anchor
   and footprint so snapping and sorting stay correct.
4. **Depth** sorts automatically by `(tileX + tileY)`, then elevation, then zBias, across
   ground / props / overlay layers.
5. **Export** PNG at 1×/2×/4× (transparent, cropped) or save the scene as JSON conforming
   to the app repo's `scene-schema.json` (version "1.0").
6. **Blockout → ControlNet** (v2 feature): place flat-shaded grey primitives and export a
   depth-map / lineart render that conditions the AI pipeline (Route C, step 3).

### Route F — Source existing assets (licences)

Do not draw what you can legally reuse — but check the licence *before* delivery.

1. **CC0 first** — Kenney iso packs, itch.io CC0 sets (Screaming Brain's 1,008 floors,
   etc.), OpenGameArt ([`asset-sourcing.md`](references/asset-sourcing.md)).
2. **Marketplaces** — IconScout, Flaticon (attribution on free), Icons8, Streamline,
   Iconify, DrawKit, Blush, Storyset, Icograms.
3. **The procurement rule** — before client delivery verify current plan + current licence +
   **AI-training clause**. "Commercial use permitted" ≠ "dataset use permitted" (DrawKit
   explicitly forbids AI training). Track attribution; prefer SVG source over PNG.

---

## 3. Scripts

All scripts follow the [Skill Resource Protocol](../../docs/SKILL-RESOURCE-PROTOCOL.md):
stdout = data only, semantic exit codes, `--help` with EXAMPLES, `--json` envelopes.
Pure-stdlib scripts run with `python`; Pillow scripts use PEP 723 inline metadata via
`uv run` (on this Windows machine avoid the Store `python3` stub — it exits 49).

| Script | What it does | Launch |
|---|---|---|
| [`iso-math.py`](scripts/iso-math.py) | Canonical constants, tile↔screen transforms, SVG grids, CSS/SVG/Illustrator/Figma transform recipes | `python scripts/iso-math.py constants --projection true --json` · `… to-screen 3 2 --tile-w 64 --tile-h 32` · `… grid-svg --projection dimetric21 --tile-w 64 --extent 8 > grid.svg` · `… transforms --target css-3d` |
| [`tile-validate.py`](scripts/tile-validate.py) | QA gate for (especially AI) tiles: dimension, alpha-halo, edge-bleed, anchor, palette checks; exit 10 on violation | `uv run scripts/tile-validate.py --tile-w 64 --tile-h 32 tiles/*.png` |
| [`sheet-pack.py`](scripts/sheet-pack.py) | Pack a tiles directory into a spritesheet PNG + JSON atlas; `--trim --padding N --pot`, deterministic order | `uv run scripts/sheet-pack.py tiles/ --trim --padding 2 --pot` |
| [`check-iso-facts.py`](scripts/check-iso-facts.py) | §7 staleness verifier: `--offline` asserts constants + reference citations; `--live` npm-checks named packages (exit 7 advisory / 10 drift) | `python scripts/check-iso-facts.py --offline` |

## 4. Assets

| Asset | What it is | Use |
|---|---|---|
| [`prompt-library.md`](assets/prompt-library.md) | Ready-to-paste prompt scaffolds by target tool (city block, room cutaway, floating island, warehouse, control room, dashboard, sprite tileset, icon) + universal negative block + Midjourney/Firefly/Recraft/Flux cheatsheets | Route C, step 2 |
| [`palettes/three-tone-presets.json`](assets/palettes/three-tone-presets.json) | 8 three-tone presets (`kenney-prototype-grey`, `pastel-dollhouse`, `industrial-muted`, `cyberpunk-teal-violet`, `blueprint`, `earthy-game`, `mono-ink`, `brand-neutral`); top-lightest verified by WCAG luminance | Route A/B, [`style-guide.md`](references/style-guide.md) |
| [`grids/`](assets/grids/) | Pre-generated `true-iso-{32,64,128}.svg` and `dimetric-2to1-{32,64,128}.svg` (line slope 0.5 dimetric / tan30° true iso) | Route A, backdrops |
| [`blender-iso-rig.py`](assets/blender-iso-rig.py) | Headless Blender ortho-rig + N-direction sprite baker + optional depth/normal passes | Route D, step 2 |
| **iso-studio** (external) | The zero-dependency scene composer — standalone repo at `X:\Forge\iso-studio` (github.com/0xDarkMatter/iso-studio), owns `scene-schema.json` + the asset library; pointer: [`iso-studio.md`](references/iso-studio.md) | Route E, §5 |

## 5. iso-studio — the scene composer (standalone app)

**iso-studio** is a zero-dependency, no-build isometric scene composer that grew out of
this skill and now lives in its own repository — local checkout `X:\Forge\iso-studio`,
remote `github.com/0xDarkMatter/iso-studio` (`index.html` + `server.mjs`, no npm deps).
Launch it, then work the docked palettes:

```
node X:\Forge\iso-studio\server.mjs      # then open http://localhost:4323
PORT=8080 node X:\Forge\iso-studio\server.mjs
```

- **Canvas + Grid** — projection selector (2:1 dimetric / true isometric / custom angle),
  tile W×H (H is derived-and-locked for the two named projections), grid extent, and a
  full / half / quarter / free snap segmented control.
- **Asset tray** — drag-drop, clipboard-paste, or file-picker import (PNG/SVG/WebP, stored
  as data URIs so scenes are self-contained); click-to-place, stays armed for rapid
  placement.
- **Depth sorting** — automatic `(x+y) → elevation → layer → zBias` sort across
  ground / props / overlay, matching the doctrine in
  [`coordinates-depth.md`](references/coordinates-depth.md) exactly.
- **Inspector, Scene, Export palettes** — anchor/footprint/elevation/scale/flip/zBias
  editing; background/checkerboard/canvas size; PNG export at 1×/2×/4× (crop-to-content,
  transparent), SVG export (gated — every placed asset must be SVG-sourced), and scene
  JSON save/load conforming to the app repo's `scene-schema.json` (version "1.0").
- **Blockout mode (signature feature)** — place flat-shaded three-tone grey primitives
  (box / slab / ramp / cylinder) and export a **depth map** and a **lineart** render sized
  to the canvas; both condition the ControlNet step of the AI pipeline
  ([`ai-generation.md`](references/ai-generation.md) §4) without touching Blender.
- **Undo/redo** (`Ctrl+Z` / `Ctrl+Y`, ≥50 steps, drag-moves and rapid nudges coalesced
  into single entries) and the full hotkey legend via `?` in-app.

The full manual — workspace tour, projection/snap configuration, anchor-at-feet
discipline, the complete hotkey table, the scene-JSON schema walkthrough, the
blockout → depth/lineart → ControlNet round trip step by step, and a "known limits"
section (depth export is per-instance flat grey, elevation-aware but not per-face;
`flipX` mirrors a ramp's slope, no-op on symmetric primitives) — lives in the app repo
at `docs/MANUAL.md`; this skill's [`references/iso-studio.md`](references/iso-studio.md)
is the quickstart pointer.

---

## 6. Gotcha index — the top 10 footguns

| # | Footgun | Fix | Reference |
|---|---|---|---|
| 1 | **Mislabelled dimetric** — calling 2:1 game tiles "isometric" and cutting them to a 30° grid; tiles don't tessellate | Game tiles are **2:1 dimetric at 26.565°**; write the exact angle into the tile spec | [`projection-math.md`](references/projection-math.md) §2/§4, [`tile-spec.md`](references/tile-spec.md) |
| 2 | **Skew without scale** — shearing a flat asset onto the iso axes but skipping the `cos(30°)=0.86603` vertical scale; right axes, wrong height, won't stack | Run the full **Scale → Shear → Rotate**; build on the iso plane, never skew-and-call-it-done | [`projection-math.md`](references/projection-math.md) §3.2/§3.3 |
| 3 | **Centre anchors break y-sort** — a tall sprite's centre is high on screen, so a centre-based sort draws it behind nearer objects | Anchor every sprite at its **visual feet** (ground contact); the sort key uses the tile it stands on | [`coordinates-depth.md`](references/coordinates-depth.md) §8 |
| 4 | **Elevation folded into the depth key** — using `x+y+z` makes a tall near object sort behind a short far one | `z` is a **tie-breaker after** `(x+y)`, never added into it: `(x+y, z, layer, zBias)` | [`coordinates-depth.md`](references/coordinates-depth.md) §5/§7 |
| 5 | **Unity near-clip clipping** — default near plane hides geometry behind the ortho camera on the XZ map | Push near clip to a large negative (−1000+); Stable Fit → Close Fit shadows; disable cascades | [`engine-integration.md`](references/engine-integration.md) §2 |
| 6 | **Ortho frustum not recomputed on resize** — the iso view stretches when the viewport changes | Recompute aspect-scaled left/right/top/bottom in the resize handler; update the projection matrix | [`threejs-orthographic.md`](references/threejs-orthographic.md) §3 |
| 7 | **AI halo edges** — semi-transparent fringe around AI-generated tiles that shows as a seam | Alpha-threshold / defringe; `tile-validate.py` flags halo % mechanically | [`ai-refinement.md`](references/ai-refinement.md) §3 |
| 8 | **Licence AI-training clause** — "commercial use OK" is not "dataset use OK"; DrawKit forbids AI training | Verify plan + licence + **AI-training clause** before client delivery | [`asset-sourcing.md`](references/asset-sourcing.md) |
| 9 | **Flux-dev LoRA licences** — Flux.1-dev derivatives are **non-commercial**; shipping them in a client project is a violation | Check each LoRA's licence flag; prefer permissively-licensed adapters for commercial work | [`ai-generation.md`](references/ai-generation.md) §2/§7 |
| 10 | **Staircasing & the >4× upscale trap** — 30° lines staircase in pixel art; pushing an upscaler past 4× invents perspective-breaking detail | Commit to 2:1 pixel-neat stepping; above 4× **regenerate at a higher base**, don't upscale | [`pixel-art-workflow.md`](references/pixel-art-workflow.md) §1, [`ai-refinement.md`](references/ai-refinement.md) §1 |

---

## Related skills

[`genart-ops`](../genart-ops/SKILL.md) (general three.js / creative coding) ·
`threejs-ops` (app/game-scale three.js: GLTF, r3f, `InstancedMesh`) ·
[`color-ops`](../color-ops/SKILL.md) (colour science, OKLCH ramps) ·
[`frontend-design`](../frontend-design/SKILL.md) (production UI craft) ·
[`playwright-ops`](../playwright-ops/SKILL.md) (headless render verification).
