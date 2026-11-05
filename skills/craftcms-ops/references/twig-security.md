# Twig Output Security

How Craft's Twig escapes output, which values bypass escaping, and the rules that keep
user input from becoming XSS or template injection. Checked 2026-10-05 against the
[Craft Twig docs](https://craftcms.com/docs/5.x/development/twig.html),
[filters](https://craftcms.com/docs/5.x/reference/twig/filters.html),
[functions](https://craftcms.com/docs/5.x/reference/twig/functions.html), Twig's
[escape filter](https://twig.symfony.com/doc/3.x/filters/escape.html), and
[Securing Craft](https://craftcms.com/knowledge-base/securing-craft).

## Contents

- [The five rules](#the-five-rules)
- [Autoescape: what is on by default](#autoescape-what-is-on-by-default)
- [Escaping by context](#escaping-by-context)
- [Values that are NOT escaped](#values-that-are-not-escaped)
- [CSRF](#csrf)
- [Template injection (SSTI)](#template-injection-ssti)
- [Request input in element queries](#request-input-in-element-queries)
- [Keep Craft patched](#keep-craft-patched)

## The five rules

1. **Never `|raw` anything a visitor could have influenced** - form input, query
   strings, submission data, user profile fields, imported feeds. Craft's guidance:
   never output user-provided content with `raw`, never compile or render it as Twig,
   never parse it for reference tags.
2. **Escape for the context**, not just for HTML: `|e('js')` inside JS strings,
   `|e('url')` for URL components, quoted attributes for attribute values.
3. **Every state-changing form carries `{{ csrfInput() }}`** - async on cached pages.
4. **Rich text is purified on save** (HTML Purifier) because it is printed unescaped.
5. **Untrusted input never reaches a template loader** - no user-chosen `include`
   paths, no `template_from_string`, no `renderObjectTemplate()`.

## Autoescape: what is on by default

Craft enables Twig's **HTML autoescaping** for every `{{ }}` print. Exceptions are
values marked safe (below) and anything passed through `|raw`. In `headlessMode`, site
requests autoescape with the `js` strategy instead.

```twig
{{ entry.title }}                 {# escaped - safe #}
{{ craft.app.request.getParam('q') }}  {# escaped - safe to print #}
{{ userBio|raw }}                 {# NOT escaped - XSS if userBio is user input #}

{% autoescape 'js' %}
  var label = '{{ entry.title }}';  {# every print in this block uses the js strategy #}
{% endautoescape %}
{% autoescape false %}...{% endautoescape %}   {# off - same risk as |raw #}
```

`|raw` only works as the **last** filter in a print tag. Craft's `raw()` *function*
returns a `Markup` object whose safe flag survives being passed into another template
or macro - convenient, and equally dangerous with untrusted input.

## Escaping by context

| Context | Use | Example |
|---------|-----|---------|
| HTML body, quoted attribute | default autoescape (`html`) | `<p title="{{ entry.title }}">` |
| JavaScript string | `\|e('js')` | `var q = '{{ query\|e('js') }}';` |
| URL component (query value, path segment) | `\|e('url')` | `href="/search?q={{ query\|e('url') }}"` |
| CSS value | `\|e('css')` | `style="--accent: {{ colour\|e('css') }}"` |
| Unquoted attribute value / attribute name | `\|e('html_attr')` - better: quote the attribute | |
| Data for front-end JS | JSON in a data attribute | below |

Passing structured data to JS - the data-attribute route needs no `|raw` at all:

```twig
<div id="map" data-config="{{ { lat: entry.lat, lng: entry.lng, label: entry.title }|json_encode }}"></div>
{# JS: JSON.parse(document.getElementById('map').dataset.config) #}
```

If you must inline JSON in a `<script>`, Craft's `|json_encode` defaults to
`JSON_HEX_TAG|JSON_HEX_AMP|JSON_HEX_QUOT` on HTML responses, which hex-escapes `<`, `&`,
and `"` inside strings so a value can't close the `<script>` - that is what makes
`{{ data|json_encode|raw }}` acceptable there. Never pass custom `options` that drop
those flags.

## Values that are NOT escaped

These return safe `Markup`, so autoescape skips them. Fine for trusted content; a
problem the moment untrusted text flows in.

| Source | Why it's unescaped | Guard |
|--------|-------------------|-------|
| CKEditor / Redactor field values | `HtmlFieldData` extends Twig `Markup` | Keep the field's **Purify HTML** on ([ckeditor.md](ckeditor.md)); never let front-end forms write to these fields unpurified |
| `\|md` / `\|markdown` | Output is trusted HTML | Docs: don't use it on user-submitted content. Escape first (`text\|e\|md`) or use its encode argument |
| `\|purify` | HTML Purifier output | This is the fix for user HTML: `{{ submission.message\|purify }}` (configs in `config/htmlpurifier/*.json`) |
| `\|parseRefs` | Expands `{entry:123:url}` reference tags | Never on user input |
| `tag()` with `html:` | `text:` is encoded, `html:` is not | Use `text:` for anything dynamic |
| `\|attr` filter | Its **input** is an HTML tag string | Only feed it trusted markup; attribute values you pass are encoded |
| `svg()` | Sanitizes assets and raw markup, **not** file paths/aliases | Never build the path from input |
| `csrfInput()`, `actionInput()`, `redirectInput()`, `hiddenInput()` | Generate their own escaped markup | Safe |

## CSRF

`enableCsrfProtection` is on by default (token name `CRAFT_CSRF_TOKEN`). Every POST to
a Craft or plugin controller needs the token:

```twig
<form method="post">
  {{ csrfInput() }}                       {# async on cached pages: csrfInput({ async: true }) #}
  {{ actionInput('users/save-user') }}
  {{ redirectInput('account/thanks') }}    {# hashed - visitors can't tamper with the target #}
  ...
</form>
```

- `{{ csrfInput({ async: true }) }}` (Craft 5.1+) fetches the token over Ajax, so the
  page HTML is cacheable; `asyncCsrfInputs` makes that the default.
- A plain `csrfInput()` must never end up in a cached page - a cached token belongs to
  whoever primed the cache. Since 5.3 Craft sends no-cache headers whenever it
  generates a token. With Blitz use async inputs or `craft.blitz.csrfInput()`
  ([blitz.md](blitz.md#dynamic-content-on-cached-pages)); Formie has its own refresh
  ([formie.md](formie.md#csrf-and-statically-cached-pages)).
- JS requests: read the name from `craft.app.config.general.csrfTokenName` and the value
  from `craft.app.request.getCsrfToken()`, send as a header or body param.
- Never set `enableCsrfProtection` to `false` to make a cached form "work".

Source: [forms](https://craftcms.com/docs/5.x/development/forms.html), [functions](https://craftcms.com/docs/5.x/reference/twig/functions.html).

## Template injection (SSTI)

Twig is a language; treating input as a template hands the visitor code execution.

- Never: `{{ include(userPath) }}`, `{{ source(userPath) }}`,
  `{{ template_from_string(userInput) }}`, `renderObjectTemplate(userInput, ...)`,
  `{% include 'cards/' ~ craft.app.request.getParam('style') %}`. Map input to an
  allowlist instead: `{% set style = param in ['grid', 'list'] ? param : 'grid' %}`.
- Craft docs, on `renderObjectTemplate()`: don't pass user-supplied templates.
- **`enableTwigSandbox`** (Craft 4.17+ / 5.9+, default off, enabled in the starter
  project's `config/general.php`) sandboxes user-authored templates such as System
  Messages. Turn it on in existing projects.
- Production: `allowAdminChanges => false` and `devMode => false`. Many Craft Twig RCE
  advisories need admin or CP access to plant a template; locking schema changes and
  limiting admin accounts shrinks that surface.

## Request input in element queries

Query params from the request can be arrays or Craft query syntax (`not 123`,
`>= 5`), so passing them straight into an element query changes its meaning. Validate:

```twig
{% set id = craft.app.request.getQueryParam('id') %}
{% if id is not numeric %}{% exit 404 %}{% endif %}
{% set item = craft.entries().id(id).one() %}
```

## Keep Craft patched

Craft has shipped a steady run of Twig/SSTI and RCE fixes - e.g. CVE-2023-41892
(critical RCE, fixed 4.4.15), CVE-2025-32432 (critical RCE, fixed 3.9.15 / 4.14.15 /
5.6.17), a 2026 sandbox and SSTI series fixed in 4.17.0 / 5.9.0, and further high-severity
Twig RCE fixes through the 5.10.x line. List:
[craftcms/cms security advisories](https://github.com/craftcms/cms/security/advisories)
(checked 2026-10-05).

Practical floor: stay on the **latest Craft 5 patch release**. Craft 4's security
support ended 30 April 2026 and Craft 3's on 30 April 2024
([supported versions](https://craftcms.com/knowledge-base/supported-versions)) - an
unpatched Craft 3/4 site is a reason to schedule the upgrade ([upgrades.md](upgrades.md)),
not a configuration problem.
