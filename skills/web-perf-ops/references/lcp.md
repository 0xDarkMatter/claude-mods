# LCP: Largest Contentful Paint

LCP is the time from navigation start until the largest image or text block in the
viewport is painted. Good is <= 2.5 s, poor is > 4 s at p75. Every LCP decomposes into
four **subparts**. Find the dominant one and fix that, not "LCP" in general.

## Contents

- [The four subparts](#the-four-subparts)
- [Diagnose](#diagnose)
- [Fix by subpart](#fix-by-subpart)
- [The LCP element is text](#the-lcp-element-is-text)
- [Making the next page instant](#making-the-next-page-instant)
- [Gotchas](#gotchas)

## The four subparts

```
navigation ──► TTFB ──► load delay ──► load duration ──► render delay ──► LCP paint
               server    HTML parsed,    image bytes       bytes here,
               + network image not yet   downloading       not painted yet
                         requested
```

| Subpart | What it is | Healthy share (web.dev) |
|---|---|---|
| **TTFB** | Navigation start to first byte of HTML | ~40% |
| **Resource load delay** | First byte to the moment the LCP resource starts downloading | < 10% |
| **Resource load duration** | Download time of the LCP resource | ~40% |
| **Element render delay** | Resource downloaded to the moment it is painted | < 10% |

A text LCP has no resource, so its delay and duration are zero and render delay holds
everything after TTFB. The two **delays** are pure waste and the cheapest to remove.
Look there first.

## Diagnose

| Source | How |
|---|---|
| CrUX (field) | The API returns image-LCP subparts at p75; `triage-vitals.py crux.json` flags the dominant one |
| RUM | `web-vitals/attribution` `onLCP`: `target` (selector), `url`, `timeToFirstByte`, `resourceLoadDelay`, `resourceLoadDuration`, `elementRenderDelay` |
| Lab | Lighthouse `lcp-breakdown-insight` (subparts) and `lcp-discovery-insight` (is the image discoverable in the HTML? `fetchpriority=high`? not lazy?); DevTools Performance panel -> LCP breakdown |

**Check which element is the LCP on mobile.** It is often different from desktop: a
heading instead of the hero, or the cookie-consent banner's text block.

## Fix by subpart

### TTFB is dominant

Server and network time. The HTML must come from a cache, close to the user.

| Cause | Fix |
|---|---|
| Page rendered by PHP/Twig on every request | Full-page static cache (Blitz on Craft - see [craft.md](craft.md)); CDN caching of HTML ([caching-cdn.md](caching-cdn.md)) |
| Redirect chains (`http`->`https`->`www`->trailing slash) | One hop at most; link to the canonical URL |
| Origin far from users | CDN in front; cache HTML at the edge with purge-on-publish |
| Cache miss after every deploy or purge | Warm the cache (Blitz cache generation, a crawler) after deploys |
| Slow DB queries on uncached pages | Eager loading and query fixes - see [craft.md](craft.md) and `perf-ops` for profiling |
| Server think-time you cannot remove | `103 Early Hints` to start preconnects/preloads while the server works (Chrome/Firefox honour preload; Safari honours preconnect only) |

### Resource load delay is dominant

The browser found the LCP resource late, or deprioritised it.

| Cause | Fix |
|---|---|
| `loading="lazy"` (or a `data-src` lazy-loading library) on the hero | **Never lazy-load the LCP image.** Eager-load the first one or two images in a template |
| Image is a CSS `background-image` | Use an `<img>` in the HTML; if it must stay CSS, `<link rel="preload" as="image" fetchpriority="high">` |
| Image injected by JavaScript (slider, Vue component, client-side render) | Render the first slide / hero in the server HTML |
| Image competes with scripts, fonts, other images | `fetchpriority="high"` on the LCP `<img>` (Baseline since Oct 2024) |
| Responsive hero preloaded wrongly | Preload with `imagesrcset` + `imagesizes` matching the `<img>` exactly, or the browser fetches twice |
| A/B-testing or personalisation "anti-flicker" snippet hides the page | Remove it, or cap its timeout hard; it adds its whole duration to render delay |
| Preloading too much | Every preload competes; keep to the LCP image and one or two critical fonts |

### Resource load duration is dominant

The bytes take too long.

| Cause | Fix |
|---|---|
| Image too large for the slot | `srcset` + accurate `sizes`; serve AVIF/WebP - see [images.md](images.md) |
| Image served from the origin, uncached | CDN with long-lived caching of hashed or transform URLs |
| Bandwidth contention | Fewer requests in the critical window; defer third-party tags ([javascript.md](javascript.md)) |
| Cross-origin image host | `preconnect` to it, or move the images to the main origin/CDN |

### Element render delay is dominant

The resource arrived, but something blocked the paint.

| Cause | Fix |
|---|---|
| Render-blocking CSS/JS in `<head>` | Critical CSS, defer scripts - see [css.md](css.md), [javascript.md](javascript.md) |
| Hero fades or slides in with a CSS/JS animation | Elements at `opacity: 0` are not painted; drop the entrance animation on the LCP element |
| Text LCP waiting on a web font | `font-display`, preload, metric-matched fallback - see [fonts.md](fonts.md) |
| Client-side rendering / hydration paints the hero late | Server-render the above-the-fold markup |
| Long tasks on the main thread at load (tag managers, chat widgets) | Defer them until after load or interaction ([javascript.md](javascript.md)) |

## The LCP element is text

Common on article templates and on mobile. The fix list is short: deliver HTML fast
(TTFB), unblock rendering (critical CSS, defer JS), and make sure the font does not hold
the paint (`font-display: swap`/`optional` with a metric-matched fallback). Image work
won't move this LCP at all.

## Making the next page instant

| Technique | Effect | Support (2026-10) |
|---|---|---|
| bfcache eligibility | Back/forward navigations restore instantly (LCP ~0) | All major browsers; blockers include `unload` handlers and some `Cache-Control: no-store` responses |
| Speculation Rules `prerender` | The next page renders before the click | Chromium only; prefetch only (behind a flag) in Safari 26.2; none in Firefox |
| Speculation Rules `prefetch` | HTML fetched early, TTFB ~0 | Same as above |

```html
<script type="speculationrules">
{ "prerender": [{ "where": { "href_matches": "/*" }, "eagerness": "moderate" }] }
</script>
```

`eagerness`: `immediate`, `eager`, `moderate` (hover ~200 ms), `conservative`
(pointer down). Exclude logout, add-to-cart and other state-changing URLs. Prerendered
pages run their JavaScript, so analytics must count a prerender only when it is
activated (most current tag libraries handle this).

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| `loading="lazy"` added site-wide by an image macro or plugin setting | The hero is lazy too | Make "eager + `fetchpriority=high`" an explicit parameter of the image macro for the first image |
| Preloading the hero *and* lazy-loading it | Wasted preload, still late | Pick one: eager `<img fetchpriority=high>` |
| Placeholder (LQIP/blurhash) counted as LCP | The low-quality image is the largest paint, then the real one replaces it | Fine if the placeholder is tiny and the real image loads fast; check the real image's time in RUM |
| LCP fixed in lab but not field | Field users hit a cold CDN/Blitz cache, or a different LCP element | Check field subparts and the `target` selector by device |
| Carousel picks a random first slide | Different LCP image per load, nothing preloadable | Fixed first slide in HTML |
