# CSS: render-blocking, critical CSS, unused CSS

CSS is the most common cause of a slow **FCP** and of LCP **element render delay**:
the browser will not paint until every stylesheet in `<head>` has downloaded and parsed.

## Contents

- [Why CSS blocks the first paint](#why-css-blocks-the-first-paint)
- [Diagnose](#diagnose)
- [Fix 1: inline critical CSS, defer the rest](#fix-1-inline-critical-css-defer-the-rest)
- [Fix 2: stop shipping unused CSS](#fix-2-stop-shipping-unused-css)
- [Fix 3: remove request chains](#fix-3-remove-request-chains)
- [Rendering cost (after first paint)](#rendering-cost-after-first-paint)
- [Gotchas](#gotchas)

## Why CSS blocks the first paint

| Fact | Consequence |
|---|---|
| A `<link rel="stylesheet">` in `<head>` is render-blocking by default | First paint waits for its download + parse, however small the page |
| A stylesheet with a non-matching `media` (e.g. `print`) is fetched at low priority and does **not** block | `media` is a free, safe lever |
| A classic `<script>` after a stylesheet waits for that stylesheet (the script may read styles) | Slow CSS also delays the JavaScript behind it |
| `@import` inside CSS is discovered only after the parent file parses | Every `@import` adds a serial round trip |
| The first server round trip carries roughly 14 KB of compressed data (TCP initial congestion window) | Critical CSS small enough to ride with the HTML costs no extra round trip |

## Diagnose

| Signal | Where | Meaning |
|---|---|---|
| Large gap between TTFB and FCP | Lighthouse metrics, WebPageTest filmstrip | Render-blocking resources (CSS, sync JS, fonts) |
| Render-blocking insight lists stylesheets with estimated savings | Lighthouse 13 / DevTools Performance panel | Those files block FCP; savings are an upper bound |
| LCP is a text node and render delay dominates | LCP subparts (see [lcp.md](lcp.md)) | The resource is there; CSS (or a font) holds the paint |
| Coverage tab shows most of a stylesheet unused on load | DevTools -> More tools -> Coverage | Candidate for splitting or purging |

Only act on items with non-zero estimated savings. A render-blocking file that downloads in
20 ms on a warm connection is not your problem.

## Fix 1: inline critical CSS, defer the rest

**Critical CSS** is the minimum CSS needed to render the above-the-fold viewport. Inline
it in `<head>`, then load the full stylesheet without blocking render.

```html
<head>
  <style>/* critical CSS: generated, not hand-written */</style>

  <!-- Full stylesheet, non-blocking. The media swap is the most robust pattern. -->
  <link rel="stylesheet" href="/dist/app.4f9a2c.css" media="print" onload="this.media='all'">
  <noscript><link rel="stylesheet" href="/dist/app.4f9a2c.css"></noscript>
</head>
```

| Generator | Use when | Notes |
|---|---|---|
| `critical` (npm, v9) | Build step that renders real pages in headless Chrome | Per-template output; the engine behind `rollup-plugin-critical` |
| `rollup-plugin-critical` | Vite / Rollup builds | What craft-vite's critical-CSS workflow uses - see [craft.md](craft.md) |
| `beasties` | SSR / static output, no headless browser | The maintained fork of Google's `critters`, which stopped releasing in Oct 2024 |

Rules that keep critical CSS honest:

- **Generate per template type** (home, listing, article), not one blob for the site. A
  generic blob either misses styles (flash of unstyled content, CLS) or inlines too much.
- **Generate at mobile viewport first**; it is the CrUX population that usually fails.
- **Regenerate on every build.** Stale critical CSS is worse than none: it renders a
  layout that then shifts when the real stylesheet lands (a CLS regression).
- **Budget it**: keep inlined CSS well under ~14 KB compressed. Beyond that it delays the
  HTML it rides in.
- Inlined CSS is not cached across pages. On a site where users view many pages per
  visit, weigh that against the first-view win (or inline only on landing templates).

## Fix 2: stop shipping unused CSS

| Stack | Lever |
|---|---|
| Tailwind v3 | Every template path must be in `content` (Twig: `./templates/**/*.twig`); missing paths ship nothing, extra globs ship bloat |
| Tailwind v4 | Automatic source detection; add `@source` for templates outside the project root (e.g. Craft `templates/` beside a `src/` build root) |
| Laravel Mix / webpack, hand-written CSS | PurgeCSS (`purgecss` v8) in the build, with a safelist for classes added at runtime (Vue transitions, JS-toggled states, CMS-authored classes) |
| Component CSS (Vue SFC) | Already split per component when code-split; check that async components carry their CSS with them |
| Third-party CSS (sliders, consent banners) | Load it with the widget, not globally on every page |

Purging is a **correctness risk**: classes built by string concatenation in Twig or JS
(`'bg-' ~ colour`) are invisible to the scanner. Safelist them, or write the full class
names out.

## Fix 3: remove request chains

- Replace CSS `@import` with build-time bundling (Vite, PostCSS `postcss-import`).
- Self-host font CSS instead of a third-party CSS file that then requests fonts from a
  second origin (two serial connections) - see [fonts.md](fonts.md).
- Split print or rarely-used CSS behind a `media` attribute instead of bundling it.
- Preload is a last resort for CSS discovered late (e.g. injected by JS); fixing the
  discovery is better than papering over it with `<link rel="preload" as="style">`.

## Rendering cost (after first paint)

CSS also drives **INP** presentation delay and **CLS**:

| Pattern | Effect | Fix |
|---|---|---|
| Animating `top`/`left`/`width`/`height`/`margin` | Layout every frame; counts as a layout shift if not user-initiated | Animate `transform` and `opacity` only |
| Huge DOM restyled on every interaction | Long presentation delay (INP) | Reduce DOM size; scope class toggles to small subtrees |
| `content-visibility: auto` on long below-the-fold sections | Skips rendering offscreen work - big render savings | Always pair with `contain-intrinsic-size` or the scrollbar jumps (CLS) |
| `will-change` on many elements | Memory and compositing cost | Apply it just before an animation, remove after |
| Web fonts swapping metrics | CLS on text | Metric-matched fallback fonts - see [fonts.md](fonts.md) |

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Critical CSS generated against the dev server | Dev CSS is unminified and unpurged | Generate against the production build |
| `onload` swap without `<noscript>` | No-JS users and some crawlers get no styles | Always ship the `<noscript>` fallback |
| `preload` + `onload` pattern without the media swap fallback | Some loaders apply the stylesheet twice | Prefer the `media="print"` swap shown above |
| Purge removed a class used only in CMS-authored rich text | Content editors pick classes the scanner never saw | Safelist the rich-text class vocabulary |
| Inlining critical CSS on a Blitz/static-cached page, then changing the build | The cached HTML still inlines the old critical CSS | Clear the static cache on deploy (see [craft.md](craft.md)) |
