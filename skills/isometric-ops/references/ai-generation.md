# AI Generation of Isometric Assets

The deep chapter. This file covers **generating** isometric assets with AI — model
selection, LoRA/style control, ControlNet-conditioned structure, the Blender-blockout
pipeline, and prompt doctrine. It stops at the point where a raster generation exists.

- **Refining** what you generated — upscaling, vectorization, edge-halo cleanup —
  lives in [`ai-refinement.md`](ai-refinement.md). Generate here, refine there.
- **Ready-to-paste prompt scaffolds** live in
  [`assets/prompt-library.md`](../assets/prompt-library.md). This file teaches the
  *doctrine*; that file is the copy-paste bank.
- **Plane/shadow/palette rules** the prompts and post-processing enforce live in
  [`style-guide.md`](style-guide.md) (three-tone shading, one light direction,
  scale grammar).
- **The projection decision** — true iso vs 2:1 dimetric vs pixel-neat — is upstream of
  everything and lives in [`projection-math.md`](projection-math.md). Decide it *before*
  you write a single prompt; the prompt names the projection.

> **Terminology.** Games call their 2:1 grid "isometric" but it is **2:1 dimetric
> (commonly called isometric in games)**, at 26.565° (arctan 1/2), not the 30° / 120°
> of true isometric. AI models trained on game art will happily give you dimetric when
> you ask for "isometric." If you need *true* iso (equal foreshortening, 30° axes) you
> must condition structure with ControlNet or a 3D blockout — text prompts alone do not
> reliably hit true iso. See `projection-math.md` for why.

> **Volatility.** AI-tool facts (model versions, LoRA URLs, Midjourney params, pricing,
> upscaler tiers) move fast. Every volatile figure below is date-stamped **"as of
> July 2026"** and kept in grep-able tables. Re-verify on the vendor's live docs before
> committing to a pipeline — `scripts/check-iso-facts.py --live` exists to catch drift
> in the named packages.

---

## 1. The decision ladder — pick the model by what the output must *be*

The single most consequential choice is made before any prompt: **what does the final
asset need to be, and how many of them need to match?** That determines the model, not
the subject matter.

```
                          ┌─ Editable VECTORS (icons, SVG UI illustration)?
                          │     → Recraft (vector-native — generates real SVG, not traced)
                          │       + Adobe Firefly when brand-safe vector + Content
                          │         Credentials matter (see §7 ethics)
                          │
  What must the output ───┼─ ONE hero RASTER (marketing, landing-page centerpiece)?
      be, and how         │     → Midjourney + --sref / --sw for a locked style
      many must match?    │       (+ Firefly Text-to-Vector if it must become editable)
                          │
                          ├─ LOCAL control / a game TILESET you'll iterate on?
                          │     → Flux or SDXL + a named isometric LoRA + ControlNet
                          │       (depth for massing, MLSD/lineart for edges)
                          │
                          └─ A CONSISTENT LARGE SET (dozens of matching assets)?
                                → Scenario / Layer.ai: train a custom model on 10–20
                                  on-style references. The only reliable way to get
                                  dozens of assets that actually match.
```

**Model landscape (as of July 2026):**

| Model / platform | Best for | Output | Commercial / licence note |
|---|---|---|---|
| **Recraft** (V4 / V4.1 engine) | Vector-native iso icons & illustration; low-node SVG | Editable **SVG** + PNG | Free tier makes creations *public*; paid keeps them private + grants full commercial ownership |
| **Adobe Firefly** (Text-to-Vector / Illustrator Text to Vector Graphic) | Brand-safe editable vector, Content Credentials provenance | Editable **AI/SVG/PDF/EPS** inside Illustrator | Creative Cloud subscription; consumes generative credits; requires rights confirmation for custom-model training |
| **Midjourney** | Hero raster, style exploration, strongest general aesthetic | Raster | Paid plans carry commercial-use rights for most users — company-size rules apply; verify per client |
| **FLUX.1 / FLUX.1 Kontext** | Open-weight generation + image-conditioned editing; local control | Raster | **FLUX.1 [dev] outputs OK for commercial use, but the model + derivatives (LoRA weights) are non-commercial** — see §3 |
| **Stable Diffusion XL (SDXL)** | Open ecosystem, ControlNet, LoRA/DreamBooth fine-tuning | Raster | Model-specific Stability licence + acceptable-use policy; verify per org before commercialising |
| **Scenario** (scenario.com) | Style-consistent **tilesets**; DreamBooth-style custom models; game studios | Raster (edit-with-prompts) | Vendor case studies (Ubisoft, InnoGames) are vendor-reported; SOC 2; Unity plugin, API/MCP |
| **Layer.ai** | "AI OS for creative teams"; 40+ style models + custom training; vectorize/upscale/3D | Raster + vector | Pooled-credit pricing; Unity Verified Solution |
| **Recraft V4 "Icon" / "Vector Art" models** | Minimal node count, clean curves | SVG | as above |

