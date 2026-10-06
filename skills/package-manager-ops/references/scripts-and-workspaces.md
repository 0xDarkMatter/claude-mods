# Scripts, Lifecycle Hooks and Workspaces

Running a project's scripts, what runs implicitly during an install, why dependency
install scripts no longer run by default anywhere, Composer scripts and plugins, and
monorepo workspaces. Configuring the bundler a script calls belongs to
`frontend-upgrade-ops`. Facts verified 2026-10-06 against docs.npmjs.com (v11 and v12, the
npm CHANGELOG), yarnpkg.com and the Yarn 4.14.0 release, pnpm.io and the pnpm 10, 11 and 12
release notes, bun.com, and getcomposer.org (docs and CHANGELOG at the 2.10.3 tag).

## Contents

- [npm scripts and pre/post hooks](#npm-scripts-and-prepost-hooks)
- [Dependency install scripts are blocked by default](#dependency-install-scripts-are-blocked-by-default)
- [ignore-scripts](#ignore-scripts)
- [Composer scripts and plugins](#composer-scripts-and-plugins)
- [Workspaces and monorepos](#workspaces-and-monorepos)
- [pnpm settings moved to pnpm-workspace.yaml](#pnpm-settings-moved-to-pnpm-workspaceyaml)

## npm scripts and pre/post hooks

- `npm run build` runs `scripts.build` with `node_modules/.bin` on `PATH`; pass flags
  after `--`: `npm run build -- --mode staging`.
- With npm, a script named `prebuild` or `postbuild` runs automatically before or after
  `build`. Yarn 4 does not run `pre`/`post` hooks for your own scripts. Don't build a
  pipeline on implicit hooks: chain explicitly,
  `"build": "npm run clean && vite build"`.
- Install-time lifecycle scripts of the *root* project (`preinstall`, `install`,
  `postinstall`, `prepare`) run on a local `npm install` and `npm ci`. npm 12 runs the
  root `preinstall` before dependencies are installed, so it cannot use them.
- List what a repo defines with `npm run` (no arguments).

## Dependency install scripts are blocked by default

A dependency's `postinstall` used to run on every install. All four managers now block
dependency install scripts unless you allow the package:

| Manager | Default | Allow one package |
|---|---|---|
| npm 12 | blocked unless the root package.json's `allowScripts` policy allows it (npm 11.16 only printed a notice) | `npm install-scripts approve <pkg>` (records `pkg@version` by default); review with `npm install-scripts ls`; `--allow-scripts=sharp,canvas` for an `npx` or `-g` install |
| pnpm 10+ | blocked; pnpm 11 makes an unapproved build an error (`strictDepBuilds`) | `pnpm approve-builds`, which writes `allowBuilds` (it replaced `onlyBuiltDependencies`, removed in pnpm 11) |
| Yarn 4.14.0+ | blocked (`enableScripts: false` is the default) | `dependenciesMeta: { <pkg>: { built: true } }` in package.json |
| Bun | only a built-in list of popular packages runs | `trustedDependencies` in package.json, which *replaces* the built-in list |

Day-to-day symptom: a package with a native or downloaded binary (esbuild, sharp,
`@parcel/watcher`, an old `node-sass`) installs but fails at run time with a missing
binary, or the install prints that builds were skipped. Approve that one package, commit
the policy change, and reinstall. Whether to allow a given package is a security decision;
the policy and its review belong to `supply-chain-defense`.

The project's own scripts, and its workspaces', still run.

## ignore-scripts

`ignore-scripts=true` in `.npmrc` (or `--ignore-scripts`) stops npm running scripts from
package.json files during installs, *including the root project's own* install scripts.
An explicit `npm run x` still runs `x`, but not its `prex`/`postx`. Use it for a CI step
that must not execute anything (a lockfile check), not as a substitute for the approval
lists above.

## Composer scripts and plugins

- Events fire around commands: `pre-install-cmd`, `post-install-cmd`, `pre-update-cmd`,
  `post-update-cmd`, `pre-autoload-dump`, `post-autoload-dump`,
  `post-root-package-install`, `post-create-project-cmd` and more. Craft's starter
  project, for example, runs Craft's own setup from `post-create-project-cmd`.
- Run a named script: `composer run-script <name>` (alias `composer run <name>`).
- Skip scripts: `--no-scripts` on any command, or `COMPOSER_SKIP_SCRIPTS` (2.8.6+) with
  a comma-separated list of event names.
- Plugins (packages of type `composer-plugin`) execute code inside Composer. Composer
  2.2+ only loads plugins listed in `config.allow-plugins`; interactively it asks, and a
  non-interactive run (CI, deploy) fails on an unlisted one, unless the plugin sets
  `extra.plugin-optional: true` (Composer 2.5.3+), in which case it is skipped without a
  word. The fix is a reviewed entry (`composer config allow-plugins.vendor/plugin true`),
  committed, never a blanket `true`.

## Workspaces and monorepos

One lockfile at the root covers every workspace: always in npm and Yarn, and by default
in pnpm (`sharedWorkspaceLockfile: false` in `pnpm-workspace.yaml` gives each project its
own).

| Manager | Declare | Run one | Run all |
|---|---|---|---|
| npm | `"workspaces": ["packages/*"]` in root package.json | `npm run build -w packages/site` | `npm run build --workspaces` |
| Yarn 4 | `"workspaces"` in root package.json | `yarn workspace site run build` | `yarn workspaces foreach -A run build` |
| pnpm | `packages:` list in `pnpm-workspace.yaml` | `pnpm --filter site run build` | `pnpm -r run build` |

Add a dependency to one workspace, not the root: `npm install zod -w packages/site`,
`yarn workspace site add zod`, `pnpm --filter site add zod`.

Composer has no workspaces; a monorepo uses path repositories, symlinked by default:

```json
{
  "repositories": [{ "type": "path", "url": "packages/*" }],
  "require": { "acme/shared": "@dev" }
}
```

pm-audit checks root manifests only; run it per workspace root if packages carry their
own lockfiles (they should not).

## pnpm settings moved to pnpm-workspace.yaml

pnpm 11 stopped reading the `pnpm` field of package.json. A repo upgraded from pnpm 10
with that field silently loses those settings; pm-audit reports it as
`js.pnpm.field-ignored`. `overrides`, `patchedDependencies`, `allowBuilds` and every
other project setting now live in `pnpm-workspace.yaml`, which a single-package repo also
has. User-wide settings go in the global `~/.config/pnpm/config.yaml`.

`.npmrc` keeps registry and auth settings, plus network settings (`httpProxy`,
`httpsProxy`, `noProxy`, `localAddress`, `strictSsl`, `gitShallowHosts`) that are still
read there to ease migration. Nothing else counts there: `engine-strict=true` needs to
become `engineStrict: true` in `pnpm-workspace.yaml`. `npm_config_*` environment
variables are no longer read (use `pnpm_config_*`). Since 11.5.3, a `${...}` in a
registry or auth setting of the project `.npmrc` is ignored
([registries-and-auth.md](registries-and-auth.md#pnpm-no-placeholders-in-the-project-npmrc)).

```yaml
# pnpm-workspace.yaml
packages:
  - "."
overrides:
  postcss: "^8.5.6"
```

Let `pnpm approve-builds` write the `allowBuilds` entries rather than hand-editing them.

pnpm 12 reports an unrecognised setting in this file. If the project pins a pnpm version
and the running pnpm satisfies that pin, it fails with
`ERR_PNPM_UNRECOGNIZED_WORKSPACE_SETTINGS`; otherwise it warns. `pnpm config` subcommands
never fail on it.
