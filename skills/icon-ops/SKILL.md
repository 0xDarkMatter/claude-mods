---
name: icon-ops
description: "Source, vet, normalize and ship SVG icons for web UI - set selection, licence and trademark traps, currentColor theming, sprite/inline delivery, and accessibility. Triggers on: icon, icons, svg icon, find an icon, add an icon, icon set, icon library, iconify, lucide, heroicons, phosphor, tabler, feather, material symbols, font awesome, simple icons, brand logo, icon sprite, svg sprite, symbol use, currentColor, icon won't change colour, icon font, icon accessibility, aria-hidden icon, icon-only button, icon size, icons look inconsistent, mixed icon sets, normalize svg, strip svg cruft, optimise svg, brandfetch, company logo, client logo, logo by domain, brand assets api, logo api, thesvg, brand icon, brandmark, brand mark, find a logo, logo wall, partner logo, greyscale logo, grayscale, tint a logo, reverse out, knockout, mono logo, dark mode logo, favicon, app icon, apple-touch-icon, maskable icon, svg id collision."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: svg-brand-tint-ops, color-ops, tailwind-ops
---

# icon-ops

Getting an icon onto a page is easy. Getting one that themes correctly, carries
the right licence, matches the twelve icons beside it, and behaves for a screen
reader is where the work actually is.

## Helps with

An icon that won't change colour on hover, in dark mode, or when the theme
switches — almost always a hardcoded `#000` in the file where `currentColor`
should be.

A UI where the icons "look off" without an obvious cause. Usually two icon sets
mixed: different grid size, different stroke width, different corner language.
Individually fine, together visibly wrong.

Choosing an icon set at the start of a project, when the choice is cheap, rather
than after 60 icons are embedded.

Using a brand logo — GitHub, Google, a client's mark — and needing to know
whether you actually may. The file licence does not answer this; trademark does.

Needing a logo for an arbitrary company that no icon set carries. That is a
different category from icon sets — a runtime lookup by domain, not a committed
glyph — with its own quota, caching and trademark consequences.

Icon-only buttons that a screen reader announces as "button", or announces
twice. Both come from putting the accessible name in the wrong place.

Vendor SVGs carrying Inkscape/Figma metadata, fixed `width`/`height` that fights
CSS, and inline styles that resist theming.

Deciding between inline SVG, a `<symbol>` sprite, framework components, and an
icon font — and discovering too late that `<img src="icon.svg">` cannot be
recoloured at all.

A sprite that renders nothing in production but worked locally (the external
`<use>` CORS trap).

Two inlined logos where the second one's gradient bleeds into the first. Both
files declared `id="a"`; the last definition in the document wins for the whole
page. Brand marks hit this constantly because they carry gradients.

Needing a mark in grey, knocked out of a dark header, or in one brand ink — and
wanting to know whether to generate it or use the owner's published variant.

A logo wall where one wide wordmark dominates because everything was set to the
same `width`.

Favicons and app icons — the modern four-file set, and why an Android maskable
icon gets its edges cropped.

## The core technique

**`fill="currentColor"` is the whole game.** An icon that inherits the CSS
`color` of its context gets hover, focus, disabled, dark mode, and every future
theme for free, with no icon-specific CSS. An icon with a baked-in hex breaks all
of them simultaneously, and each one gets "fixed" separately later.

Everything else in this skill exists to get icons into that state and keep them
there.

## Workflow

### 1. Choose the set before sourcing anything

Lock four decisions; they constrain every icon that follows:

| Decision | Options |
|---|---|
| Grid | 24 (most common) · 20 · 16 |
| Family | stroke · filled · both-as-matched-pair |
| Stroke width | 1.5 · 2 — **must be identical across the set** |
| Corner language | round caps/joins · square |

Sensible defaults: **Lucide** (ISC, 24-grid, stroke 2) for a general UI,
**Heroicons** (MIT) when you want matched outline/solid/mini tiers, **Phosphor**
(MIT) when you need multiple weights in one family.

Reach for a second set only when the first genuinely lacks the concept — then
match grid and stroke width and expect to redraw. Prefer a near-neighbour
concept from your set over an exact match from a foreign one.

Full comparison table, licences, and the aggregator problem →
[`references/icon-sources.md`](references/icon-sources.md).

### 2. Vet the licence — two traps

**Brand marks are trademarks regardless of file licence.** Simple Icons ships
brand logos under CC0, but the marks remain their owners' property. Nominative
use ("Sign in with GitHub") is fine; implying endorsement, recolouring a mark to
your palette, or putting it in your own logo is not. Quoting "it's CC0" as
clearance is the wrong answer.

