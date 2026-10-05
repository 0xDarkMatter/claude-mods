# Blitz (Static Page Caching)

Blitz (`putyourlightson/craft-blitz`) caches rendered HTML per URL, tracks which
elements each page used, and refreshes exactly those pages when an element changes.
Versions: Blitz 5 for Craft 5 (5.13.x requires Craft 5.6+), 4.x for Craft 4 (Packagist,
2026-10-05). Source for everything below unless noted:
[Blitz docs](https://putyourlightson.com/plugins/blitz).

## Contents

- [Enable it deliberately](#enable-it-deliberately)
- [Serving: storage and server rewrites](#serving-storage-and-server-rewrites)
- [Refresh and invalidation](#refresh-and-invalidation)
- [Cache generation (warming)](#cache-generation-warming)
- [Dynamic content on cached pages](#dynamic-content-on-cached-pages)
- [Blitz versus `{% cache %}`](#blitz-versus--cache-)
- [Finding N+1s: Hints is gone](#finding-n1s-hints-is-gone)
- [Purgers, deployers, integrations](#purgers-deployers-integrations)
- [Debugging "my change isn't showing"](#debugging-my-change-isnt-showing)

## Enable it deliberately

Out of the box `cachingEnabled` is **false** and `includedUriPatterns` is **empty** - nothing
is cached until you opt in. Patterns are regex; excluded patterns win over included.

```php
// config/blitz.php
use putyourlightson\blitz\models\SettingsModel;

return [
    '*' => [
        'cachingEnabled' => false,
        // siteId '' = all sites; shape matches the plugin's own src/config.php
        'includedUriPatterns' => [['enabled' => true, 'siteId' => '', 'uriPattern' => '.*']],
        'excludedUriPatterns' => [['enabled' => true, 'siteId' => '', 'uriPattern' => '^(search|account|cart)']],
        'queryStringCaching' => 0,   // 0 = don't cache URLs with query strings (default)
        'refreshMode' => SettingsModel::REFRESH_MODE_CLEAR_AND_GENERATE,
    ],
    'production' => ['cachingEnabled' => true],
];
```

Exclude anything personalised (account, cart, search results, form confirmation pages
with user data). `queryStringCaching` 1 caches each query string as its own page, 2
treats them as the same page; unbounded query strings (UTM tags) at mode 1 explode the
cache - list them in `excludedQueryStringParams`.

## Serving: storage and server rewrites

| Storage | When |
|---------|------|
| **File storage** (default, `@webroot/cache/blitz`) | Single server. Pair with server rewrites so cached hits never touch PHP |
| **Yii cache storage** | Multi-node or ephemeral filesystems; uses Craft's cache component (Redis via `config/app.php`) |

Server rewrites (Apache `.htaccess` / Nginx `try_files` snippets in the docs' "Server
Rewrites" section) serve `cache/blitz/{host}/{uri}/index.html` directly and bypass on
non-GET requests and preview `token=` URLs. **Don't** use server rewrites when a CDN in
front caches the HTML - you would bypass the cache-control headers Blitz relies on.

## Refresh and invalidation

- Saving, creating, or deleting an element refreshes every cached page that **tracked**
  that element or a query that could include it. Expiry dates and `cacheDuration` also
  trigger refreshes (`blitz/cache/refresh-expired` from cron if you rely on them).
- Saving a **global set refreshes the entire cache** (`refreshCacheAutomaticallyForGlobals`).
  Footer globals edited daily = a full re-warm daily. Consider a Single instead.
- `refreshMode`: `REFRESH_MODE_CLEAR_AND_GENERATE` (default), `EXPIRE_AND_GENERATE`
  (serve stale until regenerated - safest for traffic spikes), `CLEAR`, `EXPIRE`
  (regenerate manually or organically).
- The two `*_AND_GENERATE` modes **regenerate in a queue job**. A stalled queue means a
  stale or empty cache - run the queue as a daemon in production
  ([performance.md](performance.md#queue)).
- Tags for manual control: `{% do craft.blitz.options({ tags: ['nav'] }) %}`, then
  `php craft blitz/cache/refresh-tagged nav`.
- Per-page options: `{% do craft.blitz.options({ cachingEnabled: false }) %}`, also
  `cacheDuration`, `expiryDate`, `trackElements`, `trackElementQueries`, `tags`.

Console commands (5.13.4 source): `blitz/cache/clear`, `flush`, `generate`, `refresh`,
`refresh-expired`, `refresh-site`, `refresh-urls`, `refresh-tagged`, `purge`, `deploy`,
plus `-site` / `-urls` / `-tagged` variants. Run `php craft blitz/cache/refresh` after a
deploy that changes templates - Blitz tracks content changes, not template changes.

## Cache generation (warming)

`cacheGeneratorType`: the **HTTP generator** (default) requests each URL over HTTP, so
the site must be reachable from the server itself (watch basic-auth on staging); the
**local generator** renders via mocked requests. `cacheGeneratorSettings` defaults to
`['concurrency' => 3]`; drop it to 1 if generation knocks the server over. Add URLs
Blitz can't discover (paginated pages, routes outside sections) to `customSiteUris`.

## Dynamic content on cached pages

A cached page is identical for every visitor, so anything per-user must be fetched
after load:

| Need | Blitz 5 API |
|------|-------------|
| CSRF token in a cached form | `{{ craft.blitz.csrfInput() }}` (also `csrfParam()`, `csrfToken()`) |
| A per-user fragment (cart count, "logged in as") | `{{ craft.blitz.includeDynamic('_partials/cart-count', { siteId: currentSite.id }) }}` |
| Another URL's output | `{{ craft.blitz.fetchUri('/api/stock', { id: product.id }) }}` |
| A shared fragment cached once, included everywhere | `{{ craft.blitz.includeCached('_partials/footer') }}` (SSI/ESI if `ssiEnabled`/`esiEnabled`, else Ajax) |

Params must be primitives (ids, not elements). `craft.blitz.getTemplate()` and `getUri()`
were deprecated in 4.3 and **removed in 5.0** - upgrade them to `includeDynamic()` /
`fetchUri()` when moving to Blitz 5. Craft's own `{{ csrfInput({ async: true }) }}`
also works on cached pages ([twig-security.md](twig-security.md)); Formie handles its
own tokens ([formie.md](formie.md)).

## Blitz versus `{% cache %}`

The Blitz docs call `{% cache %}` **redundant** on Blitz-cached pages and say it does not
play well with Blitz's invalidation: a `{% cache %}` block can serve a stale fragment
into a freshly regenerated page. On a fully Blitz-cached site remove the tags, or set
`'enableTemplateCaching' => false` in `config/general.php`.

`{% cache %}` still earns its place on pages Blitz **excludes** (search, account) or on
sites that can't use full-page caching - see [performance.md](performance.md).

## Finding N+1s: Hints is gone

The **Blitz Hints** utility flagged lazy-loaded relations that could be eager-loaded
(and, on Craft 5, suggested `.eagerly()`). It shipped through Blitz 4 and early Blitz 5
and was **removed in 5.10.0 (2025-04-07)**
([CHANGELOG](https://github.com/putyourlightson/craft-blitz/blob/develop/CHANGELOG.md)).
On Blitz 4 and early Blitz 5 sites it is still under Utilities. On 5.10+ use the
**Blitz Diagnostics** utility (tracked pages, elements, element queries - with template,
line, and backtrace since 5.12) plus Craft's debug toolbar for query counts, and fix
what you find with `.with()` / `.eagerly()` ([element-queries.md](element-queries.md)).
Blitz hides N+1s on cached hits; they still cost you on every regeneration.

## Purgers, deployers, integrations

- **Reverse-proxy purgers:** Cloudflare is built in; CloudFront, KeyCDN, Fastly, Varnish
  are separate packages. Use one when a CDN caches HTML, instead of server rewrites.
- **Deployers:** Git built in (push the cache to a static host); Shell and Netlify as add-ons.
- **SEOmatic integration** is built into Blitz 5: when SEOmatic clears its meta caches,
  Blitz refreshes the affected pages. Nothing to configure.

## Debugging "my change isn't showing"

1. View source: a Blitz-served page ends with a Blitz HTML comment carrying the cache
   date (when `outputComments` is on, the default). No comment = not served by Blitz.
2. Is the URL excluded, or did the request carry a query string with
   `queryStringCaching` 0? Those never cache. Neither does any page containing
   **image-transform generation URLs** - set `generateTransformsBeforePageLoad => true`
   ([performance.md](performance.md#images-transforms-srcset-avif)).
3. Template change? Blitz doesn't track templates - `blitz/cache/refresh`.
4. Content change not refreshing? The page didn't track that element: a custom query
   in a module, or a relation fetched via a plugin API. Tag the page and refresh by tag.
5. CDN in front? Check its cache before blaming Blitz; configure the matching purger.
