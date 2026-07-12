# Cutout methods — how each works and when it wins

Companion to [SKILL.md](../SKILL.md). The skill body owns the *decision ladder*;
this file owns the *mechanism* — why each method behaves as it does, so you can
reach for the right one and tune it.

## Why flat sticker art is a special case

General background removal is hard because photographic backgrounds are busy and
the subject boundary is fuzzy. Flat illustration is the opposite: **one flat
background colour, a thick sealing outline, hard-edged flat fills.** That structure
is what makes a deterministic colour-key exact — and it's exactly the structure
ML saliency models *don't* need, so they sometimes fight it. Pick the method that
exploits the structure you have.

## 1. `rembg` (ML segmentation) — the default engine

rembg wraps U²-Net / IS-Net segmentation models. This skill defaults to
**`isnet-anime`**: IS-Net (the "Dichotomous Image Segmentation" architecture,
Qin et al. ECCV 2022) fine-tuned on anime/cartoon line-art. It learned that "the
subject" is the ink-outlined, flat-filled character region — the visual grammar of
sticker art — so it:

- cuts crisply *at* the black outline (not a soft photographic feather), and
- treats a baked drop-shadow as *not the character* and usually drops it.

It's **colour-agnostic** (semantic, not chroma) — a greenscreen background helps it
none. Its failure mode is **low salience**: a pale subject that doesn't "pop"
against a light background (a cream moon, a mint UFO) is read as background and
dropped. Detect this as a collapsed alpha coverage (`< --min-cov`).

`u2net` (rembg's default model) is trained on general/photographic salient objects
— on flat cartoon art it softens edges and half-keeps baked shadows as a grey
ghost. Use it for photos, not stickers.

## 2. `colorkey` (flat-bg flood-fill) — the deterministic recoverer

Sample the background colour from the four corners (median), mark pixels within
`--tol` of it, then **flood-fill from the image border** and transparent-out only
the background region reachable from an edge. Everything the outline seals off
stays fully opaque.

Why it's the workhorse fallback:

- **Ignores subject brightness** — recovers the pale subjects rembg drops.
- **Forces translucent subjects opaque** — a clear-plastic cup or glass that rembg
  gives partial alpha becomes solid, because the whole outline-sealed interior is
  kept at alpha 255.
- **Keeps interior background-coloured regions** — a bg-colour patch *inside* the
  subject doesn't touch a border, so it survives (flood only removes edge-reachable
  bg). This is the difference from a naive global colour replace.
- **Deterministic** — no model, no download, same output every run.

Its blind spot: a **baked drop-shadow** is a distinct dark shape sitting *on* the
background. Colour-key removes the bg colour but leaves the shadow (it isn't
bg-coloured). Hence the two shadow post-processors below.

Tuning: raise `--tol` if a slightly noisy/gradient background leaves a colour fringe;
lower it if the key eats into a subject colour close to the background.

## 3. `--flatten-alpha T` — kill a semi-transparent shadow ghost

When rembg keeps a baked shadow as a **~50%-opaque** ghost (you can see the
checkerboard through it) while the subject is fully opaque, binarise the alpha:
`alpha = 255 if alpha >= T else 0`. The translucent shadow drops; the opaque
subject stays. `T≈170` cleanly separates a half-opaque shadow from a solid subject.
Side effect: it hardens anti-aliased edges to a die-cut — desirable for stickers,
and invisible at avatar size.

Fails when the shadow is **fully opaque** (nothing to threshold) — use method 4.

## 4. `--strip-offset-shadow` — remove an opaque baked offset shadow

The hard case: a solid, offset drop-shadow that survives binarise. Colour-aware
removal:

1. colour-key the background (method 2) → subject + shadow remain, subject opaque.
2. classify **dark** pixels (`luma < ~80`) = outline **and** shadow.
3. classify **coloured** pixels = the subject's non-dark fills.
4. dilate the coloured region a few px; **keep a dark pixel only if it hugs a
   coloured fill** (that's the outline) and **drop dark pixels standing alone**
   (that's the offset shadow, which sits behind/beside the subject, away from any
   fill).

Keeps the subject's own outline and any outlined decorations (their dark edge hugs
a light interior); removes the detached offset shadow. Assumes a dark shadow and
coloured subject fills — on an all-dark subject it over-eats, so prefer
`--flatten-alpha` there.

## Choosing quickly from a contact sheet

Render `--contact-sheet` (every cutout on a checkerboard) and scan:

- **Missing / ghostly** → `--method colorkey` (pale subject).
- **See-through where it should be solid** → `--method colorkey` (translucent subject).
- **Grey haze offset behind the subject** → `--flatten-alpha 170`.
- **Solid dark shape offset behind the subject** → `--strip-offset-shadow`.
- **Clean** → leave it (rembg got it).

Batch the whole set on `auto`, then re-run only the handful that need escalation
into the same `--out` dir (they overwrite by name).
