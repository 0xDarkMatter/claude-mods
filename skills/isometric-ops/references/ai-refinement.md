# AI Refinement: Upscaling, Vectorization, and Halo Cleanup

Once an isometric tile or scene has been generated (see
[`ai-generation.md`](ai-generation.md) for the generate → control step), it is
rarely production-ready as-is. AI rasters need **upscaling** without breaking
projection geometry, **vectorization** when the deliverable must be editable
SVG, **halo cleanup** when alpha edges are dirty (the single most common
AI-tile defect), and a final **normalization** pass that re-imposes this
skill's three-tone plane discipline. This file is the refinement stage of the
pipeline; it assumes you already have a raster or rough-vector candidate in
hand and covers everything between "generated" and "shippable."

Related: [`ai-generation.md`](ai-generation.md) (generation + ControlNet),
[`svg-vector-generation.md`](svg-vector-generation.md) (hand-rolled and
library-based SVG authoring — the non-AI vectorization path),
[`style-guide.md`](style-guide.md) (the three-tone plane system this file's
normalization step re-imposes), `scripts/tile-validate.py` (mechanical
detection of the defects described below).

---

## 1. Upscaling: the two-camp decision

Every upscaler on the market optimizes for one of two incompatible goals.
Picking the wrong camp for isometric work is the most common way a clean
generation gets ruined at the refinement stage.

| Camp | Behavior | Tools | Use for |
|---|---|---|---|
| **Creative / "hallucinate"** | Adds plausible new detail; can invent texture, geometry, and micro-perspective that was not in the source | **Magnific** (Freepik; Creativity + Resemblance sliders, up to 10K output, Precision V2 models), **SUPIR** (open-source, SDXL-prior, text-promptable, runs in ComfyUI via `kijai/ComfyUI-SUPIR`, needs 12GB+ VRAM), Krea Enhance, Clarity | AI-generated iso art that needs sharper edges and more surface detail than the base render had |
| **Faithful / "preserve"** | Enlarges pixels without inventing content; will also enlarge existing noise/blur/error | **Topaz Gigapixel** (local, Bloom diffusion model, face recovery, batch), **Real-ESRGAN** (free, fast, excellent for flat-color/line-art), **Upscayl** (free local GUI wrapper around Real-ESRGAN-class models) | Pixel-art tiles, flat-color vector-style renders, or any asset where the pixels ARE the deliverable and must not drift |

**As of July 2026**, Magnific is packaged under Freepik's account/credit system;
SUPIR remains the open self-hosted route for teams that need the creative camp
without a subscription. Verify current tiers on the vendor sites before
committing a pipeline — pricing and packaging on AI upscalers changes
quarterly.

### The isometric rule

For AI-generated isometric art, **default to the creative camp, but bias the
sliders toward resemblance-high / creativity-low.** The goal is sharper
edges and cleaner surface detail, not new content. A creative upscaler run at
high creativity will happily "fix" a flat isometric plane into something with
implied depth, ambient occlusion gradients that fight the three-tone system,
or — worst case — subtly curved edges that break the projection's dead-straight
lines. Concretely:

- Magnific: bias the Resemblance slider high and Creativity low (neither
  source document gives concrete percentages — treat this as directional
  guidance, not a calibrated setting; see Flags). Pushed too far toward
  creativity, Magnific starts re-drawing panel lines and adding perspective
  cues that were never in the source.
