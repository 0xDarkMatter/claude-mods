# CKEditor Fields

The first-party CKEditor plugin (`craftcms/ckeditor`) is Craft's rich-text field and the
replacement for the retired Redactor. Versions (Packagist, 2026-10-05):

| Plugin line | Craft | Config model |
|-------------|-------|--------------|
| **CKEditor plugin 5.x** (5.8.0) | Craft 5.10+ | **Per-field** settings; optional files in `config/ckeditor/` (5.3+) |
| 4.x (4.11.x) | Craft 5 | Global configs under Settings → CKEditor (Project Config `ckeditor.configs`); nested entries introduced in 4.0 |
| 3.x | Craft 4 | Global configs |

Source unless noted: [craftcms/ckeditor README + CHANGELOG](https://github.com/craftcms/ckeditor).

## Contents

- [Configuring a field](#configuring-a-field)
- [HTML Purifier and output](#html-purifier-and-output)
- [Nested entries (Craft 5)](#nested-entries-craft-5)
- [Converting from Redactor or Matrix](#converting-from-redactor-or-matrix)
- [Upgrading 4.x to 5.x](#upgrading-4x-to-5x)

## Configuring a field

On 5.x everything lives on the field: toolbar, the **Config options** (JSON, or a JS
object body), and **Custom Styles** CSS. Since 5.3 both can point at files in
`config/ckeditor/`, which is the version-controllable choice for an agency - one file
reused by every "body copy" field instead of hand-edited JSON in each field's settings.
On 4.x and 3.x the same settings live in named global configs that fields select.

Custom styles: declare them with CKEditor's `style.definitions` option and ship matching
CSS scoped to `.ck.ck-content` so the editor previews them; the front end needs the same
classes in your site CSS.

Keep toolbars small. Every extra button (tables, font colours, inline styles) is markup
your front end must style and your editors will use creatively.

## HTML Purifier and output

Each field has a **Purify HTML** setting that selects an HTML Purifier config from
`config/htmlpurifier/*.json` (new projects ship `Default.json`). Purification happens
on save. Leave it on: Craft's security guide says to keep "Purify HTML?" enabled -
purify before storage, escape before output
([securing Craft](https://craftcms.com/knowledge-base/securing-craft)).

Output is **not escaped** by Twig: the field value is an `HtmlFieldData` object, which
is Twig `Markup`. So `{{ entry.body }}` prints HTML - correct for editor content,
dangerous if a front-end form ever writes into that field. Details:
[twig-security.md](twig-security.md).

## Nested entries (Craft 5)

CKEditor fields can hold **nested entries** (add entry types to the field). Editors
place them inline - a pull quote, an image with caption, a CTA - between paragraphs.

**Rendering, simple:** `{{ entry.body }}` renders the HTML and each nested entry through
its element partial: `templates/_partials/entry/<entryTypeHandle>.twig`, which receives
`entry`. The `_partials` root is the `partialTemplatesPath` setting; since Craft 5.6 a
generic `_partials/entry.twig` is the fallback
([rendering elements](https://craftcms.com/docs/5.x/system/elements.html#rendering-elements)).

```twig
{# templates/_partials/entry/pullQuote.twig #}
<blockquote class="pull-quote">
  <p>{{ entry.quote }}</p>
  {% if entry.attribution %}<cite>{{ entry.attribution }}</cite>{% endif %}
</blockquote>
```

**Rendering, controlled:** iterate the field as chunks (plugin 4.1+) when the wrapper
markup must differ:

```twig
{% for chunk in entry.body %}
  {% if chunk.type == 'markup' %}
    <div class="prose">{{ chunk }}</div>
  {% else %}
    {{ chunk.entry.render({ variant: 'inline' }) }}
  {% endif %}
{% endfor %}
```

The same partials serve Matrix nested entries (`entry.matrixField.render()`, see
[element-queries.md](element-queries.md#nested-entries-matrix-in-craft-5)) - write one
partial per entry type and share it. Inside partials, use `.eagerly()` for relations
(`entry.image.eagerly().one()`), as the README advises: a long article with ten image
entries otherwise runs ten image queries.

## Converting from Redactor or Matrix

| From | Command | Notes |
|------|---------|-------|
| Redactor fields | `php craft ckeditor/convert/redactor` | Converts field settings + configs; content is HTML and carries over. Added in plugin 3.1 |
| A Matrix "text + blocks" field | `php craft ckeditor/convert/matrix <fieldHandle>` | Generates a **content migration**; run it with `php craft up`. Plugin 4.2+ |

Run conversions on a local copy of production data first (`ddev pull`, see
[ddev.md](ddev.md)), commit the Project Config and migration, then deploy. The Matrix
conversion is the classic Craft 5 "longform content" move - it keeps the blocks as
nested entries inside one rich-text field.

## Upgrading 4.x to 5.x

Plugin 5.x needs Craft 5.10+, and:

- **Global configs are dropped** - migrated into each field's own settings
  (`m260220_182920_drop_cke_configs`). Re-check fields that shared a config; consider
  moving the result into `config/ckeditor/` files.
- Third-party CKEditor plugins are now registered as modules - **a custom CKEditor plugin
  package breaks** until updated.
- Adds fullscreen, a new link modal and advanced link fields, images as nested entries,
  and a guard against deleting referenced elements (5.6).
- 5.7.0 fixed a high-severity authorization bypass (GHSA-jcjm-q9x2-72xv) - don't run 5.0-5.6.

Upgrade in its own commit, separate from a Craft minor bump, so a regression is
attributable.
