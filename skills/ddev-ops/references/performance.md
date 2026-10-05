# Performance: Mutagen, upload_dirs, WSL2 and Docker Providers

Facts from DDEV's performance, Docker-installation, troubleshooting and FAQ docs at DDEV
v1.25.4, release notes v1.25.0-v1.25.4, and its source (`upload_dirs.go`,
`pkg/settings/viper.go`), checked 2026-10-06.

## Contents

- [Why is this project slow?](#why-is-this-project-slow)
- [Mutagen](#mutagen)
- [upload_dirs](#upload_dirs)
- [Windows and WSL2](#windows-and-wsl2)
- [Docker providers](#docker-providers)

## Why is this project slow?

On Linux, including WSL2, Docker bind mounts are fast and Mutagen adds little. On macOS
and traditional Windows, bind mounts are the bottleneck and Mutagen is the fix. Work down
the list:

| Check | Command | Fix |
|---|---|---|
| Xdebug left on | `ddev xdebug status` | `ddev xdebug off` - it slows every request |
| Mutagen state | `ddev mutagen status`, `ddev utility mutagen-diagnose` | Below |
| Huge sync (first start takes minutes) | `ddev mutagen st -l` while starting | Add `node_modules` and big asset folders to `upload_dirs` (docroot-relative: `../node_modules` when `docroot: web`) |
| WSL2 project on the Windows drive | `pwd` starts with `/mnt/c` | Move it into the WSL2 filesystem |
| Docker VM starved | Provider settings | 5-6 GB memory suits most projects; keep the disk image under 80% full |
| Slow `ddev start` | Hooks | Move `npm install`/`composer install` out of `post-start` into explicit steps or a daemon |
| Many stopped projects' containers | `ddev list` | `ddev poweroff`, then start only what you need |

## Mutagen

- **Default:** on for macOS and traditional Windows, off elsewhere. DDEV installs and runs
  its own `mutagen` binary with its own data directory, so nothing needs installing (and a
  separately installed Mutagen doesn't interfere).
- **Per developer, not per project:** don't commit `performance_mode` in `config.yaml`. A
  WSL2 or Linux teammate gains nothing from Mutagen and pays its sync cost. Use
  `config.local.yaml` or `ddev config global --performance-mode=<mode>`.
- **Turn off for one project:** `ddev config --performance-mode=none && ddev restart`
  (writes to `config.yaml`, so move the line into `config.local.yaml`).
  `ddev config --performance-mode-reset` returns to the global setting.
- **It is asynchronous two-way sync:** a host change reaches the container "pretty soon".
  `ddev start` and `ddev stop` force a sync; `ddev mutagen sync` forces one now.
- **Sync after mass changes:** switching branches, `npm install`, a big `composer update`.
  A git `post-checkout` hook running `ddev mutagen sync || true` keeps branch switches
  honest. Do big git operations on the host, not inside the container.
- **Don't change files while DDEV is stopped:** Mutagen cannot see the change and may
  restore the old copy from its volume on the next start. If you did (a branch switch,
  say), run `ddev mutagen reset` *before* `ddev start`, so the host copy wins. Only when
  stale files have already come back: `ddev stop`, restore files with git (this discards
  uncommitted work - check `git status` first), `ddev mutagen reset`, `ddev start`.
- **Custom commands that write files** should carry `## MutagenSync: true`.
- **After changing `upload_dirs` or `.ddev/mutagen/mutagen.yml`:** `ddev mutagen reset`.
- **Diagnose:** `ddev utility mutagen-diagnose` (volume size warnings at 5 GB and 10 GB,
  large files, ignore patterns; `--all` for every project), `ddev mutagen monitor`,
  `ddev mutagen logs`, `DDEV_DEBUG=true ddev start`.
- **To prove Mutagen is the problem:** `performance_mode: none` in `config.local.yaml`,
  `ddev restart`, compare.

## upload_dirs

`upload_dirs` lists the user-generated-file directories. DDEV uses them as the target of
`ddev import-files` and, with Mutagen on, bind-mounts them instead of syncing them.

- **Paths resolve from the docroot**, not the project root (DDEV's
  `calculateHostUploadDirFullPath` joins each entry onto the docroot). With
  `docroot: web`, an entry `storage` means `web/storage`. A directory beside the docroot
  is `../storage`. Entries must stay inside the project.
- **Setting it replaces the project type's defaults**, so list the CMS's own upload
  folder too (Drupal: `sites/default/files`).
- **Exclude heavy, regenerable trees from Mutagen** by listing them: `node_modules`,
  large asset or font folders, framework runtime/cache folders. Write them relative to the
  docroot: with `docroot: web`, a root-level `node_modules` is `../node_modules`.
- **Override files append to the list** (`config.*.yaml` adds entries unless it sets
  `override_config: true`), so check the merged result with
  `ddev utility configyaml --full-yaml`.
- Types with no default (`php`, `craftcms`) print a warning when Mutagen is on and
  `upload_dirs` is empty. Fix the setting rather than reaching for
  `disable_upload_dirs_warning`.
- `scripts/audit-ddev-config.py` flags an entry that resolves to a missing path while
  the same name exists at the project root (`upload-dir-misplaced`).

Craft's layout (asset volumes, `storage/`): craftcms-ops' `ddev.md`.

## Windows and WSL2

- **Keep projects inside the WSL2 filesystem** (`~/projects/<site>` in the distro). DDEV's
  FAQ calls WSL2 access to the Windows NTFS drive "intolerably slow"; `/mnt/c/...` is the
  most common cause of a slow Windows setup. Edit from Windows through the WSL extension
  of your editor or the `\\wsl$` share.
- **Recommended engine:** Docker CE installed inside WSL2 ("most users, best
  performance"). Docker Desktop also works. Mutagen is unnecessary there.
- **Traditional Windows** (no WSL2) relies on Mutagen and needs `bash` from Git for
  Windows on PATH for custom commands.
- **Disk:** check free space on both the Windows drive and the WSL2 virtual disk.
- **Ports:** `ddev utility port-diagnose` checks both the Linux and the Windows side; IIS
  on Windows can hold port 80 for WSL2.
- **HTTPS:** `$CAROOT` in WSL2 must point at the Windows mkcert directory;
  `ddev utility tls-diagnose` checks it.

## Docker providers

| Platform | Provider | Notes (DDEV docs, v1.25.4) |
|---|---|---|
| macOS | OrbStack | Recommended: easiest, most performant; commercial, not open source |
| macOS | Lima, Colima | Free, open source; by default only projects under your home directory work |
| macOS | Docker Desktop | Long supported; may need a licence; enable "Allow privileged port mapping" |
| macOS | Rancher Desktop | Free, open source; slower startup |
| Linux | Docker CE | Best tested |
| Windows | Docker CE inside WSL2 | Recommended |
| Windows | Docker Desktop | Works with WSL2 and traditional Windows |
| Any | Podman rootless, Docker rootless | Stable since v1.25.3 (experimental in v1.25.0-v1.25.2). On macOS Podman cannot bind 80/443, so set router ports globally; DDEV's Linux setup lowers the unprivileged-port limit instead |

- `ddev utility dockercheck` confirms DDEV can talk to the provider.
- Colima switches the Docker context; `docker context ls` shows which engine DDEV uses.
- Databases live in the provider's Docker volumes, so a new provider starts empty:
  snapshot or export first (OrbStack can migrate images and volumes from Docker Desktop).
