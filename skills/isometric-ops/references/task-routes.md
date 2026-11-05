# Task Routes C, D and F: Full Steps

The full numbered steps for three of SKILL.md's six task routes. Routes A (web illustration) and B (game tileset) stay inline in SKILL.md; route E (compose a scene) lives with the app in [iso-studio.md](iso-studio.md).

### Route C — AI pipeline (generate → control → refine → vectorize)

Fast, but perspective drifts without structure control. Pick the model by what the output
must *be*, then hold the geometry with ControlNet.

1. **Climb the decision ladder** ([`ai-generation.md`](ai-generation.md) §1):
   editable vectors → Recraft (vector-native); hero raster → Midjourney `--sref`/`--sw`
   (+ Firefly for brand-safe vector with Content Credentials); local control / tilesets →
   Flux/SDXL + iso LoRA + ControlNet; consistent large sets → a custom-trained model
   (Scenario/Layer) on 10–20 on-style refs.
2. **Prompt** from the ready scaffolds in [`assets/prompt-library.md`](../assets/prompt-library.md)
   — subject + projection + material language + simplification rule + lighting rule +
   output intent, plus the universal negative-prompt block (vanishing points, perspective
   distortion, dramatic shadows, text, watermarks). Doctrine in
   [`ai-generation.md`](ai-generation.md) §6.
3. **Control the structure.** For anything that must tessellate or hold true perspective,
   condition with ControlNet: depth (massing), MLSD (architecture lines), lineart/canny
   (exact outlines). The gold-standard workflow is Blender blockout → depth + normal pass →
   dual-ControlNet generation ([`ai-generation.md`](ai-generation.md) §4;
   blockout export via Route D or iso-studio, Route E).
4. **Refine.** Upscale with the *creative* camp at resemblance-high / creativity-low to
   sharpen edges without inventing perspective-breaking geometry; need >4× → regenerate at
   a higher base instead. Clean AI edge-halos (semi-transparent fringe) mechanically —
   `tile-validate.py` detects them ([`ai-refinement.md`](ai-refinement.md)).
5. **Vectorize** if you need scalable output: Recraft (cleanest) → Vectorizer.AI →
   SVGcode/potrace → Illustrator Image Trace + Expand; re-impose the three-tone plane
   system after tracing ([`ai-refinement.md`](ai-refinement.md) §4,
   [`style-guide.md`](style-guide.md)).
6. **Check licences before delivery** — LoRA and model licences bite (see Route F and the
   gotcha index).

### Route D — Pre-render from 3D (Blender / three.js)

Model once, bake sprites for eight directions. The web-native alternative to Blender is a
three.js scene.

1. **Rig the ortho camera** at the correct rotation for your projection — **both** rigs are
   in [`blender-prerender.md`](blender-prerender.md) §1 (60/0/45 dimetric vs
   54.736/0/45 true iso) with the cube-top verification test.
2. **Blender route.** Drive it headless:
   `blender -b -P assets/blender-iso-rig.py -- --projection dimetric21 --directions 8 --out ./sheet`.
   A parented empty spins the model for N-direction batching; transparent film; one render
   per direction. Add `--passes` for the depth + camera-space normal maps that feed
   ControlNet (Route C).
3. **three.js route.** Owns only the iso delta ([`threejs-orthographic.md`](threejs-orthographic.md)):
   exact-rotation idiom (`camera.rotation.order='YXZ'; y=-π/4; x=atan(-1/√2)`),
   frustum sizing with the resize-recompute gotcha, pixel-perfect world→CSS-px mapping,
   render-to-target sprite export at 1×/2×/4×, constrained `OrbitControls`, and 8-direction
   sprite baking in the browser. General scene scaffolding → [`genart-ops`](../../genart-ops/SKILL.md).
4. **Feed the tileset pipeline.** Baked sprites re-enter Route B at step 3 (validate) → 4
   (pack) → 5 (engine).

### Route F — Source existing assets (licences)

Do not draw what you can legally reuse — but check the licence *before* delivery.

1. **CC0 first** — Kenney iso packs, itch.io CC0 sets (Screaming Brain's 1,008 floors,
   etc.), OpenGameArt ([`asset-sourcing.md`](asset-sourcing.md)).
2. **Marketplaces** — IconScout, Flaticon (attribution on free), Icons8, Streamline,
   Iconify, DrawKit, Blush, Storyset, Icograms.
3. **The procurement rule** — before client delivery verify current plan + current licence +
   **AI-training clause**. "Commercial use permitted" ≠ "dataset use permitted" (DrawKit
   explicitly forbids AI training). Track attribution; prefer SVG source over PNG.
