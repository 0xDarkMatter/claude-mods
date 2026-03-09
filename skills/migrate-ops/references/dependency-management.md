# Dependency Management

Comprehensive guide to auditing, updating, and securing dependencies across ecosystems.

---

## Audit Tools by Ecosystem

### JavaScript / Node.js

```bash
# Built-in npm audit
npm audit                      # Show vulnerabilities
npm audit fix                  # Auto-fix where possible
npm audit fix --force          # Fix with major version bumps (risky)
npm audit --json               # JSON output for CI parsing

# npm audit in CI (fail on moderate+)
npx audit-ci --moderate        # Fail CI on moderate or higher

# Socket.dev (supply chain analysis)
# Detects: typosquatting, install scripts, obfuscated code
npx socket:npm info <package>

# Check for outdated packages
npm outdated                   # Show outdated direct deps
npx npm-check-updates          # Interactive update tool
npx npm-check-updates -u       # Update package.json

# Yarn
yarn audit
yarn upgrade-interactive

# pnpm
pnpm audit
pnpm update --interactive
```

### Python

```bash
# pip-audit (recommended)
pip install pip-audit
pip-audit                      # Scan installed packages
pip-audit -r requirements.txt  # Scan requirements file
pip-audit --fix                # Auto-update vulnerable packages
pip-audit -f json              # JSON output for CI

# Safety (alternative)
pip install safety
safety check                   # Scan installed packages
safety check -r requirements.txt

# Check outdated
pip list --outdated

# uv (fast alternative)
uv pip list --outdated
uv pip audit                   # If available in your uv version
```

### Rust

```bash
# cargo-audit
cargo install cargo-audit
cargo audit                    # Check for known vulnerabilities
cargo audit fix                # Auto-apply fixes (where possible)

# cargo-deny (comprehensive policy enforcement)
cargo install cargo-deny
cargo deny check advisories    # Security advisories
cargo deny check bans          # Banned crate checks
cargo deny check licenses      # License compliance
cargo deny check sources       # Source restrictions

# Check outdated
cargo outdated                 # Requires cargo-outdated
cargo update --dry-run         # Show what would update
```

### Go

```bash
# govulncheck (official Go vulnerability checker)
go install golang.org/x/vuln/cmd/govulncheck@latest
govulncheck ./...              # Scan project
govulncheck -mode binary app   # Scan compiled binary

# Check for updates
go list -m -u all              # List all modules with available updates
go get -u ./...                # Update all dependencies
go mod tidy                    # Clean up go.sum

# Nancy (Sonatype vulnerability scanner)
go list -m -json all | nancy sleuth
```

### PHP

```bash
# Composer built-in audit
composer audit                 # Check for known vulnerabilities
composer audit --format=json   # JSON output for CI

# Check outdated
composer outdated              # All outdated
composer outdated --direct     # Only direct dependencies

# Symfony security checker
composer require --dev sensiolabs/security-checker
vendor/bin/security-checker security:check
```

### Ruby

```bash
# bundler-audit
gem install bundler-audit
bundle audit check             # Scan Gemfile.lock
bundle audit update            # Update vulnerability database

# Check outdated
bundle outdated
```

### Multi-Ecosystem

```bash
# Trivy (containers, filesystems, git repos)
trivy fs .                     # Scan current directory
trivy image myapp:latest       # Scan container image
trivy repo https://github.com/org/repo

# Snyk
snyk test                      # Test for vulnerabilities
snyk monitor                   # Monitor for new vulnerabilities

# OSV-Scanner (Google)
osv-scanner -r .               # Recursive scan
osv-scanner --lockfile=package-lock.json
```

---

## Dependency Update Strategies

### Automated Update Services

| Service | Ecosystems | Key Features |
|---------|-----------|-------------|
| **Dependabot** | npm, pip, Cargo, Go, Composer, Bundler, Docker, GitHub Actions | GitHub-native, grouped updates, auto-merge rules |
| **Renovate** | 50+ managers | Highly configurable, monorepo support, custom rules, self-hosted option |
| **Snyk** | npm, pip, Go, Java, .NET, Ruby | Security-focused, fix PRs, runtime monitoring |

