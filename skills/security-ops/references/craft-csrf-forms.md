# Craft CSRF and Front-End Forms

CSRF tokens, hashed hidden inputs, static caching, and Formie - the front-end form surface
of a Craft site. Craft CMS 3/4/5 (version notes inline); facts verified 2026-10-05 against
craftcms.com/docs/5.x and craftcms/cms source.

## Contents

- How Craft Enforces CSRF
- Every POST Form
- Hashed Inputs
- Ajax and Headless Requests
- Static Caching
- Formie
- Turning CSRF Off
- Review Checklist

## How Craft Enforces CSRF

- `enableCsrfProtection` defaults to `true`; tokens travel in a hidden input named by
  `csrfTokenName` (default `CRAFT_CSRF_TOKEN`)
  (https://craftcms.com/docs/5.x/reference/config/general.html).
- Craft "requires a valid CSRF token for any POST requests" to controller actions -
  including actions that allow anonymous access
  (https://craftcms.com/docs/5.x/extend/controllers.html). The check runs in
  `craft\web\Controller::beforeAction()`, before the anonymous-access gate.
- `enableCsrfCookie` (default `true`) keeps the token in a cookie; `false` keeps it in
  the PHP session, which the docs call more secure at the cost of starting a session on
  every page that renders a form.
- GraphQL requests do not use CSRF tokens at all
  (https://craftcms.com/docs/5.x/development/forms.html) - their protection is the
  bearer token and schema scope (`craft-graphql-security.md`).
- OWASP's CSRF guidance: SameSite cookies help but do not replace a token
  (https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html).
  Set `sameSiteCookieValue` to `'Lax'` as a second layer, not instead of tokens.

## Every POST Form

`csrfInput()` "must" be included in each form that makes a POST request
(https://craftcms.com/docs/5.x/reference/twig/functions.html):

```twig
<form method="post">
  {{ csrfInput() }}
  {{ actionInput('users/save-user') }}
  {{ redirectInput('account/thanks') }}
  ...
</form>
```

- `actionInput()` is a plain hidden input naming the route. It is **not** hashed - the
  controller's own checks decide whether the visitor may call it.
- A form without `csrfInput()` fails with a 400 on submit. If someone "fixes" that by
  disabling validation, the review finding is the disablement, not the missing input.

## Hashed Inputs

| Helper | What the hash protects |
|---|---|
| `redirectInput(url)` | renders `<input name="redirect" value="{{ url\|hash }}">`. Craft validates it with `getValidatedBodyParam('redirect')` and then renders it as an **object template** (`Controller::getPostedRedirectUrl()`), so an unhashed redirect would be template injection as well as an open redirect |
| `\|hash` on any hidden value | prepends an HMAC keyed by the security key; read it back with `craft.app.request.getValidatedBodyParam('name')`, which throws a 400 on tampering |

Limits, from https://craftcms.com/docs/5.x/reference/twig/filters.html:

- "Hashes are not a suitable alternative to CSRF tokens or authentication."
- "Do not hash sensitive data" - the value stays readable in the page source.
- Rotating the security key invalidates every outstanding hash.
- Never feed user input into the string given to `redirectInput()`
  (https://craftcms.com/docs/5.x/system/object-templates.html): `redirectInput('search?q=' ~ q)`
  makes the visitor's text part of an object template.

Hidden inputs that are **not** hashed are user input. A front-end entry form that hides a
field does not protect it: Craft's docs say hiding or omitting fields "is not enough"
(https://craftcms.com/docs/5.x/reference/controller-actions.html). See
`craft-access-control.md` for field-level tamper protection.

## Ajax and Headless Requests

- Send the token in an `X-CSRF-Token` header or in the body under `csrfTokenName`
  (https://craftcms.com/docs/5.x/development/forms.html). The docs' pattern embeds
  `craft.app.request.getCsrfToken()` and `craft.app.config.general.csrfTokenName` in
  data attributes and adds `Accept: application/json`.
- From a statically cached or decoupled front end, fetch a fresh token from
  `GET /actions/users/session-info` with `Accept: application/json`; it returns
  `csrfTokenValue` (plus `csrfTokenName` on Craft 5) and starts a guest session
  (https://craftcms.com/docs/5.x/reference/controller-actions.html). Available since
  Craft 3.4.0.

## Static Caching

"By generating and outputting a CSRF token into HTML, the page can no longer be safely
cached" (https://craftcms.com/docs/5.x/development/forms.html). A token baked into a
cached page is served to every visitor: forms break once it expires, and every visitor
shares one token.

| Setup | Fix |
|---|---|
| Craft 4.9+ / 5.1+ | `{{ csrfInput({ async: true }) }}`, or `asyncCsrfInputs` on globally (site requests only). The input fetches its token over Ajax, one request per page, and the page stays cacheable |
| Blitz static cache | `{{ craft.blitz.csrfInput() }}` - Blitz injects the field via Ajax (https://putyourlightson.com/plugins/blitz) |
| Craft 3, no Blitz | exclude form pages from the cache, or fetch `/actions/users/session-info` and inject the token in JS |
| Template `{% cache %}` blocks | keep `csrfInput()` outside the block (a non-async token sends no-cache headers since 5.3.0) |

Static caching also bypasses Twig access tags: a page served from the static cache never
runs `{% requireLogin %}` or `{% requirePermission %}`, because Craft never renders it.
Never statically cache a page whose template relies on those tags.

## Formie

Verbb's Formie (https://verbb.io/craft-plugins/formie/docs) renders its own CSRF input:

- Cached pages: call `Formie.refreshForCache()` - for example
  `document.addEventListener('onFormieInit', e => e.detail.formie.refreshForCache(e.detail.formId))`
  - which fetches `actions/formie/forms/refresh-tokens` and swaps in a fresh token and
  captcha tokens (https://verbb.io/craft-plugins/formie/docs/template-guides/cached-forms).
  The token "needs to be unique per-request".
- `enableCsrfValidationForGuests` (default `true`) - setting it `false` disables CSRF for
  guest submissions. Leave it on; a cached-page token problem is solved with
  `refreshForCache()`, not by dropping validation.
- Formie also skips CSRF for its own API action and for previews; that is by design.
- File-upload fields store files in an asset volume - make that volume private
  (`craft-uploads-assets.md`).
- Spam is not CSRF: enable Formie's captchas (honeypot, JavaScript, Duplicate, or a
  third-party captcha) for public forms.

## Turning CSRF Off

```php
// Only for a webhook that authenticates by signature instead
public function beforeAction($action): bool
{
    if ($action->id === 'receive-webhook') {
        $this->enableCsrfValidation = false;
    }
    return parent::beforeAction($action);  // skipping this skips CSRF AND the anonymous gate
}
```

- Craft's docs: "Only disable CSRF validation when you have some other means of
  validating" the request (https://craftcms.com/docs/5.x/extend/controllers.html). For a
  webhook that means verifying an HMAC signature with `hash_equals()`.
- `enableCsrfProtection(false)` in `config/general.php` turns it off site-wide. There is
  no legitimate production reason for that.

## Review Checklist

```bash
rg -n "enableCsrf(Protection|Validation)['\"]?\s*(=>|=|\()\s*false" config/ modules/ plugins/ src/
# POST forms in templates that never mention csrfInput (Blitz's helper matches too)
rg -il -0 '<form[^>]*method="?post' templates/ | xargs -0 rg --files-without-match -e 'csrfInput' --
rg -n 'redirectInput\([^)]*~' templates/
rg -n 'enableCsrfValidationForGuests' config/
```

- [ ] `enableCsrfProtection` not disabled anywhere; controller opt-outs limited to signed webhooks
- [ ] Every POST form carries `csrfInput()` (or the Blitz/Formie equivalent)
- [ ] Cached pages use async inputs, Blitz injection or `refreshForCache()` - never a baked token
- [ ] Redirects use `redirectInput()` with a constant string; other trusted hidden values use `|hash`
- [ ] No page relying on `{% requireLogin %}`-style tags is statically cached
- [ ] Formie guest CSRF validation on; captchas on for public forms
