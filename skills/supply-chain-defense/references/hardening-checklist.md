# Supply Chain Hardening Checklist

Step-by-step procedures for the hygiene and self-integrity layers. Run top to
bottom for a full hardening pass, or jump to a section. The first three are
read-only; the rest change live state — confirm before acting.

---

## Contents

1. [1. Self-integrity + exposure scan (read-only — run first)](#1-self-integrity--exposure-scan-read-only--run-first)
2. [2. Editor extension audit (read-only)](#2-editor-extension-audit-read-only)
3. [3. Stale OIDC trust audit (read-only)](#3-stale-oidc-trust-audit-read-only)
4. [4. Revoke stale OIDC + rotate tokens (changes live state — confirm)](#4-revoke-stale-oidc--rotate-tokens-changes-live-state--confirm)
5. [5. Dependency pinning + cooldown policy](#5-dependency-pinning--cooldown-policy)
6. [6. Wrap installs (layer 2)](#6-wrap-installs-layer-2)
7. [7. Behavioural scanning in PRs + CI (layer 1)](#7-behavioural-scanning-in-prs--ci-layer-1)
8. [8. Client-facing posture (optional but increasingly asked)](#8-client-facing-posture-optional-but-increasingly-asked)
9. [Quick pass (the 1-hour version)](#quick-pass-the-1-hour-version)

## 1. Self-integrity + exposure scan (read-only — run first)

Detect whether a worm has already persisted on this machine, and whether you have a
known-bad package/extension installed.

```bash
bash scripts/integrity-audit.sh      # persistence: .claude/MCP/editor configs,
                                      # shell rc files, .npmrc/.pypirc, workflow OIDC
bash scripts/run-python.sh scripts/exposure-check.py --root .
                                      # known-IOC match across npm/pnpm/yarn/
                                      # pypi/composer/cargo/go/rubygems + extensions
```

Manual equivalents if you want to eyeball it:

```bash
# Claude Code config — look for hooks / mcpServers you didn't add
cat ~/.claude/settings.json ~/.claude/settings.local.json ~/.claude.json 2>/dev/null

# VS Code user settings — look for startup tasks, autorun, unexpected entries
#   macOS:   ~/Library/Application Support/Code/User/settings.json
#   Linux:   ~/.config/Code/User/settings.json
#   Windows: %APPDATA%\Code\User\settings.json
```

**If you find an entry you didn't add → treat as an incident:** isolate the
machine, rotate every credential reachable from it (cloud, npm/PyPI, GitHub, AI
API keys), and investigate before continuing. Do not just delete the hook and
move on — the worm's first act was credential theft.

---

## 2. Editor extension audit (read-only)

```bash
bash scripts/scan-extensions.sh          # inventory + recency of extensions/plugins/skills
bash scripts/scan-extensions.sh --deep   # + GuardDog behavioural (auto-detects engine)
code --list-extensions --show-versions   # manual cross-check
```

`exposure-check.py` (step 1) already flags *known-bad* extensions by IOC; this step
adds inventory, recency, and behavioural triage for *unknown* ones. For each
extension, check publication recency on the Marketplace. **Pause anything
published in the last 7 days from a non-verified publisher.** Remember Nx Console:
verified publisher, 2.2M installs, still backdoored — verified status is not a
safety guarantee, recency + behaviour is.

Disable rather than uninstall while triaging, so you can compare versions:

```bash
code --disable-extension <publisher.extension>
```

---

## 3. Stale OIDC trust audit (read-only)

The Mini Shai-Hulud entry point. Find every workflow that can mint a publish
token:

```bash
# Workflows requesting an OIDC token
rg -l 'id-token:\s*write' .github/workflows/

# Publish steps that consume it
rg -n 'npm publish|pypi|twine upload|trusted.?publish|setup-node.*registry-url' .github/workflows/
```

`scripts/integrity-audit.sh` reports these automatically. For richer static
analysis — `pull_request_target` misuse, template injection, over-broad token
scopes — run **zizmor** (the audit script invokes it automatically if installed):

```bash
uv tool install zizmor
zizmor .github/workflows/
```

For each workflow with publish trust, ask: **is this still needed?** A federation
left configured on an orphaned/archived workflow is pure attack surface.

---

## 4. Revoke stale OIDC + rotate tokens (changes live state — confirm)

For trust relationships you no longer need:

- **npm:** Settings → trusted publishers → remove the GitHub workflow binding.
  Audit Access Tokens; delete unused; prefer granular automation tokens with the
  narrowest scope, or move to trusted publishing entirely.
- **PyPI:** Project → Settings → Publishing → remove stale trusted publishers.
  Revoke unused API tokens.
- **Workflow side:** drop `id-token: write` from `permissions:` where publishing
  no longer happens.

Prefer **short-lived OIDC trusted publishing** over long-lived tokens everywhere.
Rotate any long-lived publish token now; keep the set of accounts with standing
publish access as small as the team allows.

> T3 — rotating a token or removing trust can break a running pipeline. Confirm
> the workflow is genuinely stale, and have the replacement (OIDC) ready before
> revoking the old path.

---

## 5. Dependency pinning + cooldown policy

- Commit lockfiles (`package-lock.json`, `pnpm-lock.yaml`, `composer.lock`,
  `uv.lock`, `Cargo.lock`).
- Pin exact versions for anything that runs in CI or production.
- **7-day cooldown:** do not auto-update production dependencies until a release
  has aged at least a week. Encode it in Renovate/Dependabot:

```jsonc
// renovate.json — hold prod deps for 7 days after release
{
  "packageRules": [
    { "matchDepTypes": ["dependencies"], "minimumReleaseAge": "7 days" }
  ]
}
```

Rationale: the axios poisoned versions were live ~3 hours. A 7-day lag gives the
ecosystem (and Socket's behavioural feed) time to detect and remediate before you
pull.

Check publish age ad-hoc before any add:

```bash
bash scripts/preinstall-check.sh axios react@19.0.0
# a standalone tool from a GitHub release (an installer, a CLI binary):
bash scripts/release-check.sh <owner/repo> <tag> <downloaded-file> --reference <installed-binary>
```

### Security-release exception

A release that patches a published vulnerability may skip the wait, because a week on
a known, exploitable hole is the bigger risk. "Security fix, upgrade now" is also the
lure a hijacked publish uses, so the label alone waives nothing. **Every** check below
must pass. If one fails or cannot be run, the release waits the 7 days.

1. **CVE IDs named for this version.** Published CVEs must be named by ID for this exact
   version, in a CVE or vendor advisory or in the vendor's own release notes for it.
   Upstream advisories often go public before they name a fixed version (git's
   GHSA-vp2w-7xxj-jvxr still read "patches are being discussed" when Git for Windows
   2.56.1 shipped the fix), which is why the notes count. A changelog that says only
   "security fixes", with no IDs, is the lure, not evidence. A note can also cite an older
   CVE as background, so confirm each ID is fixed in this release, not just mentioned.
2. **Vendor checksum or signature, from the vendor's own channel.** Fetch the published
   checksum or signature from the vendor (its download site, checksum API, or signed
   release page), not from the registry entry, and compare it with the artifact you
   actually installed (the archive in the package cache, or the `dist` URL your lockfile
   resolved). Registry metadata alone proves nothing: a stolen publish token can rewrite it.
   **For a signed binary**, its code signature must also be valid and come from the same
   signing identity as the version already installed. A hijacked release account can
   rewrite the notes and the hashes beside the asset, but it does not hold the
   code-signing key. A new or missing signer sends the release back under the cooldown,
   and a renewed certificate is confirmed out of band first.
3. **Change confined to the patched package(s).** `git diff -- <lockfile>` must move
   only the advised package and any sibling the vendor ships with it (a core package and
   its core-files package, say). Anything else moving sends the whole change back under
   the cooldown. A single tool installer is confined by nature.
4. **A person approves, staging first for a dependency.** A person merges the PR, or OKs
   the tool install. No agent or bot merges, deploys or installs a waived release. A
   dependency runs on staging (or the equivalent) before production.
5. **Record the waiver** in the PR body or commit message, or in the install note for a
   tool:

   ```text
   Cooldown waived: security release.
   CVEs: <CVE IDs>, named for <version> in <advisory ID + URL | release notes URL>.
   Checksum: <algorithm> <value>, from <vendor URL>, matches the installed artifact.
   Signer: <subject> [<thumbprint>], same as the installed <version>.   (signed binaries)
   Lock: only <package(s)> changed.                                     (dependencies)
   ```

The behavioural scan still runs; the exception waives only the wait.

**What the tools report.** Neither script waives anything, and neither has a flag to:
a flag would be the first thing a lure asks for. They gather the evidence for step 1 (and,
for a tool, step 2) and say when a waiver may be requested. The person still decides.

| Tool | Exit 11 means | It cannot check |
|---|---|---|
| `scripts/preinstall-check.sh` (a package) | OSV lists a non-withdrawn advisory with a CVE ID whose fixed version is exactly this one. The CVE IDs and advisory URLs are in stderr and in `--json` `.data[].waiver` | The vendor checksum, the lock diff, staging, the record. Exit 10 stays the plain hold, also when OSV is unreachable |
| `scripts/release-check.sh` (a tool from a GitHub release) | The notes name CVE IDs, the file's SHA-256 matches the release's asset digest or notes, and its Authenticode signature is valid with the same certificate as `--reference` (the installed binary) | Whether each CVE is fixed rather than mentioned; signatures other than Authenticode, so a non-Windows host or a non-PE file only ever holds |

`release-check.sh` exits 12 (refuse) at any age when the hash or the signer contradicts
the release or the installed version: do not install that file. Both exit 7 when they
could not check at all, which is never a pass.

**Example (dependency).** A CMS ships core `X.Y.4`, a security point release whose
advisory fixes a CVE in `X.Y.3`. The lock moves the core package and its core-files
package, and nothing else. The archive's SHA-1 matches the checksum on the vendor's own
download API. The PR records all of that, a person merges it to staging, then promotes it
the same day.

**Example (tool).** Git for Windows 2.56.1 shipped 3 days after 2.56.0(4). Its notes
name six CVEs fixed in it, and also cite CVE-2019-1348 as background, which is why the
person confirms each ID. They publish the installer's SHA-256 in a `file | hash` table,
and GitHub holds the same value as the asset digest. `release-check.sh git-for-windows/git
v2.56.1.windows.1 Git-2.56.1-64-bit.exe --reference "C:\Program Files\Git\cmd\git.exe"`
reads all of that; when the installer's signer certificate matches the installed
`git.exe`'s, it exits 11. The workstation owner OKs the install, and the install note
records the CVE IDs, the hash and the signer. Had the signer changed, it would exit 12;
had the notes said only "security fixes", it would exit 10.

---

## 6. Wrap installs (layer 2)

Route installs through the behavioural scanner so lifecycle scripts are gated:

```bash
socket npm install <pkg>     # one-off
socket wrapper on            # workspace-wide alias of npm/npx → Socket
```

Reinforce inside Claude Code with the `pre-install-scan.sh` hook (advisory; set
`SUPPLY_CHAIN_BLOCK=1` for a hard gate). See SKILL.md → Hook setup.

Two more cheap, free hardening levers:

```bash
# Disable lifecycle scripts where you don't need build hooks (removes the
# postinstall vector entirely). Allow specific packages back via npm rebuild.
npm config set ignore-scripts true        # pnpm: enable-pre-post-scripts=false

# Validate the committed lockfile points only at the real registry over https.
npx lockfile-lint --path package-lock.json --allowed-hosts npm --validate-https
```

---

## 7. Behavioural scanning in PRs + CI (layer 1)

- Install the Socket **GitHub app** on the repo (free tier, private repos
  included). It comments a risk report on any dependency-changing PR.
- In CI: `socket ci` enforces your org's policy and fails the build on a flagged
  package. Free-tier scan cap is 1,000/month.
- Add free/OSS engines for breadth and a runtime backstop:

```bash
osv-scanner scan -r .            # broad CVE coverage (Google OSV.dev), all manifests
guarddog npm verify package-lock.json   # local behavioural second opinion (Datadog)
```

```yaml
# .github/workflows/*.yml — runtime egress control on the runner (free for public repos)
- uses: step-security/harden-runner@v2
  with:
    egress-policy: audit         # tighten to 'block' + allowlist once baseline is known
```

See `references/tooling-landscape.md` for the full when-to-use-which matrix.

---

## 8. Client-facing posture (optional but increasingly asked)

For security questionnaires and proposals, "we run behavioural package scanning on
every dependency change, enforce a release-age cooldown on production
dependencies, and audit CI publish trust" is a credible, specific answer. Expect
procurement and insurance to ask harder supply-chain questions through 2027.

---

## Quick pass (the 1-hour version)

1. `bash scripts/integrity-audit.sh` — confirm the machine is clean.
2. Install the Socket GitHub app on your lowest-risk repo.
3. `claude mcp add --transport http socket-mcp https://mcp.socket.dev/` — free
   depscore in Claude Code, no key.
4. Add `minimumReleaseAge: 7 days` to Renovate/Dependabot for prod deps.
5. Skim `rg -l 'id-token:\s*write' .github/workflows/` and note anything stale to
   revoke later.
