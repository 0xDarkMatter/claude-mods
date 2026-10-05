---
name: supply-chain-defense
description: "Behavioural-first defense against poisoned npm/PyPI/Composer/Cargo packages, malicious editor extensions and config-as-code repo poisoning, in the publish-to-advisory window CVE tools miss. Use when adding or bumping a dependency, when an advisory names a package you may run, when auditing CI OIDC trust or publish tokens, or when checking a machine or repo for worm persistence: 7-day cooldown gate, Socket.dev score, exposure and integrity scans."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent WebFetch"
metadata:
  author: claude-mods
  related-skills: security-ops, ci-cd-ops, github-ops, auth-ops, package-manager-ops
---

# Supply Chain Defense

Behavioural-first defense against the 2026 supply-chain worms (Shai-Hulud / Mini
Shai-Hulud): they poison popular npm and PyPI packages, steal credentials, republish
from stolen tokens, and plant persistence hooks in **Claude Code and VS Code
settings**. `security-ops` is the reactive half (`npm audit` / `pip-audit` against
the CVE database); this skill is the proactive half and judges what a fresh package
*does*. The gap it closes is the 30-minute-to-6-hour window between "published" and
"advisory issued" - `references/threat-model.md` shows how lockfiles, `npm audit`,
2FA and even Sigstore/SLSA provenance were each bypassed in 2026.

Every install or version bump is a use case, not just a suspected attack: the
routine below is the point.

## The routine: every install or version bump

1. **Score it** before you suggest or add it: the depscore MCP (free, no key) or
   `socket package score <eco> <name> <version>`. Score the whole manifest, not just
   the new package - depscore takes a list.
2. **Age it**: `bash scripts/preinstall-check.sh <pkg>[@ver] ...` (`--pip`,
   `--composer`, `--cargo`, `--go`); exit 10 = published inside the 7-day cooldown.
   Never suggest a day-zero (`@latest`) release for a production path.
3. **Install behind a gate**: `socket npm install <pkg>`, or no lifecycle scripts at
   all (`npm config set ignore-scripts true`).
4. **Pin it**: commit the lockfile; exact versions for anything in CI/prod.
5. **Don't stop at a clean `npm audit`** - it only knows yesterday's CVEs.

## Which workflow?

Step-by-step for each letter: `references/workflows.md`.

| Situation | Workflow | First move |
|---|---|---|
| About to add or bump a dependency | A, E | The routine above |
| A teammate or CI just pulled a fresh version (axios 1.14.1 was live ~3 h) | A, I | Score it, then `exposure-check.py` |
| `npm audit` / `pip-audit` clean but you're uneasy | A, K | Behavioural score + `postinstall-audit.py` |
| Rolling out Socket.dev on a budget | B | GitHub app + depscore MCP (both free) |
| Install commands need a gate | C | `socket` wrapper, `ignore-scripts`, `lockfile-lint` |
| CI publishes to npm/PyPI | D, F | `integrity-audit.sh` or `zizmor`; revoke stale OIDC trust; rotate to short-lived OIDC |
| Production deps auto-update | E | Renovate `minimumReleaseAge: 7 days` |
| Editor extensions, Claude plugins, skills | G | `exposure-check.py`, then `scan-extensions.sh [--deep]` |
| Is this machine already compromised? | H | `integrity-audit.sh` (hooks, MCP servers, shell rc, `.npmrc`) |
| An advisory names a package or extension | I | `exposure-check.py --root <dirs>` (exit 10 = exposed) |
| An unexplained UAC prompt or process you can't place; a post-compromise tripwire (Windows) | J | `phone-home-monitor.ps1` (stealers exfiltrate as outbound connections) |
| Is anything already on disk misbehaving? | K | `postinstall-audit.py --root <dirs>` |
| A repo you own is poisoned in place (build config, `tasks.json`) | L | `config-drift-check.py --staged` / `--root .` |
| Which scanner for which job? | - | `references/tooling-landscape.md` |
| Proof the skill covers a given attack | - | Coverage matrix in `references/threat-model.md` |

A finding from H-L is an incident: isolate the machine, rotate every credential it
could read, then investigate. Removing the hook or package alone treats a symptom -
the credentials were stolen before the worm persisted.

## Running the scripts

