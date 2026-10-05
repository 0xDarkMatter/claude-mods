# npx, dlx and exec: Running Packages Safely

`npx some-tool` is the shortest path from a README to arbitrary code on your machine. This
is the day-to-day discipline. Behavioural security (release-age cooldowns, Socket scans,
IOC checks, install hooks) belongs to `supply-chain-defense`: one owner per fact. Facts
verified 2026-10-05 against docs.npmjs.com (`npx`, `npm exec`, v11 and v12), the
libnpmexec source, yarnpkg.com, pnpm.io and bun.com.

## Contents

- [What npx actually does](#what-npx-actually-does)
- [The rules](#the-rules)
- [Never route a native CLI through npx](#never-route-a-native-cli-through-npx)
- [The other launchers](#the-other-launchers)
- [Composer: exec and global](#composer-exec-and-global)

## What npx actually does

Since npm 7, `npx` is `npm exec`:

1. A bin already in the project (`node_modules/.bin`) or installed globally is used
   first. A name without a version matches whatever the project has installed.
2. Otherwise the package is fetched into the npx cache and run. An unversioned name
   resolves to the newest published version at that moment.
3. Before fetching, npx prompts, **unless stdin is not a TTY or a CI environment is
   detected, in which case `--yes` is assumed**. In CI, `npx tool` installs and runs
   whatever `tool` is today, with only a log line.
4. `--no` refuses to fetch: the command fails if the package is not already local.
   `--no-install` is a deprecated spelling that npm converts to `--no`.

npm 12 also blocks dependency install scripts by default; `--allow-scripts` lets an
`npx` or `-g` install run them. See
[scripts-and-workspaces.md](scripts-and-workspaces.md#dependency-install-scripts-are-blocked-by-default).

## The rules

1. **No `npx` inside package.json scripts.** `npm run` already puts `node_modules/.bin`
   on `PATH`, so `"lint": "eslint ."` works once ESLint is a devDependency. `npx eslint`
   in a script either does nothing extra (local) or fetches an unpinned copy (not local).
2. **Tools a repo needs are devDependencies**, versioned by the lockfile, installed by
   `npm ci`. Run them with `npm exec eslint` or `npx --no eslint` outside scripts.
3. **One-off scaffolders get an exact version**: `npx create-vite@8.0.2 my-app`, never
   `npx create-vite` or `@latest`. Pin README instructions the same way; a README is a
   script that humans run.
4. **Check the name before the first run.** Typosquats live one character away from
   popular names. Confirm the exact package on npmjs.com (publisher, repository link,
   weekly downloads) and prefer an official scoped name where one exists.
5. **Global installs are pinned too**: `npm install -g corepack@0.36.0`, not
   `npm install -g corepack`.

pm-audit flags `npx.unpinned` in package.json scripts, and in the code of docs, CI, git
hooks and shell files. It skips exact `pkg@x.y.z` pins, packages the repo already
declares, and docs that show the repo's own published package. It does not walk
dot-directories other than CI, hook and DDEV ones (`.github`, `.husky`, `.ddev` and
similar), because vendored agent-config copies would repeat one finding many times.

## Never route a native CLI through npx

ripgrep, fd, sd, jq, bat, fzf, delta and their kind are native binaries distributed
through winget, Homebrew, apt, cargo or GitHub releases. Their npm names are not their
official channel: `npx rg` or `npx sd` runs whatever package owns that npm name, which may
be unrelated, abandoned or a squatter waiting for exactly this mistake. Install the tool
from its own channel and call it directly. pm-audit reports these as `npx.native-cli`
(severity error); the name list lives in `assets/package-manager-facts.json`.

## The other launchers

| Launcher | Runs | Pin with | Local only? |
|---|---|---|---|
| `npx`, `npm exec` | local bin, else fetches | `pkg@1.2.3` | `npx --no pkg` |
| `yarn dlx` (Yarn 4) | always a temporary environment | `yarn dlx pkg@1.2.3`, or `-p pkg@1.2.3` for extra packages | use `yarn exec` / `yarn run` |
| `pnpm dlx`, `pnpx`, `pnx` (pnpm 11+ alias) | fetches into a temporary store | `pnx pkg@1.2.3` | use `pnpm exec` |
| `bunx`, `bun x` | local bin, else fetches | `bunx pkg@1.2.3` | - |
| Yarn 1 | no dlx; uses `npx` | - | `yarn run` |

pnpm 11+ applies its `minimumReleaseAge` setting (default one day) to `pnx` as well as to
installs; that setting is a supply-chain control, so its policy lives in
`supply-chain-defense`.

## Composer: exec and global

- `composer exec <bin>` runs a binary from the project's `vendor/bin` with Composer's bin
  directory on `PATH`. It never fetches anything, which makes it the PHP analogue of
  `npx --no`.
- `composer global require vendor/tool` installs into `COMPOSER_HOME` for the whole user,
  outside any lockfile. Prefer `require-dev` in the project so the version is locked and
  every developer and CI run gets the same one. When a global tool is unavoidable, pin it:
  `composer global require "vendor/tool:1.2.3"`.
- Composer has no `dlx`; `composer create-project vendor/skeleton dir 1.2.*` is the
  scaffolding equivalent, and the version argument is the pin.
