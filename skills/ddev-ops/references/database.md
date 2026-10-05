# Database Workflows

Facts from DDEV's database-management, hosting-provider and command docs at DDEV v1.25.4,
checked 2026-10-05.

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
| Import (`.sql`, `.sql.gz`, `.mysql(.gz)`, `.tar(.gz)`, `.zip`) | `ddev import-db --file=dump.sql.gz` |
| Import into an extra database (created on demand) | `ddev import-db --database=legacy --file=legacy.sql.gz` |
| Export | `ddev export-db --file=dump.sql.gz` (`--database=<name>` for another) |
| Client shell | `ddev mysql`, `ddev mariadb`, `ddev psql` |
| One query | `ddev mysql -e 'SHOW TABLES;'` |
| GUI | `ddev sequelace`, `ddev tableplus`, `ddev tablepro` (macOS), `ddev dbeaver`, `ddev heidisql`; `ddev add-on get ddev/ddev-phpmyadmin` or `ddev/ddev-adminer` |
| Host-side client | `ddev describe` shows host and port; set `host_db_port` in `config.local.yaml` for a fixed port |

Inside the containers the database host is `db` with database, user and password `db`
(root/root for admin). Those are local-only values, not secrets.

## Snapshots

A snapshot saves the whole database server state (every database) to
`.ddev/db_snapshots/`, zstd-compressed since v1.25.0.

```bash
ddev snapshot --name=before-upgrade     # take one before risky work
ddev snapshot --list                    # size and database version of each
ddev snapshot restore before-upgrade    # or: --latest, or no name for a picker
ddev snapshot --cleanup                 # delete them all (prompts)
```

- **Take one before** every migration, CMS upgrade, content import or `ddev pull`. DDEV's
  provider docs suggest a `pre-pull` hook for the pull case:

  ```yaml
  hooks:
    pre-pull:
      - exec-host: ddev snapshot --name=pre-pull
  ```
- **Git worktrees share them** (v1.25.4): `ddev snapshot restore` also offers snapshots
  from other worktrees of the same repository, so a lane can restore the main
  checkout's data without copying files.
- **Seed a fresh database** (v1.25.4): a snapshot named `seed` loads automatically when a
  project starts with an empty database volume. `ddev start --seed-snapshot=<name|path>`
  picks another for one start. A snapshot only seeds the type and version that made it,
  so keep the `-<type>_<version>` suffix on its file name.
- **Start over:** `ddev start --reset-database` snapshots, deletes and recreates the
  database (`-O` skips the snapshot, `-y` skips the prompt); combine it with
  `--seed-snapshot`.
- `ddev snapshot restore --force` restores a snapshot from a different version of the
  same server; `--uncompressed` trades disk for faster restores of huge databases.

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
  (`live.yaml` gives `ddev pull live`). Built in: Upsun (Fixed and Flex), Acquia, Lagoon;
  examples for Pantheon, git, local files and `rsync` sit beside them as `*.example`. The
  old Platform.sh add-on is deprecated in favour of `ddev/ddev-upsun`.
- **Stanzas:** `auth_command`, `db_pull_command` (leave a gzipped dump at
  `/var/www/html/.ddev/.downloads/db.sql.gz`), `files_pull_command` (into
  `.ddev/.downloads/files`), optional `db_import_command`/`files_import_command`, and
  `db_push_command`/`files_push_command`.
- **Typical VPS or managed PHP host:** start from `rsync.yaml.example` - it runs in the web
  container over SSH, so load one key first with `ddev auth ssh -f <key>`.
- **Flags:** `--skip-db`, `--skip-files`, `--skip-import` (download only), `-y`,
  `--environment=KEY=value,...`. Debug a recipe by uncommenting its `set -x` and running
  each command by hand inside `ddev ssh`.
- **`ddev push` overwrites the upstream database and files.** Delete the push stanzas from
  any recipe that can reach production; content flows down, schema flows up through
  migrations or project config. `scripts/audit-ddev-config.py` flags recipes that can
  push (`provider-push`).

## Production data on laptops

A raw production dump puts real people's personal data and password hashes on every
laptop that pulls it. The default should be: **sanitise where the data lives, pull the
result.**

1. **Produce a sanitised artifact upstream.** A scheduled job on the server (or a staging
   copy) writes `sanitized.sql.gz`. One tool for MySQL/MariaDB is `smile/gdpr-dump`
   (Composer package, v5 as of 2026-10-05), which anonymises columns during the dump from
   a YAML rule file. The floor, with no tool: `mysqldump --ignore-table` for sessions,
   tokens, logs and queue tables.
2. **Pull only that artifact.** [`assets/sanitized-pull.yaml.example`](../assets/sanitized-pull.yaml.example)
   is a pull-only rsync recipe for it: no push stanzas, no files by default.
3. **Fix local-only settings after import** with a `post-import-db` hook (site URLs,
   disabling outbound mail or webhooks). That is hygiene, not sanitising: by the time it
   runs, the data is already on the disk.
4. **Share the result** as a `seed` snapshot or a team-internal artifact instead of every
   developer pulling from production.

Why it matters, and what else crosses environments (mail transports, keys, API tokens):
security-ops' `ddev-config-drift.md`.

## Import troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Unknown collation `utf8mb4_0900_ai_ci` or `utf8mb4_uca1400_ai_ci` | Dump from newer MySQL/MariaDB into an older or different server | Pin the same engine as production; rewrite the collation in the dump as a last resort |
| `ddev start` refuses after a `database:` edit | Data made by another server | [Changing the database engine](#changing-the-database-engine) |
| Pull hangs at auth | No key in the agent | `ddev auth ssh -f <key>`; test with `ddev ssh` then `ssh <host>` |
| `Host key verification failed` inside the container | Stale `known_hosts` in the agent container | `ddev exec ssh-keygen -f /home/.ssh-agent/known_hosts -R <host>` |
| Import works, site shows production URLs | Base URL stored in the database | `post-import-db` hook with the CMS's own URL tool |
