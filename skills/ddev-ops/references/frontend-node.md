# Node.js and Front-End Tooling in DDEV

Facts from DDEV's config and Vite docs at DDEV v1.25.4, checked 2026-10-05. Craft's
craft-vite wiring (the port that must agree in four places, CORS, allowed hosts, Twig
tags) is owned by frontend-upgrade-ops; this file covers the DDEV side only.

## Contents

- [Pick the Node.js version](#pick-the-nodejs-version)
- [Package managers](#package-managers)
- [Running a dev server](#running-a-dev-server)
- [Legacy build chains](#legacy-build-chains)

## Pick the Node.js version

`nodejs_version` sets the Node.js in the web container (managed by `n`). DDEV's default
is Node.js 24.

| Value | Result |
|---|---|
| `"24"` | DDEV's preinstalled default, no download |
| `""` | Whatever the image ships, no download - fastest where startup time matters |
| `"22"`, `"20.2"`, `"18.19.2"` | That version at image build; a bare major takes its newest release |
| `"v24"` | Newest 24.x at build (the `v` prefix only for the current default major) |
| `auto` / `engine` | Read from `.nvmrc`/`.node-version` / `package.json` `engines.node`; v1.25.4 requires the file to exist, and `nodejs_root` points at a subfolder that holds it |

- **The version is fixed when the image builds.** After changing it: `ddev restart`
  (DDEV rebuilds), or `ddev utility rebuild` to force it. Several versions side by side:
  `n install <version>` inside the container (v1.25.3).
- **Codenames still appear in old repositories** (`erbium`, `gallium`). They map to
  majors: argon 4, boron 6, carbon 8, dubnium 10, erbium 12, fermium 14, gallium 16,
  hydrogen 18, iron 20, jod 22, krypton 24.
- **Node.js older than 22 is end of life** upstream as of 2026-10-05 (endoflife.date).
  Such a pin usually protects an old build chain; treat it as upgrade debt, not a
  setting to copy into new projects. `scripts/audit-ddev-config.py` reports it
  (`node-eol`).

## Package managers

- `ddev npm`, `ddev npx` and `ddev yarn` run in the container with its Node.
- pnpm and modern yarn: `corepack_enable: true`, then
  `ddev exec corepack use pnpm@latest` (`pnpm@latest` needs Node 22+; DDEV's docs use
  `pnpm@latest-10` on Node 18/20). Add a `pnpm` web command with `## ExecRaw: true` for
  `ddev pnpm`.
- **The older pnpm setup** - a custom `.ddev/commands/web/pnpm` that installs pnpm itself,
  plus `PNPM_HOME` in `web_environment` (seen in several agency repos) - predates
  corepack. Replace it with `corepack_enable: true`, which pins the version through
  `package.json` `packageManager`.
- **Install and build in the container**, not on the host: the container's Node matches
  teammates' and the lockfile's expectations, and native modules compile for Linux. A
  `node_modules` built on macOS or Windows can fail inside the container.
- With Mutagen on, add `node_modules` to `upload_dirs` so thousands of files are not
  synced. Entries are docroot-relative: with `docroot: web` a root-level folder is
  `../node_modules` ([performance.md](performance.md#upload_dirs)).
- Which install command, one lockfile, `.nvmrc` and `engines` that agree with
  `nodejs_version`, and pinned `npx`: `package-manager-ops`, whose `pm-audit.py` checks a
  repo's Node and PHP pins against `.ddev/config.yaml`.

## Running a dev server

A dev server inside the web container is reachable only through a port DDEV's router
exposes. All four fields are required, and `ddev restart` applies them:

```yaml
web_extra_exposed_ports:
  - name: vite
    container_port: 5173   # what the dev server listens on in the container
    http_port: 5172        # router port for http
    https_port: 5173       # router port for https (HMR over https needs this)
```

- The dev server must listen on all interfaces (`--host`, or `server.host: '0.0.0.0'`).
- Its public URL is the project URL from `ddev describe` plus the port; inside the
  container, `$DDEV_PRIMARY_URL_WITHOUT_PORT` plus `:5173` builds it (DDEV's documented
  form for a bundler's `origin`).
- **Start it with the project** instead of a spare terminal:

  ```yaml
  web_extra_daemons:
    - name: vite
      command: bash -c 'npm install && npm run dev -- --host'
      directory: /var/www/html
  ```

  Its output goes to `ddev logs`.
- A 502 Bad Gateway on the port: check `web_extra_exposed_ports`, check the server is
  running (`ddev logs -s web`), and `ddev restart` after config changes. A CORS error or a
  "host is not allowed" response comes from the bundler's own allow-list, fixed in the
  bundler's config, not in DDEV.
- Framework wiring - Laravel, Craft, WordPress, TYPO3 - is in DDEV's Vite page. For Craft
  and craft-vite: frontend-upgrade-ops' `craft-vite-twig.md`.

## Legacy build chains

- Laravel Mix and webpack 4 projects often pin Node 12-16 and break on anything newer.
  Keep the pin in `config.yaml` so builds stay reproducible, and plan the move to Vite
  with frontend-upgrade-ops.
- Without a Vite-style dev server, `ddev/ddev-browsersync` provides live reload.
- A build that only works on one developer's host Node is a reproducibility bug: move it
  into `ddev npm run build`.
