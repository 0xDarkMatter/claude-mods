# Craft Security Advisories and Patching

Where Craft vulnerabilities are announced, which versions still get fixes, the CVEs that
were exploited in the wild, and a triage routine. Snapshot taken 2026-10-05 - version
floors move monthly, so re-read the advisory list before quoting any number below.

## Contents

- Support Windows
- Where Advisories Come From
- Exploited and Critical CVEs
- Triage Routine
- Running an End-of-Life Version
- Review Checklist

## Support Windows

From https://craftcms.com/knowledge-base/supported-versions (at least two years of active
support, then one more year of security fixes):

| Version | Released | Bug fixes until | Security fixes until | Status on 2026-10-05 |
|---|---|---|---|---|
| Craft 3 | 2018-04-04 | 2023-04-30 | **2024-04-30** | end of life |
| Craft 4 | 2022-05-04 | 2025-04-30 | **2026-04-30** | end of life |
| Craft 5 | 2024-03-26 | 2030-12-31 | 2031-12-31 | supported |

- Craft 6 is unreleased (alpha only; https://craftcms.com/docs/6.x/).
- **Every Craft 3 and Craft 4 site is now outside security support.** Craft has shipped
  critical fixes past end of life (3.9.15 for CVE-2025-32432; 4.18.x releases in 2026),
  but that is goodwill, not policy - plan the upgrade to Craft 5.
- PHP has its own clock (https://www.php.net/supported-versions.php): 8.1 is end of life;
  8.2 security support ends 2026-12-31; 8.3 ends 2027-12-31; 8.4 ends 2028-12-31. Craft 5
  needs PHP 8.2+ (https://craftcms.com/docs/5.x/requirements.html).

## Where Advisories Come From

- **Source of truth**: GitHub Security Advisories on craftcms/cms
  (https://github.com/craftcms/cms/security/advisories), per Craft's security policy
  (https://github.com/craftcms/cms/security/policy). Plugins publish on their own repos.
- **Disclosure lag**: details and the CVE go public 30 days after a release that contains
  the fix. A "critical" release can therefore land with a vague changelog line - patch on
  the release, not on the write-up.
- **Signals**: the control panel shows a banner for critical releases; Craft also runs a
  Critical Releases feed and a Discord #security channel
  (https://craftcms.com/knowledge-base/security-faq).
- **Machine check**: `composer audit` reads the same GitHub advisory data through
  Packagist, for Craft and for every plugin (`php-composer-supply-chain.md`).
- **Reporting** a vulnerability you find: Craft's policy routes reports through its
  vulnerability disclosure programme linked from the security policy page - not public
  issues.

## Exploited and Critical CVEs

| CVE | What | Affected | Fixed | Exploited |
|---|---|---|---|---|
| CVE-2023-41892 | unauthenticated RCE (CVSS 10) | 4.0.0-RC1 to 4.4.14 | 4.4.15 | no KEV entry found |
| CVE-2024-56145 | RCE when PHP `register_argc_argv` is on | 3.0.0-3.9.13, 4.0.0-RC1-4.13.1, 5.0.0-RC1-5.5.1 | 3.9.14, 4.13.2, 5.5.2 | yes - CISA KEV 2025-06-02 |
| CVE-2025-23209 | RCE for anyone holding the security key | 4.0.0-RC1 to <4.13.8, 5.0.0-RC1 to <5.5.5 (*) | 4.13.8, 5.5.8 (*) | yes - CISA KEV 2025-02-20 |
| CVE-2025-32432 | unauthenticated RCE via image transforms | 3.0.0-RC1-3.9.14, 4.0.0-RC1-4.14.14, 5.0.0-RC1-5.6.16 | 3.9.15, 4.14.15, 5.6.17 | yes - CISA KEV 2026-03-20 |

Sources: each CVE's GHSA under https://github.com/craftcms/cms/security/advisories,
NVD (https://nvd.nist.gov/vuln/detail/CVE-2024-56145 and siblings) for KEV dates, and
Craft's CVE knowledge-base articles. (*) The GHSA's 5.x affected range and patched
version disagree; treat 5.5.8 as the floor.

What each one teaches:

- **CVE-2024-56145** is a configuration precondition: patching *and* setting
  `register_argc_argv = Off` for the web SAPI both close it. PHP 8.5 deprecates the
  directive and its `php.ini-production` no longer sets it, so the built-in default (On)
  applies unless you set it - see `ddev-config-drift.md`.
- **CVE-2025-23209** turns a leaked security key into RCE. Treat the key as a production
  credential (`craft-config-hardening.md`).
- **CVE-2025-32432** needed nothing but network access. Exposure time is the risk: this
  class is why "patch within days" beats "patch next sprint".

2026 brought a steady run of high-severity fixes, mostly authenticated RCE through
condition/field-layout handling and Twig sandbox bypasses, plus admin-takeover password
reset flaws, GraphQL scope bypasses and a passkey replay. All are fixed only in recent
5.x releases (5.10.x-5.11), with some backported to 4.18.x. **The practical floor is
"the latest Craft 5 patch release"**; on 2026-10-05 that was 5.11.4.

## Triage Routine

1. **Version**: `composer show craftcms/cms` (and `twig/twig`, and each `craftcms/*` or
   vendor plugin) - or Utilities > System Report in the control panel.
2. **Match**: compare against the advisory's affected range. Ranges are inclusive and
   often skip RC labels - read them literally.
3. **Preconditions**: does it need a login, admin, `allowAdminChanges`, a leaked key, a
   PHP setting, a plugin, GraphQL enabled? Preconditions decide urgency, never whether to
   patch.
4. **Exploited?** Check the CISA KEV catalogue
   (https://www.cisa.gov/known-exploited-vulnerabilities-catalog). KEV-listed = assume
   scanned; patch now and look for compromise.
5. **Patch**: `composer update craftcms/cms --with-all-dependencies`, deploy, run
   `php craft up`. Commit the lock file.
6. **Compromise check** for exploited RCEs: unexpected PHP files in `web/` or upload
   roots, new admin users, changed templates, odd queue jobs, outbound connections. On
   evidence, follow Craft's response steps (offline, clean, update, rotate key and
   credentials, force password resets).
7. **Record**: note the advisory, decision and date in the project's changelog or
   security log so the next audit sees it.

## Running an End-of-Life Version

When an upgrade cannot happen immediately, reduce exposure while it is planned:

- Pin to the last 3.x/4.x release (3.9.15+ or the latest 4.18.x) - never an older patch.
- `register_argc_argv = Off`; `devMode` off; `allowAdminChanges` off.
- Block unused action routes at the web server or WAF (for example `generate-transform`
  if the site does not use dynamic transforms; the GraphQL endpoint if unused).
- Unique security key; rotate if it ever sat in git.
- Watch the advisory list monthly; an EOL site's risk only grows.

## Review Checklist

- [ ] Craft major version noted with its support status; Craft 3/4 sites carry an upgrade plan
- [ ] `craftcms/cms` at the latest patch for its major; `twig/twig` at 3.27.0 or later
- [ ] No affected range from the table above matches the installed version
- [ ] `composer audit` clean, or each finding triaged and recorded
- [ ] Someone owns the advisory watch (feed, Discord, or a scheduled audit)
- [ ] PHP version inside its security window
