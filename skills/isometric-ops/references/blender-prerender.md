# Blender Pre-Rendering for Isometric Assets

Pre-rendering 3D geometry into 2D isometric sprites is the production route classic and
modern isometric games actually use — *Age of Empires*, *Factorio*, and *Hades* all bake
high-fidelity 3D models to 2D sprite sheets rather than rendering isometric scenes in
real time.[^grid-dynamics] Blender is the free, scriptable tool of choice for this:
model once, render every camera direction, ship flat PNGs to any 2D engine.

This file owns the Blender-specific delta: camera rigs, batch rendering, the
depth/normal-pass export used to condition AI generation, and projecting AI output back
onto geometry. For the web-native alternative (rendering isometric sprites straight out
of a three.js scene, no Blender required), see
[`threejs-orthographic.md`](threejs-orthographic.md). For the underlying angle math, see
[`projection-math.md`](projection-math.md). For post-render QA, see
[`../scripts/tile-validate.py`](../scripts/tile-validate.py).

**The projection decision comes first**, per [`projection-math.md`](projection-math.md):
decide *true isometric* (81.65% axonometric foreshortening, all three cube faces
render equal) or *2:1 dimetric* (commonly called isometric in games; game tile
rendering, cube top is exactly 2× as wide as tall) before touching the camera. The two
rigs below are not interchangeable and mixing them across a set is the single most
common isometric-pre-render mistake.

---

## 1. The two camera rigs (headline distinction)

Most tutorials present only one rig and treat it as "the" isometric camera. It isn't —
there are two correct rigs for two different projections, and conflating them produces
tiles that don't tile or illustrations that read as subtly "off." **Both rigs below must
be considered whenever an isometric Blender pipeline is discussed; picking the wrong one
for the job is the signature footgun this reference exists to prevent.**

| Target | Camera rotation (XYZ, degrees) | Projection type | Verification test |
|---|---|---|---|
| 2:1 dimetric game tiles | **RotX 60°, RotY 0°, RotZ 45°** | 2:1 dimetric (not true isometric) | Rendered cube top face is exactly **2× as wide as tall** — elevation angle is 30° above the horizon, and sin(30°) = 0.5, which is the 2:1 pixel ratio the whole "game isometric" convention is built on. |
| True isometric | **RotX 54.736°, RotY 0°, RotZ 45°** | True isometric (all axes at 120°, cube tilt 35.264°) | **All three visible cube faces render as equal parallelograms** — no face looks "flatter" than another. 54.736° = 90° − 35.264° (arctan(√2)); this is the camera-elevation form of the same true-iso angle used everywhere else in this skill. |

Both rigs use an **orthographic** camera — never a perspective camera; a perspective
lens introduces vanishing points, which is the #1 giveaway that breaks the isometric
illusion no matter how the rotation is set.

Why both exist in the wild, unlabeled: Clint Bellanger's widely-cited Blender tutorial
("Isometric Tiles in Blender") uses the 60/0/45 rig and explicitly verifies the "cube top
2× as wide as tall" check[^bellanger] — that is the 2:1 dimetric rig, correct for pixel
game tiles, and is what most "Blender isometric" tutorials teach because most people
asking are making game tiles. The ControlNet ortho-to-AI workflow (§3 below) instead uses
54.736/0/45 — true isometric — because it targets illustrative renders (architecture,
cutaways, hero art) where equal-face fidelity matters more than 2:1 pixel-grid tiling.
**Neither tutorial is wrong; they are solving different problems.** State which one you
need before opening Blender. A Blender Artists forum thread on "Creating an Isometric
Camera" independently confirms the historical footgun: ortho angles that merely "look
isometric" by eye are usually **trimetric**, not true isometric or 2:1 dimetric, and a
commenter there calls this out explicitly — always dial in the exact rotation numbers
above rather than eyeballing the viewport.[^blenderartists]

### Camera placement (both rigs)

