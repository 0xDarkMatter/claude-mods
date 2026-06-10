---
name: supply-chain-defense
description: "Behavioural-first software supply chain defense - catches poisoned npm/PyPI packages in the publish-to-advisory window that CVE tools miss. Use BEFORE every install or version bump (not only when an attack is suspected) - the 7-day cooldown gate + behavioural score catches freshly-published malware that CVE tools won't see for days. Socket.dev integration (free CLI + GitHub app + depscore MCP for Claude Code), stale-OIDC audit, dependency cooldown policy, publish-token rotation, VS Code extension audit, and a self-integrity scan that detects worm persistence hooks injected into Claude Code / VS Code settings. Triggers on: pip install, uv add, uv tool install, npm install, pnpm add, yarn add, cargo add, go get, composer require, gem install, upgrade dependency, version bump, adding dependency, vet package, is this package safe, before installing, pre-install check, preinstall-check, release cooldown, minimumReleaseAge, score a package, depscore, socket score, supply chain, supply chain attack, malicious package, poisoned dependency, npm worm, Shai-Hulud, behavioural scanning, Socket.dev, socket scan, dependency security, postinstall malware, OIDC token theft, compromised maintainer, typosquat, dependency confusion, package provenance, SLSA, persistence hook, malicious VS Code extension."
when_to_use: "Use before any dependency install or version bump — e.g. 'is this package safe', 'pre-install check', 'score this package' — or when investigating a suspected malicious package or worm persistence hook."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent WebFetch"
metadata:
  author: claude-mods
  related-skills: security-ops, ci-cd-ops, github-ops, auth-ops
---

# Supply Chain Defense

Proactive, behavioural-first defense against the 2026 software supply chain threat:
self-propagating worms (Shai-Hulud / Mini Shai-Hulud) that poison popular npm and
PyPI packages, steal credentials, republish from stolen tokens, and inject
persistence hooks into **Claude Code and VS Code settings** specifically.

## Helps with

Every install or version bump is a use case for this skill, not just suspected attacks — the routine cooldown gate + behavioural score is the whole point.

Deciding whether a dependency you're about to add is safe — getting a behavioural
verdict on an npm or PyPI package *before* `npm install` / `pip install`, not days
later when a CVE drops. `socket package score`, the depscore MCP, or
`scripts/preinstall-check.sh`.

A teammate or CI just pulled a freshly-published package version and you need to
know if it's poisoned. The Shai-Hulud / Mini Shai-Hulud worm ships malicious
versions that live for only hours (axios 1.14.1 / 0.30.4 were live ~3h).

`npm audit` / `pip-audit` come back clean but you're uneasy — those are
CVE/advisory-driven and blind to malware that hasn't been reported yet. You want
behavioural analysis (new `postinstall` hooks, unexpected network calls,
obfuscated payloads), not a CVE lookup.

Setting up Socket.dev on a budget — the free `socket` CLI, the GitHub PR app, or
the `depscore` MCP for Claude Code (`claude mcp add --transport http socket-mcp
https://mcp.socket.dev/`, no API key). Deciding free vs paid tiers.

Auditing GitHub Actions for the stale-OIDC / `pull_request_target` misconfiguration
that Mini Shai-Hulud abused to mint npm publish tokens from an orphaned workflow.
`zizmor`, or `scripts/integrity-audit.sh`.

Hardening installs against `postinstall` / `preinstall` lifecycle-script malware —
`npm config set ignore-scripts true`, the `socket` wrapper, `lockfile-lint`, or the
`pre-install-scan.sh` hook.

Checking whether *this* machine is already compromised — detecting worm persistence
hooks injected into `~/.claude/settings.json`, `~/.claude.json`, or VS Code
`settings.json`. `scripts/integrity-audit.sh`.

Choosing among supply-chain scanners — when to reach for Socket vs GuardDog vs
OSV-Scanner vs zizmor vs Harden-Runner. See `references/tooling-landscape.md`.

Enforcing a release-age cooldown so production never pulls a day-zero version
(Renovate `minimumReleaseAge`), and rotating long-lived npm/PyPI publish tokens to
short-lived OIDC.

