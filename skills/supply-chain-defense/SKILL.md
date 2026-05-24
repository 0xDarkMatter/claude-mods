---
name: supply-chain-defense
description: "Behavioural-first software supply chain defense - catches poisoned npm/PyPI packages in the publish-to-advisory window that CVE tools miss. Socket.dev integration (free CLI + GitHub app + depscore MCP for Claude Code), stale-OIDC audit, dependency cooldown policy, publish-token rotation, VS Code extension audit, and a self-integrity scan that detects worm persistence hooks injected into Claude Code / VS Code settings. Triggers on: supply chain, supply chain attack, malicious package, poisoned dependency, npm worm, Shai-Hulud, behavioural scanning, Socket.dev, socket scan, dependency security, postinstall malware, OIDC token theft, compromised maintainer, typosquat, dependency confusion, package provenance, SLSA, persistence hook, malicious VS Code extension."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent WebFetch"
metadata:
  author: claude-mods
  related-skills: security-ops, ci-cd-ops, github-ops, auth-ops
---

# Supply Chain Operations

Proactive, behavioural-first defense against the 2026 software supply chain threat:
self-propagating worms (Shai-Hulud / Mini Shai-Hulud) that poison popular npm and
PyPI packages, steal credentials, republish from stolen tokens, and inject
persistence hooks into **Claude Code and VS Code settings** specifically.

## Helps with

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

Responding to a fresh advisory — it names a poisoned package + version and you need
to know whether any project or machine actually has it installed *right now*.
`scripts/exposure-check.py` matches your on-disk lockfiles / installed packages
against an IOC catalog (seeded with 2026 incidents like axios 1.14.1 / 0.30.4). For
fleet-scale exposure response on macOS/Linux, see Bumblebee in
`references/tooling-landscape.md`.

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

### G. VS Code extension audit

List installed extensions and check publication recency:
`code --list-extensions --show-versions`. Anything published in the last 7 days
from a non-verified publisher should be paused until it ages. The GitHub breach
(3,800 repos) and the Nx Console backdoor (2.2M installs, verified publisher) both
came through extensions — verified status is **not** sufficient.

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

## Hook setup — `pre-install-scan.sh`

Advisory PreToolUse hook on `Bash`. It recognises install verbs
(`npm/pnpm/yarn install|add`, `pip install`, `uv add/pip install`,
`composer require`, `gem install`, `cargo add`) and surfaces the cooldown policy +
the `socket` equivalent before the command runs. It does **not** block by default
(preserves muscle memory). Set `SUPPLY_CHAIN_BLOCK=1` to make it a hard gate.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/pre-install-scan.sh\"", "timeout": 5 }
        ]
      }
    ]
  }
}
```

The hook reads the tool call as JSON on stdin (`.tool_input.command`) on current
Claude Code, and falls back to `$1` for older configs. For a hard gate, set
`SUPPLY_CHAIN_BLOCK=1` in the environment Claude Code runs under.

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

All three follow the Axiom Tool Protocol: `--help` with EXAMPLES, `--json` for
machine-readable output, stdout = data / stderr = progress, semantic exit codes
(0 ok, 2 usage, 3 not-found, 4 invalid, 5 missing-dep, 7 unavailable, **10 = signal
found** — review items / inside-cooldown / exposed). Pipe-friendly: `--json | jq`.

**No hard tool dependencies.** The skill is markdown + bash; the scripts need only
baseline tooling (bash, coreutils, `curl`; `jq` only for `--json`). Every
supply-chain tool named in this skill (socket, zizmor, guarddog, …) is optional —
`command -v`-gated with graceful fallback. The named tools are a *menu*, not a
required stack; see `references/tooling-landscape.md` → "How the controls interact"
for the minimum viable set and what's redundant vs complementary.

| Script | Purpose | Side effects |
|---|---|---|
| `scripts/integrity-audit.sh` | Scan AI-tool configs (Claude Code/Desktop, Gemini, MCP host JSON) + editor settings (VS Code, Cursor, Windsurf, VSCodium) for injected persistence hooks/MCP servers; flag workflows with live OIDC publish trust (uses `zizmor` if installed). Exit 10 if anything to review. | Read-only |
| `scripts/preinstall-check.sh` | Given package specs, report registry publish age (npm/PyPI), flag any inside the cooldown window, route to `socket` if available. Exit 10 if any inside cooldown. | Read-only (queries registries) |
| `scripts/exposure-check.py` | Match on-disk npm/PyPI installed packages against an IOC catalog (`assets/exposure-catalog.json`) — the "are we running a named-bad version?" check. Exit 10 if exposed. Catalog format borrowed from Bumblebee. | Read-only |

```bash
scripts/integrity-audit.sh --json | jq '.data.review[]'
scripts/preinstall-check.sh --pip requests fastapi@0.110.0 --json | jq '.data[] | select(.inside_cooldown)'
```

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
