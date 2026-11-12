# Supply Chain Hygiene — behavioural-first dependency defense

Companion to the [`supply-chain-defense`](../skills/supply-chain-defense/SKILL.md) skill
(the full playbook + scripts) and [`security-ops`](../skills/security-ops/SKILL.md)
(reactive CVE auditing). This file is the *directive* — what to do every time a
dependency enters the tree, in any project.

## The rule

**Treat every dependency add or version bump as untrusted until it has been
behaviourally scanned. CVE/advisory tools are necessary but not sufficient — they
report yesterday's known-bad, and the active 2026 threat is a worm that publishes
and self-propagates inside the 30-minute-to-6-hour window *before* any advisory
exists.**

Three non-negotiables:

1. **Never install an unconstrained, just-published version into anything that
   executes** — build, CI, dev shell, or production. Lifecycle scripts
   (`postinstall`, `prepare`, sdist `setup.py`) run code the moment you install.
2. **A behavioural scan gates the merge, not the CVE database.** `npm audit` /
   `pip-audit` passing is not a green light. Behaviour is.
3. **The blast radius includes this machine.** The 2026 worm family
   (Shai-Hulud / Mini Shai-Hulud) writes persistence hooks into Claude Code and
   VS Code settings to survive reboots. A poisoned `npm install` is an attack on
   your editor, your credentials, and your publish tokens — not just one package.

## Why this matters

Over 90 days in 2026: axios (100M weekly downloads, NK state actor, stolen npm
token), Microsoft's official `durabletask` PyPI SDK (zero provenance, credential
stealer), 323 packages poisoned in a 22-minute automated burst, and GitHub itself
losing 3,800 internal repos to one poisoned VS Code extension on one laptop. The
worm source is public on BreachForums; copycats are live. Every control that
depends on maintainer hygiene (2FA, lockfile-on-clean, even Sigstore/SLSA
provenance) has already been bypassed in the wild. The only control that closed
the gap was behavioural analysis of what the package *does* within seconds of
publication.

See `supply-chain-defense/references/threat-model.md` for the full timeline and IOCs.

## Directives — apply on every dependency touch

