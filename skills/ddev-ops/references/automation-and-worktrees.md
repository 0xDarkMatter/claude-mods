# Scripting DDEV, Destructive Commands and Several Checkouts

How an agent or script should drive DDEV, what destroys data, and how to run several
checkouts of one repository (git worktrees) at once. Facts from DDEV's commands, CLI,
config, FAQ and managing-projects docs at DDEV v1.25.4, its source
(`pkg/ddevapp/ddevapp.go` `Describe`, `cmd/ddev/cmd/list.go`), and Docker's
`volume prune` reference, checked 2026-10-06. "Observed" marks behaviour seen in
throwaway projects on DDEV v1.25.4 (Docker Desktop, WSL2) that day.

## Contents

- [Run DDEV without a terminal](#run-ddev-without-a-terminal)
- [Machine-readable output](#machine-readable-output)
- [Commands that destroy data](#commands-that-destroy-data)
- [Several checkouts of one repository](#several-checkouts-of-one-repository)
- [Renaming and moving a project](#renaming-and-moving-a-project)

## Run DDEV without a terminal

- **Always name a subcommand.** Bare `ddev` opens an interactive dashboard;
  `DDEV_NO_TUI=true` (or global `no_tui: true`) makes it print help instead.
- **Always pass flags to `ddev config`.** With none it asks questions. It keeps existing
  values unless told otherwise; `ddev config --update` re-detects type and docroot.
- **Answer prompts up front:** `ddev import-db --file=<dump>`, `ddev import-files
  --source=<path>`, and `-y` (`--yes` / `--skip-confirmation`) on `delete`,
  `delete images`, `snapshot`, `start --reset-database`, `pull`, `push` and `clean`.
- **Quote for the container.** `ddev exec` runs its command through bash inside the
  container, so single-quote anything with `$`, pipes or redirects:
  `ddev exec 'echo "$DDEV_PRIMARY_URL" | tee /tmp/url'`. Double quotes let the host
  shell expand it first.
- **Gate on the DDEV version** a script needs: `ddev utility match-constraint '>= 1.25.4'`
  (non-zero exit when it doesn't match), or `ddev_version_constraint` in `config.yaml`.
- **Don't trust exit 0 from these two.** Observed with v1.25.4:
  - `ddev snapshot` with a name that already exists prints an error, saves nothing and
    exits 0. The old file is still there, so checking for `.ddev/db_snapshots/<name>-*`
    afterwards proves nothing. Use a name to the second (`$(date +%Y%m%d%H%M%S)`); a
    script that must be sure checks that no such file exists *before* it runs.
  - `ddev add-on remove` exits 0 but leaves files without a `#ddev-generated` line,
    printing "Unwilling to remove '<path>'" for each. `git status` shows only the ones
    never committed. Read those lines and delete only files nobody took over on purpose.

## Machine-readable output

`-j` / `--json-output` works on every command; the data sits under `.raw`:

```bash
ddev describe -j | jq -r '.raw.primary_url'              # the project URL
ddev describe -j | jq -r '.raw.status'                   # running, stopped, ...
ddev describe -j | jq -r '.raw.dbinfo.published_port'    # database port on the host
ddev list -j | jq -r '.raw[] | [.name, .status, .approot] | @tsv'
ddev launch --print-url                                  # URL only, no browser
```

Other `describe` fields: `name`, `approot`, `docroot`, `httpsurl`, `httpurl`, `urls`,
`hostnames`, `type`, `database_type`, `database_version`, `nodejs_version`,
`performance_mode`, `mailpit_url`, `xhgui_url`, and `dbinfo.host`/`dbPort`/`username`/
`password`/`dbname`.

- **The host database port changes on every `ddev start`** unless `host_db_port` is set.
  Set it in `.ddev/config.local.yaml`, with a different port per project.
- **Inside the container** the database is always host `db`, port 3306 (5432 for
  Postgres), user, password and database `db`.

## Commands that destroy data

Confirm with the user before running anything in the "Destroys" column. `ddev snapshot`
(or `ddev snapshot --all`, which starts stopped projects to snapshot them) first.

| Command | Destroys | Notes |
|---|---|---|
| `ddev delete [project]` | Containers and the project's database | Snapshots first unless `-O`/`--omit-snapshot` |
| `ddev stop --remove-data` | The database | Plain `ddev stop` keeps it |
| `ddev start --reset-database` | The database | Snapshots first unless `-O` |
| `ddev import-db` | Everything already in the target database | It empties the database first; `--no-drop` keeps it |
| `ddev import-files` | The current upload directory's contents | It empties the destination first |
| `ddev snapshot --cleanup` | All snapshots of the project | `--name <x>` removes just one |
| `ddev clean [--all]` | Most of what DDEV created for those projects | Preview with `--dry-run` |
| `ddev push <provider>` | The upstream database and files | Never against production |
| `docker volume prune -a` | Every named volume not attached to a container | After `ddev stop`, that is every stopped project's database. Plain `docker volume prune` only removes anonymous volumes |
| Docker provider factory reset, or switching provider | Every DDEV database | Databases live only in the provider's volumes |
| `ddev poweroff` | Nothing | Stops every project on the machine, including other sessions' |

**Safe disk recovery:**
- Run `ddev delete images` (old DDEV image versions).
- Run `docker builder prune`.
- Run `ddev mutagen reset` on a project whose sync volume is huge.
- Find the offenders with `ddev utility mutagen-diagnose --all` and `docker system df`.

## Several checkouts of one repository

Git worktrees, a second clone, an agent's lane: each is a separate DDEV project, and
**project names must be unique on a machine**. A `name:` committed in `config.yaml` makes
every checkout claim the same project, and the second `ddev start` refuses.

- **Preferred:** don't commit `name:`. Without it DDEV names the project after its
  directory. Run `ddev config global --omit-project-name-by-default` so `ddev config`
  stops writing it back. DDEV's docs recommend this for worktree users.
- **If the name must stay committed**, override it per checkout in
  `.ddev/config.local.yaml` (`name: site-feature-x`).
- **A fresh checkout doesn't ignore `config.local.yaml` yet.** The rule lives in
  DDEV's generated `.ddev/.gitignore`, which is itself untracked. A new clone or worktree
  has none until a `ddev config` or a successful `ddev start` writes it, and a start that
  fails on the name clash doesn't. Observed: `git status` showed
  `?? .ddev/config.local.yaml`, so a `git add -A` would commit it and every checkout would
  inherit that name. Add `.ddev/config*.local.y*ml` to the project root's `.gitignore`;
  the auditor flags a tracked one (`local-file-committed`).
- **Each checkout starts with an empty database.** `ddev snapshot restore` also offers
  snapshots from sibling worktrees of the same repository (v1.25.4), or use
  `ddev start --seed-snapshot=<name>`.
- **Keep these different per checkout:** `host_db_port` and `host_webserver_port` if set,
  and `additional_hostnames`. Duplicate hostnames across running projects make the router
  unhealthy.
- **Settings management follows the new name:** DDEV rewrites its generated settings (for
  Craft, `.ddev/.env.web` with `PRIMARY_SITE_URL`) for each checkout.
- **Before deleting a checkout's folder**, run `ddev delete -Oy` inside it. Otherwise its
  database volume and project entry are orphaned.

## Renaming and moving a project

Per DDEV's FAQ:

- **Rename:** run these steps in order.
  1. `ddev export-db --file=<dump>`
  2. `ddev delete` (snapshots by default)
  3. `rm -r .ddev/traefik/config` (it can hold the old name)
  4. `ddev config --project-name=<new>`
  5. `ddev start`
  6. `ddev import-db --file=<dump>`
- **Move to another directory:** `ddev stop --unlist`, move the folder, then `ddev start`
  in the new place.
- **Move to another machine:**
  1. On the old machine: `ddev start && ddev snapshot`, then `ddev stop --unlist`.
  2. Copy the folder across.
  3. On the new machine: `ddev start && ddev snapshot restore --latest`.
- **From traditional Windows into WSL2:** the same steps as moving to another machine,
  copying the project into the WSL2 filesystem (`~/sites/<project>`), not `/mnt/c`.
