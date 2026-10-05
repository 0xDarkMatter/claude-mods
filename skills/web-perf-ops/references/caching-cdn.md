# Caching and CDN headers: TTFB, repeat views, bfcache

Caching moves two numbers: **TTFB** (HTML served from a cache near the user instead of
rendered by PHP) and **repeat-view load** (assets that never re-download). Header
semantics are stable. Browser support comes from MDN BCD, checked 2026-10-05. Server and CDN
configuration depth lives in `nginx-ops` and `cloudflare-ops`; this file is the
performance policy.

## Contents

- [The policy in one table](#the-policy-in-one-table)
- [Cache-Control directives that matter](#cache-control-directives-that-matter)
- [HTML at the edge](#html-at-the-edge)
- [Why the CDN isn't caching (checklist)](#why-the-cdn-isnt-caching-checklist)
- [Compression and protocol](#compression-and-protocol)
- [103 Early Hints](#103-early-hints)
- [bfcache: the free instant navigation](#bfcache-the-free-instant-navigation)
- [Gotchas](#gotchas)

## The policy in one table

| Resource | `Cache-Control` | Why |
|---|---|---|
| Hashed build assets (`app-3f9a2c.js`, `app-8b1d.css`, fonts) | `public, max-age=31536000, immutable` | The URL changes when the content changes, so it can be cached forever. `immutable` stops revalidation in Firefox and Safari; Chrome doesn't implement it (harmless to send) |
| Images from CMS transforms (stable URL per transform) | `public, max-age=2592000` or longer + `ETag` | Transforms rarely change; when one does, the filename usually changes too |
| HTML, logged-out | `public, max-age=0, s-maxage=<long>` (+ purge on publish), or a short `s-maxage` + `stale-while-revalidate` | Browsers revalidate; the CDN keeps a copy. Blitz's default header is exactly `public, s-maxage=31536000, max-age=0` |
| HTML, logged-in or personalised | `private, no-cache` | Never in a shared cache |
| Truly sensitive responses | `no-store` | Not cacheable anywhere. It can also cost bfcache eligibility - use it deliberately, not as the default |
| Unhashed files you must update in place (`/favicon.ico`, legacy `/js/site.js`) | `public, max-age=3600` + `ETag` | Short-lived; better: start hashing them |

## Cache-Control directives that matter

| Directive | Applies to | Meaning |
|---|---|---|
| `max-age=N` | Browser and shared caches | Fresh for N seconds |
| `s-maxage=N` | Shared caches (CDN, proxies) only | Overrides `max-age` for the CDN; lets HTML live long at the edge and short in browsers |
| `no-cache` | All | May store, **must revalidate** before use (ETag/Last-Modified makes that a cheap 304) |
| `no-store` | All | Don't store at all |
| `private` | Browser only | Shared caches must not store |
| `immutable` | Browsers | Don't revalidate while fresh, even on reload. Firefox 49+, Safari 11+; not Chrome |
| `stale-while-revalidate=N` | Browsers (Chrome 75, Firefox 68, Safari 14) and CDNs (e.g. Cloudflare revalidates in the background) | Serve stale for up to N seconds while fetching a fresh copy: TTFB of a hit with the freshness of a miss |
| `stale-if-error=N` | Mostly CDNs | Serve stale if the origin errors |

## HTML at the edge

Caching HTML at a CDN gives the biggest TTFB win available, because the response comes
from a data centre near the user instead of from PHP at the origin.

1. **Make the origin response cacheable**: `s-maxage`, no `Set-Cookie`, no `Vary: Cookie`
   on logged-out pages.
2. **Purge on publish**: a CMS integration purges changed URLs (Blitz's Cloudflare purger;
   CDN APIs). Without purging you are choosing between stale content and short TTLs.
3. **Bypass for sessions**: a cache rule that skips the cache when the session cookie is
   present, so editors and logged-in users get fresh, personalised HTML.
4. **Static cache at the origin too** (Blitz): a CDN miss then costs a file read, not a
   full PHP render.

## Why the CDN isn't caching (checklist)

| Check | How |
|---|---|
| Is it a hit? | Response headers: `cf-cache-status: HIT` (Cloudflare), `x-cache: HIT` (most others), `age:` > 0 |
| `Set-Cookie` on the HTML response | Most CDNs won't cache a response that sets a cookie. Common sources: a session started on every page view, a CSRF token rendered into cached templates, A/B or consent tools setting cookies server-side |
| `Cache-Control: private` / `no-store` / `no-cache` from the app or a plugin | Check the actual header, not the config you think applies |
| CDN default doesn't cache HTML | Cloudflare, for example, caches only static file extensions by default; HTML needs an explicit Cache Rule |
| Query strings fragment the cache | `?utm_source=...` creates a new cache key per campaign; strip or ignore marketing params in the cache key (and in Blitz - see [craft.md](craft.md)) |
| `Vary` on `User-Agent` or `Cookie` | Thousands of variants, near-zero hit rate. `Vary: Accept-Encoding` is fine; `Vary: Accept` only for image negotiation |
| Redirect chains before the cached page | Each hop is a full round trip; cache or remove them |

## Compression and protocol

| Lever | Detail |
|---|---|
| Brotli for text (HTML, CSS, JS, SVG, JSON) | Universal browser support; smaller than gzip. Pre-compress build assets at max level (`.br` files) and serve them statically; on-the-fly compression uses a lower level |
| zstd | Chrome 123, Firefox 126, Safari 26.3. CDNs negotiate it automatically where enabled; no need to pre-build it |
| Don't compress images/fonts again | JPEG/WebP/AVIF/WOFF2 are already compressed |
| HTTP/2 or HTTP/3 | Multiplexing removes the reason for domain sharding and sprite sheets. Lighthouse 13's `modern-http-insight` flags HTTP/1.1. Most CDNs give you HTTP/3 with a toggle |
| Fewer origins | Each new origin costs DNS + TCP + TLS. Self-host fonts and first-party scripts; `preconnect` only to origins used in the first seconds (at most 2-3) |

## 103 Early Hints

The server (or CDN) sends a `103` response with `Link:` headers **before** the final
response, so the browser can start connecting and fetching while the server still renders
the HTML. Its value grows with server think-time: it is a TTFB-hiding tool for uncached
pages.

| Browser | Honours |
|---|---|
| Chrome / Edge 103+ | `preconnect` and `preload` |
| Firefox 120+ | `preconnect`; `preload` from 123 |
| Safari 17+ | `preconnect` only |

Top-level navigations only, over HTTP/2 or later. CDNs (Cloudflare among them) can
generate 103s from the `Link` headers of cached responses. Hint only what is certainly
needed: the main stylesheet, the LCP image origin, critical fonts.

## bfcache: the free instant navigation

The back/forward cache keeps a whole page in memory, so Back and Forward restore it
instantly, with LCP and CLS essentially zero for that view. Make pages eligible:

| Blocker | Fix |
|---|---|
| `unload` event handlers (yours or a third party's) | Use `pagehide` / `visibilitychange` instead; find third-party ones in DevTools |
| `Cache-Control: no-store` on the HTML | Historically always blocked bfcache. Chrome has rolled out partial support, but pages are still evicted when cookies change, and other browsers differ. Don't send `no-store` on pages that don't need it |
| Open connections at navigation time (WebSocket, WebRTC, in-flight `no-store` fetch) | Close them on `pagehide`; reopen on `pageshow` with `event.persisted` |
| `window.opener` references | `rel="noopener"` on cross-window links |

Test: DevTools -> Application -> Back/forward cache -> "Test back/forward cache" names
each blocker. Lighthouse has a `bf-cache` audit.

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Long `max-age` on unhashed `site.css` | Users keep the old file after a deploy; the layout breaks | Hash filenames (Vite/Mix `version()`), then cache forever |
| CDN caches HTML, but the CSRF token is baked in | Every visitor gets the same token; forms fail | Inject tokens dynamically (Blitz `csrfInput()`, Formie `refreshForCache`) |
| "We purge the whole CDN on every deploy" | Every page is a cold miss afterwards | Hashed assets never need purging; purge HTML only, then warm it |
| HTML cached at the edge but TTFB still poor in CrUX | Many users hit uncached variants (query strings, cookies) or distant PoPs with low hit rates | Check hit ratio by URL pattern; normalise cache keys |
| `Cache-Control` set in two places (app and server config) | The last writer wins, or both headers are sent | Decide on one owner per resource type and verify with `curl -sI` |
