# Icon Delivery and Accessibility

How an icon reaches the page, and how it behaves for people who cannot see it.

---

## Choose the delivery mechanism first

It determines whether the icon can be themed at all, so it is not a late detail.

| Mechanism | Themeable | Requests | Use when |
|---|---|---|---|
| **Inline `<svg>`** | Yes — full CSS access to every path | 0 | Few icons, or an icon needing per-part styling/animation |
| **`<symbol>` sprite + `<use>`** | Yes — `currentColor` and CSS on the host `<svg>` | 1 | **The default for a real UI.** Many icons, each used repeatedly |
| **Component (JSX/Vue/Svelte)** | Yes | 0 (bundled) | Component framework already in play; tree-shaking removes unused icons |
| **`<img src="icon.svg">`** | **No** — cannot recolour, cannot inherit `color` | 1 each | Never, for UI icons. Acceptable for a fixed logo |
| **CSS `background-image`** | **No** (short of `mask`) | 1 each | Decorative only. `mask-image` recolours but loses multi-tone |
| **Icon font** | Colour only | 1 | Legacy systems. See the warning below |

### Why not an icon font

Icon fonts map glyphs onto private-use codepoints. The failure modes are real
and user-visible: a screen reader may announce the codepoint or nothing at all;
a font-blocking extension or a failed font load leaves an empty box; browser
font-substitution can render an unrelated glyph; and text-only zoom or a reader
mode can displace it entirely. Ligature-based fonts also leak literal text into
copy-paste. SVG has no equivalent failure mode. Migrate rather than extend.

### The external-`<use>` trap

```html
<!-- Silently renders nothing when the sprite is on another origin -->
<svg><use href="/assets/sprite.svg#i-search"/></svg>
```

An external `<use>` reference is subject to CORS and is blocked cross-origin —
including from a CDN — with no console error in some browsers. **Inline the
sprite into the document** (near the top of `<body>`), or bundle icons as
components. If you must reference externally, verify it on the deployed origin,
not on localhost.

## Sizing

Size icons in `em`, not `px`:

```css
.icon { width: 1em; height: 1em; flex: none; }
```

`1em` ties the icon to the adjacent text size, so it stays optically matched to
its label at every step of the type scale and through user font-size settings.
`flex: none` stops a flex parent from squashing it into an ellipse — the single
most common icon layout bug.

For optical alignment with a text baseline, prefer flex centring on the
container over `vertical-align` nudges:

```css
.btn { display: inline-flex; align-items: center; gap: 0.5em; }
```

## Colour

**`fill="currentColor"` is the whole technique.** It makes the icon inherit the
CSS `color` of its context, so hover, focus, disabled, dark mode and theme
switches all work with no icon-specific rules:

```css
.btn        { color: var(--fg); }
.btn:hover  { color: var(--fg-strong); }   /* icon follows automatically */
```

Hardcoding a hex in the SVG breaks every one of those states at once. For stroke
icons the same applies to `stroke="currentColor"`, and `fill` must be `none` or
the glyph floods solid.

Recolouring a whole set to a brand palette (duotone, gradients, filter-based
tinting) is `svg-brand-tint-ops`, not this skill.

## Accessibility — exactly two cases

Every icon is either decorative or meaningful. There is no third option, and
leaving it undecided is the defect.

### Decorative — the icon repeats adjacent text

```html
<button>
  <svg class="icon" aria-hidden="true" focusable="false"><use href="#i-trash"/></svg>
  Delete
</button>
```

`aria-hidden="true"` removes it from the accessibility tree; `focusable="false"`
stops legacy IE/Edge putting the SVG in the tab order. The button already has
its name from the visible text.

### Meaningful — the icon *is* the only label

```html
<button aria-label="Delete item">
  <svg class="icon" aria-hidden="true" focusable="false"><use href="#i-trash"/></svg>
</button>
```

**Name the control, not the icon.** This is the counter-intuitive part: even
here the SVG stays `aria-hidden`, and the accessible name goes on the `<button>`.
A name on the icon and a name on the button produces a double announcement.

Use `role="img"` plus `<title>` only when the SVG is standalone content rather
than the contents of a control:

```html
<svg role="img" aria-labelledby="chart-t" viewBox="0 0 24 24">
  <title id="chart-t">Revenue trending upward</title>
  ...
</svg>
```

### The rest of the checklist

- **Never convey status by icon shape alone** if colour is the differentiator —
  pair a colour change with a distinct shape (✓ vs ✕, not green dot vs red dot).
- **Target size**: the interactive area of an icon-only control should be at
  least 24×24 CSS px (WCAG 2.2 §2.5.8, AA), regardless of how small the glyph is.
  Pad the control, don't grow the icon.
- **Honour `prefers-reduced-motion`** for any animated icon (spinners excepted,
  where the motion carries the meaning).
- **Contrast**: a meaningful icon is subject to the 3:1 non-text contrast
  requirement (WCAG 1.4.11) against its background. Decorative icons are exempt.

## Optimising

`normalize-icon.py` handles the correctness pass — cruft, `currentColor`, sizing,
a11y attributes. For byte-level path optimisation (precision reduction, path
merging), run **SVGO** after normalizing, not before:

```bash
normalize-icon.py raw.svg -o icon.svg && npx svgo --multipass icon.svg
```

Order matters — SVGO's default plugins can inline or restructure attributes in
ways that make the normalizer's paint rebinding harder to apply cleanly.

Keep `viewBox` through every step. Dropping it is the one optimisation that
breaks scaling outright, and some aggressive configs still do it.