**Rules of thumb:**

1. **Match the model to the output need first, subject second.** Needing *editable
   vectors* points at Recraft or Firefly no matter what you're drawing; needing *dozens
   of matching tiles* points at Scenario/Layer no matter how good Midjourney's single
   image is.
2. **Do not blend generations.** Pick *one* strong composition and drive it forward.
   Blending five half-good generations is the most common way to lose plane and scale
   consistency across a set.
3. **When text prompts stop being enough, stop prompting.** Repeatable perspective/
   structure is a ControlNet or custom-model problem (§4, §5), not a prompt-wording
   problem.

---

## 2. LoRA catalog — named isometric adapters (Civitai)

LoRAs (Low-Rank Adaptation adapters) bolt an isometric *style* onto a Flux or SDXL base
checkpoint. The Civitai `isometric` tag lists ~136 iso-tagged models/LoRAs/checkpoints/
embeddings as of July 2026. The high-signal, named ones:

| LoRA | Base | Civitai model ID | Recommended weight / trigger | Licence flag |
|---|---|---|---|---|
| **Isometric Style** v1.0 | SDXL | 158081 | **weight 0.7** (per model page) | verify per-model |
| **Isometric** (kiyomoritaira) | SDXL | 1463579 | start ~0.7 | verify per-model |
| **IsometricPixelFlux** | Flux.1 [dev] | 671566 | start ~0.7 | ⚠ **Flux.1-dev derivative — non-commercial** |
| **Isometric — interior/outdoor building** (oosayam) | SDXL | 461566 | separate interior vs outdoor versions | verify per-model |
| **Isometric & Pixelized View** | SDXL | 153601 | buildings, cutaways, "streamer rooms" | verify per-model |
| **Zavy's Cute Isometric Tiles** | SDXL | — | trigger **`zavy-ctsmtrc, isometric`**; pairs with a transparent-SDXL LoRA | verify per-model |
| **Isometric Dreams** (ktiseos_nyx) | SDXL | 98851 | start ~0.7 | verify per-model |
| **Isometric world 01** | SD1.5 | 91248 | use with ReV Animated + Hires.fix | verify per-model |

**Licence discipline (this is the trap):** LoRAs trained on **FLUX.1 [dev]** inherit its
**non-commercial** derivative restriction. FLUX.1 [dev]'s *generated outputs* may be used
commercially, but the **model weights and their derivatives (any dev-based LoRA) are
licensed non-commercial**. So a Flux-dev iso LoRA is fine for personal/experimental work
and its images are usable, but shipping or redistributing the *adapter* in a commercial
product crosses the licence. Prefer SDXL-based LoRAs (or a properly licensed base) for
commercial pipelines. **Check each model's licence before commercial use** — the flag
column above is a prompt to verify, not a warranty.

> Verify LoRA IDs/availability on Civitai before building a pipeline — the catalog churns.
> `scripts/check-iso-facts.py` tracks the *package* names in prose (§7 verifier); the
> Civitai IDs above are date-stamped July 2026 and must be re-checked live.

Sources: Civitai `isometric` tag and the individual model pages (civitai.com/models/{ID});
FLUX.1 [dev] license, https://huggingface.co/black-forest-labs/FLUX.1-dev.

---

## 3. ControlNet — conditioning structure so perspective holds

Text prompts drift. **ControlNet** conditions the generation on a structural map so the
iso geometry is *enforced*, not hoped for. Three preprocessors matter for iso work:

| ControlNet | Preprocessor / model | Controls | Use for |
|---|---|---|---|
| **Depth** | `control_v11f1p_sd15_depth`, midas / depth_anything | 3D volume, spatial massing | Preserving the *shape and layout* of an iso scene from a depth map |
| **MLSD** | mlsd | Straight lines only | Architecture / building edges — the crisp iso line grammar |
| **Lineart / Canny** | lineart, canny | Exact outlines | Locking precise iso outlines when you already have clean line art |

