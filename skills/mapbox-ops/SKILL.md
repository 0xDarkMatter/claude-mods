---
name: mapbox-ops
description: "Mapbox GL JS v3 (web) toolkit: custom markers, symbol/geojson layers, clustering, style expressions, 3D terrain/fill-extrusion, heatmaps, choropleths, camera animation, and performance gotchas. Use for any Mapbox GL JS work — markers, layers, style, 3D, or headless map verification."
license: MIT
compatibility: "Web mapbox-gl-js v3.x. screenshot_map.py needs Python 3.10+ and Playwright (chromium); check-mapbox-facts.py is stdlib-only Python 3.10+."
metadata:
  author: claude-mods
  related-skills: "color-ops, screenshot, genart-ops, threejs-ops"
---

# Mapbox GL JS — advanced web toolkit (v3)

An advanced toolkit for building production Mapbox GL JS map experiences on the **web**:
markers, thematic dataviz, 3D, terrain, cinematic camera, style composition, performance,
and the hard-won gotchas that bite. Scope: **`mapbox-gl-js` v3.x in the browser** (CDN
`mapbox-gl-js/v3.x/`) — not the native iOS/Android SDKs (different APIs). Plain GL JS,
framework-agnostic. Several patterns were distilled from a production trail map; adapt the
constants to your own design.

## Setup invariants

- Set `mapboxgl.accessToken` before `new mapboxgl.Map(...)`.
- The map needs **`'load'`** before adding sources/layers/images. In a throttled
  or background tab `'load'` can be missed — also bind `'idle'` as a one-shot
  fallback guarded by an `_inited` flag (see [verification.md](references/verification.md)).
- Resolving token/style from `.env`: **read the token FIRST** (that triggers the
  `.env` load), THEN read `MAPBOX_STYLE`. Reading the style before the token load
  silently falls back to the default style. See [palette.md](references/palette.md).
- **Classic vs Standard style.** Several techniques here (basemap palette recolour,
  the terrain boost-or-add `getStyle().layers` walk) assume a **classic** style
  (Streets/Outdoors/Light/Dark `…-v12`). The v3 default **Standard** style has no
  enumerable named layers — use slots + `setConfigProperty` instead. See
  [v3-standard-style.md](references/v3-standard-style.md) before porting to Standard.

## Pick the technique

Read the matching reference file only when the task needs it:

| Task | Reference |
|------|-----------|
| Custom SVG/canvas markers, `addImage`/`updateImage`, namespacing, AA/fringing, circular image masks, anchoring | [references/markers.md](references/markers.md) |
| Dashed/cased trail lines, `line-dasharray` units, translucency over hillshade, colour-by-attribute, `line-gradient`/`lineMetrics` | [references/lines-and-trails.md](references/lines-and-trails.md) |
| Hillshade, dense contours, 3D terrain (`setTerrain`), boost-or-add an existing style's terrain | [references/terrain.md](references/terrain.md) |
| Symbol-layer text labels that never hide icons (`text-optional`), AllTrails-style placement | [references/labels.md](references/labels.md) |
| Recolour a base style's land/vegetation fills (palette shift / choropleth-style `match`) | [references/palette.md](references/palette.md) |
| Custom popups, circular photo cards, zoom-scaled offsets | [references/popups.md](references/popups.md) |
| Style expressions — `interpolate`/`step`/`match`/`case`, the **zoom-outermost** rule, `feature-state` in expressions | [references/expressions.md](references/expressions.md) |
| Hover/select via `feature-state` (not `setData`), `queryRenderedFeatures` caveats, clustering, GeoJSON perf, event hygiene | [references/interaction-and-performance.md](references/interaction-and-performance.md) |
| Data viz & 3D — `fill-extrusion` buildings/extruded data, heatmap layer, data-join choropleth (feature-state/`match`), proportional symbols, sky/fog | [references/dataviz-and-3d.md](references/dataviz-and-3d.md) |
| **three.js in the map** — `CustomLayerInterface` + shared GL context, animated 3D objects/models, the baked-matrix vs reconstructed-camera (Threebox `CameraSync`) fork, raycast picking, ENU-metre scene space, constant screen-size actors, terrain elevation, far-plane clipping at pitch | [references/three-custom-layer.md](references/three-custom-layer.md) |
| Camera & animation — `flyTo`/`easeTo`/`fitBounds` padding, `freeCameraOptions` cinematics/orbit, flight/first-person camera (bearing+pitch choreography; roll is MapLibre-only), animated day–night cycle (`setLights`), HUD synced to camera, point-along-line, draw-in lines, paint transitions, spinning globe, the `essential`/reduced-motion gotcha | [references/camera-and-animation.md](references/camera-and-animation.md) |
| Style library & composition — first-party style catalog, choosing a base by use case, custom/third-party styles, style switcher, light/dark, hand-rolled style JSON | [references/styles.md](references/styles.md) (+ [assets/style-catalog.json](assets/style-catalog.json)) |
| `setStyle` wiping custom layers, the 0×0 `resize()` bug, SPA teardown / WebGL-context cap, token security, readiness events | [references/lifecycle.md](references/lifecycle.md) |
| **v3 Standard style** — slots vs `beforeId`, `setConfigProperty`/`lightPreset`, why layer-walking (palette/terrain) breaks; localisation, RTL, globe | [references/v3-standard-style.md](references/v3-standard-style.md) |
| Headless screenshot + pixel-accurate marker-alignment checks (Playwright, `map.project`) | [references/verification.md](references/verification.md) |

