# Craft CMS: performance levers mapped to each metric

The Craft-specific half of web-perf-ops: which Craft feature or plugin moves which metric,
and the traps that silently undo them. Content modelling, Twig conventions and element
queries in general live in the `craftcms-ops` skill, whose `references/performance.md`
covers the Craft-side mechanics (queue, transforms, caching layers). This file maps
those levers to Core Web Vitals and does not repeat them.

## Contents

- [Lever map](#lever-map)
- [What exists on which Craft version](#what-exists-on-which-craft-version)
- [Blitz: TTFB](#blitz-ttfb)
- [{% cache %}: when there is no Blitz](#-cache--when-there-is-no-blitz)
- [Eager loading: TTFB on a cache miss](#eager-loading-ttfb-on-a-cache-miss)
- [Image transforms: LCP and CLS](#image-transforms-lcp-and-cls)
- [craft-vite: render delay, CLS, INP](#craft-vite-render-delay-cls-inp)
- [SEOmatic and Formie: script loading](#seomatic-and-formie-script-loading)
- [The queue](#the-queue)
- [Deploy checklist](#deploy-checklist)

Versions and defaults were checked against Craft and plugin source and changelogs on
2026-10-05: Craft 5.11 / 4.18, Blitz 5.13 / 4.23, craft-vite 5.0 / 4.0, SEOmatic 5.1 / 4.1,
ImageOptimize 5.0 / 4.0, Imager X 6.1 / 4.5, Formie 3.1 / 2.2.

<!-- TODO(web-perf): when craftcms-ops' performance reference has landed (lane/craft-refresh),
     turn the craftcms-ops mention in the intro into a link:
     ../../craftcms-ops/references/performance.md (useful anchors: #queue,
     #images-transforms-srcset-avif, #caching-layers--cache--versus-blitz). It is plain
     text until then because doc-drift fails on links to files that are not on disk. -->

## Lever map

| Metric / subpart | Craft lever | Trap that undoes it |
|---|---|---|
| **TTFB** (LCP subpart 1) | Blitz static cache served by server rewrites | Pages with ungenerated transform URLs are never cached; query-string variants (`utm_*`) bypass the cache |
| TTFB on a cache miss | `.with()` / `.eagerly()` eager loading; `{% cache %}` where Blitz is absent | `{% cache %}` *with* Blitz; a cold cache after every deploy |
| **LCP load delay** | Hero image markup that is eager + `fetchpriority="high"` (native `getImg`, ImageOptimize `imgTag()`, Imager X) | A shared image macro or ImageOptimize `loadingStrategy('lazy')` applied to the hero |
| LCP load duration | WebP/AVIF transforms with real `srcset`/`sizes`; CDN transformers (Imager X) | Serving the original upload; AVIF without ImageMagick support |
| LCP render delay / FCP | craft-vite critical CSS + `modulepreload`; SEOmatic script positions | craft-vite's async CSS with no critical CSS (FOUC) |
| **INP** | Fewer and later tracking scripts (SEOmatic positions and per-template disable); Formie JS only where a form renders; Vue islands | GTM tags firing at page view; queue snippet requests on busy pages |
| **CLS** | `getImg()` width/height; placeholder sizes for Blitz dynamic includes; critical CSS that matches the layout | craft-vite async CSS (FOUC then reflow); dynamic-include placeholders of the wrong size |

## What exists on which Craft version

| Feature | Craft 3 | Craft 4 | Craft 5 |
|---|---|---|---|
| `.with([...])` eager loading | yes | yes | yes |
| `.eagerly()` (lazy eager loading) | no | no | **5.0.0+** |
| `asset.getSrcset()` / `getImg($transform, $sizes)` | 3.5.0+ | yes | yes |
| `{% cache %}` captures inline `{% js %}`/`{% css %}` | 3.7.0+ | external files 4.0.0+, `{% html %}` 4.3.0+ | asset bundles 5.3.0+, import maps 5.6.0+ |
| AVIF as a transform `format` | 3.7.26+ (if ImageMagick supports it) | yes | yes |
| Blitz | 3.x | 4.x (has Hints) | 5.x (**Hints retired in 5.10.0**) |
| craft-vite | 1.0.x | 4.0.x | 5.0.x |
| ImageOptimize `imgTag()` / `pictureTag()` | no | 4.0.6+ | 5.0.0+ |
| Imager X | - | 4.x | 5.x / 6.x |

## Blitz: TTFB

Blitz writes rendered pages to static files (`@webroot/cache/blitz` by default) and serves
them without booting Craft. It is the largest single TTFB lever on a Craft site.

| Setting / practice | Do |
|---|---|
| Serving | Use **server rewrites** (Nginx/Apache/Caddy rules from the Blitz docs) so cached pages never touch PHP. Next best is the PHP rewrite (`require .../craft-blitz/src/rewrite.php` in `web/index.php`). Serving "through Craft" still boots PHP. Use Yii cache storage (Redis) on multi-node or ephemeral hosts |
| Warming | `php craft blitz/cache/generate` after deploys and imports; the HTTP generator (default concurrency 3) crawls the site |
| `refreshMode` | `REFRESH_MODE_EXPIRE_AND_GENERATE` serves the stale page while regenerating (stale-while-revalidate). The default clear-and-generate gives the next visitor a cache miss |
| Query strings | Default `QUERY_STRINGS_DO_NOT_CACHE_URLS` means every `?utm_source=` visit is uncached. Add `utm_.*` to `excludedQueryStringParams` (default excludes only `gclid`, `fbclid`) |
| CDN in front | `CloudflarePurger` with a Cache Rule: eligible for cache, Edge TTL "use cache-control header if present", Browser TTL "respect origin". Don't combine server rewrites with a reverse proxy |
| Headers | Default `cacheControlHeader` is `public, s-maxage=31536000, max-age=0`: shared caches keep it, browsers revalidate. That fits HTML. Uncached pages get `no-store` (which can cost bfcache eligibility - see [caching-cdn.md](caching-cdn.md)) |
| Compression | `compressCachedValues` writes gzip only (no Brotli); behind a CDN that compresses, leave it off |

**Pages Blitz will not cache:** pages showing the debug toolbar, Live Preview, and pages
whose HTML contains **ungenerated image-transform URLs** (see transforms below). Look for
the `<!-- Cached by Blitz ... -->` comment (`outputComments`) or the
`X-Powered-By: Blitz` header to confirm a page is served from cache.

**Dynamic bits on cached pages** (cart counts, user names, CSRF tokens):

```twig
{# Rendered by AJAX after load: give the placeholder the final box size, or it shifts (CLS) #}
{{ craft.blitz.includeDynamic('_partials/cart-count', {}, {placeholder: '<span class="cart-count">0</span>'}) }}

{# Cached fragment, injected by SSI/ESI if enabled, else AJAX #}
{{ craft.blitz.includeCached('_partials/footer-latest') }}

{{ craft.blitz.csrfInput() }}
```

Pass primitive params (IDs), not elements. The injection script runs on `DOMContentLoaded`
by default.

## {% cache %}: when there is no Blitz

```twig
{% cache globally using key 'nav' for 1 day unless currentUser %}
  {% include '_partials/nav' %}
{% endcache %}
```

- **Don't combine with Blitz.** Blitz's docs say template caching is redundant with
  full-page caching and interferes with its invalidation; set
  `'enableTemplateCaching' => false` in `config/general.php`.
- The key ignores the query string unless you add it (`request.queryStringWithoutPath`).
- It is disabled for Live Preview and tokenized requests, but **not** for logged-in users:
  add `unless currentUser` where output is personalised.
- Never wrap `csrfInput()` or forms. Variables set inside the tag don't exist after a
  cache hit.
- Cache **after** fixing queries, never instead of fixing them (`craftcms-ops`).

## Eager loading: TTFB on a cache miss

Every uncached request (first view, logged-in users, previews, query-string URLs) pays
for N+1 queries.

```twig
{# Craft 3/4/5: declare relations and transforms up front #}
{% set posts = craft.entries().section('news').with([
  'author',
  ['featureImage', {withTransforms: ['card']}],
]).limit(12).all() %}

{# Craft 5: lazy eager loading - loads the relation for the whole result set on first access #}
{% for post in posts %}
  {% set image = post.featureImage.eagerly().one() %}
{% endfor %}
```

**Blitz Hints is gone** from Blitz 5.10.0 (Craft 5 element-query changes made it
unreliable). The replacement advice is `.eagerly()` on relational fields and `.with()` for
native attributes and transforms. Count queries with the Yii debug toolbar on an
uncached request.

## Image transforms: LCP and CLS

### Native transforms

```twig
{# Hero: eager, high priority. getImg() emits src, srcset, width, height, alt - NOT loading or sizes #}
{{ hero.getImg({width: 1440, format: 'webp'}, ['640w', '960w', '1440w', '1920w'])
    |attr({sizes: '100vw', fetchpriority: 'high'}) }}

{# Cards: lazy #}
{{ card.getImg({width: 720, format: 'webp'}, ['320w', '480w', '720w'])
    |attr({sizes: '(min-width: 64rem) 33vw, 100vw', loading: 'lazy', decoding: 'async'}) }}
```

Make "eager or lazy" an explicit parameter of the project's image macro, so the first
image on a template is never lazy by default.

**The transform-generation trap.** When a transform file does not exist yet, Craft
outputs a temporary `actions/assets/generate-transform` URL (generated on first request),
queues a generation job, and **sends no-cache headers for the whole page**. Blitz then
refuses to cache that page. On a content-heavy site after an import or deploy, that means
uncached HTML and slow first image loads at the same time. Fixes:

- `'generateTransformsBeforePageLoad' => true` in `config/general.php`: transforms are
  generated during the render, so the page is cacheable. The first render is slower;
  warm with `blitz/cache/generate`.
- Pre-generate on upload or save (Imager X Pro's auto-generate; ImageOptimize generates
  its field's variants on save).

Formats: `format: 'avif'` works only when the server's ImageMagick has AVIF support.
AVIF is slow to encode, so pre-generate it rather than generating during a page render
at peak traffic. `defaultImageQuality` is 82.

### ImageOptimize

- Generates its variants when the asset is saved. WebP variants come from the `cwebp`
  variant creator. There is **no AVIF variant creator**.
- Craft 4.0.6+ / 5.0+: `imgTag()` / `pictureTag()` / `linkPreloadTag()` builders emit
  `width`/`height`:

```twig
{{ hero.optimizedImagesField.imgTag().loadingStrategy('eager')
    .imgAttrs({sizes: '100vw', fetchpriority: 'high', alt: hero.title}).render() }}
```

- Use `'eager'` (the default) for the hero and `'lazy'` (native `loading="lazy"`) below
  the fold. Avoid the `'lazySizes'` strategies: they depend on the lazysizes library,
  unreleased since 2021 (see [images.md](images.md)).

### Imager X

- `craft.imagerx.transformImage(image, [{width: 480}, {width: 960}], {format: 'webp'})`
  plus `craft.imagerx.srcset(transforms)`; named transforms in
  `config/imager-x-transforms.php`; `fillTransforms` to fill width gaps.
- Paid **Lite** and **Pro** editions; Pro adds generate-on-save, console generation and
  third-party transformers. Transformers offload resizing to a CDN (Cloudflare Images,
  Bunny, ImageKit; Imgix moved to its own transformer package in Imager X 6), which
  removes the generation trap entirely.
- `craft.imagerx.serverSupportsAvif()` tells you whether AVIF output works on the host.

## craft-vite: render delay, CLS, INP

```twig
{{ craft.vite.includeCriticalCssTags() }}   {# inline critical CSS for this template #}
{{ craft.vite.script('src/js/app.ts') }}    {# module script + modulepreload + CSS links #}
```

| Behaviour | Consequence | Do |
|---|---|---|
| `script()` emits `<link rel="modulepreload">` for imported chunks and the CSS `<link>`s | Good: no request chains | Nothing |
| CSS is **async by default** (`media="print" onload`) | Without critical CSS the page paints unstyled, then reflows: FOUC and CLS | Ship critical CSS, or pass `false` as the second argument: `craft.vite.script('src/js/app.ts', false)` |
| Critical CSS comes from `rollup-plugin-critical`, read from `criticalPath` (`@webroot/dist/criticalcss`) with `criticalSuffix` (`_critical.min.css`) | One file per template | Generate per template type at mobile width; regenerate every build ([css.md](css.md)) |
| `@vitejs/plugin-legacy` is auto-detected | Adds a `nomodule` bundle | Drop the plugin unless analytics show browsers that need it |

Laravel Mix sites have none of this. Hand-roll critical CSS with `critical` or move the
build to Vite (see [javascript.md](javascript.md)).

## SEOmatic and Formie: script loading

**SEOmatic tracking scripts** (GTM, gtag, Meta Pixel, LinkedIn, HubSpot, etc.) are set in
the CP under Tracking Scripts and render only in the `live` environment, so **measure
production or a live-mode staging site**, or the cost is invisible.

| Lever | How |
|---|---|
| Position | Per script in the CP: "Script Render Location" head / body begin / body end. Move non-essential pixels to body end |
| Turn off per template | `{% do seomatic.script.get('facebookPixel').include(false) %}` in templates that don't need it |
| GTM data layer | `{% do seomatic.script.get('googleTagManager').dataLayer({...}) %}` |
| Consent | No built-in Consent Mode setting. The documented pattern rewrites tag attributes for a consent manager: `.tagAttrs({type: 'text/plain', 'data-name': 'gtm'})` |
| async / defer | Scripts inject themselves `async`; there is no defer option. The tags GTM fires are the real cost ([javascript.md](javascript.md)) |

**Formie** registers its CSS/JS only on pages that render a form. Levers per form
template:

| Setting | Effect |
|---|---|
| JavaScript Render Location (`outputJsLocation`): `page-footer` (default), `inside-form`, `manual` | Keep `page-footer`, or `manual` + `{{ craft.formie.renderFormJs(form) }}` where you choose |
| Output CSS / Output Theme | Turn off the theme CSS if the site styles forms itself |
| Captcha "Script Loading Method" (reCAPTCHA, Turnstile, hCaptcha) | `asyncDefer` (default). There is no lazy-load setting; a captcha on every page is a third-party script on every page |
| Forms on Blitz-cached pages | Call `{% do craft.formie.registerAssets(form) %}` outside cached areas, and refresh CSRF tokens with `Formie.refreshForCache(formId)` in an `onFormieInit` listener |

## The queue

`runQueueAutomatically` (default `true`) runs queued jobs over HTTP: when jobs are
waiting, Craft injects a snippet before `</body>` **on front-end pages too**, which fires
a second request to work the queue. On a busy site with transform and Blitz-refresh jobs,
that is extra requests and PHP load on visitor page views.

- Production: set `CRAFT_RUN_QUEUE_AUTOMATICALLY=false` and run a worker:
  `php craft queue/listen --verbose` under systemd or supervisor (`nice -n 10`), or
  `php craft queue/run` from cron.
- Blitz refreshes and transform generation both ride the queue. A stopped worker shows
  up as stale cached pages and missing transforms.

## Deploy checklist

1. `php craft up` (migrations + project config).
2. Rebuild assets; **regenerate critical CSS** for every template type.
3. Refresh Blitz (`php craft blitz/cache/refresh`, or clear + `generate`) so no cached
   HTML references old hashed assets or old critical CSS.
4. Warm the cache before running Lighthouse CI or comparing TTFB.
5. Confirm the queue worker is running and draining.
