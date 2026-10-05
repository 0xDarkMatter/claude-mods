# Extending DDEV: Add-ons, Commands, Hooks, Services

Facts from DDEV's add-on, custom-command, hooks and customisation docs at DDEV v1.25.4,
and its source (`cmd/ddev/cmd/commands.go`), checked 2026-10-05.

## Contents

- [Add-ons](#add-ons)
- [Custom commands](#custom-commands)
- [Hooks](#hooks)
- [Background processes](#background-processes)
- [Extra services and custom images](#extra-services-and-custom-images)
- [SSH keys inside containers](#ssh-keys-inside-containers)

## Add-ons

Use an add-on for a standard service (Redis, search, cron); hand-write a
`docker-compose.<name>.yaml` only for something no add-on covers.

```bash
ddev add-on search redis                        # or browse addons.ddev.com
ddev add-on get ddev/ddev-redis --version v1.0.4  # pin a release
ddev add-on list --installed
ddev add-on update --dry-run                    # v1.25.4: check every installed add-on
ddev add-on remove redis
ddev restart
```

- **Review before installing.** An add-on's Bash install actions run directly on your
  machine (PHP actions run in a temporary container). Read its `install.yaml` and compose
  file first, prefer the official `ddev/` add-ons, and pin `--version`.
- **What it writes:** `docker-compose.<name>.yaml`, maybe `config.<name>.yaml`, commands,
  and `addon-metadata/<name>/`. Commit all of it so teammates get the same services.
- **Customise without forking:** set the add-on's documented variables in
  `.ddev/.env.<addon>` (`ddev dotenv set .ddev/.env.redis --redis-tag 7-bookworm`), put
  tokens in `.ddev/.env.<addon>.local` (gitignored, v1.25.4), or override in a separate
  `docker-compose.<name>_extra.yaml` so updates do not clobber your change.
- **Debug:** `ddev logs -s <service>`, `ddev describe`, `ddev utility compose-config`.

Official add-ons a PHP agency reaches for:

| Need | Add-on |
|---|---|
| Object/page cache | `ddev/ddev-redis` (+ `ddev/ddev-redis-insight`), `ddev/ddev-memcached` |
| Search | `ddev/ddev-elasticsearch`, `ddev/ddev-opensearch`, `ddev/ddev-solr` |
| Scheduled tasks in the web container | `ddev/ddev-cron` |
| DB browser in the browser | `ddev/ddev-phpmyadmin`, `ddev/ddev-adminer` |
| Live reload without Vite | `ddev/ddev-browsersync` |
| S3-compatible storage, queues | `ddev/ddev-minio`, `ddev/ddev-rabbitmq` |
| Browser tests | `ddev/ddev-selenium-standalone-chrome` |

Mail capture needs no add-on: Mailpit is built in (`ddev mailpit`).

## Custom commands

| Location | Runs |
|---|---|
| `.ddev/commands/web/<file>` (or `db/`, or any service) | Inside that container |
| `.ddev/commands/host/<file>` | On your machine |
| `~/.ddev/commands/<service or host>/<file>` | Global, every project |

```bash
#!/usr/bin/env bash
## Description: Rebuild front-end assets
## Usage: assets
## Example: "ddev assets"
## ExecRaw: true
## MutagenSync: true
npm run build "$@"
```

- The command's name comes from `## Usage:`, not the file name. Check it with `ddev -h`.
- Useful annotations: `ExecRaw: true` (pass arguments untouched; DDEV recommends it for
  every container command), `MutagenSync: true` (sync before and after - for commands
  that write files), `HostWorkingDir: true`, `ProjectTypes`, `OSTypes` and
  `HostBinaryExists` (host only), `DBTypes`, `Flags`, `AutocompleteTerms`,
  `CanRunGlobally`.
- **LF line endings only.** DDEV skips a command file containing CRLF, with just a
  warning. Pin `.ddev/commands/** text eol=lf` in `.gitattributes` on Windows teams.
- **A project command shadows a built-in of the same name.** Project commands register
  before global ones and the first registration wins. A taken-over copy of `craft`,
  `npm`, `artisan` or `wp` freezes an old version and misses DDEV's fixes; delete it
  unless the override is deliberate. Built-ins ship from DDEV's global commands folder
  (`ddev -h` lists them).
- `scripts/audit-ddev-config.py` reports both (`crlf-command`, `shadowed-command`).

## Hooks

```yaml
hooks:
  post-start:
    - exec: ln -sf /var/www/html/vendor/bin/some-tool ~/.local/bin/some-tool
  post-import-db:
    - exec: php bin/console cache:clear
    - exec-host: echo "imported"
```

- Events: `pre-`/`post-` for `start`, `stop`, `import-db`, `import-files`, `composer`,
  `pull`, `push`, `snapshot`, `restore-snapshot`, `share`, `exec`, `config` and more.
- Tasks: `exec` (in a container; `service:` and `user:` optional), `exec-host`, and
  `composer`. `pre-start` and `post-stop` allow only `exec-host`, because the containers
  are not running.
- Hooks must not prompt. A failing hook does not interrupt `ddev start` unless
  `fail_on_hook_fail: true` (project or global).
- Keep `post-start` fast: an `npm install` there runs on every start for every teammate.

## Background processes

`web_extra_daemons` starts long-running processes with the web container and supervises
them; their output goes to `ddev logs`.

```yaml
web_extra_daemons:
  - name: queue
    command: php artisan queue:work --tries=3
    directory: /var/www/html
```

Front-end dev servers use the same mechanism: [frontend-node.md](frontend-node.md).

## Extra services and custom images

- **Extra service:** add `.ddev/docker-compose.<name>.yaml` with a `services:` block
  (docker-ops covers Compose syntax). Mount `ddev-global-cache:/mnt/ddev-global-cache` if
  the service should run DDEV custom commands. `ddev utility compose-config` shows the
  merged result.
- **Extra Debian packages:** `webimage_extra_packages`, for example the `webp`,
  `jpegoptim`, `optipng` and `gifsicle` binaries that image-optimising plugins call, or
  `php${DDEV_PHP_VERSION}-<ext>` for a PHP extension.
- **Anything more:** `.ddev/web-build/Dockerfile` (or `Dockerfile.<name>`); since v1.25.4,
  `~/.ddev/web-build/` applies to every project.
- **PHP settings:** `.ddev/php/<name>.ini`; database settings: `.ddev/mysql/<name>.cnf`.
  Use them to make DDEV *closer* to production, not further away (security-ops'
  `ddev-config-drift.md` lists the ini directives that differ by default).
- **Rebuild after image changes:** `ddev start --no-cache` or `ddev utility rebuild`.
- **Shell niceties:** files in `.ddev/homeadditions/` (or `~/.ddev/homeadditions/`) are
  copied into the container user's home - never commit an `auth.json` or key there.

## SSH keys inside containers

Provider pulls, private Composer repositories and git over SSH need a key inside the
container.

- **Use `ddev auth ssh -f ~/.ssh/<key>`** with one key scoped to what the project needs (a
  deploy or read-only key). It loads into DDEV's own `ddev-ssh-agent` container and stays
  there until `ddev poweroff`. Plain `ddev auth ssh` loads every key in `~/.ssh`.
- **Never commit host SSH-agent forwarding** (a compose bind of a host `ssh-auth.sock` or
  `$SSH_AUTH_SOCK` into `web`). Every process in the container - Composer plugins and
  scripts, npm lifecycle scripts, CMS plugin code - can then ask that agent to sign with
  every key it holds, on every start, for every teammate who clones the repository. A
  password manager's agent typically holds all of a developer's keys. The private key
  never leaves the agent, but signing is all an attacker needs. The forwarding socket
  path also only exists on some Docker providers.
- `scripts/audit-ddev-config.py` flags the forwarding (`ssh-agent-forwarded`).
- Stale host keys: `ddev exec ssh-keygen -f /home/.ssh-agent/known_hosts -R <host>`.
