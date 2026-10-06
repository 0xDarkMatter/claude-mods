# Extending DDEV: Add-ons, Commands, Hooks, Services

Facts from DDEV's add-on, custom-command, hooks, customisation, custom-compose and
managing-projects docs at DDEV v1.25.4, and its source (`cmd/ddev/cmd/commands.go`,
`ddevapp.go` `ProcessHooks`), checked 2026-10-06.

## Contents

- [Add-ons](#add-ons)
- [Custom commands](#custom-commands)
- [Hooks](#hooks)
- [Background processes](#background-processes)
- [Web server configuration](#web-server-configuration)
- [Extra services and custom images](#extra-services-and-custom-images)
- [Networking between projects and to the host](#networking-between-projects-and-to-the-host)
- [SSH keys inside containers](#ssh-keys-inside-containers)

## Add-ons

Use an add-on for a standard service (Redis, search, cron); hand-write a
`docker-compose.<name>.yaml` only for something no add-on covers.

```bash
ddev add-on search redis                        # or browse addons.ddev.com
ddev add-on get ddev/ddev-redis --version <tag> # pin the add-on's current release tag
ddev add-on list --installed
ddev add-on update --dry-run                    # v1.25.4: check every installed add-on
ddev add-on remove redis
ddev restart
```

- **Review before installing.** An add-on's Bash install actions run directly on your
  machine (PHP actions run in a temporary container). Read its `install.yaml` and compose
  file first, prefer the official `ddev/` add-ons, and pin `--version` to a tag from the
  add-on's releases page (DDEV's docs show old example tags).
- **What it writes:**
  - `docker-compose.<name>.yaml`;
  - maybe `config.<name>.yaml`;
  - commands;
  - `addon-metadata/<name>/`.

  Commit all of it so teammates get the same services.
- **Customise without forking:**
  - set the variables the add-on's own README documents in `.ddev/.env.<addon>`, for
    example `ddev dotenv set .ddev/.env.redis --redis-docker-image=redis:7` for
    ddev-redis v2 (DDEV's docs still show an older `--redis-tag` variable);
  - put tokens in `.ddev/.env.<addon>.local` (v1.25.4), kept out of git as
    [config-and-env.md](config-and-env.md#what-to-commit) says;
  - or override in a separate `docker-compose.<name>_extra.yaml` so updates do not
    clobber your change.
- **`ddev add-on remove` deletes only files carrying `#ddev-generated`.** Any other file the
  add-on installed stays put (DDEV prints "Unwilling to remove ..."). Delete those by hand
  and check `git status`.
- **Connecting:** services are reached by service name from the web container, e.g. Redis
  at `redis:6379`.
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
- **Useful annotations:**
  - `ExecRaw: true`: pass arguments untouched (DDEV recommends it for every container
    command);
  - `MutagenSync: true`: sync before and after (for commands that write files);
  - `HostWorkingDir: true`;
  - `ProjectTypes`;
  - `OSTypes` and `HostBinaryExists` (host commands only);
  - `DBTypes`, `Flags`, `AutocompleteTerms`, `CanRunGlobally`.
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
- **A failing hook only warns**, and the command carries on. With
  `fail_on_hook_fail: true` (project or global), any failing hook aborts its command,
  whether that's `start`, `pull`, `import-db` or another. Hooks must not prompt.
- **Keep `post-start` fast:** an `npm install` there runs on every start for every
  teammate.

## Background processes

`web_extra_daemons` starts long-running processes with the web container and supervises
them; their output goes to `ddev logs`.

```yaml
web_extra_daemons:
  - name: queue
    command: php artisan queue:work --tries=3
    directory: /var/www/html
```

Restart them without restarting the project:
`ddev exec supervisorctl restart 'webextradaemons:*'` (or `webextradaemons:<name>`).
Front-end dev servers use the same mechanism: [frontend-node.md](frontend-node.md).

## Web server configuration

- **Prefer snippets.** Add a file under `.ddev/nginx/` (for example `redirects.conf`); DDEV
  includes it in the generated server block, so you keep receiving DDEV's updates.
  Then `ddev restart`.
- **Full take-over** is the last resort: delete the `#ddev-generated` line from
  `.ddev/nginx_full/nginx-site.conf` (or `.ddev/apache/apache-site.conf` with
  `webserver_type: apache-fpm`) and edit it.
  - Keep the `/phpstatus` alias: DDEV's health check needs it. DDEV's troubleshooting
    docs name a user-defined site config as the most common cause of
    "web service unhealthy".
- **Test before restarting:** `ddev exec nginx -t` or `ddev exec apachectl -t`.
- **The config is copied into the container on restart,** so edit the host file and
  `ddev restart`; editing the copy inside the container is lost.

## Extra services and custom images

- **Extra service:** add `.ddev/docker-compose.<name>.yaml` with a `services:` block
  (docker-ops covers Compose syntax). DDEV's conventions:
  - `container_name: "ddev-${DDEV_SITENAME}-<service>"`.
  - HTTP(S) UIs go through the router: `expose:` the internal port and set
    `VIRTUAL_HOST=$DDEV_HOSTNAME`, `HTTP_EXPOSE=<router>:<internal>` and
    `HTTPS_EXPOSE=...`. Avoid `ports:`: it binds the host and blocks a second project
    with the same service. Keep `ports:` only for non-HTTP protocols.
  - Mount `ddev-global-cache:/mnt/ddev-global-cache` if the service should run DDEV
    custom commands.
  - Never edit `.ddev/.ddev-docker-compose-base.yaml` or `-full.yaml`: DDEV rewrites
    them on every start.
  - `ddev utility compose-config` shows the merged result.
- **Extra Debian packages:** `webimage_extra_packages`. For example, the `webp`,
  `jpegoptim`, `optipng` and `gifsicle` binaries that image-optimising plugins call, or
  `php${DDEV_PHP_VERSION}-<ext>` for a PHP extension.
- **Anything more:** `.ddev/web-build/Dockerfile` (or `Dockerfile.<name>`); since v1.25.4,
  `~/.ddev/web-build/` applies to every project.
- **PHP settings:** `.ddev/php/<name>.ini`, starting with `[PHP]` as DDEV's example does.
  Each file is copied into both the CLI and FPM `conf.d`. Database settings go in
  `.ddev/mysql/<name>.cnf` with a `[mysqld]` header. Use both to make DDEV *closer* to
  production, not further away (security-ops' `ddev-config-drift.md` lists the ini
  directives that differ by default).
- **Rebuild after image changes:** `ddev start --no-cache` or `ddev utility rebuild`.
- **Shell niceties:** files in `.ddev/homeadditions/` (or `~/.ddev/homeadditions/`) are
  copied into the container user's home - never commit an `auth.json` or key there.

## Networking between projects and to the host

| From a container, reach | Use |
|---|---|
| Another service in the same project | Its service name (`redis`, `opensearch:9200`, `web`) |
| Another project's database | `ddev-<project>-db` |
| Another project's site | Its project URL, or `https://ddev-<project>-web` (v1.24.10+; HTTPS from a non-web container must trust DDEV's CA) |
| Another project's service | `ddev-<project>-<service>` |
| A service on your machine | `host.docker.internal:<port>`. The host service must listen on `0.0.0.0`, not only `127.0.0.1` |

## SSH keys inside containers

Provider pulls, private Composer repositories and git over SSH need a key inside the
container.

- **Use `ddev auth ssh -f ~/.ssh/<key>`** with one key scoped to what the project needs (a
  deploy or read-only key). It loads into DDEV's own `ddev-ssh-agent` container and stays
  there until `ddev poweroff`. Plain `ddev auth ssh` loads every key in `~/.ssh`.
- **Never commit host SSH-agent forwarding** (a compose bind of a host `ssh-auth.sock` or
  `$SSH_AUTH_SOCK` into `web`).
  - Every process in the container can then ask that agent to sign with every key it
    holds. That includes Composer plugins and scripts, npm lifecycle scripts and CMS
    plugin code.
  - It happens on every start, for every teammate whose machine has that socket.
    `/run/host-services/ssh-auth.sock` is the agent socket of Docker Desktop on macOS and
    Linux, and of OrbStack; a `${SSH_AUTH_SOCK}` bind forwards on native Linux Docker.
  - A password manager's agent typically holds all of a developer's keys. The private key
    never leaves the agent, but signing is all an attacker needs.
  - On Docker Desktop for Windows (WSL2), a file that also sets `SSH_AUTH_SOCK` breaks
    SSH instead. Observed with DDEV v1.25.4: `ddev start` succeeded, Docker mounted an
    empty root-owned directory at that path, and `SSH_AUTH_SOCK` pointed there. `ssh-add
    -l` in `web` failed with "Permission denied". A key loaded with `ddev auth ssh` was
    still in DDEV's agent and answered when asked through DDEV's socket explicitly, but
    anything relying on `SSH_AUTH_SOCK` no longer reached it. Other providers weren't
    tested.
- `scripts/audit-ddev-config.py` flags the forwarding (`ssh-agent-forwarded`).
- Stale host keys: `ddev exec ssh-keygen -f /home/.ssh-agent/known_hosts -R <host>`.
