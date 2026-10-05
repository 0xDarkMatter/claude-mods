# Diagnostics: Reading the Tools and the Audit

What each pm-audit finding means, how to read `npm ls`, `npm explain` and
`composer why`, the anatomy of ERESOLVE and integrity failures, lockfile merge
conflicts, and the "works on my machine" checklist. Facts verified 2026-10-05 against
docs.npmjs.com (v12), getcomposer.org (checked against 2.10.3) and the Composer CHANGELOG.

## Contents

- [pm-audit finding ids](#pm-audit-finding-ids)
- [npm ls, explain and query](#npm-ls-explain-and-query)
- [Composer diagnostics](#composer-diagnostics)
- [ERESOLVE](#eresolve)
- [Integrity failures](#integrity-failures)
- [Lockfile merge conflicts](#lockfile-merge-conflicts)
- [Works on my machine](#works-on-my-machine)

## pm-audit finding ids

`bash scripts/run-python.sh scripts/pm-audit.py <repo>` exits 10 when it reports any of
these, 0 when clean. Notes on stderr (for example `js.packagemanager.unset`,
`js.yarn.classic`, `js.engines.unenforced`) are advice and never change the exit code.

| Id | Severity | Means | Fix in |
|---|---|---|---|
| `js.lockfile.conflict` | error | two or more JS lockfiles at the root | [detect-and-choose.md](detect-and-choose.md#two-lockfiles-pick-one) |
| `js.lockfile.missing` | warn | dependencies but no lockfile | [install-semantics.md](install-semantics.md#the-one-table) |
| `js.lockfile.stale` | warn | lockfile disagrees with package.json; a frozen install fails | [install-semantics.md](install-semantics.md#why-a-lockfile-changes-under-you) |
| `js.lockfile.v1` | warn | npm 6-era lockfile | [legacy-exits.md](legacy-exits.md#npm-lockfileversion-1) |
| `js.lockfile.shrinkwrap` | warn | only `npm-shrinkwrap.json`, which npm 12 ignores | [detect-and-choose.md](detect-and-choose.md#lockfile-to-manager) |
| `js.pnpm.field-ignored` | warn | a `pnpm` field pnpm 11+ no longer reads | [scripts-and-workspaces.md](scripts-and-workspaces.md#pnpm-settings-moved-to-pnpm-workspaceyaml) |
| `js.packagemanager.mismatch` | error | `packageManager` names a manager (or Yarn flavour) the lockfile is not from | [detect-and-choose.md](detect-and-choose.md#declaring-the-manager-packagemanager-corepack-devengines) |
| `js.manifest.invalid` | error | package.json is not valid JSON | - |
| `js.node.unpinned` | warn | nothing pins Node | [version-pinning.md](version-pinning.md#the-recommended-node-pin-set) |
| `js.node.eol` | warn | a pinned (or the only admitted) Node is end of life | [legacy-exits.md](legacy-exits.md#end-of-life-node) |
| `node.pin.disagree` | warn | `.nvmrc`, `engines`, `devEngines`, DDEV and friends name different majors | [version-pinning.md](version-pinning.md#what-reads-which-node-pin) |
| `ddev.node.unpinned` | warn | DDEV has no `nodejs_version`, so it follows DDEV's default | [platform-gotchas.md](platform-gotchas.md#ddev-host-or-container) |
| `ddev.php.unpinned` | warn | DDEV has no `php_version` | [platform-gotchas.md](platform-gotchas.md#ddev-host-or-container) |
| `php.manifest.invalid` | error | composer.json is not valid JSON | `composer validate` |
| `php.require.missing` | warn | no `require.php` | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.platform.unset` | warn | no `config.platform.php` in a project | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.pin.disagree` | warn | DDEV `php_version`, `config.platform.php`, the lock's platform override and `require.php` disagree | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.eol` | warn | a pinned (or the only admitted) PHP is past security support | [legacy-exits.md](legacy-exits.md#end-of-life-php) |
| `php.lockfile.missing` | warn | a project with packages but no `composer.lock` | [install-semantics.md](install-semantics.md#composer-install-versus-composer-update) |
| `php.lockfile.stale` | warn | `composer.json` requires packages the lock lacks | [install-semantics.md](install-semantics.md#composer-install-versus-composer-update) |
| `npx.unpinned` | warn | `npx`/`dlx`/`bunx` of an unpinned, undeclared package | [npx-exec-safety.md](npx-exec-safety.md#the-rules) |
| `npx.native-cli` | error | a native CLI (rg, fd, sd, jq...) through npx | [npx-exec-safety.md](npx-exec-safety.md#never-route-a-native-cli-through-npx) |
| `legacy.bower` | warn | `bower.json` or `.bowerrc` | [legacy-exits.md](legacy-exits.md#bower-to-npm) |
| `legacy.node-sass` | warn | node-sass in package.json | [legacy-exits.md](legacy-exits.md#node-sass-to-dart-sass) |
| `registry.token.committed` | error | a literal token in `.npmrc` or `.yarnrc.yml` | [registries-and-auth.md](registries-and-auth.md#when-a-token-was-committed) |
| `registry.authjson.committed` | error | a root `auth.json` that is not gitignored | [registries-and-auth.md](registries-and-auth.md#when-a-token-was-committed) |

The end-of-life checks read dated tables from `assets/package-manager-facts.json`; pass
`--as-of YYYY-MM-DD` to ask "is this still supported on the day we ship?".

## npm ls, explain and query

- `npm ls <pkg>`: every path to `<pkg>` in the tree. Markers: `invalid` (installed
  version outside the range something wants), `extraneous` (installed, required by
  nothing), `missing`, `deduped`.
- `npm ls --all`: the whole tree (depth defaults to unlimited with `--all`, 0 without).
- `npm explain <pkg>` (alias `npm why`): the chain of dependents that pulled `<pkg>` in,
  with the range each one asked for. Start here for "why is this old version installed?".
- `npm query '<selector>'`: CSS-like selectors over the tree, for example
  `npm query ':root > .dev'` lists direct devDependencies.
- Yarn: `yarn why <pkg>`; pnpm: `pnpm why <pkg>`.

## Composer diagnostics

| Command | Answers |
|---|---|
| `composer validate` | is composer.json valid, and is the lock up to date with it? `--strict` fails on warnings too; `--no-check-lock` skips the lock check |
| `composer diagnose` | environment problems: connectivity, auth, PHP settings, Composer's own dependencies, active plugins |
| `composer why vendor/pkg` | who requires it (`-t` tree, `-r` recursive) |
| `composer why-not vendor/pkg 6.0` | what blocks that version |
| `composer check-platform-reqs --lock` | does the real PHP and extension set satisfy the lock |
| `composer audit` | known advisories; since 2.10.0 it exits 0 or 1. Triage belongs to `security-ops` |

## ERESOLVE

npm could not build a tree that satisfies every peer range. Read the three lines that
matter: *while resolving* (the package with the peer requirement), *found* (what you
have), *could not resolve dependency* (what it wants). The fix is a compatible version,
not a flag; [upgrades.md](upgrades.md#peer-dependency-conflicts-eresolve) walks through it.

## Integrity failures

`EINTEGRITY` (npm), "integrity check failed" (Yarn, pnpm) or a Composer checksum
mismatch: the tarball downloaded does not hash to what the lockfile recorded.

- **Corrupt local cache**: `npm cache verify`, then retry.
- **A mirror serving a different tarball** for the same version: fix the mirror, or
  point the repo at one registry consistently.
- **A hand-edited or badly merged lockfile**: regenerate that entry by reinstalling the
  package, never by deleting `integrity` fields.
- **A public package whose published hash changed**: registries forbid republishing a
  version, so treat it as a possible compromise and hand it to `supply-chain-defense`
  before installing anything.

## Lockfile merge conflicts

Never hand-merge a lockfile. Resolve `package.json` or `composer.json` first, then let
the tool rebuild the lock:

- **npm**: after fixing package.json, `npm install` (or `npm install
  --package-lock-only`) rewrites a conflicted `package-lock.json`. Yarn and pnpm also
  repair a conflicted lockfile on a plain install; review the result either way.
- **Composer**: take one side's `composer.lock` (`git checkout --theirs composer.lock`),
  then re-apply the other branch's change with the same command it used
  (`composer require vendor/pkg:^2` or `composer update vendor/pkg`). The
  getcomposer.org article "Resolving merge conflicts" describes this.

## Works on my machine

When an install or build differs between two machines, check in this order:

1. Same manager and same major (`npm -v`, `yarn -v`, `pnpm -v`, `composer -V`)?
2. Frozen install on both (`npm ci`, not `npm install`)?
3. Same Node major as the pins (`node -v` vs `.nvmrc`) and the same architecture
   (`node -p process.arch`)?
4. Same PHP (`php -v` on the host vs DDEV `php_version`), and was Composer run on the
   host or in the container?
5. `node_modules` installed on one OS and used on another (host vs DDEV, macOS vs Linux)?
6. User-level config that the repo does not see: `~/.npmrc` registry or token,
   `COMPOSER_HOME` auth, global `NODE_ENV=production`.
7. Then run pm-audit on the repo; most remaining causes are a finding in the table above.
