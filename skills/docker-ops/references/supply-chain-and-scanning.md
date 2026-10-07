# Image Supply Chain and Scanning

What goes into an image, how to prove it, and how to keep it current. Vetting a package
before it enters a lockfile is supply-chain-defense's job. Wiring this into a pipeline is
ci-cd-ops'.

## Contents

- [The scanner incident that changed the rules](#the-scanner-incident-that-changed-the-rules)
- [Scanning](#scanning)
- [SBOM and provenance](#sbom-and-provenance)
- [Signing and verifying](#signing-and-verifying)
- [Pinning and keeping bases current](#pinning-and-keeping-bases-current)
- [Checking that tags exist](#checking-that-tags-exist)

## The scanner incident that changed the rules

On 2026-03-19, stolen credentials were used to publish a malicious Trivy v0.69.4 (binary,
packages and images, about 3 hours). Attackers also force-pushed 76 of the 77
`aquasecurity/trivy-action` tags and all 7 `setup-trivy` tags to an infostealer for up to
12 hours. On 03-22, Docker Hub-only images `aquasec/trivy:0.69.5` and `0.69.6` followed.
Aqua's advisory is GHSA-69fq-xp46-6x23. The lessons apply to every scanner and action:

- **A tag is not a version: pin actions by full commit SHA**, with the tag as a comment.
  Restored trivy-action tags now carry a `v` prefix, and some old tags were never restored.
- Install scanner binaries from a release you have verified (checksums, signatures), or
  pin the scanner image by digest.
- A scanner runs with your CI's credentials. Give the job read-only tokens.

## Scanning

```yaml
# GitHub Actions: trivy-action pinned by SHA (v0.36.0, 2026-04-22)
- uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
  with:
    image-ref: ghcr.io/acme/app:${{ github.sha }}
    severity: HIGH,CRITICAL
    ignore-unfixed: true
    exit-code: "1"
```

| Tool | Command | Notes |
|---|---|---|
| Trivy | `trivy image --severity HIGH,CRITICAL --ignore-unfixed app:1.4.0` | also scans Dockerfiles and Compose (`trivy config .`) |
| Grype | `grype app:1.4.0 --only-fixed --fail-on high` | pairs with Syft for SBOMs |
| Docker Scout | `docker scout cves app:1.4.0`, `docker scout recommendations app:1.4.0` | built into the docker CLI; recommends base-image updates |

`--ignore-unfixed` (or `--only-fixed`) keeps the gate on what you can actually fix today.
Track the unfixable rest separately, or the gate gets ignored. Scan the image you ship (by
digest), not a rebuild of it.

## SBOM and provenance

BuildKit attaches both as attestations at build time:

```bash
docker buildx build --sbom=true --provenance=mode=max -t ghcr.io/acme/app:1.4.0 --push .
docker buildx imagetools inspect ghcr.io/acme/app:1.4.0 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/acme/app:1.4.0 --format '{{ json .Provenance }}'
```

`mode=max` records the build's full inputs. That includes build-arg values, so it is one
more reason to keep secrets out of `ARG`.

## Signing and verifying

Keyless signing with Sigstore cosign, from CI with an OIDC identity. Sign the digest, never a tag:

```bash
cosign sign --yes ghcr.io/acme/app@sha256:<digest>
cosign verify ghcr.io/acme/app@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/acme/app/.github/workflows/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

On GitHub, artifact attestations do the same job. Run the attest-build-provenance action
(pinned by SHA) in the workflow, then check with `gh attestation verify oci://ghcr.io/acme/app:1.4.0 --owner acme`.
Verification belongs where the image is *deployed* (an admission policy in Kubernetes, see
kubernetes-ops). A signature nobody checks proves nothing.

## Pinning and keeping bases current

- Production `FROM` lines pin a digest: `FROM node:24-slim@sha256:<digest>`. Readable tag, immutable content.
- Let a bot move the digests. Renovate's `docker:pinDigests` preset pins them and opens
  update PRs. Dependabot's `docker` ecosystem updates `FROM` and Compose `image:` lines.
  Either way the base gets security fixes without anyone remembering to rebuild.
- Rebuild on a schedule (weekly) even when your code hasn't changed: the base's fixes only
  reach you through a rebuild.
- Runtime lines past end of life get no fixes at all. `docker-audit.py` reports
  `base-eol` from the floors in `assets/docker-facts.json`.

## Checking that tags exist

Tags disappear: a distroless family stops building, a vendor moves registries, an EOL line
stops getting new tags. Before a release, or weekly for docs that recommend images:

```bash
python "<skill-dir>/scripts/check-image-tags.py" --live .
```

Missing exits 10 (the tag is gone, or it no longer serves both linux/amd64 and linux/arm64).
Uncertain exits 7 (rate limits, network). Docker Hub is queried through its tags API, which
does not count against anonymous pull limits.
