# Troubleshooting Runbook

Facts from DDEV's troubleshooting, command and Docker-installation docs at DDEV v1.25.4,
and its source, checked 2026-10-06. "Observed" marks behaviour seen in throwaway projects
on DDEV v1.25.4 (Docker Desktop, WSL2) that day. `ddev debug` still works as an alias of
`ddev utility`.

## Contents

- [First moves](#first-moves)
- [Symptom table](#symptom-table)
- [Ports, the router and several projects](#ports-the-router-and-several-projects)
- [Disk space](#disk-space)
- [Asking for help](#asking-for-help)

## First moves

1. **Versions:** `ddev version`. Upgrade DDEV and the Docker provider before debugging an
   old release.
2. **Quick assessment:** `ddev utility diagnose` checks Docker, networking, DNS, HTTPS and
   the current project (`DDEV_DIAGNOSE_FULL=true` adds a test project).
3. **Clean restart:** `ddev poweroff && ddev start`. Note that `poweroff` stops every
   project on the machine.
4. **Logs:** `ddev logs` (web), `ddev logs -s db`, `ddev logs -f` to follow.
5. **Back out customisations:** `ddev utility check-custom-config` lists every non-default
   file (PHP/nginx/MySQL overrides, compose files, commands, env files). Move them aside
   and retry.
6. **Isolate the project:** in a new folder, run `ddev config --auto`, add an `index.php`
   containing `phpinfo()`, and `ddev start`. If that works, the problem is this project's
   config: run `scripts/audit-ddev-config.py`.

## Symptom table

| Symptom | First command | Usual cause and fix |
|---|---|---|
| "Cannot connect to the Docker daemon" | `docker context ls` | The provider isn't running, or the active context points at another engine. Start it or `docker context use <name>` |
| "Port 443 is not available, using 33001 instead" | `ddev utility port-diagnose` | Another process holds 80/443 (Apache, nginx, IIS, another Docker environment). Stop it, then `ddev poweroff && ddev start`: DDEV keeps the substitute port until the router is recreated. Or set router ports globally (below) |
| `Ports are not available ... bind` errors | `ddev utility port-diagnose --allow-sudo` | Leftover containers or root-owned `docker-proxy`; `ddev poweroff`, restart Docker |
| `failed to start ddev-router ... ports are not available: exposing port TCP 127.0.0.1:8143` (or another router port) | `ddev utility port-diagnose` | A program DDEV's busy-port check can't see holds a router port, typically a Windows process under WSL2. XHGui's ports are published even with XHGui off. Free the port or move it globally (below) |
| `403 authentication required` or `unauthorized` pulling images | `docker logout` | Stale Docker Hub credentials; log out and retry |
| A build complains about buildx | `docker buildx version` | DDEV requires the buildx plugin (v1.25.1+): `brew install docker-buildx` / `apt-get install docker-buildx-plugin` |
| `apt-get update` fails during an image build | `ddev utility rebuild` | WSL2 clock drift, or a packet-inspection VPN breaking TLS; on a VPN add its CA via `.ddev/web-build` |
| "web service unhealthy", "container failed to become ready" | `ddev logs` | Most often a user-defined `nginx-site.conf` or `apache-site.conf` (keep `/phpstatus`; test with `ddev exec nginx -t`), else a failing `post-start` or no disk space |
| 404 "No input file specified" (nginx) or 403 Forbidden (Apache) | `ddev describe` | `docroot` in `config.yaml` doesn't contain `index.php` |
| "No such container: ddev-router" | `ddev poweroff` | DDEV's fix: `ddev poweroff`, then `docker rm -f $(docker ps -aq)` and `docker rmi -f $(docker images -q)`. That removes **every** container and image on the machine, not just DDEV's; database volumes survive. Ask first |
| Browser cannot reach the project URL | `ddev utility diagnose` | DNS rebinding blocked by the router, a VPN or proxy, or offline name resolution (`ddev hostname`) |
| Certificate warning | `ddev utility tls-diagnose` | `mkcert -install` not run; on WSL2, `$CAROOT` not pointing at the Windows mkcert directory |
| `ddev start` refuses after editing `database:` | `ddev utility check-db-match` | Data made by another server: [database.md](database.md#changing-the-database-engine) |
| Unknown collation on import | `ddev logs -s db` | Import with `ddev import-db`, which translates newer collations ([database.md](database.md#import-troubleshooting)) |
| Second checkout won't start: project root already set | `ddev list` | Same `name:` as another checkout: [automation-and-worktrees.md](automation-and-worktrees.md#several-checkouts-of-one-repository) |
| Custom command missing from `ddev -h` | `ddev start` output | CRLF endings (skipped with a warning), no `## Usage:` line, `ProjectTypes` mismatch |
| A built-in command behaves oddly or is outdated | `ls .ddev/commands/*/` | A project copy shadows it ([extending.md](extending.md#custom-commands)) |
| Files differ between host and container | `ddev mutagen status` | Mutagen lag or a conflict: `ddev mutagen sync`, then `ddev mutagen reset` ([performance.md](performance.md#mutagen)) |
| Very slow first start | `ddev mutagen st -l` | Mutagen syncing huge files: fix `upload_dirs` |
| Xdebug never stops at breakpoints | `ddev utility xdebug-diagnose` | Firewall or endpoint security on 9003, path mapping, `xdebug_ide_location` set, or on WSL2 the VS Code extensions not enabled in the distro |
| git inside the container: "detected dubious ownership" | `ddev exec git status` | Mark the repo safe for the container user: `.ddev/homeadditions/.gitconfig` with `[safe]` `directory = /var/www/html` (a pattern several agency repos use) |
| Image build fails after a DDEV upgrade | `ddev utility rebuild` | `webimage_extra_packages` names gone from Debian Trixie; fix them |
| `post-start` hook fails writing `/usr/local/bin` | `ddev logs` | Since v1.25.3 that path is not writable; use `~/.local/bin` |
| Setting seems ignored | `ddev utility configyaml --full-yaml` (merged result) | Misspelled or retired key (DDEV ignores unknown keys), a `config.local.yaml` override, or a list an override file appended to |

## Ports, the router and several projects

- **Every running project shares one router** (Traefik) on ports 80 and 443, routed by
  hostname. Several DDEV projects never conflict with each other; conflicts come from
  non-DDEV processes on those ports, or from two checkouts claiming one project name.
- **Change router ports globally, not per project:**
  `ddev config global --router-http-port=8080 --router-https-port=8443`, then remove any
  `router_http_port`/`router_https_port` from the project's `config.yaml`. Project values
  win over global ones, so a committed `"80"`/`"443"` stops a teammate fixing a clash.
- **The router publishes far more than 80/443.** By default: HTTP and HTTPS (80/443),
  Mailpit (8025/8026), XHGui (8143/8142, even when XHGui is off) and the Traefik monitor
  (10999, on 127.0.0.1). It also publishes every port a running project's add-ons or
  `web_extra_exposed_ports` expose through it (`determineRouterPorts`).
  - DDEV swaps a busy router port for a free one ("Port 443 is not available, using
    33001 instead"), finding it by connecting from where DDEV runs
    (`netutil.IsPortActive`). It neither checks nor swaps the Traefik monitor port.
  - On WSL2 that check can miss a Windows program. Observed with Docker Desktop and DDEV
    v1.25.4: a Windows process listening on 8143 made `ddev start` fail with
    `/forwards/expose returned unexpected status: 500` (`port-diagnose` checks both
    sides, so run it then).
  - To move one: `ddev config global --mailpit-http-port=<p> --mailpit-https-port=<p>`
    or `--traefik-monitor-port=<p>`. XHGui's ports have no flag in v1.25.4: set
    `xhgui_http_port` and `xhgui_https_port` in `~/.ddev/global_config.yaml`. A
    per-project value moves only that project's port; every other project still claims
    the default.
- **`port-diagnose` covers the router's HTTP and HTTPS ports plus Mailpit and XHGui** (run
  it inside the project). It does not check `web_extra_exposed_ports`. On WSL2 it checks
  both the Linux and the Windows side.
- **The router outlives the last project** since v1.25.0: `ddev poweroff` frees 80/443.
- **`ddev list`** shows every project and its state; `ddev poweroff` stops them all. To
  drop a project from DDEV's list without deleting anything: `ddev stop --unlist`.
- **Traefik customisation:** add extra `*.yaml` files beside the generated
  `.ddev/traefik/config/<project>.yaml`; DDEV merges them. Global Traefik config goes in
  `~/.ddev/traefik/custom-global-config/`.
- **Podman rootless on macOS** cannot bind 80/443 and needs the global router ports above.
- **CI** doesn't run DDEV in the repositories surveyed; keeping CI on DDEV's PHP is in
  [config-and-env.md](config-and-env.md#ci-and-production-parity).

## Disk space

Safe, data-preserving recovery, in this order:

1. See what's big: `docker system df` and `ddev utility mutagen-diagnose --all`.
2. `ddev delete images` removes previous DDEV image versions.
3. `docker builder prune` removes the build cache.
4. `ddev mutagen reset` in a project with a bloated sync volume.
5. On macOS, enlarge the provider's disk image (keep usage under ~80%); on WSL2, check
   both the Windows drive and the WSL2 disk.

Anything that removes databases needs the user's OK first: `ddev delete`, `ddev clean`,
`ddev stop --remove-data` and `docker volume prune -a`. See the table in
[automation-and-worktrees.md](automation-and-worktrees.md#commands-that-destroy-data).

## Asking for help

- `ddev utility test` prints a full environment report for an issue or a support thread.
- `ddev utility mutagen-diagnose`, `xdebug-diagnose`, `tls-diagnose` and `port-diagnose`
  give targeted reports.
- DDEV's issue queue and Discord are the support channels; search the issue queue first.