Responding to a fresh advisory — it names a poisoned package, version, or
**malicious VS Code / Cursor extension** and you need to know whether any project or
machine actually has it installed *right now*. `scripts/exposure-check.py` matches
on-disk npm / PyPI / Composer / Cargo / Go / RubyGems lockfiles **and installed
editor extensions** against an IOC catalog seeded with cited 2026 incidents (axios
1.14.1, Laravel-Lang tag rewrite, Nx Console 18.95.0 → the GitHub breach). For fleet-scale exposure response
on macOS/Linux, see Bumblebee in `references/tooling-landscape.md`.

Wanting proof the skill covers a specific attack — the
`references/threat-model.md` "Coverage" matrix maps every 2026 vector
(maintainer compromise, OIDC theft, lifecycle scripts, persistence hooks, forged
provenance, tag-rewrite, malicious extensions, MCP attacks) to its control + caveat.

## Overview

This skill is the operational complement to two siblings:

- **`security-ops`** is *reactive* — it runs `npm audit` / `pip-audit` /
  `govulncheck` against the **CVE/advisory database**. Necessary, but blind to a
  malicious package that hasn't been reported yet.
- **`supply-chain-defense`** (this skill) is *proactive* — it analyses what a
  freshly-published package actually **does** (new install scripts, network calls,
  obfuscation) within seconds of publication, before any CVE exists.

> The defensive gap is the window between "package published" and "advisory
> issued" — typically 30 minutes to 6 hours. A worm does real damage in that
> window. Behavioural analysis is the only control that closes it. See
> `references/threat-model.md` for why lockfiles, `npm audit`, 2FA, and even
> Sigstore/SLSA provenance were each bypassed in the wild in 2026.

## The four layers

| Layer | Control | What it stops |
|---|---|---|
| 1. Detection | Behavioural scanner (Socket.dev) on every dependency change | Poisoned package merged via PR or pulled by an install |
| 2. Interception | `socket` CLI wrapper + `pre-install-scan.sh` hook | Lifecycle scripts (`postinstall`, sdist `setup.py`) executing on install |
| 3. Hygiene | Stale-OIDC audit, dep cooldown, token rotation, extension audit | The *entry points* worms use to mint publish access |
| 4. Self-integrity + exposure | `integrity-audit.sh` (persistence hooks in AI-tool / editor configs) + `exposure-check.py` (am I running a named-bad package?) | Worm persistence on *this* machine; latent exposure to a fresh advisory |

## Cost reality — free is enough to start

**The Socket CLI is open-source and free. The free account tier defends against
this exact campaign at $0.** Paid tiers buy noise-reduction and scale, not the core
malware detection.

| Capability | Free ($0) | Paid (Team $25/dev → Enterprise) |
|---|---|---|
| `socket` CLI (open source) | ✅ | ✅ |
| Malware / behavioural blocking, 70+ risk types | ✅ | ✅ |
| Private repos (unlimited) | ✅ | ✅ |
| Scans / month | 1,000 | 5,000 → unlimited |
| Members | 3 | 10 → unlimited |
| **depscore MCP for Claude Code (no API key)** | ✅ | ✅ |
| Reachability analysis (cuts CVE false positives) | ❌ | ✅ (Team+) |
| SSO/SAML, SBOM, GitHub Actions + AI-model scanning | ❌ | ✅ (Business+) |
| OSS projects | Free **Team** account on request | — |

Start free. Move to Team only when CVE false-positive noise or seat count justifies
it. Full breakdown + exact commands in `references/socket-cli.md`.

## Setup (one-time)

All free, in priority order. The **scripts in this skill need no setup** — run them
directly. What you switch on is the live tooling:

1. **depscore MCP** — behavioural package scoring inside Claude Code, no API key:
   `claude mcp add --transport http socket-mcp https://mcp.socket.dev/`
2. **Install-scan hook** — advisory on every dependency install. Wire
   `pre-install-scan.sh` into `~/.claude/settings.json` (see "Hook setup" below);
   set `SUPPLY_CHAIN_BLOCK=1` for a hard gate. Restart Claude Code after editing.
