# Private Registries, Auth and Mirrors

Pointing npm, Yarn, pnpm and Composer at private packages and mirrors without a credential
ever reaching git. Facts verified 2026-10-05 against docs.npmjs.com (`npmrc`, v12),
yarnpkg.com (`.yarnrc.yml`), the pnpm 11 release notes, the actions/setup-node README,
and getcomposer.org (authentication and repositories articles, checked against 2.10.3).

## Contents

- [The rule](#the-rule)
- [npm and pnpm: .npmrc](#npm-and-pnpm-npmrc)
- [Yarn 4: .yarnrc.yml](#yarn-4-yarnrcyml)
- [Composer: auth.json, COMPOSER_AUTH and repositories](#composer-authjson-composer_auth-and-repositories)
- [CI wiring](#ci-wiring)
- [Mirrors and proxies](#mirrors-and-proxies)
- [When a token was committed](#when-a-token-was-committed)

## The rule

The **project** file says *where* packages come from and *which variable* holds the
credential. The credential itself lives in the environment, the user-level config, or the
CI secret store. Committed config contains `${NPM_TOKEN}`, never a token. pm-audit reports
a literal token as `registry.token.committed` (by file and line; it never prints the
value) and a committed `auth.json` as `registry.authjson.committed`.

## npm and pnpm: .npmrc

```ini
# .npmrc (committed)
@acme:registry=https://npm.example.com/
//npm.example.com/:_authToken=${NPM_TOKEN}
engine-strict=true
```

- A scope (`@acme`) maps to one registry; everything unscoped still comes from the
  default registry.
- Auth keys must be scoped to a registry URL (`//host/path/:_authToken=`). npm refuses
  unscoped auth settings.
- `${VAR}` is expanded from the environment. If the variable is unset npm leaves the text
  as is; write `${VAR?}` to make a missing variable an error instead of a confusing 401.
- The real token goes in the user's `~/.npmrc` (written by `npm login --registry` or
  `npm config set //npm.example.com/:_authToken <token>`), or in the environment.
- pnpm reads `.npmrc` for registries and auth. From pnpm 11 that is all it reads there;
  every other setting moved to `pnpm-workspace.yaml`.

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

`setup-node` writes a temporary `.npmrc` that reads `NODE_AUTH_TOKEN`. For Composer, set
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
- Lockfiles record where each package resolved from (npm's `resolved`, Yarn's
  resolution, pnpm's tarball URL when non-default). A team split between the public
  registry and a mirror produces lockfile churn on every install. Pick one registry per
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
   environment or user config.
3. Check the registry's audit log for use of the token.
4. Rewriting history is optional once the token is dead, and needs the team's agreement.