| Situation | Directive |
|---|---|
| Adding or bumping a dependency | Run a behavioural scan (`socket scan` / depscore MCP) and surface the verdict **before** merge. Don't merge on a CVE-clean signal alone. |
| Production / build dependency | Enforce a **7-day cooldown** after a release before pulling it. The axios poisoned versions were live ~3 hours; a 7-day lag lets the ecosystem detect and remediate first. One exception: a security release that passes every check in [the next section](#security-release-exception-to-the-cooldown). |
| Any `install` / `add` command | Prefer the Socket wrapper (`socket npm …`, `socket npx …`) when available, so a risky install is intercepted before lifecycle scripts execute. |
| A certificate error during a fetch or install | Stop and report the error and the host. Never switch verification off to get past it (`curl -k`, `verify=False`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, `strict-ssl false`, `--trusted-host`): anyone on the network path could then swap the package or download. The `pre-tls-verify-ask` hook asks before a command does it, and `post-tls-verify-scan` flags code that does. |
| Lifecycle scripts | Where a project doesn't need build hooks, disable them: `npm config set ignore-scripts true` / pnpm `enable-pre-post-scripts=false`. It removes the `postinstall` execution vector outright — the cheapest mitigation that exists. |
| Lockfiles | Commit them. Pin exact versions for anything that runs in CI or prod. A pin only protects you if it *pre-dates* the compromise and you never run unconstrained installs. |
| CI/CD workflows | Audit GitHub Actions for stale OIDC trust federation to npm/PyPI. Revoke any publish trust no longer needed — this is the exact entry point Mini Shai-Hulud abused (orphaned commit, live OIDC federation, minted token). Run `zizmor` to catch the `pull_request_target` + OIDC misconfigs statically; add `step-security/harden-runner` for runtime egress control. |
| Publish tokens | Prefer short-lived OIDC over long-lived npm/PyPI tokens. Audit and tighten who has standing publish access. |
| After any install on this machine | Be alert to new/modified entries in `.claude/settings.json`, `.claude.json`, or VS Code `settings.json` — unexplained hooks/`mcpServers`/startup entries are a persistence IOC. |

## Security-release exception to the cooldown

**A release that patches a published vulnerability may skip the 7-day cooldown, but only
when every condition below holds.** The cooldown guards against a poisoned *new* release;
waiting a week on the fix for a known, exploitable hole trades that risk for a worse one.
Shipping a fix fast is the whole reason vendors cut a security point release.

The same urgency is also the attacker's best lever: "critical security fix, upgrade now"
is how a hijacked publish gets waved through. So the CVE label alone never waives the
cooldown. The conditions make the release prove where it came from instead.

| Condition (all must hold) | Why it is there |
|---|---|
| It fixes **published** CVEs that are named by ID **for this exact version**, either in a CVE or vendor advisory or in the vendor's own release notes for the version. | The CVE IDs are the evidence; a changelog that only says "security fixes" is the lure. Vendor release notes count because upstream advisories often go public before they name a fixed version. Git's GHSA-vp2w-7xxj-jvxr still read "patches are being discussed" when Git for Windows 2.56.1 shipped the fix, with the CVE IDs in its release notes. The next condition is what makes the notes trustworthy. |
| The artifact matches a checksum or signature the vendor publishes **on its own channel** (its website, signed release page, or checksum API), compared with what you actually installed. For a signed binary, its code signature must also be valid and come from **the same signing identity as the version already installed**. | A hijacked registry account can rewrite the registry's own metadata, so checking the registry against itself proves nothing. A hijacked release account can rewrite the notes and the hashes beside the asset. Neither attacker also holds the vendor's code-signing key, so an unchanged signer is the strongest second channel there is. A new or missing signer sends the release back under the cooldown. |
| The change is **confined to the patched package(s)**. If any other package moves in the lockfile, stop: the whole change goes back under the cooldown. A single tool installer is confined by nature. | A security bump that drags in an unrelated new transitive version is the exact shape of a worm piggy-backing on urgency. A diff that touches only the patched package is small enough to review. |
| A **person approves** it: they merge the PR, or OK the tool install. A dependency change also runs on **staging** (or the equivalent) before production. | Skipping the cooldown removes the week in which the ecosystem would have caught a bad release. A human decision and a staging soak are the cheap stand-ins for that week. The waiver never lets an agent or bot merge, deploy or install unattended. |
| The **waiver is recorded** in the PR or commit, or in the install note for a tool. Record the CVE IDs and where they were named, the checksum and signer and where they came from, and, for a dependency, confirmation that nothing else moved in the lock. | The next reader, or the incident review if it goes wrong, must see that the cooldown was skipped on purpose and on what evidence. An unrecorded waiver looks the same as a missed check. |

The behavioural scan still runs. The exception waives the *wait*, nothing else. If any
condition fails or cannot be checked, the default holds: wait out the 7 days.
`preinstall-check.sh` still exits 10 for such a release, because release age is a fact
it reports. It has no flag to waive the cooldown; the waiver is a human decision recorded
in the PR, or in the install note for a tool.

**Worked example (generic).** A CMS ships core `X.Y.4`, a security point release whose
advisory fixes a CVE in `X.Y.3`. The site's lock moves the core package and its paired
core-files package from `X.Y.3` to `X.Y.4`, and nothing else. The downloaded archive's
SHA-1 matches the checksum the vendor publishes on its own download API, not only the
registry entry. The PR states the advisory ID, the checksum and its source URL, and "only
the two core packages changed in the lock". A person merges it to staging, checks the
site, then promotes it to production the same day. Had a third package moved in the lock,
or had the checksum come only from the registry, the PR would wait the 7 days.

**Worked example (tool).** Git for Windows 2.56.1 shipped 3 days after 2.56.0(4). Its
release notes name six CVEs by ID, one of them remote code execution through a recursive
clone. The installer's SHA-256 matches the table in the vendor's release notes. Its
Authenticode signature is valid and has the same signer certificate as the installed
2.56.0(4). The workstation owner OKs the install, and the install note records the CVE IDs,
the hash and the signer. Had the signer changed, or had the notes said only "security fixes",
it would wait the 7 days.

## Self-check before generating install/setup commands

Before writing any `npm install`, `pip install`, `uv add`, `composer require`, etc.
into a README, Dockerfile, CI workflow, or shell snippet:

- Never recommend day-zero pulls (`npm install <pkg>@latest` of a brand-new
  release) for production paths. Pin a version that has aged past the cooldown,
  unless it is a security release that meets every condition of the exception above.
- Where a behavioural scanner is in play, route the command through it
  (`socket npm install …`) rather than raw `npm`.
- If the user is wiring CI publish, default to OIDC trusted publishing, not a
  stored long-lived token.

## When the playbook is needed

For the full operational workflow — trialling Socket.dev, the wrapper setup, the
GitHub PR app, the depscore MCP server for Claude Code, the OIDC audit, token
rotation, VS Code extension audit, the self-integrity scan that detects injected
persistence hooks, and the wider free/OSS toolset (GuardDog, OSV-Scanner, zizmor,
Harden-Runner, lockfile-lint) — **invoke the `supply-chain-defense` skill.** Everything
needed to defend against this campaign works at $0.

## Cross-reference

- `~/.claude/skills/supply-chain-defense/SKILL.md` — full playbook + scripts
- `~/.claude/skills/security-ops/SKILL.md` — reactive CVE/SAST/auth audit
- `~/.claude/hooks/pre-install-scan.sh` — PreToolUse advisory on install commands
- `~/.claude/rules/cli-tools.md` — modern tool preferences (uv, fd, rg)
