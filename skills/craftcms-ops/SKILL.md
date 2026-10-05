---
name: craftcms-ops
description: "Craft CMS 3/4/5 agency site builds: Matrix-as-entries content modeling, Twig and element queries, eager loading, output escaping and CSRF, and the usual plugin stack - SEOmatic, Blitz, Formie, CKEditor, craft-vite - plus DDEV, Codeception, image transforms, the queue, and 3-to-4-to-5 upgrades. Use when building, debugging, securing, speeding up, or upgrading a Craft site, or editing its Twig templates, config/project, or any of those plugins."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "laravel-ops, sql-ops, nginx-ops, perf-ops, tailwind-ops, playwright-ops, a11y-ops"
---

# Craft CMS Operations

> Versions verified 2026-10-05 against Packagist and the official docs. Craft 5.x is
> current (5.11); Craft 4 and 3 are past security support; Craft 6 is in alpha.
> `scripts/check-craft-facts.py --live` re-checks the plugin majors on a schedule.

The recurring agency shape: Craft 5 (or a 4/3 site awaiting upgrade) on DDEV, with
SEOmatic, Blitz, Formie, and CKEditor, a Vite (or legacy Laravel Mix) front end, and
modules tested with Codeception and ECS. This file is the procedure and the router;
each topic lives in one reference.

## Step 1 - Orient before touching anything

