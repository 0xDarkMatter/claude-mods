# Composer Audit and PHP Supply Chain

Composer's own security controls - `audit`, advisory and malware blocking, plugin
allow-lists - and how a Craft project should use them. Behavioural scanning, release
cooldowns, IOC matching and install-hook advisories are owned by
[supply-chain-defense](../../supply-chain-defense/SKILL.md); this file does not repeat
them. Facts verified 2026-10-05 against https://getcomposer.org/doc (CLI, config) and the
Composer CHANGELOG; Composer stable was 2.10.3.

## Contents

- Division of Labour
- composer audit
- Blocking at Resolve Time
- Plugins, Scripts and Transport
- Production Installs
- Craft Project Specifics
- Review Checklist

## Division of Labour

| Question | Tool | Where |
|---|---|---|
| Does an installed version have a *published* advisory? | `composer audit` | this file |
| Will Composer refuse to resolve a known-bad or malware version? | `config.policy` / `audit.block-insecure` | this file |
| Is a brand-new release behaving like malware before any advisory exists? | Socket / depscore, cooldown gate | [supply-chain-defense](../../supply-chain-defense/SKILL.md) |
| Did we install a named-bad version from a known campaign? | `exposure-check.py` on `composer.lock` | supply-chain-defense |
| How do tag-rewrite and `autoload.files` payloads work? | threat model | [threat-model.md](../../supply-chain-defense/references/threat-model.md) |

An advisory database only knows yesterday's attacks. `composer audit` passing is
necessary, never sufficient.

## composer audit

Added in Composer 2.4 (https://getcomposer.org/doc/03-cli.md#audit). Advisories come
from the Packagist API, which aggregates the GitHub Advisory Database and
FriendsOfPHP/security-advisories.

```bash
composer audit --locked --format=summary            # CI: reads composer.lock, no vendor/ needed
composer audit --locked --no-dev --format=json      # production set only, machine-readable
composer audit --locked --abandoned=report          # report abandoned packages without failing
```

- **Exit codes changed twice.** 2.4-2.8.3: not meaningful. 2.8.4-2.9.x: bitmask
  (1 vulnerable, 2 abandoned, 3 both). **2.10.0+: only 0 or 1.** Scripts must test
  "non-zero", never decode the bitmask. 2.10 also fails when `vendor/` is missing unless
  `--locked` is passed.
- Abandoned packages fail the audit by default since 2.7 (`audit.abandoned` = `fail`).
  Craft 3/4 sites often carry abandoned plugins - decide per package and record it:

```json
{
  "config": {
    "audit": {
      "ignore": {
        "GHSA-xxxx-xxxx-xxxx": "Not reachable: feature disabled in config/app.php (2026-10-05)"
      }
    }
  }
}
```

- `update`, `require`, `remove` and `create-project` print an audit summary
  automatically; `install` does not unless given `--audit` (failure exit code 5). Do not
  set `COMPOSER_NO_AUDIT=1` in CI.

## Blocking at Resolve Time

- **Composer 2.9** added `audit.block-insecure` (default `true`): `update`/`require`
  refuse versions affected by an advisory (https://getcomposer.org/doc/06-config.md).
- **Composer 2.10** replaced most `audit` settings with `config.policy` - `advisories`
  (block on by default), `abandoned` (block off), and `malware` (block on by default,
  including at `install` time). Legacy `audit.*` keys are read only when the matching
  `policy` section is absent. `--no-blocking` / `COMPOSER_NO_BLOCKING=1` exist for
  emergencies - never in CI.
- **`dev-*` versions are never blocked.** Branch requirements (`dev-main`,
  `1.x-dev`) escape advisory blocking entirely; keep them out of production
  requirements.
- A native release cooldown (`policy.cooldown`) is on Composer's main branch for 2.11 but
  is **not** in 2.10.x. Until it ships, use supply-chain-defense's cooldown gate
  (`preinstall-check.sh --composer`, Renovate `minimumReleaseAge`).
- On Composer older than 2.9 (including the 2.2 LTS line, which has no `audit` command
  at all), `roave/security-advisories:dev-latest` in `require-dev` blocks vulnerable
  versions through conflict rules (https://github.com/Roave/SecurityAdvisories).

## Plugins, Scripts and Transport

- **`allow-plugins`** (Composer 2.2+) defaults to `{}` - no plugin runs unless listed.
  In non-interactive runs an unlisted plugin is an error, not a prompt. List exact
  package names; `true` ("allow all") is explicitly not recommended
  (https://getcomposer.org/doc/06-config.md#allow-plugins).
- **Scripts** in your root `composer.json` run on install/update; dependency packages'
  scripts do not, but their **plugins** and `autoload.files` code do - which is why
  `--no-scripts` is not a supply-chain defence (see supply-chain-defense's threat model).
- **`secure-http`** stays `true` (HTTPS only); never set `disable-tls`, which silently
  turns `secure-http` off. Composer 2.10.0 fixed an uppercase-scheme bypass of the HTTPS
  requirement - another reason to keep Composer current (`composer self-update`).
- `composer validate --strict` in CI fails on warnings as well as errors.

## Production Installs

```bash
composer install --no-dev --no-interaction --optimize-autoloader --audit
```

- Deploy from a committed `composer.lock`; never run `composer update` on a server.
- `--no-dev` keeps dev tooling (debug bars, generators, test fixtures) off production -
  a dev dependency reachable from `web/` is an attack surface.
- Craft's deploy guide uses `composer install --no-interaction`
  (https://craftcms.com/docs/5.x/deploy.html); `--no-dev` and `--audit` are this skill's
  additions.

## Craft Project Specifics

From Craft's starter project (https://github.com/craftcms/craft/blob/5.x/composer.json):

```json
{
  "minimum-stability": "dev",
  "prefer-stable": true,
  "config": {
    "allow-plugins": {
      "craftcms/plugin-installer": true,
      "yiisoft/yii2-composer": true
    },
    "sort-packages": true,
    "optimize-autoloader": true
  }
}
```

- Those two plugins are required; anything else added to `allow-plugins` deserves a
  review comment saying why.
- `minimum-stability: dev` + `prefer-stable: true` resolves stable releases where they
  exist, but permits `dev-*` constraints - which escape advisory blocking (above). Prefer
  tagged plugin releases.
- Pin the production PHP version so local resolution matches the server:
  `"config": { "platform": { "php": "8.3.0" } }` (`ddev-config-drift.md`).
- Craft plugins live on Packagist; `composer audit` covers them. A plugin with no release
  in years is "abandoned" in practice even if not flagged - add it to the upgrade plan.

## Review Checklist

```bash
composer audit --locked; echo "exit=$?"
composer validate --strict
jq '.config["allow-plugins"], .config.policy, .config.audit, .["minimum-stability"]' composer.json
jq -r '.packages[] | select(.version | startswith("dev-")) | .name' composer.lock
```

- [ ] `composer audit --locked` clean, or every ignore carries a dated reason
- [ ] Composer 2.10+ in CI and on build hosts; no `--no-blocking` / `COMPOSER_NO_AUDIT`
- [ ] `allow-plugins` lists exact names only; never `true`
- [ ] No `dev-*` packages in the production lock without a recorded reason
- [ ] Production installs use `--no-dev` from a committed lock
- [ ] supply-chain-defense's cooldown and behavioural checks wired for dependency changes
