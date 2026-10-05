# Caches, CI and Offline Installs

Where each manager keeps downloads, what CI should cache (the download cache, keyed on the
lockfile, never `node_modules`), and how to install without the network. Facts verified
2026-10-05 against docs.npmjs.com (`npm cache`, config), yarnpkg.com, pnpm.io, the
actions/setup-node v7 README, and getcomposer.org (config, checked against 2.10.3).

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
| Yarn 4 | global cache under `~/.yarn/berry` (`enableGlobalCache` is true by default since 4.0); `.yarn/cache` in the project when disabled | `yarn config get cacheFolder` |
| pnpm | a content-addressed store, hard-linked into each project | `pnpm store path` |
| Composer | `%LocalAppData%\Composer` (Windows), `~/Library/Caches/composer` (macOS), `$XDG_CACHE_HOME/composer` or `$COMPOSER_HOME/cache` (Linux) | `composer config cache-dir` |

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
  the cache, the lockfile is not frozen in that job.

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
| npm | `npm ci --offline` (fail on a cache miss) or `--prefer-offline` | the cache must hold every tarball in the lock |
| Yarn 4 | commit `.yarn/cache` with `enableGlobalCache: false` ("zero-installs") | the repo then carries every zip; a deliberate trade |
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
empty cache, the cause is the lockfile, the registry or the network.