**Tooling.** In ComfyUI, install **ComfyUI ControlNet Auxiliary Preprocessors**
(`Fannovel16/comfyui_controlnet_aux`) — it supplies the midas / depth_anything / mlsd
preprocessors. ComfyUI-Wiki and OpenArt host drag-and-drop Depth/MLSD/multi-ControlNet
workflows. **LooseControl** (arXiv 2312.03079) extends depth conditioning to 3D-box /
scene-boundary control — useful for laying out an iso scene from primitive boxes.

**When to reach for it:** the moment you need *the same perspective repeatedly* rather
than one-off images — a tileset, a matched prop library, a series. That is the boundary
between "prompt harder" and "condition structure."

Sources: ComfyUI ControlNet Auxiliary Preprocessors
(github.com/Fannovel16/comfyui_controlnet_aux); LooseControl, arXiv 2312.03079.

---

## 4. The Blender-blockout → dual-ControlNet workflow (the gold standard)

For **absolute perspective alignment across a large asset library**, combine a 3D
blockout with ControlNet-conditioned generation. This is the most reliable route to a
matched set at true isometric angles, and it feeds two control maps (depth + normal)
into a dual-ControlNet generation. The Blender-side rig detail (camera rotations, the
60° vs 54.736° distinction, Z-pass and normal-pass compositor node graphs) lives in
[`blender-prerender.md`](blender-prerender.md); here is the AI half, end to end.

**Step 1 — Model & camera in Blender.** Build a simple blockout (walls, beams, crates,
barrels — basic geometry). Add an **orthographic** camera. For **true isometric**, set
**RotX = 54.736°, RotZ = 45°** (this is `90° − 35.264°`; all three cube faces render
equal). For **2:1 dimetric game tiles**, use **RotX = 60°, RotZ = 45°** instead — the
rendered cube top is exactly 2× as wide as it is tall. (Both rigs and the cube-top
verification test are in `blender-prerender.md`; SRC-B's ControlNet workflow uses the
54.736° true-iso rig — correct *for true iso*.)

**Step 2 — Depth map (Z-pass).** `View Layer Properties → Passes → Data → enable Z`. In
the Compositor, route the camera's Z output through a Normalize node to a grayscale
gradient (near = white, far = black). Export as the **depth guide**.

**Step 3 — Camera-space normal map.** Build a shader that maps surface normals to RGB:
connect a **Geometry** node's `Normal` output → a **Vector Transform** node set
**World → Camera** space → a **Multiply-Add** math node that remaps `[−1.0, 1.0]` →
`[0.0, 1.0]` (multiply 0.5, add 0.5). Assign to all meshes, render from the iso camera,
save as the **camera-space normal map**.

**Step 4 — Dual-ControlNet generation.** In your SD interface (e.g. AUTOMATIC1111), load
a stylized checkpoint (SRC-B uses *AyoniMix v6*) with ControlNet 1.1 weights, then set:

| Parameter | Value |
|---|---|
| Sampler | **Euler** |
| Sampling steps | **~15** |
| Resolution | **768 × 768** |
| CFG scale | **7** (enforce structure over creative variance) |
| ControlNet Unit 0 | **Depth** — load the Blender grayscale depth map, `depth` preprocessor + model |
| ControlNet Unit 1 | **Normal** — load the baked camera-space normal map, `normal` preprocessor + model |

Example prompt blocks (SRC-B, medieval-tavern case; note the `(centered:1.5)` and
`(soft shading:0.7)` weighting and the `isometric, orthographic` anchors):

- **Building texture:** `medieval tavern, support beams, stone floor, wood walls,
  building interior, interior, diagram overlook, thunderstorm, isometric cutaway,
  3d render, stylized, intricate, 4k uhd, gradients, (centered:1.5), ambient occlusion,
  (soft shading:0.7), view from above, angular, isometric, orthographic, FXAA`
- **Props (barrels):** `wood barrels, wooden barrels, oak barrel, vertical wood,
  diagram overlook, thunderstorm, isometric cutaway, 3d render, stylized, intricate,
  4k uhd, gradients, (centered:1.5), ambient occlusion, (soft shading:0.7), view from
  above, angular, isometric, orthographic, FXAA`
