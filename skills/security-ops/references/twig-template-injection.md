# Twig Template Injection (SSTI)

When an attacker controls template *source* or a template *name*, not just a value inside
one. In Twig that is code execution, not XSS. Twig 3.x and Craft CMS 3/4/5; facts
verified 2026-10-05.

## Contents

- Why Template Source Is Code
- Injection Sinks in Craft
- Dynamic Template Names
- Craft's Twig Sandbox
- Version Floors
- Review Checklist

## Why Template Source Is Code

- OWASP WSTG-INJT-18 defines SSTI as user input "embedded in a template in an unsafe
  manner" (https://wstg.owasp.org/latest/4-Web_Application_Security_Testing/07-Injection/18-Server-side_Template_Injection).
- In Craft, any template can reach `craft.app` - the whole Yii application. Whoever can
  author Twig has close to PHP-level power. Treat the right to write a template the way
  you treat the right to deploy code.
- Outside a sandbox, Twig 3.x still accepts a PHP callable *string* in `filter`, `map`,
  `sort` and `reduce`: passing one only triggers a 3.15 deprecation, and only sandbox
  mode rejects non-closures (twigphp/Twig `src/Extension/CoreExtension.php`,
  `checkArrow`). A function name such as `'system'` in attacker-written Twig is RCE.
