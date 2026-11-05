# Caches, CI and Offline Installs

Where each manager keeps downloads, what CI should cache (the download cache, keyed on the
lockfile, never `node_modules`), and how to install without the network. Facts verified
2026-10-05 against docs.npmjs.com (`npm cache`, config), yarnpkg.com, pnpm.io, the
actions/setup-node v7 README, and getcomposer.org (config, checked against 2.10.3); the
pnpm linking, Yarn global folder, cache-difference and offline notes 2026-10-06 against
pnpm.io settings, the yarnpkg/berry source (`folderUtils.ts`), yarnpkg.com caching and
npm's config docs.

## Contents

- [Cache locations](#cache-locations)
- [What CI caches](#what-ci-caches)
- [A GitHub Actions job for a Node + Composer site](#a-github-actions-job-for-a-node--composer-site)
- [Offline and air-gapped installs](#offline-and-air-gapped-installs)
- [Cache hygiene](#cache-hygiene)

## Cache locations

| Manager | Default location | Ask the tool |
|---|---|---|
| npm | `~/.npm` (POSIX), `%LocalAppData%\npm-cache` (Windows) | `npm config get cache` |
| Yarn 1 | per-OS user cache | `yarn cache dir` |
| Yarn 4 | global cache under the Yarn global folder (`enableGlobalCache` is true by default since 4.0); `.yarn/cache` in the project when disabled | `yarn config get cacheFolder` |
| pnpm | a content-addressed store, linked into each project (hard link, or copy-on-write clone where the filesystem supports it) | `pnpm store path` |
| Composer | `%LocalAppData%\Composer` (Windows), `~/Library/Caches/composer` (macOS), `$XDG_CACHE_HOME/composer` or `$COMPOSER_HOME/cache` (Linux) | `composer config cache-dir` |

The Yarn 4 global folder is `%LOCALAPPDATA%\Yarn\Berry` on Windows,
`$XDG_DATA_HOME/yarn/berry` elsewhere when `XDG_DATA_HOME` is set, and `~/.yarn/berry`
otherwise. pnpm's `packageImportMethod` defaults to `auto`: it tries the cheap link
methods the filesystem offers and copies when none works.

`COMPOSER_CACHE_DIR` overrides Composer's location. (Composer's own CLI page lumps macOS in
with `$COMPOSER_HOME/cache`; the config page and the source say `~/Library/Caches/composer`.)

## What CI caches

- **Cache the download cache, keyed on the lockfile hash.** `npm ci` deletes
  `node_modules` before installing, so caching `node_modules` buys nothing and risks
  restoring a tree built for another Node or OS.
- **actions/setup-node** (v7 is current) caches for you: `cache: npm`, `yarn` or `pnpm`.
  The key comes from the lockfile; `cache-dependency-path` points it at a lockfile in a
  subdirectory. Since v6 it turns npm caching on automatically when `packageManager` or
  `devEngines.packageManager` names npm; Yarn and pnpm need an explicit `cache:`;
  `package-manager-cache: false` opts out.
- **Composer** has no built-in action cache: use actions/cache on
  `composer config cache-files-dir`, keyed on `hashFiles('composer.lock')`.
- A restored cache must never change what installs. If a build differs with and without
  the cache, first check that the job's install is frozen. The other usual cause is a
  cached install-script result: pnpm's `sideEffectsCache` (on by default) reuses what a
  package's postinstall built last time.

## A GitHub Actions job for a Node + Composer site

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with:
          node-version-file: .nvmrc
          cache: npm
      - run: npm ci
      - run: npm run build
      - uses: shivammathur/setup-php@v2
        with:
          php-version: "8.3"          # the same major.minor as config.platform.php and DDEV
      - id: composer-cache
        run: echo "dir=$(composer config cache-files-dir)" >> "$GITHUB_OUTPUT"
      - uses: actions/cache@v6
        with:
          path: ${{ steps.composer-cache.outputs.dir }}
          key: composer-${{ runner.os }}-${{ hashFiles('composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - run: composer install --no-interaction --no-dev --optimize-autoloader
      - run: composer check-platform-reqs --lock --no-dev
```

Pin actions to a major as shown, or to a full commit SHA if the repo's policy demands it;
reviewing action pins is `ci-cd-ops` territory.

## Offline and air-gapped installs

| Manager | Offline install | Notes |
|---|---|---|
| npm | `npm ci --offline` (fails on a cache miss) | the cache must hold every tarball in the lock; `--prefer-offline` only skips revalidation and still fetches misses, so it is not offline |
| Yarn 4 | commit `.yarn/cache` with `enableGlobalCache: false` (the offline mirror) | the repo then carries every zip; a deliberate trade. Zero-installs also needs PnP and the committed `.pnp.cjs` loader |
| pnpm | `pnpm install --offline` | uses the store only |
| Composer | `composer install` reads the cache first | no strict offline flag; point `repositories` at a local `artifact` or `path` repository for a true air gap |

For a build machine without internet, the clean pattern is a private registry or mirror
inside the network ([registries-and-auth.md](registries-and-auth.md#mirrors-and-proxies)),
not hand-copied caches.

## Cache hygiene

| Problem | Command |
|---|---|
| Suspected corrupt npm cache | `npm cache verify` (checks and garbage-collects); `npm cache clean --force` only as a last resort |
| Yarn 1 cache bloat | `yarn cache clean` |
| pnpm store bloat | `pnpm store prune` (removes packages no project references) |
| Composer cache bloat or stale metadata | `composer clear-cache` (`--gc` for just garbage collection) |

Clearing a cache never fixes a lockfile problem. If an install fails the same way with an
empty cache, the cause is the lockfile, the registry, the network or the environment: the
runtime version, a missing PHP extension, or a native build toolchain.