## Bundled resources

- **Starter code** — [assets/circular_image_marker.js](assets/circular_image_marker.js):
  copy into a page to register a circular photo marker (canvas → premultiplied
  `ImageBitmap`, `destination-in` mask, contact + drop shadow). Browser-only snippet,
  not a CLI — adapt the `frameColor`/box constants to your design.
- **Verifier script** — [scripts/screenshot_map.py](scripts/screenshot_map.py): drive
  headless Chromium to screenshot a *served* map page, assert a marker projects to its
  lng/lat, and surface console errors. Run it:

  ```bash
  python -m http.server 8777 --directory <site-dir> &          # serve the page
  uv run --with playwright scripts/screenshot_map.py \
    http://localhost:8777/preview/index.html out.png --expect 146.9 -36.1
  # exit 0 = no console errors; 10 = errors found; 5 = playwright missing; 7 = map never ready
  uv run --with playwright scripts/screenshot_map.py URL out.png --json | jq '.data'
  ```

- **Staleness verifier** — [scripts/check-mapbox-facts.py](scripts/check-mapbox-facts.py):
  stdlib-only (no Playwright), guards the fast-moving facts this skill encodes
  (SKILL-RESOURCE-PROTOCOL §7). `--offline` (default) asserts internal consistency —
  the v3 Standard config enums (`lightPreset`/`theme`), terrain tileset IDs, the weather
  (≥3.7) version gate, the no-native-camera-roll fact (roll is MapLibre GL JS v5, not
  Mapbox), and every style URL/id in
  [assets/style-catalog.json](assets/style-catalog.json). `--live` resolves the
  third-party style URLs and probes whether Mapbox GL JS has shipped a major past v3.

  ```bash
  python scripts/check-mapbox-facts.py --offline            # exit 0 ok, 4 inconsistency
  python scripts/check-mapbox-facts.py --live --json        # exit 7 network, 10 drift
  ```

## The three highest-value gotchas (full detail in the refs)

1. **Namespace every `addImage` name** (e.g. `"rcpin-<glyph>"`). Mapbox styles ship
   sprite icons literally named `parking`/`toilet`/etc — an un-namespaced
   `hasImage()` returns `true` for those and your icon is **silently dropped**.
2. **Register icons as premultiplied `createImageBitmap()`**, not a raw
   `HTMLImageElement`/`ImageData` — straight-alpha sources make Mapbox **fringe a
   white halo** around anti-aliased edges. `updateImage(name, bmp)` recolours in place.
3. **Data-driven `icon-offset` is silently ignored in GL JS v3.** Use a *constant*
   `icon-offset` (it scales with `icon-size`) or split markers into separate symbol
   layers, each with its own constant anchor/offset.
