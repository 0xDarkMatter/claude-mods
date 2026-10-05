# DDEV (Local Development)

DDEV is the default local environment for Craft (Docker-based; a `craftcms` project
type ships with it). Facts from the [DDEV docs](https://docs.ddev.com/en/stable/) and
[Craft install docs](https://craftcms.com/docs/5.x/install.html), checked 2026-10-05.

## Contents

- [New project](#new-project)
- [Existing project](#existing-project)
- [Daily commands](#daily-commands)
- [Database: import, snapshots, pull, push](#database-import-snapshots-pull-push)
- [Xdebug and profiling](#xdebug-and-profiling)
- [Node, Vite, and the queue](#node-vite-and-the-queue)
- [Versions to pin](#versions-to-pin)

## New project

```bash
mkdir my-site && cd my-site
ddev config --project-type=craftcms --docroot=web
ddev start
ddev composer create-project "craftcms/craft"   # runs `craft install` (setup wizard)
```

The starter's post-create script copies `.env.example.dev` to `.env` and runs the
installer. DDEV itself does **not** write your `.env`; it injects container env vars via
`.ddev/.env.web` - `CRAFT_DB_SERVER=db`, `CRAFT_DB_DATABASE/USER/PASSWORD=db`,
`PRIMARY_SITE_URL`, Mailpit SMTP settings - which Craft reads. Opt out with
`disable_settings_management: true` in `.ddev/config.yaml`.

## Existing project

```bash
ddev config --project-type=craftcms --docroot=web   # once; commit .ddev/config.yaml
ddev start
ddev composer install
ddev import-db --file=backup.sql.gz                 # or: ddev craft db/restore backup.sql
ddev craft up                                       # migrations + Project Config
ddev npm ci && ddev npm run build                   # if the build runs in the container
ddev launch                                         # open the site
```

Commit `.ddev/config.yaml` (and `.ddev/providers/*.yaml`, any `web-build/` Dockerfile)
so every developer gets the same PHP, database, and Node versions.

## Daily commands

| Task | Command |
|------|---------|
| Any Craft CLI command | `ddev craft <cmd>` - built in for the `craftcms` type; runs `php craft` in the project root |
| Apply migrations + Project Config | `ddev craft up` |
| Clear caches | `ddev craft clear-caches/all` |
| Rebuild Project Config from the DB / apply YAML | `ddev craft project-config/rebuild` / `project-config/apply` |
| Run queued jobs | `ddev craft queue/run` |
| Composer / npm | `ddev composer ...` / `ddev npm ...` |
| Shell in the web container | `ddev ssh` |
| Mail catcher | `ddev mailpit` |
| Database GUI | `ddev tableplus` / `ddev sequelace` / `ddev phpmyadmin` (add-on) |

## Database: import, snapshots, pull, push

| Task | Command |
|------|---------|
| Import a dump | `ddev import-db --file=dump.sql.gz` |
| Export | `ddev export-db --file=dump.sql.gz` |
| Snapshot before risky work | `ddev snapshot --name=before-upgrade` |
| Roll back | `ddev snapshot restore before-upgrade` (or `--latest`) |
| Pull DB + files from a host | `ddev pull <provider>` |
| Push DB + files to a host | `ddev push <provider>` |

Source: [database management](https://docs.ddev.com/en/stable/users/usage/database-management/).
Snapshots live in `.ddev/db_snapshots` - take one before every Craft upgrade or content
migration; restore takes seconds.

**Providers** ([hosting providers](https://docs.ddev.com/en/stable/users/providers/))
are YAML recipes in `.ddev/providers/<name>.yaml`. Built in: Acquia, Lagoon, Pantheon,
Platform.sh/Upsun. For a typical VPS or managed Craft host, start from
`rsync.yaml.example` (SSH + mysqldump + rsync; needs `ddev auth ssh`). Pull and push
move **database and user files only**, never code - code goes through git.
Flags: `--skip-db`, `--skip-files`, `-y`.

**`ddev push` overwrites the upstream database.** DDEV's own docs call it potentially
"very dangerous" to production. Delete the `push` stanza from provider files that point
at production; content flows down (prod → local), schema flows up via Project Config.

## Xdebug and profiling

```bash
ddev xdebug on        # also: off, toggle, status
ddev xdebug off       # when done - it slows every request
```

Port 9003. PhpStorm: map the project root to `/var/www/html`, and the server name must
equal the DDEV host (`my-site.ddev.site`). VS Code: the PHP Debug extension with a
"Listen for Xdebug" launch config. Troubleshoot with `ddev utility xdebug-diagnose`.
CLI debugging works too (`PHP_IDE_CONFIG` is preset), e.g. for a failing
`ddev craft` command. Source:
[step debugging](https://docs.ddev.com/en/stable/users/debugging-profiling/step-debugging/).

Profiling: `ddev xhprof on` and `ddev xhgui` for flame-graph style views of a slow
request - pair with the levers in [performance.md](performance.md).

## Node, Vite, and the queue

- Pin Node with `nodejs_version` in `.ddev/config.yaml`; run tools via `ddev npm`/`ddev npx`.
- Vite's dev server needs a port exposed through `web_extra_exposed_ports` (set
  `name`, `container_port`, `http_port`, **and** `https_port` - omitting one breaks the
  router). Full Craft wiring: [craft-vite.md](craft-vite.md#running-the-dev-server-in-ddev)
  and DDEV's [Vite page](https://docs.ddev.com/en/stable/users/usage/vite/).
- **Queue:** locally, Craft's default HTTP-triggered queue (`runQueueAutomatically`
  true) is usually fine. If you turned it off to mirror production, either set
  `CRAFT_RUN_QUEUE_AUTOMATICALLY=true` locally or run `ddev craft queue/listen --verbose`
  in a terminal. A supervised background runner via DDEV's `web_extra_daemons` also
  works - that pairing is a common pattern, not one either project documents.

## Versions to pin

| Setting | Craft 5 | Notes |
|---------|---------|-------|
| `php_version` | `"8.3"` (8.2 minimum) | DDEV's global default is 8.4; pin to match production |
| `database` | `mysql:8.0` | DDEV's `craftcms` type defaults to MySQL 8.0; Craft 5 recommends MySQL 8.0.36+ or PostgreSQL 16+ and discourages MariaDB for large sites |
| Craft 4 | `php_version: "8.1"`/`"8.2"`, MySQL 5.7.8+/8.0 | Craft 4 needs PHP 8.0.2+ |
| Craft 6 (alpha) | `--project-type=laravel --docroot=public`, PHP 8.5, MySQL 8.4 | Per the 6.x alpha install docs; not for client work yet |

Requirements source: [Craft 5 requirements](https://craftcms.com/docs/5.x/requirements.html).
Match production's PHP minor - a site built on 8.4 locally and deployed to 8.2 fails at
runtime, not at deploy.
