# 2026 Supply Chain Threat Model

Distilled from the "Sandworms in the Registry" briefing (May 2026) and the public
incident reporting it cites. This is the *why* behind every directive in the
skill and the `supply-chain.md` rule.

## Contents

1. [The shift in attacker behaviour (last 90 days)](#the-shift-in-attacker-behaviour-last-90-days)
2. [Timeline of named incidents](#timeline-of-named-incidents)
3. [Why each legacy control fails](#why-each-legacy-control-fails)
4. [Coverage — which control catches which vector](#coverage--which-control-catches-which-vector)
5. [Indicators of compromise (what behavioural scanners flag)](#indicators-of-compromise-what-behavioural-scanners-flag)
6. [What the next 12 months look like](#what-the-next-12-months-look-like)

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
| Feb 2025 → present (Apr 2026 wave) | **PolinRider / EtherHiding** (DPRK UNC5342 / Lazarus-aligned; ~1,951 repos by Apr 2026) | **Not a poisoned npm dependency** — the entry is a *trusted repo you already own*. A dev is lured into a fork / fake take-home interview repo (Contagious Interview / BeaverTail lure) carrying a malicious `.vscode/tasks.json` (auto-run on `folderOpen`) or a booby-trapped `.woff2` font. Stage 2 appends an obfuscated blockchain-C2 loader to **build config files** (`vite.config.js`, `tailwind.config.js`); on build it pulls a payload from a blockchain dead-drop (EtherHiding — BNB Smart Chain + Ethereum via centralized explorer APIs / `eth_call`), XOR-decrypts and runs it. Stage 3 = INVISIBLEFERRET RAT (creds/keys/wallets). Stage 4 = once resident, inject config files into every repo the machine can push to and **force-push**, **preserving original author + date** (backdating → false-flag attribution). | **The dependency tree was clean** — Socket/depscore/cooldown/exposure-check all pass and see nothing. In a reported incident it reached one company via a single **shared, long-lived devops deploy key** with write access to everything: one infected Mac force-pushed backdated commits into 22 repos. Config-as-code, not package-as-code. |

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

### Why PolinRider / EtherHiding is a *different class* — and the skill was blind to it

Everything else in this document reasons about the **dependency tree**: an
attacker poisons a package you pull, and behavioural scanning of that package
(Socket / depscore), a release-age cooldown, or an IOC match (`exposure-check.py`)
catches it. PolinRider does **none of that**. Its blast radius is **trusted repos
you already own and push to**, and its payload lives in **first-party config files
under version control**, not in `node_modules`. Five properties make it evade every
dependency-centric control:

1. **Initial access is not a package.** It's a poisoned fork, a fake-interview
   take-home repo, a malicious `.vscode/tasks.json` that auto-runs on `folderOpen`,
   or a parser-exploit `.woff2` font. No registry, no lockfile, no advisory.
2. **Execution is build-time config, not a lifecycle script.** The loader is
   *appended to* `vite.config.js` / `tailwind.config.js`. `ignore-scripts` does
   nothing — these are build configs the bundler imports, exactly like the
   Laravel-Lang `autoload.files` lesson but in the JS world.
3. **The C2 is a blockchain dead-drop (EtherHiding).** The loader reads an
   obfuscated payload from a smart contract / transaction calldata via **`eth_call`
   read-only calls** (no on-chain transaction, no gas, nothing to take down). GTIG
   documents UNC5342 reading via **centralized explorer APIs** (Ethplorer,
   Blockchair, Blockcypher, Binplorer) on **BNB Smart Chain + Ethereum**, not direct
   nodes — which is the *defender's* leverage point (block the centralized API, you
   can't take down an immutable contract). Variants also hit public RPC
   (TronGrid / BSC dataseed / Aptos fullnodes); the network-IOC entry covers both.
4. **Self-propagation is `git push`, not `npm publish`.** A resident RAT injects the
   same config files into every repo the machine can reach and force-pushes them.
   The cover-up **preserves the original commit author + date** (backdating), so the
   malicious commit surfaces under an innocent identity at an innocent timestamp —
   false-flag attribution that defeats a human skim of `git log`.
5. **Blast radius = key scope, not download count.** One reported victim was reached
   because a single **shared, long-lived devops deploy key** had write access to
   everything; one silently-infected Mac force-pushed backdated commits into 22 repos. A
   poisoned-package metric ("how many installs?") doesn't even apply.

**What actually protects you** is a different layer entirely — repo-integrity, not
dependency-integrity: no shared/standing keys + hardware-backed signing keys a RAT
can't read, branch protection that requires *signed* commits and blocks force-push,
treating the GitHub server-side push timestamp (not the attacker-controlled commit
date) as ground truth, build isolation, disposable environments for untrusted repos,
and Workspace Trust with auto-run tasks disabled. The full mapping is
`references/repo-integrity.md`; the on-disk detector is `scripts/config-drift-check.py`.

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
| 12 | **Config-as-code / trusted-repo poisoning** (PolinRider / EtherHiding) — build-config loader, `.vscode/tasks.json` auto-run, blockchain-C2 dead-drop, backdated false-flag force-push | **`config-drift-check.py`** (appended/obfuscated/eval/XOR + blockchain-RPC blobs in build configs & `tasks.json`) as a pre-commit + CI gate; `repo-integrity.md` controls (hardware-backed signing keys, branch protection requiring **signed** commits + no force-push, no shared keys, server-side push-log as ground truth, Workspace Trust, build/env isolation); blockchain dead-drop endpoints in `assets/network-ioc.json` feed `phone-home-monitor.ps1` | **Dependency-tree scanning does NOT cover this class** — Socket/depscore/cooldown/`exposure-check.py` all reason about packages you *pull*; this poisons first-party config in repos you *own*. Detection is content-diff of configs + git-provenance discipline. Backdated commits defeat `git log` skims; only the server push-event timestamp is trustworthy. |

> **Scope boundary (important).** Vectors 1–11 are *dependency-integrity*: something
> you install is malicious. Vector 12 is *repo-integrity*: something you already
> trust is poisoned in place. The behavioural dependency scanners (Socket, depscore,
> the cooldown gate, `exposure-check.py`, `postinstall-audit.py`) are **structurally
> blind** to vector 12 because the malicious code never enters as a package — it is
> committed, by an attacker-controlled push, into your own `vite.config.js` /
> `tailwind.config.js` / `.vscode/tasks.json`. This is a distinct detection surface,
> not a gap in the existing scanners. See `references/repo-integrity.md`.

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

For the **config-as-code / trusted-repo** vector (PolinRider) the IOCs live in your
own version control, not in `node_modules`:

- An **appended / obfuscated / minified blob** at the end of a build config
  (`vite.config.js`, `tailwind.config.js`, `webpack.config.js`, `next.config.js`,
  `rollup.config.js`, `postcss.config.js`, `svelte.config.js`, `astro.config.*`)
  that previously held readable config — or new `eval` / `new Function` / Buffer-XOR
  / dynamic-`require` / outbound-fetch code in such a file. `config-drift-check.py`.
- A `.vscode/tasks.json` with `"runOptions": {"runOn": "folderOpen"}` (or `package.json`
  scripts) that auto-executes a shell/downloader on open.
- An outbound connection from a build process to a **blockchain explorer API or
  public RPC node** (Ethplorer / Blockchair / Blockcypher / Binplorer; TronGrid /
  BSC dataseed / Aptos fullnode) on a project that isn't a web3/dApp — the
  EtherHiding dead-drop read. `assets/network-ioc.json` → `phone-home-monitor.ps1`.
- A **force-push** to a protected branch, or a commit whose author date is weeks in
  the past but whose **GitHub push-event timestamp is now** (backdated false-flag).
- A commit on a protected branch that arrives **unsigned** when signing is required
  (a deploy key authenticates the push but cannot sign the commit).

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
