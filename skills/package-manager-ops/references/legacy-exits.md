# Legacy Exits: Bower, node-sass, Yarn 1, Old Lockfiles and End-of-Life PHP

Each of these still installs today, which is why it survives. Each also stops a repo from
moving: Bower and node-sass pin the build to a dead toolchain, Yarn 1 is in maintenance
mode, and an end-of-life PHP gets no security fixes at all. Facts verified 2026-10-06
against bower.io, the node-sass README, sass-lang.com, classic.yarnpkg.com and the Yarn
repository, docs.npmjs.com, php.net, Packagist and the Composer docs and source (2.10.3).

## Contents

- [Bower to npm](#bower-to-npm)
- [node-sass to Dart Sass](#node-sass-to-dart-sass)
- [Yarn 1 to npm or Yarn 4](#yarn-1-to-npm-or-yarn-4)
- [npm lockfileVersion 1](#npm-lockfileversion-1)
- [Composer 1 to Composer 2](#composer-1-to-composer-2)
- [End-of-life Node](#end-of-life-node)
- [End-of-life PHP](#end-of-life-php)

## Bower to npm

Bower's own site now says that while it is maintained, it recommends Yarn and Vite for
front-end projects; its last release is 1.8.14 (2022-03-14). Nearly every Bower package
is on npm under the same name.

1. List what Bower installs: the `dependencies` in `bower.json`, with versions.
2. Add each to npm at the version Bower resolved, not "latest":
   `npm install --save-exact jquery@3.7.1`. A Bower range like `~3.7.1` maps to the
   same npm range if you prefer ranges.
3. Repoint every reference to `bower_components/` (Twig asset tags, Sass `@import` paths,
   copy tasks in the bundler config) to the npm package, imported through the bundler.
4. Delete `bower.json`, `.bowerrc` and `bower_components/`; remove `bower install` from
   README, CI and deploy hooks.
5. Build, compare the output assets, commit as one change.

Bundler configuration (copy tasks, aliases) belongs to `frontend-upgrade-ops`.

## node-sass to Dart Sass

node-sass is end of life: its README says there will be no more releases, even for
security fixes, and the repository was archived on 2024-07-24. Its last version, 9.0.0
(2023-05-20), wraps LibSass, itself deprecated since 2020-10-26, and its native build
fails on current Node. Its replacement is Dart Sass, published as `sass` (pure JS) or
`sass-embedded` (a faster native compiler, same results).

```bash
npm uninstall node-sass
npm install --save-dev sass
```

- `sass-loader`, Laravel Mix 6 and Vite all detect `sass` or `sass-embedded` without
  configuration changes in most setups.
- Expect deprecation warnings rather than errors. The big one: `@import` and the global
  built-in functions are deprecated as of Dart Sass 1.80.0, and removal is planned for
  Dart Sass 3.0.0, no sooner than two years after 1.80.0. Division with `/` moves to
  `math.div`.
- The official `sass-migrator` rewrites stylesheets to the module system
  (`@use`/`@forward`); run it pinned to an exact version, on a branch, and review the
  diff.
- Silence nothing globally. Fix warnings file by file, or schedule the module migration
  as its own piece of work.

## Yarn 1 to npm or Yarn 4

Yarn 1 entered maintenance mode in January 2020. Its README says the codebase will only
accept security fixes, but also that the repository is kept for "the occasional hotfix",
and the recent releases were hotfixes, not security fixes: the last, 1.22.22
(2024-03-09), fixed a punycode warning and a hoisting bug. Feature work and other bug
fixes go to Yarn 4 (yarnpkg/berry).

**To npm** (the usual choice for a server-rendered site):

1. Delete `node_modules/`, keep `yarn.lock`.
2. `npm install`: with no `package-lock.json`, npm uses `yarn.lock` as resolution guidance,
   so versions stay put.
3. Build and test; compare `npm ls --depth=0` against `yarn list --depth=0`.
4. Delete `yarn.lock`, set `"packageManager": "npm@<version>"`, and replace `yarn`
   commands in scripts, README, CI and deploy hooks (`yarn` -> `npm ci`,
   `yarn build` -> `npm run build`).

**To Yarn 4**: `yarn set version stable`, add `nodeLinker: node-modules` to
`.yarnrc.yml` unless you want Plug'n'Play, run `yarn install` (it migrates the v1 lock),
commit `.yarnrc.yml`, `yarn.lock` and the `packageManager` field. Yarn 4.14.0+ blocks
dependency build scripts by default, so approve the native packages
([scripts-and-workspaces.md](scripts-and-workspaces.md#dependency-install-scripts-are-blocked-by-default)).

## npm lockfileVersion 1

A `package-lock.json` with `"lockfileVersion": 1` was written by npm 5 or 6 (Node 14 or
older), or by a newer npm set to `lockfile-version=1`. Check `.npmrc` first: if it pins
1, a normal install keeps writing version 1, so remove that line. Then run a normal
`npm install` with a current npm once, review the diff (it rewrites the whole file),
build, and commit.
Then make sure CI and deploy also run a current npm; npm 6 cannot read a version 3 lock
at all.

## Composer 1 to Composer 2

getcomposer.org lists Composer 1 (last release 1.10.28) as end of life: its maintenance
ended 2026-05-30. Composer 2 shipped on 2020-10-24, so anything still pinned to 1 is a CI
image or a DDEV setting nobody revisited.

Packagist.org shut down Composer 1 metadata on 2025-09-01; `repo.packagist.org/packages.json`
now carries a warning saying so. Packagist's own notice says `composer install` from an
existing lock still works, because the lock holds each package's download URL. Anything
that resolves (`update`, `require`, a new package) no longer works with Composer 1.

1. Find every pin: `tools: composer:v1` in a setup-php step, `composer self-update --1`,
   `FROM composer:1` / `COPY --from=composer:1` in Dockerfiles, and DDEV's
   `composer_version` (DDEV's setting is `ddev-ops` territory; pm-audit reports the rest
   as `php.composer.v1`).
2. Check plugins: Composer 2 only loads plugins that support `composer-plugin-api` 2,
   and Composer 2.2+ also needs each one listed in `config.allow-plugins`. Old plugins are
   the usual blocker; `composer outdated --direct` shows which have newer releases.
3. Switch every pin to 2 in one commit. Run `composer install` with Composer 2 to prove
   the lock installs; `install` never rewrites an existing lock.
4. Run `composer update --lock --no-install`. It rewrites the lock's hash and metadata
   and records `plugin-api-version` without moving any version. Commit that lock.
   Skipping this step breaks CI later: with a lock below plugin API 2.2.0 and no
   `allow-plugins` config, a non-interactive run that loads a plugin throws and asks for
   `composer update --lock`.

## End-of-life Node

1. Choose an LTS target ([version-pinning.md](version-pinning.md#node-release-lines-today));
   prefer the newest Active LTS.
2. Change every pin in one commit: `.nvmrc`, `engines.node`, `devEngines`, DDEV
   `nodejs_version`, CI `node-version`, the deploy host.
3. Delete `node_modules`, `npm ci` (or a normal install if native modules need rebuilding
   into the lock), build and test.
4. Native modules that fail to build on the new Node (node-sass is the classic) are
   themselves legacy: replace them rather than holding Node back.

## End-of-life PHP

PHP 8.1 security support ended 2025-12-31; 8.0, 7.4 and older ended earlier. PHP 8.2's
security support ends 2026-12-31, so it is a poor target: aim for 8.4 or 8.5.

1. **Find the blockers**: `composer why-not php 8.4` lists every installed package whose
   constraint excludes PHP 8.4. Each needs a newer release; `composer outdated --direct`
   shows which exist.
2. **Run the target locally**: set DDEV `php_version: "8.4"`, `ddev restart`, run the
   app and tests, and read deprecation notices.
3. **Resolve for the target**: set `config.platform.php` to `"8.4.0"`, then
   `ddev composer update --with-all-dependencies`. Composer now resolves every package for
   8.4. Commit `composer.json` and `composer.lock` together.
4. **Raise `require.php`** to `"^8.4"` once the code is known to run on it (dropping the
   old floor is what lets packages drop support too).
5. **Upgrade the server before the deploy that carries the new lock.** Check the real
   server with `composer check-platform-reqs --lock --no-dev`; the generated
   `platform_check.php` stops the app at boot if the PHP is still too old.
6. Re-run `pm-audit`: `php.eol` and `php.pin.disagree` should both be gone.

CMS constraints set the floor: Craft CMS 5 requires PHP `^8.2`, Craft 4 `^8.0.2`.
Upgrading the CMS itself is `craftcms-ops` (or `laravel-ops`).
