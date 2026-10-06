# Project Configuration and Environment

Facts from the DDEV docs at DDEV v1.25.4 (configuration, environment variables, developer
tools, managing projects, FAQ, upgrading) and its source, checked 2026-10-06.
Version-sensitive values live in `assets/ddev-facts.json`.

## Contents

- [Existing repository on a new machine](#existing-repository-on-a-new-machine)
- [New project](#new-project)
- [Pin what production runs](#pin-what-production-runs)
- [CI and production parity](#ci-and-production-parity)
- [Composer](#composer)
- [Where a setting belongs](#where-a-setting-belongs)
- [What to commit](#what-to-commit)
- [Environment variables and settings files](#environment-variables-and-settings-files)
- [Upgrading DDEV itself](#upgrading-ddev-itself)

## Existing repository on a new machine

The repository already has `.ddev/config.yaml`, so **do not run `ddev config`**.

1. **Install a Docker provider:** OrbStack on macOS, or Docker CE inside WSL2 on Windows;
   see [performance.md](performance.md#docker-providers). Check
   `docker buildx version` works: DDEV requires the buildx plugin, which the GUI providers
   bundle.
2. **Install DDEV:** `brew install ddev/ddev/ddev` (macOS), the Windows installer or
   `winget install --interactive DDEV` (WSL2), or apt/yum (Linux). Then run
   `mkcert -install` once for trusted HTTPS.
3. **On Windows,** clone the project inside the WSL2 filesystem (`~/sites/<project>`),
   never under `/mnt/c`.
4. **`ddev start`**, then install dependencies: `ddev composer install` and
   `ddev npm ci` (or the project's package manager).
5. **Copy env templates:** the application's `.env.example` to `.env`, and any
   `.ddev/.env.*.example` to its `.local` twin; fill in the values.
6. **Get data:**
   - a `seed` snapshot (loaded automatically);
   - `ddev pull <provider>`;
   - or `ddev import-db --file=<sanitised dump>`.

   See [database.md](database.md).
7. **Finish:** `ddev launch`, or `ddev describe` for every URL.

Craft-specific steps (`ddev craft up` and friends): craftcms-ops' `references/ddev.md`.

## New project

```bash
ddev config --project-type=<type> --docroot=<dir> --php-version=<x.y>   # writes .ddev/config.yaml
ddev start
ddev describe                                       # URLs, ports, services, DB credentials
```

- Always pass flags: `ddev config` with none is interactive.
- **Project types:**
  - `php`: no settings management; works with anything.
  - CMS and framework types: `laravel`, `wordpress`, `wp-bedrock`, `craftcms`, `drupal`
    (and `drupal10`, `drupal11`), `symfony`, `typo3`, `magento2`, `shopware6`,
    `silverstripe`, `cakephp`, `codeigniter`.
  - `generic`, and more: see `ddev config --help`.
- Run every PHP, Composer and Node command through DDEV (`ddev composer`, `ddev php`,
  `ddev npm`, `ddev exec <cmd>`) so it uses the container's versions, not the host's.
- `ddev config` keeps values already in `config.yaml` unless you pass new ones;
  `ddev config --update` re-detects the project type and docroot and refreshes them.
  Review the diff before committing either.

## Pin what production runs

Unpinned values follow DDEV's defaults, and those move between releases. DDEV v1.25.0
changed the default PHP from 8.3 to 8.4, Node.js from 22 to 24 and MariaDB from 10.11 to
11.8 for new projects; any project without a pin silently picked up the new PHP.

| Key | Today (DDEV v1.25.4) | Rule |
|---|---|---|
| `php_version` | default `php_version` is 8.4; DDEV ships PHP 5.6 through 8.5 | Pin production's major.minor (`"8.3"`, quoted). Minor-level only |
| `database` | default `mariadb:11.8`; MySQL 5.5-8.0, 8.4, 9.7; Postgres 9-18 | Pin `type` + `version` to production. The `craftcms` type writes `mysql:8.0` at `ddev config` time |
| `nodejs_version` | Node.js 24 | Pin the build's major; see [frontend-node.md](frontend-node.md) |
| `composer_version` | `2` | Composer 1 is end of life; an exact version (`"2.9.3"`) keeps a team identical |
| `webserver_type` | `nginx-fpm` | Match production (`apache-fpm` for `.htaccess`-dependent sites) |
| `ddev_version_constraint` | none | `'>= v1.25.4'` when config relies on newer features (`.local` env files, seed snapshots) - an older DDEV then refuses to start instead of misbehaving |

- Change PHP with `ddev config --php-version=8.3 && ddev restart`. Then bump
  `composer.json` `config.platform.php` to match and run `ddev composer update`, or
  Composer keeps resolving packages for the old PHP.
- DDEV refuses MySQL 9+ with PHP 7.3 or older (MySQL 9 dropped the
  `mysql_native_password` plugin that old `mysqlnd` needs).
- Changing `database:` later needs a data move, not just an edit - see
  [database.md](database.md#changing-the-database-engine).
- PHP older than 8.2 is end of life upstream (as of 2026-10-05). DDEV still runs it; plan
  the upgrade, and keep production on the same minor meanwhile.
- `timezone:` sets the container and PHP time zone; unset, DDEV derives it from the host
  (`$TZ` or `/etc/localtime`), else UTC.

## CI and production parity

DDEV can run in CI (DDEV maintains a GitHub Action that installs it), but a 2026-10-05
read of 36 DDEV-based agency repositories found none whose workflows do: CI ran
`composer install`, tests and the deploy directly on the runner. So three environments
must agree on PHP: `.ddev/config.yaml`, the CI runner and production.

- **Read the version from DDEV's config** rather than hard-coding it in the workflow:
  `yq '.php_version' .ddev/config.yaml` feeding `shivammathur/setup-php`'s `php-version`.
- **A committed `.ddev/config.*.yaml` can override `php_version`;** check those too.
- **Match more than the version:** the PHP extensions CI installs, `nodejs_version` for the
  front-end build, and `composer.json` `config.platform.php`.

## Composer

- **`composer.json` not in the project root?** Set `composer_root` (or
  `ddev config --composer-root <dir>`); scripts can use `$DDEV_COMPOSER_ROOT`.
- **Composer changes outside the project don't persist.** `ddev composer self-update` and
  `ddev composer global require` are lost when the container restarts. Change
  `composer_version` instead, then `ddev restart --no-cache` (or `ddev utility rebuild`).
- **Private repositories:**
  - Over SSH: see [extending.md](extending.md#ssh-keys-inside-containers).
  - `auth.json`: symlink your global one into the *global* homeadditions
    (`~/.ddev/homeadditions/.composer/auth.json`), never into the project's.

## Where a setting belongs

| Setting | File | In git |
|---|---|---|
| Team-wide, mirrors production | `.ddev/config.yaml` | yes |
| An add-on's or feature's settings | `.ddev/config.<name>.yaml` (merged after `config.yaml`) | yes |
| One developer's machine: Mutagen, extra hostnames, a fixed DB port, a per-checkout `name` | `.ddev/config.local.yaml` or `config.<name>.local.yaml` | no (gitignored once DDEV has run; see below) |
| Every project on this machine | `ddev config global --<flag>` (`~/.ddev/global_config.yaml`) | n/a |
| Container env vars for the team | `.ddev/.env`, `.ddev/.env.<service>` | yes |
| Secrets and per-developer env | `.ddev/.env.local`, `.ddev/.env.<service>.local` (v1.25.4+) | no |

- Override files *merge* into `config.yaml`. Set `override_config: true` inside one when
  it must *replace* values, for example to empty a list (`additional_hostnames: []`).
- Project values beat global ones. That is why `performance_mode`, `router_http_port`
  and `router_https_port` do not belong in `config.yaml`: committed, they pin every
  teammate, and someone with a port clash can no longer fix it globally.
- A committed `name:` makes every checkout of the repository claim one project name. See
  [automation-and-worktrees.md](automation-and-worktrees.md#several-checkouts-of-one-repository).
- DDEV parses `config.yaml` non-strictly, so an unknown or retired key is ignored, not
  rejected. `mutagen_enabled` and `nfs_mount_enabled` look meaningful and do nothing.

## What to commit

**Commit:**
- `config.yaml` and `config.<name>.yaml`
- `docker-compose.*.yaml`, `commands/`
- `providers/` recipes, minus any push to production
- `web-build/`, `php/`, `mysql/`, `nginx/` snippets
- `addon-metadata/`: the add-on manifests that `ddev add-on list --installed` reads
- any taken-over generated file

**`.env.<service>.example` files** list the keys a developer must fill in. DDEV's
generated `.ddev/.gitignore` ignores `*.example`, so add each one with `git add -f`; a
plain `git add` silently skips it.

**Do not commit:**
- `config.local.yaml` and `config.*.local.yaml`, and any `*.local` env file
- `db_snapshots/`: large; a deliberate `seed-*` snapshot is the exception
- `.downloads/`, and generated files you have not taken over

Never edit or commit `.ddev/.gitignore`: DDEV regenerates it to track which files it owns.
Because it isn't committed, a fresh clone or worktree ignores none of the `.local` files
until a `ddev config` or a successful `ddev start` writes it. A `git add -A` before then
commits them. Add `.ddev/config*.local.y*ml` and `.ddev/.env*.local` to the `.gitignore`
in the project root (the folder holding `.ddev/`, which in a monorepo isn't the repository
root). The auditor flags tracked ones (`local-file-committed`).

**`#ddev-generated`:** a file carrying this line belongs to DDEV, which may rewrite it on
`ddev start`. Deleting the line takes the file over - it is now yours, and it stops
receiving DDEV's fixes. v1.25.4 changed the generated `nginx-site.conf` and
`apache-site.conf`: restore the line, `ddev restart`, diff the regenerated file against
your version and merge. Prefer snippets over take-overs
([extending.md](extending.md#web-server-configuration)).

## Environment variables and settings files

| Set it in | Reaches | Read by |
|---|---|---|
| Application `.env` in the project root | No container env; it stays a file | The framework (Laravel, Craft, Symfony) on every request |
| `.ddev/.env*` and `~/.ddev/.env*` | The environment of the named container(s) | Anything in that container |
| `web_environment` in config | The `web` container only | Anything in `web` |

- **Settings management** (DDEV writes database credentials and the URL for you):

  | Project type | What DDEV writes |
  |---|---|
  | Laravel | The root `.env`, copied from `.env.example` if missing |
  | Craft | `.ddev/.env.web` (`CRAFT_DB_*`, `PRIMARY_SITE_URL`; per DDEV's source, though one docs page still says `.env`) |
  | WordPress | `wp-config-ddev.php`, which an existing `wp-config.php` must include (DDEV prints the snippet) |
  | Drupal | `settings.ddev.php` |
  | `php` | Nothing |

  `disable_settings_management: true` opts out. `IS_DDEV_PROJECT=true` is set in the
  container, so code can fence off DDEV-only settings.
- **File names** follow `.env[.<service>[.<label>]][.local]`: `.ddev/.env` reaches every
  container, `.ddev/.env.web` only `web`, a label (`.env.web.myaddon`) keeps sources apart,
  and a trailing `.local` marks it per-developer: git ignores it once DDEV has run in the
  checkout, and always with the `.gitignore` lines under [What to commit](#what-to-commit).
- **Order (later wins):**
  1. `web_environment`, global then project.
  2. The env files: global before project. Within each, `.env`, then `.env.local`, then
     per-service files alphabetically, each followed by its `.local` twin. Labelled files
     come after their unlabelled service file.

  So any `.ddev/.env*` value beats `web_environment`. The global and `.local` files need
  v1.25.4+.
- **Changes** to `.ddev/.env*` or `web_environment` need `ddev restart`; an application
  `.env` does not.
- **Inspect:** `ddev utility check-custom-config` lists the env files in applied order,
  `ddev exec env` shows what reached `web`, and `ddev utility compose-config` prints the
  rendered compose file.
- **Edit from scripts:** `ddev dotenv set .env --app-key=value` creates the file and sets
  one key; `ddev dotenv global set` writes the global files.
- Never put a real credential in a committed `.ddev/.env*`. Use the `.local` twin and
  force-add a `.example` with empty values. Production keys never belong on a laptop at
  all - see security-ops' `ddev-config-drift.md`.

## Upgrading DDEV itself

1. `ddev poweroff`, then upgrade:
   - Homebrew, apt/yum, the Windows installer, or `winget`;
   - on WSL2 with apt, upgrade the `ddev-wsl2` package too;
   - `ddev self-upgrade` prints the right instructions for the current install.

   Then `ddev start`.
2. `ddev delete images` reclaims space from previous image versions.
3. Old repositories may still carry things v1.25 removed or changed:

| Change | Since | What breaks |
|---|---|---|
| NFS support removed | v1.25.0 | `nfs_mount_enabled` is ignored; use `performance_mode` |
| `ddev service` and `ddev nvm` removed | v1.25.0 | Use `ddev add-on get` and `nodejs_version` (or the `ddev-nvm` add-on) |
| Flags removed: `--mutagen-enabled`, `--upload-dir`, `--http-port`, `--projecttype` | v1.25.0 | READMEs and scripts that pass them fail |
| Debian Trixie base image | v1.25.0 | Obsolete `webimage_extra_packages` names stop installing |
| The router keeps running after the last project stops | v1.25.0 | Use `ddev poweroff` to free ports 80/443 |
| XHGui is the default profiler | v1.25.0 | `ddev config global --xhprof-mode=prepend` restores the old mode |
| The Docker buildx plugin is required | v1.25.1 | `brew install docker-buildx` or `apt-get install docker-buildx-plugin` where the provider lacks it |
| `post-start` hooks cannot write `/usr/local/bin` | v1.25.3 | Write to `~/.local/bin` |
| `xdebug_enabled` gone from `ddev describe -j` | v1.25.4 | Scripts must call `ddev xdebug status` |

Project Traefik customisation: add extra `*.yaml` files beside the generated
`.ddev/traefik/config/<project>.yaml`; DDEV merges them all into one config. Taking over
the generated file (deleting its `#ddev-generated` line) is the heavier option.

Source: DDEV release notes on GitHub (v1.25.0 through v1.25.4) and the v1.25.4
Traefik router docs.