3. **Socket CLI wrapper** (optional, zero-auth): `npm i -g socket`, then
   `socket npm install <pkg>` or `socket wrapper on`. `socket login` is only needed
   for `scan` / `score` / `ci`, not the install wrapper.
4. **Behavioural engine (optional, on-demand)** for `scan-extensions.sh --deep`:
   `uv tool install guarddog semgrep`. **Not installed by default** — stay lean.
   `--deep` auto-detects it; if absent, that mode runs inventory + recency and
   loudly recommends installing rather than reporting a scan it didn't run. On
   Windows GuardDog needs `PYTHONUTF8=1` (the script sets it for you).

Situational extras — install only when the need arises
(`references/tooling-landscape.md`): the behavioural engine above, OSV-Scanner (CVE
breadth), zizmor + Harden-Runner (CI hardening). The minimum viable set is Socket's
MCP + the cooldown + `ignore-scripts`; everything else is on-demand.

## Safety tiers

| Operation | Tier | Execution |
|---|---|---|
| Score / scan a package before adding it | T1 | Inline (depscore MCP or `socket package score`) |
| Detect project stack + installed tools | T1 | Inline |
| Run `integrity-audit.sh` (read-only) | T1 | Inline |
| Run `preinstall-check.sh` on a package spec | T1 | Inline |
| Behavioural scan of full manifest (`socket scan`) | T2 | Inline / background |
| Audit GitHub Actions for stale OIDC trust | T2 | Inline (read workflows) |
| **Install / upgrade a dependency** | T3 | Confirm + scan first |
| **Rotate publish tokens / revoke OIDC trust** | T3 | Confirm — changes live infra |
| **Remove a flagged persistence hook from settings** | T3 | Confirm — edits user config |

## Workflows

These map 1:1 to the briefing's recommended actions, ordered effort→value.

### A. Score a package before suggesting it (do this proactively)

When considering adding a dependency, get a behavioural verdict *first*:

- **With the depscore MCP** (free, no key): ask the `socket-mcp` server for the
  package score. Setup is a one-liner — see `references/socket-cli.md`.
- **With the CLI:** `socket package score <ecosystem> <name> <version>`
- **Cooldown check:** `scripts/preinstall-check.sh <pkg>[@version] …` flags any
  package published inside the 7-day cooldown window and routes to `socket` if
  installed.

Never recommend a brand-new (`@latest`, day-zero) release for a production path.

**Score the *whole* current project, not just one package** — the depscore MCP
takes a list, so read every dependency from the manifest and score them in one
call: parse `package.json` (`dependencies` + `devDependencies`), `requirements.txt`,
`composer.json`, `Cargo.toml`, etc., then pass the full `{depname, ecosystem,
version}` set to depscore. Triage anything with a low `supplyChain` / `quality`
score before the next install or commit. This is the highest-value recurring local
move — do it when opening a repo and after any dependency change.

### B. Trial Socket.dev on one repository (≈1 hour)

1. Pick the lowest-risk repo (small surface, low client exposure).
2. Install the **GitHub app** (free tier, private repos included) — it comments a
   risk report on any PR that adds/bumps a dependency.
3. Optionally `npm install -g socket && socket login` for terminal scanning.
4. Run for two weeks, review what it flags during PRs, then expand.

### C. Wrap installs at the terminal (layer 2)

Route risky installs through Socket so they're intercepted before lifecycle
scripts run:

- One-off: `socket npm install <pkg>` / `socket npx <pkg>`
- Workspace-wide: `socket wrapper on` (aliases `npm`/`npx` → routed through
  Socket; `socket wrapper off` to disable; `socket raw-npm` to bypass once).
- Claude Code reinforcement: enable the `pre-install-scan.sh` hook (advisory by
  default) — see Hook setup below.
- Cheapest possible mitigation — **disable lifecycle scripts entirely** where the
  project doesn't need them: `npm config set ignore-scripts true` (npm), or pnpm
  `enable-pre-post-scripts=false`. This neuters the `postinstall` vector outright.
