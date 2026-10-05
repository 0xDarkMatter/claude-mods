# iso-studio — the Companion Scene Composer (standalone app)

**iso-studio** is the zero-dependency browser scene composer that grew out of this
skill. It is now a **standalone app in its own repository** — it outgrew the skill
(an app with a roadmap and an asset library is a product, not a reference) and was
extracted so the plugin stays lean while the app evolves on its own release cadence.

| | |
|---|---|
| Local checkout | wherever you cloned it — see Repository below |
| Repository | `https://github.com/0xDarkMatter/iso-studio` |
| Launch | `node server.mjs` → http://localhost:4323 (`PORT` env overrides) |
| Manual | `docs/MANUAL.md` in the app repo — workspace tour, hotkeys, scene schema, known limits |
| Scene format | `scene-schema.json` in the app repo (draft-07, version `"1.0"`) |

## What it does

- **Stage** — snap-to-grid placement (full/half/quarter/free) on true-isometric,
  2:1 dimetric, or custom-angle grids; drag-drop/paste/pick PNG/SVG/WebP; per-asset
  anchor (feet by default) and tile footprint
- **Compose** — automatic y-sort implementing this skill's
  [depth doctrine](coordinates-depth.md) (`(x+y)`, elevation, layer, zBias), three
  layers, marquee/nudge/flip, undo/redo, tri-tone tint (per scene or per instance,
  presets shared with [`assets/palettes/`](../assets/palettes/three-tone-presets.json))
- **Blockout → ControlNet** — the signature workflow: place parametric grey primitives
  (box/slab/ramp/cylinder), export an elevation-aware **depth map** and a **lineart
  render**, and feed both into the ControlNet conditioning workflow in
  [`ai-generation.md`](ai-generation.md) §4 — the lightweight, web-native alternative
  to the [Blender depth/normal pipeline](blender-prerender.md) §3
- **Export** — PNG 1×/2×/4× (transparent, crop-to-content), SVG when the composition
  is all-vector, and versioned scene JSON that round-trips with assets embedded

## How this skill and the app relate

The app implements this skill's math and doctrine — its `MATH` section is a direct
port of [`coordinates-depth.md`](coordinates-depth.md) and is required to agree with
[`projection-math.md`](projection-math.md)'s canonical constants. The skill owns the
knowledge (references, tile-spec, AI pipeline, CLI scripts); the app repo owns the
software, the scene schema, and the starter asset library. When composing scenes:
write the [tile spec](tile-spec.md) first, validate AI-generated tiles with
[`tile-validate.py`](../scripts/tile-validate.py), compose in iso-studio, then pack
shipping sheets with [`sheet-pack.py`](../scripts/sheet-pack.py).

If the local checkout is missing, clone it:

```
git clone https://github.com/0xDarkMatter/iso-studio
node iso-studio/server.mjs
```

### Route E — Compose a scene (iso-studio)

The companion **iso-studio** scene composer (standalone app, local checkout
github.com/0xDarkMatter/iso-studio) stages assets on a snap-to-grid isometric canvas with automatic
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

## 5. iso-studio — the scene composer (standalone app)

**iso-studio** is a zero-dependency, no-build isometric scene composer that grew out of
this skill and now lives in its own repository — clone it wherever you keep checkouts,
remote `github.com/0xDarkMatter/iso-studio` (`index.html` + `server.mjs`, no npm deps).
Launch it, then work the docked palettes:

```
node <iso-studio>/server.mjs            # then open http://localhost:4323
PORT=8080 node <iso-studio>/server.mjs
```

- **Canvas + Grid** — projection selector (2:1 dimetric / true isometric / custom angle),
  tile W×H (H is derived-and-locked for the two named projections), grid extent, and a
  full / half / quarter / free snap segmented control.
- **Asset tray** — drag-drop, clipboard-paste, or file-picker import (PNG/SVG/WebP, stored
  as data URIs so scenes are self-contained); click-to-place, stays armed for rapid
  placement.
- **Depth sorting** — automatic `(x+y) → elevation → layer → zBias` sort across
  ground / props / overlay, matching the doctrine in
  [`coordinates-depth.md`](coordinates-depth.md) exactly.
- **Inspector, Scene, Export palettes** — anchor/footprint/elevation/scale/flip/zBias
  editing; background/checkerboard/canvas size; PNG export at 1×/2×/4× (crop-to-content,
  transparent), SVG export (gated — every placed asset must be SVG-sourced), and scene
  JSON save/load conforming to the app repo's `scene-schema.json` (version "1.0").
- **Blockout mode (signature feature)** — place flat-shaded three-tone grey primitives
  (box / slab / ramp / cylinder) and export a **depth map** and a **lineart** render sized
  to the canvas; both condition the ControlNet step of the AI pipeline
  ([`ai-generation.md`](ai-generation.md) §4) without touching Blender.
- **Undo/redo** (`Ctrl+Z` / `Ctrl+Y`, ≥50 steps, drag-moves and rapid nudges coalesced
  into single entries) and the full hotkey legend via `?` in-app.

The full manual — workspace tour, projection/snap configuration, anchor-at-feet
discipline, the complete hotkey table, the scene-JSON schema walkthrough, the
blockout → depth/lineart → ControlNet round trip step by step, and a "known limits"
section (depth export is per-instance flat grey, elevation-aware but not per-face;
`flipX` mirrors a ramp's slope, no-op on symmetric primitives) — lives in the app repo
at `docs/MANUAL.md`; this skill's [`references/iso-studio.md`](iso-studio.md)
is the quickstart pointer.
