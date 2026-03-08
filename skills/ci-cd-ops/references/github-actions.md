# GitHub Actions Reference

## Table of Contents

- [Workflow File Anatomy](#workflow-file-anatomy)
- [Job Dependencies and Conditionals](#job-dependencies-and-conditionals)
- [Reusable Workflows](#reusable-workflows)
- [Composite Actions](#composite-actions)
- [Matrix Strategy](#matrix-strategy)
- [Artifacts](#artifacts)
- [Environment Protection Rules](#environment-protection-rules)
- [Concurrency Control](#concurrency-control)
- [Self-Hosted Runners](#self-hosted-runners)
- [OIDC for Cloud Deployment](#oidc-for-cloud-deployment)
- [Common Action Recipes](#common-action-recipes)
- [Debugging Workflows](#debugging-workflows)

---

## Workflow File Anatomy

Every workflow lives in `.github/workflows/*.yml`. A complete annotated example:

```yaml
# .github/workflows/ci.yml
name: CI Pipeline                     # Name shown in Actions tab

# ── Triggers ──────────────────────────────────────────────
on:
  push:
    branches: [main, 'release/**']
    paths-ignore: ['docs/**', '*.md']
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
  schedule:
    - cron: '0 6 * * 1'              # Weekly Monday 6am UTC
  workflow_dispatch:                   # Manual trigger
    inputs:
      environment:
        description: 'Deploy target'
        required: true
        default: 'staging'
        type: choice
        options: [staging, production]

# ── Token Permissions (least privilege) ───────────────────
permissions:
  contents: read
  pull-requests: write
  checks: write

# ── Concurrency ──────────────────────────────────────────
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

# ── Workflow Environment ─────────────────────────────────
env:
  CI: true
  NODE_ENV: test

# ── Jobs ─────────────────────────────────────────────────
jobs:
  lint:
    name: Lint & Format
    runs-on: ubuntu-latest
    timeout-minutes: 10               # Prevent hung jobs
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: '.nvmrc'
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run format:check

  test:
    name: Test (${{ matrix.node-version }})
    runs-on: ubuntu-latest
    timeout-minutes: 15
    needs: lint                       # Run after lint passes
    strategy:
      fail-fast: false
      matrix:
        node-version: [18, 20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: npm
      - run: npm ci
      - run: npm test -- --coverage
      - uses: actions/upload-artifact@v4
        if: always()                  # Upload even on failure
        with:
          name: coverage-${{ matrix.node-version }}
          path: coverage/
          retention-days: 7

  deploy:
    name: Deploy
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: production           # Requires approval
    steps:
      - uses: actions/checkout@v4
      - run: ./deploy.sh
        env:
          DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

## Job Dependencies and Conditionals

### Job Dependencies with `needs`

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps: [...]

  test:
    needs: build                      # Waits for build
    runs-on: ubuntu-latest
    steps: [...]

  deploy:
    needs: [build, test]              # Waits for both
    runs-on: ubuntu-latest
    steps: [...]
```

### Conditional Execution with `if`

```yaml
jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest

  notify:
    needs: deploy
    if: always()                      # Run even if deploy fails
    runs-on: ubuntu-latest

  release:
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest

steps:
  - run: echo "Only on failure"
    if: failure()

  - run: echo "Only on success"
    if: success()

  - run: echo "Always run (cleanup)"
    if: always()

  - run: echo "Skip on forks"
    if: github.repository == 'owner/repo'

  - run: echo "Only for specific actor"
    if: github.actor == 'dependabot[bot]'

  - run: echo "Check PR label"
    if: contains(github.event.pull_request.labels.*.name, 'deploy')
```

### Accessing Outputs from `needs`

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    outputs:
      should-deploy: ${{ steps.decision.outputs.deploy }}
    steps:
      - id: decision
        run: |
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            echo "deploy=true" >> "$GITHUB_OUTPUT"
          else
            echo "deploy=false" >> "$GITHUB_OUTPUT"
          fi

  deploy:
    needs: check
    if: needs.check.outputs.should-deploy == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying..."
```

## Reusable Workflows

### Defining a Reusable Workflow

```yaml
# .github/workflows/reusable-test.yml
name: Reusable Test Workflow
on:
  workflow_call:
    inputs:
      node-version:
        description: 'Node.js version'
        required: false
        default: '20'
        type: string
      working-directory:
        description: 'Directory to run tests in'
        required: false
        default: '.'
        type: string
    secrets:
      NPM_TOKEN:
        required: false
        description: 'NPM auth token'
    outputs:
      coverage-percent:
        description: 'Test coverage percentage'
        value: ${{ jobs.test.outputs.coverage }}

jobs:
  test:
    runs-on: ubuntu-latest
    outputs:
      coverage: ${{ steps.cov.outputs.percent }}
    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ inputs.node-version }}
          cache: npm
      - run: npm ci
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
      - run: npm test -- --coverage
      - id: cov
        run: |
          PERCENT=$(jq '.total.lines.pct' coverage/coverage-summary.json)
          echo "percent=$PERCENT" >> "$GITHUB_OUTPUT"
```

### Calling a Reusable Workflow

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    uses: ./.github/workflows/reusable-test.yml
    with:
      node-version: '20'
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}

  # Or inherit all secrets
  test-inherit:
    uses: ./.github/workflows/reusable-test.yml
    secrets: inherit

  # Call from another repo
  test-external:
    uses: org/shared-workflows/.github/workflows/test.yml@main
    with:
      node-version: '20'

  report:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - run: echo "Coverage was ${{ needs.test.outputs.coverage-percent }}%"
```

## Composite Actions

### Creating a Composite Action

```yaml
# .github/actions/setup-project/action.yml
name: 'Setup Project'
description: 'Install dependencies and build'
inputs:
  node-version:
    description: 'Node.js version'
    required: false
    default: '20'
  install-command:
    description: 'Install command'
    required: false
    default: 'npm ci'
outputs:
  cache-hit:
    description: 'Whether cache was hit'
    value: ${{ steps.cache.outputs.cache-hit }}

runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
      with:
        node-version: ${{ inputs.node-version }}

    - id: cache
      uses: actions/cache@v4
      with:
        path: node_modules
        key: node-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

    - if: steps.cache.outputs.cache-hit != 'true'
      run: ${{ inputs.install-command }}
      shell: bash

    - run: npm run build
      shell: bash                     # shell: is REQUIRED in composite
```

### Using a Composite Action

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: ./.github/actions/setup-project
    with:
      node-version: '22'
  - run: npm test
```

## Matrix Strategy

### Basic Matrix

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, windows-latest, macos-latest]
    node: [18, 20, 22]
    # Creates 3 x 3 = 9 jobs
```

### Include and Exclude

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, windows-latest]
    node: [18, 20]
    include:
      # Add a job with extra variables
      - os: ubuntu-latest
        node: 22
        experimental: true
      # Add variables to existing combo
      - os: windows-latest
        node: 20
        npm-version: 10
    exclude:
      # Remove a specific combo
      - os: windows-latest
        node: 18
```

### Matrix with `continue-on-error`

```yaml
strategy:
  fail-fast: false
  matrix:
    node: [18, 20, 22]
    include:
      - node: 22
        experimental: true

jobs:
  test:
    continue-on-error: ${{ matrix.experimental || false }}
```

### Single-Dimension Matrix (List of Configs)

```yaml
strategy:
  matrix:
    include:
      - name: Unit Tests
        command: npm run test:unit
      - name: Integration Tests
        command: npm run test:integration
        timeout: 30
      - name: E2E Tests
        command: npm run test:e2e
        timeout: 60
```

## Artifacts

### Upload and Download Between Jobs

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build

      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/
          retention-days: 1           # Short-lived build artifacts
          if-no-files-found: error    # Fail if nothing to upload

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: dist
          path: dist/

      - run: ls -la dist/            # Verify download
```

### Multiple Artifact Upload (Matrix)

```yaml
# Upload with unique names per matrix
- uses: actions/upload-artifact@v4
  with:
    name: results-${{ matrix.os }}-${{ matrix.node }}
    path: test-results/

# Download all in a later job
- uses: actions/download-artifact@v4
  with:
    pattern: results-*
    merge-multiple: true
    path: all-results/
```

## Environment Protection Rules

Environments provide deployment gates and scoped secrets.

### Setting Up Environments

Environments are configured in **Settings > Environments** on GitHub. Options:

| Setting | Purpose |
|---------|---------|
| Required reviewers | Manual approval before deployment (up to 6 reviewers) |
| Wait timer | Delay in minutes before deployment proceeds |
| Deployment branches | Restrict which branches can deploy (e.g., only `main`) |
| Environment secrets | Secrets scoped to this environment only |
| Environment variables | Variables scoped to this environment |

### Using Environments in Workflows

```yaml
jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    environment:
      name: staging
      url: https://staging.example.com   # Shown in deployment status
    steps:
      - run: deploy --env staging
        env:
          API_KEY: ${{ secrets.API_KEY }}  # Environment-scoped secret

  deploy-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://example.com
    steps:
      - run: deploy --env production
```

## Concurrency Control

### Cancel Previous Runs on Same Branch

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

### Deployment Queue (No Cancellation)

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false           # Queue instead of cancel
```

### Per-PR Concurrency

```yaml
concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

## Self-Hosted Runners

### Runner Labels

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, gpu]    # Match all labels
```

### Runner Groups (Enterprise/Org)

```yaml
jobs:
  build:
    runs-on:
      group: production-runners
      labels: [linux, x64]
```

### Hybrid Strategy

```yaml
strategy:
  matrix:
    runner: [ubuntu-latest, self-hosted]

jobs:
  test:
    runs-on: ${{ matrix.runner }}
```

## OIDC for Cloud Deployment

OIDC eliminates stored cloud credentials. GitHub issues a short-lived JWT that your cloud provider trusts.

### AWS

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789012:role/GitHubActions
      aws-region: us-east-1
      # No access keys needed

  - run: aws s3 sync dist/ s3://my-bucket
```

### GCP

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: 'projects/123/locations/global/workloadIdentityPools/github/providers/my-repo'
      service_account: 'deploy@my-project.iam.gserviceaccount.com'

  - uses: google-github-actions/setup-gcloud@v2

  - run: gcloud run deploy my-service --image gcr.io/my-project/app
```

### Azure

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

  - run: az webapp deploy --name my-app --src-path dist/
```

## Common Action Recipes

### Checkout

```yaml
# Standard checkout
- uses: actions/checkout@v4

# Full history (for changelogs, git describe)
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

# Checkout PR head (for pull_request_target)
- uses: actions/checkout@v4
  with:
    ref: ${{ github.event.pull_request.head.sha }}

# Checkout with submodules
- uses: actions/checkout@v4
  with:
    submodules: recursive
    token: ${{ secrets.PAT }}         # For private submodules
```

### Setup Node.js

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    cache: npm                        # Or pnpm, yarn
    registry-url: https://npm.pkg.github.com
```

### Setup Go

```yaml
- uses: actions/setup-go@v5
  with:
    go-version-file: go.mod           # Read from go.mod
    cache: true                       # Cache go modules
```

### Setup Python

```yaml
- uses: actions/setup-python@v5
  with:
    python-version: '3.12'
    cache: pip                        # Or pipenv, poetry
```

### Docker Build and Push

```yaml
- uses: docker/setup-buildx-action@v3

- uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- uses: docker/metadata-action@v5
  id: meta
  with:
    images: ghcr.io/${{ github.repository }}
    tags: |
      type=semver,pattern={{version}}
      type=semver,pattern={{major}}.{{minor}}
      type=sha,prefix=
      type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
    platforms: linux/amd64,linux/arm64
```

## Debugging Workflows

### Enable Debug Logging

Set repository secret `ACTIONS_STEP_DEBUG` to `true` for verbose step output.

Or re-run a failed job with "Enable debug logging" checkbox.

### Debug Expressions

```yaml
- run: |
    echo "Event: ${{ github.event_name }}"
    echo "Ref: ${{ github.ref }}"
    echo "SHA: ${{ github.sha }}"
    echo "Actor: ${{ github.actor }}"
    echo "Matrix: ${{ toJson(matrix) }}"
    echo "Env: ${{ toJson(env) }}"

# Dump full event payload
- run: cat "$GITHUB_EVENT_PATH" | jq .
```

### Local Testing with `act`

```bash
# Install act (https://github.com/nektos/act)
brew install act                      # macOS
choco install act-cli                 # Windows

# Run default event (push)
act

# Run specific workflow
act -W .github/workflows/ci.yml

# Run specific job
act -j test

# Run with specific event
act pull_request

# Pass secrets
act -s GITHUB_TOKEN="$(gh auth token)"

# Use specific runner image
act -P ubuntu-latest=catthehacker/ubuntu:act-latest

# Dry run (show what would run)
act -n
```

### Common Debugging Patterns

```yaml
# Temporarily add to any step
- run: |
    echo "::group::Debug Info"
    env | sort
    echo "::endgroup::"

# Check file existence
- run: |
    echo "::group::Workspace Contents"
    find . -maxdepth 3 -type f | head -50
    echo "::endgroup::"

# Conditional debug step
- if: runner.debug == '1'
  run: |
    echo "Debug mode enabled"
    cat package.json | jq '.scripts'
```

### Workflow Run Annotations

```yaml
# Warning annotation
- run: echo "::warning file=app.js,line=1::Missing error handling"

# Error annotation
- run: echo "::error file=app.js,line=10,col=5::Syntax error"

# Notice annotation
- run: echo "::notice::Deployment complete"

# Group log lines
- run: |
    echo "::group::Install Dependencies"
    npm ci
    echo "::endgroup::"
```
