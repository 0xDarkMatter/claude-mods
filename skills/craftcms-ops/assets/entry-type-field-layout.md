# Content-modeling starter - Craft 5 (section + entry type + Matrix-as-entries)

A known-good shape for modeling a "flexible content page" in Craft 5. Adapt the handles.
Craft 5 stores this in **Project Config** (`config/project/*.yaml`) - build it in the
Control Panel, then commit the generated YAML. This file documents the *intended shape*;
it is not itself applied.

## Target structure

```
Section: "Pages"  (type: Structure - nestable, ordered)
└── Entry Type: "page"
    ├── Field: title            (built-in)
    ├── Field: heading          (Plain Text, global, reusable)
    ├── Field: seoDescription   (Plain Text)
    └── Field: body             (Matrix - Craft 5: stores NESTED ENTRIES)
        ├── Entry Type: "richText"   → field: text   (CKEditor)
        ├── Entry Type: "imageBlock" → field: image  (Assets, limit 1)
        └── Entry Type: "callout"    → field: body   (Plain Text), style (Dropdown)
```

Key Craft 5 facts baked into this shape:

- **Matrix `body` holds entries, not "blocks".** Each nested entry has an **entry type**
  (`richText`, `imageBlock`, `callout`). Branch on `block.type.handle` in Twig.
- **Fields are global.** `heading`, `text`, `image` etc. are defined once and reused across
  any field layout. Reuse the same `text` field in multiple entry types rather than cloning.
- An entry type can be **shared across sections** with a per-section alias (name/handle
  override) if you want the same shape exposed in, say, both "Pages" and "Landing Pages".
- `seoDescription` exists so SEOmatic's **Content SEO** for the section can map it to the
  meta description - editors fill one obvious field, no SEO Settings field needed.

## Rendering it (the section's entry template)

```twig
{# templates/pages/_entry.twig - set as the Pages section's template.
   Craft routes the URI and provides `entry`; don't re-query it by URL segment
   (that breaks on nested Structure URIs and costs a query). #}
{% extends '_layouts/base' %}

{% block content %}
  <h1>{{ entry.heading ?: entry.title }}</h1>

  {# body is a nested-entry query: eager-load the images inside it in the same call #}
  {% for block in entry.body.with(['image']).all() %}
    {% switch block.type.handle %}
      {% case 'richText' %}
        <div class="prose">{{ block.text }}</div>
      {% case 'imageBlock' %}
        {% set img = block.image|first %}
        {% if img %}<figure><img src="{{ img.url }}" alt="{{ img.alt }}" width="{{ img.width }}" height="{{ img.height }}"></figure>{% endif %}
      {% case 'callout' %}
        <aside class="callout callout--{{ block.style.value }}">{{ block.body }}</aside>
    {% endswitch %}
  {% endfor %}
{% endblock %}
```

On larger builds replace the `switch` with element partials - `{{ entry.body.render() }}`
plus one `templates/_partials/entry/<entryTypeHandle>.twig` per entry type - see
[element-queries.md](../references/element-queries.md#nested-entries-matrix-in-craft-5).

## Project Config notes

- After creating the above in the CP, the schema lands in `config/project/` as YAML.
  Commit it. On deploy, `php craft up` applies it.
- Don't hand-edit Project Config YAML for structural changes - make them in the CP and let
  Craft serialize, to keep UIDs consistent.
- Environment-specific values (asset base URLs, API keys) belong in `.env` /
  `config/general.php`, never in Project Config.