| Check | Where | Tells you |
|-------|-------|-----------|
| Craft + plugin versions | `composer.json`, `ddev composer show craftcms/cms` | Which line of the [version matrix](#version-matrix) applies - Craft 4 and 5 APIs differ |
| Local environment | `.ddev/config.yaml` | PHP/DB versions; run everything as `ddev craft`, `ddev composer`, `ddev npm` |
| Schema | `config/project/*.yaml` | Source of truth for sections, fields, entry types, plugin settings |
| Config | `config/general.php`, `config/<plugin>.php`, `.env` | Environment-specific behaviour (`devMode`, `allowAdminChanges`, caching) |
| Front-end build | `package.json` + `config/vite.php`, or `webpack.mix.js` | craft-vite or Laravel Mix |
| Templates | `templates/_layouts`, `_partials`, `_partials/entry/<type>.twig` | Layout inheritance and element partials |
| PHP | `modules/`, `tests/`, `codeception.yml`, `ecs.php` | Where logic and tests live |
| Page cache | `config/blitz.php`, Blitz utility | Whether what you see is cached HTML - check before debugging "my change isn't showing" |

## Step 2 - Route the task

| Task | Read |
|------|------|
| Listing pages, relations, Matrix/nested entries, pagination, multi-site | [element-queries.md](references/element-queries.md) |
| Printing anything user-influenced, forms that POST, JS data, rich text output | [twig-security.md](references/twig-security.md) |
| Meta tags, JSON-LD, sitemaps, robots.txt, hreflang | [seomatic.md](references/seomatic.md) |
| Static caching, "changes don't show", cache warming, dynamic bits on cached pages | [blitz.md](references/blitz.md) |
| Building, theming, or debugging forms; spam; form emails not sending | [formie.md](references/formie.md) |
| Rich-text fields, nested entries inside rich text, Redactor conversion | [ckeditor.md](references/ckeditor.md) |
| Local setup, DB pull/push, Xdebug, snapshots | [ddev.md](references/ddev.md) |
| Tests for modules/plugins, fixtures, ECS/PHPStan | [codeception.md](references/codeception.md) |
| Front-end assets, Vite dev server, critical CSS, moving off Laravel Mix | [craft-vite.md](references/craft-vite.md) |
| Upgrading Craft 3 → 4 → 5, plugin version lines, Craft 6 status | [upgrades.md](references/upgrades.md) |
| Slow pages, images, queue setup, production config | [performance.md](references/performance.md) |
| Headless front ends, GraphQL schemas and tokens | [graphql.md](references/graphql.md) |
| Modules, plugins, events, migrations, queue jobs | [plugin-development.md](references/plugin-development.md) |
| Modeling a new flexible page type | [assets/entry-type-field-layout.md](assets/entry-type-field-layout.md) |

## Step 3 - Hold the non-negotiables

1. **Eager-load before you loop.** `.with([...])` up front; `.eagerly()` inside shared
   partials (Craft 5 only). One query per card is the most common Craft perf bug.
2. **Escape by context.** Never `|raw` user-influenced values; `|e('js')` inside JS
   strings; `{{ csrfInput() }}` in every POST form - `csrfInput({ async: true })` on
   cached pages.
3. **Schema only through Project Config.** Change it in the CP locally, commit
   `config/project/`, run `php craft up` on deploy. Production runs
   `allowAdminChanges => false`; never hand-edit the YAML.
4. **Data changes are content migrations** (`php craft migrate/create`), tested on a
   copy of production - not CP clicking on live.
5. **Production runs a queue worker.** Blitz regeneration, Formie emails and
   integrations, transform pre-generation, and resaves are all queue jobs.
6. **Fix queries, then cache.** Blitz for public pages; on Blitz-cached pages drop
   `{% cache %}` (or set `enableTemplateCaching` false).
7. **Logic lives in module services**, not Twig - services are testable.
8. **Stay on the latest Craft 5 patch.** Craft ships regular Twig/RCE security fixes.

## Version matrix

| Package | Craft 3 | Craft 4 | Craft 5 (current) |
|---------|---------|---------|-------------------|
| `craftcms/cms` | 3.9 (EOL) | 4.18 (EOL Apr 2026) | Craft 5.x (5.11); Craft 6 in alpha |
| `nystudio107/craft-seomatic` | 3.x | 4.x | SEOmatic 5 |
| `putyourlightson/craft-blitz` | 3.x | 4.x | Blitz 5 (5.13 needs Craft 5.6+) |
| `verbb/formie` | 1.x | 2.x | Formie 3 (Formie 4 in beta) |
| Rich text | Redactor | Redactor or `craftcms/ckeditor` 3.x | CKEditor plugin 5.x (needs Craft 5.10+; 4.x below that) |
| `nystudio107/craft-vite` | 1.x | 4.x | craft-vite 5 |
| `nystudio107/craft-imageoptimize` | 1.x | 4.x | ImageOptimize 5 |
| `spacecatninja/imager-x` | 3.x | 4.x | Imager-X 6 (5.x still maintained) |
| `codeception/codeception` | match core's `require-dev` | match core's `require-dev` | Codeception 5 |

Requirements for Craft 5: PHP 8.2+, MySQL 8.0.17+ / MariaDB 10.4.6+ / PostgreSQL 13+.
Details and plugin upgrade notes: [upgrades.md](references/upgrades.md).

## Everyday commands

| Command (prefix `ddev` locally) | Does |
|---------------------------------|------|
| `craft up` | Pending migrations + Project Config - run on every deploy |
| `craft project-config/apply` / `project-config/rebuild` | Apply YAML to the DB / rebuild YAML from the DB |
| `craft clear-caches/all` | Data, template, and asset caches |
| `craft queue/run` / `queue/info` / `queue/retry all` | Work and inspect the queue |
| `craft blitz/cache/refresh` | Refresh Blitz after template deploys (Blitz tracks content, not templates) |
| `craft migrate/create <name>` | New content migration |
| `craft make <type>` | Scaffold modules/plugins/components (`craftcms/generator`) |
| `craft entrify/categories <group>` | Convert categories (or `tags`, `global-set`) to entries |

## Craft 5 content model

| Concept | What it is | Craft 5 change |
|---------|-----------|----------------|
| **Section** | Single, Channel, or Structure; holds entry types + URI formats | - |
| **Entry type** | The unit of content shape | **Global and reusable** across sections and Matrix fields |
| **Field** | Reusable input | **Global**, with multi-instance use in one layout |
| **Matrix field** | Repeatable nested content | Stores **nested entries**, not blocks |
| **CKEditor field** | Rich text | Can hold **nested entries** inline |
| **Element partials** | `_partials/entry/<typeHandle>.twig` | `.render()` renders nested entries through them |
| **Project Config** | `config/project/` YAML | Source of truth - commit it |

Pick the section type by shape: **Single** for one-off pages (home, contact),
**Channel** for streams (news, events), **Structure** for hierarchies (pages, docs).
Prefer flat entry types plus a Matrix "page builder" field over many near-identical
sections. Starter shape: [entry-type-field-layout.md](assets/entry-type-field-layout.md).

## Gotchas

| Symptom | Cause | Fix |
|---------|-------|-----|
| Listing page runs hundreds of queries | Relation fetched per item | `.with()` / `.eagerly()` |
| Change visible in CP, not on site | Blitz/CDN serving cached HTML | [blitz.md](references/blitz.md#debugging-my-change-isnt-showing) |
| Form submissions save, emails never send | Queue not running in production | Queue daemon ([performance.md](references/performance.md#queue)) |
| Assets unstyled in production only | Vite 5+ manifest is in `dist/.vite/` | Set `manifestPath` ([craft-vite.md](references/craft-vite.md)) |
| `{% set seomatic.meta.seoTitle = ... %}` does nothing | `set` only reads | `{% do seomatic.meta.seoTitle('...') %}` |
| Staging copy of the site got indexed / prod de-indexed | SEOmatic environment wrong | Check robots in view-source ([seomatic.md](references/seomatic.md#environments)) |
| Project Config conflicts between developers | CP edits on shared/prod environments | `allowAdminChanges` false outside local; one schema change per PR |
| Event handler fires several times per save | Drafts, revisions, propagation | Guard with `ElementHelper::isDraftOrRevision()` + `propagating` |
| `craft.matrixBlocks()` errors after upgrade | Removed in Craft 5 | `craft.entries().field(...).owner(...)` |

## Bundled resources

| File | Use |
|------|-----|
| `assets/entry-type-field-layout.md` | Content-modeling starter: section + entry type + Matrix-as-entries, mapped to Project Config |
| `assets/craft-facts.json` | The version facts this skill documents (package, major, prose token) |
| `scripts/check-craft-facts.py` | Staleness verifier: `--offline` (prose still states the facts) / `--live` (Packagist majors) |

## See also

- `laravel-ops` (Composer/PHP tooling; Craft 6 is Laravel-based) · `sql-ops` (indexes behind
  slow `orderBy`) · `nginx-ops` (serving Craft, Blitz rewrites) · `perf-ops` (profiling) ·
  `tailwind-ops` · `playwright-ops` (browser tests against the DDEV URL)
- `a11y-ops` (WCAG 2.2 for Twig sites: heading levels across partials, asset alt text, Formie
  and CKEditor markup, multi-site `lang`; see its `references/server-rendered-templates.md`)
- [Craft 5 docs](https://craftcms.com/docs/5.x/) · [Plugin Store](https://plugins.craftcms.com/) ·
  [Craft security advisories](https://github.com/craftcms/cms/security/advisories)

**Why this shape:** a 2026 survey of 57 Craft-agency repositories found Craft in 36
(Craft 5 ×17, 4 ×13, 3 ×6), DDEV in 36, SEOmatic in 33, Blitz 21, Formie 18,
CKEditor 18, Laravel Mix 18 versus craft-vite 12, Tailwind 12, ECS 11, and Codeception
10. The references follow that frequency; upgrades matter because half the Craft sites
were on an EOL major.
