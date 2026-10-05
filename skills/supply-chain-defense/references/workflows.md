# Supply Chain Defense: Workflows A-L

The full procedure behind each row of SKILL.md's "Which workflow?" table, ordered
effort -> value (they map 1:1 to the briefing's recommended actions). Paths are
relative to the skill folder. Run the `.py` scripts through
`bash scripts/run-python.sh` (it picks a Python 3.8+ that really runs; see
[scripts-and-hooks.md](scripts-and-hooks.md)) and the `.sh` scripts with `bash`.

## Contents

1. [A. Score a package before suggesting it (do this proactively)](#a-score-a-package-before-suggesting-it-do-this-proactively)
2. [B. Trial Socket.dev on one repository (≈1 hour)](#b-trial-socketdev-on-one-repository-1-hour)
3. [C. Wrap installs at the terminal (layer 2)](#c-wrap-installs-at-the-terminal-layer-2)
4. [D. Audit GitHub Actions for stale OIDC trust (≈half a day)](#d-audit-github-actions-for-stale-oidc-trust-half-a-day)
5. [E. Pin and freeze production dependencies](#e-pin-and-freeze-production-dependencies)
6. [F. Rotate publish tokens → short-lived OIDC](#f-rotate-publish-tokens--short-lived-oidc)
7. [G. Editor extension / plugin audit (Nx Console / GitHub-breach vector)](#g-editor-extension--plugin-audit-nx-console--github-breach-vector)
8. [H. Self-integrity scan (layer 4 — the one the briefing didn't have to worry about)](#h-self-integrity-scan-layer-4--the-one-the-briefing-didnt-have-to-worry-about)
9. [I. Exposure response — "an advisory just dropped; are we running it?"](#i-exposure-response--an-advisory-just-dropped-are-we-running-it)
10. [J. Outbound phone-home monitoring (Windows — the post-compromise tripwire)](#j-outbound-phone-home-monitoring-windows--the-post-compromise-tripwire)
11. [K. Post-install behavioural sweep — "is anything already on disk misbehaving?"](#k-post-install-behavioural-sweep--is-anything-already-on-disk-misbehaving)
12. [L. Repo-integrity / config-drift — "is a repo I *own* being poisoned in place?"](#l-repo-integrity--config-drift--is-a-repo-i-own-being-poisoned-in-place)

## A. Score a package before suggesting it (do this proactively)

When considering adding a dependency, get a behavioural verdict *first*:

- **With the depscore MCP** (free, no key): ask the `socket-mcp` server for the
  package score. Setup is a one-liner — see [socket-cli.md](socket-cli.md).
- **With the CLI:** `socket package score <ecosystem> <name> <version>`
- **Cooldown check:** `bash scripts/preinstall-check.sh <pkg>[@version] …` flags any
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

## B. Trial Socket.dev on one repository (≈1 hour)

1. Pick the lowest-risk repo (small surface, low client exposure).
2. Install the **GitHub app** (free tier, private repos included) — it comments a
   risk report on any PR that adds/bumps a dependency.
3. Optionally `npm install -g socket && socket login` for terminal scanning.
4. Run for two weeks, review what it flags during PRs, then expand.

## C. Wrap installs at the terminal (layer 2)

Route risky installs through Socket so they're intercepted before lifecycle
scripts run:

- One-off: `socket npm install <pkg>` / `socket npx <pkg>`
- Workspace-wide: `socket wrapper on` (aliases `npm`/`npx` → routed through
  Socket; `socket wrapper off` to disable; `socket raw-npm` to bypass once).
- Claude Code reinforcement: enable the `pre-install-scan.sh` hook (advisory by
  default) — see [scripts-and-hooks.md](scripts-and-hooks.md#hook-setup--two-checkpoints-for-the-two-ways-a-dep-enters).
- Cheapest possible mitigation — **disable lifecycle scripts entirely** where the
  project doesn't need them: `npm config set ignore-scripts true` (npm), or pnpm
  `enable-pre-post-scripts=false`. This neuters the `postinstall` vector outright.
- Validate the lockfile itself with `lockfile-lint` — catches a lockfile whose
  resolved URLs point at a non-registry host (lockfile injection). See
  [tooling-landscape.md](tooling-landscape.md).

## D. Audit GitHub Actions for stale OIDC trust (≈half a day)

The Mini Shai-Hulud entry point was an **orphaned commit with live OIDC trust
federation** to npm. No phished human. Audit and revoke:

- Find workflows requesting an OIDC token: search for `id-token: write` and
  `permissions:` blocks, plus `npm publish` / `pypi` / `twine` / trusted-publisher
  steps. `scripts/integrity-audit.sh` flags these.
- For each: is publish trust still needed? If not, revoke the trust relationship
  on the registry side (npm trusted publisher / PyPI publisher) **and** remove the
  workflow permission.

## E. Pin and freeze production dependencies

Commit lockfiles. Pin exact versions for anything in CI/prod. Apply a **7-day
cooldown**: don't auto-update production deps until a release has aged a week, so
the ecosystem has time to detect and remediate a compromise. (Axios poisoned
versions were live ~3 hours — a 7-day lag would have caught it.)

## F. Rotate publish tokens → short-lived OIDC

Audit who holds standing npm/PyPI publish tokens. Prefer short-lived OIDC trusted
publishing over long-lived tokens. Rotate any long-lived token; tighten the set of
accounts with publish access. (T3 — confirm before rotating, it can break CI.)

## G. Editor extension / plugin audit (Nx Console / GitHub-breach vector)

Three layers, in order — known-bad, then visibility, then behavioural:

1. **Known-bad (IOC):** `bash scripts/run-python.sh scripts/exposure-check.py` matches installed
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

## H. Self-integrity scan (layer 4 — the one the briefing didn't have to worry about)

Run `bash scripts/integrity-audit.sh`. It is **read-only** and reports:

- New/unexpected `hooks` or `mcpServers` entries in `~/.claude/settings.json`,
  `~/.claude/settings.local.json`, `~/.claude.json`, and project `.claude/`.
- Suspicious entries in VS Code `settings.json` (startup commands, task autoruns).
- Workflows with live OIDC publish trust (feeds workflow D).

A worm's persistence hook into Claude Code settings is the IOC from the briefing's
most-quoted line. If the scan flags something you didn't add, treat it as an
incident: isolate, rotate credentials, and investigate before continuing.

## I. Exposure response — "an advisory just dropped; are we running it?"

When an advisory names a poisoned package + version, the urgent question is which
projects/machines already have it. Match local state against an IOC catalog:

```bash
bash scripts/run-python.sh scripts/exposure-check.py --root ~/code --root ~/work
bash scripts/run-python.sh scripts/exposure-check.py --root . --json | jq '.data.findings[]'
```

It reads npm lockfiles and Python installed metadata (no execution, no network),
exits **10** if anything matches. The bundled `assets/exposure-catalog.json` is
seeded with cited 2026 IOCs (axios 1.14.1 / 0.30.4) and is meant to be **extended
from advisories** — add `{ecosystem, package, versions[]}` entries as incidents
break. A match is an incident: isolate, rotate, remove the package.

For **fleet-scale** exposure response across many macOS/Linux endpoints (with far
broader ecosystem + extension + MCP coverage), use Perplexity's **Bumblebee** —
whose catalog format this borrows. It does not run on Windows; `exposure-check.py`
is the cross-platform local equivalent. See [tooling-landscape.md](tooling-landscape.md).

## J. Outbound phone-home monitoring (Windows — the post-compromise tripwire)

Layers 1–4 act at install time or at rest; nothing above watches what running code
*does on the network*. `scripts/phone-home-monitor.ps1` closes that gap:

```powershell
pwsh -NoProfile -File scripts/phone-home-monitor.ps1            # one snapshot, exit 10 on findings
pwsh -NoProfile -File scripts/phone-home-monitor.ps1 -Status    # which capture sources exist here?
pwsh -NoProfile -File scripts/phone-home-monitor.ps1 -Watch -IntervalSeconds 30   # continuous, ring-buffer log
pwsh -NoProfile -File scripts/phone-home-monitor.ps1 -InstallTask                 # logon daemon (T3 — confirm)
```

Flags: IOC endpoints (`assets/network-ioc.json` — webhook.site is the cited
Shai-Hulud exfil drop), binaries under `node_modules`/Temp, children of package
managers (lifecycle-script behaviour), interpreters hitting raw public IPs,
unsigned userland binaries. **Tool-first:** the preferred continuous source is
Sysmon Event ID 3 with the SwiftOnSecurity config (`-Sysmon` consumes it; exit 5
with the install one-liner when absent); TCP-table polling is the zero-install
default. Full evaluation (Sysmon vs WFP 5156 vs polling vs tshark), wiring, and
triage playbook: [phone-home-monitoring.md](phone-home-monitoring.md). A finding routes back into
H/I: `integrity-audit.sh` + `exposure-check.py` + credential rotation.

## K. Post-install behavioural sweep — "is anything already on disk misbehaving?"

`exposure-check.py` (workflow I) answers the *known-bad* question; this answers the
*unknown-bad* one. `scripts/postinstall-audit.py` walks installed `node_modules` and
Python `site-packages` and flags what packages actually *do* — not what an advisory
named:

```bash
bash scripts/run-python.sh scripts/postinstall-audit.py --root ~/code              # exit 10 on a finding
bash scripts/run-python.sh scripts/postinstall-audit.py --root . --json | jq '.data.findings[]'
bash scripts/run-python.sh scripts/postinstall-audit.py --root . --deep            # GuardDog confirms each flag
bash scripts/run-python.sh scripts/postinstall-audit.py --root . --live            # is a flagged npm version still published?
```

It flags shell/downloader lifecycle scripts, credential-path reads paired with exfil
endpoints, env harvesting, obfuscation, persistence writes, and files modified after
install. Findings need a **two-signal combo** (cred+net, env+net) so real `node_modules`
trees don't false-alarm — the lesson from an earlier cut that lit up `three.js`/`vite`
on `eval`+base64 alone. An **incremental fingerprint cache** makes it daily-runnable
(only changed trees rescan), so wire it as a scheduled task — see
[postinstall-audit.md](postinstall-audit.md) for the Task Scheduler / Claude Code cron recipes and
the GuardDog/OSV/Socket tool evaluation. A high finding is an incident: isolate → read
the flagged file → rotate credentials → confirm with `--deep` + `exposure-check.py`.

## L. Repo-integrity / config-drift — "is a repo I *own* being poisoned in place?"

Workflows A–K all defend the **dependency tree** (or watch its network egress). This
one defends a different surface: the **trusted-repo / config-as-code** class
(PolinRider / EtherHiding, DPRK UNC5342), where the dependency tree stays clean and
the payload is committed into your own build configs. The dependency scanners are
structurally blind to it — see SKILL.md's layer table and
[threat-model.md](threat-model.md) vector #12.

`scripts/config-drift-check.py` is the on-disk detector. Run it two ways:

```bash
bash scripts/run-python.sh scripts/config-drift-check.py --root .             # CI / full-repo sweep, exit 10 on finding
bash scripts/run-python.sh scripts/config-drift-check.py --staged             # pre-commit: only staged config files
bash scripts/run-python.sh scripts/config-drift-check.py --root . --json | jq '.data.findings[]'
```

It scans build configs (`vite/tailwind/webpack/next/rollup/postcss/svelte/astro.config.*`),
`.vscode/tasks.json`, and `package.json` scripts for the Stage-2 injection signatures:
blockchain explorer-API / RPC dead-drop endpoints (the EtherHiding payload read —
`assets/network-ioc.json` `ETHERHIDING-BLOCKCHAIN-C2`), `eval` / `new Function` /
shell-exec, Buffer-XOR decode loops, outbound network in a config that shouldn't have
any, hex-var (`_0x..`) / long-escape obfuscation, an obfuscated appended blob, and
`tasks.json` `runOn:folderOpen` auto-run. Zero-dependency, read-only.

Wire it as a **pre-commit hook** (`--staged`, catches it before it's committed) **and**
a **CI status check** (catches a force-pushed injection at the gate). A finding is an
incident: read the flagged file, check the commit's **signature + server-side push
timestamp** (a backdated author date lies; the push event doesn't), and rotate any
credential the build could have touched.

The detector is half the defense. The other half is **prevention + attribution** —
no shared/standing keys, hardware-backed signing keys a RAT can't read, branch
protection requiring **signed** commits and blocking force-push, server-side push-log
as ground truth, build/env isolation, and VS Code Workspace Trust with auto-run tasks
disabled. The full kill-chain-mapped playbook is [repo-integrity.md](repo-integrity.md).