Position is far less exacting than rotation for an orthographic camera — since ortho
projection has no perspective falloff, *where* the camera sits along its view vector
doesn't change the render, only *how far back* it needs to be to fit the subject inside
the ortho scale. Bellanger's tutorial places the camera at a sample offset such as
LocX=10, LocY=−10, LocZ=10 (a diagonal position consistent with a 45° Z-rotation looking
back at the origin) purely to keep it clear of geometry — treat the exact coordinates as
illustrative, not load-bearing; only the **rotation** and **orthographic scale** are
load-bearing.[^bellanger]

- **Orthographic Scale** (Camera Data Properties → Lens → Orthographic Scale) sets the
  world-space width the camera frame captures. Pick a scale so your subject (a 1×1 tile
  cube, a building footprint) fills the frame with your intended margin; keep this value
  **identical across every direction render in a set** so all sprites share one
  world-to-pixel ratio. Changing it between renders is the classic cause of a spritesheet
  where objects mysteriously change size between frames.
- **Clip distances**: push `Clip Start` low and `Clip End` high enough that geometry
  never gets clipped as the rig rotates around it (the same failure mode documented for
  Unity's near-clip in [`engine-integration.md`](engine-integration.md) — an orthographic
  camera with a tight clip plane will silently clip corners of tall geometry that a
  perspective camera's wider frustum tolerated).
- **Film → Transparent** (Render Properties → Film) — enable transparent background so
  the render composites cleanly as a sprite with alpha, not a scene with a solid backdrop
  baked in.

---

## 2. 8-direction rig via a parented empty, and batch rendering

The production pattern for "one asset, every direction" is a **parented pivot empty**:
the camera is parented to an Empty placed at the world origin (or the asset's pivot
point); rotating the *empty* around its local Z axis rotates the camera around the
subject while preserving the camera's own tilt (RotX / the 60° or 54.736° elevation).
This gives clean, exact rotation increments instead of re-deriving camera position by
hand for each direction.

1. Add an **Empty** (Plain Axes is fine) at the asset's pivot — usually world origin, or
   the point that should stay fixed as the asset "turns."
2. Parent the camera to the empty (`Ctrl+P` → Object, keep transform) so the camera's
   *local* rotation (its RotX from the table above, RotZ 45°) is preserved relative to
   the empty.
3. To get **N directions**, rotate the empty's world Z rotation in `360° / N` steps and
   render at each step:
   - **4-direction** (top-down four-quadrant view, common for simple tile sprites): step
     90°.
   - **8-direction** (the standard for isometric character/prop sprites — N, NE, E, SE,
     S, SW, W, NW): step 45°. This is the QWeb "Creating an isometric rig in Blender"
     pattern — animate the empty's rotation across 8 keyframes and batch-render one frame
     per direction in a single click, using a downloadable pre-built rig as the
     reference implementation.[^qweb]
4. Keep the **camera's own rotation fixed** (RotX = 60° or 54.736°, RotZ = 45° per the
   rig table) — only the empty's Z rotation changes between frames. Never touch the
   camera's RotX per-direction; if a direction render looks "wrong," the bug is almost
   always an accidentally-nudged camera, not a math error.
5. Batch by looping empty-rotation → render → save-as-numbered-frame, either via
   Blender's built-in animation render (one keyframe per direction, render as an image
   sequence) or headlessly with `assets/blender-iso-rig.py --directions N` (§5) which
   automates exactly this loop from the CLI.

### Sprite-sheet output

Render each direction to its own numbered PNG (`name_dir00.png` … `name_dir07.png` for
8-direction), transparent background, identical orthographic scale and resolution across
all frames. Do **not** try to composite the sheet inside Blender — hand the per-direction
PNGs to [`scripts/sheet-pack.py`](../scripts/sheet-pack.py), which packs a directory of
tiles into one spritesheet PNG plus a JSON atlas (frame `{x,y,w,h,trimmed,sourceW,
sourceH}` per name) — Blender's compositor is the wrong tool for atlas packing; use the
purpose-built script downstream of the render.

### Modern pixelation post-processing

