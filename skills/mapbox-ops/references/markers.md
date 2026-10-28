# Custom markers (SVG / canvas → `addImage`)

Two ways to put a custom marker on the map:

- **`mapboxgl.Marker`** — a DOM element pinned to a lng/lat. Fine for a handful of
  markers; doesn't cluster, doesn't batch, repaints in the DOM. Avoid for many points.
- **Symbol layer + `map.addImage`** (this file) — register an image once, reference
  it by name from a `symbol` layer's `icon-image`. Batches, clusters, GPU-drawn,
  data-driven. Use this for anything beyond a few markers.

## Table of contents
- [Namespace every image name](#namespace-every-image-name) — silent-drop gotcha
- [Register as premultiplied ImageBitmap](#register-as-premultiplied-imagebitmap) — white-fringe gotcha
- [Recolour in place with updateImage](#recolour-in-place-with-updateimage)
- [Circular image markers](#circular-image-markers) — mask correctly
- [Atlas aliasing at low zoom](#atlas-aliasing-at-low-zoom) — keep edges chunky
- [High pixelRatio, never upscale](#high-pixelratio-never-upscale)
- [Anchoring: tip / centre / offset](#anchoring-tip--centre--offset) — offsets scale with icon-size

## Namespace every image name

Mapbox base styles ship sprite icons literally named `parking`, `toilet`, `circle`,
etc. `map.hasImage("parking")` returns **`true`** for the style's sprite even though
*you* never added it. If you guard `addImage` with that check, your icon is never
registered and the symbol layer **silently falls back to the style's plain glyph**.

Always prefix your names so they can't collide:

```js
const PIN = g => "rcpin-" + g;          // "rcpin-camera", "rcpin-parking", …
if (!map.hasImage(PIN(glyph))) map.addImage(PIN(glyph), bmp, {pixelRatio: 4});
```

## Register as premultiplied ImageBitmap

A marker drawn from an `<svg>`/`<canvas>` has **straight (non-premultiplied) alpha**
at its anti-aliased edge. Feeding Mapbox a raw `HTMLImageElement` or `ImageData`
makes it bleed a **white halo / fringe** around every curved edge.

`createImageBitmap()` produces a **premultiplied-alpha** bitmap → clean edges. Fall
back to the raw element only if `createImageBitmap` throws:

```js
const img = new Image(W, H);
img.onload = async () => {
  try {
    const bmp = await createImageBitmap(img);   // premultiplied alpha → no fringe
    if (map.hasImage(name)) map.updateImage(name, bmp);
    else map.addImage(name, bmp, {pixelRatio});
  } catch (e) {
    if (!map.hasImage(name)) map.addImage(name, img, {pixelRatio});  // fallback
  }
};
img.src = "data:image/svg+xml;base64," + btoa(unescape(encodeURIComponent(svg)));
```

For a `<canvas>` source, `createImageBitmap(canvas)` works the same way.

## Recolour in place with updateImage

To recolour a marker (e.g. a colour-picker in a dev panel), re-render the SVG/canvas
with the new colour and call **`map.updateImage(name, bmp)`** — same name, no layer
churn, the symbol layer repaints automatically. Rebuild *all* affected names:

```js
function setPoiColor(c) { poiColor = c; buildAllPins(map, /*force*/ true); }
// addPin(): if hasImage → updateImage(name, bmp) else addImage(name, bmp, …)
```

## Circular image markers

To crop a photo into a disc, **never use `ctx.clip()`** — clip is a 1-bit hard mask
and leaves a **jagged** circle edge. Mask with an **anti-aliased arc fill** via
`globalCompositeOperation = "destination-in"` on a scratch canvas:

```js
// scratch canvas sized to the photo disc
const sc = document.createElement("canvas"); sc.width = sc.height = d;
const sx = sc.getContext("2d");
sx.imageSmoothingEnabled = true; sx.imageSmoothingQuality = "high";
// cover-fit the photo
const scale = Math.max(d/iw, d/ih);
sx.drawImage(img, (d-iw*scale)/2, (d-ih*scale)/2, iw*scale, ih*scale);
// AA circular mask: keep only pixels inside the arc
sx.globalCompositeOperation = "destination-in";
sx.beginPath(); sx.arc(d/2, d/2, d/2, 0, 2*Math.PI); sx.fill();
// draw the masked disc into the marker canvas
ctx.drawImage(sc, cx - r, cy - r, 2*r, 2*r);
```

Full marker (frame + contact shadow + drop shadow + sheen + masked photo) in
[../assets/circular_image_marker.js](../assets/circular_image_marker.js) — copy-paste
starter code, adapt the colour/box constants.

Same-origin caveat: if the photo is fetched cross-origin the canvas is **tainted**
and `createImageBitmap`/`toDataURL` throw. Serve the page and images from the same
origin, or set `img.crossOrigin = "anonymous"` and serve images with CORS headers.

## Atlas aliasing at low zoom

Mapbox does **not mipmap** the icon atlas. A raster icon minified at low zoom
**aliases/shimmers** — and thin, high-contrast features (a 1–2px white outline or
photo rim) shimmer worst. Mitigations:

- Keep small-marker edges **chunky**; drop thin white rings on small badges (we
  removed a white pin-outline and a white photo-rim purely to stop the shimmer).
- Fade markers in over zoom so the worst-aliased small sizes barely show:
  `"icon-opacity": ["interpolate",["linear"],["zoom"], 11,0, 12,1]`.

## High pixelRatio, never upscale

Render the SVG/canvas at a **high DPI** (4×–6×) and register with the matching
`{pixelRatio}` so the icon is crisp on retina. But **don't let `icon-size` scale the
icon past its native pixel size** — upscaling a raster icon blurs it. Size the source
big enough that your max `icon-size` still maps ≤ 1.0 of native.

```js
const F = 6, W = 44*F, H = 52*F;          // draw at 6×
map.addImage(name, bmp, {pixelRatio: F}); // declare the 6×
// icon-size ramp stays ≤ ~1.5 of the *logical* box, well within native pixels
```

## Anchoring: tip / centre / offset

`icon-offset` is data-driven in GL JS v3: `["get", "offset"]` or a `["case", …]` that
returns an array works, so a per-feature offset can fan out pins that share a
coordinate. (An earlier version of this file said data-driven offsets were
silently ignored; the style spec marks the property data-driven, and a headless render
on GL JS 3.29.0 showed them applied.) The offset is in icon units and **scales with
`icon-size`**, so one value works across zooms. Two ways to anchor marker families:

1. **Constant or per-feature `icon-offset`** in one layer, paired with matched padding
   baked into every icon of that layer.
2. **Separate symbol layers**, each with its own anchor and offset, when families differ
   in more than the offset (different anchors, sizes or collision rules). Example: glyph
   badges centred on the point vs photo bubbles whose tip sits on the point —

```js
// glyph badges: disc centred on the point
map.addLayer({ id:"poi-glyph", type:"symbol", source:"pois",
  filter:["all",["!",["has","point_count"]],["!=",["get","_kind"],"photo"]],
  layout:{ "icon-image":["get","_iconimg"], "icon-anchor":"center",
           "icon-size":[/* zoom ramp */], "icon-allow-overlap":true }});

// photo bubbles: padded tip lands on the point.
// icon drawn in a 44×52 box with the tip at y=44 → 8 units of shadow padding below.
// icon-anchor:"bottom" + constant icon-offset:[0,8] (× icon-size) cancels that pad.
map.addLayer({ id:"poi-photo", type:"symbol", source:"pois",
  filter:["all",["!",["has","point_count"]],["==",["get","_kind"],"photo"]],
  layout:{ "icon-image":["get","_iconimg"], "icon-anchor":"bottom",
           "icon-offset":[0,8], "icon-size":[/* zoom ramp */],
           "icon-allow-overlap":true }});
```

Rule of thumb for landing a padded marker's tip on the point: `icon-anchor:"bottom"`
+ `icon-offset:[0, padUnits]`, where `padUnits` is the shadow padding drawn below the
tip (the offset is multiplied by `icon-size`, so it tracks zoom automatically).