Paths are relative to this skill folder. Launch the `.py` scripts through
`scripts/run-python.sh`: it runs the first of `python3`, `python`, `py` that really
is Python 3.8+ (on Windows `python3` is often the Microsoft Store alias, which exits
49 and runs nothing - the scripts' shebang hits it too). Shared exit codes: 0 ok,
2 usage, 3 not found, 5 missing dependency, 7 unavailable, **10 = finding** (review
item / inside cooldown / exposed / behavioural hit). Every script takes `--json`;
stdout is data, stderr is progress.

| Script | Answers | Run |
|---|---|---|
| `preinstall-check.sh` | Is this release inside the cooldown? | `bash scripts/preinstall-check.sh --pip requests fastapi@0.110.0` |
| `integrity-audit.sh` | Has a worm persisted in AI-tool, editor, shell or package-manager config? Live OIDC publish trust? | `bash scripts/integrity-audit.sh --json \| jq '.data.review[]'` |
| `exposure-check.py` | Is a named-bad package or extension installed? (`assets/exposure-catalog.json`) | `bash scripts/run-python.sh scripts/exposure-check.py --root ~/code` |
| `postinstall-audit.py` | Is any installed package *behaving* like malware? | `bash scripts/run-python.sh scripts/postinstall-audit.py --root . [--deep] [--live]` |
| `config-drift-check.py` | Does a build config or `tasks.json` carry an injected loader? | `bash scripts/run-python.sh scripts/config-drift-check.py --staged` |
| `scan-extensions.sh` | Which extensions, plugins and skills changed recently? | `bash scripts/scan-extensions.sh [--deep]` |
| `phone-home-monitor.ps1` | What connects out, from which process? (Windows) | `pwsh -NoProfile -File scripts/phone-home-monitor.ps1 [-Sysmon] [-Watch]` |

All are read-only except `phone-home-monitor.ps1 -InstallTask` (registers a logon
task - T3). Flags, dependencies and side effects per script:
`references/scripts-and-hooks.md`. After any edit run `bash tests/run.sh` (offline;
exit 0 = all pass).

## Setup (one-time, all free)

The scripts need no setup. What you switch on is the live tooling, in priority order:

1. **depscore MCP** - behavioural package scoring inside Claude Code, no API key:
   `claude mcp add --transport http socket-mcp https://mcp.socket.dev/`
2. **Install hooks** (optional; they ship with claude-mods, not in this folder):
   `pre-install-scan.sh` + `manifest-dep-scan.sh`, advisory by default,
   `SUPPLY_CHAIN_BLOCK=1` for a hard gate. Wiring: `references/scripts-and-hooks.md`.
3. **Socket CLI wrapper** (zero-auth): `npm i -g socket`, then
   `socket npm install <pkg>` or `socket wrapper on`. `socket login` is only needed
   for `scan` / `score` / `ci`.
4. **Behavioural engine (on demand)** for `--deep`: `uv tool install guarddog semgrep`.
   Not installed by default; `--deep` says loudly when it is missing instead of
   reporting a scan it never ran. On Windows GuardDog needs `PYTHONUTF8=1` (the
   script sets it).

The free Socket tier covers this whole campaign; paid tiers buy reachability and
seats, not detection (`references/socket-cli.md`). The minimum viable set is the
depscore MCP + the cooldown + `ignore-scripts`; OSV-Scanner, zizmor and Harden-Runner
are situational (`references/tooling-landscape.md`).

## Portability

This folder runs when copied alone: scripts, `assets/` catalogs, references, the
launcher and `tests/run.sh` are all inside it. Two things are optional and live
outside it, in claude-mods: the `skills/_lib/term.sh` panels (without them the
scripts print plain ASCII framing, same data and exit codes) and the hooks above.
`tests/run.sh` copies the folder alone and proves it. Details:
`references/scripts-and-hooks.md`.

## The layers

Layers 1-5 ask "is a package I pull malicious?". Layer 6 is a different axis - "is
a repo I already own being poisoned in place?" - where the payload never enters as a
package, so every dependency scanner is structurally blind to it.

| Layer | Control | What it stops |
|---|---|---|
| 1. Detection | Socket.dev behavioural scan on every dependency change | Poisoned package merged via PR or pulled by an install |
| 2. Interception | `socket` wrapper, `ignore-scripts`, install hook | Lifecycle scripts (`postinstall`, sdist `setup.py`) running on install |
| 3. Hygiene | Stale-OIDC audit, cooldown, token rotation, extension audit | The entry points worms use to mint publish access |
| 4. Self-integrity + exposure | `integrity-audit.sh`, `exposure-check.py` | Persistence on *this* machine; exposure to a fresh advisory |
| 5. Post-install behaviour | `postinstall-audit.py`, `phone-home-monitor.ps1` | A poisoned release already on disk or exfiltrating |
| 6. Repo integrity | `config-drift-check.py` + signed commits, no force-push, no shared keys | Config-as-code poisoning (PolinRider / EtherHiding) behind a clean dependency tree |

Layers 1-3 act before code runs; 4-5 assume something got through and hunt for it.
`exposure-check.py` answers "do I have a *named-bad* package?"; `postinstall-audit.py`
answers "is *any* installed package behaving like malware?" - the unknown-bad case.
Layer 6 playbook: `references/repo-integrity.md`.

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

## References

| File | Load when |
|---|---|
| `references/workflows.md` | Running any workflow A-L step by step |
| `references/scripts-and-hooks.md` | Per-script flags and side effects, the launcher, hook wiring, what the folder needs when copied alone |
| `references/threat-model.md` | The 2026 timeline, worm mechanics, IOCs, why legacy controls failed, the coverage matrix |
| `references/socket-cli.md` | Socket CLI + depscore MCP commands; free vs paid tiers |
| `references/tooling-landscape.md` | Choosing among Socket, GuardDog, OSV-Scanner, zizmor, Harden-Runner, lockfile-lint; how they interact; the minimum viable set |
| `references/tooling-by-layer.md` | Per-tool commands and verified gotchas (GuardDog on Windows, `ignore-scripts` limits, Bumblebee) |
| `references/hardening-checklist.md` | A step-by-step hardening pass: OIDC audit, token rotation, cooldown policy, extension audit, client-facing language |
| `references/postinstall-audit.md` | Behavioural-scan findings and severities, the false-positive lesson, the cache, `--deep` / `--live`, daily scheduling |
| `references/phone-home-monitoring.md` | Sysmon vs WFP vs polling, wiring, the rule table, triage, limits |
| `references/repo-integrity.md` | Config-as-code kill chain, keys, branch protection + signed commits, audit log as ground truth, checklist |
| `references/repo-integrity-response.md` | Isolation, Workspace Trust, the `config-drift-check.py` gate, containment scope |

## See also

| Skill | When to combine |
|---|---|
| `security-ops` | Reactive CVE/SAST/auth audit — run alongside; they solve different problems |
| `ci-cd-ops` | Hardening GitHub Actions, OIDC trusted publishing setup |
| `github-ops` | Release flow, repo security settings |
| `auth-ops` | Credential/token handling patterns after a rotation |
| `package-manager-ops` | Day-to-day manager use this skill's policy sits on: frozen installs, lockfile hygiene, pinned npx, approving a dependency's build script |