- Validate the lockfile itself with `lockfile-lint` — catches a lockfile whose
  resolved URLs point at a non-registry host (lockfile injection). See
  `references/tooling-landscape.md`.

### D. Audit GitHub Actions for stale OIDC trust (≈half a day)

The Mini Shai-Hulud entry point was an **orphaned commit with live OIDC trust
federation** to npm. No phished human. Audit and revoke:

- Find workflows requesting an OIDC token: search for `id-token: write` and
  `permissions:` blocks, plus `npm publish` / `pypi` / `twine` / trusted-publisher
  steps. `scripts/integrity-audit.sh` flags these.
- For each: is publish trust still needed? If not, revoke the trust relationship
  on the registry side (npm trusted publisher / PyPI publisher) **and** remove the
  workflow permission.

### E. Pin and freeze production dependencies

Commit lockfiles. Pin exact versions for anything in CI/prod. Apply a **7-day
cooldown**: don't auto-update production deps until a release has aged a week, so
the ecosystem has time to detect and remediate a compromise. (Axios poisoned
versions were live ~3 hours — a 7-day lag would have caught it.)

### F. Rotate publish tokens → short-lived OIDC

Audit who holds standing npm/PyPI publish tokens. Prefer short-lived OIDC trusted
publishing over long-lived tokens. Rotate any long-lived token; tighten the set of
accounts with publish access. (T3 — confirm before rotating, it can break CI.)

### G. Editor extension / plugin audit (Nx Console / GitHub-breach vector)

Three layers, in order — known-bad, then visibility, then behavioural:

1. **Known-bad (IOC):** `python scripts/exposure-check.py` matches installed
   extensions (VS Code/Cursor/Windsurf/VSCodium) against the catalog — e.g. Nx
   Console `nrwl.angular-console@18.95.0`, the backdoor behind the GitHub
   3,800-repo breach. Catches what's already named in an advisory.
2. **Inventory + recency:** `bash scripts/scan-extensions.sh` lists every
   extension, Claude plugin (with pinned commit SHA), and skill, flagging what
   changed inside the recency window — the exact "no visibility into what's
   installed or how recently" gap the campaign exploits (Nx Console was live 11
   min). Zero-dependency, no false positives.
3. **Unknown-bad (behavioural):** `bash scripts/scan-extensions.sh --deep` runs
   GuardDog's semgrep rules against recently-changed extensions when `guarddog` +
   `semgrep` are present (`uv tool install guarddog semgrep`, on-demand — not kept
   installed). If absent it runs inventory only and recommends the install — never
   a false-clean. Best-effort on minified bundles — layers 1–2 stay the backbone for
   extensions; layer 3 is strongest on source (plugins/skills).

Verified-publisher status is **not** sufficient — Nx Console was a verified
publisher with 2.2M installs. Pause anything recently published by a non-verified
publisher until it ages.

### H. Self-integrity scan (layer 4 — the one the briefing didn't have to worry about)

Run `scripts/integrity-audit.sh`. It is **read-only** and reports:

- New/unexpected `hooks` or `mcpServers` entries in `~/.claude/settings.json`,
  `~/.claude/settings.local.json`, `~/.claude.json`, and project `.claude/`.
- Suspicious entries in VS Code `settings.json` (startup commands, task autoruns).
- Workflows with live OIDC publish trust (feeds workflow D).

A worm's persistence hook into Claude Code settings is the IOC from the briefing's
most-quoted line. If the scan flags something you didn't add, treat it as an
incident: isolate, rotate credentials, and investigate before continuing.

### I. Exposure response — "an advisory just dropped; are we running it?"

When an advisory names a poisoned package + version, the urgent question is which
projects/machines already have it. Match local state against an IOC catalog:

```bash
python scripts/exposure-check.py --root ~/code --root ~/work
python scripts/exposure-check.py --root . --json | jq '.data.findings[]'
```