- SUPIR: keep the text prompt minimal/descriptive ("clean isometric game
  tile, flat lighting") rather than evocative — evocative prompts invite the
  model to invent atmosphere, which is exactly the failure mode to avoid.
- If the source is pixel art or a flat vector-style render where every pixel
  is intentional, skip the creative camp entirely and use Real-ESRGAN/Upscayl
  (faithful camp) at an integer scale factor (2×, 4×) so pixel-art grids stay
  aligned.

### The >4× ceiling

**Quality drops across every upscaler above roughly 4× linear scale**,
creative or faithful. Above that ratio, artifacts compound: creative
upscalers hallucinate visibly, faithful ones amplify compression noise and
produce soft/waxy results. If you need more than 4× resolution:

**Regenerate at a higher base resolution instead of chaining upscales.**
Two successive 2× passes are not a substitute for generating at 2× the
target resolution in the first place — each pass compounds its camp's
failure mode. Solve resolution upstream (at generation time), not by
stacking refinement passes; see the Sources section below for this
skill's own SRC-A citation of the >4× ceiling.

---

## 2. Vectorization ladder

When the deliverable must be editable vector (icon sets, brand-safe
illustration, anything a designer will need to recolor or resize by hand),
raster AI output has to cross into SVG. Quality and editability fall off in a
strict order — work down the ladder only as far as you need to:

| Rung | Tool | Output quality | When to use |
|---|---|---|---|
| 1 | **Recraft** | Cleanest — native vector generation, or upload-to-vectorize with purpose-trained tracing (not a generic autotrace) | First choice whenever available; produces the fewest, cleanest path nodes of anything on this ladder |
| 2 | **Vectorizer.AI** | High — deep-learning raster→vector, palette control, symmetry detection; outputs SVG/EPS/DXF/PDF; REST API + CLI + SDKs (~$9.99/mo as of July 2026) | API/CLI pipelines that need programmatic, unattended vectorization |
| 3 | **SVGcode** (free, open-source PWA, Potrace/WASM, fully offline) or plain **potrace** (CLI) | Moderate — classic autotrace algorithm, no ML | Free/local/offline requirement; simple flat-color source art; budget-constrained teams |
| 4 | **Adobe Illustrator Image Trace** (+ Object → Expand) | Lowest starting quality, but fully editable once expanded | Hand-drawn or AI-sketch sources where you're going to manually rebuild edges anyway |

Adobe Firefly's native "Text to Vector" mode can skip this ladder entirely
when brand-safe, Content-Credentialed vector output is the goal (see
`ai-generation.md` for the licensing rationale) — check it first if Firefly
is already in your stack.

### Path-soup avoidance

Every rung below Recraft has the same failure mode: **complex shading or
noisy raster input produces "path soup"** — hundreds of tiny, overlapping
fill regions where a human artist would have drawn three or four clean
shapes. Path soup is expensive twice: it bloats file size, and every
downstream edit (recoloring a plane, adjusting an outline) becomes a
multi-select nightmare across dozens of fragments.

Mitigations, in order of effectiveness:

1. **Simplify the raster before tracing.** Flatten gradients to hard color
   bands (2–4 tones per plane, matching the three-tone system) before
   vectorizing — the autotracer will produce roughly one path per color
   region, so fewer input tones means fewer output paths.
2. **Use a vectorizer's own simplification controls** (Vectorizer.AI's
   detail slider, Illustrator's Image Trace "Colors" and "Paths" sliders,
   SVGcode's threshold/turd-size options) rather than accepting defaults.
3. **Rebuild key edges manually** in Illustrator, Affinity, or Inkscape
   after autotracing. This is the step where production quality actually
   appears — treat the autotrace output as a floor plan, not a finished
   asset. Do not ship raw autotrace output for anything beyond a throwaway
   prototype.
4. **Run the export/optimisation pass** (simplify → export → SVGO/SVGOMG →
   raster derivatives) documented in `svg-vector-generation.md` — that file
   owns the full pipeline; this file only flags path soup as the reason the
   pass exists.

---

## 3. Edge-halo cleanup

The single most common mechanical defect in AI-generated tiles with
transparent backgrounds is a **semi-transparent fringe** — a ring of
partially-opaque pixels (alpha strictly between 0 and 255) around the
subject's silhouette, left over from the model's soft-edged background
removal or from JPEG-style compression artifacts baked into the alpha
channel. On a game tile, this fringe shows up as a visible light or dark
halo when the tile is composited over a different background color or an
adjacent tile.

### Detection and fix

Neither SRC-A nor SRC-C describes a specific alpha-compositing technique for
this defect — the mitigation below is standard raster-compositing practice
supplied from general prior knowledge, not sourced from either document (see
Flags). Treat the terminology and step order as a reasonable default, not a
sourced claim.

- **Alpha thresholding**: force every pixel's alpha to either fully
  transparent or fully opaque at a chosen cutoff (commonly 50%/128), instead
  of preserving a soft gradient. This is correct for hard-edged game tiles;
  it is wrong for intentionally soft effects (glows, shadows painted into
  the alpha channel) — decide per-asset-class, don't blanket-apply.
- **Defringe** (a.k.a. "matte cleanup" / "spill removal"): for edge pixels
  that must stay semi-transparent (anti-aliased silhouette edges), strip the
  residual background color that bled into their RGB before compositing —
  otherwise a white-background source produces a visible white halo even
  after correct alpha, because the RGB itself is contaminated. Most raster
  editors (Photoshop, Affinity, GIMP) expose this as a "Defringe" or "Matte"
  filter; the underlying operation un-premultiplies the color against the
  known background before discarding it.
- **Threshold-then-defringe order matters**: threshold first to establish a
  clean hard/soft edge boundary, then defringe only the pixels that remain
  in the soft band. Defringing before thresholding leaves you defringing
  pixels that are about to be discarded anyway, wasting the operation on
  irrelevant data.

### Mechanical detection: `tile-validate.py`

This defect is exactly what `scripts/tile-validate.py`'s **alpha-halo
check** exists to catch automatically: it scans a tile for the percentage of
semi-transparent pixels (`0 < alpha < 255`) and flags a violation when that
percentage exceeds threshold — the check a human reviewer would otherwise
have to eyeball tile-by-tile across a large AI-generated batch. The same
script's **edge-bleed check** catches the sibling defect (opaque pixels
touching the outermost rows/columns of the canvas, meaning the subject was
not given enough transparent margin and will visibly clip against
neighboring tiles). Run `tile-validate.py` as the QA gate immediately after
any AI-generation-and-refine pass and before the asset enters
`sheet-pack.py` — see `tile-spec.md` for how a written asset spec's margin
and format lines map onto these checks. Treat a violation as blocking: fix
the source art or re-run defringe/threshold, don't ship a tile with a known
halo because "it's probably fine at game resolution."

