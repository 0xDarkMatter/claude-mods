# Project Configuration and Environment

Facts from the DDEV docs at DDEV v1.25.4 (configuration, environment variables, FAQ) and
its source, checked 2026-10-05. Version-sensitive values live in `assets/ddev-facts.json`.

## Contents

- [Start or adopt a project](#start-or-adopt-a-project)
- [Pin what production runs](#pin-what-production-runs)
- [Where a setting belongs](#where-a-setting-belongs)
- [What to commit](#what-to-commit)
- [Environment variables](#environment-variables)
- [Upgrading DDEV itself](#upgrading-ddev-itself)

## Start or adopt a project

```bash
ddev config --project-type=<type> --docroot=<dir>   # writes .ddev/config.yaml
ddev start
ddev describe                                       # URLs, ports, services, DB credentials
```

- Project types: `php` (no CMS settings management, works with anything), `laravel`,
  `wordpress`, `wp-bedrock`, `craftcms`, `drupal`/`drupal10`/`drupal11`, `symfony`,
  `typo3`, `magento2`, `shopware6`, `silverstripe`, `cakephp`, `codeigniter`, `generic`
  and more (`ddev config --help`). Craft specifics live in craftcms-ops.
- Run every PHP, Composer and Node command through DDEV (`ddev composer`, `ddev php`,
  `ddev npm`, `ddev exec <cmd>`) so it uses the container's versions, not the host's.
- `ddev config --auto` rewrites `config.yaml` with the current DDEV's defaults. Diff the
  result before committing: it can add keys a teammate on an older DDEV does not know.

## Pin what production runs

Unpinned values follow DDEV's defaults, and those move between releases. DDEV v1.25.0
changed the default PHP from 8.3 to 8.4, Node.js from 22 to 24 and MariaDB from 10.11 to
11.8 for new projects; any project without a pin silently picked up the new PHP.

| Key | Today (DDEV v1.25.4) | Rule |
|---|---|---|
| `php_version` | default `php_version` is 8.4; DDEV ships PHP 5.6 through 8.5 | Pin production's major.minor (`"8.3"`, quoted). Minor-level only |
| `database` | default `mariadb:11.8`; MySQL 5.5-8.0, 8.4, 9.7; Postgres 9-18 | Pin `type` + `version` to production. The `craftcms` type writes `mysql:8.0` at `ddev config` time |
| `nodejs_version` | Node.js 24 | Pin the build's major; see [frontend-node.md](frontend-node.md) |
| `composer_version` | `2` | Composer 1 is end of life |
| `webserver_type` | `nginx-fpm` | Match production (`apache-fpm` for `.htaccess`-dependent sites) |
| `ddev_version_constraint` | none | `'>= v1.25.4'` when config relies on newer features (`.local` env files, seed snapshots) - an older DDEV then refuses to start instead of misbehaving |

- DDEV refuses MySQL 9+ with PHP 7.3 or older (MySQL 9 dropped the
  `mysql_native_password` plugin that old `mysqlnd` needs).
- Changing `database:` later needs a data move, not just an edit - see
  [database.md](database.md#changing-the-database-engine).
- PHP older than 8.2 is end of life upstream (as of 2026-10-05). DDEV still runs it; plan
  the upgrade, and keep production on the same minor meanwhile.
- `composer.json` `config.platform.php` should equal `php_version`, or Composer resolves
  packages for a PHP the site never runs on.

## Where a setting belongs

| Setting | File | In git |
|---|---|---|
| Team-wide, mirrors production | `.ddev/config.yaml` | yes |
| An add-on's or feature's settings | `.ddev/config.<name>.yaml` (merged after `config.yaml`) | yes |
| One developer's machine: Mutagen, extra hostnames, a fixed DB port | `.ddev/config.local.yaml` or `config.<name>.local.yaml` | no (DDEV gitignores them) |
| Every project on this machine | `ddev config global --<flag>` (`~/.ddev/global_config.yaml`) | n/a |
| Container env vars for the team | `.ddev/.env`, `.ddev/.env.<service>` | yes |
| Secrets and per-developer env | `.ddev/.env.local`, `.ddev/.env.<service>.local` (v1.25.4+) | no |

- Override files *merge* into `config.yaml`. Set `override_config: true` inside one when
  it must *replace* values, for example to empty a list (`additional_hostnames: []`).
- Project values beat global ones. That is why `performance_mode`, `router_http_port`
  and `router_https_port` do not belong in `config.yaml`: committed, they pin every
  teammate, and someone with a port clash can no longer fix it globally.
- DDEV parses `config.yaml` non-strictly, so an unknown or retired key is ignored, not
  rejected. `mutagen_enabled` and `nfs_mount_enabled` look meaningful and do nothing.

## What to commit

**Commit:** `config.yaml`, `config.<name>.yaml`, `docker-compose.*.yaml`, `commands/`,
`providers/` (recipes, minus any push to production), `web-build/`, `php/`, `mysql/`,
`addon-metadata/` (add-on manifests that `ddev add-on list --installed` reads), any
taken-over `nginx_full/` or `apache/` file, and `.env.<service>.example` files listing
the keys a developer must fill in.

**Do not commit:** `config.local.yaml` and `config.*.local.yaml`, any `*.local` env
file, `db_snapshots/` (large; a deliberate `seed-*` snapshot is the exception),
`.downloads/`, and generated files you have not taken over. Never edit or commit
`.ddev/.gitignore`: DDEV regenerates it to track which files it owns.

**`#ddev-generated`:** a file carrying this line belongs to DDEV, which may rewrite it on
`ddev start`. Deleting the line takes the file over - it is now yours, and it stops
receiving DDEV's fixes. v1.25.4 changed the generated `nginx-site.conf` and
`apache-site.conf`: restore the line, `ddev restart`, diff the regenerated file against
your version and merge.

## Environment variables

| Set it in | Reaches | Read by |
|---|---|---|
| Application `.env` in the project root | No container env; it stays a file | The framework (Laravel, Craft, Symfony) on every request |
| `.ddev/.env*` and `~/.ddev/.env*` | The environment of the named container(s) | Anything in that container |
| `web_environment` in config | The `web` container only | Anything in `web` |

- **Settings management.** For several project types DDEV writes database credentials and
  the project URL into the root `.env`. For `craftcms` it writes `.ddev/.env.web` instead
  (`CRAFT_DB_*`, `PRIMARY_SITE_URL`). `disable_settings_management: true` opts out.
- **File names** follow `.env[.<service>[.<label>]][.local]`: `.ddev/.env` reaches every
  container, `.ddev/.env.web` only `web`, a label (`.env.web.myaddon`) keeps sources apart,
  and a trailing `.local` keeps the file out of git.
- **Order:** global files before project files; within each, `.env`, then `.env.local`,
  then per-service files alphabetically, each followed by its `.local` twin. Later wins.
- **Changes** to `.ddev/.env*` or `web_environment` need `ddev restart`; an application
  `.env` does not.
- **Inspect:** `ddev utility check-custom-config` lists the env files in applied order,
  `ddev exec env` shows what reached `web`, and `ddev utility compose-config` prints the
  rendered compose file.
- **Edit from scripts:** `ddev dotenv set .env --app-key=value` creates the file and sets
  one key; `ddev dotenv global set` writes the global files.
- Never put a real credential in a committed `.ddev/.env*`. Use the `.local` twin and
  commit a `.example` with empty values. Production keys never belong on a laptop at
  all - see security-ops' `ddev-config-drift.md`.

## Upgrading DDEV itself

1. `ddev poweroff`, upgrade (Homebrew, apt/yum, the Windows installer or `winget`;
   `ddev self-upgrade` prints the right instructions), then `ddev start`.
2. `ddev delete images` reclaims space from previous image versions.
3. Old repositories may still carry things v1.25 removed or changed:

| Change | Since | What breaks |
|---|---|---|
| NFS support removed | v1.25.0 | `nfs_mount_enabled` is ignored; use `performance_mode` |
| `ddev service` and `ddev nvm` removed | v1.25.0 | Use `ddev add-on get` and `nodejs_version` (or the `ddev-nvm` add-on) |
| Flags removed: `--mutagen-enabled`, `--upload-dir`, `--http-port`, `--projecttype` | v1.25.0 | READMEs and scripts that pass them fail |
| Debian Trixie base image | v1.25.0 | Obsolete `webimage_extra_packages` names stop installing |
| Project Traefik config is one file, `.ddev/traefik/config/<project>.yaml` | v1.25.0 | Other files in that folder are ignored |
| The router keeps running after the last project stops | v1.25.0 | Use `ddev poweroff` to free ports 80/443 |
| XHGui is the default profiler | v1.25.0 | `ddev config global --xhprof-mode=prepend` restores the old mode |
| `post-start` hooks cannot write `/usr/local/bin` | v1.25.3 | Write to `~/.local/bin` |
| `xdebug_enabled` gone from `ddev describe -j` | v1.25.4 | Scripts must call `ddev xdebug status` |

Source: DDEV release notes on GitHub (v1.25.0 through v1.25.4).
