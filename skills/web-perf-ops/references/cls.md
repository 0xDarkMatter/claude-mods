# CLS: Cumulative Layout Shift

CLS measures **unexpected** movement of visible content. Good is <= 0.1, poor is > 0.25,
at the 75th percentile of page views (see the threshold table in `SKILL.md`).

## Contents

- [How the score is built](#how-the-score-is-built)
- [Diagnose: find the element and the cause](#diagnose-find-the-element-and-the-cause)
- [Fix catalog](#fix-catalog)
- [Why field CLS is worse than lab CLS](#why-field-cls-is-worse-than-lab-cls)
- [Gotchas](#gotchas)

## How the score is built

| Concept | Rule |
|---|---|
| Layout shift score | impact fraction (viewport area touched) x distance fraction (how far it moved) |
| Session window | Shifts less than 1 s apart group into one window; a window lasts at most 5 s |
| Page CLS | The **largest** session window over the page's whole life, not the sum of all shifts |
| Expected shifts | Shifts within 500 ms of a discrete user input (tap, click, key) are excluded (`hadRecentInput`) |
| Not inputs | Scrolling and hover are not inputs: content that moves on scroll **does** count |
| Animations | `transform` animations do not shift layout; animating `top`/`height`/`margin` does |

Because CLS covers the page's whole life, a shift caused by a lazy-loaded ad three
screens down, or a "load more" that reflows the footer, counts as much as a shift at load.

## Diagnose: find the element and the cause

1. **Field first.** CrUX p75 says whether real users see it. A RUM beacon with the
   `web-vitals/attribution` build (`onCLS`) reports `largestShiftTarget` (a CSS selector)
   and `largestShiftTime` - the element and the moment, from real sessions.
2. **Lab reproduction.** DevTools Performance panel: record a load **and scroll**,
   then read the Layout shifts track; the CLS culprits insight names root causes
   (unsized images, web fonts, injected iframes). `cloudflare:web-perf` drives the same
   trace through chrome-devtools-mcp.
3. **Visualise.** DevTools Rendering drawer -> "Layout Shift Regions" flashes every shift.
4. **Reproduce the user's state**: logged-out, consent banner not yet accepted, slow
   network, mobile viewport. Most CLS hides in a state the developer never sees.

## Fix catalog

| Cause | Fix |
|---|---|
| `<img>` / `<video>` without dimensions | Always emit `width` and `height` attributes (the intrinsic size); CSS `height: auto` keeps it responsive. The browser derives `aspect-ratio` from them before the image loads |
| Responsive art direction (`<picture>` sources with different ratios) | Set `width`/`height` on each `<source>` (supported in all modern browsers) |
| CSS background images in hero blocks | Give the container an explicit `aspect-ratio` or min-height |
| Embeds (YouTube, maps, social posts), iframes | Reserve a box with `aspect-ratio`; better, render a static facade and load the embed on click |
| Ads and promo slots | Reserve the slot's most likely size; never collapse an empty slot after it rendered |
| Cookie / consent banner pushing content down | Overlay it (`position: fixed`), do not insert it above content in normal flow |
| Content injected above existing content (alerts, "related" rows, A/B variants) | Insert below the viewport, reserve space, or show it in response to an input (then the 500 ms exclusion applies) |
| Web font swap changing text metrics | Metric-matched fallback (`size-adjust`, `ascent-override`, `descent-override`) or `font-display: optional` - see [fonts.md](fonts.md) |
| Late CSS (stylesheet arrives after first paint) | Critical CSS that actually matches the final layout - see [css.md](css.md) |
| Lazy-loaded images in a grid without boxes | Dimensions or `aspect-ratio` on every lazy image, not only the hero |
| Animation of layout properties | Animate `transform`/`opacity` instead |
| `content-visibility: auto` without a size | Add `contain-intrinsic-size: auto <height>` so offscreen sections keep a stable placeholder height |
| Skeleton screens the wrong size | Skeleton must match the final element's box, or it shifts twice |
| SPA route change that reflows before data arrives | Keep the previous layout until the new one can render at full size |

## Why field CLS is worse than lab CLS

| Field reality | Lab blind spot |
|---|---|
| Users scroll, so below-the-fold lazy content shifts | A Lighthouse navigation stops after load; it never scrolls |
| Consent banners, logged-in toolbars, personalisation | Lab runs as a fresh, logged-out, often banner-dismissed session |
| Slow 3G/4G stretches the gap between HTML and late resources | One throttling profile |
| Back/forward cache restores report a fresh, usually zero CLS | Lab never navigates back |
| Ads fill at varying sizes | Ads often blocked or stubbed in lab |

So a lab CLS of 0 proves little. Reproduce with DevTools while scrolling, or use a
Lighthouse **timespan** run that covers the interaction you suspect.

**bfcache helps CLS and LCP**: a page restored from the back/forward cache renders
instantly with no shifts. Pages that are not bfcache-eligible (an `unload` handler,
an open connection, some `Cache-Control: no-store` responses) lose that. The DevTools
Application panel -> Back/forward cache test names the blockers - see
[caching-cdn.md](caching-cdn.md).

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| "We set `width:100%` so the image is sized" | Width without height gives no aspect ratio | Emit both `width` and `height` attributes |
| Fixing the hero but CLS is still poor | The largest session window is somewhere else (often a footer or a lazy grid) | Read `largestShiftTarget` from RUM, do not guess |
| CLS regresses only for logged-in editors | Admin toolbar or preview banner injected in flow | Overlay it, or accept it and segment it out of RUM |
| CLS spikes after a design change, lab is clean | Critical CSS stale against the new layout | Regenerate critical CSS on every build |
| Carousel auto-advance shifting the page | Slides of different heights | Fix the carousel height; animate with `transform` |
