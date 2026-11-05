# Repo Integrity — defending trusted repos against config-as-code poisoning

Prevent, detect and attribute malicious commits to a repo you already own.

## Contents

1. [A distinct detection surface](#a-distinct-detection-surface)
2. [The kill chain, and where each control bites](#the-kill-chain-and-where-each-control-bites)
3. [1. Keys: no shared, no standing, hardware-backed](#1-keys-no-shared-no-standing-hardware-backed)
4. [2. Branch protection / rulesets — and why *signed commits* defeat Stage 4 (with one big caveat)](#2-branch-protection--rulesets--and-why-signed-commits-defeat-stage-4-with-one-big-caveat)
5. [3. The audit log is ground truth — git dates are not](#3-the-audit-log-is-ground-truth--git-dates-are-not)
6. [Checklist](#checklist)
7. [Sources](#sources)

## A distinct detection surface

The sibling of [`threat-model.md`](threat-model.md)'s dependency-integrity story.
Everything else in this skill asks *"is a package I pull malicious?"* This file
asks the question the PolinRider / EtherHiding campaign forced into scope:
**"is a repo I already own and push to being poisoned in place — and would I even
notice?"**

This is a **distinct detection surface**. The behavioural dependency scanners
(Socket, depscore, the cooldown gate, `exposure-check.py`, `postinstall-audit.py`)
are structurally blind to it: the malicious code never enters as a package. It is
committed — by an attacker-controlled push — into your own `vite.config.js`,
`tailwind.config.js`, or `.vscode/tasks.json`. The on-disk detector is
[`scripts/config-drift-check.py`](../scripts/config-drift-check.py); the controls
that *prevent* and *attribute* it are below; isolation, VS Code Workspace Trust, the
detector and incident containment are in
[repo-integrity-response.md](repo-integrity-response.md).

## The kill chain, and where each control bites

PolinRider (DPRK UNC5342 / Lazarus-aligned, ~1,951 repos by Apr 2026; the EtherHiding
technique is documented by Google GTIG) runs in four stages. Map a control to each —
no single one is sufficient.

| Stage | What the attacker does | Control that bites here |
|---|---|---|
| **1. Initial access** | Poisoned fork / fake take-home interview repo (Contagious Interview / BeaverTail lure); malicious `.vscode/tasks.json` auto-running on `folderOpen`; booby-trapped `.woff2` font (parser exploit) | **Disposable environment** for untrusted repos (devcontainer / throwaway VM / Codespace); **VS Code Workspace Trust** enforced + **auto-run tasks disabled** |
| **2. Build-time execution** | Appends an obfuscated blockchain-C2 loader to build config (`vite.config.js`, `tailwind.config.js`); on build, reads a payload from a blockchain dead-drop (EtherHiding), XOR-decrypts, runs it | **`config-drift-check.py`** as a pre-commit hook + CI gate (catches the appended/obfuscated/eval/XOR/blockchain-RPC blob); **build isolation** (ephemeral CI container, no standing secrets) |
| **3. Credential theft** | INVISIBLEFERRET RAT steals credentials / keys / wallets from the host | **Hardware-backed keys** (Secure Enclave / YubiKey) so a RAT with filesystem read *cannot* exfiltrate the signing/SSH key; no plaintext long-lived tokens on disk |
| **4. Git cover-up & propagation** | Injects config files into every repo the machine can push to and **force-pushes**, preserving the original author + date (backdating → false-flag) | **Branch protection / rulesets**: block force-push, require PRs, require status checks, **require signed commits**; **server-side push-log** as ground truth; **no shared/standing keys** to bound blast radius |

## 1. Keys: no shared, no standing, hardware-backed

The single fact that turned one infected laptop into a 22-repo breach in a reported
incident was a **shared, long-lived devops deploy key with write access to
everything**. Fix the key model and you cap the blast radius before any detection
fires.

- **No shared keys.** Every human and every automation gets its own credential.
  A shared key means one compromise = everyone's access, and the audit log can't
  tell you *who*.
- **No standing write access.** Prefer short-lived, per-job credentials (OIDC, GitHub
  App installation tokens scoped to one repo) over a long-lived deploy key that sits
  on a developer's disk for a year. Deploy keys are per-repo by design — a deploy key
  reused across many repos is the anti-pattern; a fine-grained PAT or App token scoped
  to exactly what a job needs is the replacement.
- **Least privilege.** A CI job that deploys does not need push access to source. Split
  read/deploy from write.
- **Hardware-backed signing + SSH keys.** This is the control that specifically
  defeats Stage 3. A key whose **private half lives in a Secure Enclave / TPM /
  YubiKey** cannot be read off disk by a RAT that has filesystem access — the RAT can
  never exfiltrate the key for offline reuse. **But residence alone does not stop
  *live abuse*:** a RAT on an unlocked machine can ask the Secure Enclave / token to
  sign *on its behalf* if signing is configured for convenience (cached agent, no
  per-use prompt). The load-bearing setting is **require a physical touch per
  signature** (YubiKey touch policy; Secretive's per-use Touch ID) — so the attacker
  can sign at most when it can induce a touch, one at a time and noisily, never 22
  repos silently. Hardware-without-touch reduces the *theft* risk but not the
  *silent-mass-signing* risk.
  - **macOS:** [Secretive](https://github.com/maxgoedjen/secretive) stores SSH keys in
    the Secure Enclave; commit-signing can use an SSH key (`gpg.format = ssh`,
    `user.signingkey` pointing at the Secure-Enclave public key). A non-Enclave option
    is a YubiKey via PIV/FIDO2.
  - **Cross-platform:** a **YubiKey** (or any FIDO2/PIV hardware token) holds the SSH
    auth key and the signing key; the private material never leaves the token.
  - The point is the *threat model*, not the brand: filesystem-read by malware must not
    equal key compromise.

## 2. Branch protection / rulesets — and why *signed commits* defeat Stage 4 (with one big caveat)

Configure on every protected branch (classic **branch protection** or the newer
**repository rulesets**, which can apply org-wide):

- **Block force-pushes** to protected branches. Stage 4 *is* a force-push; this denies
  the propagation primitive outright. (Rulesets: "Restrict force pushes"; branch
  protection: "Do not allow force pushes".)
- **Require a pull request before merging** — no direct pushes to `main`, so an
  injected commit must survive review and checks instead of landing silently.
- **Require status checks to pass** — wire `config-drift-check.py` as one of them
  (see [§6 in repo-integrity-response.md](repo-integrity-response.md#6-the-pre-commit--ci-detector)),
  so a poisoned config fails CI before merge.
- **Require signed commits** — *this is the one that specifically defeats the
  backdated false-flag*.

### Why signed commits specifically defeat the backdating cover-up

Stage 4's trick is to force-push commits that **preserve the original author name and
an old author date**, so `git log` shows a malicious change attributed to an innocent
teammate at an innocent time. Two facts collapse that trick:

1. **A deploy key (or any transport credential) authenticates the *push*, not the
   *commit*.** SSH deploy keys, HTTPS tokens, and App tokens prove "this connection is
   allowed to write here." They say nothing about who *authored* the commit and they
   do **not** sign it. A commit pushed over a deploy key arrives **unsigned**.
2. **Commit author name + date are free-text fields the committer fully controls.** A
   signature is not — it is a cryptographic binding to a key. Forging the author
   metadata is trivial; forging a *valid signature from a hardware key the attacker
   can't read* is not — **provided** the attacker also can't simply register their own
   key to the account (see the takeover caveat below; this is why hardware keys alone
   are not the whole story).

So with **require-signed-commits** on:

- The RAT can backdate and re-author all it likes, but the commits it pushes are
  **unsigned** → branch protection **rejects the push**. The propagation primitive
  fails at the gate.
- If the attacker forges author metadata *without* a matching signature, GitHub renders
  the commit **"Unverified"** — the false-flag is visibly broken rather than
  convincingly attributed.
- The legitimate developer's signing key is **hardware-backed** (§1), so the RAT can't
  steal it to produce *signed* malicious commits. The two controls compose: hardware
  key (can't be stolen) + require-signed-commits (unsigned is rejected) = backdated
  false-flag commits cannot land on a protected branch.

Caveat: require-signed-commits protects the **protected branch**. Commits on feature
branches / forks can still be unsigned; the PR-required + status-check rules are what
stop an unsigned, drift-flagged commit from reaching `main`. Enable **vigilant mode**
on developer accounts so *all* their commits display a verification state and a forged
"Unverified" stands out.

### The bypass this control does *not* survive on its own — account takeover

Do not over-trust signed commits. The reasoning above holds only while the attacker
is **outside the victim's GitHub account**. But Stage 3 steals *everything on the
host* — including the browser session cookie, OAuth tokens, and personal access
tokens for GitHub itself. With a stolen token, the RAT is **inside the account**, and:

- It can **register a new SSH/GPG signing key to the victim's GitHub account**, then
  sign its backdated commits with that key. GitHub verifies a signature against the
  keys on the account that pushed it — so a commit signed by the attacker's freshly
  added key renders as **"Verified," attributed to the victim**. Require-signed-commits
  passes. The false-flag is now *cryptographically* convincing, not visibly broken.
- With an **org-admin** token it can disable the ruleset, push, and re-enable it.

So *require-signed-commits is necessary but not self-sufficient*. It defeats the
deploy-key-only attacker; it does **not** defeat the attacker who also holds a GitHub
credential — which this campaign explicitly harvests. The companion controls that
close the gap are non-optional:

- **Phishing-resistant MFA (passkeys / hardware security keys) on GitHub, npm, and
  cloud accounts.** This is the foundation the whole signed-commit story rests on —
  it raises the cost of the account takeover that would otherwise nullify it.
- **Real-time alerting on account-integrity events** (§3): a *new signing/SSH key
  registered*, a *ruleset / branch-protection change*, a *new PAT or OAuth grant*.
  These are the events that betray a token-theft takeover even when the resulting
  commits look perfectly "Verified." A new key appearing on an account minutes before
  a backdated commit lands is the tell that the signature itself cannot give you.

## 3. The audit log is ground truth — git dates are not

Git's author date and committer date are **attacker-controlled strings**. A commit
"backdated to March" is one `GIT_AUTHOR_DATE` away. What the attacker **cannot** forge
is the server-side record of *when the push actually happened*:

- **GitHub's push event** (Audit log / `git.push`, the events API, branch "pushed N
  minutes ago", `PushEvent` timestamps) is recorded server-side and immutable to the
  pusher. A commit whose *author date* is weeks old but whose *push timestamp* is now
  is a backdating IOC.
- **Alert on force-pushes** to protected branches (Audit log streaming → SIEM, or a
  webhook on `push` with `forced: true`). Stage 4 always force-pushes.
- **Alert on account-integrity events** — a **new SSH/GPG key registered**
  (`public_key.create`), a **ruleset / branch-protection change**
  (`repository_ruleset.update`, `protected_branch.*`), a **new PAT or OAuth grant**.
  These betray the account takeover that would otherwise let an attacker mint a
  "Verified" signature (see §2's takeover caveat) — they are the signal the signature
  itself cannot give you.
- **Alert on out-of-hours / anomalous pushes** — a force-push at 03:00 from an account
  that normally opens PRs is signal even before you read the diff.
- **Stream the audit log off-platform to an immutable store.** GitHub-side retention
  is finite and an account-takeover attacker may tamper within the window; a copy in a
  SIEM / log sink the pusher can't reach is the durable ground truth.
- When triaging a suspected false-flag commit, **trust the push-event timestamp and the
  signature state, not `git log --date`.** "It says March, but it was pushed in April
  and it's unsigned" is the tell.

GitHub Enterprise / org audit-log streaming makes this durable; for smaller setups a
`push` webhook into any log sink, or periodic `gh api` polling of the events endpoint,
covers it.

## Checklist

- [ ] No shared deploy keys; no long-lived standing write credentials (per-user /
      per-job, least privilege)
- [ ] Signing + SSH keys are **hardware-backed** (Secure Enclave / YubiKey) — a RAT
      with filesystem read can't exfiltrate them
- [ ] Signing + SSH keys require a **per-use physical touch** (not just hardware
      residence) — stops silent mass-signing by a present RAT
- [ ] Protected branches: force-push blocked, PR required, status checks required,
      **signed commits required**
- [ ] **Phishing-resistant MFA (passkeys / hardware)** on GitHub, npm, cloud — the
      foundation signed-commits rests on (without it, a stolen token mints a "Verified" key)
- [ ] `config-drift-check.py` runs as a pre-commit hook **and** a CI status check —
      treated as one signal, paired with egress-deny + touch-to-sign
- [ ] Alerting wired on force-push, out-of-hours push, **new-key-registration, and
      ruleset changes**, from an **off-platform immutable** audit-log copy
- [ ] Triage uses the **push-event timestamp + signature state**, never `git log`
      author dates
- [ ] Untrusted repos (forks, take-homes) open only in a disposable container/VM
- [ ] Builds run in ephemeral containers with no standing secrets; **egress
      allowlisted** (can't reach a blockchain dead-drop)
- [ ] Agentic dev tools hold no standing creds; their pushes pass the same gates as humans
- [ ] VS Code Workspace Trust enabled; `task.allowAutomaticTasks` off; external repos
      opened as untrusted first
- [ ] IR scope = every machine that **built** a poisoned repo (not just the commits);
      all readable creds rotated; customer-shipped artifacts audited

## Sources

- Google GTIG — *DPRK Adopts EtherHiding* (UNC5342, Contagious Interview, JADESNOW →
  INVISIBLEFERRET, BNB Smart Chain + Ethereum dead-drop via centralized explorer APIs):
  <https://cloud.google.com/blog/topics/threat-intelligence/dprk-adopts-etherhiding>
- GitHub Docs — *About commit signature verification* and *About protected branches /
  rulesets* (require signed commits, restrict force pushes)
- VS Code Docs — *Workspace Trust* (Restricted Mode disables auto-run tasks) and
  *Tasks* (`runOptions.runOn`, `task.allowAutomaticTasks`)
- PolinRider attribution and the shared-deploy-key blast-radius detail: practitioner
  incident reporting on the EtherHiding npm campaign, 2026
