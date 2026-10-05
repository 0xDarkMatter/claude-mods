# Troubleshooting Runbook

Facts from DDEV's troubleshooting, command and Docker-installation docs at DDEV v1.25.4,
checked 2026-10-05. `ddev debug` still works as an alias of `ddev utility`.

## Contents

- [First moves](#first-moves)
- [Symptom table](#symptom-table)
- [Ports, the router and several projects](#ports-the-router-and-several-projects)
- [CI and DDEV](#ci-and-ddev)
- [Asking for help](#asking-for-help)

## First moves

1. **Versions:** `ddev version`. Upgrade DDEV and the Docker provider before debugging an
   old release.
2. **Quick assessment:** `ddev utility diagnose` checks Docker, networking, DNS, HTTPS and
   the current project (`DDEV_DIAGNOSE_FULL=true` adds a test project).
3. **Clean restart:** `ddev poweroff && ddev start`.
4. **Logs:** `ddev logs` (web), `ddev logs -s db`, `ddev logs -f` to follow.
5. **Back out customisations:** `ddev utility check-custom-config` lists every non-default
   file (PHP/nginx/MySQL overrides, compose files, commands, env files). Move them aside
   and retry.
6. **Isolate the project:** a trivial project in a new folder
   (`ddev config --auto`, an `index.php` with `phpinfo()`, `ddev start`). If that works,
   the problem is this project's config - run `scripts/audit-ddev-config.py`.

## Symptom table

| Symptom | First command | Usual cause and fix |
|---|---|---|
| "Port 443 is not available, using 33001 instead" | `ddev utility port-diagnose` | Another process holds 80/443 (Apache, nginx, another Docker environment). Stop it, or set router ports globally (below) |
| `Ports are not available ... bind` errors | `ddev utility port-diagnose --allow-sudo` | Leftover containers or root-owned `docker-proxy`; `ddev poweroff`, restart Docker |
| "web service unhealthy", "container failed to become ready" | `ddev logs` | A broken custom config, a failing `post-start`, or no disk space |
| "No such container: ddev-router" | `ddev poweroff` | Stale router state; start again |
| "No space left on device" | `docker system df` | `ddev delete images`, prune Docker, enlarge the provider's disk; on WSL2 check both disks |
| Browser cannot reach the project URL | `ddev utility diagnose` | DNS rebinding blocked by the router, a VPN or proxy, or offline name resolution (`ddev hostname`) |
| Certificate warning | `ddev utility tls-diagnose` | `mkcert -install` not run; on WSL2, `$CAROOT` not pointing at the Windows mkcert directory |
| `ddev start` refuses after editing `database:` | `ddev utility check-db-match` | Data made by another server: [database.md](database.md#changing-the-database-engine) |
| Database errors on a big import | `ddev logs -s db` | Collation from a newer server, or the wrong engine pinned |
| Custom command missing from `ddev -h` | `ddev start` output | CRLF endings (skipped with a warning), no `## Usage:` line, `ProjectTypes` mismatch |
| A built-in command behaves oddly or is outdated | `ls .ddev/commands/*/` | A project copy shadows it ([extending.md](extending.md#custom-commands)) |
| Files differ between host and container | `ddev mutagen status` | Mutagen lag or a conflict: `ddev mutagen sync`, then `ddev mutagen reset` ([performance.md](performance.md#mutagen)) |
| Very slow first start | `ddev mutagen st -l` | Mutagen syncing huge files: fix `upload_dirs` |
| Xdebug never stops at breakpoints | `ddev utility xdebug-diagnose` | Firewall or endpoint security on 9003, path mapping, `xdebug_ide_location` set |
| Image build fails after a DDEV upgrade | `ddev utility rebuild` | `webimage_extra_packages` names gone from Debian Trixie; fix them |
| `post-start` hook fails writing `/usr/local/bin` | `ddev logs` | Since v1.25.3 that path is not writable; use `~/.local/bin` |
| Setting seems ignored | `ddev utility configyaml --full-yaml` (merged result) | Misspelled or retired key (DDEV ignores unknown keys), or a `config.local.yaml` override |

## Ports, the router and several projects

- **Every running project shares one router** (Traefik) on ports 80 and 443, routed by
  hostname. Several DDEV projects never conflict with each other; conflicts come from
  non-DDEV processes on those ports.
- **Change router ports globally, not per project:**
  `ddev config global --router-http-port=8080 --router-https-port=8443`, then remove any
  `router_http_port`/`router_https_port` from the project's `config.yaml`. Project values
  win over global ones, so a committed `"80"`/`"443"` stops a teammate fixing a clash.
- **Mailpit, XHGui and exposed dev-server ports** are also router ports; port-diagnose
  checks them inside a project directory.
- **The router outlives the last project** since v1.25.0: `ddev poweroff` frees 80/443.
- **`ddev list`** shows every project and its state; `ddev poweroff` stops them all
  (`ddev stop --all` also removes them from DDEV's global project list).
- Project Traefik customisation lives in one file, `.ddev/traefik/config/<project>.yaml`;
  global Traefik config in `~/.ddev/traefik/custom-global-config/`.
- Docker providers that cannot bind privileged ports (Podman rootless, some macOS
  setups) need the global router ports above.

## CI and DDEV

DDEV can run in CI (DDEV maintains a GitHub Action that installs it), but a 2026-10-05
read of 36 DDEV-based agency repositories found none whose workflows do: CI ran
`composer install` and the deploy directly on the runner. The consequence that matters:

- **Three PHP versions must agree**: `php_version` in `.ddev/config.yaml`, the CI
  runner's PHP, and production's. Read the CI version from `.ddev/config.yaml` rather
  than hard-coding it in the workflow, so the two cannot drift.
- `composer.json` `config.platform.php` should match all three.

## Asking for help

- `ddev utility test` prints a full environment report for an issue or a support thread.
- `ddev utility mutagen-diagnose`, `xdebug-diagnose`, `tls-diagnose` and `port-diagnose`
  give targeted reports.
- DDEV's issue queue and Discord are the support channels; search the issue queue first.