### Dependabot Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: npm
    directory: "/"
    schedule:
      interval: weekly
      day: monday
    open-pull-requests-limit: 10
    groups:
      dev-dependencies:
        dependency-type: development
      minor-and-patch:
        update-types: [minor, patch]
    ignore:
      - dependency-name: "aws-sdk"
        update-types: ["version-update:semver-major"]

  - package-ecosystem: docker
    directory: "/"
    schedule:
      interval: weekly

  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly
```

### Renovate Configuration

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "group:allNonMajor",
    ":automergeMinor",
    ":automergePatch"
  ],
  "packageRules": [
    {
      "matchUpdateTypes": ["major"],
      "automerge": false,
      "labels": ["breaking-change"]
    },
    {
      "matchDepTypes": ["devDependencies"],
      "automerge": true
    }
  ],
  "schedule": ["before 7am on Monday"]
}
```

### Manual Update Workflow

```
When to update manually:
│
├─ Major version bump
│  1. Read CHANGELOG.md / release notes
│  2. Check for breaking changes
│  3. Check if codemods exist
│  4. Create feature branch
│  5. Update dependency
│  6. Run tests
│  7. Fix breaking changes
│  8. Run full CI pipeline
│  9. Review diff carefully
│  10. Merge when green
│
├─ Security patch (critical)
│  1. Verify advisory affects your usage
│  2. Update to patched version
│  3. Run tests
│  4. Deploy immediately
│
└─ Minor / patch version
   1. Update dependency
   2. Run tests
   3. Spot-check changelog for surprises
   4. Merge
```

---

## Lock File Management

### When to Regenerate Lock Files

```
Should you regenerate the lock file?
│
├─ Lock file has merge conflicts
│  └─ YES: Delete lock file, reinstall, commit
│     npm: rm package-lock.json && npm install
│     yarn: rm yarn.lock && yarn install
│     pnpm: rm pnpm-lock.yaml && pnpm install
│     pip: rm requirements.txt && pip freeze > requirements.txt
│     cargo: rm Cargo.lock && cargo generate-lockfile
│
├─ Dependency resolution is broken
│  └─ YES: Delete lock file, clean cache, reinstall
│     npm: rm -rf node_modules package-lock.json && npm cache clean --force && npm install
│     pip: pip cache purge && pip install -r requirements.txt
│
├─ Routine update
│  └─ NO: Use update commands that modify lock file in place
│     npm update / yarn upgrade / pnpm update
│     cargo update
│
└─ CI builds are inconsistent
   └─ Check: Is lock file committed? If not, commit it.
      Applications: ALWAYS commit lock files
      Libraries: Commit lock files (for CI reproducibility)
```

### Lock File Conflict Resolution

```bash
# npm
git checkout --theirs package-lock.json  # accept incoming
npm install                              # regenerate properly

# yarn
git checkout --theirs yarn.lock
yarn install

# pnpm
git checkout --theirs pnpm-lock.yaml
pnpm install

# Cargo
git checkout --theirs Cargo.lock
cargo update

# Go
git checkout --theirs go.sum
go mod tidy

# Composer
git checkout --theirs composer.lock
composer update --lock
```

---

## Major Version Upgrade Workflow

Detailed workflow for upgrading a dependency by one or more major versions.

### Step 1: Research

```bash
# Read the changelog
# GitHub: check Releases page
# npm: npm info <package> changelog
# Or find CHANGELOG.md / CHANGES.md / HISTORY.md in repo

# Check breaking changes
# Search for: "BREAKING", "removed", "renamed", "changed"
# Look for migration guide

# Check your usage of affected APIs
rg "importedFunction|removedAPI" src/
```

### Step 2: Check Compatibility

```bash
# npm: check peer dependency requirements
npm info <package>@latest peerDependencies

# Check if other deps are compatible
npm ls <package>  # see who depends on it

# Python: check classifiers and python_requires
pip show <package> | rg -i "requires"

# Go: check go.mod requirements of dependency
go mod graph | rg <module>
```