It reads npm lockfiles and Python installed metadata (no execution, no network),
exits **10** if anything matches. The bundled `assets/exposure-catalog.json` is
seeded with cited 2026 IOCs (axios 1.14.1 / 0.30.4) and is meant to be **extended
from advisories** — add `{ecosystem, package, versions[]}` entries as incidents
break. A match is an incident: isolate, rotate, remove the package.

For **fleet-scale** exposure response across many macOS/Linux endpoints (with far
broader ecosystem + extension + MCP coverage), use Perplexity's **Bumblebee** —
whose catalog format this borrows. It does not run on Windows; `exposure-check.py`
is the cross-platform local equivalent. See `references/tooling-landscape.md`.

## Hook setup — two checkpoints for the two ways a dep enters

A dependency reaches a local machine two ways, and each gets an advisory hook:

- **`pre-install-scan.sh`** (PreToolUse / `Bash`) — fires on install verbs
  (`npm/pnpm/yarn/bun install|add`, `pip install`, `uv add`, `composer
  require|install|update`, `gem install`, `cargo add`). Surfaces the cooldown +
  `socket` equivalent. Set
  `SUPPLY_CHAIN_BLOCK=1` for a hard gate; otherwise advisory.
- **`manifest-dep-scan.sh`** (PostToolUse / `Write|Edit`) — fires when the agent
  *edits a manifest* (`package.json`, `requirements*.txt`, `composer.json`,
  `Cargo.toml`, `go.mod`, `Gemfile`, `pyproject.toml`) and the change adds a version
  spec — the Claude-Code path the install hook misses. Advises depscore + cooldown
  before install. High-signal: silent on version bumps / metadata edits.

