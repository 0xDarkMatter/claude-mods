# DDEV for Craft (Local Development)

DDEV is the default local environment for Craft (Docker-based; a `craftcms` project
type ships with it). This file holds only what is Craft-specific. Everything generic -
version pinning, `config.local.yaml` and env files, snapshots and `ddev pull` recipes,
sanitised production data, Mutagen and `upload_dirs`, Xdebug, add-ons, the `.ddev/`
auditor and troubleshooting - lives in the [ddev-ops skill](../../ddev-ops/SKILL.md).
Facts from the [DDEV docs](https://docs.ddev.com/en/stable/) and DDEV's
`pkg/ddevapp/craftcms.go` (v1.25.4), and the
[Craft install docs](https://craftcms.com/docs/5.x/install.html), checked 2026-10-05.

## Contents

- [New project](#new-project)
- [Existing project](#existing-project)
- [What DDEV does for the craftcms type](#what-ddev-does-for-the-craftcms-type)
- [Daily commands](#daily-commands)
- [Data and upgrades](#data-and-upgrades)
- [Asset folders and Mutagen](#asset-folders-and-mutagen)
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
installer.

## Existing project

```bash
ddev config --project-type=craftcms --docroot=web   # only if the repo has no .ddev/ yet; commit it
ddev start
ddev composer install
ddev import-db --file=backup.sql.gz                 # prefer over `ddev craft db/restore`: only
                                                    # import-db translates MySQL 8 / MariaDB 11 collations
ddev craft up                                       # migrations + Project Config
ddev npm ci && ddev npm run build                   # if the build runs in the container
ddev launch                                         # open the site
```

## What DDEV does for the craftcms type

- **Env vars:** settings management writes `.ddev/.env.web` (not the project `.env`) with
  `CRAFT_DB_SERVER=db`, `CRAFT_DB_DATABASE/USER/PASSWORD=db`, `CRAFT_DB_PORT`,
  `CRAFT_WEB_ROOT`, `PRIMARY_SITE_URL` and Mailpit SMTP settings, which Craft reads. It
  never writes `CRAFT_SECURITY_KEY`. Opt out with `disable_settings_management: true`.
- **Craft 3 and older:** DDEV warns that settings management targets Craft 4+ and
  suggests the `php` project type or `disable_settings_management: true` instead.
- **Database:** `ddev config --project-type=craftcms` writes `mysql:8.0`, not DDEV's
  global default. Keep it pinned in `config.yaml`.
- **`ddev craft` is built in** for this type and runs `php craft` in the project root. A
  project copy at `.ddev/commands/web/craft` (common in older repositories) shadows the
  built-in and freezes an old version - delete it unless it does something deliberate.
  The ddev-ops auditor reports it as `shadowed-command`.

## Daily commands

| Task | Command |
|------|---------|
| Any Craft CLI command | `ddev craft <cmd>` |
| Apply migrations + Project Config | `ddev craft up` |
| Clear caches | `ddev craft clear-caches/all` |
| Rebuild Project Config from the DB / apply YAML | `ddev craft project-config/rebuild` / `project-config/apply` |
| Run queued jobs | `ddev craft queue/run` |
| Back up / restore the database the Craft way | `ddev craft db/backup` / `ddev craft db/restore <file>` |
| Composer / npm | `ddev composer ...` / `ddev npm ...` |

Generic DDEV commands (snapshots, logs, Mailpit, DB GUIs, diagnostics) are in the
ddev-ops skill's command table.

## Data and upgrades

- **Snapshot before every Craft upgrade or content migration:**
  `ddev snapshot --name=pre-upgrade`; `ddev snapshot restore pre-upgrade` rolls back in
  seconds.
- **Content flows down, schema flows up.** Pull a (sanitised) database with
  `ddev pull <provider>`; schema changes travel as Project Config YAML and migrations,
  applied with `ddev craft up`. Never `ddev push` a database to production - the
  [ddev-ops database reference](../../ddev-ops/references/database.md) covers recipes,
  sanitising and removing push stanzas.
- After importing a production dump, re-run `ddev craft up` so the local Project Config
  YAML wins over whatever the dump carried.

## Asset folders and Mutagen

The `craftcms` type has **no default `upload_dirs`**, so with Mutagen on DDEV syncs asset
uploads and Craft's runtime files unless you list them. Entries resolve from the docroot:

```yaml
# .ddev/config.yaml - docroot: web
upload_dirs:
  - uploads        # web/uploads: each local filesystem's base path under web/
  - ../storage     # Craft's storage/ (runtime, logs, backups) sits beside web/
```

Writing `storage` instead of `../storage` points at `web/storage`, which does not exist;
the auditor reports it as `upload-dir-misplaced`. Mutagen itself: the ddev-ops
performance reference.

## Node, Vite, and the queue

- Pin Node with `nodejs_version` and run tools via `ddev npm`/`ddev npx` (ddev-ops covers
  versions, ports and daemons). craft-vite's dev server under DDEV:
  [craft-vite.md](craft-vite.md#running-the-dev-server-in-ddev).
- **Queue:** locally, Craft's default HTTP-triggered queue (`runQueueAutomatically`
  true) is usually fine. If you turned it off to mirror production, either set
  `CRAFT_RUN_QUEUE_AUTOMATICALLY=true` locally or run `ddev craft queue/listen --verbose`
  in a terminal. A supervised background runner via DDEV's `web_extra_daemons` also
  works - that pairing is a common pattern, not one either project documents.
- **Profiling a slow request:** DDEV's XHGui (`ddev xhgui on`) pairs with the levers in
  [performance.md](performance.md).

## Versions to pin

| Setting | Craft 5 | Notes |
|---------|---------|-------|
| `php_version` | `"8.3"` (8.2 minimum) | DDEV's own default moves between releases; pin to match production |
| `database` | `mysql:8.0` | What the `craftcms` type writes; Craft 5 recommends MySQL 8.0.36+ or PostgreSQL 16+ and discourages MariaDB for large sites |
| Craft 4 | `php_version: "8.1"`/`"8.2"`, MySQL 5.7.8+/8.0 | Craft 4 needs PHP 8.0.2+ |
| Craft 6 (alpha) | `--project-type=laravel --docroot=public`, PHP 8.5, MySQL 8.4 | Per the 6.x alpha install docs; not for client work yet |

Requirements source: [Craft 5 requirements](https://craftcms.com/docs/5.x/requirements.html).
Match production's PHP minor - a site built on 8.4 locally and deployed to 8.2 fails at
runtime, not at deploy.
