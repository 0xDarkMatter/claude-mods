---
name: craftcms-ops
description: "Craft CMS 5 development - content modeling, Twig templating, element queries, GraphQL, plugins, and the Craft 4-to-5 Matrix-as-entries change. Use for: craft cms, craftcms, craft 5, twig, pixel & tonic, matrix field, entry types, sections, element query, eager loading, blitz, project config, headless craft, craft graphql, craft plugin, craft 4 to 5 upgrade."
when_to_use: "Use when building on Craft CMS 5 — e.g. 'model content with Matrix-as-entries', 'write a Twig template or element query', 'set up headless Craft with GraphQL', 'migrate Craft 4 to 5'. Covers sections, entry types, eager loading, project config, and plugins."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: laravel-ops, sql-ops, nginx-ops
---

# Craft CMS Operations

> Facts verified as of 2026-07.

Authoritative reference for **Craft CMS 5.x** development: content modeling, Twig templating, element-query optimization, GraphQL/headless setups, plugin development, and the Craft 4 → 5 migration. Craft is a self-hosted PHP application built on Yii 2, backed by MySQL or PostgreSQL.

> **Version note (verified against craftcms.com/docs/5.x, 2026-06):** Craft 5 is current; Craft 6 exists. The defining Craft 5 change is that **Matrix is now an entries-based field** — Matrix "blocks" are gone, replaced by nested **entries** with **entry types**. Fields are **globally reusable** across all field layouts. Don't ship Craft 3/4 "Matrix block" guidance.

---

## Craft 5 architecture at a glance

| Concept | What it is | Craft 5 change |
|---------|-----------|----------------|
| **Section** | Container exposing entry types + URL rules | Three kinds: Single, Channel, Structure |
| **Entry Type** | Atomic unit of content (fields, title, slug) | Now **global + reusable** across sections, with per-section aliases |
| **Entry** | An instance of an entry type | Can be top-level or **nested** (inside Matrix/CKEditor) |
| **Field** | Reusable input attached via field layouts | **Globally reusable** — no per-field-instance duplication |
| **Matrix field** | Repeatable nested content | **Now stores entries** (entry types), not "blocks". Nesting supported natively |
| **Project Config** | Version-controlled schema (`config/project/`) | Source of truth for sections/fields/settings |

### Section types

| Type | Use for | Has URLs? | Hierarchy? |
|------|---------|-----------|-----------|
| **Single** | One-off pages (home, about) | Optional fixed URI | No |
| **Channel** | Streams (blog, news, products) | Yes, per-entry-type URI format | No |
| **Structure** | Nested/ordered content (docs, nav) | Yes | Yes (drag-to-order, levels) |

---

## Element queries (the 80/20)

Everything readable in Craft is an *element* (entries, assets, users, categories, tags). You fetch them with element queries.

```twig
{# Channel entries, newest first #}
{% set posts = craft.entries()
  .section('blog')
  .type('article')
  .orderBy('postDate DESC')
  .limit(10)
  .all() %}

{# Eager-load relations to kill N+1 #}
{% set posts = craft.entries()
  .section('blog')
  .with(['author', 'featuredImage', 'categories'])
  .all() %}

{# Single entry by slug #}
{% set page = craft.entries().section('pages').slug('about').one() %}

{# Relations: entries related to a given category #}
{% set related = craft.entries().relatedTo(category).all() %}
```

| Need | Method |
|------|--------|
| Filter by section | `.section('handle')` |
| Filter by entry type | `.type('handle')` |
| Eager-load relations | `.with(['field', 'field.subfield'])` |
| Status | `.status('live')` / `.status(['live','expired'])` |
| One vs many | `.one()` / `.all()` / `.count()` / `.exists()` |
| Pagination | `{% paginate query as pageInfo, entries %}` |
| Eager-load nested Matrix entries | `.with(['matrixField'])` then loop nested entries |

**Eager-loading nested entries (Craft 5):** because Matrix content is now entries, eager-load the Matrix field then iterate the nested entries by their entry type:

```twig
{% set page = craft.entries().section('pages').with(['body']).one() %}
{% for block in page.body.all() %}
  {% switch block.type.handle %}
    {% case 'text' %}{{ block.richText }}
    {% case 'image' %}{{ block.image.one().url }}
  {% endswitch %}
{% endfor %}
```

See `references/twig-and-queries.md` for the full query parameter catalog, pagination, and Twig patterns.

---

## Twig conventions

