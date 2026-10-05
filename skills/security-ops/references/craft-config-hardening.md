# Craft Production Configuration and Secrets

`.env`, `config/general.php`, the security key, `devMode`, and the settings whose defaults
are wrong for production. Craft CMS 3/4/5; facts verified 2026-10-05 against
https://craftcms.com/docs/5.x/reference/config/general.html (G5 below) and
https://craftcms.com/knowledge-base/securing-craft.

## Contents

- Where Secrets Live
- The Security Key
- devMode
- Settings to Change from Default
- Web Root Layout
- Review Checklist

## Where Secrets Live

- Craft loads `.env` with vlucas/phpdotenv; read values with `App::env()` - the docs
  discourage calling `getenv()` directly (https://craftcms.com/docs/5.x/configure.html).
- Any general config setting can be overridden by an environment variable: `CRAFT_` plus
  the setting name in screaming snake case (`allowAdminChanges` becomes
  `CRAFT_ALLOW_ADMIN_CHANGES`). Overrides beat config files, which beat defaults.
- `.env` is never committed. Commit `.env.example.*` files whose values are placeholders:

```dotenv
# .env.example.production - committed; real values live on the server
CRAFT_ENVIRONMENT=production
CRAFT_SECURITY_KEY=<generate with: php craft setup/security-key>
CRAFT_DB_PASSWORD=<from the hosting secrets store>
CRAFT_DEV_MODE=false
CRAFT_ALLOW_ADMIN_CHANGES=false
```

- No literal secrets in `config/*.php`, project config YAML, or plugin settings saved to
  project config - reference environment variables instead (settings that support them
  accept a `$VAR_NAME` reference). Project config is committed, so a pasted API secret
  ships to git.
- `CRAFT_SECRETS_PATH` can point at a PHP file of secrets that are not loaded into the
  environment; the docs note this is no protection against someone with shell access.
- Multi-environment configs (`'*'` plus per-environment keys) match on
  `CRAFT_ENVIRONMENT`; if it is unset, Craft falls back to the server hostname. Set it
  explicitly everywhere so production never silently inherits a dev block.
- Secret scanning belongs in CI too: `git log -p -S 'CRAFT_SECURITY_KEY=' -- .env`
  finds a key that was ever committed. A key in history is a leaked key - rotate it.

## The Security Key

`securityKey` (G5) is "used for hashing and encrypting data": it keys `|hash` and
`hashData()`/`validateData()`, `redirectInput()`, cookie validation, and
`encryptByKey()`. Anyone holding it can forge "signed" values the application trusts.

- **Generate** with `php craft setup/security-key` (writes `CRAFT_SECURITY_KEY` to
  `.env`). One key per environment; never reuse production's key on staging or laptops.
- **Never** put it in `config/general.php` as a literal or commit it.
- **It is the precondition for real exploits.** CVE-2025-23209 (Craft 4/5, on CISA's KEV
  list) is RCE for anyone who already has the key
  (https://github.com/craftcms/cms/security/advisories/GHSA-x684-96hh-833x);
  GHSA-5r92-75j8-c534 (September 2026) was RCE through signed-cookie/redirect confusion.
- **Rotate** when it may have leaked: after any compromise, after CVE-2025-32432-style
  incidents (Craft's response guide lists key rotation,
  https://craftcms.com/knowledge-base/craft-cms-cve-2025-32432), or when someone with
  access leaves. Rotation logs everyone out and invalidates outstanding hashes and
  encrypted values - plan for it, then do it.

## devMode

Craft's knowledge base: devMode "should never be enabled on a public server"
(https://craftcms.com/knowledge-base/what-dev-mode-does). With it on:

- errors render with full stack traces and code previews;
- any request can force the Yii debug toolbar with an `X-Debug: enable` header;
- JSON requests (`Accept: application/json`) and GraphQL return verbose errors;
- Twig `dump()` is enabled.

Make the safe value the fallback, so a missing variable fails closed:

```php
// config/general.php (Craft 4+ fluent config)
use craft\config\GeneralConfig;
use craft\helpers\App;

return GeneralConfig::create()
    ->devMode(App::env('CRAFT_DEV_MODE') ?? false)
    ->allowAdminChanges(App::env('CRAFT_ALLOW_ADMIN_CHANGES') ?? false)
    ->disallowRobots(App::env('CRAFT_DISALLOW_ROBOTS') ?? false)
    ->preventUserEnumeration(true)
    ->sendPoweredByHeader(false)
    ->trustedHosts(['www.example.com'])
    ->enableTwigSandbox(true);   // Craft 4.17+ / 5.9+
```

Probe a live site without logging in: request a page that errors with
`Accept: application/json` and check the body for file paths or a trace.

## Settings to Change from Default

Defaults from G5; the "Production" column is this skill's recommendation.

| Setting | Default | Production | Why |
|---|---|---|---|
| `devMode` | `false` | `false` | see above - check the env var, not just the file |
| `allowAdminChanges` | `true` | `false` | stops schema/settings edits and admin Twig authoring in prod; also disables `allowUpdates` |
| `trustedHosts` | `['any']` | your hostnames | host-header tricks; GHSA-c55v-343g-5xff (SSRF/JS injection) cited the `any` default |
| `preventUserEnumeration` | `false` | `true` on public-account sites | forgot-password no longer reveals which accounts exist |
| `sendPoweredByHeader` | `true` | `false` | drops `X-Powered-By: Craft CMS` (obscurity, cheap) |
| `useSecureCookies` | `'auto'` | `true` behind a TLS-terminating proxy | `auto` trusts the request scheme, which a proxy can hide |
| `sameSiteCookieValue` | `null` | `'Lax'` | second CSRF layer (`craft-csrf-forms.md`) |
| `enableTwigSandbox` | `false` | `true` | `twig-template-injection.md` |
| `enableGql` | `true` | `false` if unused | removes the GraphQL endpoint (`craft-graphql-security.md`) |
| `disallowRobots` | `false` | `true` on dev and staging only | keeps non-production hosts out of search indexes |
| `maxInvalidLogins` / `cooldownDuration` | `5` / `300` | keep, or tighten | brute-force lockout |
| `elevatedSessionDuration` | `300` | keep (`0` disables elevated sessions - never) | password re-prompt for sensitive actions |
| `cpTrigger` | `'admin'` | optional change | obscurity only; or serve the CP on its own host via `baseCpUrl` |
| `sanitizeSvgUploads` | `true` | `true` | `craft-uploads-assets.md` |

Never set `enableCsrfProtection` to `false`, and leave `requireUserAgentAndIpForSession`
at `true`.

## Web Root Layout

Only `web/` should be served. Craft's securing guide keeps `config/`, `storage/`,
`templates/`, `vendor/`, `.env` and non-public asset roots above the web root
(https://craftcms.com/knowledge-base/securing-craft). Check the server's document root
points at `web/`, not the project root: a project-root docroot serves `.env` and
`composer.lock` to anyone who asks.

Security headers (HSTS, CSP, `X-Content-Type-Options`, frame protection) belong in the web
server or, since Craft 5.3, Craft's header/CORS filter configuration - see
`secure-headers.md`.

## Review Checklist

```bash
git ls-files | rg '(^|/)\.env$'                         # must print nothing
rg -n "securityKey['\"]?\s*(=>|\()\s*['\"]" config/     # literal key in config
rg -n "devMode['\"]?\s*(=>|\()\s*true" config/          # devMode hard-coded on
rg -n 'trustedHosts|allowAdminChanges|enableTwigSandbox|preventUserEnumeration' config/
```

- [ ] `.env` untracked and never in history; `.env.example.*` hold placeholders only
- [ ] `CRAFT_SECURITY_KEY` unique per environment, generated by Craft, rotated after any suspected exposure
- [ ] `devMode` and `allowAdminChanges` default to `false` when their env vars are missing
- [ ] `CRAFT_ENVIRONMENT` set explicitly on every host
- [ ] `trustedHosts` lists real hostnames; `preventUserEnumeration` on for public accounts
- [ ] Document root is `web/`; `.env`, `config/`, `storage/`, `vendor/` are not reachable over HTTP

Related: `ddev-config-drift.md` (keeping local and production honest),
`craft-advisories.md` (CVEs that turn a leaked key into RCE).
