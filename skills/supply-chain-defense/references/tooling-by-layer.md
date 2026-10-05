# Supply Chain Tooling, Layer by Layer

What each tool in [tooling-landscape.md](tooling-landscape.md)'s table does, how to
run it, and the gotchas verified while wiring it in. Paths are relative to the skill
folder.

## Contents

1. [Layer 1 — detection](#layer-1--detection)
2. [Layer 2 — interception](#layer-2--interception)
3. [Layer 3 — hygiene](#layer-3--hygiene)
4. [Layer 4 — self-integrity + exposure response](#layer-4--self-integrity--exposure-response)

## Layer 1 — detection

### Socket.dev (lead behavioural)

Hosted engine that clones registries in real time and runs static + LLM analysis
on every new package within seconds of publication. Free CLI, free $0 account
tier, no-key depscore MCP. Full command surface and pricing in
[socket-cli.md](socket-cli.md). **Use as the primary PR/merge gate and the Claude Code
package-scoring source.**

### GuardDog (Datadog) — the free local behavioural second opinion

Open-source CLI using source-code heuristics (Semgrep rules + metadata checks) to
flag malicious packages: suspicious `postinstall`/`setup.py` code, base64-encoded
exec, network exfiltration, obfuscation, npm/PyPI metadata anomalies. Runs fully
locally — no account, no telemetry.

```bash
uv tool install guarddog         # or: pipx install guarddog
guarddog npm scan <package>      # scan a published package (registry)
guarddog npm scan ./local-pkg --exit-non-zero-on-finding   # scan a local dir; exit 1 on findings
guarddog pypi scan <package>
guarddog npm verify package-lock.json   # scan a whole lockfile
guarddog github_action scan .    # workflow heuristics
```

**Do you need it alongside Socket?** For most single-dev / small-team setups,
**no — Socket is the daily driver** and GuardDog is redundant on the routine
"score before I add it" path. Reach for GuardDog *situationally*, not in parallel:

- **Privacy / air-gapped** — analysis is local; package names never leave the
  machine (Socket is a hosted service).
- **Second, auditable opinion** on a specific suspicious package — open-source
  Semgrep/YARA rules you can read, vs Socket's proprietary + LLM engine.
- **No-account / offline CI** where a hosted scanner isn't permitted.

What Socket has that GuardDog doesn't: a real-time registry feed that flags fresh
malware before advisories exist. What GuardDog has: local execution and auditable
rules. (Verified: GuardDog caught `npm-exec-base64`, `npm-serialize-environment`,
and `npm-exfiltrate-sensitive-data` with `file:line` citations on a crafted
package.)

> ⚠️ **Windows gotchas (verified):**
> 1. GuardDog reads its rule YAMLs without forcing UTF-8 and crashes on cp1252 —
>    run it with `PYTHONUTF8=1 guarddog …` (or set `PYTHONUTF8=1` for the session).
> 2. Its source-code rules (the behavioural ones — base64-exec, exfil) shell out to
>    **`semgrep`**, which must be on PATH (`uv tool install semgrep`). **Without it,
>    GuardDog prints `Found 0 potentially malicious indicators` and exits 0** with
>    only a buried "Some rules failed to run" warning — a dangerous *false-clean*.
>    Always confirm semgrep is present before trusting a clean GuardDog result.

### OSV-Scanner (Google) — broad CVE coverage

Open-source scanner against [OSV.dev](https://osv.dev), which aggregates advisories
across far more ecosystems than `npm audit` alone. CVE-based (so it shares the
advisory-lag blind spot), but a stronger CVE layer than per-ecosystem audit tools.

```bash
# install: scoop install osv-scanner | brew install osv-scanner |
#          go install github.com/google/osv-scanner/v2/cmd/osv-scanner@latest  (note the /v2)
osv-scanner scan --lockfile requirements.txt   # also: package-lock.json, go.mod, Cargo.lock, …
osv-scanner scan -r .            # recursive, all manifests; exit 1 when vulns found
```

**Use as** the CVE-side complement to `security-ops` — broader and faster than
`npm audit`/`pip-audit`. Pair with a behavioural scanner; do not rely on it alone.

### `npm audit signatures`

Verifies that installed packages match the registry's signatures and (where
present) provenance attestations. Remember the threat model: valid provenance was
**forged** in 2026, so a pass is necessary-not-sufficient. Cheap to run; treat as
one signal among several.

## Layer 2 — interception

### `ignore-scripts` — the cheapest mitigation that exists

Lifecycle scripts (`preinstall`/`postinstall`/`prepare`, sdist `setup.py`) are the
worm's execution vector. Disabling them removes it for projects that don't need
them:

```bash
npm config set ignore-scripts true                 # npm, global
# package.json / .npmrc:  ignore-scripts=true
# pnpm (.npmrc):          enable-pre-post-scripts=false
# yarn (.yarnrc.yml):     enableScripts: false
```

Trade-off: some packages legitimately need build steps (native modules). Allow them
explicitly (`npm rebuild <pkg>` / pnpm `onlyBuiltDependencies`) rather than leaving
scripts globally on.

> ⚠️ **`ignore-scripts` is not universal.** It stops *lifecycle-script* payloads
> (`postinstall` etc.). It does **nothing** against a payload wired into a runtime
> autoloader — e.g. the Laravel-Lang Composer attack injected `helpers.php` into
> `autoload.files`, which runs on every PHP request, so `composer install
> --no-scripts` would not have helped. For Composer the real protection is a
> committed `composer.lock` predating the compromise (pins reference SHA + dist +
> integrity) and never blindly `composer update`-ing.

### lockfile-lint — detect lockfile injection

Validates that resolved URLs in a lockfile point at the expected registry over
https with integrity hashes — catches a tampered lockfile redirecting a package to
an attacker host.

```bash
npx lockfile-lint --path package-lock.json --allowed-hosts npm --validate-https
```

### `socket` wrapper

`socket npm install …` / `socket wrapper on` — intercepts a risky install before
lifecycle scripts run. See [socket-cli.md](socket-cli.md).

## Layer 3 — hygiene

### zizmor (Trail of Bits) — the OIDC/workflow auditor

Open-source static analyzer for GitHub Actions. It detects exactly the class of
misconfiguration Mini Shai-Hulud abused: dangerous `pull_request_target` triggers,
over-broad `id-token`/token permissions, template injection, credential
persistence, and cache-poisoning vectors.

```bash
uv tool install zizmor           # or: pipx install zizmor
zizmor .github/workflows/        # audit all workflows
zizmor --format sarif . > zizmor.sarif
```

**Use as** the engine behind the OIDC-audit workflow (replaces hand-rolled `rg`).
`scripts/integrity-audit.sh` invokes `zizmor` automatically when it's installed.

### Harden-Runner (StepSecurity) — runtime CI egress control

A GitHub Action that instruments the runner to monitor (and optionally block)
outbound network traffic, file writes, and process events. If a compromised
dependency tries to exfiltrate the OIDC token or phone home to C2 during a CI run,
Harden-Runner surfaces or blocks it. Free for public repositories.

```yaml
# .github/workflows/*.yml — first step in the job
- uses: step-security/harden-runner@v2
  with:
    egress-policy: audit        # start in audit, tighten to 'block' with an allowlist
```

**Use when** your CI publishes or holds any credential — it's the runtime backstop
for the token-theft vector that pinning and scanning don't cover.

### gitleaks

Secret scanning to catch leaked npm/PyPI/cloud tokens before they ship. Already
used by `git-ops`' push gate. Relevant here for the token-rotation workflow.

## Layer 4 — self-integrity + exposure response

Two distinct questions here: "has the worm persisted on this machine?" and "do we
already have a named-bad package installed?"

### Persistence detection

`scripts/integrity-audit.sh` (this skill) scans AI-tool configs (Claude Code +
Desktop, Gemini, MCP host JSON) and editor settings (VS Code, Cursor, Windsurf,
VSCodium) for injected persistence hooks/MCP servers, and flags workflows with live
OIDC trust (running `zizmor` when present). The host-config map is drawn from
Bumblebee's `docs/inventory-sources.md`.

### Exposure response — Bumblebee + exposure-check.py

When an advisory names a poisoned package + version, you need to know which
machines/projects have it on disk *right now*.

- **Bumblebee** (Perplexity, Apache-2.0, Go, **macOS/Linux**) is the fleet-scale
  tool: a read-only inventory collector that walks lockfiles, package-manager
  metadata, editor + browser extensions, and MCP host configs, emits NDJSON, and —
  given an `--exposure-catalog` of known-bad `{ecosystem, package, versions[]}` —
  flags exact matches. Built for incident response across many developer endpoints.

  ```sh
  go install github.com/perplexityai/bumblebee/cmd/bumblebee@latest   # Go 1.25+
  bumblebee scan --profile deep --root "$HOME" --exposure-catalog ./catalog.json --findings-only
  ```

- **`scripts/exposure-check.py`** (this skill) is the **cross-platform local
  equivalent** — it runs on Windows, where Bumblebee doesn't, and reuses Bumblebee's
  exposure-catalog JSON shape so a catalog is portable between them. Narrower
  coverage (lockfiles + editor extensions; no browser extensions or MCP host
  configs), but the same "am I exposed to this advisory?" answer:

  ```bash
  bash scripts/run-python.sh scripts/exposure-check.py --root ~/code --json | jq '.data.findings[]'
  ```

  Seed `assets/exposure-catalog.json` from advisories as incidents break (it ships
  with cited 2026 IOCs). **Verified:** flags axios 1.14.1 in a lockfile with exit 10.

Reach for Bumblebee at fleet scale on macOS/Linux; `exposure-check.py` for a quick
local check anywhere including Windows.
