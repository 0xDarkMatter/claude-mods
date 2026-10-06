# Platform Gotchas: Windows, DDEV and macOS on Apple Silicon

The same lockfile behaves differently on a Windows laptop, inside a DDEV container and on
an Apple Silicon Mac. These are the failures that look like dependency bugs and are not.
Facts verified 2026-10-06 against docs.npmjs.com, the npm/cli issue tracker, docs.ddev.com
(stable, v1.25.4), the Composer docs (2.10.3) and the nvm-windows and fnm repositories.

## Contents

- [Windows](#windows)
- [DDEV: host or container](#ddev-host-or-container)
- [macOS on Apple Silicon](#macos-on-apple-silicon)
- [Native binaries and the cross-platform lockfile](#native-binaries-and-the-cross-platform-lockfile)

## Windows

**PowerShell refuses `npm` or `npx`.** "npx.ps1 cannot be loaded because running scripts
is disabled on this system" comes from PowerShell's execution policy blocking the `.ps1`
shim npm installs next to its `.cmd` shim. Two ways out:

- call the `.cmd` shim explicitly: `npx.cmd`, `npm.cmd`;
- or let the user decide to relax the policy for their own account
  (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`). That is a machine security
  setting: suggest it, never change it on someone's behalf.

**Line endings in lockfiles.** With `core.autocrlf=true`, git checks lockfiles out with
CRLF; the next install writes LF (or the reverse), and the diff shows every line changed.
Pin the lockfiles once in `.gitattributes` (a repo-wide `* text=auto eol=lf` also works,
but check it against any `.bat`/`.cmd` files first):

```gitattributes
package-lock.json text eol=lf
yarn.lock         text eol=lf
pnpm-lock.yaml    text eol=lf
composer.lock     text eol=lf
```

After adding it, renormalise once (`git add --renormalize .`) in its own commit.

**Long paths.** Deep `node_modules` trees can exceed Windows' legacy 260-character path
limit, which breaks git operations and some tools. `git config core.longpaths true`
fixes git; enabling long paths system-wide is an administrator registry setting the user
decides on. Keeping repos near the drive root (`C:\code\site`) avoids most of it.

**Node version managers.** nvm-windows v1 switches one global Node for every terminal and
ignores `.nvmrc` (`nvm use` needs the version typed). The project moved to the
`nvm-windows/nvm` repository; v2 is a rewrite that detects `.nvmrc` and `.node-version`
in shim mode. fnm also works natively: add
`fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression` to the end of
the PowerShell profile and it switches per directory.

**Git Bash and quoting.** Arguments after `--` reach the script differently in
PowerShell, cmd and Git Bash. When a `npm run x -- --flag=value` works in one shell and
not another, put the flags into the script itself.

## DDEV: host or container

DDEV runs PHP and Node in its web container, with the versions from `.ddev/config.yaml`.
The host can have entirely different ones.

- **Run package managers where the code runs**: `ddev composer install`, `ddev npm ci`,
  `ddev npm run build`, `ddev exec <cmd>`. Composer in the container resolves against the
  container's PHP and extensions. The PHP matches production when `php_version` does; the
  extensions match only if the DDEV image and production load the same ones.
- **Composer on the host** with a different PHP resolves for the host PHP unless
  `config.platform.php` is set. Set it ([version-pinning.md](version-pinning.md#the-three-php-pins-and-what-each-means)),
  and the host resolves for production's PHP. Extensions are still the host's: pin or
  hide any that differ in `config.platform` (`"ext-foo": "1.2.3"`, `"ext-foo": false`),
  and run `composer check-platform-reqs` against production.
- **Never install `node_modules` from both sides.** The project directory is shared with
  the container. A host install on macOS or Windows writes that OS's native binaries
  (esbuild, rollup, sass-embedded); the Linux container then fails with a missing or
  wrong binary, and vice versa. Pick one side per repo (the container, if the dev server
  runs there) and delete `node_modules` when switching.
- **Make DDEV's pins agree with the repo's**: `nodejs_version: auto` reads `.nvmrc`, so
  one file pins Node everywhere; `php_version` matches `config.platform.php`
  ([version-pinning.md](version-pinning.md#the-recommended-node-pin-set)).

DDEV itself (what `nodejs_version` and `php_version` accept, defaults that move between
DDEV releases, `corepack_enable`, rebuilding after a change, Mutagen and `upload_dirs`
for `node_modules`) is `ddev-ops`. Vite dev-server wiring inside DDEV is
`frontend-upgrade-ops`; Craft specifics are `craftcms-ops`.

## macOS on Apple Silicon

- **Check the architecture first**: `node -p process.arch` prints `arm64` or `x64`. A
  terminal running under Rosetta, or an x64 Node from an old installer, installs x64
  binaries that later fail under arm64 (or run slowly through translation).
- **Fix**: install an arm64 Node through nvm or fnm, delete `node_modules`, reinstall.
- **node-gyp builds** (packages without prebuilt binaries) need the Xcode Command Line
  Tools (`xcode-select --install`) and a Python 3.

## Native binaries and the cross-platform lockfile

Tools like esbuild, rollup, sass-embedded and sharp ship one npm package per
OS and CPU, listed as optional dependencies, and install only the one matching the
machine. The lockfile must still list all of them, or a Linux CI or a DDEV container
installs nothing and fails with "Cannot find module @rollup/rollup-linux-x64-gnu".

npm before 11.3.0 could drop other platforms' optional entries when the lock was rewritten
on a machine with an existing `node_modules` (npm/cli#4828, fixed in npm 11.3.0,
2025-04-08). A lockfile last written by an older npm may still lack them. The fix, once,
on a current npm:

```bash
rm -rf node_modules package-lock.json
npm install
git diff --stat package-lock.json   # review: versions should only move within ranges
```

Deleting the lock lets every dependency move within its range, so run the full build and
tests before committing, and do it in its own commit.