| Pattern | Rule |
|---------|------|
| Private templates | Prefix with `_` (`_layouts/`, `_partials/`) so they're not directly routable |
| Layout inheritance | `{% extends '_layouts/base' %}` + `{% block content %}` |
| Reusable markup | `{% include '_partials/card' with { entry: entry } %}` or `{{ include() }}` |
| Avoid logic in templates | Push business logic to a module/plugin service, not Twig |
| Caching | `{% cache %}` — **only after** queries are optimized, never to mask N+1 |

---

## Headless / GraphQL

Craft ships a GraphQL API for decoupled frontends (Next.js, Nuxt, Astro, etc.).

| Concern | Approach |
|---------|----------|
| Schema | Define **GraphQL schemas** + scopes in Control Panel; generate a token per schema |
| Auth | Bearer token per schema; public schema for anonymous reads |
| Alternative | Element API plugin for custom JSON endpoints when GraphQL is overkill |
| CORS | Configure allowed origins for the headless frontend |
| Eager loading | GraphQL resolves relations efficiently; still design queries to avoid over-fetching |

See `references/graphql-and-plugins.md` for schema setup, query shape, and plugin/module development.

---

## Performance decision table

| Symptom | Fix |
|---------|-----|
| Slow listing pages | Eager-load with `.with([...])` — the #1 Craft perf bug is N+1 inside loops |
| Repeated identical render | `{% cache %}` tag (after query optimization) |
| Whole-site cache needed | **Blitz** plugin (static page caching, granular invalidation) |
| Slow `orderBy` on custom field | Ensure the underlying column/field is indexed |
| Heavy asset transforms | Pre-generate transforms; use Imgix/CDN |

---

## Project Config & deployment

- **Project Config** (`config/project/*.yaml`) is the version-controlled source of truth for sections, fields, entry types, settings. Commit it.
- Apply on deploy: `php craft up` (runs migrations + applies project config).
- Environment-specific values go in `.env` and `config/general.php` (use `App::env()` / `getenv()`).
- Data transformations belong in **content migrations**, not manual DB edits.

---

## Craft 4 → 5 upgrade checklist

| Area | What changed | Action |
|------|--------------|--------|
| Matrix | Blocks → **entries with entry types** | Templates iterating `.type.handle` mostly survive; re-check block-type field handles |
| Fields | Now **globally reusable** | Expect field/entry-type proliferation post-upgrade — consolidate duplicates |
| Content storage | Reworked internal storage | Run `php craft up`; test queries on staging |
| PHP/DB | Craft 5 needs PHP 8.2+ | Verify host before upgrading |
| Plugins | Many need a Craft 5-compatible release | Audit plugin compatibility first |

Full upgrade guidance: <https://craftcms.com/docs/5.x/upgrade.html>

---

## Common gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| N+1 queries in loops | Element relations lazy-load | Always `.with([...])` before iterating |
| `{% cache %}` masking slow queries | Cache hides, doesn't fix | Optimize queries first, cache second |
| Business logic in Twig | Hard to test/reuse | Move to a module/plugin service |
| Project Config drift in teams | Out-of-band CP edits | Treat `config/project/` as source of truth; `php craft up` on deploy |
| Untested migrations to prod | Data loss risk | Test on staging clone first |
| Over-using Matrix | Complexity + perf cost | Use simpler structures when nesting isn't needed |
| Calling old "Matrix block" APIs | Removed in Craft 5 | Use entry/entry-type APIs |

---

## Assets

| File | Use |
|------|-----|
| `assets/entry-type-field-layout.md` | Annotated content-modeling starter: section + entry type + field layout + Matrix-as-entries shape, mapped to Project Config |

---

## See also

- `laravel-ops` — shared PHP/Composer/Twig-adjacent tooling, Eloquent patterns for comparison
- `sql-ops` — index strategy behind slow `orderBy`/relation queries
- `nginx-ops` — serving Craft, caching headers, reverse proxy for headless

### Key external resources

- [Craft CMS 5.x Docs](https://craftcms.com/docs/5.x/)
- [Entries reference](https://craftcms.com/docs/5.x/reference/element-types/entries.html)
- [Matrix fields (Craft 5)](https://craftcms.com/docs/5.x/reference/field-types/matrix.html)
- [Eager-loading](https://craftcms.com/docs/5.x/development/eager-loading.html)
- [GraphQL API](https://craftcms.com/docs/5.x/development/graphql.html)
- [Upgrading from Craft 4](https://craftcms.com/docs/5.x/upgrade.html)
- [Coding guidelines](https://craftcms.com/docs/5.x/extend/coding-guidelines.html)
- [Blitz plugin](https://putyourlightson.com/plugins/blitz) · [nystudio107 blog](https://nystudio107.com/blog) · [Craft Stack Exchange](https://craftcms.stackexchange.com/)