### Step 3: Update

```bash
# Create a branch
git checkout -b upgrade/<package>-v<version>

# npm
npm install <package>@latest

# pip
pip install <package>==<version>

# cargo
cargo update -p <crate> --precise <version>

# go
go get <module>@v<version>
go mod tidy

# composer
composer require <package>:<version>
```

### Step 4: Fix and Test

```bash
# Run type checker first (catches API shape changes)
npx tsc --noEmit        # TypeScript
mypy .                   # Python
go vet ./...             # Go

# Run tests
npm test                 # Node.js
pytest                   # Python
cargo test               # Rust
go test ./...            # Go
php artisan test         # Laravel

# Run linter
npm run lint
ruff check .
cargo clippy
golangci-lint run
```

### Step 5: Verify

```bash
# Build for production
npm run build
cargo build --release
go build ./...

# Run integration/e2e tests if available
npm run test:e2e
pytest tests/integration/
```

---

## Monorepo Dependency Management

### npm/pnpm/yarn Workspaces

```bash
# List workspace packages
npm ls --all --workspaces

# Update a dependency across all workspaces
npm update <package> --workspaces

# Install a dependency in a specific workspace
npm install <package> --workspace=packages/core

# Check for inconsistent versions across workspaces
npx syncpack list-mismatches

# Fix inconsistent versions
npx syncpack fix-mismatches
```

### Shared Version Strategy

```
Monorepo version strategy:
│
├─ Single version policy (recommended for most teams)
│  All packages use the same version of shared dependencies
│  Enforced with: syncpack, manypkg, or Renovate grouping
│  Pros: consistent behavior, simpler debugging
│  Cons: all packages must be compatible with same version
│
├─ Independent versions
│  Each package manages its own dependency versions
│  Pros: flexibility, independent upgrade cycles
│  Cons: version conflicts, larger node_modules, harder debugging
│
└─ Hybrid
   Pin shared infrastructure deps (React, TypeScript)
   Allow independent versions for leaf dependencies
```

### Turborepo / Nx Considerations

```bash
# Turborepo: ensure dependency changes trigger correct rebuilds
# turbo.json should include package.json in inputs

# Nx: use nx migrate for framework updates
npx nx migrate latest
npx nx migrate --run-migrations
```

---

## Vendoring vs Lock Files

### Decision Tree

```
Should you vendor dependencies?
│
├─ Deploying to air-gapped environment
│  └─ YES: Vendor everything
│
├─ Registry availability is critical
│  └─ YES: Vendor to protect against registry outages
│
├─ Reproducible builds without network access
│  └─ YES: Vendor dependencies
│
├─ Open source library
│  └─ NO: Use lock files, vendoring bloats the repo
│
├─ Standard web application
│  └─ NO: Lock files are sufficient
│
└─ Go modules
   └─ CONSIDER: Go vendor is well-supported
      go mod vendor  # creates vendor/ directory
      go build -mod=vendor
```

### Vendoring by Ecosystem

```bash
# Go
go mod vendor
# Build with: go build -mod=vendor ./...

# Python (pip download)
pip download -r requirements.txt -d vendor/
# Install from: pip install --no-index --find-links=vendor/ -r requirements.txt

# Node.js (not common, but possible)
# Use npm pack to create tarballs
# Or use pnpm with node_modules layout

# Rust
# Use cargo-vendor
cargo vendor
# Configure .cargo/config.toml to use vendored sources
```

---

## License Compliance Checking

### Tools

```bash
# Node.js
npx license-checker --summary
npx license-checker --failOn "GPL-3.0;AGPL-3.0"
npx license-checker --production  # only production deps

# Python
pip install pip-licenses
pip-licenses --format=table
pip-licenses --fail-on="GPLv3;AGPL-3.0"

# Rust
cargo deny check licenses

# Go
go install github.com/google/go-licenses@latest
go-licenses check ./...
go-licenses report ./...

# Multi-ecosystem
# FOSSA: https://fossa.com
# Snyk: snyk test --license
```

