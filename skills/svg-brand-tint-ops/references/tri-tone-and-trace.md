# The colour math, the trace engine, and the theme-aware bake

Everything the tuner does, explained so you can reproduce any piece of it in a
production app without the UI. Three parts: the **tone-map** (recolour), the
**image-trace** (raster → vector), and the **token-driven theme-aware pattern**
(how to bake a live result into a real page). Ends with a gotchas ledger.

---

## 1. The tone map — desaturate → per-channel ramp → CSS tune

Recolouring an arbitrary SVG to a brand palette is three stacked stages. The
first two are one SVG `<filter>`; the third is a CSS `filter` on top.

### Stage 1 — kill the source hue

```xml
<feColorMatrix type="saturate" values="0"/>
```

Collapses every colour to its luminance grey. Now the image is a single grey
ramp from black (0) to white (1) — a clean input the next stage can re-map.
Skip this stage (the tuner's *Desaturate* toggle) only when you want the ramp to
act on the source's raw R/G/B channels independently, which produces a channel-
shift effect rather than a true tint.

### Stage 2 — remap the grey ramp to N brand colours

`feComponentTransfer` runs an independent transfer function per channel. With
`type="table"`, each `<feFunc*>`'s `tableValues` are read as **equally-spaced
control points across the input [0,1]**, linearly interpolated between. So to
map *grey → brand ramp* you feed each channel the ramp colours' channel values:

```xml
<feComponentTransfer>
  <feFuncR type="table" tableValues="r0 r1 r2 … rN"/>   <!-- reds of each stop  -->
  <feFuncG type="table" tableValues="g0 g1 g2 … gN"/>   <!-- greens of each stop -->
  <feFuncB type="table" tableValues="b0 b1 b2 … bN"/>   <!-- blues of each stop  -->
</feComponentTransfer>
```

- **2 stops → duotone** (shadows → colour A, highlights → colour B).
- **3 stops → tri-tone** (`lines → ink`, `midtones → accent`, `faces → canvas`).
  This is the sweet spot: two-stop duotones interpolate the *whole* midrange as a
  flat blend of the two endpoints and look washed / muddy. A third mid stop
  (usually the brand **accent**) gives the midtones somewhere to land and the
  result reads as intentional. **If your duotone looks washed out, add an accent
  midstop** — that single change is the difference between "greyscale with a
  colour cast" and "designed".
- **4–5 stops** → quad/penta-tone for posterised, screen-print looks.

**Arbitrary stop positions.** `tableValues` positions are *fixed at equal
spacing*. To honour custom stop positions (a stop at 0.2 vs 0.5), don't try to
encode position into the table — **resample**. Walk the sorted `(colour,
position)` stops and emit a fixed number of equally-spaced samples (the tuner
uses 33) by piecewise-linear interpolation along position. Equal-spaced stops
resample to themselves, so it's a strict superset. This is `buildToneFilter()`
in `index.html`.

### Stage 3 — CSS tune on top

```css
filter: url(#tonemap) saturate(1.55) contrast(1.05) brightness(1);
```

`saturate()` is the headline dial — the ramp interpolation slightly desaturates
midtones, and lifting saturation back up (1.4–1.8) makes the tint sing. Add
`contrast`/`brightness`/`hue-rotate`/`sepia`/`blur`/`drop-shadow` as needed. The
order matters: `url(#tonemap)` **first** (it defines the colour), CSS functions
after (they adjust it).

### `color-interpolation-filters`

Set it explicitly on the filter. `sRGB` remaps in gamma space (what you see in
the pickers — predictable, slightly punchier midtones). `linearRGB` (the SVG
default!) remaps in linear light — physically "correct" blends but midtones read
darker and often surprise designers. The tuner defaults to `sRGB` for WYSIWYG.

---

## 2. The image-trace engine — raster → clean vector

The engine lives in **`assets/trace-core.mjs`** (`traceImage(imageData, opts)`), a
pure, dependency-free module shared by the browser tool (fed a `<canvas>`
ImageData) and the headless CLI (`scripts/trace.mjs`, fed decoded pixels) — one
implementation, no drift. Nothing is uploaded; pixels are read locally. Tuned on
a 24-logo accuracy bench (source PNG → trace → re-rasterise → per-pixel + edge
fidelity), it moved mean RMSE from **≈27 → ≈11.5** and edge-F1 **0.66 → 0.86** vs
the naïve first cut. The pipeline and *why each step earns its place*:

1. **Supersample** the source to ~2× (`super`) before reading pixels. The logos
   are ~320 px; tracing at 2× places every edge crossing with sub-pixel accuracy,
   then the resolution-independent SVG is crisp at any size. 2× was the measured
   sweet spot — 3× only adds bytes.
2. **Alpha-aware luminance + opacity** per pixel. Fully-transparent pixels are
   excluded from every layer, so a logo on a transparent/white background keeps
   its background transparent instead of tracing a giant rectangle.
3. **Segment into layers** by mode:
   - **B&W** — one field, `luma < threshold`.
   - **Steps (posterise)** — `levels` cumulative luminance masks, lightest-largest
     at the bottom to darkest on top.
   - **Color** — **median-cut** seeds → **k-means (Lloyd) refinement** snaps the
     seeds onto the true flat colours (dissolving muddy anti-alias intermediates)
     → **palette merge** collapses entries within `mergeDist` (≈48), which removes
     the near-duplicate anti-alias fringe shades that otherwise become overlapping
     tint layers on a near-monochrome logo. Each surviving colour is one binary
     membership field, painted biggest-area first.
4. **Interpolated iso-contours** (`isoContours`) — marching squares at iso 0.5 but
   with **linear interpolation of each edge crossing** between corner values, so
   the boundary lands at its true sub-pixel position rather than a pixel
   staircase. Consistent filled-on-right winding links segments into closed loops;
   `fill-rule="evenodd"` cuts holes. (Saddles 5/10 resolved "separate".)
5. **Simplify** each loop with closed-ring **Douglas–Peucker** (`detail` epsilon,
   scaled by the supersample factor).
6. **Corner-split + least-squares Bézier fit** (`fitPath`, Schneider's algorithm)
   — the key to sharp *and* smooth logos. Each vertex is classified corner-vs-curve
   by turn angle (`cornerDeg`); the ring is split at corners, and curve vertices
   are **Laplacian-faired** (`fair`). Then each smooth span is fitted with the
   **fewest cubic Béziers that stay within `fitErr` px** (recursive subdivision +
   Newton-Raphson reparameterisation) — which *averages out* the staircase noise
   into clean curves instead of interpolating through it. Straight runs and letter
   corners stay razor-sharp (lines, pinned); scripts and circles become genuinely
   smooth. This is what keeps **NGV a crisp rectangle** and **Grill'd a smooth
   script** from the same code. Feed it denser points (lower `detail`) for higher
   fidelity, raise `fitErr`/`smooth` for fewer, softer curves.
7. **Despeckle** on true occupied pixel area.

Output is a plain `<svg>` of `<path>`s that flows straight into the tone map:
**PNG → trace → SVG → brand-tint** is one continuous move.

**Honest scope.** A flat-art tracer, not a centreline/stroke tracer. It excels at
logos, icons, flat marks, and posterised art — bold/filled/geometric logos come
out near-perfect; very thin or small text (≈1 px strokes in a low-res source)
stays readable but shows some edge roughness, the fundamental limit of
vectorising an anti-aliased raster. Raise `colors`/`super`, lower `detail` for
more fidelity at the cost of path count. Tuning knobs and their effects are the
`DEFAULTS` block at the top of `trace-core.mjs`.

---

## 3. Baking a live result into an app (the theme-aware pattern)

The whole point of a *token-driven* tint: define the ramp from your theme tokens
and it re-themes for free on light/dark switch. The rules that make it work:

### Render the SVG **inline**, never as `<img>`

An inline `<svg>` participates in the document: page `@font-face`s resolve on its
`<text>`, `var(--token)` reads your CSS custom properties, and a CSS `filter:
url(#id)` referencing an in-document `<filter>` applies. An `<img src="…svg">`
**sandboxes** all of that — external font `@import`s are blocked, `var()` can't
see your tokens, and a document filter id won't resolve. If your baked tint or
font "just doesn't apply", this is almost always why.

### Filter primitives can't read CSS variables — build the ramp in JS

`tableValues` is a static attribute; it cannot reference `var(--ink)`. So read
the tokens at runtime and write the numbers:

```js
function applyToneRamp(el, filter) {
  const cs = getComputedStyle(el);
  const stops = ['--ink', '--accent', '--canvas'].map(v => cs.getPropertyValue(v).trim());
  const ch = stops.map(hexToRgb01);                        // [[r,g,b], …]
  filter.querySelector('feFuncR').setAttribute('tableValues', ch.map(c => c[0]).join(' '));
  filter.querySelector('feFuncG').setAttribute('tableValues', ch.map(c => c[1]).join(' '));
  filter.querySelector('feFuncB').setAttribute('tableValues', ch.map(c => c[2]).join(' '));
  el.style.filter = `url(#${filter.id}) saturate(1.7)`;
}
```

Call it on mount **and whenever the theme changes** (a `MutationObserver` on
`documentElement`'s `class`/`data-theme`, or your theme hook). On dark mode the
same `--ink/--accent/--canvas` resolve to different hexes and the artwork
re-tints with zero per-colour edits.

### Strip the root `width`/`height`

Remove the fixed `width`/`height` from the `<svg>` (keep the `viewBox`) so it
scales fluidly to its container via CSS. Add `preserveAspectRatio="xMidYMid
meet"`. The tuner's *Strip fixed width/height* toggle does exactly this.

The tuner's **Export → React snippet** emits this shape pre-filled with your
current ramp.

---

## 4. Gotchas ledger

| Symptom | Cause | Fix |
|---|---|---|
| Duotone looks washed / muddy | Only 2 stops — midrange is a flat blend | Add an **accent midstop** (tri-tone) |
| Midtones darker than the pickers suggest | `color-interpolation-filters` defaulting to `linearRGB` | Set `sRGB` explicitly on the `<filter>` |
| Font / `var()` tokens don't apply | SVG loaded as `<img>` — sandboxed | Render **inline** |
| `tableValues` won't pick up `--ink` | Filter primitives can't read CSS vars | Read tokens in JS, write the numbers; rebuild on theme change |
| SVG won't scale to its box | Fixed `width`/`height` on root | Strip them, keep `viewBox` + `preserveAspectRatio` |
| Trace output is inverted (art became holes) | `luma < threshold` selects the *dark* pixels | Toggle **Invert luminance** or move the threshold |
| Trace is slow / path count explodes | Working resolution too high, `detail` too low | Lower `resolution`, raise `detail`, raise `despeckle` |
| Traced holes filled solid | Missing even-odd rule | `fill-rule="evenodd"` on each layer's path |
| PNG export blank / "tainted canvas" | The rasterised SVG referenced a cross-origin resource | Inline/embed resources; trace output and self-contained SVGs are safe |
| PNG export missing the CSS look | `ctx.filter` didn't get the photographic chain | Bake tone-map into the SVG, apply the CSS functions via `ctx.filter` before `drawImage` |
| Recolour ignores some shapes | They carry inline `fill`/`stroke` the CSS filter still tints — but a `<style>` override may need `!important` | Scope an injected `<style>` and use `!important` (the tuner's Strokes & Fills does this) |
