# Version Pinning: Node, PHP and Dependency Ranges

Pin the runtime the way you pin dependencies: one declared version, every tool reading
the same one. Facts verified 2026-10-05 against nodejs/Release `schedule.json`, the
nodejs.org release-schedule announcement (2026-03-10), php.net supported-versions and EOL
pages, docs.npmjs.com, docs.ddev.com (stable, v1.25.4), the fnm, nvm-windows and Volta
repositories, and Packagist.

## Contents

- [Node release lines today](#node-release-lines-today)
- [What reads which Node pin](#what-reads-which-node-pin)
- [The recommended Node pin set](#the-recommended-node-pin-set)
- [Version managers](#version-managers)
- [PHP release lines today](#php-release-lines-today)
- [The three PHP pins and what each means](#the-three-php-pins-and-what-each-means)
- [Ranges, exact pins and overrides](#ranges-exact-pins-and-overrides)

## Node release lines today

| Major | Status on 2026-10-05 | Next change | End of life |
|---|---|---|---|
| 26 | Current | Active LTS from 2026-10-28 | 2029-04-30 |
| 24 (Krypton) | Active LTS | Maintenance from 2026-10-20 | 2028-04-30 |
| 22 (Jod) | Maintenance LTS | - | 2027-04-30 |
| 25 | end of life | - | 2026-06-01 |
| 20 (Iron) and older | end of life | - | 20 ended 2026-04-30; 18 ended 2025-04-30 |

From Node 27 the project ships one major a year (alpha October to March, Current April to
October), every line becomes LTS, and the major tracks the year (27 in 2027). Odd-numbered
"never LTS" lines end with 25. Production pins should be LTS majors; pm-audit reads its
end-of-life table from `assets/package-manager-facts.json`.

## What reads which Node pin

| Pin | Read by |
|---|---|
| `.nvmrc` | nvm, fnm, nvm-windows v2 (shim mode), DDEV `nodejs_version: auto`, actions/setup-node `node-version-file` |
| `.node-version` | fnm, nodenv, nvm-windows v2, DDEV `auto`, setup-node |
| `engines.node` | npm: advisory unless `.npmrc` sets `engine-strict=true`; fnm (on by default since 1.38.0); DDEV `auto` and `engine` |
| `devEngines.runtime` | npm 10.9.0+ before `install`, `ci` and `run`; pnpm |
| `volta.node` in package.json | Volta, which is unmaintained (its README recommends moving to mise) |
| `.tool-versions`, `mise.toml` | asdf, mise |
| `.ddev/config.yaml` `nodejs_version` | the DDEV web container |

`engines` without `engine-strict=true` only warns, so on its own it pins nothing. Note
that `engines` also tells *consumers* of a published package what it supports; for an
application, `devEngines` is the stricter, project-only form.

## The recommended Node pin set

For an application, four lines that agree:

```text
.nvmrc                      24
package.json engines.node   ">=24 <25"        (or "24.x")
.npmrc                      engine-strict=true
.ddev/config.yaml           nodejs_version: auto   (reads .nvmrc), or "24"
```

CI then uses `node-version-file: .nvmrc`, and the deploy host installs the same major.
Pin the major in `.nvmrc` unless you have a reason to pin a minor: a major pin follows
security releases automatically.

DDEV details: `nodejs_version` takes a major (`"22"` installs the newest 22.x), a partial
or full version, `auto` (reads `.node-version`, `.nvmrc`, then `engines.node`), `engine`
(reads only `engines.node`), or `""` for the image default. Unset, it follows DDEV's
default, the current LTS at the time that DDEV release shipped, so a DDEV upgrade can move
the container's Node under you. The version is fixed when the image builds; after
changing it, `ddev restart`.

## Version managers

| Tool | Platforms | Notes |
|---|---|---|
| nvm | macOS, Linux, WSL | reads `.nvmrc` on `nvm use` / `nvm install` |
| fnm | all, including Windows | reads `.nvmrc` and `.node-version`, and `engines.node` by default since 1.38.0; `--use-on-cd` switches per directory |
| nvm-windows | Windows | the project moved to the `nvm-windows/nvm` repository and v2 is a rewrite; v2 detects `.nvmrc`, `.node-version` and package.json in shim mode; v1 ignores `.nvmrc` |
| mise | all | reads `.tool-versions`, `mise.toml` and, with config, `.nvmrc`; the migration target Volta's README names |
| Volta | all | unmaintained: move off it, keep `.nvmrc` as the shared pin |

On Windows, nvm-windows v1 switches one global Node for every open terminal. That is why
"it works in my other terminal" happens there.

## PHP release lines today

| Branch | Status on 2026-10-05 | Active support ends | Security support ends |
|---|---|---|---|
| 8.5 | active | 2027-12-31 | 2029-12-31 |
| 8.4 | active | 2026-12-31 | 2028-12-31 |
| 8.3 | security fixes only | ended 2025-12-31 | 2027-12-31 |
| 8.2 | security fixes only | ended 2024-12-31 | 2026-12-31 |
| 8.1 | end of life | - | ended 2025-12-31 |
| 8.0, 7.x | end of life | - | 8.0 ended 2023-11-26; 7.4 ended 2022-11-28 |

PHP 8.6 is scheduled for 2026-11-19. Craft CMS 5 requires PHP `^8.2` and Craft 4
`^8.0.2` (Packagist), so a Craft 4 site can sit on an end-of-life PHP while satisfying
Craft; check the PHP, not just the CMS.

## The three PHP pins and what each means

| Pin | Means | Set it to |
|---|---|---|
| `require.php` in `composer.json` | the PHP versions the code supports | a range: `"^8.3"` |
| `config.platform.php` in `composer.json` | pretend to be this PHP when resolving | production's exact version: `"8.3.0"` |
| `php_version` in `.ddev/config.yaml` | what the container runs | production's major.minor: `"8.3"` |

Why the platform pin matters: `composer update` resolves for whatever PHP runs it. A
developer with PHP 8.5 on the host gets packages that need 8.5, and production on 8.3
fatals. With `config.platform.php` every machine resolves for production. The lock
records it as `platform-overrides`, which pm-audit compares too.

Because the platform pin pretends, check the real server at deploy:
`composer check-platform-reqs --lock --no-dev`. `require.php` must admit the
platform and DDEV versions, or `composer update` cannot resolve. A library (anything not
`"type": "project"`) sets `require.php` but not `config.platform`.

## Ranges, exact pins and overrides

For applications the lockfile is the pin; ranges in the manifest only say what an
update may move to. Caret ranges (`^8.0.10`) are the sane default. Exact pins
(`save-exact=true` in `.npmrc`) make every update an explicit manifest diff, which some
teams want for review; the cost is noisier upgrade PRs.

Forcing a transitive version:

| Manager | Field | Notes |
|---|---|---|
| npm (8.3.0+) | `overrides` in the root package.json | flat (`"pkg": "1.2.3"`), nested, version-qualified keys, `$dep` references |
| Yarn 1 / 4 | `resolutions` | Yarn 4 accepts one level of nesting, root only |
| pnpm | `overrides` in `pnpm-workspace.yaml` | pnpm 11+ ignores the `pnpm` field in package.json; pnpm 10 read both |
| Composer | no override field | require the transitive package directly with a constraint, or forbid versions with `conflict` |

Every override is a promise to remove it later: leave a comment in the PR saying which
advisory or bug it works around, and check `npm ls <pkg>` after.
