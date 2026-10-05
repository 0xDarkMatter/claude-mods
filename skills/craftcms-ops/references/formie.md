# Formie (Forms)

Formie (`verbb/formie`) is the CP form builder: fields, notifications, submissions,
spam protection, and integrations. Versions: Formie 3 for Craft 5 (current stable),
2.x for Craft 4, 1.x for Craft 3; **Formie 4 is in beta** for Craft 5 (4.0.0-beta.16,
Packagist 2026-10-05) and changes several APIs below - flagged where it matters.
Source unless noted: [Formie 3 docs](https://verbb.io/craft-plugins/formie/docs/).

## Contents

- [Rendering](#rendering)
- [Front-end assets](#front-end-assets)
- [Theming](#theming)
- [Spam protection](#spam-protection)
- [CSRF and statically cached pages](#csrf-and-statically-cached-pages)
- [Integrations and the queue](#integrations-and-the-queue)
- [Submissions and data retention](#submissions-and-data-retention)
- [Formie 4 changes to plan for](#formie-4-changes-to-plan-for)

## Rendering

```twig
{# Simplest: the whole form, with Formie's templates, CSS, and JS #}
{{ craft.formie.renderForm('contact') }}

{# With options #}
{{ craft.formie.renderForm('contact', {
    fieldNamespace: 'contact',
    themeConfig: { resetClasses: true },
}) }}

{# Fetch the form element first (e.g. picked via a Forms field) #}
{% set form = craft.formie.forms.handle('contact').one() %}
{{ craft.formie.renderForm(form) }}
```

Finer-grained: `craft.formie.renderPage(form, page)` (includes captchas and buttons)
and `craft.formie.renderField(form, field)`. Render options include `fieldNamespace`,
`sessionKey`, `themeConfig`, `renderCss`, `renderJs`. Source:
[available variables](https://verbb.io/craft-plugins/formie/docs/template-guides/available-variables).

Editors usually pick a form with Formie's **Forms field** on an entry type, so templates
render `entry.form.one()` rather than a hard-coded handle - forms get renamed.

## Front-end assets

Each **Form Template** (Settings → Form Templates) controls output:

| Setting | Options |
|---------|---------|
| Output CSS / Output Theme (CSS) | Page Header, Inside Form, Manual |
| Output Base JavaScript / Output Theme (JS) | Page Footer, Inside Form, Manual |

Manual placement: `{{ craft.formie.renderFormCss(form) }}` and
`{{ craft.formie.renderFormJs(form) }}`. When the form markup itself comes from a cache
or custom rendering, call `{% do craft.formie.registerAssets(form) %}` **before** the
`<form>` so Craft still registers the CSS/JS. For forms injected after load (Ajax,
Sprig, SPA), load the bundles once with `craft.formie.renderCss(true)` /
`renderJs(true)` and initialise the injected form from JS (`initForms()` /
`initForm($form)`, `onFormieInit` event).

Formie's JS is about 20 KB gzipped, deferred, with per-field JS lazy-loaded and forms
initialised only when visible. If you use your own design system, turn off the theme
CSS (keep the layout CSS) rather than overriding it rule by rule.

## Theming

**Theme Config is the recommended route** in Formie 3: per-component `resetClass`, `tag`,
and `attributes`, set in plugin config, in `renderForm` options, or via a PHP event (in
increasing precedence). `resetClasses: true` strips every `fui-*` class but keeps the
accessibility and JS hook attributes:

```twig
{{ craft.formie.renderForm('contact', {
    themeConfig: {
        resetClasses: true,
        field: { attributes: { class: 'form-field' } },
        fieldInput: { attributes: { class: 'input' } },
        submitButton: { attributes: { class: 'btn btn-primary' } },
    },
}) }}
```

Full template overrides (Form Templates → Use Custom Template → Copy Templates) are the
heavy option: you own those templates through every Formie upgrade. Prefer Theme Config
unless the markup structure itself must change. Source:
[theming](https://verbb.io/craft-plugins/formie/docs/theming/overview).

## Spam protection

Built-in captcha integrations (Settings → Captchas): Honeypot, Javascript (with a
`minTime` minimum-submit-time option), Duplicate, plus third-party reCAPTCHA (v2
checkbox/invisible, v3, Enterprise), hCaptcha, Cloudflare Turnstile, Friendly Captcha,
Akismet, CleanTalk, OOPSpam, and others. Spam settings: `saveSpam`, `spamLimit`
(default 500 kept), `spamBehaviour`, `spamKeywords` (supports `[ip:]` and `[match:]`
rules), `spamEmailNotifications`. Source:
[spam protection](https://verbb.io/craft-plugins/formie/docs/feature-tour/spam-protection).

A sensible default stack: Honeypot + Javascript (with `minTime`) everywhere, one
interactive or invisible captcha (Turnstile or reCAPTCHA v3) only on forms that
still get spam - every third-party captcha adds a script, cookies, and a consent question.

## CSRF and statically cached pages

A form on a Blitz-cached page carries **someone else's** CSRF token and stale captcha
tokens (notably the Javascript and Duplicate captchas). Formie 3 fixes this in JS - there
is no Twig `refreshTokens` helper:

```twig
{% js %}
document.addEventListener('onFormieInit', (event) => {
    Formie.refreshForCache(event.detail.formId);   // fetches fresh CSRF + captcha tokens
});
{% endjs %}
```

Source: [cached forms](https://verbb.io/craft-plugins/formie/docs/template-guides/cached-forms).
Formie 4 does this automatically with Blitz (`staticCacheRefreshOnLoad` otherwise).
Never disable Craft's CSRF protection to "fix" cached forms; general CSRF rules are in
[twig-security.md](twig-security.md), Blitz's own helpers in [blitz.md](blitz.md).

## Integrations and the queue

Integration categories: Address Providers, Automations (Zapier, Make, n8n, generic web
request - this is where "webhooks" live), Captchas, CRM, Elements (create entries/users
from submissions), Email Marketing, Help Desk, Messaging, Miscellaneous, Payments.

`useQueueForNotifications` and `useQueueForIntegrations` default to **true** - email
and CRM pushes happen in queue jobs, not during the submit request. Consequence: if the
production queue isn't running, submissions save but **no emails go out**. That is the
most common "Formie stopped sending email" root cause; see
[performance.md](performance.md#queue).

## Submissions and data retention

Submissions are elements (searchable, exportable, viewable per form). Retention is set
per form (minutes to years); prune with `php craft formie/gc/prune-data-retention-submissions`.
Sensitive fields can be encrypted. Incomplete multi-page submissions are removed after
`maxIncompleteSubmissionAge` (default 30 days). Set retention deliberately for privacy
compliance, and not shorter than your queue's worst-case backlog - a pruned submission
can't be delivered by a job still waiting to run.

## Formie 4 changes to plan for

From the [v3 → v4 upgrade guide](https://verbb.io/craft-plugins/formie/docs/v4/get-started/upgrading-from-v3)
(beta, Craft 5):

- Honeypot/Javascript/Duplicate captchas become global **Submission Guards**.
- Static-cache token refresh is automatic with Blitz; the custom JS above goes away.
- Asset API: `formAssets()` / `browserAssets()` replace `renderFormCss`/`renderFormJs`/
  `renderCss`/`renderJs`; location values become `page-header`, `page-footer`,
  `inside-form`, `manual`.
- Default CSS class prefix `fui-` becomes `formie-` - CSS targeting `fui-*` breaks
  unless `compatibilityMode` (default on) bridges it.
- Submission state moves from the session to the database.

Don't start production work on the beta; do avoid building new custom CSS on `fui-*`
class names you will have to rename.
