# Private Registries, Auth and Mirrors

Pointing npm, Yarn, pnpm and Composer at private packages and mirrors without a credential
ever reaching git. Facts verified 2026-10-06 against docs.npmjs.com (`npmrc` and
`config`, v12) and the npm/cli source, yarnpkg.com (`.yarnrc.yml`) and the Yarn source,
pnpm.io (`npmrc`, settings) with the pnpm 11.0 and 11.5.3 release notes, the
actions/setup-node README, and getcomposer.org (authentication and repositories
articles, checked against 2.10.3).

## Contents

- [The rule](#the-rule)
- [npm: .npmrc](#npm-npmrc)
- [pnpm: no placeholders in the project .npmrc](#pnpm-no-placeholders-in-the-project-npmrc)
- [Yarn 4: .yarnrc.yml](#yarn-4-yarnrcyml)
- [Composer: auth.json, COMPOSER_AUTH and repositories](#composer-authjson-composer_auth-and-repositories)
- [CI wiring](#ci-wiring)
- [Mirrors and proxies](#mirrors-and-proxies)
- [When a token was committed](#when-a-token-was-committed)

## The rule

The **project** file says *where* packages come from and *which variable* holds the
credential. The credential itself lives in the environment, the user-level config, or the
CI secret store. Committed npm and Yarn config contains `${NPM_TOKEN}`, never a token;
pnpm ignores even the placeholder, so a pnpm repo commits no auth line at all. pm-audit
reports a literal token as `registry.token.committed` (by file and line; it never prints
the value) and a committed `auth.json` as `registry.authjson.committed`.

## npm: .npmrc

```ini
# .npmrc (committed; read by npm and Yarn 1, not usable this way by pnpm)
@acme:registry=https://npm.example.com/
//npm.example.com/:_authToken=${NPM_TOKEN}
engine-strict=true
```

- A scope (`@acme`) maps to one registry; everything unscoped still comes from the
  default registry.
- Auth keys must be scoped to a registry URL (`//host/path/:_authToken=`). npm refuses
  unscoped auth settings.
- `${VAR}` is expanded from the environment. If the variable is unset, npm leaves the
  text as is and sends it as the token. `${VAR?}` turns a missing variable into an empty
  string, not an error. Neither fails loudly, so check the variable in CI before the
  install (`test -n "$NPM_TOKEN"`).
- The real token goes in the user's `~/.npmrc` (written by `npm login --registry` or
  `npm config set //npm.example.com/:_authToken <token>`), or in the environment.
- `engine-strict=true` here is npm-only. pnpm 11+ reads no such setting from `.npmrc`; it
  wants `engineStrict: true` in `pnpm-workspace.yaml`.

## pnpm: no placeholders in the project .npmrc

pnpm reads `.npmrc` for registry and auth settings. Network settings (`httpProxy`,
`httpsProxy`, `noProxy`, `localAddress`, `strictSsl`, `gitShallowHosts`) are still read
there to ease migration; everything else goes in `pnpm-workspace.yaml` or the global
`~/.config/pnpm/config.yaml`.

Since pnpm 11.5.3 (2026-06-10, backported to 10.34.2), a `${...}` in the project `.npmrc`
is ignored, with only a warning, in these positions: `registry`, `@scope:registry`, proxy
URLs, any `//host/...` key, `_authToken`, `_auth`, `_password`, `username`,
`tokenHelper`, `cert` and `key`. Registry URLs in `pnpm-workspace.yaml` are covered too.
It is a security fix (GHSA-3qhv-2rgh-x77r): a cloned repo could otherwise send your CI
token to a registry of its choosing. So the committed auth line above works for npm
only; under pnpm, auth silently fails. pm-audit reports it as
`registry.pnpm.placeholder-ignored`.

Put the token where pnpm still expands it:

- `pnpm config set //npm.example.com/:_authToken "$NPM_TOKEN"`, which writes the
  user-level config, never the repo;
- the user's `~/.npmrc`, where `${NPM_TOKEN}` still expands;
- the environment: `pnpm_config_//npm.example.com/:_authToken` (11.6+), or
  `pnpm_config__auth` as JSON (11.10+);
- in GitHub Actions, setup-node's `registry-url`, which writes a user-level `.npmrc`.

A registry URL that is not secret can be written literally in the project `.npmrc`.
`PNPM_CONFIG_NPMRC_AUTH_FILE=.npmrc` declares the project file trusted again; set it only
in CI that never runs untrusted pull requests.

## Yarn 4: .yarnrc.yml

Yarn 4 ignores `.npmrc`. The equivalent:

```yaml
# .yarnrc.yml (committed)
npmScopes:
  acme:
    npmRegistryServer: "https://npm.example.com/"
    npmAuthToken: "${NPM_TOKEN}"
```

`${NAME}` throws when the variable is unset (good: fails loudly); `${NAME:-fallback}` and
`${NAME-fallback}` supply a default. Yarn 1 reads `.npmrc` and `.yarnrc`.

## Composer: auth.json, COMPOSER_AUTH and repositories

Credentials, in the order you should reach for them:

1. **Global `auth.json`** in `COMPOSER_HOME` (find it with `composer config --global home`),
   written by:

   ```bash
   composer config --global http-basic.repo.example.com <username> <token>
   composer config --global bearer.repo.example.com <token>
   ```

2. **`COMPOSER_AUTH`** environment variable, a JSON object with the same shape as
   `auth.json`, for CI. Since 2.8.x it takes precedence over a project `auth.json`.
3. **Project `auth.json`**: allowed, and must be in `.gitignore` (pm-audit checks).
4. **`composer.json`**: possible, never right.

Where packages come from (`repositories` in `composer.json`, in priority order):

| Type | Use |
|---|---|
| `composer` | a Composer repository: Private Packagist, Satis, a mirror |
| `vcs` | a git repository with a `composer.json` |
| `path` | a local directory (monorepos, plugin development) |
| `package` | an inline package definition for something with no `composer.json` |
| `artifact` | a directory of zip files |

Since Composer 2.9, `repositories` is preferably a list whose entries carry a `name`, and
`composer repository` manages it from the CLI. To use only your own repositories, disable
Packagist with `{"packagist.org": false}` in that list, or globally with
`composer config -g repo.packagist.org false`.

## CI wiring

GitHub Actions with npm:

```yaml
- uses: actions/setup-node@v7
  with:
    node-version-file: .nvmrc
    registry-url: https://npm.example.com/
- run: npm ci
  env:
    NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

`setup-node` writes a temporary user-level `.npmrc` that reads `NODE_AUTH_TOKEN`, so it
works for pnpm too (`pnpm install --frozen-lockfile` in place of `npm ci`). For Composer, set
`COMPOSER_AUTH` from a secret on the install step:

```yaml
- run: composer install --no-interaction --no-dev --optimize-autoloader
  env:
    COMPOSER_AUTH: ${{ secrets.COMPOSER_AUTH_JSON }}
```

Never `echo` a token to "debug" it, and never write one into a file that a later step
uploads as an artefact.

**The Docker build context is an artefact too.** A step that writes `auth.json` or a
token-bearing `.npmrc` into the workspace, followed by `docker build .` with a Dockerfile
that does `ADD .` or `COPY . .`, bakes the credential into an image layer, and every
image pushed since carries it. pm-audit reports this as `registry.credentials.image`.
Pass `COMPOSER_AUTH` or `NODE_AUTH_TOKEN` as step environment instead of writing a file;
if a file is unavoidable, list it in `.dockerignore` (and in `.gitignore`). If images
already shipped with it, rotate the credential: deleting it from the next image does not
remove it from the old layers.

## Mirrors and proxies

- npm, pnpm and Yarn 1: `registry=https://proxy.example.com/` in the project `.npmrc`
  sends every unscoped package through the mirror. Yarn 4 uses `npmRegistryServer`.
- Lockfiles record where packages came from: npm's and Yarn 1's `resolved` URL, and
  pnpm's tarball URL when it is not the default. Yarn 4 records only `name@npm:version`,
  plus an `__archiveUrl` when a registry serves a non-standard tarball path.
- A team split between the public registry and a mirror mixes hosts in the lockfile:
  each new or updated entry records whichever registry resolved it. npm's default
  `replace-registry-host=npmjs` fetches `registry.npmjs.org` URLs through a configured
  mirror (not the reverse) and never rewrites stored entries. Pick one registry per
  repo, commit it in project config, and keep personal registry overrides out of the
  repo.
- A mirror that serves a different tarball for the same version fails integrity checks
  (`EINTEGRITY`); that is the system working, see
  [diagnostics.md](diagnostics.md#integrity-failures).
- Composer: add the mirror as a `composer` repository and disable `packagist.org`.

## When a token was committed

1. **Revoke it first** at the registry or Packagist. Removing the line does not help:
   the token is in git history, in every clone and in any fork.
2. Replace the line with a `${VAR}` reference and move the real value to the
   environment or user config. In a pnpm repo, delete the line instead and use one of
   the pnpm options above.
3. Check the registry's audit log for use of the token.
4. Rewriting history is optional once the token is dead, and needs the team's agreement.
