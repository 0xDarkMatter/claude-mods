# Fonts: preload, font-display, subsetting, fallback metrics

Web fonts hit three metrics. They delay **FCP/LCP** when text waits for the font, they
cause **CLS** when the fallback and web font have different metrics and the text
reflows on swap, and they compete for bandwidth with the LCP image. Compat data: MDN
BCD, checked 2026-10-05.

## Contents

- [Decision table](#decision-table)
- [font-display](#font-display)
- [Delivery: self-host, WOFF2, preload](#delivery-self-host-woff2-preload)
- [Subsetting](#subsetting)
- [Metric-matched fallbacks (the CLS fix)](#metric-matched-fallbacks-the-cls-fix)
- [Gotchas](#gotchas)

## Decision table

| Situation | Do |
|---|---|
| Body text, performance first | `font-display: optional` + preload. No swap means no font CLS; first-time visitors on slow connections may see the fallback for that page view |
| Brand-critical headings that must use the web font | `font-display: swap` + preload + a metric-matched fallback (`size-adjust`) |
| Fonts served from Google Fonts / Adobe Fonts | Self-host them (see below), or at minimum `preconnect` to both the CSS and font origins |
| 6+ font files on a page | Cut weights/styles; switch to one variable font; subset |
| Icon font for a handful of icons | Replace with inline SVG |

## font-display

| Value | Block period (invisible text) | Swap period | Typical effect |
|---|---|---|---|
| `block` | ~3 s | infinite | Invisible text: delays FCP/LCP. Avoid for text |
| `swap` | ~0 (very short) | infinite | Text paints immediately in the fallback, then reflows (CLS risk) |
| `fallback` | ~100 ms | ~3 s | Compromise: swaps only if the font arrives quickly |
| `optional` | ~100 ms | none | Uses the font only if it is ready almost immediately; otherwise keeps the fallback for this page view. No layout shift |
| `auto` | browser decides | | Usually behaves like `block` |

web.dev's guidance: prefer `optional` when performance comes first. Use `swap` only when
the font is delivered early (preloaded, same origin) **and** paired with `size-adjust`
to limit the shift. Lighthouse 13 reports font-display problems in
`font-display-insight`.

## Delivery: self-host, WOFF2, preload

```html
<!-- Preload only the 1-2 files used above the fold. crossorigin is REQUIRED, even
     same-origin: fonts are fetched in CORS mode, and a preload without it is wasted
     and the font is downloaded twice. -->
<link rel="preload" href="/fonts/inter-var-latin.woff2" as="font" type="font/woff2" crossorigin>

<style>
  @font-face {
    font-family: "Inter";
    src: url("/fonts/inter-var-latin.woff2") format("woff2");
    font-weight: 100 900;          /* one variable file instead of 4-6 static weights */
    font-display: swap;
    unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA,
                   U+02DC, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193,
                   U+2212, U+2215, U+FEFF, U+FFFD;
  }
</style>
```

| Rule | Why |
|---|---|
| **Self-host** | Browsers partition the HTTP cache per site, so a third-party font CDN gives no cross-site cache benefit. It costs extra connections (Google Fonts = CSS origin + font origin, discovered serially) |
| **WOFF2 only** | Universal support and the best compression. Drop WOFF/TTF/EOT fallbacks |
| Put `@font-face` inline in `<head>` (or in critical CSS) | The font request starts as soon as the text that needs it is styled, not after an external stylesheet loads |
| Preload sparingly | Each preload competes with the LCP image; preloading a font that is not used on the page is pure waste (Chrome warns in the console) |
| Long cache lifetime with hashed filenames | Fonts rarely change; see [caching-cdn.md](caching-cdn.md) |

## Subsetting

Ship only the glyphs the site uses.

| Tool | Use |
|---|---|
| `unicode-range` split files (Latin, Latin-ext, Cyrillic) | The browser downloads a file only when the page contains those characters |
| `pyftsubset` (fonttools 4.66) | Precise subsets: `pyftsubset Inter.ttf --unicodes="U+0000-00FF,U+2000-206F" --flavor=woff2 --layout-features='kern,liga'` |
| `glyphhanger` (v6) | Crawl the built site, find the characters actually used, emit the subset |
| `subfont` (v7) | Build step that subsets + inlines `@font-face` per page |

Keep the layout features you use (`kern`, `liga`, tabular numbers). Subsets that drop
them change rendering. For **CMS content**, editors can type characters your crawl never
saw, so subset to a script range (Latin-1 + punctuation), not to the exact glyph list.

## Metric-matched fallbacks (the CLS fix)

When the fallback font (the platform's system sans) has different widths and vertical
metrics from the web font, text reflows on swap. Override the fallback's metrics so it
occupies the same space:

```css
/* Tuned against Roboto: Android is the bulk of most mobile CrUX populations, and
   mobile is where Core Web Vitals usually fail. Generate one face per platform font. */
@font-face {
  font-family: "Inter Fallback";
  src: local("Roboto");
  size-adjust: 107%;        /* Chrome 92, Firefox 92, Safari 17: safe everywhere   */
  ascent-override: 90%;     /* Chrome 87, Firefox 89, Safari: NOT shipped (preview  */
  descent-override: 22%;    /*   only, 2026-10) - Safari ignores these lines, so    */
  line-gap-override: 0%;    /*   vertical match there relies on size-adjust alone   */
}
body { font-family: "Inter", "Inter Fallback", system-ui, sans-serif; }
```

Compute the numbers rather than guessing:

| Tool | What it does |
|---|---|
| `fontaine` (v1) | Build plugin (Vite/webpack/Nuxt) that generates the fallback `@font-face` with overrides automatically |
| `@capsizecss/core` (v4) | Exposes font metrics; compute overrides yourself |
| Framework font loaders (Next.js `next/font`) | Do this automatically for their users |

The font named in `src: local()` must exist on the visitor's platform, and overrides
tuned for one font are wrong for another. Use one fallback face per platform font
(Roboto on Android, Segoe UI on Windows), which `fontaine` generates for you, rather than
one hand-tuned face. A bare `sans-serif` fallback resolves to a different font on each
platform, so name a concrete family before it.

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Preload with no `crossorigin` | Credentials mode mismatch: the preload is discarded and the font fetched again | Always add `crossorigin` |
| Preloading every weight | Bandwidth taken from the LCP image | Preload 1-2 files; let the rest load on demand |
| `font-display: swap` added but CLS got worse | The swap now happens visibly, with mismatched metrics | Add a metric-matched fallback, or use `optional` |
| Font CSS from a third party with `@import` | Serial: page CSS, then font CSS, then the font | Self-host; inline the `@font-face` |
| Variable font bigger than the two static weights you used | Variable files carry the whole axis | Compare bytes; subset the axis range, or keep two statics |
| FOIT in old Safari despite `swap` | Very old Safari ignored `font-display` | Not a concern on supported browsers today; don't add JS font loaders for it |