- **Props (crates):** `old, wooden crates, metal handles, storage crate, dark oak crate,
  storage boxes, ((metal frames)), rusty metal, diagram overlook, thunderstorm,
  isometric cutaway, 3d render, stylized, intricate, 4k uhd, gradients, (centered:1.5),
  ambient occlusion, (soft shading:0.7), view from above, angular, isometric,
  orthographic, FXAA`
- **Negative:** `shadows, torch, fire, lamp, light, cartoon, zombie, disfigured,
  deformed, b&w, black and white, duplicate, morbid, cropped, out of frame, clone,
  photoshop, tiling, cut off, patterns, borders, (frame:1.4), symmetry, signature,
  text, watermark, fisheye, harsh lighting`

**Step 5 — Texture projection mapping back onto geometry.** Import the AI images into
Blender and **project them from the camera's exact coordinates** onto the 3D models
(camera-projection UVs from the orthographic view). Bake into flat UV maps, apply PBR
material properties, set up scene lighting, and you can now re-render the *textured*
asset from multiple lighting angles — consistent, interactive, and grid-aligned. Add a
pixelation post-process here if the target is pixel art.

**Lightweight alternative — iso-studio blockout export.** The Blender route is powerful
but heavy. The bundled **iso-studio** app (`assets/iso-studio/`, launch with
`node server.mjs`) exports a blockout **depth map** (per-instance flat grey, normalized
near-white → far-black — massing-grade conditioning) and a **lineart render** (visible
edges, black on white) directly from a scene composed against
`assets/scene-schema.json` — the same dual-control idea without a full Blender rig.
Stage grey primitives on the grid, export both maps at 1×/2×/4×, and feed them to the
depth + lineart/MLSD ControlNet units exactly as in the Blender workflow above. Full
walkthrough: [`iso-studio.md`](iso-studio.md) §"Blockout → ControlNet".

Sources: SRC-B "3D-to-2D ControlNet Rendering Workflow in Blender" (steps 1–5); SRC-A
Ch. 6 ControlNet section.

---

## 5. Consistent large sets — custom-trained models

When you need **dozens of assets that genuinely match** (a full tileset, a themed prop
library, a character-variation set), neither prompting nor a generic LoRA is enough.
Train a **custom model on 10–20 of your own on-style references** (DreamBooth-style):

- **Scenario** (scenario.com) — creative AI infrastructure for game studios; 500+ base
  models, Unity plugin, API/MCP. Dedicated iso workflows include an **Isometric Tile
  Maker** pipeline and "Dual Reference" (Image-to-Image + ControlNet Structure) to
  *reskin* materials while preserving edges. Vendor-reported: Ubisoft produced 10,000+
  character variations for the isometric *Captain Laserhawk: The G.A.M.E.*; InnoGames
  reports ~50% asset-time reduction. (Vendor case studies — treat the figures as
  vendor-reported, not independently verified.)
- **Layer.ai** — 40+ pre-built style models + custom training; built-in vectorization,
  upscaling, 3D, node-based workflows; Unity Verified Solution.
- **Diffusers + LoRA / DreamBooth (self-hosted)** — the open route. Hugging Face's
  text-to-image + LoRA training docs, the LoRA paper (why low-rank adaptation is
  efficient), the DreamBooth paper (subject-driven tuning), and the `sd-scripts` /
  `kohya_ss` GUI/script layer are the standard toolkit.

**LoRA dataset discipline (the make-or-break):** a good house-style isometric LoRA
dataset is **30–100 tightly curated examples**, all sharing **one projection logic, one
material logic, one shadow logic, and a narrow colour grammar**. If the data mixes
different axonometric rules, the model learns "generic illustration vibe" instead of a
reliable isometric language. Curate ruthlessly: one projection angle, one light
direction, one plane-shading system across the entire dataset. (This mirrors the
[`style-guide.md`](style-guide.md) consistency rules — the dataset must already obey
them.)

Sources: SRC-A Ch. 6 (Scenario, Layer.ai, Diffusers/LoRA/DreamBooth, Grid Dynamics
tutorial); Hugging Face Diffusers docs (huggingface.co/docs/diffusers/en/training/text2image).

---

## 6. Prompt doctrine

The prompt pattern that works is **not** "isometric illustration." It is a six-part
structure:

```
subject + projection + material language + simplification rule + lighting rule + output intent
```