- Admin-authored templates count too. CVE-2026-28697 was admin-to-RCE through Twig
  (`craft.app.fs.write()`), fixed in Craft 4.17.0 / 5.9.0
  (https://github.com/craftcms/cms/security/advisories/GHSA-v47q-jxvr-p68x). This is the
  case for `allowAdminChanges` false in production and `enableTwigSandbox` on.

## Injection Sinks in Craft

| Sink | Why it is dangerous | Safe alternative |
|---|---|---|
| `template_from_string(x)` | Craft registers Twig's `StringLoaderExtension` (craftcms/cms `src/web/View.php`), so this is live in every Craft template; plain Twig does not load it | Never pass request data, submissions or editable field text |
| `Craft::$app->getView()->renderString($s)` | renders `$s` as a template; HTML escaping off unless `$escapeHtml` is true | Render a fixed template file and pass the data as variables |
| `renderObjectTemplate($s, $object)` | Craft's docs: "Do not pass user-supplied templates to the `renderObjectTemplate()` function!" (https://craftcms.com/docs/5.x/reference/twig/functions.html) | Fixed object templates authored in config or by trusted admins |
| Posted `redirect` param | Craft renders the redirect as an object template (`Controller::getPostedRedirectUrl()`), which is why `redirectInput()` hashes it | Always `{{ redirectInput('path/{id}') }}`; never build the string from user input (https://craftcms.com/docs/5.x/system/object-templates.html) |
| Entry title formats, URI formats, system message bodies | object templates edited in the CP | Keep CP schema edits off in production; enable the sandbox |

```php
// WRONG - the visitor's text becomes Twig source
$html = Craft::$app->getView()->renderString($request->getBodyParam('message'));

// CORRECT - the template is fixed; the text is data and gets escaped
$html = Craft::$app->getView()->renderTemplate('_emails/contact', [
    'message' => $request->getBodyParam('message'),
]);
```

## Dynamic Template Names

`include`, `embed`, `extends`, `import`, `from` and `source()` all accept a variable
name (https://twig.symfony.com/doc/3.x/functions/include.html). A request-controlled
name lets a visitor render any template under `templates/`, including partials that
were never meant to be reached directly.

```twig
{# WRONG - visitor chooses the template #}
{% include craft.app.request.getQueryParam('layout') %}

{# CORRECT - map input onto a fixed allow-list, with a default #}
{% set layouts = { grid: '_layouts/grid', list: '_layouts/list' } %}
{% include layouts[craft.app.request.getQueryParam('layout')] ?? '_layouts/grid' %}
```

- Twig's filesystem loader once let a name escape the template root (CVE-2022-39261,
  fixed in Twig 3.4.3). Current versions confine names to the configured paths, but an
  allow-list is still the control: it also stops cross-template confusion inside the root.
- Craft routes URLs straight to templates. Any template whose path segment does not
  start with `privateTemplateTrigger` (default `_`) is reachable by URL
  (https://craftcms.com/docs/5.x/reference/config/general.html). Keep partials,
  layouts and email templates under `_`-prefixed names so they cannot be requested
  directly with missing variables.

## Craft's Twig Sandbox

- `enableTwigSandbox` (default `false`, since Craft 5.9.0 and 4.17.0) sandboxes
  user-defined templates (https://craftcms.com/docs/5.x/reference/config/general.html).
  Craft's securing guide notes new projects ship with it on
  (https://craftcms.com/knowledge-base/securing-craft); upgraded projects do not.
- With it off, `renderSandboxedString()` and friends - which Craft's mailer uses for
  system-message subjects and bodies - render **unsandboxed** (craftcms/cms
  `src/web/View.php`, `src/mail/Mailer.php`).
- The allow-list starts from Craft's `src/config/twig-sandbox.php`, merged with your
  `config/twig-sandbox.php`. Add only what authored templates genuinely need.
- A sandbox is defence in depth, not a licence. Twig shipped a long run of sandbox
  bypasses in 2026 (next section), and Craft's own GHSA-vfcw-xv8p-8rj2 (September 2026)
  was a non-admin RCE via a sandbox bypass in the `has some` / `has every` operators.
  Twig's docs add that the sandbox does not protect against resource exhaustion
  (https://twig.symfony.com/doc/3.x/sandbox.html).

```php
// config/general.php
return GeneralConfig::create()
    ->enableTwigSandbox(true)
    ->allowAdminChanges(App::env('CRAFT_ALLOW_ADMIN_CHANGES') ?? false);
```

## Version Floors

From https://github.com/twigphp/Twig/security/advisories (read 2026-10-05):

| Advisory | Affected | Fixed |
|---|---|---|
| CVE-2024-45411 sandbox bypass (high) | <3.14.0 | 3.14.0 |
| CVE-2026-46640 code execution via `_self` macro reference (critical) | 3.15.0 - <3.26.0 | 3.26.0 |
| CVE-2026-46633 code injection via `{% use %}` name (critical) | <3.26.0 | 3.26.0 |
| CVE-2026-46634 `template_from_string()` escapes a SourcePolicy sandbox | 3.9.0 - <3.26.0 | 3.26.0 |
| CVE-2026-47732 and a 3.26.0 regression set (sandbox `__toString`, `column`, cached-template state) | <=3.26.0 | 3.27.0 |

- **Floor: Twig 3.27.0.** Current Craft 5 pins `~3.28.0`
  (https://github.com/craftcms/cms/blob/5.x/composer.json), so a current Craft 5 is above
  it. A Craft 3 or 4 site, or one with a stale `composer.lock`, may not be - check with
  `composer show twig/twig`.
- Twig 3.29 reworked the sandbox API (`Twig\Sandbox\Sandbox`, `render_sandboxed()`) and
  deprecated `include(..., sandboxed)`; custom modules that sandbox their own rendering
  should follow https://twig.symfony.com/doc/3.x/api.html.

## Review Checklist

```bash
# String-to-template sinks
rg -n 'template_from_string\s*\(' templates/
rg -n 'render(String|ObjectTemplate|SandboxedString)\s*\(' modules/ plugins/ src/ --type php

# Template names built from requests
rg -n '(include|embed|extends|import|source)\b[^%}]*craft\.app\.request' templates/

# Callable strings handed to arrow-function filters
rg -n "\|\s*(map|filter|sort|reduce)\(\s*['\"]" templates/

# Sandbox and CP-authoring posture
rg -n 'enableTwigSandbox|allowAdminChanges' config/
```

- [ ] No request data, submission or editable field reaches a string-to-template sink
- [ ] Dynamic template names resolve through an allow-list
- [ ] Partials and email templates sit under `_` names
- [ ] `enableTwigSandbox` on (Craft 4.17+ / 5.9+); `allowAdminChanges` off in production
- [ ] Twig at or above 3.27.0; Craft on its latest patch release

Related: `twig-escaping.md` (values inside a template), `craft-access-control.md`
(who may author templates and system messages).
