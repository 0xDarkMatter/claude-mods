---
name: pypi-ops
description: "Publish Python packages to PyPI via OIDC Trusted Publishing (PEP 740 attestations, gh-action-pypi-publish) instead of stored tokens. Use for: invalid-publisher errors, pending-publisher 404s, uv publish/twine, TestPyPI, environment approval gates, and rotating/auditing publish tokens."
license: MIT
compatibility: "Python 3.8+ packaging; GitHub Actions for the OIDC flow; uv or twine for local publish"
allowed-tools: "Read Write Edit Bash Glob Grep WebFetch"
metadata:
  author: claude-mods
  related-skills: "supply-chain-defense, github-ops, git-ops, ci-cd-ops, python-env"
---

# PyPI Operations

Publish Python packages to PyPI on the **2026 best-practice path: OIDC Trusted
Publishing with signed PEP 740 attestations**, no long-lived token to leak. This
skill owns the *publish* layer (the registry handshake, the first-publish
gotchas, the recovery playbook). General GitHub Actions syntax is `ci-cd-ops`;
the install-side worm defense is `supply-chain-defense`; `gh`/release-page
mechanics are `github-ops`.

## Where this fits — the release pipeline

A release spans several skills; pypi-ops owns the **registry** step. Chain them:

1. **Vet dependencies** before cutting a release — `supply-chain-defense`
   (cooldown + behavioural scan). The build runs dependency code *before* it
   touches your publish credential, so a poisoned build dep can steal the token.
2. **Preflight** — `scripts/publish-preflight.sh --build .` (this skill).
3. **Bump → tag → push** — `git-ops` (its push-gate scans for secrets / forbidden
   files before the tag goes up).
4. **CI publishes** via OIDC — this skill's `assets/publish.yml`; you approve at
   the `pypi` environment gate.
5. **Release page** (optional, GitHub) — `github-ops`, human-reviewed notes.

## The one decision: OIDC vs API token

**Default to OIDC Trusted Publishing.** Reach for a token only when OIDC is
impossible (publishing from a non-supported CI, or a one-off local push).

| | **Trusted Publishing (OIDC)** ← default | **API token** |
|---|---|---|
| Secret stored | None — short-lived OIDC token minted per run | Long-lived `pypi-…` token in a secret |
| Leak/phish blast radius | None to steal | Full publish rights until rotated |
| Provenance | PEP 740 attestations (signed, verifiable) | None by default |
| Setup | One-time publisher registration on PyPI | Generate token + store secret |
| Best for | **All CI/CD releases** | Legacy CI, emergency local upload |

If a repo currently uses a token, migrating to OIDC is strictly an upgrade — see
[references/trusted-publishing.md](references/trusted-publishing.md).

## The #1 gotcha: first publish needs a *pending* publisher

A Trusted Publisher is normally configured **under the project's settings** on
PyPI — but on the **first ever publish the project doesn't exist yet**, so there's
nothing to configure it under. The fix is a **pending publisher**, registered at
the account level *before* the first upload.

Symptom (the exact failure this skill exists to kill):

```
Trusted publishing exchange failure:
* invalid-publisher: valid token, but no corresponding publisher
  (Publisher with matching claims was not found)
```

The OIDC token was valid; PyPI just has no publisher matching the claims. Fix:

> **PyPI → https://pypi.org/manage/account/publishing/ → Add a pending publisher**
>
> | Field | Value |
> |---|---|
> | PyPI Project Name | the dist name from `pyproject.toml` `[project].name` |
> | Owner | GitHub org/user |
> | Repository name | repo name |
> | Workflow name | the **filename**, e.g. `publish.yml` (not the `name:`) |
> | Environment name | must equal the job's `environment:` (e.g. `pypi`) |

All four claims must match the run's OIDC token exactly. After the first
successful publish, the pending publisher auto-converts to a normal project
publisher — no further action. Run `diagnose-publish.sh` on a failed run to read
the exact claims it presented and compare them field-by-field.

> This is the most common silent-failure mode: a package's `publish.yml` looks
> perfect and every release builds green, yet nothing ever reaches PyPI because
> the publisher was never registered. Check it **first**.

