---
name: package-manager-ops
description: "Use when installing, pinning, upgrading or debugging JS and PHP dependencies with npm, Yarn, pnpm, Bun or Composer: two lockfiles, switching managers, npm ci vs install, frozen or offline CI installs, workspace targeting, Node/PHP pins vs DDEV, packageManager, Corepack, unpinned npx, ERESOLVE, EINTEGRITY, duplicate versions, dedupe, Composer autoload, registry auth, CI caches, leaving Bower, node-sass, Yarn 1 and EOL PHP. Ships pm-audit. Not for bundler config, CVE triage or vetting a package."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "supply-chain-defense, frontend-upgrade-ops, javascript-ops, typescript-ops, docker-ops, ddev-ops, craftcms-ops, ci-cd-ops, security-ops"
---

# Package Manager Operations

Day-to-day use of npm, Yarn, pnpm, Bun and Composer: which one a repo uses, which install
command belongs in dev, CI and deploy, how to pin Node and PHP so every machine agrees,
how to run packages without fetching strangers' code, and how to get off the legacy
tools. Written for server-rendered sites (Craft CMS, Laravel, WordPress) on DDEV with a
Vite or Laravel Mix build, where these mistakes are common: two lockfiles, unpinned
Node, no `require.php`, end-of-life PHP and `npx` in READMEs.

