# Twig Output Escaping (XSS)

How Twig escapes output, where autoescape is not enough, and what `|raw` really promises.
Twig 3.x and Craft CMS 3/4/5. Facts verified 2026-10-05 against twig.symfony.com and
craftcms.com; re-check version floors before quoting them.

## Contents

- How Autoescape Works
- Context Strategies
- The raw Filter
- Craft Output Helpers
- Escaping Pitfalls
- Review Checklist

## How Autoescape Works

- Twig's `autoescape` option defaults to the `html` strategy
  (https://twig.symfony.com/doc/3.x/api.html). Every `{{ expression }}` is HTML-escaped
  unless the value is already marked safe.
- Craft keeps that default: "Auto-escaping is enabled by default in Craft templates"
  (https://craftcms.com/docs/5.x/development/twig.html). Craft does not use Twig's
  filename-based `name` strategy, so `.twig` and `.html` templates both escape as HTML;
  only headless-mode site requests switch the default to `js` (craftcms/cms
  `src/web/View.php`).
- Autoescape skips values that are `Twig\Markup` objects or come from a function/filter
  declared `is_safe` (https://twig.symfony.com/doc/3.x/advanced.html). That is the whole
  attack surface: XSS in a Twig app is almost always "something marked safe that was not".
- The `html` strategy is right for element bodies and **quoted** attribute values only.
  Every other context needs an explicit strategy, autoescape or not
  (https://twig.symfony.com/doc/3.x/templates.html).

## Context Strategies

Strategies from https://twig.symfony.com/doc/3.x/filters/escape.html, mapped to the
OWASP output-encoding rules
(https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html):

| Output context | Write | Why |
|---|---|---|
| Element body | `{{ value }}` | autoescape `html` covers it |
| Quoted attribute | `<a title="{{ value }}">` | `html` covers it - keep the quotes |
| Unquoted attribute / dynamic attribute name | `{{ value\|e('html_attr') }}` | `html` does not stop space or `=` breaking out; quoting is cheaper |
| JavaScript string | `var q = '{{ value\|e('js') }}';` | `html` leaves `\` and newlines live inside JS |
| Data for scripts | `<div data-config="{{ data\|json_encode }}">` then `JSON.parse(el.dataset.config)` | the attribute is HTML-escaped; no `\|raw` inside `<script>` |
| CSS value | `{{ value\|e('css') }}` | `css` escapes everything but alphanumerics |
| URL query parameter | `?q={{ value\|e('url') }}` | for parameter values only, never a whole URL |
| Whole URL from users | validate the scheme server-side, then `{{ url }}` | no strategy blocks `javascript:` |

Two traps in that table deserve their own line:

- **`{{ data|json_encode|raw }}` inside `<script>` is XSS.** A string containing
  `</script>` ends the block. Use the data-attribute pattern above, or escape each
  scalar with `e('js')`.
- **`e('url')` encodes a value, it does not validate a link.** For a user-supplied URL,
  allow only `http`/`https` before it reaches the template; PHP's `FILTER_VALIDATE_URL`
  does not check the scheme either (https://www.php.net/manual/en/filter.constants.validation.php).

## The raw Filter

- `|raw` "marks the value as being 'safe'" and only works as the **last** filter applied
  (https://twig.symfony.com/doc/3.x/filters/raw.html). It disables escaping; it does not
  sanitise anything.
- Rule: `|raw` is acceptable only on HTML your own code or a trusted author produced.
  Never on request input, form submissions, user profile fields, search terms, or a
  plain-text field that front-end users can write.

```twig
{# WRONG - reflected XSS: the search term is attacker-controlled #}
<p>Results for {{ craft.app.request.getQueryParam('q')|raw }}</p>

{# CORRECT - let autoescape do its job #}
<p>Results for {{ craft.app.request.getQueryParam('q') }}</p>

{# CORRECT - user-supplied HTML that must render: purify, never raw #}
{{ submission.bio|purify }}
```

- `{% autoescape false %}` blocks are `|raw` for every expression inside them - review
  them as such (https://twig.symfony.com/doc/3.x/tags/autoescape.html).
- `source()` returns template source **unescaped** and should only receive trusted names
  (https://twig.symfony.com/doc/3.x/functions/source.html).

## Craft Output Helpers

Verified against https://craftcms.com/docs/5.x/reference/twig/filters.html and
craftcms/cms `src/web/twig/Extension.php`:

| Helper | Escaped? | Safe use |
|---|---|---|
| `\|purify` | output is HTML Purifier-cleaned, marked safe | user-supplied HTML that must render; configs live in `config/htmlpurifier/` |
| `\|markdown` / `\|md` | output marked safe, **not escaped** | Craft's docs: never on user-submitted content unless escaped first or `encode` is true - `{{ comment\|markdown(encode=true) }}` |
| `attr()` / `\|attr` | attribute values HTML-encoded | building attribute lists from data |
| Rich text (CKEditor) fields | returns `Twig\Markup` - prints unescaped **without** `\|raw` | trusted-author content only; front-end-submitted rich text needs `\|purify` |
| `raw()` function | same as `\|raw` | same rule as `\|raw` |

The CKEditor row surprises reviewers: no `|raw` appears in the template, yet the output
is unescaped (`craft\ckeditor\data\FieldData` extends `HtmlFieldData`, which extends
`Twig\Markup`). Where untrusted users can write to a rich-text field - a front-end entry
form, a Formie rich-text field - the template must purify it.

## Escaping Pitfalls

- **Custom `is_safe` declarations.** A Twig extension in a Craft module or plugin that
  registers `['is_safe' => ['html']]` promises its output is already escaped. If the
  function interpolates input without escaping, every call site is XSS. Twig itself
  shipped this bug: `twig/markdown-extra` and `cssinliner-extra` declared
  `is_safe => ['all']` (GHSA-jv8m-2544-3pg3) and `spaceless` marked output safe
  (GHSA-4j38-f5cw-54h7), both fixed in Twig 3.26.0
  (https://github.com/twigphp/Twig/security/advisories).
- **`??` lost escaping** in Twig 3.16.0-3.18.x (CVE-2025-24374, fixed 3.19.0). Current
  Craft 5 pins Twig `~3.28.0`; a Craft 4 site frozen on old dependencies may not.
- **Double escaping is a smell, not a bug to fix with `|raw`.** If `&amp;amp;` appears,
  find where the value was escaped early (often in PHP) and stop escaping there.
- **Escaping happens per context, once, at output.** Values escaped for HTML and then
  dropped into JS or a URL are still exploitable.
- **Plain PHP views** (a module rendering without Twig) need
  `htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8')`; those are the PHP 8.1+
  default flags, written out so 8.0 code behaves the same
  (https://www.php.net/manual/en/function.htmlspecialchars.php).

## Review Checklist

```bash
# Every raw output - each needs a reason the value is trusted
rg -n '\|\s*raw\b' templates/

# Escaping switched off for a whole block
rg -n '\{%-?\s*autoescape\s+false' templates/

# Request data reaching output - confirm no raw/markdown/autoescape-false in the chain
rg -n 'craft\.app\.request\.(get\w*Param|getParam)' templates/

# Markdown on user content without encode=true
rg -n '\|\s*(markdown|md)\b' templates/

# json_encode inside script blocks (look for |raw beside it)
rg -n 'json_encode\s*\|\s*raw' templates/

# Custom extensions declaring safe output
rg -n "is_safe" modules/ plugins/ src/ --type php
```

- [ ] Every `|raw` value traced to a trusted producer
- [ ] No request parameter, submission or user field reaches `|raw`, `|markdown` (without `encode`), or an `autoescape false` block
- [ ] JS, CSS, URL and unquoted-attribute contexts use the matching `e()` strategy
- [ ] Front-end-writable rich text is purified
- [ ] Custom `is_safe` functions escape their own inputs
- [ ] Twig is at or above the current advisory floor (`composer show twig/twig`)

Related: `twig-template-injection.md` (when the template itself is attacker-controlled),
`secure-headers.md` (CSP as the second line of defence).