## Recommended workflow (copy [assets/publish.yml](assets/publish.yml))

The shipped template is hardened to the patterns below — adapt the marked points
and drop it in `.github/workflows/`. Non-negotiables it encodes:

- **`on: push: tags: ['v*']`** — release on a version tag, never on every push.
- **OIDC, no token:** the `publish` job has `permissions: id-token: write` and
  `pypa/gh-action-pypi-publish` with `attestations: true`. No `password:`/token.
- **`environment: pypi`** on the publish job → a human approves every release
  (defense-in-depth: even a compromised repo can't auto-ship).
- **Build/publish split:** a `build` job (no elevated perms) produces + uploads
  the `dist` artifact; `publish` downloads it. Least privilege per job.
- **`uv sync --locked` + `pip-audit`:** the release is built against the
  committed, hash-verified lockfile and blocked if a dep has a known CVE.
- **`twine check` / metadata validation** before upload.
- **SHA-pinned actions** with a trailing `# vX` comment (mutable tags get
  hijacked — see `check-action-pins.py`).
- **Verify-on-PyPI** tail job — polls the JSON API so a *silent* publish failure
  (accepted-but-not-live, CDN lag) surfaces loudly instead of looking fine.

## Supply-chain hardening — the publisher side

Stealing your publish credential lets an attacker ship malware to everyone who
installs you — so the publish path is the surface the 2026 worm campaign (Mini
Shai-Hulud) targets, minting PyPI/npm tokens from **stale OIDC trust and orphaned
workflows**. The template above isn't just convention; each choice is a defense:

| Control | Defends against |
|---|---|
| OIDC, no stored token | Credential theft/phishing — there is no long-lived secret to steal |
| PEP 740 attestations | Tampered artifacts — provenance is signed and verifiable |
| `environment: pypi` + reviewers | A compromised repo/CI auto-shipping — a human still gates the release |
| `pip-audit` gate | A knowingly-vulnerable dependency reaching the release build |
| SHA-pinned actions (`check-action-pins.py`) | Action-tag hijacks (tj-actions, 2025) repointing `@vN` to a malicious commit |
| `permissions: {}` + per-job least privilege | A poisoned build step escalating beyond read |
| `uv sync --locked` | Build-time dependency injection / silent re-resolution |

Then audit the **trust** itself, not just the workflow:

- **Revoke stale Trusted Publishers / OIDC federation** you no longer use — an
  orphaned publisher bound to a deletable workflow is the Mini Shai-Hulud entry
  point. Review PyPI → project → *Publishing* periodically.
- **If a token is in play, rotate it** (project-scoped, short-lived) — better,
  migrate to OIDC and delete it. See [trusted-publishing.md](references/trusted-publishing.md).
- **Vet build dependencies before a release**, not after — a poisoned `uv sync`
  step runs before your OIDC token is even minted.

Division of labour: **pypi-ops owns publisher hardening**; `supply-chain-defense`
owns the install side and ships `integrity-audit.sh` (hunts `pull_request_target`
+ OIDC misconfig and worm persistence) — run it on any repo that publishes, and
gate dependency bumps through its cooldown + behavioural scan.

## Cutting a release — preflight then tag

Before tagging, run the preflight so a release never fails on something
mechanical (version skew, dirty lock, missing publisher config):

```bash
scripts/publish-preflight.sh .                 # human summary; exit 10 = not ready
scripts/publish-preflight.sh --build .          # also build + twine-check the dist
scripts/publish-preflight.sh --json . | jq '.data[] | select(.ok==false)'
```

It checks: `pyproject` version == `__init__.__version__`, the version is **not
already on PyPI** (uploads are immutable — you cannot re-push `1.2.3`), the
lockfile self-version matches, a tag (if present) matches the version, and the
publish workflow uses OIDC (flags a stored token). `--build` additionally
verifies the package actually builds and passes `twine check`. Dynamic-versioned
projects (hatch-vcs / setuptools-scm) are read from the HEAD tag. Green → bump,
commit, tag, push the tag; CI builds, waits at the `pypi` environment gate, you
approve.

## When a publish fails — classify, don't guess

```bash
scripts/diagnose-publish.sh <run-id>           # reads gh run log, names the cause + fix
gh run view <run-id> --log-failed | scripts/diagnose-publish.sh -   # or pipe a log
```

The high-frequency failure classes and their fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `invalid-publisher` / claims not found | No (pending) publisher on PyPI | Register the pending publisher (above) |
| `File already exists` / 400 on upload | Version already on PyPI (immutable) | Bump the version; never reuse — see [recovery](references/recovery-playbook.md) |
| Job stuck "Waiting" | `environment: pypi` needs approval | Approve the deployment in the run's UI |
| `environment … not found` | Publisher claim names an env the job lacks | Make `environment:` and the publisher's Environment match |
| Built green, not on PyPI | Silent accept / no verify step | Add the verify-on-PyPI job; re-run |
| `non-OIDC`/token rejected | Token wrong/expired, or OIDC misread as token | Prefer OIDC; if token, rotate + re-store |

Full catalogue with the underlying mechanics: [references/recovery-playbook.md](references/recovery-playbook.md).

## Local & manual publishing (uv / twine)

For a one-off or a non-CI environment. **Prefer `uv` in 2026** (faster, native):

```bash
uv build                                   # sdist + wheel into dist/
uv publish --trusted-publishing automatic  # OIDC if in supported CI, else prompts
# token path (store in ~/.pypirc or env, never inline on the CLI history):
UV_PUBLISH_TOKEN="pypi-…" uv publish
```

`twine` remains the canonical fallback and the metadata validator (the GitHub
Action wraps it internally):

```bash
python -m twine check dist/*               # ALWAYS run before any upload
python -m twine upload dist/*              # token from ~/.pypirc; legacy path
```

Never hand-roll the HTTP upload. Details + `~/.pypirc` shape:
[references/uv-publish.md](references/uv-publish.md).

## Dry-run on TestPyPI first

For a brand-new package or a risky metadata change, publish to **test.pypi.org**
first — it has its own separate accounts *and its own pending-publisher
registration*. Point the action at `repository-url: https://test.pypi.org/legacy/`
and register the pending publisher on TestPyPI. See
[references/trusted-publishing.md](references/trusted-publishing.md#testpypi).

## Keeping the workflow from rotting

The pinned action SHAs and `pypa/gh-action-pypi-publish` major drift over time.
The verifier flags it before a release does:

```bash
scripts/check-action-pins.py --offline .github/workflows/publish.yml   # structure: all pinned + commented
scripts/check-action-pins.py --live    .github/workflows/publish.yml   # resolve tags → flag SHA drift
```

`--offline` is the PR gate (every `uses:` is SHA-pinned with a `# vX` comment);
`--live` runs scheduled (resolves each pin against GitHub and exits 10 on drift,
7 if GitHub is unreachable — advisory, never a flaky block).

## Publishing many packages (a fleet)

When several repos publish the same way, don't copy `publish.yml` N times — each
copy drifts its own SHA pins. Hoist the publish job into a **reusable workflow**
(`on: workflow_call`) in one repo, and have each package's tiny caller pass its
dist name. OIDC still works: the *caller's* `workflow_ref` is what PyPI matches,
so **register each package's pending publisher against the caller** filename
(e.g. `release.yml`), not the shared one. One place to refresh pins
(`check-action-pins.py` on the reusable workflow); one approval gate definition;
per-package publishers. See [references/trusted-publishing.md](references/trusted-publishing.md)
for the claim that must match.

## Reference files

| File | Load when |
|---|---|
| [references/trusted-publishing.md](references/trusted-publishing.md) | Setting up OIDC, pending vs project publisher, OIDC claim semantics, environments, TestPyPI, token→OIDC migration |
| [references/recovery-playbook.md](references/recovery-playbook.md) | A publish failed and you need the full failure-class catalogue + mechanics |
| [references/uv-publish.md](references/uv-publish.md) | Local/manual publishing, `uv build`/`uv publish`, `twine`, `~/.pypirc`, build backends |
