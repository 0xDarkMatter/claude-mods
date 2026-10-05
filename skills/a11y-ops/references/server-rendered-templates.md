# Server-Rendered Templates — Craft CMS and Twig

Accessibility for sites whose HTML is assembled on the server from layouts,
partials, CMS fields and plugin output. Examples are **Craft CMS 5 + Twig**; the
patterns carry to any server-rendered CMS. Verified **2026-10-05** against Craft
5.11, Formie 3.1, the Craft CKEditor plugin 5.8 and axe-core 4.13 — plugin markup
read from source, not marketing pages. [Sources](#sources) at the end.

## Contents

1. [The rendered page is the unit](#1-the-rendered-page-is-the-unit)
2. [Layout skeleton: landmarks, title, skip link](#2-layout-skeleton-landmarks-title-skip-link)
3. [Heading order across partials](#3-heading-order-across-partials)
4. [Images: alt text from asset fields](#4-images-alt-text-from-asset-fields)
5. [Link text in loops](#5-link-text-in-loops)
6. [Focus states](#6-focus-states)
7. [Forms via Formie](#7-forms-via-formie)
8. [Rich text via CKEditor](#8-rich-text-via-ckeditor)
9. [Language on multi-site Craft](#9-language-on-multi-site-craft)
10. [Testing rendered pages](#10-testing-rendered-pages)

## 1. The rendered page is the unit

Conformance is judged per page, and on a CMS site **no single file owns the
page**: layout, partials, Matrix loops, editor rich text and plugin forms all
contribute markup. So:

- **Fix each failure at the layer that produced it**: developer markup in the
  template; editor content by restricting field settings; plugin markup via the
  plugin's theme config or events, never a forked template.
- **`scan-a11y.py` does not read `.twig`**, and should not — branches and includes
  mean the file is not the page. Scan the output instead:
  `curl -sk https://<project>.ddev.site/about -o about.html && scan-a11y.py about.html`
- **Test one URL per template**, not per site: each entry template, each Matrix
  entry type, search results, the 404, and every form state.

## 2. Layout skeleton: landmarks, title, skip link

The base layout owns the landmarks, so every page gets them by construction.

```twig
{# templates/_layouts/base.twig #}
<!doctype html>
<html lang="{{ craft.app.language }}">
<head><meta charset="utf-8"><title>{% block title %}{{ siteName }}{% endblock %}</title></head>
<body>
  <a class="skip-link" href="#main">Skip to main content</a>
  <header>{% include '_partials/site-header' %}</header>
  <main id="main" tabindex="-1">{% block content %}{% endblock %}</main>
  <footer>{% include '_partials/site-footer' %}</footer>
</body>
</html>
```

- **Exactly one `<main>`, owned by the layout** — a partial opening its own makes
  two. `<header>`/`<footer>` inside an `<article>` partial are fine; only top-level
  ones become banner/contentinfo. Two `<nav>`s need distinct `aria-label`s.
- **Every entry template overrides `title`** (`{{ entry.title }} | {{ siteName }}`);
  a layout default left in place gives every page the same title (2.4.2).
- **Skip link (2.4.1)**: first focusable element; `tabindex="-1"` on the target
  makes the jump move focus, not just scroll. Check: the next Tab lands *inside* main.
- **Consistency comes free — keep it.** Navigation (3.2.3, AA) and help links
  such as contact details or a chat launcher (3.2.6 Consistent Help, A, new in
  2.2) stay put because they live in shared partials. The usual regression is a
  landing-page entry type extending a *different* layout that drops or reorders them.

## 3. Heading order across partials

A heading's correct level depends on **where a partial is included**, which the
partial cannot know: a card hard-coding `<h3>` is right under an `<h2>` section
and wrong at the top of a listing. The caller passes the level in:

```twig
{# _partials/card.twig — the CALLER owns the heading level #}
{% set level = level ?? 3 %}
<article class="card">
  <h{{ level }} class="card__title"><a href="{{ entry.url }}">{{ entry.title }}</a></h{{ level }}>
</article>

{# listing page: cards sit directly under the page h1 #}
{% for item in entries %}
  {% include '_partials/card' with { entry: item, level: 2 } only %}
{% endfor %}
```

- **One `<h1>`**: the entry template renders `entry.title`, and nothing else may —
  not plugin output (Formie's form title is a hard-coded `<h2>`, §7), not editor
  content (CKEditor allows h1 by default, §8).
- **Matrix (Craft 5 nested entries)**: pass `level` into each entry type's
  partial; a "section" type renders `h{{ level }}` and passes `level + 1` inward.
- **Size is a class, not a level** — `<h2 class="h4">`, never a tag picked for its
  font size (1.3.1, 2.4.6).

## 4. Images: alt text from asset fields

What Craft 5 gives you (docs and source):

- A native asset **`alt`** property (since 4.0.0), edited through the
  **Alternative Text** element in each volume's field layout; it can be **Required**.
- Since **5.10**, Alternative Text is pre-filled on upload from XMP/IPTC metadata.
  Treat it as a **draft** — stock captions describe the file, not its meaning here.
- **`asset.getImg()` omits `alt` entirely when it is empty**, as does the `tag()`
  helper for any null attribute (Yii `Html`). No `alt` fails 1.1.1, and screen
  readers may fall back to reading the filename.
- A per-volume **alt translation method** — on multi-site, translate alt per
  language, or a German page reads English alt.

The trap: **alt lives on the asset, but decorative-or-informative belongs to the
placement.** One photo is decoration behind a hero headline and the subject of a
news story. So the template decides:

```twig
{# Decorative here: the adjacent headline carries the meaning #}
<img src="{{ image.url('hero') }}" alt="" width="{{ image.getWidth('hero') }}" height="{{ image.getHeight('hero') }}">

{# Informative: written literally, so the attribute always renders (null prints as "") #}
<img src="{{ image.url }}" alt="{{ image.alt }}">

{# Editor-decided: a "Decorative" lightswitch on the Matrix image entry type (nested entry) #}
<img src="{{ image.url }}" alt="{{ nested.decorative ? '' : image.alt }}">
```

- **Image inside a link that already has text** (a titled card): `alt=""`, or the
  destination is read twice. **Image as the only link content** (logo linking
  home): alt names the destination — `alt="{{ siteName }}"`.
- Requiring alt on a volume of decorative art breeds filler. Require it on
  content-image volumes; hard-code `alt=""` in decorative placements.

## 5. Link text in loops

A listing loop yields twelve "Read more" links, indistinguishable in a screen
reader's link list (2.4.4 Link Purpose (In Context)). Make the title the link
(§3), or complete the control for AT — never via `title`, which is mouse-only:

```twig
<a href="{{ entry.url }}">Read more<span class="visually-hidden">: {{ entry.title }}</span></a>
```

Icon-only links in footer partials need a name: `aria-label="{{ siteName }} on
LinkedIn"` on the `<a>`, `aria-hidden="true"` on the SVG.

## 6. Focus states

Focus styling ships in the front-end build but must also cover markup the build
did not write — CKEditor links, Formie inputs, embedded widgets.

```css
:focus-visible { outline: 3px solid currentColor; outline-offset: 2px; }
.skip-link { position: absolute; left: -9999px; }
.skip-link:focus { left: 1rem; top: 1rem; z-index: 1000; }
html { scroll-padding-top: var(--site-header-height, 5rem); } /* sticky header vs 2.4.11 */
```

Disabling a plugin's bundled CSS (common with Formie) removes its focus styles
too, and a fixed cookie-consent bar is the other usual 2.4.11 (AA) offender —
confirm both in the keyboard pass rather than trusting the CSS.

## 7. Forms via Formie

What Formie 3 renders, read from its `craft-5` branch source:

| Concern | Formie output | Your job |
|---|---|---|
| Label | `<label for>` bound to the input; the "Hidden" position keeps it, visually hidden | Prefer visible labels (3.3.2); never placeholder-only |
| Instructions | `<div id="{id}-instructions">`; input gets `aria-describedby` — **only when Instructions are set** | Put format hints ("DD/MM/YYYY") in Instructions, not the placeholder |
| Required | `required` on the input; the asterisk is `aria-hidden="true"` | Explain the asterisk once, at the top |
| Client-side errors | JS validator sets `aria-invalid="true"` + `aria-errormessage`; message container is `aria-live="polite" aria-atomic="true"` | Messages say how to fix it (3.3.3), not "Invalid" |
| Server-rendered errors | Message renders in that container, but the input gets only an `fui-error` **class** — no `aria-invalid`, no association | Patch via the HTML-tag event below, or keep every rule client-side too |
| Form alerts | Error and success alerts carry `role="alert"` | Keep them — 4.1.3 Status Messages |
| Multi-page | Page title is a `<legend>` in a `<fieldset>` when "Display current page title" is on | Do not re-ask earlier answers (3.3.7 Redundant Entry, A, new in 2.2) |
| Form title | Hard-coded `<h2 class="fui-title">` | Re-level with theme config, or hide it when the page supplies a heading |

```twig
{{ craft.formie.renderForm('contact', { themeConfig: { formTitle: { tag: 'h3' } } }) }}
```

Server-validated failures need their programmatic state back. `context['errors']`
is populated for the input tag, so this is safe globally (module or plugin `init()`):

```php
use verbb\formie\base\FormField;
use verbb\formie\events\ModifyFieldHtmlTagEvent;
use yii\base\Event;

// Server-rendered errors arrive as a CSS class only; expose them (3.3.1, 4.1.2).
Event::on(FormField::class, FormField::EVENT_MODIFY_HTML_TAG, function(ModifyFieldHtmlTagEvent $event) {
    if ($event->key === 'fieldInput' && $event->tag && !empty($event->context['errors'])) {
        $event->tag->attributes['aria-invalid'] = 'true';
    }
});
```

Add `autocomplete` (`email`, `given-name`, …) through each field's **Input
Attributes** setting where it collects the user's own data — 1.3.5 Identify Input
Purpose (AA). In the screen-reader pass, confirm a client-side error is read when
focus returns to the field, not only when it first appears.

## 8. Rich text via CKEditor

Editors write half the markup on a CMS site; constrain it in field settings
rather than hoping for discipline.

- **Heading Levels** is a per-field setting that **defaults to all six**, so
  editors can insert a second `<h1>`. Under a template h1 allow 2–4; under a
  template `<h2>` (inside a Matrix section) 3–4. Craft 5 fields are global, so a
  different range means a different field. Offer visual size as custom **Styles**,
  so "make it smaller" never means "make it an h5".
- **Tables**: header rows/columns come from the Table Row / Table Column menus;
  **Table Cell Properties** exposes Column header / Row header, which set `scope`
  (H63). Captions render as `<figcaption>` *outside* the table by default — set
  `useCaptionElement` for a real `<caption>`, announced on entering the table
  (H39). In the field's *Config options*:

```json
{ "table": {
    "contentToolbar": ["tableRow", "tableColumn", "mergeTableCells",
                       "toggleTableCaption", "tableCellProperties"],
    "tableCaption": { "useCaptionElement": true } } }
```

- **Inline language changes (3.1.2, AA)**: the plugin fills CKEditor's *text part
  language* list from the site's locales; add the `textPartLanguage` toolbar
  button so editors can mark a foreign phrase as `<span lang>`.
- **HTML Purifier runs on save**: a customised `config/htmlpurifier/*.json` must
  keep `scope`, `lang` and `<caption>`. Check the **saved front-end HTML** — the
  editor view shows what was typed, not what survived.

## 9. Language on multi-site Craft

- **`<html lang>` (3.1.1, A)**: `craft.app.language` is the current site's
  language on the front end, so the §2 layout is right per site. A hard-coded
  `lang="en"` in a shared layout fails every other site and voices it wrongly.
- **Language switcher (3.1.2, AA)**: name each language *in* that language and
  mark it, or "Deutsch" is read with English phonetics. `getLocalized()` returns
  the same element on its other sites; site names should be the endonym:

```twig
<nav aria-label="Language">
  <ul>
  {% for localized in entry.getLocalized().all() %}
    <li><a href="{{ localized.url }}" lang="{{ localized.site.language }}"
           hreflang="{{ localized.site.language }}">{{ localized.site.name }}</a></li>
  {% endfor %}
  </ul>
</nav>
```

- **`hreflang` on `<link rel="alternate">` is SEO, not WCAG**: every version lists
  itself and all others (plus optional `x-default`). It does nothing for AT — do both.

## 10. Testing rendered pages

Run against the DDEV site — `ddev describe` prints the URL, normally
`https://<project>.ddev.site`. **Playwright + axe** (`npm install -D @axe-core/playwright`):

```ts
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test('entry template has no detectable violations', async ({ page }) => {
  await page.goto('/news/an-entry');                       // baseURL = DDEV URL
  const { violations } = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice']).analyze();
  expect(violations).toEqual([]);
});
```

**Keep `best-practice` in the tag list.** axe tags `heading-order`,
`page-has-heading-one`, `landmark-one-main`, `region` and `skip-link` as
best-practice only, so a WCAG-only filter silently drops exactly the rules that
catch broken layout/partial composition. If Playwright's browser does not trust
DDEV's mkcert certificate (common in CI), set `ignoreHTTPSErrors: true` in `use`.

**Cypress** (`cypress-axe`): `cy.injectAxe()` after `cy.visit()`, then
`cy.checkA11y(null, { runOnly: { type: 'tag', values: [/* same list */] } })`.

**pa11y-ci** for whole-site sweeps, via `.pa11yci`:

```json
{ "defaults": { "runners": ["axe", "htmlcs"],
                "chromeLaunchConfig": { "args": ["--ignore-certificate-errors"] } },
  "urls": ["https://<project>.ddev.site/", "https://<project>.ddev.site/de/"] }
```

Or take URLs from the live sitemap while testing the local build:
`npx pa11y-ci --sitemap https://www.example.com/sitemap.xml --sitemap-find www.example.com --sitemap-replace <project>.ddev.site`

States still need scripting — open the menu, submit an empty form, step to page 2
of a multi-page form — then the keyboard and screen-reader passes in
[audit-workflow.md](audit-workflow.md). A green run covers the minority of WCAG.

## Sources

- **WCAG 2.2**: [Recommendation](https://www.w3.org/TR/WCAG22/) · Understanding [2.4.11](https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum.html) · [3.1.2](https://www.w3.org/WAI/WCAG22/Understanding/language-of-parts.html) · [3.2.3](https://www.w3.org/WAI/WCAG22/Understanding/consistent-navigation.html) · [3.2.6](https://www.w3.org/WAI/WCAG22/Understanding/consistent-help.html) · [3.3.7](https://www.w3.org/WAI/WCAG22/Understanding/redundant-entry.html) · [4.1.3](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html)
- **W3C techniques**: [G1](https://www.w3.org/WAI/WCAG22/Techniques/general/G1) · [ARIA11](https://www.w3.org/WAI/WCAG22/Techniques/aria/ARIA11) · [H39](https://www.w3.org/WAI/WCAG22/Techniques/html/H39) · [H57](https://www.w3.org/WAI/WCAG22/Techniques/html/H57) · [H58](https://www.w3.org/WAI/WCAG22/Techniques/html/H58) · [H63](https://www.w3.org/WAI/WCAG22/Techniques/html/H63) · WAI tutorials: [decorative images](https://www.w3.org/WAI/tutorials/images/decorative/), [tables](https://www.w3.org/WAI/tutorials/tables/)
- **Craft 5**: [assets & alt](https://craftcms.com/docs/5.x/reference/element-types/assets.html) · [sites & language](https://craftcms.com/docs/5.x/system/sites.html) · 5.10.0 release notes · `ElementInterface::getLocalized()`
- **Plugins**: Formie 3 [theme config](https://verbb.io/craft-plugins/formie/docs/theming/theme-config) and source (`src/base/Field.php`, `src/elements/Form.php`, `validator.js`, branch `craft-5`) · [CKEditor for Craft](https://github.com/craftcms/ckeditor) README and `src/Field.php` · CKEditor 5 table caption and cell-properties docs
- **Testing**: [Playwright](https://playwright.dev/docs/accessibility-testing) · [axe-core tags](https://github.com/dequelabs/axe-core/blob/develop/doc/API.md) · [cypress-axe](https://github.com/component-driven/cypress-axe) · [pa11y-ci](https://github.com/pa11y/pa11y-ci) · [pa11y](https://github.com/pa11y/pa11y) · [DDEV](https://docs.ddev.com/en/stable/users/quickstart/) · hreflang: [Google Search Central](https://developers.google.com/search/docs/specialty/international/localized-versions)
