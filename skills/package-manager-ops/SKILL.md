---
name: package-manager-ops
description: "Use when installing, pinning, upgrading or debugging JS and PHP dependencies with npm, Yarn, pnpm, Bun or Composer: two lockfiles in one repo, npm ci vs install, frozen installs in CI and deploys, Node or PHP pins that disagree with DDEV, packageManager and Corepack, unpinned npx, ERESOLVE and integrity errors, private registry auth, CI caches, or leaving Bower, node-sass, Yarn 1 and end-of-life PHP. Ships pm-audit, a read-only repo audit."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "supply-chain-defense, frontend-upgrade-ops, javascript-ops, typescript-ops, docker-ops, craftcms-ops, ci-cd-ops, security-ops"
---

# Package Manager Operations

Day-to-day use of npm, Yarn, pnpm, Bun and Composer: which one a repo uses, which install
command belongs in dev, CI and deploy, how to pin Node and PHP so every machine agrees,
how to run packages without fetching strangers' code, and how to get off the legacy
tools. Written for server-rendered sites (Craft CMS, Laravel, WordPress) on DDEV with a
Vite or Laravel Mix build, where these mistakes are common: two lockfiles, unpinned
Node, no `require.php`, end-of-life PHP and `npx` in READMEs.

> Facts verified as of 2026-10-05 against docs.npmjs.com, yarnpkg.com, pnpm.io, bun.com,
> getcomposer.org (checked against the 2.10.3 tag), nodejs.org, php.net and
> docs.ddev.com. Current majors: npm 12 (since 2026-07-08; Node 24 and 26 still bundle
> npm 11), pnpm 12, Yarn 4, Composer 2 (2.10.3), Bun 1. Each reference cites its sources.

## Start here

