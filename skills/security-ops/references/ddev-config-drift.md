# DDEV and Production Configuration Drift

A site that is safe on DDEV can be exposed in production, and the reverse - local
settings that would be dangerous anywhere public. This file lists where they drift and
how to check. Facts verified 2026-10-05 against DDEV v1.25.4 docs and source
(https://docs.ddev.com/en/stable/), php-src `php.ini-*` files, and Craft 5 docs.
DDEV mechanics - pinning, `.local` env files, sanitised pulls, `ddev auth ssh` - live in
the ddev-ops skill, whose `audit-ddev-config.py` flags several risks below (secrets in
committed env files, host SSH-agent forwarding, push recipes, unpinned PHP).

## Contents

- Why Drift Is a Security Problem
- What DDEV Sets for Craft
- PHP Runtime Drift
- Craft Settings by Environment
- Data and Secrets Crossing Environments
- Sharing a Local Site
- Drift Check
- Review Checklist

## Why Drift Is a Security Problem

- Tests and manual checks run locally. Anything that differs in production - PHP
  version, ini settings, env vars, extensions - is untested there.
- Some settings are deliberately unsafe locally (`devMode`, `display_errors`, Xdebug).
  The risk is one of them reaching a public host, or a public tunnel reaching them.
- CVE-2024-56145 is the cautionary tale: DDEV ships `register_argc_argv = Off`, so the
  exploit cannot be reproduced locally, while a production PHP with the directive on is
  vulnerable (`craft-advisories.md`).

## What DDEV Sets for Craft

For the `craftcms` project type, DDEV writes `.ddev/.env.web` with `CRAFT_DB_*`
(server `db`, user/password/database `db`), `CRAFT_WEB_ROOT`, `PRIMARY_SITE_URL` and
Mailpit SMTP settings (DDEV `pkg/ddevapp/craftcms.go`; quickstart:
https://docs.ddev.com/en/stable/users/quickstart/#craft-cms).

- It does **not** write the project `.env` or `CRAFT_SECURITY_KEY`.
- `.ddev/.env.web` is committed by default - local database credentials only. Never add
  real API keys there; per-developer values go in `.ddev/.env.local` or
  `config.local.yaml`, which DDEV's generated `.gitignore` excludes.
- Defaults if unpinned: **PHP 8.4** and, for the Craft type, **MySQL 8.0**
  (https://docs.ddev.com/en/stable/users/configuration/config/). Production for most
  sites is something else - pin both.

```yaml
# .ddev/config.yaml - mirror production, not DDEV's defaults
type: craftcms
php_version: "8.3"
database:
  type: mysql
  version: "8.0"
webserver_type: nginx-fpm
composer_version: "2"
```

## PHP Runtime Drift

DDEV's bundled php.ini (v1.25.4, PHP 8.4 fpm) against `php.ini-production`
(https://github.com/php/php-src/blob/PHP-8.4/php.ini-production):

| Directive | DDEV fpm | php.ini-production | Production should be |
|---|---|---|---|
| `display_errors` | On | Off | Off |
| `display_startup_errors` | On | Off | Off |
| `log_errors` | On | On | On |
| `expose_php` | Off | **On** | Off (set it yourself) |
| `register_argc_argv` | Off | Off on 8.4; **unset (default On) on 8.5** | Off |
| `memory_limit` | 1024M | 128M | what the site needs |
| `upload_max_filesize` / `post_max_size` | 100M / 100M | 2M / 8M | match Craft's `maxUploadFileSize` |
| `zend.assertions` | -1 | -1 | -1 |
| `session.use_strict_mode` | - | 0 | 1 (OWASP) |

- PHP 8.5 deprecated `register_argc_argv` for non-CLI SAPIs and its `php.ini-production`
  comments the line out, so an unedited 8.5 server runs with the built-in default (On).
  Set `register_argc_argv = Off` explicitly in production's FPM config.
- OWASP's PHP configuration guidance (https://cheatsheetseries.owasp.org/cheatsheets/PHP_Configuration_Cheat_Sheet.html)
  adds `allow_url_include = Off`, `session.cookie_httponly = 1`, `session.cookie_secure = 1`.
- Local overrides go in `.ddev/php/*.ini` (applied after `ddev restart`). Use them to make
  DDEV *closer* to production - for example matching upload limits - not further away.
- Xdebug is off by default in DDEV (`ddev xdebug on` to enable). It must never be
  installed on production.
- Compare extensions too: `ddev exec php -m` against production `php -m`. A missing
  extension (`intl`, `imagick`) changes behaviour and sometimes security (image
  processing falls back to GD).

## Craft Settings by Environment

| Setting | DDEV | Staging | Production |
|---|---|---|---|
| `CRAFT_ENVIRONMENT` | `dev` | `staging` | `production` |
| `CRAFT_DEV_MODE` | `true` | `false` | `false` |
| `CRAFT_ALLOW_ADMIN_CHANGES` | `true` | `false` | `false` |
| `CRAFT_DISALLOW_ROBOTS` | `true` | `true` | `false` |
| `CRAFT_SECURITY_KEY` | own value | own value | own value |
| GraphQL introspection | on | on | off |

- Schema changes flow through project config: made on DDEV, committed, applied in
  production with `php craft up` (or `php craft project-config/apply`). With
  `allowAdminChanges` off in production, the CP cannot drift from git.
- `CRAFT_ENVIRONMENT` unset makes multi-environment config fall back to the hostname -
  set it everywhere (`craft-config-hardening.md`).

## Data and Secrets Crossing Environments

- **Production databases pulled to DDEV** carry real users' personal data and password
  hashes onto laptops. Prefer sanitised dumps; if a raw pull is unavoidable, treat the
  laptop as holding production data (disk encryption, deletion after use).
- **Mail**: Mailpit catches mail sent through PHP's mailer, but "will not intercept" a
  custom SMTP or third-party email-service configuration
  (https://docs.ddev.com/en/stable/users/usage/developer-tools/#email-capture-and-review-mailpit).
  A pulled database whose project config points at a real mail service can email real
  customers from a laptop - keep mail transport settings in env vars per environment.
- **Security keys** stay per environment. Copying production's key to DDEV so encrypted
  values decrypt spreads the one secret that turns CVE-2025-23209 into RCE across every
  laptop. Re-enter the few encrypted settings locally instead.
- **GraphQL tokens** live in the database - a pulled database brings production tokens;
  regenerate them locally or treat the dump as secret.

## Sharing a Local Site

`ddev share` publishes the local site through a tunnel - ngrok by default, or
`--provider=cloudflared` (https://docs.ddev.com/en/stable/users/topics/sharing/).

- While shared, everything local becomes internet-facing: `devMode` stack traces, the
  debug toolbar (any request can force it with an `X-Debug: enable` header), Xdebug,
  `display_errors`, and any production data in the local database.
- Before sharing: set `CRAFT_DEV_MODE=false`, use a sanitised database, and stop the
  tunnel as soon as the demo ends. Never share from a database pulled from production.

## Drift Check

```bash
# Local
ddev describe
ddev exec php -v
ddev exec php -i | rg -i '^(display_errors|expose_php|register_argc_argv|memory_limit|upload_max_filesize|post_max_size|session.use_strict_mode) '
ddev exec php -m > /tmp/ext-local.txt
ddev composer audit --locked

# Production (web SAPI values matter; CLI always has register_argc_argv on)
# Craft CP > Utilities > PHP Info shows the FPM values; compare line by line.
```

## Review Checklist

- [ ] `.ddev/config.yaml` pins `php_version` and database type/version to production's
- [ ] `composer.json` `config.platform.php` matches production's PHP
- [ ] Production FPM: `display_errors` Off, `expose_php` Off, `register_argc_argv` Off, `session.use_strict_mode` 1
- [ ] Per-environment env vars for devMode, admin changes, robots, security key; `CRAFT_ENVIRONMENT` set everywhere
- [ ] No real secrets in `.ddev/.env.web`; production keys and tokens never copied locally
- [ ] Mail transport per environment; sanitised dumps for local work
- [ ] `ddev share` only with devMode off and non-production data
