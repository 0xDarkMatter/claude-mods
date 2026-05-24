# Supply Chain Hardening Checklist

Step-by-step procedures for the hygiene and self-integrity layers. Run top to
bottom for a full hardening pass, or jump to a section. The first three are
read-only; the rest change live state — confirm before acting.

---

## 1. Self-integrity scan (read-only — run first)

Detect whether a worm has already injected persistence into this machine.

```bash
bash scripts/integrity-audit.sh
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

## 2. VS Code extension audit (read-only)

```bash
code --list-extensions --show-versions
```

For each extension, check publication recency on the Marketplace. **Pause anything
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
```

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