| You find or are asked | Do | Read |
|---|---|---|
| Any repo, before changing dependencies | Run pm-audit (below) and fix its findings first | [diagnostics.md](references/diagnostics.md#pm-audit-finding-ids) |
| Two lockfiles (`package-lock.json` + `yarn.lock`) | Keep the one the deploy uses, delete the other, reinstall, commit with the reason | [detect-and-choose.md](references/detect-and-choose.md) |
| "Which command in CI / on deploy?" | The frozen one: `npm ci`, `composer install` | [install-semantics.md](references/install-semantics.md) |
| `npm install` or `composer update` in a deploy hook | Replace with the frozen install | [install-semantics.md](references/install-semantics.md#deploy-patterns) |
| No `.nvmrc`, or pins that disagree with DDEV | One Node major in `.nvmrc`, `engines`, DDEV | [version-pinning.md](references/version-pinning.md) |
| `composer.json` without `require.php` or `config.platform.php` | Add both; match DDEV `php_version` | [version-pinning.md](references/version-pinning.md#the-three-php-pins-and-what-each-means) |
| `npx something` in scripts or README | devDependency, or an exact `@x.y.z` pin | [npx-exec-safety.md](references/npx-exec-safety.md) |
| Upgrading dependencies, ERESOLVE | Survey, then one layer and one major at a time | [upgrades.md](references/upgrades.md) |
| A native package "installed" but its binary is missing | Dependency build scripts are blocked by default now; approve that package | [scripts-and-workspaces.md](references/scripts-and-workspaces.md#dependency-install-scripts-are-blocked-by-default) |
| Monorepo, workspaces, Composer scripts or plugins | One lockfile at the root; allow plugins one by one | [scripts-and-workspaces.md](references/scripts-and-workspaces.md) |
| Private packages, tokens, mirrors | Env references only; never a token in git | [registries-and-auth.md](references/registries-and-auth.md) |
| Slow or flaky CI installs | Cache the download cache keyed on the lockfile | [caches-and-ci.md](references/caches-and-ci.md) |
| Windows, DDEV host-vs-container, Apple Silicon oddities | Install where the code runs; check `node -p process.arch` | [platform-gotchas.md](references/platform-gotchas.md) |
| `bower.json`, node-sass, Yarn 1, PHP 8.1 or older | Planned exit, one at a time | [legacy-exits.md](references/legacy-exits.md) |
| EINTEGRITY, lock merge conflict, "works on my machine" | Never hand-merge a lockfile: take one side, re-run the other side's commands | [diagnostics.md](references/diagnostics.md) |

## Hard rules

1. **One manager, one lockfile, committed.** The lockfile is the contract; the manifest
   only says what an update may move to. Two lockfiles is always a bug.
2. **Frozen installs everywhere but a dev machine.** CI and deploy run `npm ci`,
   `yarn install --immutable`, `pnpm install --frozen-lockfile` or `composer install`.
   Never `npm install` or `composer update` on a server; if a frozen install fails, the
   fix happens on a dev machine and is committed.
3. **Never switch managers by deleting the lockfile.** Import it (`pnpm import`, npm reading
   `yarn.lock`, Yarn 4 migrating a v1 lock) so resolved versions survive.
4. **Pin the runtimes and make every pin agree.** Node: `.nvmrc`, `engines.node` with
   `engine-strict=true`, DDEV `nodejs_version` (or `auto`). PHP: `require.php` (range),
   `config.platform.php` (production's exact version) and DDEV `php_version` (same
   major.minor). Production pins name supported releases.
5. **Run package managers where the code runs.** In a DDEV project that is
   `ddev composer ...` and `ddev npm ...`; never install `node_modules` from both the
   host and the container.
6. **No `npx` in package.json scripts; exact pins everywhere else.** In CI `npx` installs
   without asking. Never route a native CLI (rg, fd, sd, jq) through npx: its npm name
   is not its official channel.
7. **Credentials live in the environment.** Committed `.npmrc`/`.yarnrc.yml` hold
   `${NPM_TOKEN}`; Composer uses global `auth.json` or `COMPOSER_AUTH`. A committed
   token is revoked first, removed second.
8. **Read the error before the flag.** `--legacy-peer-deps`, `--force` and
   `--no-scripts` hide the problem from everyone except you; if one is truly needed, it
   goes in project config with a comment, so every machine resolves the same tree.
9. **Upgrade one layer at a time**: runtime, manager, build tooling, frameworks, leaf
   libraries; one major per commit.

## The install table

| Manager | Dev (may change the lock) | CI / deploy (lock is law) | Production deps only |
|---|---|---|---|
| npm | `npm install` | `npm ci` | `npm ci --omit=dev` |
| Yarn 1 | `yarn install` | `yarn install --frozen-lockfile` | add `--production` |
| Yarn 4 | `yarn install` | `yarn install --immutable` | `yarn workspaces focus --all --production` |
| pnpm | `pnpm install` | `pnpm install --frozen-lockfile` | `pnpm install --prod --frozen-lockfile` |
| Bun | `bun install` | `bun ci` | `bun install --production` |
| Composer | `composer update <pkg>` | `composer install` | `composer install --no-dev --optimize-autoloader` |

Two facts that changed recently and break old habits: Corepack has not shipped with Node
since 25.0.0 (install it standalone where you still rely on `packageManager` through it),
and npm 12, pnpm 10+, Yarn 4.14+ and Bun all block dependency install scripts by default.

## Audit a repo: pm-audit

A read-only scan of one repo root. It finds conflicting lockfiles, lockfiles that
disagree with their manifests, Node and PHP pins that are missing, disagree with each
other or with DDEV, or name end-of-life releases, unpinned `npx`/`dlx` use in scripts,
docs and CI, native CLIs routed through npx, Bower and node-sass, and committed registry
credentials (reported by file and line, never by value).

```bash
bash scripts/run-python.sh scripts/pm-audit.py path/to/repo
bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[] | "\(.id)\t\(.file)"'
bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2027-01-01 path/to/repo
```

- Exit `0` clean, `10` findings, `2` usage, `3` path missing. Plain output is one TSV
  row per finding: severity, id, file, message, fix. Advisory notes go to stderr.
- `--as-of` moves the end-of-life line (PHP 8.2 dies on 2026-12-31: ask before you
  ship). `--no-docs` skips the docs/CI walk; package.json scripts are still checked.
- It reads root manifests only. Every finding id, its meaning and its fix are in
  [diagnostics.md](references/diagnostics.md#pm-audit-finding-ids).
- `scripts/run-python.sh` picks the first real Python 3.8+ (`python3`, `python`, `py`),
  stepping over the Windows Store `python3` stub. The skill folder runs copied alone.

## Keep the facts fresh

The end-of-life tables and tool majors live in one place,
`assets/package-manager-facts.json`, which pm-audit reads at run time.
`scripts/check-pm-facts.py` guards it:

```bash
bash scripts/run-python.sh scripts/check-pm-facts.py --offline   # PR CI: tables valid, prose names every fact
bash scripts/run-python.sh scripts/check-pm-facts.py --live      # weekly: nodejs.org, php.net, npm, Composer, GitHub
```

`--live` exits `10` on drift (a new Node or PHP line, a moved date, a new manager major,
Volta or Corepack changing status) and `7` when a source is unreachable, which is
advisory. After drift, re-verify the affected reference against its source, then update
the table and the prose together.

## Boundaries

| Concern | Owner |
|---|---|
| Dependency security: cooldowns, behavioural scans, IOCs, install-hook policy | `supply-chain-defense` |
| Vulnerability triage, `composer audit` and `npm audit` findings | `security-ops` |
| Configuring Mix, Webpack or Vite and migrating between them | `frontend-upgrade-ops` |
| JavaScript language and Node runtime patterns | `javascript-ops` |
| TypeScript and `tsconfig` | `typescript-ops` |
| Container images, multi-stage `npm ci` and `composer install` layers | `docker-ops` |
| Craft CMS itself, including Craft on DDEV | `craftcms-ops` |
| CI pipeline design and action pinning | `ci-cd-ops` |

This skill covers running build scripts, not configuring bundlers, and day-to-day
dependency use, not deciding whether a package is safe.

## References

| File | Covers |
|---|---|
| [references/detect-and-choose.md](references/detect-and-choose.md) | lockfile to manager, two lockfiles, `packageManager`, Corepack, `devEngines`, switching managers |
| [references/install-semantics.md](references/install-semantics.md) | `npm ci` vs `install`, frozen installs, `composer install` vs `update`, autoloader levels, deploy patterns |
| [references/version-pinning.md](references/version-pinning.md) | Node and PHP release lines, every pin and who reads it, version managers, overrides |
| [references/npx-exec-safety.md](references/npx-exec-safety.md) | npx semantics, pinning rules, native CLIs, dlx/bunx/pnx, `composer exec`/`global` |
| [references/upgrades.md](references/upgrades.md) | outdated surveys, upgrade order, ERESOLVE and peer deps, `composer why-not php`, lockfile-only refresh |
| [references/scripts-and-workspaces.md](references/scripts-and-workspaces.md) | scripts and hooks, blocked install scripts, Composer scripts and plugins, workspaces, pnpm settings |
| [references/registries-and-auth.md](references/registries-and-auth.md) | `.npmrc`, `.yarnrc.yml`, `auth.json`, `COMPOSER_AUTH`, CI wiring, mirrors, leaked tokens |
| [references/caches-and-ci.md](references/caches-and-ci.md) | cache locations, CI cache keys, a GitHub Actions job, offline installs |
| [references/platform-gotchas.md](references/platform-gotchas.md) | Windows, DDEV host vs container, Apple Silicon, cross-platform lockfiles |
| [references/legacy-exits.md](references/legacy-exits.md) | Bower, node-sass, Yarn 1, lockfile v1, end-of-life Node and PHP |
| [references/diagnostics.md](references/diagnostics.md) | pm-audit ids, `npm ls`/`explain`, Composer diagnostics, ERESOLVE, EINTEGRITY, merge conflicts |
