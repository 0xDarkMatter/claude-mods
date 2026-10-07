# Diagnostics: Reading the Tools and the Audit

What each pm-audit finding means, how to read `npm ls`, `npm explain` and
`composer why`, the anatomy of ERESOLVE and integrity failures, lockfile merge
conflicts, and the "works on my machine" checklist. Facts verified 2026-10-05 against
docs.npmjs.com (v12), getcomposer.org (checked against 2.10.3) and the Composer CHANGELOG;
the pnpm placeholder row 2026-10-06 against pnpm.io (`npmrc`) and the pnpm 11.5.3 and
10.34.2 releases; the CI-runner and ERESOLVE notes 2026-10-06 against docs.github.com
(hosted runners) and the npm/cli source (`explain-eresolve.js`).

## Contents

- [pm-audit finding ids](#pm-audit-finding-ids)
- [Auditing many repos](#auditing-many-repos)
- [npm ls, explain and query](#npm-ls-explain-and-query)
- [Composer diagnostics](#composer-diagnostics)
- [ERESOLVE](#eresolve)
- [Integrity failures](#integrity-failures)
- [Lockfile merge conflicts](#lockfile-merge-conflicts)
- [Works on my machine](#works-on-my-machine)

## pm-audit finding ids

`bash scripts/run-python.sh scripts/pm-audit.py <repo>` exits 10 when it reports any of
these, 0 when clean. Notes on stderr (for example `js.packagemanager.unset`,
`js.yarn.classic`, `js.engines.unenforced`, `js.nested.roots`) are advice and never
change the exit code. pm-audit audits the root manifests; `js.nested.roots` lists nested
package roots that carry their own lockfile, so run it again on each of those.

It also reads CI configs (`.github/workflows/`, `.gitlab-ci.yml`, `bitbucket-pipelines.yml`,
`buildspec*.yml` and similar), Dockerfiles and AWS CodeDeploy `appspec.yml` hook scripts. In
YAML only command keys (`run:`, `script:`, `commands:`) count, so a command quoted in a
release body is not read as one. Commands are read as the shell gets them: quoted and
folded (`>-`) YAML scalars, backslash continuations (in Dockerfile `RUN` too) and a
Jenkinsfile's `sh` strings. An install counts only as the command word, so
`echo "npm install"` is text. Lockfile-only refreshes (`--package-lock-only`,
`--lockfile-only`, `composer update --lock`) are maintenance and pass. Each CI install is
placed in the package root it runs in: a literal `working-directory:` (the step's, else
the job's `defaults.run`), `${{ env.X }}` from the workflow or job `env:`, `cd` within
one command block, and the tool's own `--prefix` / `--dir` / `--cwd` / `--working-dir`.
A matrix path or any other expression leaves it unplaced. A workspace member (npm or Yarn
`workspaces`, `pnpm-workspace.yaml`) installs from its workspace root's lockfile. A
literal `node-version` given to actions/setup-node and `php-version` given to
shivammathur/setup-php count as pins for the agreement and end-of-life checks.
Local composite actions under `.github/actions/` and local reusable workflows under
`.github/workflows/` are read recursively at the calling job's scope. Remote actions are
never fetched. A missing local target marks the deploy check skipped with its path rather
than allowing an incomplete scan to read as a pass.
Package scripts, Composer scripts, DDEV hooks/commands, Just recipes and Make recipes are
local tooling: a developer is meant to run `npm install` or `composer update` there, so
only the rules that hold everywhere apply - an unpinned global install
(`deploy.global.unpinned`, at the script's own file line), the Composer installer check and
the npx findings. The frozen-install, `--no-dev` and ad-hoc Composer rules stay CI and
deploy rules. A repo with local tooling but no CI or deploy file still reports the deploy
check skipped, so a clean result there is never read as "CI is fine".

Frozen installs are required in every CI job, whether it ships or not: the managers
document the frozen install for CI as a whole, and a front-end job whose build a deploy job
downloads ships its install without any deploy marker of its own. `--no-dev` is required
only where `vendor/` ships; `--update-no-dev` and a literal `COMPOSER_NO_DEV=1` at the
workflow, job or step scope (or an earlier Dockerfile `ENV`) satisfy the same rule:

- a Dockerfile or an appspec hook script, always;
- a GitHub Actions **job** that ships something (`docker push`, `aws deploy`, an `aws s3 cp`
  upload, `rsync`, `ansible-playbook`, ...) and runs no tests. On GitHub-hosted runners
  each job starts on a fresh machine (self-hosted runners can keep state) and shares files
  only through artifacts (or a cache key it restores), so a lint or test job beside the
  deploy job may install dev packages. A job that hands `vendor/` to the deploy job as an
  artifact is not followed;
- any other CI file judged **as a whole**, with the same rule. In GitLab CI and Bitbucket
  Pipelines a later job downloads every earlier artifact by default, and jobs inherit
  commands through `extends:`, `default:` and anchors, so one job's block is not the
  whole story.

| Id | Severity | Means | Fix in |
|---|---|---|---|
| `js.lockfile.conflict` | error | two or more JS lockfiles at the root; when CI installs at the root with one manager, it names the live lockfile and the unused one | [detect-and-choose.md](detect-and-choose.md#two-lockfiles-pick-one) |
| `js.lockfile.missing` | warn | dependencies but no lockfile (only a note when CI installs nothing at the root, just nested roots that have a lockfile) | [install-semantics.md](install-semantics.md#the-one-table) |
| `js.lockfile.stale` | warn | lockfile disagrees with package.json; a frozen install fails | [install-semantics.md](install-semantics.md#why-a-lockfile-changes-under-you) |
| `js.lockfile.v1` | warn | npm 6-era lockfile | [legacy-exits.md](legacy-exits.md#npm-lockfileversion-1) |
| `js.lockfile.shrinkwrap` | warn | only `npm-shrinkwrap.json`, which npm 12 ignores | [detect-and-choose.md](detect-and-choose.md#lockfile-to-manager) |
| `js.lockfile.source` | warn | a package-lock (v1 tree or v2/v3 `packages`) or Yarn 1 resolved URL uses HTTP, a registry tarball (`/<name>/-/...`) names another package (an npm alias is compared by its target), or an artifact has SHA-1/missing integrity; Yarn 2+ and pnpm locks are checked for HTTP sources only. Shape only: behavioural trust belongs to supply-chain-defense, git tarballs to `js.dep.non-registry` | [registries-and-auth.md](registries-and-auth.md) |
| `js.pnpm.field-ignored` | warn | a `pnpm` field pnpm 11+ no longer reads | [scripts-and-workspaces.md](scripts-and-workspaces.md#pnpm-settings-moved-to-pnpm-workspaceyaml) |
| `js.install-policy` | warn | pnpm enables `dangerouslyAllowAllBuilds`, bypassing every per-package build-script decision; the JSON metadata separately records which install-policy controls are explicitly set | [scripts-and-workspaces.md](scripts-and-workspaces.md#dependency-install-scripts-are-blocked-by-default) |
| `js.dep.non-registry` | warn | package.json points a dependency at git/GitHub, a local file/link, or a direct HTTP(S) tarball rather than the configured registry | [registries-and-auth.md](registries-and-auth.md) |
| `js.dep.paired-drift` | warn | Vue 2 and vue-template-compiler differ at all (Vue 3 and @vue/compiler-sfc by major.minor); a locked @vitejs/* or @tailwindcss/* package's own `peerDependencies` range rejects the locked vite or tailwindcss (majors alone prove nothing: those plugins version on their own); or one direct dependency's MAJOR differs between nested package roots | [upgrades.md](upgrades.md#duplicate-versions) |
| `js.engine.floor` | warn | a literal Node pin (.nvmrc, .node-version, setup-node) can select no version that a package's `engines.node` in package-lock v2/v3 accepts. A partial pin (`20`) means its newest release, a full one (`20.11.1`) only itself. No literal pin: `runtime.floors` is skipped | [version-pinning.md](version-pinning.md#the-recommended-node-pin-set) |
| `js.root.not-private` | warn | a root package with dependencies is not private and has no conservative publication signal (`files`, `publishConfig`, exports/main, scoped name, or a non-default version) | [detect-and-choose.md](detect-and-choose.md) |
| `js.packagemanager.mismatch` | error | `packageManager` names a manager (or Yarn flavour) the lockfile is not from | [detect-and-choose.md](detect-and-choose.md#declaring-the-manager-packagemanager-corepack-devengines) |
| `js.manifest.invalid` | error | package.json is not valid JSON, or not a JSON object | - |
| `js.node.unpinned` | warn | nothing pins Node | [version-pinning.md](version-pinning.md#the-recommended-node-pin-set) |
| `js.node.eol` | warn | a Node the repo pins (or the only one it admits) is end of life; the server's own Node is not in the repo, so confirm it. DDEV's `nodejs_version` alone never raises it: that is `ddev-ops`' finding | [legacy-exits.md](legacy-exits.md#end-of-life-node) |
| `js.node.eol-soon` | warn | a pinned Node major reaches end of life within the facts catalogue's `eol_soon_days` window | [version-pinning.md](version-pinning.md) |
| `node.pin.disagree` | warn | `.nvmrc`, `engines`, `devEngines`, DDEV, CI's setup-node and friends name different majors | [version-pinning.md](version-pinning.md#what-reads-which-node-pin) |
| `ddev.node.unpinned` | warn | DDEV has no `nodejs_version`, so it follows DDEV's default | [version-pinning.md](version-pinning.md#the-recommended-node-pin-set); values in `ddev-ops` |
| `php.manifest.invalid` | error | composer.json is not valid JSON, or not a JSON object | `composer validate` |
| `php.require.missing` | warn | no `require.php` in a library, or in a project without `config.platform.php` (with the platform pin it is only a note) | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.platform.unset` | warn | no `config.platform.php` in a project | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.pin.disagree` | warn | DDEV `php_version`, `config.platform.php`, the lock's platform override, CI's setup-php and `require.php` disagree (`require.php` read as Composer reads it: `>8.2` admits 8.2.1, `!=` excludes one version) | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `php.eol` | warn | a PHP the repo pins (or the only one it admits) is past security support; confirm the server's own PHP. DDEV's `php_version` alone never raises it: that is `ddev-ops`' finding | [legacy-exits.md](legacy-exits.md#end-of-life-php) |
| `php.eol-soon` | warn | a pinned PHP major.minor reaches the end of security support within the facts catalogue's `eol_soon_days` window | [version-pinning.md](version-pinning.md) |
| `php.lockfile.missing` | warn | a project with packages but no `composer.lock` | [install-semantics.md](install-semantics.md#composer-install-versus-composer-update) |
| `php.lockfile.stale` | warn | `composer.json` requires packages the lock lacks, judged as Composer does: a locked package's `replace` or `provide` meets a requirement, and `require` is met only from `packages` | [install-semantics.md](install-semantics.md#composer-install-versus-composer-update) |
| `php.composer.safety-off` | warn | composer.json disables transport, plugin or advisory/malware/abandoned-package safeguards (`allow-plugins: true`, insecure HTTP/TLS, or an audit block switched off) | [scripts-and-workspaces.md](scripts-and-workspaces.md#composer-scripts-and-plugins) |
| `php.composer.eol` | warn | setup-php `tools: composer:v2.x` or a `composer:2.x` image runs a minor line past support (a supported line below the security/malware blocking floors is a note). composer.lock's `plugin-api-version` is never read: it names the plugin API, not the Composer line, and only the lock's last writer | [legacy-exits.md](legacy-exits.md#composer-1-to-composer-2) |
| `php.craft.eol` | warn | composer.lock contains a Craft CMS major past the catalogue's critical-security support date | [version-pinning.md](version-pinning.md) |
| `php.package.abandoned` | warn | composer.lock marks a package abandoned; when its metadata names a replacement, the finding names it too | [upgrades.md](upgrades.md) |
| `php.dep.non-registry` | warn | composer.json uses a VCS/path/artifact repository, a `dev-*` or `*` constraint, or `minimum-stability: dev` without `prefer-stable: true` | [registries-and-auth.md](registries-and-auth.md) |
| `php.lock.floor` | warn | a production package in composer.lock requires a PHP that config.platform.php (exact), a production PHP image tag (not `Dockerfile.dev`/`.test`) or a literal setup-php pin cannot provide | [version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means) |
| `npx.unpinned` | warn | `npx`/`dlx`/`bunx` of an unpinned, undeclared package (every `-p` counts; a bin a declared package provides, like `tsc`, is local), or of a declared one at a dist-tag or a range its installed version misses. `--no`/`--no-install` never fetch, so never fire | [npx-exec-safety.md](npx-exec-safety.md#the-rules) |
| `npx.native-cli` | error | a native CLI (rg, fd, sd, jq...) through npx, or a global npm install of one in CI | [npx-exec-safety.md](npx-exec-safety.md#never-route-a-native-cli-through-npx) |
| `legacy.bower` | warn | `bower.json` or `.bowerrc` | [legacy-exits.md](legacy-exits.md#bower-to-npm) |
| `legacy.node-sass` | warn | node-sass in package.json | [legacy-exits.md](legacy-exits.md#node-sass-to-dart-sass) |
| `legacy.package` | warn | a dependency matches the facts catalogue's versioned legacy-package table (initially Laravel Mix, Vue 2/compiler, webpack 4, request and PhantomJS) | [legacy-exits.md](legacy-exits.md) |
| `registry.token.committed` | error | a literal, non-empty token in `.npmrc` or `.yarnrc.yml` | [registries-and-auth.md](registries-and-auth.md#when-a-token-was-committed) |
| `registry.authjson.committed` | error | a root `auth.json` that git tracks, or that is not ignored (git decides; without git, the root `.gitignore` by git's rules: `**/`, `!`, last match wins) | [registries-and-auth.md](registries-and-auth.md#when-a-token-was-committed) |
| `registry.credentials.image` | error | CI writes `auth.json` or `.npmrc` inside the context of a later `docker build` in the same job, its Dockerfile copies the whole context (not `COPY --from`), and `.dockerignore` (root-anchored, last match wins) lets it through | [registries-and-auth.md](registries-and-auth.md#ci-wiring) |
| `registry.pnpm.placeholder-ignored` | warn | a pnpm repo's project `.npmrc` has a `${...}` in a registry, proxy or auth setting, which pnpm 11.5.3+ (and 10.34.2+) ignores with only a warning | [registries-and-auth.md](registries-and-auth.md#pnpm-no-placeholders-in-the-project-npmrc) |
| `js.manager.mixed` | warn | nested package roots use a different manager than the root | [detect-and-choose.md](detect-and-choose.md#two-lockfiles-pick-one) |
| `deploy.install.unfrozen` | warn | CI or a deploy runs `npm install`, a non-frozen Yarn/pnpm/Bun install (Yarn 2+ counts as frozen on CI unless `.yarnrc.yml` sets `enableImmutableInstalls: false`), or `composer update`/`require`; names the nested root it runs in | [install-semantics.md](install-semantics.md#the-one-table) |
| `deploy.install.unlocked` | warn | CI installs in a nested folder that has a `package.json` or `composer.json` but no lockfile, and no workspace root's lockfile covers it, so every run resolves fresh | [install-semantics.md](install-semantics.md#the-one-table) |
| `deploy.npm.yarn-flag` | error | a Yarn flag (`--frozen-lockfile`, `--immutable`) on `npm ci` or `npm install`: npm 12 refuses the command | [install-semantics.md](install-semantics.md#npm-ci-versus-npm-install) |
| `deploy.global.unpinned` | warn | `npm install -g <pkg>` without an exact version in CI, a deploy, or local tooling (package/Composer scripts, Just/Make recipes, DDEV hooks) | [npx-exec-safety.md](npx-exec-safety.md#the-rules) |
| `deploy.composer.dev` | warn | `composer install` without `--no-dev`, `--update-no-dev` or an applicable `COMPOSER_NO_DEV=1` where `vendor/` ships: a Dockerfile, an appspec hook, a shipping GitHub Actions job, or another CI file that ships | [install-semantics.md](install-semantics.md#deploy-patterns) |
| `deploy.composer.safety-off` | warn | a shipping Composer command disables advisory/malware blocking, audit, or all platform requirements through a flag or environment setting | [install-semantics.md](install-semantics.md#deploy-patterns) |
| `deploy.composer.adhoc` | warn | CI or deploy runs `composer require`, `composer global require` or `composer update` instead of installing the committed lock | [install-semantics.md](install-semantics.md#composer-install-versus-composer-update) |
| `deploy.composer.installer-unverified` | warn | the Composer installer is fetched and piped to PHP without downloading `installer.sig` and checking its SHA-384 hash first | [registries-and-auth.md](registries-and-auth.md) |
| `deploy.bundle.credentials` | error | CI writes auth.json or a token-bearing .npmrc inside a later zip/CodeDeploy source and the bundle excludes do not remove it | [registries-and-auth.md](registries-and-auth.md#ci-wiring) |
| `php.composer.v1` | warn | CI or a Dockerfile uses Composer 1, end of life since 2026-05-30 | [legacy-exits.md](legacy-exits.md#composer-1-to-composer-2) |

The end-of-life checks read dated tables from `assets/package-manager-facts.json`; pass
`--as-of YYYY-MM-DD` to ask "is this still supported on the day we ship?".

DDEV's own configuration (an unpinned `php_version` or database, values DDEV no longer
ships, committed Mutagen or router ports) is audited by `ddev-ops`'
`audit-ddev-config.py`. pm-audit reads DDEV's PHP and Node only to check that they agree
with the repo's other pins. An end-of-life DDEV pin is `ddev-ops`' finding: `php.eol` and
`js.node.eol` list the repo's own end-of-life pins and only point at DDEV's, so the two
audits never report the same fact.

## Auditing many repos

pm-audit only reads files, so a sweep needs pm-audit's inputs, not a working build. Clone
each repo shallow, without blobs and without a checkout, then write only those inputs:

```bash
git clone --depth 1 --filter=blob:none --no-checkout --config core.longpaths=true <url> <dir>
git -C <dir> sparse-checkout set --no-cone --stdin < pm-audit-inputs.txt
git -C <dir> read-tree -mu HEAD
bash scripts/run-python.sh scripts/pm-audit.py --json <dir>
```

`pm-audit-inputs.txt`, one pattern per line: every root file but no root folder, the CI
and hook folders, manifests and lockfiles at any depth, shell scripts (appspec hooks live
anywhere) and the main files the npx scan reads (with `--no-docs`, drop the last three):

```text
/*
!/*/
/.github/
/.gitlab/
/.circleci/
/.ddev/
/.husky/
**/package.json
**/composer.json
**/composer.lock
**/package-lock.json
**/npm-shrinkwrap.json
**/yarn.lock
**/pnpm-lock.yaml
**/bun.lock
**/bun.lockb
**/deno.lock
**/*.sh
**/*.md
**/*.yml
**/*.yaml
```

`sparse-checkout set` writes nothing into a `--no-checkout` clone. `read-tree -mu HEAD`
fills the index from HEAD and writes only the sparse paths, fetching just those blobs. Use
it rather than `git checkout <branch>`, which prints "Already on" because HEAD is already
there, so its output does not show whether it wrote anything. (On git 2.49 it does write
the sparse paths.)

- **Windows**: `core.longpaths=true` covers deep CMS project-config paths. Git writes its
  pack files read-only, and Python's `shutil.rmtree` stops on them with `PermissionError`
  unless its error handler makes the file writable and retries
  (`os.chmod(path, stat.S_IWRITE)`).
- **Audit the branch that deploys.** The default branch may not be what ships. Read
  `on.push.branches` in the deploy workflow (or the GitLab/Bitbucket branch rules) and
  clone that branch with `--branch <name>`. In one sweep a default branch was about 500
  commits behind the deploy branch, and a finding there was already fixed where it shipped.
- **Verify before reporting.** Open the file behind each finding before it goes in a
  report. Shapes known to mislead: a test or lint job beside the deploy job (GitHub Actions
  jobs are judged apart, other CI files whole); a package met by another package's
  `replace` or `provide`; a build in a nested folder (pm-audit follows only the literal
  forms above); and a stale default branch.

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
matter: *while resolving* (the package npm was placing, often your project or a
workspace), *found* (what you have), *could not resolve dependency* (the conflicting peer
range and the package declaring it). The fix is a compatible version, not a flag;
[upgrades.md](upgrades.md#peer-dependency-conflicts-eresolve) walks through it.

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

Never hand-merge a lockfile. The pattern that works for every manager is the one
Composer documents ("Resolving merge conflicts" on getcomposer.org): accept one branch's
lockfile, then re-apply the other branch's change with the command it used.

1. Resolve the manifest (`package.json` or `composer.json`) by hand.
2. Take the lockfile from the branch with the most dependency changes:
   `git checkout --theirs package-lock.json` (or `--ours`).
3. Re-run the other branch's commands: `npm install vite@^8`,
   `composer require vendor/pkg:^2`, `composer update vendor/pkg`.
4. Check before committing: `npm ci` (or `composer validate` and
   `composer install --dry-run`).

The re-run may pick a newer version than the other branch had locked; review the lock
diff. When only Composer's `content-hash` conflicts, `composer update --lock` is enough.
npm 6's docs described `npm install` repairing a conflicted `package-lock.json`
automatically; current npm docs no longer document that, so don't rely on it.

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
