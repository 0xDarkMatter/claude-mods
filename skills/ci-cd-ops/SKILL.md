---
name: ci-cd-ops
description: "CI/CD pipeline patterns with GitHub Actions, release automation, and testing strategies. Use for: github actions, workflow, CI, CD, pipeline, deploy, release, semantic release, changesets, goreleaser, matrix, cache, secrets, environment, artifact, reusable workflow, composite action."
allowed-tools: "Read Write Bash"
related-skills: [git-ops, docker-ops, testing-ops]
---

# CI/CD Operations

Comprehensive patterns for continuous integration, delivery, and deployment using GitHub Actions, release automation tools, and testing pipelines.

## GitHub Actions Quick Reference

### Workflow File Anatomy

```yaml
name: CI                          # Display name in Actions tab
on:                               # Trigger events
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:                      # GITHUB_TOKEN scope (least privilege)
  contents: read
  pull-requests: write

concurrency:                      # Prevent duplicate runs
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:                              # Workflow-level environment variables
  NODE_VERSION: "20"

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm
      - run: npm ci
      - run: npm test
```

### Core Syntax Elements

| Element | Purpose | Example |
|---------|---------|---------|
| `on` | Event triggers | `push`, `pull_request`, `schedule` |
| `jobs.<id>.runs-on` | Runner selection | `ubuntu-latest`, `self-hosted` |
| `jobs.<id>.needs` | Job dependencies | `needs: [build, lint]` |
| `jobs.<id>.if` | Conditional execution | `if: github.event_name == 'push'` |
| `jobs.<id>.strategy.matrix` | Parallel variants | `node-version: [18, 20, 22]` |
| `jobs.<id>.environment` | Deployment target | `environment: production` |
| `jobs.<id>.permissions` | Token scope | `contents: write` |
| `steps[*].uses` | Use an action | `uses: actions/checkout@v4` |
| `steps[*].run` | Run a command | `run: npm test` |
| `steps[*].env` | Step environment | `env: { CI: true }` |

## Trigger Decision Tree

| Scenario | Trigger | Config |
|----------|---------|--------|
| Run tests on every PR | `pull_request` | `branches: [main]` |
| Deploy on merge to main | `push` | `branches: [main]` |
| Release on version tag | `push` | `tags: ['v*']` |
| Nightly builds | `schedule` | `cron: '0 2 * * *'` |
| Manual deployment | `workflow_dispatch` | `inputs: { environment: ... }` |
| Called by another workflow | `workflow_call` | `inputs:`, `secrets:` |
| On PR label change | `pull_request` | `types: [labeled]` |
| On issue comment | `issue_comment` | `types: [created]` |
| On release published | `release` | `types: [published]` |
| On package push | `registry_package` | `types: [published]` |

### Trigger Filter Patterns

```yaml
on:
  push:
    branches: [main, 'release/**']      # Branch patterns
    paths: ['src/**', '!src/**/*.test.*'] # Path filters (ignore tests)
    tags: ['v*']                          # Tag patterns
  pull_request:
    types: [opened, synchronize, reopened] # Default types
    paths-ignore: ['docs/**', '*.md']     # Ignore docs-only changes
```

## Caching Strategies

| Ecosystem | Action / Key | Path | Restore Key |
|-----------|-------------|------|-------------|
| Node (npm) | `actions/setup-node` with `cache: npm` | Auto | Auto |
| Node (pnpm) | `actions/setup-node` with `cache: pnpm` | Auto | Auto |
| Go modules | `actions/setup-go` with `cache: true` | Auto | Auto |
| Cargo | `actions/cache@v4` | `~/.cargo/registry`, `target` | `cargo-${{ runner.os }}-${{ hashFiles('Cargo.lock') }}` |
| pip / uv | `actions/setup-python` with `cache: pip` | Auto | Auto |
| Docker layers | `docker/build-push-action` | Uses buildx cache | `type=gha` or `type=registry` |
| Gradle | `actions/setup-java` with `cache: gradle` | Auto | Auto |
| Composer | `actions/cache@v4` | `vendor` | `composer-${{ hashFiles('composer.lock') }}` |

### Manual Cache Example

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/bin
      ~/.cargo/registry
      ~/.cargo/git
      target
    key: cargo-${{ runner.os }}-${{ hashFiles('**/Cargo.lock') }}
    restore-keys: |
      cargo-${{ runner.os }}-
```

## Matrix Strategy

```yaml
strategy:
  fail-fast: false                    # Don't cancel siblings on failure
  max-parallel: 4                     # Limit concurrent jobs
  matrix:
    os: [ubuntu-latest, windows-latest, macos-latest]
    node-version: [18, 20, 22]
    include:                          # Add specific combos
      - os: ubuntu-latest
        node-version: 22
        coverage: true
    exclude:                          # Remove specific combos
      - os: windows-latest
        node-version: 18
