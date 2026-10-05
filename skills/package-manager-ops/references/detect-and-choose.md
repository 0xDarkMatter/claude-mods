# Detect and Choose a Package Manager

Which manager a repo uses, what to do when it uses two, how to declare the choice so tools
enforce it, and how to switch managers without losing the versions you already run.
Facts verified 2026-10-05 against docs.npmjs.com (v11 and v12), yarnpkg.com, pnpm.io,
bun.com and the Node.js repository.

## Contents

- [Lockfile to manager](#lockfile-to-manager)
- [Two lockfiles: pick one](#two-lockfiles-pick-one)
- [Declaring the manager: packageManager, Corepack, devEngines](#declaring-the-manager-packagemanager-corepack-devengines)
- [Switching managers without losing resolved versions](#switching-managers-without-losing-resolved-versions)
- [Choosing for a new or orphaned repo](#choosing-for-a-new-or-orphaned-repo)

## Lockfile to manager

The lockfile is the ground truth. `package.json` says what is allowed; the lockfile says
what was installed, and only the manager that wrote it reads it.

| File at the repo root | Manager | Tell-tale |
|---|---|---|
| `package-lock.json` | npm | `lockfileVersion` 1 = npm 5-6, 2 = readable by npm 6 and 7+, 3 = npm 7+ only (current default) |
| `npm-shrinkwrap.json` | npm up to 11 | npm 12 neither reads nor writes it; rename it to `package-lock.json` in an application |
| `yarn.lock` starting `# yarn lockfile v1` | Yarn 1 (classic) | no `.yarnrc.yml` |
| `yarn.lock` with a `__metadata:` block | Yarn 2+ (Berry, today Yarn 4) | `.yarnrc.yml`, often `.yarn/releases/` |
| `pnpm-lock.yaml` | pnpm | `pnpm-workspace.yaml` in pnpm 11+ projects |
| `bun.lock` (text) or `bun.lockb` (binary) | Bun | text `bun.lock` is the default since Bun 1.2 |
| `deno.lock` | Deno | `deno.json` |
| `composer.lock` | Composer | always alongside `composer.json` |

npm also reads `yarn.lock` as resolution guidance when no `package-lock.json` exists
(npm 12 order: `package-lock.json`, then `yarn.lock`). That is a migration aid, not a
second source of truth.

`bash scripts/run-python.sh scripts/pm-audit.py <repo>` reports all of this at once.

## Two lockfiles: pick one

Two lockfiles mean two people (or a developer and the deploy) install different trees.
Each manager resolves from its own file and ignores the other, so they drift apart
silently. Resolve it in one commit:

1. **Find what production installs.** The deploy decides, because that is what is
   live. Read the deploy and CI config: an AWS CodeDeploy `appspec.yml` hook script,
   `buildspec.yml`, `.github/workflows/*.yml`, a `Dockerfile`, a `Makefile` or `justfile`.
   Whichever of `npm ci`, `yarn install` or `pnpm install` runs there is the keeper.
2. **If nothing deploys JS**, keep the lockfile touched most recently by a human:
   `git log -1 --format='%ci %an' -- package-lock.json yarn.lock pnpm-lock.yaml`.
3. **Switch cleanly**: delete `node_modules/` and the losing lockfile, run the keeper's
   normal install (not the frozen one), run the build, commit the deletion, the
   refreshed lockfile and a `packageManager` field together.
4. **Say why in the commit body**: which lockfile won and what decided it.
5. **Stop it recurring**: the `packageManager` field (below), a frozen install in CI
   (`npm ci` fails with no `package-lock.json`), and optionally the losing filename in
   `.gitignore`.

## Declaring the manager: packageManager, Corepack, devEngines

**`packageManager`** names one manager and an exact version:

```json
{ "packageManager": "pnpm@12.9.1" }
```

Yarn 4's `yarn set version` writes it, pnpm reads it, and actions/setup-node v6+ turns on
npm caching automatically when it names npm. It may carry a `+sha512.<hash>` suffix.

**Corepack** was the shim that read `packageManager` and fetched that exact version. The
Node.js TSC voted on 2025-03-19 to stop distributing it, and it has not shipped with Node
since **25.0.0**. Node 24 and earlier still bundle it as experimental. On Node 25+:

```bash
npm install -g corepack@0.36.0   # standalone; pin it like any global tool
corepack enable
```

DDEV has a `corepack_enable: true` setting for its web container. Do not build a new
workflow on Corepack being present; use it where it already is.

**`devEngines`** (npm **10.9.0**+) makes npm itself check the runtime and manager before
`install`, `ci` and `run`:

```json
{
  "devEngines": {
    "runtime": { "name": "node", "version": ">=24 <25", "onFail": "error" },
    "packageManager": { "name": "npm", "version": ">=11", "onFail": "error" }
  }
}
```

`onFail` is `warn`, `error` or `ignore`; undefined means `error`. Unlike `engines`, it
applies to the project itself, not to consumers of a published package.

## Switching managers without losing resolved versions

Never "delete the lockfile and reinstall" to switch: that silently upgrades every
dependency to the newest version its range allows. Import instead.

| From -> to | How | Notes |
|---|---|---|
| Yarn 1 -> npm | keep `yarn.lock`, delete `node_modules`, `npm install`, commit `package-lock.json`, delete `yarn.lock` | npm uses `yarn.lock` for guidance when no `package-lock.json` exists |
| npm or Yarn 1 -> pnpm | `pnpm import`, then `pnpm install` | reads `package-lock.json`, `npm-shrinkwrap.json` or `yarn.lock` |
| Yarn 1 -> Yarn 4 | `yarn set version stable`, then `yarn install` | migrates a v1 `yarn.lock`; add `nodeLinker: node-modules` to `.yarnrc.yml` to keep a `node_modules` layout |
| npm -> Yarn 4 | Yarn 1's `yarn import` first, then migrate to Yarn 4 | Yarn 4 removed `yarn import` and does not read `package-lock.json` |

After any switch: run the build and tests, then compare top-level versions
(`npm ls --depth=0` before and after, or the manager's equivalent). Update every place
that names the old manager in the same commit: package.json `scripts`, README, CI, deploy
hooks and DDEV custom commands.

## Choosing for a new or orphaned repo

There is no universally right manager; there is a wrong one per repo, which is "two".

- **npm** is the default for a server-rendered site (Craft, Laravel, WordPress): it ships
  with Node, every host and CI image has it, and `npm ci` is the simplest frozen install.
- **pnpm** earns its place in monorepos and disk-heavy machines (content-addressed store,
  strict `node_modules`). From pnpm 11, its settings live in `pnpm-workspace.yaml`.
- **Yarn 4** is right where a repo is already on Berry. Starting a new repo on Yarn 1 is
  never right: it has been in maintenance mode since January 2020 and only takes
  security fixes.
- **Bun** fits Bun-runtime projects; as a manager for a Node site it is one more tool
  every developer and CI image must carry.

Whatever you choose, write it down three ways: the lockfile, `packageManager`, and the
install command in CI and deploy.
