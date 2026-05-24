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
| Production / build dependency | Enforce a **7-day cooldown** after a release before pulling it. The axios poisoned versions were live ~3 hours; a 7-day lag lets the ecosystem detect and remediate first. |
| Any `install` / `add` command | Prefer the Socket wrapper (`socket npm …`, `socket npx …`) when available, so a risky install is intercepted before lifecycle scripts execute. |
| Lifecycle scripts | Where a project doesn't need build hooks, disable them: `npm config set ignore-scripts true` / pnpm `enable-pre-post-scripts=false`. It removes the `postinstall` execution vector outright — the cheapest mitigation that exists. |
| Lockfiles | Commit them. Pin exact versions for anything that runs in CI or prod. A pin only protects you if it *pre-dates* the compromise and you never run unconstrained installs. |
| CI/CD workflows | Audit GitHub Actions for stale OIDC trust federation to npm/PyPI. Revoke any publish trust no longer needed — this is the exact entry point Mini Shai-Hulud abused (orphaned commit, live OIDC federation, minted token). Run `zizmor` to catch the `pull_request_target` + OIDC misconfigs statically; add `step-security/harden-runner` for runtime egress control. |
| Publish tokens | Prefer short-lived OIDC over long-lived npm/PyPI tokens. Audit and tighten who has standing publish access. |
| After any install on this machine | Be alert to new/modified entries in `.claude/settings.json`, `.claude.json`, or VS Code `settings.json` — unexplained hooks/`mcpServers`/startup entries are a persistence IOC. |

## Self-check before generating install/setup commands

Before writing any `npm install`, `pip install`, `uv add`, `composer require`, etc.
into a README, Dockerfile, CI workflow, or shell snippet:

- Never recommend day-zero pulls (`npm install <pkg>@latest` of a brand-new
  release) for production paths. Pin a version that has aged past the cooldown.
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