Both read the tool call as JSON on stdin (`.tool_input`), falling back to `$1`.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"$HOME/.claude/hooks/pre-install-scan.sh\"", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [
        { "type": "command", "command": "bash \"$HOME/.claude/hooks/manifest-dep-scan.sh\"", "timeout": 5 } ] }
    ]
  }
}
```

## Anti-patterns

| Anti-pattern | Why it fails | Do instead |
|---|---|---|
| "We run `npm audit` in CI, we're covered." | Advisory-driven; blind to malware in the publish-to-CVE window — the exact gap the 2026 worms exploit. | Add a behavioural scan (Socket / GuardDog) gating the merge, not just a CVE check. |
| Trusting valid provenance / SLSA attestation as proof of safety. | Mini Shai-Hulud minted **valid Build L3 attestations** from stolen OIDC tokens. Valid ≠ safe. | Treat provenance as one signal; require behavioural verdict too. |
| Auto-updating production deps the day a release lands. | Poisoned versions live for hours; you become an early victim. | 7-day release-age cooldown (Renovate `minimumReleaseAge`). |
| Treating a verified-publisher VS Code extension as trustworthy. | Nx Console: verified publisher, 2.2M installs, backdoored. | Check publication recency; pause <7-day non-verified; audit on a schedule. |
| Leaving `id-token: write` on workflows that no longer publish. | The orphaned-OIDC entry point — a token minted from a stale workflow. | Revoke registry trust + drop the permission. Run `zizmor`. |
| Deleting a found persistence hook and moving on. | The worm stole credentials *before* it persisted; the hook is the symptom. | Treat as an incident: isolate, rotate every reachable credential, then investigate. |

## Verification checklist

- [ ] A behavioural verdict (not just `npm audit`) exists for every newly added/bumped dependency
- [ ] Production deps respect a release-age cooldown (≥7 days)
- [ ] Lockfiles committed; exact pins for anything in CI/prod
- [ ] No workflow carries `id-token: write` it doesn't need (`zizmor` clean)
- [ ] Long-lived publish tokens rotated or replaced with short-lived OIDC
- [ ] `scripts/integrity-audit.sh` exits 0 (no unexplained hooks/MCP servers in `.claude/` or VS Code settings)
- [ ] `ignore-scripts` enabled where lifecycle scripts aren't needed
- [ ] depscore MCP or `socket` CLI available so packages can be scored before they're suggested

## Scripts

All four follow the Axiom Tool Protocol: `--help` with EXAMPLES, `--json` for
machine-readable output, stdout = data / stderr = progress, semantic exit codes
(0 ok, 2 usage, 3 not-found, 4 invalid, 5 missing-dep, 7 unavailable, **10 = signal
found** — review items / inside-cooldown / exposed / behavioural finding).
Pipe-friendly: `--json | jq`.

**Dependencies.** The skill is markdown + bash and every script's *default* mode is
zero-dep (bash, coreutils, `curl`; `jq` only for `--json`). `scan-extensions.sh
--deep` auto-detects `guarddog`+`semgrep` and uses them when present; when absent it
runs inventory + recency and *loudly recommends* the on-demand install rather than
reporting a behavioural scan it never ran (which would be the same false-clean
GuardDog itself hits without semgrep). Nothing heavyweight is kept on the machine by
default. All named tools (socket, guarddog, semgrep, zizmor, OSV-Scanner) are an
optional *menu* — see `references/tooling-landscape.md` → "How the controls
interact" for the minimum viable set.

| Script | Purpose | Side effects |
|---|---|---|
| `scripts/integrity-audit.sh` | Scan AI-tool configs (Claude Code/Desktop, Gemini, MCP host JSON) + editor settings (VS Code, Cursor, Windsurf, VSCodium) for injected persistence hooks/MCP servers; flag workflows with live OIDC publish trust (uses `zizmor` if installed). Exit 10 if anything to review. | Read-only |
| `scripts/preinstall-check.sh` | Given package specs, report registry publish age (npm/PyPI), flag any inside the cooldown window, route to `socket` if available. Exit 10 if any inside cooldown. | Read-only (queries registries) |
| `scripts/exposure-check.py` | Match on-disk **npm (package-lock/pnpm/yarn) / PyPI / Composer / Cargo / Go / RubyGems** lockfiles **and installed editor extensions** against an IOC catalog (`assets/exposure-catalog.json`) — the "are we running a named-bad version/extension?" check. Supports a `*` wildcard for tag-rewrite attacks. Exit 10 if exposed. Catalog format borrowed from Bumblebee. | Read-only |
| `scripts/scan-extensions.sh` | **Unknown-bad** triage of installed editor extensions / Claude plugins / skills. Default = zero-dep **inventory + recency** (no false positives). `--deep` auto-detects `guarddog`+`semgrep`: runs the behavioural scan if present (exit 10 on a finding), else runs inventory only and *loudly recommends* the on-demand install — never a false-clean. | Read-only |

```bash
scripts/integrity-audit.sh --json | jq '.data.review[]'
scripts/preinstall-check.sh --pip requests fastapi@0.110.0 --json | jq '.data[] | select(.inside_cooldown)'
```

`tests/run.sh` is an offline-deterministic self-test (18 assertions) covering all
three scripts + the hook against crafted fixtures — run it after any edit:
`bash tests/run.sh` (exit 0 = all pass).

## Reference files

| File | Contents |
|---|---|
| `references/threat-model.md` | 2026 timeline (axios, Shai-Hulud, durabletask, Nx, GitHub breach), worm mechanics, IOCs, and why each legacy control failed |
| `references/socket-cli.md` | Accurate Socket CLI + depscore MCP command surface, free-vs-paid table, Claude Code setup, source links, briefing corrections |
| `references/tooling-landscape.md` | The wider (mostly free/OSS) defender ecosystem — GuardDog, OSV-Scanner, zizmor, Harden-Runner, lockfile-lint, `ignore-scripts` — mapped to the four layers, with a when-to-use-which matrix |
| `references/hardening-checklist.md` | Step-by-step OIDC audit, token rotation, dep cooldown policy, extension audit, persistence detection, client-proposal language |

## See also

| Skill | When to combine |
|---|---|
| `security-ops` | Reactive CVE/SAST/auth audit — run alongside; they solve different problems |
| `ci-cd-ops` | Hardening GitHub Actions, OIDC trusted publishing setup |
| `github-ops` | Release flow, repo security settings |
| `auth-ops` | Credential/token handling patterns after a rotation |