```

### Dynamic Matrix

```yaml
prepare:
  runs-on: ubuntu-latest
  outputs:
    matrix: ${{ steps.set.outputs.matrix }}
  steps:
    - id: set
      run: echo "matrix=$(jq -c . matrix.json)" >> "$GITHUB_OUTPUT"

test:
  needs: prepare
  strategy:
    matrix: ${{ fromJson(needs.prepare.outputs.matrix) }}
```

## Secrets Management

| Scope | Access | Use Case |
|-------|--------|----------|
| Repository secrets | All workflows in repo | API keys, tokens |
| Environment secrets | Jobs targeting that environment | Production credentials |
| Organization secrets | Selected repos in org | Shared service accounts |
| OIDC tokens | Federated identity | Cloud deployment (no stored secrets) |

### Secrets Best Practices

```yaml
# Reference secrets - NEVER echo or log them
- run: deploy --token ${{ secrets.DEPLOY_TOKEN }}

# Mask custom values
- run: echo "::add-mask::$CUSTOM_SECRET"

# Use environments for deployment secrets
jobs:
  deploy:
    environment: production           # Requires approval + has secrets
    steps:
      - run: deploy --key ${{ secrets.PROD_API_KEY }}
```

### OIDC for Cloud (No Stored Secrets)

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789:role/github-actions
      aws-region: us-east-1
```

## Common Workflow Patterns

### Test on Pull Request

```yaml
name: Test
on:
  pull_request:
    branches: [main]
concurrency:
  group: test-${{ github.head_ref }}
  cancel-in-progress: true
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run lint
      - run: npm test -- --coverage
```

### Deploy on Merge to Main

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - run: npx wrangler deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
```

### Release on Tag

```yaml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: |
          gh release create ${{ github.ref_name }} \
            --generate-notes \
            --title "${{ github.ref_name }}"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Gotchas Table

| Gotcha | Problem | Fix |
|--------|---------|-----|
| Shallow clone | `git describe` fails, history missing | `actions/checkout@v4` with `fetch-depth: 0` |
| Default permissions | `GITHUB_TOKEN` is read-only by default | Set `permissions:` explicitly |
| Action pinning | `@main` can break without warning | Pin to SHA: `@abc123` or `@v4` |
| Fork PR secrets | Secrets unavailable on fork PRs | Use `pull_request_target` carefully |
| Concurrent deploys | Race condition on production | Use `concurrency:` groups |
| Stale caches | Cache grows unbounded | Include lockfile hash in key |
| Node.js version | `setup-node` defaults vary | Always specify `node-version` |
| Docker layer cache | Rebuilds everything without cache | Use `cache-from: type=gha` |
| Matrix + environment | Each matrix job needs approval | Use a single deploy job after matrix |
| Path filters + required checks | Skipped jobs block merge | Use `paths-filter` action or make checks non-required |
| `GITHUB_TOKEN` in PRs | Cannot trigger other workflows | Use a PAT or GitHub App token |
| Windows line endings | Scripts fail with `\r\n` | Use `.gitattributes` or `core.autocrlf` |

## Expression Syntax Quick Reference

| Expression | Result |
|------------|--------|
| `${{ github.event_name }}` | `push`, `pull_request`, etc. |
| `${{ github.ref_name }}` | Branch or tag name |
| `${{ github.sha }}` | Full commit SHA |
| `${{ github.actor }}` | User who triggered |
| `${{ runner.os }}` | `Linux`, `Windows`, `macOS` |
| `${{ contains(github.event.head_commit.message, '[skip ci]') }}` | Check commit message |
| `${{ needs.build.outputs.version }}` | Output from prior job |
| `${{ fromJson(steps.meta.outputs.json) }}` | Parse JSON output |
| `${{ hashFiles('**/package-lock.json') }}` | Hash for cache keys |
| `${{ format('refs/heads/{0}', matrix.branch) }}` | String formatting |
| `${{ toJson(matrix) }}` | Debug: print matrix config |

## Step Outputs

```yaml
steps:
  - id: version
    run: echo "value=$(cat VERSION)" >> "$GITHUB_OUTPUT"

  - run: echo "Version is ${{ steps.version.outputs.value }}"
```

### Job Outputs (for Cross-Job Communication)

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      artifact-id: ${{ steps.upload.outputs.artifact-id }}
    steps:
      - id: upload
        run: echo "artifact-id=abc123" >> "$GITHUB_OUTPUT"

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying ${{ needs.build.outputs.artifact-id }}"
```

## Reference Files

| File | Contents |
|------|----------|
| `references/github-actions.md` | Complete workflow syntax, reusable workflows, composite actions, OIDC, runners, debugging |
| `references/release-automation.md` | Semantic versioning, semantic-release, changesets, goreleaser, changelog, publishing |
| `references/testing-pipelines.md` | Test stages, parallelism, coverage, service containers, e2e in CI, deployment pipelines |
