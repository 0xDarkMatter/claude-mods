# iso-studio — the Companion Scene Composer (standalone app)

**iso-studio** is the zero-dependency browser scene composer that grew out of this
skill. It is now a **standalone app in its own repository** — it outgrew the skill
(an app with a roadmap and an asset library is a product, not a reference) and was
extracted so the plugin stays lean while the app evolves on its own release cadence.

| | |
|---|---|
| Local checkout | `X:\Forge\iso-studio` |
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
git clone https://github.com/0xDarkMatter/iso-studio X:\Forge\iso-studio
node X:\Forge\iso-studio\server.mjs
```
