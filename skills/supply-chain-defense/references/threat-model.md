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
| 22 May 2026 | **Laravel-Lang** (Composer/Packagist) | ~700 historical git tags across 4 packages (`laravel-lang/lang`, `/attributes`, `/http-statuses`, `/actions`) **rewritten** to point at a malicious commit in an attacker fork. Payload injected into Composer `autoload.files` (`helpers.php`) — runs on every PHP request. Credential stealer (cloud keys, CI tokens, SSH, env, wallets). | Composer/PHP is in scope too. Two nasty firsts below. |

### Why the Laravel-Lang pattern defeats naive defenses

- **Tag rewriting, not new versions.** The attacker rewrote *existing historical
  tags* to new commits. So the "bad version" carries an **old, aged version number**
  — a release-age **cooldown keys off publish date and is fooled**. Every version is
  suspect, which is why the IOC catalog uses `versions:["*"]` for it.
- **`autoload.files`, not a lifecycle script.** The payload runs via Composer's
  autoloader on every request — **`composer install --no-scripts` does NOT stop it**
  (it's not a script hook). The npm-world `ignore-scripts` reflex fails here.
- **What actually protects you:** a **committed `composer.lock` that predates the
  compromise** — it pins the dist URL + reference SHA + integrity, so `composer
  install` from it won't pull the rewritten tag. The danger is `composer update`,
  an unpinned fresh `composer install`, or a lock generated after the rewrite.

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

## Coverage — which control catches which vector

Every distinct 2026 attack vector mapped to the control in this skill, with the
honest caveat. No single control is sufficient; the layering is the point.

| # | Attack vector (incident) | Primary control(s) here | Honest caveat |
|---|---|---|---|
| 1 | Compromised maintainer → poisoned version (axios, AntV, durabletask) | Behavioural scan: depscore MCP / GuardDog / Socket GitHub app, **+ 7-day cooldown** (`preinstall-check.sh`), **+ post-advisory** `exposure-check.py` | Scanning can miss if the scanner hasn't analysed that exact version yet; cooldown is the backstop |
| 2 | Stale-OIDC token theft from CI (Mini Shai-Hulud / TanStack) | `zizmor` + `integrity-audit.sh` flag `id-token: write` / `pull_request_target`; revoke trust + rotate (workflow D/F) | Detection only — you must actually revoke |
| 3 | Lifecycle-script execution on install (Shai-Hulud `postinstall`) | `ignore-scripts`, `socket npm` wrapper, `pre-install-scan.sh` hook | Doesn't stop runtime-autoload payloads (see #9) |
| 4 | Worm self-propagation via stolen CI creds | OIDC hygiene + short-lived tokens + Harden-Runner egress control | Limits/detects; can't undo a leaked token — rotate |
| 5 | **Persistence in Claude Code / VS Code settings** | `integrity-audit.sh` scans Claude Code/Desktop, Gemini, MCP host JSON + VS Code/Cursor/Windsurf/VSCodium settings | Detection after the fact — treat a hit as an incident |
| 6 | CVE-lag window (advisory issued hours late) | Behavioural scanning (the core thesis) — verdict in seconds, not days | The whole reason `npm audit` alone is insufficient |
| 7 | Forged SLSA / Sigstore provenance | Treated as **one signal only**; behavioural verdict required regardless. `npm audit signatures` documented | Valid provenance ≠ safe — never trust it alone |
| 8 | PyPI zero-provenance dropper (durabletask `rope.pyz`) | Behavioural scan flags the dropper/obfuscation; `exposure-check.py` (pypi) post-advisory | PyPI has no provenance baseline to fall back on |
| 9 | Composer **tag-rewrite + `autoload.files`** (Laravel-Lang) | `exposure-check.py` (composer + `*` wildcard); pinned `composer.lock`; threat-model doc | `--no-scripts`/`ignore-scripts` useless here; cooldown fooled by aged tags |
| 10 | **Malicious editor extension** (Nx Console 18.95.0 → GitHub 3,800-repo breach) | `exposure-check.py` IOC match + `scan-extensions.sh` inventory/recency + `--deep` GuardDog behavioural | Extensions ship minified → even AST scanning is best-effort; inventory + recency + IOC is the backbone |
| 11 | MCP server / AI-agent-skill attacks | `integrity-audit.sh` flags injected `mcpServers`; `scan-extensions.sh` inventories plugins (pinned SHA) + skills with recency, `--deep` behaviourally scans source; depscore scores packages | Plugin/skill *source* is scannable (un-minified); MCP-server runtime behaviour still not sandboxed |

If a new vector appears, add a row here and a control — this table is the skill's
definition of "complete."

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