For pixel-art-styled games, render at a comfortably high resolution (e.g. 512² or 1024²)
with anti-aliasing on for clean edges, then **downsample and posterize/pixelate as a
post-process** rather than trying to render native low-res — this is the workflow
demonstrated in community tutorials on rendering and pixelating isometric assets in
Blender, and it produces cleaner results than forcing Blender's renderer to output
native low-res pixel art directly.[^pixelate-tutorial] Downsampling with a box/nearest
filter to the target tile resolution (e.g. 512² → 64²) after rendering at high
resolution avoids the jagged, uncontrolled aliasing that comes from rendering natively
small. Feed the downsampled output through
[`scripts/tile-validate.py`](../scripts/tile-validate.py) `--max-colors` to confirm the
palette stayed within your target budget after any smoothing/dithering step.

---

## 3. Depth pass and camera-space normal pass export (for ControlNet conditioning)

When the goal is AI-generated final art that is perspective-*locked* to a 3D blockout
(see [`ai-generation.md`](ai-generation.md) for the full decision ladder and ControlNet
theory), Blender's job shifts from "renderer of final sprites" to "renderer of
*conditioning maps*" — a depth pass and a camera-space normal pass, both exported as
flat images and fed into Stable Diffusion's ControlNet as structural guides. This is
steps 1–3 (of a 5-step pipeline) of the Blender→ControlNet workflow; step 4
(ControlNet + Stable Diffusion generation) belongs to
[`ai-generation.md`](ai-generation.md) and is only summarized here for continuity.

### Step 1 — Model and configure the camera

Build a simple 3D blockout of the target scene using primitive geometry — walls, support
beams, crates, barrels; massing and silhouette matter far more than surface detail at
this stage, since the blockout only needs to condition depth/normal maps, not appear in
the final render. Set the camera to **Orthographic** and rotate it to the **true
isometric** rig: **RotX 54.736°, RotZ 45°** (the true-iso row of the rig table in §1 —
this workflow specifically wants true isometric, not the 2:1 dimetric game rig, because
the target output is illustrative cutaway/scene art, not tiling game sprites). Isolate
and scale up any complex assets (barrels, crates) within the camera frame so their
geometric detail is clearly captured in the depth/normal passes — a barrel that occupies
4 pixels of the frame will bake to a useless depth blob.[^src-b-step1]

### Step 2 — Render and export the depth map (Z-pass)

