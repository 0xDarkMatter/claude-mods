# Performance (Craft-side Levers)

The Craft-specific levers that move server time and page weight: queries, caching
layers, images, the queue, and asset delivery. This file owns the **levers**, not the
measurement method.

## Contents

- [Triage: which lever?](#triage-which-lever)
- [Queries and eager loading](#queries-and-eager-loading)
- [Caching layers: `{% cache %}` versus Blitz](#caching-layers--cache--versus-blitz)
- [Images: transforms, srcset, AVIF](#images-transforms-srcset-avif)
- [Queue](#queue)
- [Front-end delivery with craft-vite](#front-end-delivery-with-craft-vite)
- [Production config checklist](#production-config-checklist)

<!-- TODO(web-perf): once lane/web-perf lands, turn the mention below into a link:
     ../../web-perf-ops/references/craft.md (agreed with that lane 2026-10-05; it maps
     these same Craft levers to LCP/INP/CLS/TTFB). Owner: the "Build a web-perf skill
     for Core Web Vitals" chip. Not linked yet because the file does not exist on this
     branch and doc-drift rejects ghost links. Keep this file Craft-side - the metric
     method lives there, not here. -->
**Measure first.** The Core Web Vitals method (field vs lab data, LCP/INP/CLS/TTFB
triage, and which of these levers moves which metric) belongs to the `web-perf-ops`
skill (its `references/craft.md`), landing separately. Until it does, use `perf-ops`
for profiling and come back here for the Craft fix.

## Triage: which lever?

| Symptom | Likely cause | Lever |
|---------|-------------|-------|
| Slow TTFB on uncached pages, query count in the hundreds | N+1 relation queries | `.with()` / `.eagerly()` |
| Slow TTFB everywhere, few queries | No page cache; heavy Twig | Blitz; then `{% cache %}` on excluded pages |
| Fast TTFB, slow LCP | Unsized or untransformed hero image; render-blocking CSS | Transforms + `srcset` + preload; critical CSS |
| First visit to new pages slow, then fine | Transforms generated on first request | Pre-generate (ImageOptimize / Imager-X / queue) |
| Changes take minutes to appear; CP feels slow | Queue backed up or not running | Queue daemon |
| CLS on load | Images without dimensions; stale critical CSS | `width`/`height` attrs; regenerate critical CSS |

Read query counts from the debug toolbar (enable per user: My Account → Preferences →
Development) or Blitz Diagnostics. A listing page should be a handful of queries, not
one per card.

## Queries and eager loading

The #1 Craft performance bug is a relation queried inside a loop. Full patterns:
[element-queries.md](element-queries.md#eager-loading-kill-n1). The levers:

| Lever | Craft | Use |
|-------|-------|-----|
| `.with(['field', 'field.nested'])` | 3, 4, 5 | You know the relations up front |
| `.eagerly()` on the relation inside the loop | **5 only** (added 5.0.0) | Shared partials/components that can't know their caller's query |
| `.with([['image', {withTransforms: ['card']}]])` / `.withTransforms([...])` | 3, 4, 5 | Transform URLs without a lookup per image |
| `.with(['author'])` | 3, 4, 5 | Native attributes (`author`, `uploader`) - `.eagerly()` does not cover them |
| `preloadSingles` (general config) | 5 | Lets templates reference Singles by handle without per-template queries |

Craft 5 notes from the [eager-loading docs](https://craftcms.com/docs/5.x/development/eager-loading.html):
eager-loaded values are `ElementCollection`s, so `|first`, loops, and `.all()` behave
like the unloaded query in most templates - you can add eager loading without
rewriting the template. Other query levers: `.ids()` / `.count()` / `.exists()` instead
of `.all()` when you need no elements; index custom fields used in `orderBy` on large
sections (see `sql-ops`).

## Caching layers: `{% cache %}` versus Blitz

| | `{% cache %}` | Blitz |
|--|---------------|-------|
| Unit | A template fragment | A whole URL's HTML |
| Invalidation | Automatic for elements queried inside the block; else time-based | Tracks elements/queries per page; refreshes on save (via queue) |
| Serves without PHP? | No - Craft boots every request | Yes, with server rewrites or a CDN |
| Per-user content | Can't vary per user unless keyed | Needs `includeDynamic()` / `fetchUri()` holes |
| Best for | Expensive fragments on pages that can't be fully cached (search, account) | Everything public |

Rules:

1. **Fix the queries first.** Caching an N+1 hides it until the cache misses - then
   regeneration is slow and Blitz warming hammers the database.
2. On Blitz-cached pages `{% cache %}` is redundant and can serve stale fragments into
   fresh pages - the Blitz docs say remove it or set `enableTemplateCaching => false`
   ([blitz.md](blitz.md#blitz-versus--cache-)).
3. Never wrap SEOmatic calls in `{% cache %}` ([seomatic.md](seomatic.md#performance-pitfalls)).
4. Useful `{% cache %}` forms: `{% cache globally using key 'footer' for 1 day %}`
   (one copy per site, not per URL) and `{% cache unless currentUser %}`. There is no
   "nocache hole" tag in core - keep per-user markup outside the block
   ([tags reference](https://craftcms.com/docs/5.x/reference/twig/tags.html#cache)).

## Images: transforms, srcset, AVIF

**Native Craft 5** ([image transforms](https://craftcms.com/docs/5.x/development/image-transforms.html)):

```twig
{% set img = entry.heroImage|first %}
{% if img %}
  {% do img.setTransform({ width: 1200, height: 630, mode: 'crop', format: 'avif', quality: 70 }) %}
  <img src="{{ img.url }}"
       srcset="{{ img.getSrcset(['480w', '800w', '1200w']) }}"
       sizes="(min-width: 1024px) 50vw, 100vw"
       width="{{ img.width }}" height="{{ img.height }}"
       alt="{{ img.alt }}" fetchpriority="high">
{% endif %}
```

- `format` accepts `jpg`, `png`, `gif`, `webp`, `avif` - WebP/AVIF only when the server's
  ImageMagick supports them. Check before promising AVIF; GD builds often can't.
- With `generateTransformsBeforePageLoad` false (default), an ungenerated transform URL
  points at a generate action and Craft also queues a `GenerateImageTransform` job;
  responses carrying such URLs are sent no-cache. **Blitz refuses to cache any page
  containing transform-generation URLs** - so on a Blitz site with lazy transforms, image-heavy
  pages silently stay uncached. Blitz's documented fix: set
  `generateTransformsBeforePageLoad => true` (cache warming then pays the transform cost
  once), or pre-generate with ImageOptimize/Imager-X.
- Defaults worth knowing: `defaultImageQuality` 82, `upscaleImages` true (turn off
  for hero art), `optimizeImageFilesize` true (Imagick only).
- Always output `width`/`height` (or `aspect-ratio`) - unsized images are a CLS source.
- Lazy-load below-the-fold (`loading="lazy"`); never lazy-load the LCP image - give it
  `fetchpriority="high"` instead.

**ImageOptimize 5** (`nystudio107/craft-imageoptimize`,
[docs](https://nystudio107.com/docs/image-optimize/)): an OptimizedImages field
pre-generates responsive variants **on asset save, via a queue job** - so first page
views never pay for transforms. Builder API: `field.imgTag().loadingStrategy('lazy').render()`,
`.pictureTag()`, `.linkPreloadTag()` (preload the LCP image), plus `.srcset()`,
`.placeholderImage()`. Transform back ends: Craft native, imgix, Thumbor, Sharp. The
default config only creates WebP variants; AVIF needs a variant creator you add.

**Imager-X 6** (`spacecatninja/imager-x`, [docs](https://imager-x.spacecat.ninja/)):
`craft.imagerx.transformImage(asset, [{width: 480}, {width: 1200}], {format: 'webp'})`
with `craft.imagerx.srcset(images)`; named transforms in
`config/imager-x-transforms.php`; auto-generation on save (`config/imager-x-generate.php`,
**Pro edition**, always queued); external transformers (imgix, Cloudflare Images, AWS
Serverless Image Handler, ...) as separate plugins. Imager-X 6.0 (May 2026) moved the
imgix transformer, S3/GCS storages, and Kraken/Tinify optimizers out of core into
add-on plugins - an upgrade from 5.x must add them back explicitly.

Pick one image pipeline per site. Mixing native transforms, ImageOptimize, and Imager-X
triples storage and makes cache invalidation guesswork.

## Queue

Transform pre-generation, Blitz refresh/warming, search indexing, resaves, and Formie
integrations all run as queue jobs. By default (`runQueueAutomatically` true) Craft runs
jobs off web requests - fine for local, fragile in production (jobs stall when traffic
stops, long jobs time out with PHP).

Production pattern ([queue docs](https://craftcms.com/docs/5.x/system/queue.html)):

```ini
# /etc/systemd/system/craft-queue.service (or the supervisor equivalent)
[Service]
User=www-data
ExecStart=/usr/bin/php /var/www/site/craft queue/listen --verbose
Restart=always
TimeoutStopSec=300     # >= the queue's ttr, so in-flight jobs finish on stop
```

Then set `CRAFT_RUN_QUEUE_AUTOMATICALLY=false` in production `.env`. Restart the daemon
on every deploy (it holds old code in memory). Never run it as root. Cron alternative:
`php craft queue/run` every minute. Triage: `queue/info`, `queue/retry all`,
`queue/release <id>`. Managed hosts (Servd, Craft Cloud, Forge daemons) have their own
runner switch - use it rather than a hand-rolled unit. Local with DDEV: see
[ddev.md](ddev.md).

## Front-end delivery with craft-vite

- `<link rel="modulepreload">` for imported chunks is automatic.
- Inline per-template **critical CSS** with `craft.vite.includeCriticalCssTags()` and
  keep `asyncCss` true; without critical CSS pass `false` or you ship a FOUC.
- Preload the LCP image (ImageOptimize `.linkPreloadTag()`, or a hand-written
  `<link rel="preload" as="image" imagesrcset=...>`).
- Drop `@vitejs/plugin-legacy` unless analytics justify the extra bundles.

Details: [craft-vite.md](craft-vite.md).

## Production config checklist

| Setting | Production value | Why |
|---------|------------------|-----|
| `devMode` | `false` | Debug overhead, verbose errors, 30 s SEOmatic cache |
| `allowAdminChanges` | `false` | Schema changes come from Project Config only |
| `runQueueAutomatically` | `false` + daemon | See [Queue](#queue) |
| `enableTemplateCaching` | `false` on Blitz-cached sites | Avoid stale fragments |
| `generateTransformsBeforePageLoad` | `true` on Blitz sites; else `false` (default) + pre-generation | Blitz won't cache pages with pending transform URLs |
| `enableGraphqlCaching` | `true` (default) | Headless sites |
| Blitz `cachingEnabled` | `true`, with server rewrites or CDN purger | Serve HTML without PHP |
| OPcache | On, `validate_timestamps=0` + reload on deploy | PHP compile cost per request |
