# pm-audit Rules, Formats and Suppression

The rule catalogue behind `scripts/pm-audit.py`, and everything that decides what a run
reports: output formats, `.pm-audit.json` waivers, inline ignores, baselines, `--fail-on`
and profiles. What a finding means in prose, and how to fix it, is in
[diagnostics.md](diagnostics.md#pm-audit-finding-ids); this file is the machine-readable
side. The catalogue lives in `pm-audit.py` (`RULES`), and `tests/run.sh` fails when this
file's ids or severities drift from it. Output formats follow SARIF 2.1.0 (OASIS) and
GitHub's workflow-command grammar (`@actions/core`: `escapeData`, `escapeProperty`).

## Contents

- [Using the catalogue](#using-the-catalogue)
- [Output formats](#output-formats)
- [Suppressing findings](#suppressing-findings)
- [Baselines](#baselines)
- [Gating CI](#gating-ci)
- [Profiles](#profiles)
- [Reading a rule row](#reading-a-rule-row)
- [Manifest rules](#manifest-rules)
- [Lockfile and manager rules](#lockfile-and-manager-rules)
- [Dependency rules](#dependency-rules)
- [Runtime and end-of-life rules](#runtime-and-end-of-life-rules)
- [PHP and Composer rules](#php-and-composer-rules)
- [npx rules](#npx-rules)
- [Legacy rules](#legacy-rules)
- [Registry and credential rules](#registry-and-credential-rules)
- [CI and deploy rules](#ci-and-deploy-rules)
- [Suppression and config rules](#suppression-and-config-rules)

## Using the catalogue

```bash
bash scripts/run-python.sh scripts/pm-audit.py --rules                    # id, severity, category, summary (TSV)
bash scripts/run-python.sh scripts/pm-audit.py --rules --format json      # the same, with confidence and docs_url
bash scripts/run-python.sh scripts/pm-audit.py --explain deploy.composer.dev
```

`--explain` prints one rule's rationale, its generic fix and the docs anchor. Neither flag
needs a PATH or the facts file. Every finding carries `docs_url`, a relative anchor into the
tables below (`references/pm-audit-rules.md#<id>`; each id is an HTML anchor, so the dots
stay). An unknown id is a usage error (exit 2).

## Output formats

`--format tsv|json|sarif|github` (default `tsv`; `--json` is an alias for `--format json`,
and combining it with another format is exit 2).

| Format | Shape |
|---|---|
| `tsv` | One row per finding: severity, id, `file[:line]`, message, fix text. Data only on stdout |
| `json` | `{"data": [finding...], "meta": {...}}`, schema `claude-mods.package-manager-ops.pm-audit/v1` |
| `sarif` | SARIF 2.1.0, one run, one rule per catalogue id, `ruleIndex` on every result, the baseline fingerprint in `partialFingerprints["pmAudit/v1"]`, the fix object and confidence under `properties` |
| `github` | `::warning file=F,line=N::<id> <message>` (`::error` for error severity). `%`, CR and LF are escaped in the message; `:` and `,` also in `file=`. Notes are not printed. Run it from the repo root so `file=` resolves in the checkout |

JSON finding fields: `id`, `severity`, `file`, `line`, `message`, plus these, added by the
output contract:

| Field | Meaning |
|---|---|
| `fix` | `{"kind": "command"\|"edit"\|"manual", "text", "command", "safe"}`. `command` is only a command the text itself quotes in backticks, else `null`. `safe` means mechanical, local and reversible with git; it never means skip the review |
| `fix_text` | The fix as a plain string (what `fix` was before it became an object) |
| `confidence` | `high` a fact read from a manifest or lockfile, `medium` a judgement over shell, CI or version arithmetic, `low` a signal that can be legitimate |
| `docs_url` | The anchor in this file |
| `fingerprint` | Stable identity, see [Baselines](#baselines) |

`meta` adds `profile`, `fail_on`, `config` (`file`, `valid`, `ignores`), `suppressed`
(every waived finding with `by` = `config` or `inline`, and its reason), `profile_silenced`
and `baseline` (`file`, `known`). Nothing is suppressed silently.

## Suppressing findings

A waiver needs a reason and an end date, so tolerated risk is re-decided rather than
forgotten. Two forms:

```json
{
  "profile": "site",
  "ignore": [
    {"id": "npx.unpinned", "path": "docs/*", "reason": "docs only, never run in CI", "until": "2027-01-31"}
  ]
}
```

That is `.pm-audit.json` at the repo root (`--config FILE` reads another; an explicit file
that is missing is exit 3). `reason` and `until` (`YYYY-MM-DD`) are required; `path` is an
optional glob over the finding's file (`*` crosses `/`; a finding that names several files
matches when any one does) and defaults to every file. An ignore is live through its `until`
day. The other form is a comment on the flagged line or the line above it:

```text
# pm-audit: ignore[npx.unpinned] one-off bootstrap, the CI image pins it
npx eslint .
```

An inline ignore needs a reason too (without one the finding stays and a
`suppression.inline-no-reason` note says so) and only works on findings that carry a line,
in files that have comments. `package.json` and `composer.json` use the config file.

| Situation | Result |
|---|---|
| `until` before the audit date (`--as-of`) | The finding is reported again, plus `suppression.expired` |
| An ignore matched no finding | `suppression.unused` note (never changes the exit code) |
| Any malformed config (bad JSON, unknown key, unknown id, no reason, bad date, bad profile) | `config.invalid` error, and **none** of the file applies, so a typo never half-works |

`config.invalid`, `suppression.expired` and `suppression.unused` cannot themselves be ignored.

## Baselines

`--baseline FILE` takes a previous `--json` output and reports only findings absent from it,
so an old estate can adopt pm-audit and fail only on new problems. A finding's fingerprint is
the first 16 hex digits of sha1 over id, file and a subject (the message with line numbers
masked), **not** the line: an unrelated edit above a finding must not resurrect it. A rule
whose wording changes resurfaces its baselined findings once. A baseline written before
fingerprints existed still matches (they are computed from id, file and message). Two findings
with the same id, file and subject share one fingerprint, so a new twin of a baselined
finding is hidden. A missing baseline is exit 3, an unparseable one exit 4.

## Gating CI

`--fail-on error|warn`. Default: any finding exits 10. `--fail-on error` still prints every
finding but exits 10 only when one has error severity, so warnings can be tracked without
blocking a merge. Notes never count. Exit codes stay 0, 10, 2, 3, 4.

## Profiles

`--profile site|library|pedantic` (or `"profile"` in the config; the flag wins).

| Profile | Effect | Why |
|---|---|---|
| `site` (default) | Silences nothing | The repo type every rule was written for: something deployed |
| `library` | Drops `js.lockfile.missing`, `php.lockfile.missing`, `php.platform.unset`, `js.node.unpinned`, `ddev.node.unpinned`, `js.root.not-private`, `deploy.install.unlocked`, `js.engine.floor`, `php.lock.floor` | A published library legitimately ships no lockfile, sets no `config.platform.php`, pins no runtime and is published on purpose. The count is in `meta.profile_silenced` |
| `pedantic` | Reports every warn as error | Pair with `--fail-on error` to make warnings block |

## Reading a rule row

`Severity` is the most severe level the rule emits (a stale lockfile is an error when it
cannot be parsed, a warn when merely behind). `Fix` is `command`, `edit` or `manual`, with
`(safe)` where a mechanical edit is safe to apply after review.

## Manifest rules

A manifest the tools cannot read.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="js.manifest.invalid"></a>`js.manifest.invalid` | error | high | manual | package.json is not valid JSON, or not a JSON object |
| <a id="php.manifest.invalid"></a>`php.manifest.invalid` | error | high | manual | composer.json is not valid JSON, or not a JSON object |

## Lockfile and manager rules

Which manager owns the install, and whether its lockfile can be trusted.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="js.install-policy"></a>`js.install-policy` | warn | high | edit | pnpm enables dangerouslyAllowAllBuilds |
| <a id="js.lockfile.conflict"></a>`js.lockfile.conflict` | error | high | manual | two or more JS lockfiles at the root |
| <a id="js.lockfile.missing"></a>`js.lockfile.missing` | warn | high | command | dependencies but no lockfile |
| <a id="js.lockfile.shrinkwrap"></a>`js.lockfile.shrinkwrap` | warn | high | edit (safe) | only npm-shrinkwrap.json, which npm 12 ignores |
| <a id="js.lockfile.source"></a>`js.lockfile.source` | warn | medium | manual | lockfile resolved URL is HTTP, names another package, or lacks a strong integrity hash |
| <a id="js.lockfile.stale"></a>`js.lockfile.stale` | error | high | command | lockfile disagrees with package.json (or cannot be parsed) |
| <a id="js.lockfile.v1"></a>`js.lockfile.v1` | warn | high | command | npm 6-era lockfileVersion 1 |
| <a id="js.manager.mixed"></a>`js.manager.mixed` | warn | high | manual | nested package roots use a different manager than the root |
| <a id="js.packagemanager.mismatch"></a>`js.packagemanager.mismatch` | error | high | edit | `packageManager` names a manager the lockfile is not from |
| <a id="js.pnpm.field-ignored"></a>`js.pnpm.field-ignored` | warn | high | edit | a package.json `pnpm` field pnpm 11+ no longer reads |

## Dependency rules

Where dependencies come from and whether they fit together.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="js.dep.non-registry"></a>`js.dep.non-registry` | warn | high | manual | package.json points a dependency at git, a local path or a direct tarball URL |
| <a id="js.dep.paired-drift"></a>`js.dep.paired-drift` | warn | medium | edit | packages that must move together are on different versions |
| <a id="js.engine.floor"></a>`js.engine.floor` | warn | medium | edit | a locked package needs a newer Node than the repo pins |
| <a id="js.root.not-private"></a>`js.root.not-private` | warn | low | edit (safe) | a root package with dependencies is neither private nor evidently published |
| <a id="php.dep.non-registry"></a>`php.dep.non-registry` | warn | high | manual | composer.json uses a VCS/path/artifact repository, a dev-* or * constraint, or minimum-stability dev |

## Runtime and end-of-life rules

Node, PHP, Composer and Craft pins against the facts catalogue's dated tables.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="ddev.node.unpinned"></a>`ddev.node.unpinned` | warn | high | edit | DDEV has no nodejs_version |
| <a id="js.node.eol"></a>`js.node.eol` | warn | medium | edit | a pinned Node is end of life |
| <a id="js.node.eol-soon"></a>`js.node.eol-soon` | warn | medium | edit | a pinned Node reaches end of life within the eol_soon_days window |
| <a id="js.node.unpinned"></a>`js.node.unpinned` | warn | high | edit | nothing pins Node |
| <a id="node.pin.disagree"></a>`node.pin.disagree` | warn | high | edit | Node pins in different files name different majors |
| <a id="php.composer.eol"></a>`php.composer.eol` | warn | medium | edit | the Composer minor line in use is past support |
| <a id="php.composer.v1"></a>`php.composer.v1` | warn | high | edit | CI or a Dockerfile uses Composer 1 |
| <a id="php.craft.eol"></a>`php.craft.eol` | warn | medium | manual | composer.lock contains a Craft CMS major past critical-security support |
| <a id="php.eol"></a>`php.eol` | warn | medium | edit | a pinned PHP is past security support |
| <a id="php.eol-soon"></a>`php.eol-soon` | warn | medium | edit | a pinned PHP leaves security support within the eol_soon_days window |
| <a id="php.lock.floor"></a>`php.lock.floor` | warn | medium | edit | a locked package needs a newer PHP than production runs |
| <a id="php.pin.disagree"></a>`php.pin.disagree` | warn | high | edit | PHP pins in different files name different versions |

## PHP and Composer rules

composer.json and composer.lock hygiene.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="php.composer.safety-off"></a>`php.composer.safety-off` | warn | high | edit | composer.json disables transport, plugin or advisory safeguards |
| <a id="php.lockfile.missing"></a>`php.lockfile.missing` | warn | high | command | a project with packages but no composer.lock |
| <a id="php.lockfile.stale"></a>`php.lockfile.stale` | error | high | command | composer.json requires packages the lock lacks (or the lock cannot be parsed) |
| <a id="php.package.abandoned"></a>`php.package.abandoned` | warn | high | manual | composer.lock marks a package abandoned |
| <a id="php.platform.unset"></a>`php.platform.unset` | warn | high | edit | no config.platform.php in a project |
| <a id="php.require.missing"></a>`php.require.missing` | warn | high | edit | no require.php in a library, or in a project without config.platform.php |

## npx rules

Running registry packages outside the lockfile.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="npx.native-cli"></a>`npx.native-cli` | error | high | edit | a native CLI (rg, fd, jq...) is run through npx or installed globally from npm |
| <a id="npx.unpinned"></a>`npx.unpinned` | warn | medium | edit | npx/dlx/bunx runs an unpinned or undeclared package |

## Legacy rules

Tools and packages the ecosystem has moved on from.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="legacy.bower"></a>`legacy.bower` | warn | high | manual | bower.json or .bowerrc |
| <a id="legacy.node-sass"></a>`legacy.node-sass` | warn | high | manual | node-sass is a dependency |
| <a id="legacy.package"></a>`legacy.package` | warn | high | manual | a dependency matches the facts catalogue's legacy-package table |

## Registry and credential rules

Tokens and auth files that must not ship.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="registry.authjson.committed"></a>`registry.authjson.committed` | error | high | command | a root auth.json that git tracks or does not ignore |
| <a id="registry.credentials.image"></a>`registry.credentials.image` | error | medium | edit | CI writes credentials into a Docker build context that the image copies |
| <a id="registry.pnpm.placeholder-ignored"></a>`registry.pnpm.placeholder-ignored` | warn | high | edit | a ${...} placeholder in a project .npmrc setting that pnpm ignores |
| <a id="registry.token.committed"></a>`registry.token.committed` | error | high | manual | a literal token in .npmrc or .yarnrc.yml |

## CI and deploy rules

Installs and bundles in CI, Dockerfiles and deploy hooks.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="deploy.bundle.credentials"></a>`deploy.bundle.credentials` | error | medium | edit | CI writes a credential file and then zips it into a deploy bundle |
| <a id="deploy.composer.adhoc"></a>`deploy.composer.adhoc` | warn | medium | edit | CI or deploy runs `composer require`, `global require` or `update` |
| <a id="deploy.composer.dev"></a>`deploy.composer.dev` | warn | medium | edit | `composer install` without --no-dev where vendor/ ships |
| <a id="deploy.composer.installer-unverified"></a>`deploy.composer.installer-unverified` | warn | medium | edit | the Composer installer is piped to php without checking installer.sig |
| <a id="deploy.composer.safety-off"></a>`deploy.composer.safety-off` | warn | medium | edit | a shipping Composer command disables security blocking, audit or platform checks |
| <a id="deploy.global.unpinned"></a>`deploy.global.unpinned` | warn | medium | edit | `npm install -g` without an exact version |
| <a id="deploy.install.unfrozen"></a>`deploy.install.unfrozen` | warn | medium | edit | CI or a deploy runs a non-frozen install |
| <a id="deploy.install.unlocked"></a>`deploy.install.unlocked` | warn | medium | manual | CI installs in a nested folder that has no lockfile |
| <a id="deploy.npm.yarn-flag"></a>`deploy.npm.yarn-flag` | error | high | edit (safe) | a Yarn flag on `npm ci` or `npm install` |

## Suppression and config rules

Raised by pm-audit about its own configuration.

| Id | Severity | Confidence | Fix | Means |
|---|---|---|---|---|
| <a id="config.invalid"></a>`config.invalid` | error | high | edit | the --config file is malformed, so none of it applies |
| <a id="suppression.expired"></a>`suppression.expired` | warn | high | manual | an ignore passed its `until` date |
| <a id="suppression.unused"></a>`suppression.unused` | note | high | edit | an ignore matched no finding |

