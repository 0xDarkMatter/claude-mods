# Upgrade Paths: Craft 3 → 4 → 5 (→ 6)

Major upgrades are sequential: **Craft 3 → latest Craft 4 → Craft 5**. There is no
3 → 5 jump, and Craft 6 will only accept upgrades from the latest 5.x. Checked
2026-10-05 against the [Craft 4 upgrade guide](https://craftcms.com/docs/4.x/upgrade.html),
[Craft 5 upgrade guide](https://craftcms.com/docs/5.x/upgrade.html), and
[supported versions](https://craftcms.com/knowledge-base/supported-versions).

## Contents

- [Where each major stands](#where-each-major-stands)
- [The routine for any major upgrade](#the-routine-for-any-major-upgrade)
- [Craft 3 → 4](#craft-3--4)
- [Craft 4 → 5](#craft-4--5)
- [Plugin lines to move together](#plugin-lines-to-move-together)
- [Craft 6 (alpha)](#craft-6-alpha)

## Where each major stands

| Major | Status (2026-10-05) | Latest | PHP |
|-------|--------------------|--------|-----|
| Craft 3 | EOL - security support ended 30 Apr 2024 (one late critical fix, 3.9.15, Apr 2025) | 3.9.15 | 7.2.5+ |
| Craft 4 | EOL - security support ended 30 Apr 2026 (a few fixes still shipped "where possible") | 4.18.x | 8.0.2+ |
| **Craft 5.x** | Current. Active support to 31 Dec 2030, security to 31 Dec 2031 | 5.11.x | 8.2+ |
| Craft 6 | Alpha (since May 2026), Laravel-based | 6.0.0-alpha | 8.5+ |

A Craft 3 or 4 site is running without guaranteed security fixes. Price the upgrade as
a security item, not a feature.

## The routine for any major upgrade

1. **Locally, on production data**: `ddev pull` (or import a fresh dump) and take a
   snapshot (`ddev snapshot --name=pre-upgrade`) - see [ddev.md](ddev.md).
2. Update to the **latest release of the current major** and every plugin's latest
   release for that major. Clear **all deprecation warnings** (Utilities → Deprecation
   Warnings) - Craft only evaluates the templates you visit, so crawl the site.
3. Check every plugin has a release for the target major (Plugin Store, or the
   in-CP upgrade utility). Find replacements for abandoned ones *before* starting.
4. Upgrade PHP and the database to the target's minimums first - the latest release of
   the old major runs on the new requirements.
5. Change constraints, `composer update`, `php craft up` (migrations + Project Config).
6. Fix templates and modules; run the test suite ([codeception.md](codeception.md)).
7. Commit `composer.json`, `composer.lock`, `config/project/`, templates. Deploy, run
   `php craft up` on each environment, clear caches, re-warm Blitz.

## Craft 3 → 4

- **Start from Craft 3.7.11+** (the 4.x `minVersionRequired`); latest 3.9.x is better.
- **Requirements:** PHP 8.0.2+, MySQL 5.7.8+ / MariaDB 10.2.7+ / PostgreSQL 10+; the
  BCMath and Intl extensions become required.
- **Volumes → Filesystems:** storage settings move from volumes to filesystems;
  `config/volumes.php` is no longer supported - recreate as filesystem config.
- **Twig 3:** `{% spaceless %}` → `{% apply spaceless %}`, `{% filter x %}` →
  `{% apply x %}`, the `if` clause on `{% for %}` is removed (filter first), and
  string/number comparisons are stricter.
- **Removed template APIs:** `getCsrfInput()` → `csrfInput()`; `craft.request`,
  `craft.config` etc. → `craft.app.*`; query `.find()` → `.all()`, `.first()` → `.one()`.
- **Behaviour changes:** `.collect()` / `collect()` return Laravel-style collections
  (an empty collection is truthy - `{% if entries %}` on a collection is always true);
  user queries return all users by default; logging moves to Monolog.
- **Config removed:** `siteName`, `siteUrl`, `useProjectConfigFile`,
  `suppressTemplateErrors`, and others - move site name/URL to Settings → Sites with
  env vars.
- Matrix is unchanged in 4 (`craft.matrixBlocks()` still exists).

## Craft 4 → 5

- **Start from the latest Craft 4** (core enforces 4.5.0 minimum; the docs ask for the
  latest 4.x with zero deprecation warnings).
- **Requirements:** PHP 8.2+, MySQL 8.0.17+ / MariaDB 10.4.6+ / PostgreSQL 13+.
  Recommended: MySQL 8.0.36+ or PostgreSQL 16+; MariaDB no longer recommended.
- **Prep on Craft 4:** empty the queue, `php craft project-config/rebuild`,
  `php craft utils/fix-field-layout-uids`, deploy that, note the Temp Uploads Location
  setting. MySQL: put the current charset/collation in `.env` for the upgrade.
- **Upgrade:** Craft 5 Upgrade utility → **Prep composer.json** (or set
  `craftcms/cms: ^5.0.0` and every plugin's Craft 5 constraint by hand - all at once),
  `composer update`, `php craft up`. MySQL: remove the temporary charset settings and
  run `php craft db/convert-charset`.

**What changes for templates and content:**

| Change | Impact |
|--------|--------|
| Matrix blocks become **entries** with entry types | `craft.matrixBlocks()` → `craft.entries()` (with `.field()` / `.owner()`); `block.type.handle` switches keep working (local handle overrides, 5.6+) |
| Migrated entry types can get **new handles** (`gallery1`) | `.type('gallery')` queries may need updating - check Settings → Entry Types |
| Entry types and fields are **global**; multi-instance fields | Expect duplicated fields/types after upgrade; consolidate with `fields/auto-merge`, `fields/merge`, `entry-types/merge` (5.3+) |
| The `content` table is gone (JSON column on `elements_sites`) | Element queries keep working; raw SQL against `content` breaks |
| MySQL text queries become **case-sensitive** | Use the `caseInsensitive` query option for third-party values |
| GraphQL entry types drop the section prefix | `blog_article_Entry` → `article_Entry` ([graphql.md](graphql.md)) |
| URL fields become **Link** fields (5.3+) | Templates fine; PHP type hints may change |
| `.eagerly()` arrives | Lazy eager loading for shared partials ([performance.md](performance.md)) |

**Categories, tags, globals → entries:** optional, but where agencies end up. The
`entrify/categories`, `entrify/tags`, and `entrify/global-set` commands (available
since 4.4) convert them to sections, keeping relations. Do it as a separate deploy after
the core upgrade has settled.

## Plugin lines to move together

| Plugin | Craft 3 | Craft 4 | Craft 5 | Upgrade notes |
|--------|---------|---------|---------|---------------|
| SEOmatic | 3.x | 4.x | 5.x | Settings migrate automatically |
| Blitz | 3.x | 4.x | 5.x | `craft.blitz.getTemplate()` / `getUri()` removed in 5 → `includeDynamic()` / `fetchUri()` ([blitz.md](blitz.md)) |
| Formie | 1.x | 2.x | 3.x (4.x in beta) | Check custom form templates against the new version's templates |
| Rich text | Redactor | Redactor or CKEditor 3.x | CKEditor 4.x / 5.x | Convert with `ckeditor/convert/redactor` before or during the move ([ckeditor.md](ckeditor.md)) |
| craft-vite | 1.x | 4.x | 5.x | Config keys unchanged; check `manifestPath` if Vite also jumps ([craft-vite.md](craft-vite.md)) |
| ImageOptimize | 1.x | 4.x | 5.x | Re-run variant generation after upgrade |
| Imager-X | 3.x | 4.x | 5.x / 6.x | 6.0 moved imgix, S3/GCS, Kraken/Tinify into add-on plugins |

Versions from Packagist on 2026-10-05; verifier: `scripts/check-craft-facts.py`.

## Craft 6 (alpha)

- Craft 6 rebuilds Craft on **Laravel** (PHP 8.5+), with a rebuilt control panel and
  templates moving to `resources/views/`. Alpha since 6 May 2026; Pixel & Tonic expects
  6.0.0 around the end of 2026 or Q1 2027
  ([transition planning](https://craftcms.com/knowledge-base/laravel-transition-planning)).
- Path: latest 5.x only; a `craft6-revamp` CLI automates steps, and a
  `craftcms/yii2-adapter` keeps Yii-based plugins and modules running during transition.
- Craft 5 moves to long-term support when 6 ships - there is no rush for client sites.
  Don't put client work on the alpha; do keep new module code service-shaped and
  framework-light so it ports cleanly.