1. `View Layer Properties → Passes → Data` → enable the **Z** pass.
2. In the **Compositing** workspace, connect the render layer's Z output through a
   Normalize node (or Map Range, clamped to the scene's near/far bounds) into a grayscale
   output — this converts raw depth values into a high-contrast grayscale gradient where
   **near geometry renders white and far geometry renders black** (or the inverse,
   depending on the ControlNet depth preprocessor's expected convention — check which
   polarity your target preprocessor/model expects before exporting).
3. Export the composited grayscale image as the depth guide — this is the file that gets
   loaded into ControlNet's Depth unit in step 4.[^src-b-step2]

### Step 3 — Bake and export the camera-space normal map

1. Create a dedicated shader material whose sole job is to encode surface normals as RGB
   color, so that rendering the scene with this material assigned produces a normal map
   image instead of a lit render.
2. In the Shader Editor: `Geometry` node → `Normal` output → `Vector Transform` node, set
   to convert **World Space → Camera Space**. This step is what makes the normal map
   *camera-space* rather than *world/object-space* — camera-space normals are what most
   ControlNet "normal" preprocessors/models expect, since they encode which way each
   surface faces relative to the *view*, not relative to the world.
3. Feed the transformed vector through a `Multiply-Add` math node to remap the
   [−1.0, 1.0] vector-component range into the standard [0.0, 1.0] RGB image range
   (multiply by 0.5, add 0.5 — the conventional tangent-to-RGB normal-map encoding).
4. Assign this material to every model in the scene (a temporary material override, or a
   dedicated render layer with the override applied), render the viewport from the same
   isometric camera used for the depth pass, and save the result as the camera-space
   normal map.[^src-b-step3]

Both exported maps (depth + normal) must come from the **exact same camera transform**
used for step 1 — any camera nudge between the two passes desynchronizes them and the
dual-ControlNet conditioning in step 4 will fight itself.

### Step 4 (pointer only) — ControlNet conditioning + generation

Covered in full in [`ai-generation.md`](ai-generation.md): load the depth map into a
Depth ControlNet unit and the normal map into a Normal ControlNet unit in
AUTOMATIC1111/ComfyUI, generate with the documented parameters (Euler, ~15 steps, 768²,
CFG 7), using the prompt/negative-prompt doctrine described there. Do not duplicate that
material here — this file's job ends at "export two clean conditioning images from
Blender."

---

## 4. Step 5 — Texture projection mapping: AI output back onto geometry

Once the AI has synthesized high-resolution, perspective-locked texture art
(step 4, elsewhere), the workflow closes the loop by projecting that art back onto the
original 3D blockout:

1. Import the synthesized AI image(s) back into the Blender project as image textures.
2. Use **texture projection mapping** (Blender's UV Project modifier, or manual "Project
   From View" UV unwrapping) to project the generated texture from the **camera's exact
   coordinates** — the same orthographic camera and transform used to export the
   depth/normal passes — directly onto the 3D models. Because the projection uses the
   identical camera the AI image was conditioned against, this automatically produces
   accurate UV coordinates with no manual re-alignment.
3. With projection mapping complete, bake the projected texture into a flat, standard UV
   map per object, apply conventional PBR material properties on top of the baked
   texture, and light the scene normally in Blender.
4. The payoff: because the texture is now baked into real UVs on real geometry (not just
   a flat billboard), the scene can be **re-rendered from multiple lighting angles or
   re-lit dynamically**, producing a family of consistent isometric sprites/frames from
   one AI-conditioned texture pass rather than needing a fresh AI generation per lighting
   variant.[^src-b-step5]

This is the highest-effort tier of the isometric AI pipeline — reserve it for hero
assets or asset families that need lighting variation; one-off sprites are usually
better served by generating directly at the target angle (see the decision ladder in
[`ai-generation.md`](ai-generation.md)) without the round-trip through Blender geometry.

---

## 5. Driving it with `assets/blender-iso-rig.py`

The skill ships `assets/blender-iso-rig.py` to automate §1 (rig construction) and §2
(N-direction batch rendering) so a team doesn't hand-build the empty/camera parenting
every time. Documented here per the Resource Protocol contract; see the script's own
`--help` and first-comment-block for the authoritative, current interface.

**Invocation (headless, inside Blender's bundled Python):**

```
blender -b -P assets/blender-iso-rig.py -- --projection dimetric21|true --directions 8 --out DIR [--resolution N]
```

- Everything **before** the bare `--` is consumed by Blender itself (`-b` = background/
  headless, `-P` = run this Python file); everything **after** `--` is the script's own
  argv — this split is a Blender convention, not a choice this script makes, and it's
  the reason the CLI can't be `blender -b -P script.py --projection true` (Blender would
  swallow `--projection` as one of its own flags).
- `--projection dimetric21` selects the **RotX 60°, RotZ 45°** rig (§1); `--projection
  true` selects **RotX 54.736°, RotZ 45°**. The script's `argparse` default is
  `dimetric21` (confirm with `--help`) — but treat that as a convenience for the common
  game-tile case, not license to skip the decision: the projection choice is still the
  first decision per this skill's doctrine (§1), and passing `--projection` explicitly
  every time is the way to avoid silently shipping the wrong rig for an illustrative
  (true-isometric) job.
- `--directions N` builds the parented-empty rig (§2) with N evenly-spaced rotations
  (`360/N` per step) — `4` and `8` are the common values; the empty's rotation step and
  the camera's own rig rotation (RotX/RotZ) are independent and the script must not
  conflate them.
- `--out DIR` is the output directory for the numbered per-direction renders
  (`name_dir00.png` … `name_dir{N-1}.png`), transparent film, one orthographic-scale
  value held constant across all frames per §2.
- `--resolution N` sets the square render resolution in pixels (applies to both width
  and height — isometric sprite renders are conventionally square-canvas even when the
  final sprite content isn't square, so downstream trimming in
  [`scripts/sheet-pack.py`](../scripts/sheet-pack.py) `--trim` has clean margin to work
  with).

**Two run modes, by design:**

- **GUI-run (no CLI args, launched by opening the `.py` in Blender's Text Editor and
  pressing Run, or via Blender's normal windowed startup):** builds the camera + empty
  rig only — no render, no `--out` required. This lets an artist inspect the rig in the
  3D viewport, nudge the orthographic scale to frame their asset, and render manually
  or resume the headless batch path once satisfied.
- **Headless (`blender -b -P … -- --out DIR`):** builds the rig *and* renders every
  direction to `--out`, suitable for CI/batch pipelines with no display.

**Degrading gracefully outside Blender.** This file is plain Python but only runs
correctly inside Blender's bundled interpreter, which provides the `bpy` module. Running
it under a system Python (`python assets/blender-iso-rig.py`) must not crash with a raw
`ModuleNotFoundError` traceback — per the Resource Protocol's agent-safety rule, the
script catches the `bpy` import, prints a helpful stderr message naming the correct
invocation (`blender -b -P assets/blender-iso-rig.py -- --help`), and exits with the
protocol's `5` (PRECONDITION — environment issue, wrong interpreter) rather than an
uncaught exception. `--help` (run under either interpreter, since argument parsing
should not itself require `bpy`) prints the usage above plus worked EXAMPLES per the
first-comment-block contract in
[`SKILL-RESOURCE-PROTOCOL.md`](../../../docs/SKILL-RESOURCE-PROTOCOL.md).

---

## Footnotes / sources

[^grid-dynamics]: The pre-render pipeline pattern (*Age of Empires*, *Factorio*, *Hades*
    baking 3D-to-2D sprite sheets) — SRC-B, "3D-to-2D Pre-Rendering Pipeline" section.
[^bellanger]: Clint Bellanger, "Isometric Tiles in Blender" — the canonical tutorial for
    the 60/0/45 dimetric rig and the "cube top 2× as wide as tall" verification test;
    cited via SRC-A's Blender-for-isometric-rendering catalog.
[^blenderartists]: Blender Artists forum, "Creating an Isometric Camera" — documents the
    true-iso rig and the historical orthographic-scale bug (fixed in Blender 2.49+); a
    commenter's correction that eyeballed "nice-looking" ortho angles are typically
    trimetric, not true isometric — cited via SRC-A.
[^qweb]: QWeb, "Creating an isometric rig in Blender" — the parented-empty, 8-frame
    animated-rotation batch-render pattern with a downloadable pre-built rig — cited via
    SRC-A.
[^pixelate-tutorial]: Community tutorial, "Rendering Isometric Assets & Pixelating
    Renders [In Blender]" — the render-high/downsample-to-pixelate post-process pattern —
    cited via SRC-A.
[^src-b-step1]: SRC-B, "3D-to-2D ControlNet Rendering Workflow in Blender," Step 1
    (Modeling and Camera Configuration).
[^src-b-step2]: SRC-B, ibid., Step 2 (Rendering and Exporting the Depth Map / Z-Pass).
[^src-b-step3]: SRC-B, ibid., Step 3 (Baking and Exporting the Normal Map).
[^src-b-step5]: SRC-B, ibid., Step 5 (Texture Projection Mapping in Blender).

**Source documents** (paths as supplied to the isometric-ops build):
SRC-A = `compass_artifact_wf-75a0e032-3465-48c7-84ea-e104bae213c2_text_markdown.md`
(Blender-for-isometric-rendering catalog); SRC-B = "Engineering and Aesthetic Standards
for Isometric Design" (3D-to-2D ControlNet Rendering Workflow section, steps 1–3 and 5).
