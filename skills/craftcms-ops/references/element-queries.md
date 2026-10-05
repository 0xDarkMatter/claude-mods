# Element Queries & Templating

Load this when writing non-trivial templates: listings, nested Matrix content,
pagination, relations, multi-site. Craft 5.x syntax; Craft 4 differences are flagged.

## Contents

- [Parameter catalog](#parameter-catalog)
- [Eager loading (kill N+1)](#eager-loading-kill-n1)
- [Nested entries (Matrix in Craft 5)](#nested-entries-matrix-in-craft-5)
- [Pagination](#pagination)
- [Template organization](#template-organization)
- [Multi-site](#multi-site)

## Parameter catalog

Every element type (entries, assets, users, categories, tags, addresses) shares one
query builder. Common parameters for `craft.entries()`:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `.section()` | One or more section handles | `.section(['blog','news'])` |
| `.type()` | Entry type handle | `.type('article')` |
| `.id()` / `.slug()` / `.uri()` | Identity | `.slug('about')` |
| `.status()` | `live`, `pending`, `expired`, `disabled` | `.status(['live','expired'])` |
| `.orderBy()` | Sort | `.orderBy('postDate DESC')` |
| `.limit()` / `.offset()` | Slice | `.limit(10).offset(20)` |
| `.search()` | Full-text via the search index | `.search('keyword')` |
| `.relatedTo()` | Relations (either direction) | `.relatedTo(category)` |
| `.with()` | Eager-load relations | `.with(['author','image'])` |
| `.site()` / `.unique()` | Multi-site targeting / dedupe | `.site('*').unique()` |
| `.field()` / `.owner()` | Nested entries of a given field / owner (Craft 5) | `.field('body').owner(entry)` |

Terminators: `.all()`, `.one()`, `.count()`, `.exists()`, `.ids()`, `.nth(n)`,
`.collect()` (an `ElementCollection`). Full list: the
[entry query reference](https://craftcms.com/docs/5.x/reference/element-types/entries.html#querying-entries).

## Eager loading (kill N+1)

The single most common Craft performance bug is querying a relation inside a loop.

```twig
{# BAD - one extra query per entry #}
{% for entry in craft.entries().section('blog').all() %}
  {{ entry.featuredImage.one().url }}
{% endfor %}

{# GOOD - one query per relation for the whole set #}
{% set posts = craft.entries().section('blog').with(['featuredImage', 'author']).all() %}
{% for entry in posts %}
  {% set image = entry.featuredImage|first %}
  {{ image ? image.url }}
{% endfor %}
```

Nested paths work: `.with(['author.photo', 'categories', 'body.image'])`. Transforms can
be eager-loaded alongside: `.with([['featuredImage', {withTransforms: ['card']}]])`.

**Craft 5 lazy eager loading.** When you can't build the `.with()` list up front (a
shared partial, a component rendered in many contexts), call `.eagerly()` on the relation
inside the loop. The first access eager-loads that field for every element in the
result set the current element came from:

```twig
{% for entry in posts %}
  {% set image = entry.featuredImage.eagerly().one() %}
{% endfor %}
```

Source: [eager-loading docs](https://craftcms.com/docs/5.x/development/eager-loading.html).
`.eagerly()` works only where the value is an element query (relation and Matrix
fields). Native attributes - an entry's `author`/`authors`, an asset's `uploader` - still
need an explicit `.with(['author'])` (per the
[Craft 5 upgrade notes](https://craftcms.com/docs/5.x/upgrade.html#eager-loading)).
`.eagerly()` does not exist in Craft 4 - there, `.with()` is the only fix.

Finding the N+1s in the first place: the debug toolbar's database panel, or Blitz
Diagnostics (the old Blitz Hints utility was removed in Blitz 5.10 - see
[blitz.md](blitz.md#finding-n1s-hints-is-gone) and [performance.md](performance.md)).

## Nested entries (Matrix in Craft 5)

Craft 5 Matrix fields store **entries**, each with an entry type. Eager-load the field,
then branch on the entry type handle:

```twig
{% set page = craft.entries().section('pages').slug(slug).with(['body.image']).one() %}
{% for block in page.body %}
  {% switch block.type.handle %}
    {% case 'richText' %}
      {{ block.text }}
    {% case 'imageBlock' %}
      {% set img = block.image|first %}
      {% if img %}<img src="{{ img.url }}" alt="{{ img.alt }}">{% endif %}
  {% endswitch %}
{% endfor %}
```

**Element partials** replace the `switch` on larger builds: `{{ page.body.render() }}`
renders each nested entry with `templates/_partials/entry/<entryTypeHandle>.twig`
(path root set by the `partialTemplatesPath` setting, default `_partials`). Each partial
receives the element as `entry`. Same mechanism CKEditor uses for its nested entries
([ckeditor.md](ckeditor.md)). Source:
[general config](https://craftcms.com/docs/5.x/reference/config/general.html#partialtemplatespath).

Craft 4 equivalent: `craft.matrixBlocks()` and `block.type.handle` on Matrix *blocks* -
see [upgrades.md](upgrades.md) for the conversion.

## Pagination

```twig
{% set query = craft.entries().section('blog').orderBy('postDate DESC').limit(12) %}
{% paginate query as pageInfo, entries %}

{% for entry in entries %}{{ entry.title }}{% endfor %}

{% if pageInfo.prevUrl %}<a href="{{ pageInfo.prevUrl }}">Previous</a>{% endif %}
{% if pageInfo.nextUrl %}<a href="{{ pageInfo.nextUrl }}">Next</a>{% endif %}
```

`pageInfo` exposes `currentPage`, `totalPages`, `total`, `first`, `last`,
`getRangeUrls()`. Paginated URLs (`/blog/p2`) are separate cache entries for Blitz and
separate sitemap concerns for SEOmatic - decide early whether `p2+` should be indexed.

## Template organization

| Convention | Detail |
|------------|--------|
| Private templates | Prefix `_` (`_layouts/`, `_partials/`, `_macros/`) - Craft won't route to them (`privateTemplateTrigger`) |
| Layout inheritance | `{% extends '_layouts/base' %}`, fill `{% block %}` regions |
| Includes | `{% include '_partials/card' with { entry } only %}` - `only` isolates scope |
| Macros | `{% macro %}` / `{% import %}` for repeated markup helpers |
| Embeds | `{% embed %}` to override blocks inside an included template |
| Logic | Anything you'd want to unit-test belongs in a module service, not Twig |
| Error pages | `templates/404.twig`, `500.twig`, ... (prefix via `errorTemplatePrefix`) |

## Multi-site

| Need | Approach |
|------|----------|
| Query a specific site | `.site('handle')` |
| Query all sites, deduped | `.site('*').unique()` (add `.preferSites(['en'])` to pick which copy wins) |
| Current site | `currentSite` global (`currentSite.handle`, `currentSite.language`) |
| The same entry in another site | `craft.entries().id(entry.id).site('fr').one()` - `null` if not enabled there |
| hreflang / alternate links | SEOmatic emits these automatically ([seomatic.md](seomatic.md)) |

Each field and section has a propagation/translation method; settle it before content
entry starts - changing it later re-propagates content across sites.