### License Compatibility Matrix

| Your License | Compatible Dependencies | Incompatible |
|-------------|------------------------|-------------|
| MIT | MIT, BSD, ISC, Apache-2.0, Unlicense | - |
| Apache-2.0 | MIT, BSD, ISC, Apache-2.0, Unlicense | GPL-2.0 (debated) |
| GPL-3.0 | MIT, BSD, ISC, Apache-2.0, GPL-2.0, LGPL, AGPL | Proprietary |
| Proprietary | MIT, BSD, ISC, Apache-2.0, Unlicense | GPL, AGPL, LGPL (static) |

### Cargo Deny License Config

```toml
# deny.toml
[licenses]
allow = [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Unicode-3.0",
]
deny = [
    "AGPL-3.0",
]
confidence-threshold = 0.8
```

---

## Supply Chain Security

### npm Provenance

```bash
# Verify package provenance (npm 9.5+)
npm audit signatures

# Publish with provenance (in GitHub Actions)
npm publish --provenance

# Check a specific package
npm view <package> --json | jq '.dist.attestations'
```

### Sigstore / cosign

```bash
# Verify container image signatures
cosign verify --key cosign.pub myregistry/myimage:tag

# Sign a container image
cosign sign --key cosign.key myregistry/myimage:tag

# Verify in CI
cosign verify --certificate-identity user@example.com \
  --certificate-oidc-issuer https://accounts.google.com \
  myregistry/myimage:tag
```

### cargo-vet (Rust)

```bash
# Initialize cargo-vet
cargo vet init

# Certify a crate after review
cargo vet certify <crate> <version>

# Import trusted audits from other organizations
cargo vet trust <organization>

# Check all dependencies are vetted
cargo vet
```

### Supply Chain Best Practices

```
Supply chain security checklist:
│
├─ [ ] Lock files committed and reviewed in PRs
├─ [ ] Dependabot or Renovate configured for automated updates
├─ [ ] npm audit / pip-audit / cargo audit in CI pipeline
├─ [ ] npm audit signatures verified (if using npm)
├─ [ ] Avoid running arbitrary install scripts (npm ignore-scripts)
├─ [ ] Pin GitHub Actions to SHA, not tag
│      Bad:  uses: actions/checkout@v4
│      Good: uses: actions/checkout@b4ffde65f46...
├─ [ ] Review new dependencies before adding
│      Check: download count, maintenance activity, known issues
├─ [ ] Use private registry or proxy for sensitive environments
├─ [ ] Container images signed and verified
├─ [ ] SBOM (Software Bill of Materials) generated for releases
│      Tools: syft, cyclonedx-cli, npm sbom
└─ [ ] Socket.dev or similar for install-time behavior analysis
```

### SBOM Generation

```bash
# Syft (Anchore)
syft dir:. -o spdx-json > sbom.json
syft myimage:tag -o cyclonedx-json > sbom.json

# npm (built-in)
npm sbom --sbom-format cyclonedx

# CycloneDX
# Python
pip install cyclonedx-bom
cyclonedx-py environment -o sbom.json

# Go
go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@latest
cyclonedx-gomod mod -output sbom.json

# Rust
cargo install cargo-cyclonedx
cargo cyclonedx --format json
```

---

## Dependency Update CI Integration

### GitHub Actions Example

```yaml
name: Dependency Audit
on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '0 8 * * 1'  # Weekly Monday 8am

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: npm audit
        run: npm audit --audit-level=moderate

      - name: License check
        run: npx license-checker --failOn "GPL-3.0;AGPL-3.0" --production

      - name: Check for outdated deps
        run: npm outdated || true  # informational, don't fail
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit or via pre-commit framework

# Check for new dependencies without lock file update
if git diff --cached --name-only | rg -q "package\.json"; then
  if ! git diff --cached --name-only | rg -q "package-lock\.json"; then
    echo "ERROR: package.json changed but package-lock.json was not updated"
    echo "Run: npm install"
    exit 1
  fi
fi
```
