# SEOmatic

SEOmatic (`nystudio107/craft-seomatic`) generates every head tag, JSON-LD block, sitemap,
and robots.txt from a settings cascade. Versions: SEOmatic 5 for Craft 5, 4.x for
Craft 4, 3.x for Craft 3 (Packagist, 2026-10-05). The v4 and v5 docs are the same apart
from the Craft version. Source for everything below unless noted:
[SEOmatic docs](https://nystudio107.com/docs/seomatic/).

## Contents

- [Mental model: the cascade](#mental-model-the-cascade)
- [Rendering](#rendering)
- [Overriding from Twig](#overriding-from-twig)
- [JSON-LD](#json-ld)
- [Sitemaps and robots.txt](#sitemaps-and-robotstxt)
- [Environments](#environments)
- [Headless](#headless)
- [Performance pitfalls](#performance-pitfalls)

## Mental model: the cascade

| Layer (lowest to highest priority) | Scope | Where |
|-----------------------------------|-------|-------|
| **Global SEO** | Whole site (per site) | SEOmatic → Global SEO |
| **Content SEO** | Per section / category group / product type, per site. Maps source fields (e.g. `summary`) to title, description, image | SEOmatic → Content SEO |
| **SEO Settings field** | Per entry, with an Override switch per value | A field you add to a field layout |
| **Twig** | Per request | `{% do seomatic.meta... %}` in templates |

An empty value falls back to the layer above. Most sites need **no** SEO Settings field:
map Content SEO to existing fields (summary, hero image) and editors never think about
SEO. Add the field only where editors genuinely need per-entry overrides.

## Rendering

SEOmatic **injects automatically** - no template tag. Title, meta, and link tags go into
`<head>`; JSON-LD goes just before `</body>`. Because injection happens after the
template renders, a `{% do seomatic.meta... %}` in any template - including an included
partial - still takes effect.

The "Automatic Render Enabled" setting is `renderEnabled`. Turn it off per request with
`{% do seomatic.config.renderEnabled(false) %}`, or globally and then render containers
yourself (`seomatic.tag.render()`, `seomatic.link.render()`, ...). Only do that for
templates that are not HTML pages (feeds, JSON).

## Overriding from Twig

```twig
{# Setting uses method-call syntax inside {% do %} - {% set %} only READS #}
{% do seomatic.meta.seoTitle(entry.title ~ ' | Case study') %}
{% do seomatic.meta.seoDescription(entry.summary) %}
{% set hero = entry.heroImage.one() %}
{% if hero %}{% do seomatic.meta.seoImage(hero.getUrl('social')) %}{% endif %}  {# a URL string #}

{# Several at once #}
{% do seomatic.meta.setAttributes({ seoTitle: entry.title, seoDescription: entry.summary }) %}

{# Individual tags, links, scripts #}
{% do seomatic.tag.get('description').content('...') %}
{% do seomatic.link.get('canonical').href(canonicalUrl) %}
{% do seomatic.script.get('googleAnalytics').include(false) %}

{# Read the final, parsed value #}
{{ seomatic.meta.parsedValue('seoDescription') }}
```

Common agency bug: `{% set seomatic.meta.seoTitle = 'x' %}` - silently does nothing.
Pass values directly (`entry.title`) rather than SEOmatic's `{entry.title}` single-brace
template strings unless you are inside the CP settings.

Paginated listings: set canonical/robots per page deliberately (see
[element-queries.md](element-queries.md#pagination)).

## JSON-LD

SEOmatic builds `WebSite`, `Organization`/`Person` (from Site Settings), `BreadcrumbList`,
and a `mainEntityOfPage` typed per Content SEO (Article, Product, Event, ...).

```twig
{# Adjust the main entity #}
{% set main = seomatic.jsonLd.get('mainEntityOfPage') %}
{% do main.setAttributes({ datePublished: entry.postDate|atom }) %}

{# Create AND add an entity. A second arg of false builds it without adding -
   use that for an entity you nest inside another one #}
{% set faq = seomatic.jsonLd.create({
    'type': 'FAQPage',
    'mainEntity': faqItems
}) %}
```

Source: [JSON-LD meta](https://nystudio107.com/docs/seomatic/using/json-ld-meta.html).
Validate output with Google's Rich Results Test; schema.org types that Google ignores
add bytes, not rankings.

## Sitemaps and robots.txt

- One sitemap per section / category group / product type, per site, paginated
  (Sitemap Page Size, default 500). The index lives at `/sitemaps-1-sitemap.xml`
  (`1` = site group id).
- Sitemaps are generated **on demand and cached**; the cache is invalidated when an
  element saves. They are no longer queue-built - the `seomatic/sitemap/generate`
  command and `regenerateSitemapsAutomatically` are deprecated.
- Image and video sitemap entries come from Asset fields (including inside Matrix);
  indexable files (PDF, DOCX) can be included.
- Search engines dropped sitemap pings, so `submitSitemaps` is effectively legacy - submit
  the index once in Search Console.
- robots.txt, humans.txt, ads.txt, security.txt are Twig templates under Global SEO.
  A physical `web/robots.txt` (or an nginx `location = /robots.txt`) **overrides** them -
  a common reason "SEOmatic's robots.txt isn't working".

Sections that should not be indexed (thank-you pages, landing-page variants): turn off
their sitemap in Content SEO and set robots to `noindex` there, not in templates.

## Environments

SEOmatic's own `environment` setting (`live` | `staging` | `local`) is separate from
Craft's `CRAFT_ENVIRONMENT`. With `manuallySetEnvironment = false` it auto-detects, and
`devMode` forces `local`. On `local`/`staging`: robots meta is `none`, robots.txt
disallows everything, tracking scripts don't load, and canonicals are omitted (unless
`alwaysIncludeCanonicalUrls`). Source:
[multi-environment](https://nystudio107.com/docs/seomatic/configuring/multi-environment.html).

**Launch checklist item:** confirm production resolves to `live` (view source: robots
must not be `none`). A staging environment value deployed to production de-indexes the
site.

`config/seomatic.php` real keys include `renderEnabled`, `sitemapsEnabled`,
`environment`, `manuallySetEnvironment`, `metaCacheDuration` (there is no
`cacheDuration`), `allowedUrlParams`, `addHrefLang`, `maxTitleLength` (70),
`maxDescriptionLength` (155), `enableMetaContainerEndpoint`, `cspNonce`. Use the
`'*'` multi-environment array shape.

## Headless

GraphQL (Craft Pro): `seomatic(uri: "/about", siteId: 1, asArray: true) {
metaTitleContainer metaTagContainer metaLinkContainer metaScriptContainer
metaJsonLdContainer }`, or `entry { seomatic { ... } }`. The REST equivalent
`/actions/seomatic/meta-container/all-meta-containers/?uri=/` is **off** for anonymous
callers until `enableMetaContainerEndpoint` is true. See [graphql.md](graphql.md).

## Performance pitfalls

| Pitfall | Why | Fix |
|---------|-----|-----|
| Wrapping SEOmatic output or setters in `{% cache %}` | The docs warn against it: tags are built per request from SEOmatic's own cache, so a cached `{% do %}` never runs on the next request | Keep `seomatic.*` calls outside `{% cache %}` |
| Unbounded `allowedUrlParams` | Each allowed query param is part of the meta cache key | Only list params that change SEO meaning |
| Raw full-size `seoImage` | Social crawlers fetch multi-MB originals | Pass a transformed URL, or `seomatic.helper.socialTransform(asset, 'facebook')` |
| Debug toolbar panel in prod | Extra work per request | `enableDebugToolbarPanel` only in dev |
| Assuming Blitz + SEOmatic need glue | Blitz 5 ships a SEOmatic integration that refreshes cached pages when SEOmatic clears its caches | Nothing to do - see [blitz.md](blitz.md) |

Meta containers cache until SEOmatic invalidates them (`metaCacheDuration` null); with
`devMode` on they last 30 seconds, so "my change didn't show" in dev is usually the 30 s
cache, and in prod usually Blitz.
