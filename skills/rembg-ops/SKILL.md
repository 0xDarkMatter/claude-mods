---
name: rembg-ops
description: "Transparent-PNG cutouts / background removal for flat illustration, sticker, cartoon and avatar art — rembg (isnet-anime) with a deterministic fallback ladder for the cases ML drops. Triggers on: rembg, remove background, background removal, transparent PNG, cutout, die-cut sticker, isnet-anime, alpha matte, chroma/colour key, remove drop shadow, avatar cutout, flat illustration cutout."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: color-ops, svg-brand-tint-ops
---

# rembg Operations — cutouts for flat illustration & sticker art

Turn opaque, flat-background illustration (avatars, stickers, cartoon/vector art,
generated character portraits) into clean **transparent PNGs** — without
regenerating the source. rembg's ML models are the default engine; the value this
skill adds is the **deterministic fallback ladder** for the cases pure ML gets
wrong on flat-colour art.

## The one thing to know

**rembg is a semantic model, not a chroma keyer.** `isnet-anime` (the model tuned
for outlined cartoon art) segments *the salient character* and ignores background
*colour* — so it cannot be "helped" with a greenscreen, and it fails in two
predictable ways on flat art:

1. **Pale / low-salience subjects get dropped** (a near-white moon, a mint UFO on a
   light background read as "not the subject").
2. **Baked drop-shadows** survive as a grey ghost or an opaque offset blob.

Both are fixed deterministically because flat sticker art always has **one flat
background colour + a sealing outline**. That geometry makes a corner flood-fill
colour-key exact, regardless of how pale the subject is. **The axis that matters is
shadow-vs-no-shadow, never greenscreen-vs-not.**

## Quickstart

```bash
# default: rembg isnet-anime, auto-fallback to colour-key if the subject collapses
python scripts/cutout.py "avatars/*.png" --out cutouts/ --contact-sheet
```

The `--contact-sheet` renders every cutout on a checkerboard so bad mattes jump
out. Then triage failures with the ladder below. `--json | jq '.data[] |
select(.coverage < 0.12)'` flags collapsed subjects programmatically.

## Method ladder — escalate only for the images that need it

| Symptom on the contact sheet | Fix | Flag |
|---|---|---|
| Clean die-cut | — (rembg isnet-anime) | default |
| Subject gone / faint ghost (pale subject) | flat-bg colour-key | `--method colorkey` |
| Translucent subject reads see-through (glass, clear cup) | colour-key forces the sealed interior opaque | `--method colorkey` |
| Semi-transparent grey shadow ghost | binarise alpha — drops the ~50% shadow, keeps the 100% subject | `--flatten-alpha 170` |
| Opaque baked offset shadow (survives binarise) | colour-aware: drop dark pixels not hugging a coloured fill | `--strip-offset-shadow` |

`auto` (the default) already does rembg→colour-key when the silhouette collapses
(`--min-cov`, default 0.10). The post-processing flags are opt-in per image because
detecting a shadow ghost automatically is unreliable — eyeball the sheet, escalate
the few that need it. See [references/cutout-methods.md](references/cutout-methods.md)
for how each method works and why.

## Why no regeneration

Every method here **alpha-masks the original pixels** — it never re-renders the
subject. That's what lets you cut out AI-generated character art (or any
hand-drawn asset) without changing how the character looks. If your generator is
text-to-image only (no img2img / transparent-output flag, e.g. most portrait
CLIs), local background removal is the *only* way to get transparency without a
character-drifting re-roll.

## The intended downstream shape

Cut once to transparent PNG, then composite in the app: **transparent PNG over a
CSS background colour + a CSS hard-offset shadow** (drawn in CSS, not baked into
the image). This is what makes a colour-picker possible — one asset, any
background. Never bake the shadow back into the PNG.

## Gotchas

- **`isnet-anime` vs `u2net`:** the default `u2net` model leaves a grey ghost of a
  baked shadow and softer edges on cartoon art — always pass `--model isnet-anime`
  (this skill's default) for flat/outlined work. `u2net` is fine for photos.
- **First rembg run downloads a ~170 MB model** (cached after). Fully offline work
  → `--method colorkey`.
- **Colour-key keeps bg-coloured regions *inside* the subject** (they don't touch
  a border) — a subject with a same-as-background patch stays intact. It only
  removes background reachable from the image edge.
- **Disconnected decorations** (sparkle stars floating on the background) are kept
  by colour-key as islands — usually what you want for a sticker; crop them out
  first if not.
- **`--strip-offset-shadow` assumes a dark shadow + coloured subject fills.** On an
  all-dark subject it will over-eat; use `--flatten-alpha` there instead.

## Dependencies

`pillow` + `numpy` (required); `scipy` (optional, faster flood-fill); `rembg`
(only for the `rembg`/`auto` ML path — `colorkey` and the post-processors are
pure Pillow/numpy and need no model download).

```bash
uv pip install pillow numpy scipy rembg   # rembg optional
```
