# Database Workflows

Facts from DDEV's database-management, hosting-provider, customisation and command docs
at DDEV v1.25.4, and its source (`provider.go`, `ddevapp.go`), checked 2026-10-06.
"Observed" marks behaviour seen in throwaway projects on DDEV v1.25.4 (Docker Desktop,
WSL2) that day.

## Contents

- [Import, export, connect](#import-export-connect)
- [Snapshots](#snapshots)
- [Changing the database engine](#changing-the-database-engine)
- [Pulling from hosting](#pulling-from-hosting)
- [Production data on laptops](#production-data-on-laptops)
- [Import troubleshooting](#import-troubleshooting)

## Import, export, connect

| Task | Command |
|---|---|
| Import (`.sql`, `.sql.gz`, `.mysql(.gz)`, `.tar(.gz)`, `.zip`) | `ddev import-db --file=dump.sql.gz`. It **empties the target database first**; `--no-drop` keeps existing tables |
| Import into an extra database (created on demand) | `ddev import-db --database=legacy --file=legacy.sql.gz` |
| Export | `ddev export-db --file=dump.sql.gz` (`--database=<name>` for another) |
| Client shell | `ddev mysql`, `ddev mariadb`, `ddev psql` |
| One query | `ddev mysql -e 'SHOW TABLES;'` |
| GUI | `ddev sequelace`, `ddev tableplus`, `ddev tablepro` (macOS), `ddev dbeaver`, `ddev heidisql`; `ddev add-on get ddev/ddev-phpmyadmin` or `ddev/ddev-adminer` |
| Host-side client | `ddev describe` shows host and port; set `host_db_port` in `config.local.yaml` for a fixed port |
| Another project's database | Host `ddev-<project>-db` from inside a container |

Inside the containers the database host is `db` with database, user and password `db`
(root/root for admin). Those are local-only values, not secrets.

Server settings go in `.ddev/mysql/<name>.cnf`, which needs a `[mysqld]` header, then
`ddev restart`. DDEV already sets `max_allowed_packet` to 256M.

## Snapshots

A snapshot saves the whole database server state (every database) to
`.ddev/db_snapshots/`, zstd-compressed since v1.25.0.

```bash
ddev snapshot --name=before-upgrade-$(date +%Y%m%d%H%M%S)   # names must be unique
ddev snapshot --list                    # size and database version of each
ddev snapshot restore <name>            # or: --latest, or no name for a picker
ddev snapshot --cleanup                 # delete all (prompts; -y skips); --name <x> for one
```

- **Names must be unique, and a clash still exits 0.** Reusing one prints "snapshot ...
  already exists" in red and saves nothing, but DDEV reports it as a warning
  (`cmd/ddev/cmd/snapshot.go`, which does the same for every snapshot error), so the exit
  code is 0. Put a timestamp to the second in any name a script or hook reuses. To be
  sure, check that no `.ddev/db_snapshots/<name>-*` exists before and that one does after;
  the old file survives a clash, so existence afterwards alone proves nothing.
- **Take one before** every migration, CMS upgrade, content import or `ddev pull`. DDEV's
  provider docs suggest a `pre-pull` hook for the pull case. Timestamp its name: with a
  fixed name every pull after the first runs with no new snapshot, and
  `fail_on_hook_fail: true` can't stop it, because it only reacts to a non-zero exit.
  Observed with v1.25.4: with a fixed name the second pull exited 0 and re-imported over
  the data; with the timestamped hook below, each pull left its own snapshot. For a pull
  that must stop when no snapshot was saved, the hook has to check for the file itself and
  exit non-zero, with `fail_on_hook_fail: true` set.

  ```yaml
  hooks:
    pre-pull:
      - exec-host: ddev snapshot --name=pre-pull-$(date +%Y%m%d%H%M%S)
  ```
- **Git worktrees share them** (v1.25.4): `ddev snapshot restore` also offers snapshots
  from other worktrees of the same repository, so a new checkout can restore the main
  checkout's data without copying files.
- **Seed a fresh database** (v1.25.4): a snapshot named `seed` loads automatically when a
  project starts with an empty database volume. `ddev start --seed-snapshot=<name|path>`
  picks another for one start. A snapshot only seeds the type and version that made it,
  so keep the `-<type>_<version>` suffix on its file name.
- **To share a seed through git,** force-add it: `git add -f .ddev/db_snapshots/seed-*`.
  DDEV's generated `.ddev/.gitignore` ignores `db_snapshots`, so a plain add silently
  skips it.
- **Start over:** `ddev start --reset-database` snapshots, deletes and recreates the
  database (`-O` skips the snapshot, `-y` skips the prompt); combine it with
  `--seed-snapshot`.
- **Restoring across versions:** `ddev snapshot restore --force` restores a snapshot made
  by a different version of the same server.
- **Big databases:** `ddev snapshot --uncompressed` *takes* an uncompressed snapshot
  (more disk, faster restore). A restore longer than the default 120-second timeout needs
  a larger `default_container_timeout`; a timeout doesn't mean it failed
  (`ddev logs -s db` shows it finishing).

## Changing the database engine

Editing `database:` alone makes `ddev start` refuse: the existing data was created by the
old server.

```bash
ddev export-db --file=before-engine-change.sql.gz
ddev config --database=mysql:8.0         # now warns instead of failing (v1.25.4)
ddev start --reset-database              # snapshots the old data first
ddev import-db --file=before-engine-change.sql.gz
ddev utility check-db-match              # running server matches config.yaml?
```

For MySQL or MariaDB targets, `ddev utility migrate-database mysql:8.0` does the export,
snapshot, recreate and import in one step and updates `config.yaml` (default `db`
database only; not Postgres).

## Pulling from hosting

`ddev pull <provider>` downloads the **database and user-uploaded files** from upstream;
`ddev push <provider>` uploads them. Neither moves code - code goes through git and your
deploy pipeline.

- **Recipes** are YAML files in `.ddev/providers/`; the file name is the provider name
  (`live.yaml` gives `ddev pull live`).
  - **Ready-made, generated into every project:** `acquia.yaml`, `lagoon.yaml`,
    `pantheon.yaml`, `platform.yaml` (Upsun Fixed / Platform.sh) and `upsun.yaml`
    (Flex). They're DDEV-generated and gitignored.
  - **Examples:** `git`, `localfile` and `rsync`, as `*.example`.
  - DDEV's GitHub marks the separate `ddev-platformsh` add-on deprecated in favour of
    `ddev/ddev-upsun`.
- **Stanzas:**
  - `auth_command`;
  - `db_pull_command`: leave a gzipped dump at `/var/www/html/.ddev/.downloads/db.sql.gz`;
  - `files_pull_command`: put files into `.ddev/.downloads/files`;
  - optional `db_import_command` / `files_import_command`;
  - `db_push_command` / `files_push_command`.
- **`files_pull_command` can wipe your uploads.** If the stanza exists but downloads
  nothing (DDEV's docs suggest `true` when "nothing has to be done"), DDEV imports the
  empty download folder, and the import **empties the upload directory first**
  (`doFilesPullCommand` -> `doFilesImport` -> `ImportFiles`). Observed with v1.25.4: the
  pull exited 0 with the upload folder empty. With no stanza DDEV printed "No
  files_pull_command provided, so skipping files pull" and the files survived, as they
  did with `--skip-files`. Delete the stanza, or always pass `--skip-files`. The auditor
  flags it (`provider-files-noop`).
- **A plain VPS over SSH,** dumping live (load a key first with `ddev auth ssh -f <key>`):

  ```yaml
  # .ddev/providers/staging.yaml - pull-only, no files stanza (see above)
  environment_variables:
    sshtarget: deploy@staging.example.com
    remotedb: site_staging
  db_pull_command:
    command: |
      set -eu -o pipefail
      ssh "${sshtarget}" "mysqldump --single-transaction --no-tablespaces ${remotedb}" | gzip > /var/www/html/.ddev/.downloads/db.sql.gz
    service: web
  ```

  The server needs its own MySQL credentials (e.g. `~/.my.cnf`). `--no-tablespaces`
  avoids the PROCESS-privilege error on MySQL 8 hosts. This pulls whatever that
  database holds, so use it on sanitised staging data only (next section).
- **One-off, no recipe:** on the host run
  `ssh <host> "mysqldump --single-transaction <db>" | gzip > dump.sql.gz`, then
  `ddev import-db --file=dump.sql.gz`.
- **Pull flags:**
  - `--skip-db`, `--skip-files`;
  - `--skip-import` (download only);
  - `-y`;
  - `--environment=KEY=value,...`.

  To debug a recipe, uncomment its `set -x` and run each command by hand inside
  `ddev ssh`.
- **`ddev push` overwrites the upstream database and files.** Delete the push stanzas from
  any recipe of your own that can reach production. Content flows down; schema flows up
  through migrations or project config. The auditor flags such recipes
  (`provider-push`), skipping DDEV's generated ones.

## Production data on laptops

A raw production dump puts real people's personal data and password hashes on every
laptop that pulls it. The default should be: **sanitise where the data lives, pull the
result.**

1. **Produce a sanitised artifact upstream.** A scheduled job on the server (or a staging
   copy) writes `sanitised.sql.gz`.
   - One tool for MySQL/MariaDB is `smile/gdpr-dump` (Composer package; 5.0.7 on
     Packagist as of 2026-10-05). It anonymises columns during the dump from a YAML
     rule file.
   - The floor, with no tool: `mysqldump --ignore-table` for sessions, tokens, logs and
     queue tables.
2. **Pull only that artifact.**
   [`assets/sanitized-pull.yaml.example`](../assets/sanitized-pull.yaml.example) is a
   database-only rsync recipe for it: no push stanzas and no files stanza.
3. **Fix local-only settings after import** with a `post-import-db` hook: site URLs, and
   disabling outbound mail or webhooks. That is hygiene, not sanitising: by the time it
   runs, the data is already on the disk.
4. **Share the result** as a `seed` snapshot or a team-internal artifact instead of every
   developer pulling from production.

Why it matters, and what else crosses environments (mail transports, keys, API tokens):
security-ops' `ddev-config-drift.md`.

## Import troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Unknown collation `utf8mb4_0900_ai_ci` or `utf8mb4_uca1400_ai_ci` | Dump from newer MySQL/MariaDB, imported by a route that doesn't translate it | Import with `ddev import-db`, which swaps these for the server's `collation-server`; set that in `.ddev/mysql/*.cnf` (`[mysqld]` header). `ddev mysql < dump` and CMS restore commands (e.g. `ddev craft db/restore`) don't swap them |
| Rows from an old import still there | `--no-drop`, or a dump without `DROP TABLE` | Re-import without `--no-drop`, or `ddev start --reset-database` first |
| Big import stalls or fails | Low Docker disk space | Free space (`ddev delete images`, `docker builder prune`); `max_allowed_packet` is already 256M |
| `ddev start` refuses after a `database:` edit | Data made by another server | [Changing the database engine](#changing-the-database-engine) |
| Pull hangs at auth | No key in the agent | `ddev auth ssh -f <key>`; test with `ddev ssh` then `ssh <host>` |
| `Host key verification failed` inside the container | Stale `known_hosts` in the agent container | `ddev exec ssh-keygen -f /home/.ssh-agent/known_hosts -R <host>` |
| Import works, site shows production URLs | Base URL stored in the database | `post-import-db` hook with the CMS's own URL tool |
