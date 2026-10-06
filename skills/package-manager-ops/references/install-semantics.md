# Install Semantics: Dev, CI and Deploy

Which install command belongs where, what each one promises, and why a lockfile changes
under you. Facts verified 2026-10-05 against docs.npmjs.com (v11 and v12), yarnpkg.com,
classic.yarnpkg.com, pnpm.io, bun.com and getcomposer.org (checked against the Composer
2.10.3 tag, because getcomposer.org/doc is built from `main` and documents unreleased
features).

## Contents

- [The one table](#the-one-table)
- [npm ci versus npm install](#npm-ci-versus-npm-install)
- [Yarn, pnpm and Bun frozen installs](#yarn-pnpm-and-bun-frozen-installs)
- [composer install versus composer update](#composer-install-versus-composer-update)
- [Why a lockfile changes under you](#why-a-lockfile-changes-under-you)
- [Deploy patterns](#deploy-patterns)

## The one table

| Manager | Dev: may change the lock | CI and deploy: the lock is law | Production deps only |
|---|---|---|---|
| npm | `npm install` | `npm ci` | `npm ci --omit=dev` |
| Yarn 1 | `yarn install` | `yarn install --frozen-lockfile` | `yarn install --frozen-lockfile --production` |
| Yarn 4 | `yarn install` | `yarn install --immutable` (default on CI) | `yarn workspaces focus --all --production` |
| pnpm | `pnpm install` | `pnpm install --frozen-lockfile` (default on CI), or `pnpm ci` (pnpm 11+) | `pnpm install --prod --frozen-lockfile` |
| Bun | `bun install` | `bun ci` or `bun install --frozen-lockfile` | `bun install --production` (implies frozen) |
| Composer | `composer update <pkg>` to change; `composer install` to sync | `composer install --no-interaction` | `composer install --no-dev --optimize-autoloader --no-interaction` |

A frozen install that fails is the system working: the lockfile and the manifest
disagree, and someone must decide which is right on a dev machine, not on a server.

## npm ci versus npm install

`npm ci`:

- needs `package-lock.json` (npm 11 also accepts `npm-shrinkwrap.json`; npm 12 does not
  read shrinkwrap files at all);
- exits with an error, instead of updating the lock, when lock and `package.json`
  disagree;
- deletes an existing `node_modules/` first, so every run starts clean;
- never writes `package.json` or the lockfile.

`npm install` resolves `package.json` ranges against the lock and rewrites the lock when
it must. That is right on a dev machine after editing dependencies and wrong everywhere
else. `npm install --package-lock-only` refreshes the lock without touching
`node_modules`.

`npm install --frozen-lockfile` is not a frozen install. The flag is Yarn's, and npm has
no such option. npm up to 11.1 drops it silently, 11.2 and later warn about an "Unknown
cli config" and install unfrozen anyway, and npm 12 refuses the command, because unknown
CLI flags became errors (npm/cli#9276; #9729 relaxed that only for `.npmrc` keys). The
frozen npm install is `npm ci`.

Production-only: `--omit=dev` (the old `--production` flag is a deprecated alias for it).
`omit` defaults to `dev` when `NODE_ENV=production`, which surprises builds: a build step
that needs Vite or Sass (devDependencies) fails if the CI sets `NODE_ENV=production`
before installing. Set it after the install, or for the build command only.

## Yarn, pnpm and Bun frozen installs

- **Yarn 1**: `--frozen-lockfile` refuses to write `yarn.lock`.
- **Yarn 4**: `--immutable` refuses to change the lockfile and is the default when Yarn
  detects CI (`enableImmutableInstalls`). `--frozen-lockfile` survives only as a
  deprecated alias. `yarn install --mode=update-lockfile` refreshes the lock without
  linking, which is what dependency bots use.
- **pnpm**: `--frozen-lockfile` is the default in CI when a lockfile exists. pnpm 12
  removed the `--frozen-lockfile false` spelling; use `--no-frozen-lockfile`. pnpm 11
  added `pnpm ci` (clean, then a frozen install).
- **Bun**: `--frozen-lockfile` errors when `package.json` disagrees with `bun.lock`.
  Unlike Yarn and pnpm, Bun does not switch it on in CI; pass it or use `bun ci`.

## composer install versus composer update

- `composer install` with a `composer.lock` installs exactly the locked versions. With
  no lock it resolves and writes one, which is why a missing lock is a finding.
- `composer update` resolves `composer.json` constraints, rewrites `composer.lock`,
  then installs. Scope it: `composer update vendor/package` (add `-W`,
  `--with-all-dependencies`, when its dependencies must move too).
- When `composer.json` changed after the lock was written, install warns: "The lock file
  is not up to date with the latest changes in composer.json". Fix it on a dev machine
  with `composer update <the package you changed>`. `composer update --lock` only
  refreshes the hash and package metadata (mirrors, URLs); use it for edits that cannot
  change resolution, such as a description.
- `composer update --no-install` (since 2.0) resolves and writes the lock without
  installing: useful for a lockfile-only refresh.
- Composer 2.9.0 started blocking packages with security advisories during `update` by
  default; 2.10 moved that switch into a new `policy` config block. When an update
  refuses a version for that reason, the decision belongs to `security-ops` and
  `supply-chain-defense`, not to a flag that skips the block.

Autoloader levels for production (`composer install` or `composer dump-autoload`):

| Flag | Level | Use when |
|---|---|---|
| `-o`, `--optimize-autoloader` | classmap | always in production |
| `-a`, `--classmap-authoritative` | classmap only, implies `-o` | no class is generated or added at run time |
| `--apcu-autoloader` | APCu cache of lookups | APCu is installed and `-a` is not safe |

## Why a lockfile changes under you

| Symptom | Cause | Fix |
|---|---|---|
| Whole-file lock diff after a plain install | a different manager major wrote it (npm 6 vs 11, Yarn 1 vs 4) | pin the manager (`packageManager`, `devEngines`) and the Node major |
| Platform packages appear or vanish (`@rollup/rollup-linux-x64-gnu`, `@esbuild/*`) | npm before 11.3.0 dropped other platforms' optional dependencies (npm/cli#4828, fixed in 11.3.0) | regenerate the lock once with npm 11.3+ |
| `resolved` URLs change host | someone installed through a different registry or mirror | one registry per repo, set in the project `.npmrc` |
| Lock changes on `npm install` with no edits | `package.json` was edited by hand without installing, or a merge took one side | install on a dev machine, review, commit |
| "lock file is not up to date" (Composer) | `composer.json` edited without `composer update` | `composer update <pkg>` |
| `composer.lock` resolves for the wrong PHP | `composer update` ran on a PHP other than production | set `config.platform.php` (references/version-pinning.md) |

Line endings are the other classic: see
[platform-gotchas.md](platform-gotchas.md#windows).

## Deploy patterns

1. **Build once in CI, ship artefacts.** `npm ci && npm run build` and
   `composer install --no-dev -o` in the build step; deploy the built assets and
   `vendor/`. The server never resolves anything.
2. **Install on the server** (common with AWS CodeDeploy, where an `appspec.yml` hook
   runs a script on the instance): the hook may only run frozen commands, `npm ci` and
   `composer install --no-dev --no-interaction --optimize-autoloader`, never
   `npm install` or `composer update`. Pin Node and PHP on the instance to match the
   repo pins.
3. **Check the real platform before switching traffic.** `config.platform.php` makes
   resolution pretend; the server must really have it.
   `composer check-platform-reqs --lock --no-dev` checks the server's actual PHP and
   extensions against the lock. Composer also generates
   `vendor/composer/platform_check.php` (`platform-check` defaults to `php-only`), which
   stops the app at boot when the PHP is too old.

Never deploy a lockfile that CI did not install. A deploy that runs its own `install`
step has a different tree from the one your tests ran against.