**A company logo is not a UI icon.** Three sources cover brand marks and they
trade off reach against commitment — **Simple Icons** (committed, monochrome,
themeable), **theSVG** (MIT, 6,500+ marks in brand colour via
`npm i thesvg`, an MCP server needing no key, or `npx skills add glincker/thesvg`), and **Brandfetch** (runtime lookup by *domain*, any company, nothing
committed; free key at developers.brandfetch.com/dashboard, hotlink-only URLs
that expire in ~24h, and two free tiers that differ by 10,000x). All three carry
the identical trademark position — see
[Brand marks](references/icon-sources.md#brand-marks--three-sources-one-trademark-position).
They resolve the mark for you; none of them clears it.

**Aggregators hide the licence.** Iconify, and any icon-search MCP or plugin,
resolve across 150+ sets each keeping its own terms. Record the *originating
set* and its licence when the icon enters the repo — one line in `LICENSES.md`
or atop the sprite. That single line is the difference between an answerable
question and an audit.

### 3. Normalize before it enters the repo

Vendor output is not shippable. `scripts/normalize-icon.py` strips editor cruft,
**namespaces internal ids** so two inlined SVGs cannot clobber each other's
gradients, drops fixed `width`/`height` so CSS controls size, and applies the
correct accessibility attributes.

**Colour is never guessed.** A single-colour source rebinds to `currentColor`. A
multi-colour source is **refused (exit 11)** until you name the treatment,
because flattening a mark to a silhouette is lossy *and* counts as modifying it:

| Flag | Result |
|---|---|
| *(default)* | mono source → `currentColor` |
| `--keep-colour` | colours untouched — the right default for someone else's mark |
| `--greyscale` | Rec.709 luminance-mapped grey |
| `--tint '#fff'` | flatten to one colour; white = knockout / reverse-out |
| `--flatten` | yes, really collapse a multi-colour source to `currentColor` |

**It also sanitises.** An *inlined* SVG runs script in your page's origin; an
`<img src="x.svg">` does not. Since this skill tells you to inline third-party
SVGs, the normalizer strips `<script>`, `<foreignObject>`, every `on*` handler
and `javascript:`/`data:text` hrefs. Treat any SVG you did not author as
untrusted input, and never inline one that has not been through this.

```bash
# Would this file change? exit 10 = yes, 0 = already clean
scripts/normalize-icon.py --check vendor.svg

# Normalize a filled icon into the repo (atomic write)
scripts/normalize-icon.py vendor.svg -o src/icons/search.svg

# A brand mark: keep its colours, just clean and namespace it
scripts/normalize-icon.py --keep-colour acme.svg -o src/logos/acme.svg

# Stroke icon: forces fill=none, stroke=currentColor, consistent caps/joins
scripts/normalize-icon.py --stroke vendor.svg -o src/icons/search.svg

# Append to a sprite as a <symbol>
scripts/normalize-icon.py --symbol --id i-search vendor.svg >> src/sprite.svg

# Machine-readable result (what changed, and why)
scripts/normalize-icon.py --json vendor.svg | jq '.data[0]'
```

Exit codes: `0` ok · `2` usage · `3` no such file · `4` not a usable SVG ·
`10` (`--check` only) normalization would change the file · `11` multi-colour
source refused. The `--check` mode is a CI gate — run it over `src/icons/` to
keep un-normalized icons out.

For byte-level path optimisation, run **SVGO after** normalizing, never before:

```bash
scripts/normalize-icon.py raw.svg -o icon.svg && npx svgo --multipass icon.svg
```

### 4. Deliver

| Mechanism | Themeable | Use when |
|---|---|---|
| **`<symbol>` sprite + `<use>`** | Yes | **Default for a real UI** — many icons, reused |
| Inline `<svg>` | Yes | Few icons, or per-path styling/animation |
| Framework component | Yes | Component stack already in play; tree-shakes |
| `<img src="icon.svg">` | **No** | Never for UI icons |
| Icon font | Colour only | Legacy only — migrate, don't extend |

Start a sprite from [`assets/sprite-template.svg`](assets/sprite-template.svg),
which carries the hiding pattern that survives Safari, per-symbol `viewBox` so
mixed grids scale correctly, and the sizing rule.

**Size in `em`, never `px`:**

```css
.icon { width: 1em; height: 1em; flex: none; }
```

`1em` keeps the icon optically matched to its label at every type scale.
`flex: none` stops a flex parent squashing it into an ellipse — the most common
icon layout bug there is.

**The trap that only shows in production:** an external
`<use href="/sprite.svg#id">` is CORS-blocked cross-origin and renders nothing,
sometimes with no console error. Inline the sprite into the document.

Decision detail, icon-font failure modes, and optimisation order →
[`references/inline-delivery.md`](references/inline-delivery.md).

### 5. Get the accessibility right — exactly two cases

Every icon is decorative or meaningful. Leaving it undecided is the defect.

```html
<!-- Decorative: text beside it already names the control -->
<button>
  <svg class="icon" aria-hidden="true" focusable="false"><use href="#i-trash"/></svg>
  Delete
</button>

<!-- Meaningful: the icon IS the label -->
<button aria-label="Delete item">
  <svg class="icon" aria-hidden="true" focusable="false"><use href="#i-trash"/></svg>
</button>
```

**Name the control, not the icon.** The counter-intuitive part is that the SVG
stays `aria-hidden` in *both* cases — a name on the icon *and* on the button
produces a double announcement. `role="img"` + `<title>` is for standalone
graphics, not for the contents of a control.

Also: icon-only controls need a **24×24 CSS px** minimum interactive area (WCAG
2.2 §2.5.8) — pad the control, don't grow the glyph. Never let colour alone carry
meaning: pair it with a distinct shape.

### 6. Variants and site icons

A mark rarely ships in one treatment. **Use the owner's published mono/reversed/
greyscale asset when one exists** — theirs is drawn, yours is computed, and a
designer already fixed the hairline that vanishes when knocked out. Generate
only when they publish none.

```bash
scripts/normalize-icon.py --tint '#fff'  acme.svg -o src/logos/acme-knockout.svg
scripts/normalize-icon.py --greyscale    acme.svg -o src/logos/acme-grey.svg
```

`filter: grayscale(1)` is right for a *hover-reveal effect* and wrong for a
canonical asset. `filter: invert(1)` is **never** a knockout — it inverts hue
too, so a blue mark comes back orange.

**Logo walls: constrain both axes.** `width: 120px` on everything makes a wide
wordmark occupy ~3x the visual area of a square badge. Use `max-width` **and**
`max-height` in a fixed box, then correct optically by eye.

**Favicons are a different mark**, not your logo scaled down — four files
(`favicon.ico`, `icon.svg`, `apple-touch-icon.png` 180x180, and a *separate*
512x512 maskable PNG whose content sits inside the centre 80%-diameter circle).

Variant production, light/dark pairs, logo-wall sizing and logo `alt` conventions
→ [`references/brand-variants.md`](references/brand-variants.md). The favicon set,
the theme-aware SVG favicon, and maskable safe zones →
[`references/favicons-and-app-icons.md`](references/favicons-and-app-icons.md).

## What this skill doesn't cover

- **Duotone/tri-tone treatments, filter-based tinting of a whole set, and
  raster→vector tracing** → `svg-brand-tint-ops`. This skill produces flat
  variants (mono, grey, knockout) of a single mark; that one does tonal
  re-mapping and vectorising.
- **Choosing the palette itself** → `color-ops`
- **Illustration and generative artwork** → `genart-ops`, `isometric-ops`
- **Authoring new icons** — this skill sources, vets and ships existing ones

## Cross-references

| When | Use |
|---|---|
| The icons are right but the palette isn't | `color-ops` |
| A whole set needs brand recolouring or a logo needs vectorising | `svg-brand-tint-ops` |
| Building the surrounding component styles | `tailwind-ops` |

## References

- [`references/icon-sources.md`](references/icon-sources.md) — the set comparison
  table (licence, grid, family, notes) for the eleven sets worth knowing; the
  trademark-vs-file-licence distinction for brand marks; the aggregator licence
  trap; MCP/plugin sourcing discipline; what each licence class actually
  requires by way of attribution; and **brand marks** — Simple Icons vs theSVG
  vs Brandfetch compared on shape, coverage, colour and offline behaviour, plus
  Brandfetch's key setup, its two very different free tiers, hotlink/expiry
  constraints, and both MCP servers. Load when choosing a set, sourcing a
  company logo, or before shipping any brand mark.

- [`references/inline-delivery.md`](references/inline-delivery.md) — delivery
  mechanism comparison and why icon fonts fail; the external-`<use>` CORS trap;
  `em` sizing and optical alignment; `currentColor` theming; the full
  accessibility checklist (both cases, target size, contrast, reduced motion);
  and SVGO ordering. Load when wiring icons into a page or debugging one that
  won't theme.

- [`references/brand-variants.md`](references/brand-variants.md) — producing mono,
  greyscale, knockout and single-ink variants of a mark; why Rec.709 luminance
  beats an RGB average; when a CSS filter is right and when it is a lie; the three
  light/dark approaches and why the internal-media-query one usually breaks;
  logo-wall sizing by area rather than width; and logo `alt` conventions. Load
  when a mark needs a treatment it did not ship with.

- [`references/favicons-and-app-icons.md`](references/favicons-and-app-icons.md) —
  the modern four-file set and the head block that serves it, why `rel="shortcut
  icon"` is meaningless, the theme-aware SVG favicon, Android maskable safe zones,
  and designing a mark down to 16px. Load for favicons, PWA icons or app icons.

## Scripts

- `scripts/normalize-icon.py` — normalize a vendor SVG for inline themeable use.
  `--check` for a CI gate, `--stroke` for stroke families, `--symbol --id` for
  sprite assembly, `--json` for a machine-readable diff summary. Idempotent:
  re-running on a normalized file reports clean.

## Assets

- `assets/sprite-template.svg` — commented `<symbol>` sprite scaffold to copy
  into a project, carrying the Safari-safe hiding pattern, per-symbol `viewBox`,
  `currentColor` defaults, and both filled and stroke examples.
