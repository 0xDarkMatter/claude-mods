# Brand Mark Variants — mono, greyscale, knockout, light/dark

Every real brand needs its mark in more than one treatment: full colour on
white, reversed out of a dark header, greyscale on a partner wall, single-colour
where printing allows one ink. This file covers producing those without
wrecking the mark or your layout.

Companion to [icon-sources.md](icon-sources.md) (where marks come from) and
[inline-delivery.md](inline-delivery.md) (how any SVG reaches the page).

---

## Rule zero: use the owner's variant before you make one

**Most brand guidelines already publish a mono, a reversed and a greyscale
version.** They are drawn, not computed — a designer thickened a hairline that
would disappear when knocked out, or removed a gradient that greyscales to mud.
A generated variant is a *fallback for when no official one exists*, never the
first choice.

Order of preference:

1. The owner's official variant from their brand/press page.
2. A generated variant, if they publish none and your use is permitted.
3. Nothing — use the full-colour mark on a background that suits it.

This matters legally as well as visually: modifying a mark is exactly what
trademark guidelines restrict (see
[trap 1](icon-sources.md#1-brand-logos-are-trademarks-whatever-the-file-licence-says)).
Generating a knockout for a dark header is normally uncontroversial and often
explicitly permitted; recolouring a mark into *your* palette usually is not.

## The two colour worlds

Everything below depends on which of these you are holding, and they behave
completely differently:

| | Mono icon / mono mark | Full-colour mark |
|---|---|---|
| Source | one colour, or `currentColor` | several colours, often gradients |
| Recolour | **free** — CSS `color` drives it | needs a generated variant or a filter |
| Knockout | `color: #fff` | generate, or use the official reversed asset |
| Greyscale | already mono | luminance-map, or `filter: grayscale(1)` |

A mono mark is a solved problem: `fill="currentColor"` and the CSS cascade does
the rest, in every state and both themes, with no extra assets.

## Producing variants

`scripts/normalize-icon.py` will not guess. A multi-colour source is **refused**
(exit 11) until you name the treatment, because flattening a mark silently is
both lossy and a modification:

```bash
# Keep it exactly as published — the correct default for someone else's mark
normalize-icon.py --keep-colour acme.svg -o src/logos/acme.svg

# Knockout / reverse-out for a dark header
normalize-icon.py --tint '#fff' acme.svg -o src/logos/acme-knockout.svg

# Greyscale, Rec.709 luminance-mapped (preserves relative tonal separation)
normalize-icon.py --greyscale acme.svg -o src/logos/acme-grey.svg

# A single brand ink
normalize-icon.py --tint '#0f172a' acme.svg -o src/logos/acme-mono.svg

# Genuinely mono icon drawn with several greys — collapse to currentColor
normalize-icon.py --flatten scruffy-icon.svg -o src/icons/thing.svg
```

**Why luminance and not average.** Rec.709 weights green far above blue
(0.2126R + 0.7152G + 0.0722B) because the eye does. A naive `(r+g+b)/3` renders
a saturated blue and a saturated yellow as near-identical greys, collapsing
exactly the contrast the mark relies on.

### The CSS alternative, and when it is wrong

```css
.logo--grey { filter: grayscale(1); }
.logo--grey:hover { filter: none; }          /* the partner-wall convention */
```

A CSS filter is right for a **hover-reveal** effect: one asset, reversible, no
extra request. It is wrong when the greyscale version is the *canonical* asset,
because a filter cannot fix the things a designer would — a gradient that turns
to mud, a hairline that vanishes, a light element that disappears on white.
Generate the asset when it is the real one; filter when it is an effect.

`filter: invert(1)` is **never** a knockout. It inverts hue as well as
lightness, so a blue mark becomes orange. Use a real knockout variant.

## Light/dark pairs

Dark mode rarely wants the same mark with a different colour — it often wants a
*different asset*, because the light-mode mark may contain a light element that
disappears. Three approaches, best first:

```html
<!-- 1. Two assets, browser picks. Works in plain HTML, no JS, no flash. -->
<picture>
  <source srcset="/logos/acme-dark.svg" media="(prefers-color-scheme: dark)">
  <img src="/logos/acme.svg" alt="Acme" width="120" height="32">
</picture>
```

```css
/* 2. Two elements, CSS toggles. Needed when the theme is class-driven, not
      media-driven — a user-selectable theme is not prefers-color-scheme. */
.logo-dark { display: none; }
[data-theme="dark"] .logo-light { display: none; }
[data-theme="dark"] .logo-dark  { display: block; }
```

```xml
<!-- 3. One SVG that adapts internally. Elegant, but ONLY works when inlined:
        a media query inside an SVG loaded via <img> evaluates against the
        image's own context and will not see the page's theme reliably. -->
<svg viewBox="0 0 120 32">
  <style>
    .mark { fill: #0f172a; }
    @media (prefers-color-scheme: dark) { .mark { fill: #f8fafc; } }
  </style>
  <path class="mark" d="…"/>
</svg>
```

Approach 3 is the one people reach for and the one that most often fails, because
the failure only appears once the SVG is moved into an `<img>` or a CSS
background. If the mark must adapt and might be loaded as an image, use 1 or 2.

## Logo walls — size by area, not by width

**The single most common logo-wall bug is `width: 120px` on everything.** Marks
have wildly different aspect ratios: a wide wordmark set to the same width as a
square badge occupies roughly three times the visual area and dominates a grid
that was supposed to read as equals.

Constrain both axes inside a fixed box and let each mark find its own fit:

```css
.logo-wall { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 2rem; align-items: center; }
.logo-wall img {
  max-width: 100%;
  max-height: 40px;      /* the real constraint for wide wordmarks */
  width: auto;
  height: auto;
  margin-inline: auto;
  display: block;
}
```

Then correct **optically**, not mathematically. Equal bounding boxes still read
unequal: a circular mark looks smaller than a square one of identical height, and
a mark with heavy strokes looks larger than a fine one. Nudge per-logo with a
modifier class rather than pursuing a formula — this is a judgement call every
design system ends up making by eye.

Two more that bite:

- **Always set `width` and `height` attributes** on logo `<img>` elements even
  when CSS overrides them; without an intrinsic ratio the grid reflows as each
  logo lands, and Cumulative Layout Shift is measured on exactly this.
- **Give marks a consistent optical padding**, not a consistent box. Most brand
  guidelines specify clear space in terms of the mark's own geometry (e.g. "the
  height of the A"); honour that rather than a uniform CSS padding.

## Accessible names for logos

The [two-case rule](inline-delivery.md#accessibility--exactly-two-cases) applies,
with one logo-specific convention:

```html
<!-- Home link: the mark IS the label. Name it for the company, not the file. -->
<a href="/" aria-label="Acme, home">
  <svg class="logo" aria-hidden="true" focusable="false">…</svg>
</a>

<!-- Partner wall: the company name is the content, so it must be readable -->
<img src="/logos/acme.svg" alt="Acme" width="120" height="32">

<!-- Decorative repetition — the name is already in adjacent text -->
<figure>
  <img src="/logos/acme.svg" alt="" width="120" height="32">
  <figcaption>Acme</figcaption>
</figure>
```

**Never `alt="Acme logo"`.** A screen reader already announces it as an image;
"logo" is noise, and the useful information is the company name. `alt=""` is
correct — and required — when the name appears in adjacent text, or the name is
announced twice.

## Cross-reference

- Where marks come from and the trademark position → [icon-sources.md](icon-sources.md)
- Delivery, sizing, the full a11y checklist → [inline-delivery.md](inline-delivery.md)
- Duotone/tri-tone filter treatments and raster→vector tracing → `svg-brand-tint-ops`
- Choosing the palette a tint targets → `color-ops`