> Facts verified as of 2026-10-06 against docs.npmjs.com, yarnpkg.com, pnpm.io, bun.com,
> getcomposer.org (checked against the 2.10.3 tag), nodejs.org, php.net and
> docs.ddev.com. Current majors: npm 12 (since 2026-07-08; Node 24 and 26 still bundle
> npm 11), pnpm 12, Yarn 4, Composer 2 (2.10.3), Bun 1. Each reference cites its sources.
> For a version-sensitive answer, read `assets/package-manager-facts.json` and re-check
> upstream when this date is stale; keeping it current (`scripts/check-pm-facts.py`) is in
> [version-pinning.md](references/version-pinning.md#maintaining-the-facts).

## Start here

| You find or are asked | Do | Read |
|---|---|---|
| Any repo, before changing dependencies | Run pm-audit (below); fix the findings relevant to the change and report the rest | [diagnostics.md](references/diagnostics.md#pm-audit-finding-ids) |
| Two lockfiles (`package-lock.json` + `yarn.lock`) | Keep the one the deploy uses, delete the other, reinstall, commit with the reason | [detect-and-choose.md](references/detect-and-choose.md) |
| Choosing a manager, or switching managers | npm by default for a site; switch by importing the lockfile, never by deleting it | [detect-and-choose.md](references/detect-and-choose.md) |
| "Which command in CI / on deploy?" | The frozen one: `npm ci`, `composer install` | [install-semantics.md](references/install-semantics.md) |
| `npm install` or `composer update` in a deploy hook | Replace with the frozen install | [install-semantics.md](references/install-semantics.md#deploy-patterns) |
| Offline or air-gapped CI | `npm ci --offline` or `pnpm install --offline` from a filled cache, or a mirror inside the network | [caches-and-ci.md](references/caches-and-ci.md#offline-and-air-gapped-installs) |
| Composer autoloader for production | `-o` always; `-a` only when no class appears at run time | [install-semantics.md](references/install-semantics.md#composer-install-versus-composer-update) |
| No `.nvmrc`, or pins that disagree with DDEV | One Node major in `.nvmrc`, `engines`, DDEV | [version-pinning.md](references/version-pinning.md) |
| `composer.json` without `require.php` or `config.platform.php` | Add both; match DDEV `php_version` | [version-pinning.md](references/version-pinning.md#the-three-php-pins-and-what-each-means) |
| `npx something` in scripts or README | devDependency, or an exact `@x.y.z` pin | [npx-exec-safety.md](references/npx-exec-safety.md) |
| A planned dependency upgrade | Survey, then one layer and one major at a time | [upgrades.md](references/upgrades.md) |
| ERESOLVE during an install | Read which peer range conflicts; fix the version, not the flag | [diagnostics.md](references/diagnostics.md#eresolve) |
| Duplicate versions, or an unexpected transitive dependency | Find who pulls it in, then dedupe or move the range that holds it back | [upgrades.md](references/upgrades.md#duplicate-versions) |
| A native package "installed" but its binary is missing | Check the platform and the lockfile's optional per-platform packages first; only if a lifecycle script was blocked, follow the project's install-script policy (owned by `supply-chain-defense`) | [platform-gotchas.md](references/platform-gotchas.md#native-binaries-and-the-cross-platform-lockfile), [scripts-and-workspaces.md](references/scripts-and-workspaces.md#dependency-install-scripts-are-blocked-by-default) |
| Monorepo, workspaces, Composer scripts or plugins | One lockfile at the root; allow plugins one by one | [scripts-and-workspaces.md](references/scripts-and-workspaces.md) |
| Adding a dependency to one workspace | Target the workspace (`-w`, `yarn workspace`, `--filter`), not the root | [scripts-and-workspaces.md](references/scripts-and-workspaces.md#workspaces-and-monorepos) |
| Private packages, tokens, mirrors | Env references only; never a token in git | [registries-and-auth.md](references/registries-and-auth.md) |
| Slow or flaky CI installs | Cache the download cache keyed on the lockfile | [caches-and-ci.md](references/caches-and-ci.md) |
| Windows, DDEV host-vs-container, Apple Silicon oddities | Install where the code runs; check `node -p process.arch` | [platform-gotchas.md](references/platform-gotchas.md) |
| `bower.json`, node-sass, Yarn 1, PHP 8.1 or older | Planned exit, one at a time | [legacy-exits.md](references/legacy-exits.md) |
| EINTEGRITY | Diagnose the artifact, the registry and the cache before touching the lockfile | [diagnostics.md](references/diagnostics.md#integrity-failures) |
| Lockfile merge conflict | Resolve the manifest's intent, then regenerate with the pinned manager; never hand-merge a lockfile | [diagnostics.md](references/diagnostics.md#lockfile-merge-conflicts) |
| "Works on my machine" | Compare manager and runtime pins, then the platform | [diagnostics.md](references/diagnostics.md#works-on-my-machine) |

## Hard rules

1. **One JS manager and one JS lockfile per package root, committed.** The lockfile is the
   contract; the manifest only says what an update may move to. A `composer.lock` beside
   it is normal, and committed too.
2. **Frozen installs everywhere but a dev machine.** CI and deploy run `npm ci`,
   `yarn install --immutable`, `pnpm install --frozen-lockfile` or `composer install`.
   Never `npm install` or `composer update` on a server; if a frozen install fails, the
   fix happens on a dev machine and is committed.
3. **Never switch managers by deleting the lockfile.** Import it (`pnpm import`, npm reading
   `yarn.lock`, Yarn 4 migrating a v1 lock) so resolved versions survive.
4. **Pin the runtimes and make every pin agree.** Node: `.nvmrc`, `engines.node` with
   `engine-strict=true` in `.npmrc` (pnpm: `engineStrict` in `pnpm-workspace.yaml`), DDEV
   `nodejs_version` (or `auto`). PHP: `require.php` (range),
   `config.platform.php` (production's exact version) and DDEV `php_version` (same
   major.minor). Production pins name supported releases.
5. **Run package managers where the code runs.** In a DDEV project that is
   `ddev composer ...` and `ddev npm ...`; never install `node_modules` from both the
   host and the container.
6. **No `npx` in package.json scripts; exact pins everywhere else.** In CI `npx` installs
   without asking. Never route a native CLI (rg, fd, sd, jq) through npx: its npm name
   is not its official channel.
7. **Credentials live in the environment.** Committed `.npmrc`/`.yarnrc.yml` hold
   `${NPM_TOKEN}` for npm and Yarn. pnpm 11.5.3+ ignores that placeholder in a project
   `.npmrc`, so a pnpm token goes in user config or the environment. Composer uses
   global `auth.json` or `COMPOSER_AUTH`. A committed token is revoked first, removed
   second.
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
and npm 12, pnpm 10+, Yarn 4.14+ and Bun (outside its built-in trusted list) all block
dependency install scripts by default.

## Audit a repo: pm-audit

A read-only scan of one repo root. It finds conflicting lockfiles, lockfiles that
disagree with their manifests, Node and PHP pins that are missing, disagree with each
other or with DDEV, or name end-of-life releases, unpinned `npx`/`dlx` use in scripts,
docs and CI, native CLIs routed through npx, Bower and node-sass, committed registry
credentials (reported by file and line, never by value), and `.npmrc` placeholders pnpm
ignores. From CI configs, Dockerfiles and appspec hook scripts it reports unfrozen
installs, Yarn flags on npm, unpinned global installs, deploys without `--no-dev`,
Composer 1, and credentials written into a Docker build context; it follows a CI build
into the subfolder it runs in. It lists nested package roots and flags them when they use
another manager, or when CI installs in one that has no lockfile.

Paths are relative to this skill's folder; in Claude Code use `${CLAUDE_SKILL_DIR}/scripts/...`.

```bash
bash scripts/run-python.sh scripts/pm-audit.py path/to/repo
bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[] | "\(.id)\t\(.file)"'
bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2027-01-01 path/to/repo
```

- Exit `0` clean, `10` findings, `2` usage, `3` path missing. Plain output is one TSV
  row per finding: severity, id, file, message, fix. Advisory notes go to stderr.
- `--as-of` moves the end-of-life line (PHP 8.2 dies on 2026-12-31: ask before you
  ship). `--no-docs` skips the npx walk of docs; package.json scripts and the CI and
  deploy checks still run.
- It audits root manifests; run it again on each nested root it lists. Every finding id, its meaning and its fix are in
  [diagnostics.md](references/diagnostics.md#pm-audit-finding-ids). DDEV's own
  `.ddev/` config is `ddev-ops`' auditor; pm-audit only checks that DDEV agrees.
- Sweeping many repos: read-only sparse clones, the branch that deploys, and the
  findings to check by hand are in [diagnostics.md](references/diagnostics.md#auditing-many-repos).
- `scripts/run-python.sh` picks the first real Python 3.8+ (`python3`, `python`, `py`),
  stepping over the Windows Store `python3` stub. The skill folder runs copied alone.

## Boundaries

| Concern | Owner |
|---|---|
| Dependency security: cooldowns, behavioural scans, IOCs, install-hook policy | `supply-chain-defense` |
| Vulnerability triage, `composer audit` and `npm audit` findings | `security-ops` |
| Configuring Mix, Webpack or Vite and migrating between them | `frontend-upgrade-ops` |
| JavaScript language and Node runtime patterns | `javascript-ops` |
| TypeScript and `tsconfig` | `typescript-ops` |
| Container images, multi-stage `npm ci` and `composer install` layers | `docker-ops` |
| DDEV itself: config keys and defaults, `.ddev/` audit, pulls, Mutagen, add-ons | `ddev-ops` |
| Craft CMS itself | `craftcms-ops` |
| CI pipeline design and action pinning | `ci-cd-ops` |

This skill covers running build scripts, not configuring bundlers, and day-to-day
dependency use, not deciding whether a package is safe.

## References

| File | Covers |
|---|---|
| [references/detect-and-choose.md](references/detect-and-choose.md) | lockfile to manager, two lockfiles, `packageManager`, Corepack, `devEngines`, switching managers |
| [references/install-semantics.md](references/install-semantics.md) | `npm ci` vs `install`, frozen installs, `composer install` vs `update`, autoloader levels, deploy patterns |
| [references/version-pinning.md](references/version-pinning.md) | Node and PHP release lines, every pin and who reads it, version managers, overrides, maintaining the facts |
| [references/npx-exec-safety.md](references/npx-exec-safety.md) | npx semantics, pinning rules, native CLIs, dlx/bunx/pnx, `composer exec`/`global` |
| [references/upgrades.md](references/upgrades.md) | outdated surveys, upgrade order, ERESOLVE and peer deps, `composer why-not php`, duplicate versions and dedupe, lockfile-only refresh |
| [references/scripts-and-workspaces.md](references/scripts-and-workspaces.md) | scripts and hooks, blocked install scripts, Composer scripts and plugins, workspaces, pnpm settings |
| [references/registries-and-auth.md](references/registries-and-auth.md) | `.npmrc`, `.yarnrc.yml`, `auth.json`, `COMPOSER_AUTH`, CI wiring, mirrors, leaked tokens |
| [references/caches-and-ci.md](references/caches-and-ci.md) | cache locations, CI cache keys, a GitHub Actions job, offline installs |
| [references/platform-gotchas.md](references/platform-gotchas.md) | Windows, DDEV host vs container, Apple Silicon, cross-platform lockfiles |
| [references/legacy-exits.md](references/legacy-exits.md) | Bower, node-sass, Yarn 1, lockfile v1, end-of-life Node and PHP |
| [references/diagnostics.md](references/diagnostics.md) | pm-audit ids, `npm ls`/`explain`, Composer diagnostics, ERESOLVE, EINTEGRITY, merge conflicts |
