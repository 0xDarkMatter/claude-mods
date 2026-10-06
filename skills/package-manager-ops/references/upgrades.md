# Upgrades: Survey, Order, Peers and Lockfile-Only Refreshes

How to see what is behind, move it in an order that keeps the site building, read a peer
conflict instead of silencing it, and refresh a lockfile without touching anything else.
Facts verified 2026-10-06 against docs.npmjs.com, yarnpkg.com and the Yarn source,
pnpm.io, the npm-check-updates README, and the Composer docs and CHANGELOG at 2.10.3.

## Contents

- [Survey what is behind](#survey-what-is-behind)
- [In-range updates versus majors](#in-range-updates-versus-majors)
- [Upgrade order](#upgrade-order)
- [Peer dependency conflicts (ERESOLVE)](#peer-dependency-conflicts-eresolve)
- [Composer: why and why-not](#composer-why-and-why-not)
- [Lockfile-only refresh](#lockfile-only-refresh)

## Survey what is behind

| Manager | Command | Shows |
|---|---|---|
| npm | `npm outdated` | current, wanted (newest in range), latest |
| npm, major view | `npx npm-check-updates@23.1.0` | the latest of dependencies, devDependencies, optionalDependencies and `packageManager`, including majors (peers only with `--dep`); `-u` rewrites package.json |
| Yarn 1 / 4 | `yarn upgrade-interactive` | built in to both; Yarn 4 bundles every official plugin |
| pnpm | `pnpm outdated`, `pnpm update --interactive --latest` | `-i -L` picks across majors |
| Composer | `composer outdated --direct` | add `--major-only`, `--minor-only` or `--patch-only`; `--strict` exits non-zero when anything is outdated |

npm-check-updates is the one tool here usually run through npx, so it gets an exact pin
(see [npx-exec-safety.md](npx-exec-safety.md#the-rules)); bump the pin when you bump the
tool.

## In-range updates versus majors

- **In range** (safe by your own declaration): these move within the existing ranges.
  - `npm update`, `yarn upgrade` (Yarn 1) and `composer update` rewrite only the lockfile
    (npm also writes package.json when `save` applies).
  - `yarn up -R <pkg>` (Yarn 4) re-resolves `<pkg>` within the existing ranges and
    changes only the lockfile.
  - `pnpm update` also moves each package.json range up to the resolved version, keeping
    the operator (`^1.1.0` becomes `^1.4.2`), and updates catalog entries in
    `pnpm-workspace.yaml`. `pnpm update --no-save` changes the lockfile only.
- **Across a major** (a deliberate change): `npm install vite@^9`,
  `yarn up vite@^9`, `pnpm add vite@^9`, `composer require vendor/pkg:^6`. A plain
  `yarn up vite` belongs here too: it ignores the range in package.json, takes the
  newest version (majors included) and rewrites package.json. Both `yarn up` forms need
  package names; with none they change nothing.
- **Composer helpers**: `composer bump` (2.4.0+) raises each constraint in
  `composer.json` to the version currently installed, so the manifest stops admitting
  versions you no longer test; use it on applications, not libraries.
  `composer update --bump-after-update` (2.8.0+) does both in one step.
  `composer update --minimal-changes` (`-m`, 2.7.0+ for partial updates, 2.9.0+ for full
  ones) moves only what the requested change forces.

## Upgrade order

Move one layer at a time, building and testing between each, one major per commit:

1. **Runtime**: Node and PHP pins first ([version-pinning.md](version-pinning.md)),
   because everything below declares which runtimes it supports.
2. **Package manager**: the manager major and its lockfile format.
3. **Build tooling**: the bundler and its plugins (configuration changes belong to
   `frontend-upgrade-ops`).
4. **Frameworks**: Craft, Laravel, Vue and similar (`craftcms-ops`, `laravel-ops`,
   `vue-ops`).
5. **Leaf libraries**: everything else, batched only when each is a minor.

Read each package's changelog or upgrade guide before its major. When something breaks,
`git bisect` across commits is easy only if each commit moved one thing.

## Peer dependency conflicts (ERESOLVE)

npm 7+ installs peer dependencies itself, so a plugin that declares
`peerDependencies: { vite: "^7" }` conflicts with a project on Vite 8. npm stops with
`ERESOLVE unable to resolve dependency tree`. Read it before reaching for a flag:

```text
While resolving: vite-plugin-example@3.1.0
Found: vite@8.0.10
Could not resolve dependency:
peer vite@"^7.0.0" from vite-plugin-example@3.1.0
```

That says: `vite-plugin-example` 3.1.0 only supports Vite 7. The fixes, best first:

1. Upgrade the plugin to a release whose peer range admits Vite 8 (`npm view
   vite-plugin-example peerDependencies` per version).
2. Hold the core package back until the plugin catches up.
3. Replace or drop the plugin.
4. Only as a recorded, temporary decision: `--legacy-peer-deps`.

`--legacy-peer-deps` ignores peer dependencies entirely, as npm 3 to 6 did; npm's own docs
call it not recommended. If you must use it, put `legacy-peer-deps=true` in the project
`.npmrc` (so CI, deploy and every developer resolve the same tree) with a comment naming the
plugin and the issue to watch. A flag used once on one laptop yields a lockfile nobody else
can reproduce. `--force` is broader (it also overrides engine checks and more): don't.
`strict-peer-deps=true` turns peer warnings into failures if you want the opposite.

## Composer: why and why-not

- `composer why vendor/pkg` (alias of `depends`): which packages require it, and with
  what constraint. Add `-r` for recursion, `-t` for a tree.
- `composer why-not vendor/pkg 6.0` (alias of `prohibits`): what blocks moving to that
  version.
- `composer why-not php 8.4`: which packages would stop you running on PHP 8.4, the
  first command of any PHP upgrade ([legacy-exits.md](legacy-exits.md#end-of-life-php)).

## Lockfile-only refresh

Refresh metadata or resolve without installing:

| Manager | Command |
|---|---|
| npm | `npm install --package-lock-only` |
| Yarn 4 | `yarn install --mode=update-lockfile` |
| pnpm | `pnpm install --lockfile-only` |
| Composer | `composer update --no-install` (resolve and write the lock); `composer update --lock --no-install` (hash and metadata only; without `--no-install` the install step runs too) |

Review the diff: a lockfile-only refresh that moves dozens of versions is an update, and
deserves the same testing as one.