---

## 4. Post-vectorization normalization

Vectorizing a raster (or generating a rough vector directly) does not, by
itself, produce output that respects this skill's shading discipline. A
generic autotrace or a loosely-prompted AI generation will typically produce
inconsistent lighting logic between the top, left, and right planes — soft
gradients where there should be flat fills, or a light direction that
subtly shifts across the composition. **The last step before an
AI-refined asset is production-ready is always a normalization pass** that
re-imposes the three-tone plane system documented in full in
[`style-guide.md`](style-guide.md):

1. **Flatten each plane to its assigned tone.** Top plane gets the lightest
   fill, one side plane gets the mid tone, the other side plane gets the
   dark tone — per the fixed light direction chosen for the whole asset set,
   not re-derived per tile.
2. **Collapse any residual gradient banding** left by the vectorizer into
   the flat three-tone fills (or, if soft shading is an intentional style
   choice, make sure the gradient stops match the ramp defined in
   `assets/palettes/three-tone-presets.json` rather than whatever the
   autotrace happened to sample).
3. **Check cross-tile/cross-asset consistency.** A single AI-refined asset
   can look correct in isolation and still break the set if its light
   direction or tone mapping doesn't match its siblings — verify against the
   consistency checklist in `style-guide.md` before considering the asset
   done, not just against itself.
4. **Re-run `tile-validate.py`** after normalization — flattening fills can
   shift edge pixels and occasionally reintroduces halo or edge-bleed if the
   normalization pass touched the silhouette boundary.

This four-step pass is what turns "AI output that looks isometric" into
"an asset that matches the rest of the set" — treat it as mandatory, not
optional polish, for anything beyond a one-off concept image.

---

## Sources

- SRC-A ch.6 ("AI-Assisted Generation & Refinement") — upscaling two-camp
  framing (Magnific/SUPIR vs Topaz/Real-ESRGAN/Upscayl), the isometric
  resemblance-high/creativity-low rule, the >4× regenerate-instead-of-chain
  threshold, the vectorization tool list (Recraft, Vectorizer.AI, SVGcode,
  Illustrator Image Trace), and the licensing caveat that AI tool pricing
  and availability move fast.
- SRC-C (converted PDF, "Export and optimisation workflow" and "Step-by-step
  AI tutorial" sections) — the vectorize → clean paths in
  Illustrator/Affinity/Inkscape → normalize highlight-midtone-shadow → SVGO/
  SVGOMG optimise pipeline order, and the "outputs still need cleanup;
  complex shading can become path soup — use for conversion, not as the
  final illustrator" characterization of AI-driven vectorizers. Neither
  SRC-A nor SRC-C names the specific alpha-compositing technique described
  in "Edge-halo cleanup" above (thresholding, defringe/matte-cleanup,
  un-premultiplying) — that material is general raster-compositing prior
  knowledge, not drawn from either source document; see Flags.
- Magnific (Freepik): https://magnific.ai
- SUPIR (ComfyUI integration): https://github.com/kijai/ComfyUI-SUPIR
- Topaz Gigapixel: https://www.topazlabs.com/gigapixel-ai
- Real-ESRGAN: https://github.com/xinntao/Real-ESRGAN
- Upscayl: https://github.com/upscayl/upscayl
- Recraft: https://www.recraft.ai
- Vectorizer.AI: https://vectorizer.ai
- SVGcode: https://github.com/tomayac/SVGcode
- potrace: http://potrace.sourceforge.net

## Flags

- SRC-A's mention of "Krea Enhance" and "Clarity" as additional creative-camp
  upscalers is a brief aside with no further detail in either source
  document; included here for completeness but not independently verified
  against vendor docs — treat as pointers, not endorsements, and verify
  current capability before depending on either.
- Neither source document gives an exact numeric threshold for the
  alpha-halo percentage that `tile-validate.py` should flag as a violation;
  that threshold is owned by the script itself (`--help` documents its
  default and `--` flag to override it), not restated here.
- The Magnific slider guidance ("bias Resemblance high / Creativity low")
  is qualitative in both SRC-A and SRC-C — neither source gives concrete
  percentages. An earlier draft of this file stated "Resemblance 70–90%,
  Creativity 10–30%" as if sourced; those numbers were invented precision
  and have been removed. Treat any specific slider percentage as a starting
  point to tune against the vendor's current UI, not a sourced fact.
- The "Edge-halo cleanup" section (alpha thresholding, defringe/matte
  cleanup, threshold-then-defringe ordering, the un-premultiply mechanism)
  has no support in SRC-A or SRC-C — a grep of both for halo/fringe/matte/
  premultiply/alpha turns up nothing outside this file. It is standard
  raster-compositing prior knowledge presented as workflow guidance, not
  a claim attributed to either named source. The mechanical detection it
  feeds (`tile-validate.py`'s alpha-halo and edge-bleed checks) is real and
  sourced to this skill's own script, but the cleanup technique itself is
  uncited.