| Slot | What goes here | Examples |
|---|---|---|
| **Subject** | The thing, concretely | `modern logistics warehouse`, `cozy bedroom cutaway`, `cyberpunk control room` |
| **Projection** | Name the angle explicitly | `30 degree isometric perspective view`, `2:1 isometric`, `consistent 30-degree axes`, `no perspective distortion` |
| **Material language** | Surface + finish | `clean vector art style`, `flat colors with soft ambient occlusion`, `low poly stylized`, `muted industrial palette` |
| **Simplification rule** | Forbid clutter/realism | `simple geometric forms`, `clean sharp edges throughout`, `high readability` |
| **Lighting rule** | One direction, soft | `soft long shadows consistent lighting`, `warm soft lighting ambiance`, `gentle ambient occlusion` |
| **Output intent** | What it's for | `scalable SVG icon style`, `game asset quality`, `suitable for conversion into a hero illustration`, `product-marketing illustration` |

**Keyword structuring:** favour comma-separated keywords over narrative sentences. Use
round brackets `( )` to emphasise critical elements (and weights like `(soft shading:0.7)`
in SD). Name the intended artefact type — *icon* vs *scene* vs *subject* — Firefly's
vector workflow in particular is stronger when you say which.

**The universal negative-prompt block** (forbid the perspective-breakers):

```
vanishing points, perspective distortion, dramatic shadows, realistic photography,
harsh lighting, text, signatures, watermarks, fisheye, camera lens realism
```

**Drift recovery** — when a model keeps breaking perspective, in order of effectiveness:

1. **Stop wording, add structure.** Feed an **image prompt / style reference**
   (Midjourney `--sref`) or switch to **ControlNet depth/MLSD** (§3). Perspective is a
   structure problem; solve it structurally.
2. **Name the artefact type** — "icon" / "scene" / "tile" / "subject" — so the model
   picks the right internal prior.
3. **Explicitly forbid lens realism** — add `no perspective distortion`, `no vanishing
   points`, `orthographic`, `camera lens realism` (negative). Repetition in the negative
   block helps.
4. **Escalate to a custom-trained model** (§5) if drift persists across a set — one-off
   drift is a prompt issue; *set-wide* drift is a training issue.

Three worked prompt targets (SRC-B/SRC-C — the full bank is in
[`assets/prompt-library.md`](../assets/prompt-library.md)):

- **City block:** `isometric city block illustration, 30 degree angle perspective view,
  detailed buildings and streets, miniature urban environment, soft shadows consistent
  lighting, vibrant color palette, clean vector art style, no perspective distortion,
  game asset quality design`
- **Room cutaway:** `isometric room interior cutaway, cozy bedroom detailed furniture,
  30 degree isometric view angle, walls removed showing interior, warm soft lighting
  ambiance, miniature dollhouse aesthetic, clean detailed illustration, pastel color
  scheme, architectural visualization style`
- **Dashboard scene:** `minimal isometric finance dashboard scene, white background,
  geometric UI cards, shallow depth, consistent 30-degree axes, gentle ambient
  occlusion, product-marketing illustration`

**Midjourney parameter cheatsheet (as of July 2026):**

| Param | Meaning | Range / default |
|---|---|---|
| `--sref <code>` | Style reference — lock a consistent iso style across a set | a style code or image URL |
| `--sw <n>` | Style weight — how strongly `--sref` applies | **0–1000, default 100** (per Midjourney docs) |
| `--cref <url>` | Character reference — consistent *subject* across images | image URL (omni-reference in newer versions) |

> ⚠ Midjourney's `--sref`/`--cref` syntax **shifts between versions** — several 2026
> sources warn on this explicitly. Verify against Midjourney's live docs before building
> a `--sref`-dependent workflow.

Sources: SRC-B "Prompt Engineering and Aesthetic Structuring" + curated prompt
templates; SRC-A Ch. 6 (Midjourney `--sref`/`--sw`, per docs.midjourney.com); SRC-C
prompt examples.

---

## 7. Ethics, IP & commercial-use — the two legal layers most teams miss

AI-assisted delivery has **two** licence layers, and teams routinely check only the
first.

**Layer 1 — the model licence (what the generator lets you commercialise):**

- **Adobe Firefly** — the strongest governance story here: applies **Content
  Credentials** (C2PA provenance) to outputs, and requires users to **confirm they hold
  rights** for anything uploaded to train custom models. Best choice when brand safety
  and disclosure matter.
