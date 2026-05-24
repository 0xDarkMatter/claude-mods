# 2026 Supply Chain Threat Model

Distilled from the "Sandworms in the Registry" briefing (May 2026) and the public
incident reporting it cites. This is the *why* behind every directive in the
skill and the `supply-chain.md` rule.

## The shift in attacker behaviour (last 90 days)

Attackers stopped typosquatting and moved to compromising packages you *actually
use*. The pattern:

1. Compromise a maintainer account, **or** steal an OIDC token from a stale CI
   workflow.
2. Publish a poisoned version of a real, popular package (axios, an official MS
   SDK, TanStack, …).
3. Malware runs on `npm install` / `pip install`. It steals every credential on
   the machine, then uses those credentials to publish more poisoned packages —
   **it self-propagates**. It targets VS Code and Claude Code specifically and
   writes itself into editor settings to survive reboots.
4. By the time a CVE is published, it has been in `node_modules` for hours.

## Timeline of named incidents

| Date | Incident | Mechanism | Why it matters |
|---|---|---|---|
| 30–31 Mar 2026 | **axios** (100M weekly downloads) | Maintainer socially engineered, machine RAT'd, attacker manually published 1.14.1 / 0.30.4 with a stolen token in a 39-min window; live ~3 hours. Attributed to Sapphire Sleet (NK state actor). | Bypassed GitHub Actions OIDC Trusted Publisher safeguards by publishing manually. Every control depending on maintainer hygiene failed at once. |
| Sep 2025 → present | **Shai-Hulud** | Self-propagating npm worm using lifecycle scripts to execute on install, harvest credentials, and republish using them. | The wormable baseline. |
| 11 May 2026 | **Mini Shai-Hulud** (TeamPCP) — 170+ npm/PyPI packages (TanStack, Mistral AI, OpenSearch) | Entry point was an **orphaned commit in a TanStack CI workflow still configured with OIDC trust to npm**. Attacker extracted an OIDC token from the runner and exchanged it for publish access to the whole namespace. Forged **valid SLSA Build L3 provenance**. Injects persistence hooks into Claude Code + VS Code. | No phished human. A stale CI workflow was enough. Each infected `npm install` contributed CI creds the worm used to publish from *that* victim's pipeline. Blast radius compounds per install. |
| 18 May 2026 | **Nx Console** VS Code extension (2.2M installs, verified publisher) | Briefly backdoored; collected credentials silently on opening any workspace. Auto-update pushed it to most users. | Verified-publisher status is not a safety signal. |
| 19 May 2026 | **Microsoft `durabletask`** PyPI SDK | 3 malicious versions built locally and uploaded via `twine`. Dropper downloads a 28KB stage-2 zipapp (`rope.pyz`), steals AWS/Azure/GCP/k8s/password-manager creds + 90+ tool configs, spreads laterally. | **No provenance on any `durabletask` release**, legit or malicious — PyPI returns "No provenance available". Even MS official SDKs have zero cryptographic baseline. |
| 19 May 2026 | **AntV wave** (TeamPCP) | 300+ malicious versions across 323 packages in a 22-minute automated burst (~16M weekly downloads). Compromised maintainer account. | 323 packages in 22 minutes — the worm's speed advantage over human review. |
| 19–20 May 2026 | **GitHub internal breach** | ~3,800 internal repos breached after one employee installed a poisoned VS Code extension. | If it happens to GitHub (their budget, their threat intel), it happens to anyone. Developer workstations are the #1 target. |

## Why each legacy control fails

| Control | Why it does **not** catch this |
|---|---|
| Lockfiles (`package-lock.json`, `composer.lock`) | Pin versions but don't validate behaviour. A fresh unconstrained install can still pull the malicious `latest`. Pinning only protects if the pin pre-dates the compromise *and* you never run unconstrained installs. |
| `npm audit` / `pip-audit` | Rely on CVE/NVD advisories, which largely don't cover *malicious* packages and are published *after* detection. In wormable attacks the malicious version is often the newest, spreading before any signature exists. |
| 2FA on maintainer accounts | Bypassed in Mini Shai-Hulud via OIDC token exchange from CI. No human touched the 2FA prompt. |
| Code signing / provenance (Sigstore, SLSA) | Forged. Stolen OIDC tokens drove the legitimate Sigstore stack to mint **valid Build L3 attestations** for malicious packages. Valid provenance ≠ safe. |
| Snyk / CVE-based SCA | Excellent at CVEs; not designed to detect zero-day malicious behaviour in a freshly published package. Different problem. |
| Manual dependency review | Does not scale to hundreds of transitive deps and every `postinstall` hook. |

**The gap:** the window between "published to registry" and "malicious behaviour
detected + advisory issued" — typically 30 min to 6 hours. Only behavioural
analysis of what the package *does* (new install scripts, unexpected network
calls, env-var harvesting, obfuscated payloads) closes it, because those signals
are present at publication time; CVE assignment takes days.

## Indicators of compromise (what behavioural scanners flag)

- A `postinstall` / `preinstall` / `prepare` hook that did **not** exist in the
  previous version.
- A sudden network call to a domain not previously associated with the package.
- A new dependency on a credential-adjacent or obfuscation helper (the attacks
  used droppers like `rope.pyz`, plain-crypto helpers, etc.).
- Obfuscated / minified payloads in a package that previously shipped readable
  source.
- Writes to `~/.claude/settings.json`, `~/.claude.json`, VS Code `settings.json`,
  or shell rc files during install (persistence).
- Reads of cloud credential files (`~/.aws`, `~/.config/gcloud`, kube configs),
  `.npmrc` / `.pypirc` (publish tokens), or password-manager stores.

## What the next 12 months look like

- More wormable variants targeting Composer, RubyGems, Cargo, Maven Central.
- More direct attacks on developer tooling: extensions, MCP servers, **AI agent
  skills** (Socket benchmarked its detector against 382 known-malicious skills).
- More attacks on AI-adjacent packages specifically — OpenAI/Anthropic keys and
  hosted-model cloud creds on AI builders' machines have immediate cash value.
- Harder procurement/insurance questions. "We use behavioural package scanning on
  every dependency change" becomes a standard security-questionnaire answer.

The worm source is public (TeamPCP ran a $1,000 Monero "supply chain attack
contest" on BreachForums with the source attached); copycats are already
observed. A behavioural scanning control is not optional 18 months out — move
while the cost is hours and a few hundred dollars a month, or $0 on the free tier.
