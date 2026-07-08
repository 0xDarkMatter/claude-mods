---
name: svg-brand-tint-ops
description: "Recolour, vectorise, and theme any SVG to a brand palette with a zero-dependency studio that emits a copy-paste CSS filter. Triggers on: recolour svg, brand tint an svg, duotone svg, recolour a diagram, cloudcraft/draw.io/figma svg to brand, svg css filter, png to svg, vectorise a logo, image trace."
license: MIT
metadata:
  author: claude-mods
  related-skills: "color-ops, genart-ops, mapbox-ops"
---

# SVG Brand-Tint Studio

Recolour **any** SVG to a brand palette — theme-aware — and get a copy-paste CSS
filter you can bake into an app. Also **vectorises rasters** (PNG/JPG → SVG) so a
flat-image logo or a screenshot becomes an editable, recolourable SVG. One
zero-dependency HTML file served by a ~90-line Node server. Nothing uploads —
pixels are read in a local `<canvas>`.

Extracted from a real job: taming a CloudCraft AWS-diagram export into a house
brand for an app's hosting page. It generalises to any third-party SVG export
(draw.io, Figma, Mermaid, Excalidraw, icon sets) and any raster you need as
vector.

## When to reach for it

- A **diagram/icon/logo export** is the wrong colours and has hundreds of inline
  `fill`/`stroke` values you don't want to hand-edit.
- You want a **duotone / tri-tone** brand treatment and a light + dark variant
  from one palette swap.
- You have a **PNG/JPG** and need clean **vector paths** (threshold, posterised,
  or colour-quantised — an in-browser Image-Trace).
- You need the **exact CSS `filter:` line** (and a React snippet) to bake a
  theme-aware tint into a real page.

This is a **skill, not a rule**: it carries the operational knowledge (the
colour math, the trace pipeline, the bake pattern) plus the working tool. For
one-line "always do X" guidance there's no rule here — the value is the studio +
the reference.

## Run the studio

```bash
node skills/svg-brand-tint-ops/scripts/server.mjs        # → http://localhost:4322
# PORT=8080 node …/server.mjs      choose a port
# node …/server.mjs --root ./icons  serve your own folder of SVGs/PNGs
# node …/server.mjs --help          usage + exit codes
```

It serves the sibling `assets/` (the studio + a generic `sample.svg`). Open the
URL, then **drop an SVG or PNG** on the canvas (or use the Source panel's sample
buttons). The left rail is accordion sections; the right is a scalable,
pan/zoom viewport with a live readout of the exact `filter:` line and ramp hex.

**What the panels do** — *Source* (load SVG/PNG/JPG, drop, paste, samples) ·
*Image Trace* (raster → vector: B&W / Steps / Color, detail, smoothing,
despeckle) · *Tone Map* (the N-stop brand ramp + presets + "palette from image")
· *Photographic* (saturate/contrast/brightness/hue/sepia/blur/drop-shadow) ·
*Strokes & Fills* (outline-only, fill-only, stroke width/colour) · *Typography*
(curated Google Fonts on the SVG's `<text>`, weight, size scale, tracking) ·
*Geometry* (rotate/flip/scale, strip fixed size) · *Canvas* (checker/solid/
light/dark, padding, grid) · *Inspect* (hover to highlight any element with its
tag/id/class/colours) · *Export* (copy CSS / baked SVG / tokens / React snippet;
download SVG or PNG @1–4×). `Split` (top bar) is a before/after divider.

## How the recolour works (tri-tone)

Three stacked stages — the first two are one SVG `<filter>`, the third is CSS:

1. `feColorMatrix type="saturate" values="0"` → collapse the source to a grey ramp.
2. `feComponentTransfer` → remap that ramp per channel to the brand stops via
   `tableValues` (`lines → ink`, `mid → accent`, `faces → canvas`).
3. `filter: url(#tonemap) saturate(1.55) …` → CSS tune on top.

**Two stops = duotone (often washed); a third accent midstop = tri-tone that
reads as designed.** Custom stop positions are handled by resampling the ramp to
a fixed table. Full derivation, N-stop math, and the `sRGB` vs `linearRGB` note:
[references/tri-tone-and-trace.md](references/tri-tone-and-trace.md).

## How the vectoriser works (PNG → SVG)

A from-scratch, accuracy-tuned engine ([assets/trace-core.mjs](assets/trace-core.mjs),
shared by the tool and the headless CLI): **2× supersample** → alpha-aware
segment into layers (threshold / posterise / **median-cut → k-means-refined →
merged** colour) → **interpolated sub-pixel iso-contours** (`fill-rule="evenodd"`
cuts holes) → closed-ring **Douglas–Peucker** → **corner-split + Schneider
least-squares Bézier fit** (fairs out staircase noise into clean curves; straight
runs and letter corners stay razor-sharp) → despeckle. Benchmarked on 24 real
logos (RMSE ≈27→11.5, edge-F1 0.66→0.86) it reproduces bold/geometric/coloured
marks near-perfectly (thin small text stays readable). It's one
continuous move: **PNG → trace → SVG → brand-tint**. Algorithm + tuning knobs:
[references/tri-tone-and-trace.md](references/tri-tone-and-trace.md) §2.

Trace from the command line (needs `sharp` to decode; the browser tool needs
nothing):

```bash
node skills/svg-brand-tint-ops/scripts/trace.mjs logo.png logo.svg --colors 6
node skills/svg-brand-tint-ops/scripts/trace.mjs --help    # flags + exit codes
```

## Baking the result into an app

Render the SVG **inline** (an `<img>` sandboxes fonts + `var()` tokens + document
filters). Because filter primitives can't read CSS variables, read your theme
tokens with `getComputedStyle(el).getPropertyValue('--ink')` and write the
`feFunc*` `tableValues` in JS — rebuild on theme change so light/dark re-tints
for free. Strip the root `width/height` (keep `viewBox`) so it scales. Apply
`filter: url(#id) saturate(…)`. The studio's **Export → React snippet** emits
this pre-filled; the full pattern + gotchas ledger is in
[references/tri-tone-and-trace.md](references/tri-tone-and-trace.md) §3–4.

## Resources

| Path | What |
|---|---|
| [scripts/server.mjs](scripts/server.mjs) | Zero-dep Node static server. `node scripts/server.mjs --help` for flags (`--root`, `--port`, exit codes). Serves `assets/`. |
| [scripts/trace.mjs](scripts/trace.mjs) | Headless PNG/JPG → SVG tracer over the shared engine. `--help` for options + exit codes. Needs `sharp` to decode (browser tool doesn't). |
| [assets/trace-core.mjs](assets/trace-core.mjs) | The canonical, dependency-free trace engine (`traceImage`). Same code the tool runs inline; imported by the CLI. `DEFAULTS` at the top are the tuning knobs. |
| [assets/index.html](assets/index.html) | The studio — the whole tool in one self-contained file (kept classic-script so the `file://` preview works). Editable `PRESETS` and `FONTS` maps near the top of the `<script>`; brand palettes are examples only. |
| [assets/sample.svg](assets/sample.svg) | Generic (brand-agnostic) diagram that auto-loads for a first-run demo. |
| [references/tri-tone-and-trace.md](references/tri-tone-and-trace.md) | The colour math, the trace algorithm, the theme-aware bake pattern, and a gotchas ledger. |

**Tenant-agnostic:** every shipped palette (petrol, mono, blueprint, …) is an
example. Swap the `PRESETS` map for your own tokens — nothing here is bound to a
brand.