- **Midjourney** — paid plans grant commercial-use rights for most users, but **terms
  and company-size rules apply** — verify per client and org size.
- **FLUX.1 [dev]** — **outputs usable commercially, but the model + derivatives (LoRA
  weights) are non-commercial.** A dev-based LoRA is not commercially redistributable
  even though its images are usable. (§2.)
- **Stability / SDXL** — model-specific licensing + acceptable-use policy; self-hosting
  or open-weight access does **not** remove the need to verify what your org may
  commercialise.

**Layer 2 — the *asset-library* licence (the one teams miss):** an asset library's
licence can **forbid AI training even when it permits normal commercial use.** DrawKit,
for example, **explicitly forbids using its icons and illustrations to train, fine-tune,
or improve AI/ML models** — while allowing ordinary commercial use of the art itself. So:

> **"Commercial use permitted" ≠ "dataset use permitted."** Before you feed *any*
> sourced asset into a LoRA/DreamBooth training set, check its licence's **AI-training
> clause** specifically — not just its commercial-use clause.

This directly gates §5: your custom-model training set must be assets you are licensed
to *train on*, not merely licensed to *use*. See [`asset-sourcing.md`](asset-sourcing.md)
for the per-library procurement rule and the AI-training-clause audit.

**Delivery hygiene.** When AI was involved, attach provenance/notes for client delivery —
especially if your org uses Content Credentials or has internal disclosure rules.

Sources: SRC-C "Ethics, IP and commercial-use considerations" (Firefly Content
Credentials, DrawKit AI-training prohibition); SRC-B; FLUX.1 [dev] license,
https://huggingface.co/black-forest-labs/FLUX.1-dev; DrawKit license,
https://www.drawkit.com/license.

---

## 8. End-to-end AI pipeline (brand-safe)

The through-line — AI as **composition and ideation, not final master**:

1. **Decide the projection** (`projection-math.md`) and build a small **reference board**
   — one palette, one material direction, three-to-six exemplar shapes.
2. **Generate composition candidates** — Midjourney / Firefly / Flux / SDXL, using image
   prompts / style refs where available. Match model to output need (§1).
3. **Pick ONE composition.** Do not blend five half-good generations.
4. **Enforce structure if it drifts** — ControlNet depth/MLSD (§3) or the Blender
   dual-control route (§4); a custom-trained model for a whole set (§5).
5. **Get to vector if you need it** — Firefly Text-to-Vector first; else Image Trace /
   Vectorizer.AI / SVGcode. → hand off to [`ai-refinement.md`](ai-refinement.md).
6. **Rebuild key edges manually** in Illustrator / Affinity / Inkscape — this is where
   production quality actually appears. (`ai-refinement.md`.)
7. **Normalise the planes** — re-impose the three-tone top/left/right highlight-midtone-
   shadow system ([`style-guide.md`](style-guide.md)). Clean edge halos on tiles
   (detected mechanically by `scripts/tile-validate.py`; see `ai-refinement.md`).
8. **Optimise & attach provenance** — SVGO/SVGOMG + a raster optimiser
   ([`svg-vector-generation.md`](svg-vector-generation.md)), then attach Content
   Credentials / disclosure notes for delivery (§7).

Steps 1–4 are *this* file. Steps 5–8 hand off to `ai-refinement.md`,
`svg-vector-generation.md`, and `style-guide.md`.

Sources: SRC-C "AI-assisted isometric workflow" + "Step-by-step AI tutorial"; SRC-A
Ch. 6 recommendations.

---

## Related

- [`ai-refinement.md`](ai-refinement.md) — upscaling, vectorization, edge-halo cleanup (the *refine* half).
- [`assets/prompt-library.md`](../assets/prompt-library.md) — ready-to-paste prompt scaffolds by tool.
- [`blender-prerender.md`](blender-prerender.md) — the Blender rigs, Z-pass and normal-pass detail feeding §4.
- [`projection-math.md`](projection-math.md) — the projection decision that precedes every prompt.
- [`style-guide.md`](style-guide.md) — three-tone shading, one light direction, scale grammar the prompts enforce.
- [`asset-sourcing.md`](asset-sourcing.md) — per-library licences + the AI-training-clause audit gating §5/§7.
- Colour ramps / perceptual palettes: cross-link the **color-ops** skill (don't restate colour science here).
