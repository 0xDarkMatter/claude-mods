# Isometric Prompt Library

Ready-to-paste prompt scaffolds for generating isometric illustration with text-to-image
models. Curated from field-tested scaffolds (Grid Dynamics' production tutorial), vendor
prompt guidance (Midjourney, Adobe Firefly), and cross-checked prompt sets for common
subject categories. Pair this file with `references/ai-generation.md` (the decision
ladder for *which* tool/model to reach for) and `references/style-guide.md` (the
three-tone shading doctrine these prompts encode in words).

**The projection decision still comes first.** Every scaffold below assumes you already
decided: true isometric (30°, vector/hero illustration) or 2:1 dimetric (26.565°, "game
isometric" tiles). Say so explicitly in the prompt — models default to arbitrary
axonometric angles otherwise, and this is the #1 cause of AI perspective drift. See
`references/projection-math.md` for the projection decision table.

Volatile facts (parameter syntax, weight ranges, pricing) are date-stamped **as of July
2026** — these move fast. Verify against the vendor's live docs before building a
pipeline around a specific flag; `scripts/check-iso-facts.py --live` tracks the packages
named elsewhere in this skill but does not track AI vendor parameters, which are out of
scope for a stdlib grep-check.

---

## 1. The universal prompt formula

Every scaffold in this file follows the same anatomy — this is the doctrine, the
scaffolds below are just filled-in instances of it:

```
[SUBJECT] + [PROJECTION] + [MATERIAL LANGUAGE] + [SIMPLIFICATION RULE] + [LIGHTING RULE] + [OUTPUT INTENT]
```

| Slot | Purpose | Example fragment |
|---|---|---|
| Subject | What it is, concretely | "modern logistics warehouse" |
| Projection | Locks the axonometric angle in words | "2:1 dimetric projection", "30 degree isometric perspective view" |
| Material language | Concrete surface/material nouns, not mood words | "corrugated metal siding, concrete loading dock" |
| Simplification rule | Forces flat/clean geometry over photoreal clutter | "simple geometric forms, clean vector art style" |
| Lighting rule | One fixed light direction, soft shadows, no drama | "soft long shadows, consistent lighting, no dramatic shadows" |
| Output intent | Tells the model what medium/use it's for | "scalable SVG icon style", "game asset quality design" |

Comma-separated keyword style beats narrative prose for structural control — models
respond more reliably to a flat list of concrete nouns/adjectives than a sentence. Use
round brackets `(term)` (Midjourney/SD family) to up-weight a single critical keyword
when the model keeps dropping it, e.g. `(isometric:1.3)` or `(orthographic:1.2)`.

---

## 2. Universal negative-prompt block

Append this to every generation regardless of subject or tool (drop the syntax that
doesn't apply — Firefly and Recraft don't take a separate negative-prompt field the way
Stable-Diffusion-family UIs do; fold the concepts into "avoid" language in the main
prompt instead):

```
vanishing points, perspective distortion, dramatic shadows, realistic photography,
lens flare, depth of field, motion blur, fisheye, wide-angle lens, camera lens realism,
mixed scale objects, uneven wall thickness, harsh spot lighting, text, signatures,
watermarks, logos, borders, frame, cropped, out of frame, low quality, blurry,
duplicate, deformed, disfigured
```

Rationale for each cluster (so you can trim intelligently rather than pasting blindly):

- **`vanishing points, perspective distortion, ... lens flare, depth of field, ... fisheye,
  wide-angle lens, camera lens realism`** — the single biggest failure mode. Diffusion
  models are trained overwhelmingly on photographs, which have perspective and lens
  effects; isometric/axonometric projection has neither. Naming these explicitly is more
  effective than hoping "isometric" alone overrides the photographic prior.
- **`mixed scale objects, uneven wall thickness`** — enforces the style-guide.md scale
  grammar and cutaway conventions (see `references/style-guide.md`) directly in the
  negative space.
- **`harsh spot lighting, dramatic shadows`** — enforces the three-tone doctrine's single
  soft fixed light direction; models left alone default to moody single-source drama
  lighting borrowed from photography/cinema training data.
- **`text, signatures, watermarks, logos, borders, frame, cropped, out of frame`** —
  standard hygiene negatives; isometric icon/scene generations are especially prone to
  picking up stock-art watermark ghosts because so much iso stock art in training sets
  carries them.
- **`low quality, blurry, duplicate, deformed, disfigured`** — generic SD-family quality
  negatives, harmless to include, cheap insurance.

---

## 3. Subject scaffolds

Each scaffold is a complete, paste-ready prompt. Swap the bracketed subject noun and
adjust the material language for your specific asset; keep the projection, lighting,
and simplification clauses intact — they are what stops the drift.

### 3.1 City block / urban environment

```
Isometric city block illustration, 2:1 dimetric projection, 30 degree angle
perspective view, detailed buildings and streets, mixed low- and mid-rise structures,
clean architectural massing, miniature urban environment, muted urban color palette
with one accent hue, soft long shadows, consistent single light direction,
flat colors with soft ambient occlusion, clean vector art style, no perspective
distortion, game asset quality design, scalable SVG icon style
```

**Do:** keep every building's vertical edges parallel to the three iso axes; keep
window/door proportions consistent across buildings (same-scale grammar, one human ≈ N
tiles tall — see `references/style-guide.md` §Scale grammar). **Avoid:** vanishing
points on street recession, mixed building scales, photographic window reflections.

### 3.2 Room / interior cutaway

```
Isometric room interior cutaway, 30 degree isometric view angle, [cozy bedroom /
minimalist studio apartment / cluttered workshop] with detailed furniture, walls
removed cleanly showing interior, uniform wall thickness at the cut edge, warm soft
ambient lighting, single fixed light direction, three-tone plane shading (lightest
top, mid-tone one side wall, darkest other side wall), miniature dollhouse aesthetic,
clean detailed illustration, limited pastel color palette, architectural
visualization style, no perspective distortion
```

**Do:** cut walls with one uniform thickness all around (the cutaway-conventions rule
in `references/style-guide.md`); keep furniture on the same scale grammar as the room.
**Avoid:** uneven wall thickness at the cut plane, harsh spot lighting, furniture at
inconsistent scale relative to the room shell.

### 3.3 Floating island / nature environment

```
Isometric floating island scene, fantasy nature environment, waterfall trees and
mossy rocks, 30 degree isometric perspective view, low-poly stylized aesthetic,
clean sharp geometric edges throughout, vibrant greens and blues, high-contrast flat
color blocking, one fixed soft light direction with long cast shadows, game
environment concept art, magical whimsical atmosphere, no perspective distortion,
no airbrushed gradients
```

**Do:** use clean, sharp geometric edges (avoid organic photographic foliage
rendering); apply high-contrast flat color, not gradient-heavy painterly shading.
**Avoid:** inconsistent ground-plane angles between the island's top surface and its
underside/root mass, organic airbrushed gradients that break the flat-shading language.

### 3.4 Warehouse / logistics

```
Clean isometric vector illustration of a modern logistics warehouse, 2:1 dimetric
projection, corrugated metal siding, loading dock with roller doors, stacked
pallet racking visible through a cutaway wall, simple geometric forms, clear
top/left/right plane separation, soft long shadows, consistent single light
direction, muted industrial palette (steel grey, safety yellow accent), no
perspective distortion, no text, scalable SVG icon style
```

**Do:** keep the three visible planes (top/left/right) each a single flat tone per the
three-tone doctrine — this is the scaffold that maps most directly onto the SSR/CSS
plane-composition recipes in `references/projection-math.md`. **Avoid:** photographic
metal specular highlights, mixed-scale pallets/racking.

### 3.5 Control room (cyberpunk / sci-fi)

```
Isometric cyberpunk control room, orthographic feel, 30 degree isometric
perspective, modular wall panels, bank of monitor screens, teal-violet accent
lighting against a dark neutral base palette, precise clean geometry, layered
depth via overlapping panel modules, high readability, one dominant fixed light
source, no dramatic shadows, suitable for conversion into a hero illustration,
no perspective distortion, no lens flare
```

**Do:** let the accent color (teal-violet) carry all the "mood," while geometry and
shading stay flat and legible — accent color is not a substitute for the three-tone
plane structure. **Avoid:** volumetric fog/light-shaft photographic effects, screen
glare/bloom that implies a camera lens.

### 3.6 Dashboard / product-marketing scene

```
Minimal isometric finance dashboard scene, 30 degree isometric projection, white
background, geometric UI cards floating above a flat isometric desk/base plane,
shallow depth, consistent 30-degree axes throughout every card, gentle ambient
occlusion, soft single-direction shadow beneath each card, flat clean color
palette with one brand accent, product-marketing illustration style, no
perspective distortion, no text, no watermark
```

**Do:** keep every floating card at the *same* projection angle as the base plane —
this is the most common failure in dashboard/SaaS-marketing iso art (cards rendered at
a different axonometric angle than the ground they float above). **Avoid:** drop
shadows that imply a different light source per card, cards at inconsistent scale.

### 3.7 Grid Dynamics production scaffold (game sprite tileset)

The field-tested scaffold from Grid Dynamics' "Game Asset Creation With Generative AI
Tools" tutorial — a systematic Midjourney + Scenario workflow for consistent iso
building sprites. Good starting template when you need dozens of matching tileset
pieces rather than one hero illustration:

```
isometric [subject], cyberpunk style, realistic, video game, style of behance, made
in blender 3D, white background
```

This is the scaffold as documented — `cyberpunk style` is the actual worked example in
the source tutorial, not a placeholder. Fill `[subject]` with a concrete noun (`house`,
`watchtower`, `market stall`) for your own tileset. Swapping `cyberpunk style` for a
different art-direction phrase (`medieval fantasy style`, `sci-fi industrial style`) is
a reasonable generalization of the pattern, but it is **not** itself sourced — treat it
as an inferred extension and verify the result still reads clean before committing a
whole tileset to it. The `made in blender 3D` clause is doing real work here — it steers
the model toward clean-render aesthetics (flat AO, no photographic grain) rather than
painterly illustration, which matters when every tile in a set must read as the same
"material" as its neighbors. `white background` isolates the subject for downstream
background removal / sprite packing (`scripts/sheet-pack.py`).

**Do:** generate the whole tileset in one session/seed lineage where the tool
supports it (Midjourney's seed-locking options — unverified against this skill's
sources, check `docs.midjourney.com` for current syntax — or a single Scenario custom
model) so lighting direction and material rendering stay consistent across tiles.
**Avoid:** regenerating
each tile from a fresh unrelated seed — this is the single most common cause of a
tileset that "almost matches."

### 3.8 Isometric icon (single subject, UI/brand icon set)

```
isometric icon of a [subject], 30 degree isometric projection, top-down 45 degree
axonometric, single object centered, simple geometric forms, minimal detail, flat
color fills, one soft ambient shadow beneath the object, transparent background,
clean vector icon style, no perspective distortion, no text, no background scene
```

Recraft explicitly supports "isometric illustration" and "top-down 45° axonometric"
phrasing as first-class prompt vocabulary for its vector-native icon/vector-art models
— use both phrasings together (as above) when targeting Recraft, since its models were
trained to recognize them as a matched pair.

---

## 4. Model-specific parameter cheatsheets

Organized by target tool. All parameter values below are **as of July 2026** — Midjourney
in particular has shifted `--sref`/`--cref` syntax between major versions before; verify
against `docs.midjourney.com` before locking a production workflow to a specific flag.

### 4.1 Midjourney

Parameters marked **[sourced]** are confirmed against this skill's named source
documents (SRC-A/B/C). Parameters marked **[unverified]** are real Midjourney flags
from general model knowledge, not confirmed against those sources — spot-check them at
`docs.midjourney.com` before depending on the exact syntax/defaults shown.

| Parameter | Purpose | Value / default |
|---|---|---|
| `--sref <code or image URL>` **[sourced]** | Style reference — locks a consistent visual style (palette, rendering, "isometric-ness") across a whole generation set | one or more codes/URLs; combine multiple for a blended style |
| `--sw <0–1000>` **[sourced]** | Style weight — how strongly `--sref` pulls the result toward the reference style | default **100**; push toward 1000 for strict style-lock, lower toward 0 to let the text prompt dominate |
| `--cref <image URL>` **[sourced]** | Character/subject reference (omni-reference) — locks a consistent *subject*, independent of style | pairs with `--cw` (character weight, **[unverified]**) |
| `--iw <0–2>` **[unverified]** | Image weight — how strongly an attached image prompt influences the result vs. the text prompt | default varies by model version; raise when the image prompt should dominate composition |
| `--style raw` **[unverified]** | Reduces Midjourney's default aesthetic embellishment, useful for cleaner iso geometry | boolean flag |

**Recommended pattern for a consistent iso set:** generate one strong hero result, run
it through Style Explorer or extract its `--sref` code, then reuse that `--sref` at
`--sw 150–300` across every subsequent prompt in the set. Named community iso style
codes exist (Midlibrary's "Isometric Mellow Scribe", sref-midjourney.com's isometric
library) as starting points — treat these as inspiration, not guaranteed-stable IDs;
community `--sref` catalogs churn as Midjourney model versions change.

**Prompt formula for Midjourney specifically:** `[Subject] + [Environment] + [Lighting]
+ [Medium] + [--params]` — put the isometric/projection constraint inside `[Medium]`
(e.g. "clean vector art, isometric game asset") since Midjourney treats medium-language
as a strong style anchor.

### 4.2 Adobe Firefly

| Concept | Notes |
|---|---|
| Asset-type framing | Firefly's vector workflow responds better when you name the artefact type explicitly — `icon`, `scene`, or `subject` — rather than leaving it implicit. Add this as an explicit word in the prompt. |
| Text to Vector | Generates editable, grouped vector paths directly; try this first when you need vector output immediately — it can skip the raster→trace step entirely. |
| Content Credentials | Firefly applies Content Credentials (provenance metadata) to generated outputs — the strongest governance/attribution story of the tools in this table, relevant when client delivery requires provenance disclosure. |
| Commercial governance | Firefly requires users to confirm rights/permissions for any image uploaded to train a custom model; review plan terms per client and company size regardless. |

No `--sref`-equivalent flag syntax is documented for Firefly's public prompt field as
of July 2026 — style consistency is driven by reference-image upload and the
brand/style controls in the Firefly UI, not inline text parameters.

### 4.3 Recraft

- No negative-prompt field or reference-code parameter syntax; style consistency comes
  from brand-style image uploads (consistency across an icon set) and from its
  dedicated "Icon" vs "Vector Art" model selection.
- Prompt vocabulary Recraft explicitly recognizes: `"isometric illustration"`,
  `"top-down 45 degree axonometric"` — use this exact phrasing (§3.8 above) rather than
  paraphrasing.
- Free tier makes generations public; paid tiers keep generations private and grant
  full commercial ownership — relevant before running client work through the free tier.

### 4.4 Flux / SDXL (ComfyUI / Automatic1111 family)

Full negative-prompt syntax applies (§2 above, verbatim). Typical generation
parameters for the Blender-blockout → ControlNet iso workflow (see
`references/blender-prerender.md` and `references/ai-generation.md` for the full
pipeline): Euler sampler, ~15 sampling steps, 768×768 resolution, CFG scale 7 (favors
structural fidelity to the ControlNet conditioning over creative variance — raise CFG
if the model ignores the depth/normal maps, lower if output looks over-baked/artifacted).

Weight emphasis syntax `(term:1.3)` works in this family exactly as in Midjourney —
use it to up-weight `isometric`, `orthographic`, or `flat lighting` when a LoRA or base
checkpoint keeps drifting toward photographic perspective.

---

## 5. Drift-recovery tactics

When output keeps introducing vanishing points, camera-lens effects, or otherwise
breaking the flat axonometric read, apply these in order — cheapest fix first:

1. **Add an image prompt or style reference.** Feed a shape/mood reference (Midjourney
   image prompt or `--sref`, Firefly reference image, SDXL IP-Adapter) alongside the
   text prompt. Text alone under-constrains the geometry; an image anchors it.
2. **Name the intended artefact type explicitly.** "icon", "scene", "sprite", "game
   asset" — vague subject nouns let the model fall back on its dominant (photographic)
   training prior.
3. **Explicitly forbid camera-lens realism.** Add `no camera lens, no depth of field,
   no lens flare, orthographic, not a photograph` to the negative space — this is
   stronger than relying on "isometric" alone to suppress photographic priors.
4. **Escalate to structural control.** If prompt-only recovery fails after 2–3 retries,
   stop prompting and switch to ControlNet depth/MLSD conditioning from a Blender
   blockout (see `references/ai-generation.md` §ControlNet workflow) — this is a hard
   geometric constraint the model cannot drift away from, unlike a text/image prompt
   which is only ever a soft bias.
5. **For a whole inconsistent set**, don't keep re-rolling individual tiles — train a
   small custom model (Scenario/Layer.ai DreamBooth-style, 10–20 on-style references,
   or a house LoRA on 30–100 curated examples with one projection/material/shadow
   logic) per `references/ai-generation.md`'s LoRA dataset discipline. Re-rolling
   individual outputs against a drifting base model has a hard ceiling; a trained model
   does not.

---

## 6. Sources

- Grid Dynamics, "Game Asset Creation With Generative AI Tools" — production Midjourney
  + Scenario tileset scaffold (§3.7).
- Midjourney official parameter documentation, `docs.midjourney.com` — `--sref`, `--sw`
  (0–1000, default 100), `--cref` (as of July 2026; verify before production use, syntax
  has shifted between model versions).
- Adobe Firefly product documentation and Content Credentials overview,
  `helpx.adobe.com/firefly` — Text to Vector, asset-type framing, governance model.
- Recraft product documentation — `"isometric illustration"` / `"top-down 45 degree
  axonometric"` prompt vocabulary, Icon/Vector Art model distinction.
- SRC-B (Engineering and Aesthetic Standards for Isometric Design) — prompt template
  table (city/room/nature scaffolds §3.1–3.3), negative-constraint doctrine, Blender→
  ControlNet step-4 generation parameters (§4.4).
- SRC-C (isometric tool/market landscape PDF) — warehouse/control-room/dashboard prompt
  examples (§3.4–3.6), drift-recovery tactics (§5), AI ethics/licensing caveats
  (cross-referenced in `references/asset-sourcing.md` and `references/ai-generation.md`).
- SRC-A (compass artifact resource library) — Civitai LoRA catalog, ControlNet
  preprocessor tooling, upscaler two-camp decision (all detailed in
  `references/ai-generation.md` and `references/ai-refinement.md`, not restated here).

Cross-references: `references/ai-generation.md` (model/tool decision ladder, LoRA
catalog, ControlNet workflow in full), `references/ai-refinement.md` (upscaling and
vectorization after generation), `references/style-guide.md` (the three-tone/scale/
composition doctrine these prompts encode), `references/asset-sourcing.md` (licensing
and AI-training-clause discipline for any reference imagery you feed into a prompt).
