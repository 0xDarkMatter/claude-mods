# Testing Pipelines Reference

## Table of Contents

- [Test Stages](#test-stages)
- [Parallel Test Execution](#parallel-test-execution)
- [Test Splitting Strategies](#test-splitting-strategies)
- [Code Coverage](#code-coverage)
- [Database Testing in CI](#database-testing-in-ci)
- [Docker in CI](#docker-in-ci)
- [E2E Testing in CI](#e2e-testing-in-ci)
- [Flaky Test Detection and Retry](#flaky-test-detection-and-retry)
- [Performance Testing in CI](#performance-testing-in-ci)
- [Status Checks and Branch Protection](#status-checks-and-branch-protection)
- [Pull Request Checks Workflow](#pull-request-checks-workflow)
- [Deployment Pipelines](#deployment-pipelines)

---

## Test Stages

A typical CI pipeline progresses through these stages, failing fast on cheap checks:

```
┌─────────┐   ┌──────────┐   ┌─────────────┐   ┌──────────┐   ┌────────┐
│  Lint    │──>│  Unit    │──>│ Integration │──>│  E2E     │──>│ Deploy │
│  ~1 min  │   │  ~2 min  │   │  ~5 min     │   │  ~10 min │   │        │
└─────────┘   └──────────┘   └─────────────┘   └──────────┘   └────────┘
```

### Stage Characteristics

| Stage | Speed | Dependencies | Flakiness | What It Catches |
|-------|-------|-------------|-----------|----------------|
| Lint / Format | Fastest | None | None | Style, syntax, type errors |
| Unit tests | Fast | None (mocked) | Low | Logic bugs, regressions |
| Integration | Medium | Services (DB, cache) | Medium | API contracts, data flow |
| E2E | Slow | Full environment | High | User-facing regressions |
| Performance | Slow | Full environment | Medium | Performance regressions |

### Staged Workflow

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run lint
      - run: npm run typecheck

  unit:
    needs: lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run test:unit -- --coverage

  integration:
    needs: lint
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_DB: test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run test:integration
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test

  e2e:
    needs: [unit, integration]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npm run test:e2e
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7
```

## Parallel Test Execution

### Matrix-Based Parallelism

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm test -- --shard=${{ matrix.shard }}/${{ strategy.job-total }}
```

### Playwright Sharding

```yaml
strategy:
  matrix:
    shard: [1/4, 2/4, 3/4, 4/4]
steps:
  - run: npx playwright test --shard=${{ matrix.shard }}

  - uses: actions/upload-artifact@v4
    if: always()
    with:
      name: blob-report-${{ strategy.job-index }}
      path: blob-report/

# Merge reports in a separate job
merge-reports:
  needs: test
  runs-on: ubuntu-latest
  steps:
    - uses: actions/download-artifact@v4
      with:
        pattern: blob-report-*
        merge-multiple: true
        path: all-blob-reports

    - run: npx playwright merge-reports --reporter html all-blob-reports
```

### Jest Parallelism

```yaml
# Jest auto-parallelizes across workers
- run: npx jest --maxWorkers=50%      # Use half available CPUs
- run: npx jest --maxWorkers=4        # Or specify exactly

# With sharding (Jest 28+)
- run: npx jest --shard=${{ matrix.shard }}/${{ strategy.job-total }}
```

## Test Splitting Strategies

### By File Count (Simple)

```bash
# Split test files evenly across shards
files=$(find src -name '*.test.ts' | sort)
total=$(echo "$files" | wc -l)
per_shard=$(( (total + SHARD_COUNT - 1) / SHARD_COUNT ))
echo "$files" | sed -n "${start},${end}p"
```

### By Timing (Optimal)

```yaml
# Use test timing data from previous runs
- uses: actions/cache@v4
  with:
    path: .test-timings
    key: test-timings-${{ github.ref }}
    restore-keys: test-timings-

- run: |
    npx jest --json --outputFile=results.json
    # Store timing data for next run
    jq '[.testResults[] | {file: .testFilePath, duration: .perfStats.runtime}]' \
      results.json > .test-timings
```

### By Test Type

```yaml
strategy:
  matrix:
    include:
      - name: unit
        command: npm run test:unit
        timeout: 10
      - name: integration
        command: npm run test:integration
        timeout: 20
      - name: e2e
        command: npm run test:e2e
        timeout: 30

jobs:
  test:
    timeout-minutes: ${{ matrix.timeout }}
    steps:
      - run: ${{ matrix.command }}
```

## Code Coverage

### Codecov

```yaml
- run: npm test -- --coverage

- uses: codecov/codecov-action@v4
  with:
    token: ${{ secrets.CODECOV_TOKEN }}
    files: coverage/lcov.info
    flags: unittests
    fail_ci_if_error: true
```

### Coveralls

```yaml
- run: npm test -- --coverage

- uses: coverallsapp/github-action@v2
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    path-to-lcov: coverage/lcov.info
```

### Coverage Gates

```yaml
# Fail if coverage drops
- run: |
    COVERAGE=$(jq '.total.lines.pct' coverage/coverage-summary.json)
    echo "Coverage: ${COVERAGE}%"
    if (( $(echo "$COVERAGE < 80" | bc -l) )); then
      echo "::error::Coverage ${COVERAGE}% is below 80% threshold"
      exit 1
    fi
```

### Multi-Platform Coverage Merge

```yaml
# Upload per-shard coverage
- uses: actions/upload-artifact@v4
  with:
    name: coverage-${{ matrix.shard }}
    path: coverage/

# Merge in separate job
merge-coverage:
  needs: test
  runs-on: ubuntu-latest
  steps:
    - uses: actions/download-artifact@v4
      with:
        pattern: coverage-*
        merge-multiple: true
        path: all-coverage

    - run: npx nyc merge all-coverage merged-coverage.json
    - run: npx nyc report --reporter=lcov --temp-dir=.

    - uses: codecov/codecov-action@v4
      with:
        token: ${{ secrets.CODECOV_TOKEN }}
```

## Database Testing in CI

### Service Containers

```yaml
services:
  postgres:
    image: postgres:16-alpine
    env:
      POSTGRES_DB: test_db
      POSTGRES_USER: test_user
      POSTGRES_PASSWORD: test_pass
    ports: ['5432:5432']
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5

  redis:
    image: redis:7-alpine
    ports: ['6379:6379']
    options: >-
      --health-cmd "redis-cli ping"
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5

  mysql:
    image: mysql:8
    env:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: test_db
    ports: ['3306:3306']
    options: >-
      --health-cmd "mysqladmin ping -h localhost"
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
```

### Testcontainers

```yaml
# Testcontainers manages its own containers - just needs Docker
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-java@v4
    with: { java-version: 21, distribution: temurin }

  # Testcontainers needs Docker socket access (default on ubuntu-latest)
  - run: ./gradlew test
    env:
      TESTCONTAINERS_RYUK_DISABLED: false
```

### Database Migrations in CI

```yaml
steps:
  - run: npm run db:migrate
    env:
      DATABASE_URL: postgresql://test_user:test_pass@localhost:5432/test_db

  - run: npm run db:seed           # Optional test data

  - run: npm run test:integration
    env:
      DATABASE_URL: postgresql://test_user:test_pass@localhost:5432/test_db
```

## Docker in CI

### Docker-in-Docker (DinD)

```yaml
# Not recommended for GitHub Actions - use standard Docker
# GitHub-hosted runners have Docker pre-installed

steps:
  - uses: actions/checkout@v4
  - run: docker build -t myapp .
  - run: docker run myapp npm test
```

### Docker-outside-of-Docker (DooD)

```yaml
# Mount the host Docker socket (for self-hosted runners)
# GitHub-hosted runners use this by default
steps:
  - run: docker compose up -d
  - run: docker compose run app npm test
  - run: docker compose down
```

### Docker Compose in CI

```yaml
steps:
  - uses: actions/checkout@v4

  - run: docker compose -f docker-compose.test.yml up -d --wait
  - run: docker compose -f docker-compose.test.yml run app npm test
  - run: docker compose -f docker-compose.test.yml down -v

  # Alternative: use --exit-code-from
  - run: docker compose -f docker-compose.test.yml up --exit-code-from test
```

## E2E Testing in CI

### Playwright

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-node@v4
    with: { node-version: 20, cache: npm }
  - run: npm ci

  # Install browsers (cache for speed)
  - name: Cache Playwright browsers
    uses: actions/cache@v4
    id: playwright-cache
    with:
      path: ~/.cache/ms-playwright
      key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

  - if: steps.playwright-cache.outputs.cache-hit != 'true'
    run: npx playwright install --with-deps chromium

  - if: steps.playwright-cache.outputs.cache-hit == 'true'
    run: npx playwright install-deps chromium

  # Run tests
  - run: npx playwright test
    env:
      CI: true

  # Upload artifacts on failure
  - uses: actions/upload-artifact@v4
    if: failure()
    with:
      name: playwright-report
      path: |
        playwright-report/
        test-results/
      retention-days: 7
```

### Cypress

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: cypress-io/github-action@v6
    with:
      build: npm run build
      start: npm start
      wait-on: 'http://localhost:3000'
      wait-on-timeout: 120
      browser: chrome
      record: true                    # Cypress Cloud recording
    env:
      CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}

  - uses: actions/upload-artifact@v4
    if: failure()
    with:
      name: cypress-screenshots
      path: cypress/screenshots/
```

### E2E with Containerized App

```yaml
steps:
  - uses: actions/checkout@v4

  # Start the app in Docker
  - run: docker compose up -d --wait

  # Run E2E tests against containerized app
  - run: npm ci
  - run: npx playwright test
    env:
      BASE_URL: http://localhost:3000

  - run: docker compose down -v
    if: always()
```

## Flaky Test Detection and Retry

### GitHub Actions Retry

```yaml
# Retry the entire job
- uses: nick-fields/retry@v3
  with:
    timeout_minutes: 10
    max_attempts: 3
    command: npm run test:e2e
    retry_on: error
```

### Built-in Test Runner Retries

```bash
# Playwright
npx playwright test --retries=2

# Jest
npx jest --bail --forceExit          # Fail fast, clean exit

# Vitest
npx vitest --retry=2

# pytest
pip install pytest-rerunfailures
pytest --reruns 3 --reruns-delay 1
```

### Flaky Test Quarantine Pattern

```yaml
jobs:
  stable-tests:
    runs-on: ubuntu-latest
    steps:
      - run: npm test -- --testPathIgnorePatterns='flaky'

  flaky-tests:
    runs-on: ubuntu-latest
    continue-on-error: true           # Don't block PR
    steps:
      - run: npm test -- --testPathPattern='flaky' --retries=3
```

### Detect New Flaky Tests

```yaml
# Run tests multiple times on PR to detect flakiness
- run: |
    for i in {1..5}; do
      echo "Run $i of 5"
      npm test -- --bail || exit 1
    done
```

## Performance Testing in CI

### Benchmark Comparison

```yaml
- uses: benchmark-action/github-action-benchmark@v1
  with:
    tool: 'customBiggerIsBetter'
    output-file-path: benchmark-results.json
    github-token: ${{ secrets.GITHUB_TOKEN }}
    auto-push: true
    alert-threshold: '150%'           # Alert if 50% slower
    comment-on-alert: true
    fail-on-alert: true
```

### Lighthouse CI

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-node@v4
    with: { node-version: 20, cache: npm }
  - run: npm ci && npm run build

  - name: Start server
    run: npm start &
    env: { PORT: 3000 }

  - run: npx @lhci/cli autorun
    env:
      LHCI_GITHUB_APP_TOKEN: ${{ secrets.LHCI_GITHUB_APP_TOKEN }}
```

### Lighthouse Configuration

```json
// lighthouserc.json
{
  "ci": {
    "collect": {
      "url": ["http://localhost:3000", "http://localhost:3000/about"],
      "numberOfRuns": 3
    },
    "assert": {
      "assertions": {
        "categories:performance": ["error", { "minScore": 0.9 }],
        "categories:accessibility": ["error", { "minScore": 0.95 }],
        "categories:best-practices": ["error", { "minScore": 0.9 }],
        "first-contentful-paint": ["warn", { "maxNumericValue": 2000 }]
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

### Bundle Size Check

```yaml
- uses: andresz1/size-limit-action@v1
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    # Reads config from .size-limit.json or package.json
```

## Status Checks and Branch Protection

### Required Status Checks

Configure in **Settings > Branches > Branch protection rules**:

| Setting | Purpose |
|---------|---------|
| Require status checks to pass | Block merge until CI passes |
| Require branches to be up to date | Ensure tests run against latest main |
| Status checks to require | Select specific job names |

### Handling Skipped Checks with Path Filters

Problem: Path-filtered workflows skip jobs, blocking required checks.

Solution 1: Paths-filter action with always-running workflow:

```yaml
name: CI
on: [push, pull_request]

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      src: ${{ steps.filter.outputs.src }}
    steps:
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            src:
              - 'src/**'
              - 'package.json'

  test:
    needs: changes
    if: needs.changes.outputs.src == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: npm test

  # Always passes - use this as the required check
  ci-success:
    needs: [test]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: |
          if [[ "${{ needs.test.result }}" == "failure" ]]; then
            exit 1
          fi
```

Solution 2: Make the check non-required and use a merge queue.

### Merge Queue

```yaml
on:
  merge_group:                        # Triggered by merge queue
    types: [checks_requested]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test
```

## Pull Request Checks Workflow

Complete PR workflow with all common checks:

```yaml
name: PR Checks
on:
  pull_request:
    branches: [main]

concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  # ── Fast Checks ────────────────────────────────────────
  lint:
    name: Lint & Format
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run lint
      - run: npm run typecheck
      - run: npm run format:check

  # ── Unit Tests ─────────────────────────────────────────
  unit:
    name: Unit Tests
    needs: lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run test:unit -- --coverage

      - uses: codecov/codecov-action@v4
        with:
          token: ${{ secrets.CODECOV_TOKEN }}
          flags: unittests

  # ── Integration Tests ─────────────────────────────────
  integration:
    name: Integration Tests
    needs: lint
    runs-on: ubuntu-latest
    timeout-minutes: 15
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run db:migrate
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test
      - run: npm run test:integration
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test

  # ── E2E Tests ─────────────────────────────────────────
  e2e:
    name: E2E Tests (${{ matrix.shard }})
    needs: [unit, integration]
    runs-on: ubuntu-latest
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        shard: [1/3, 2/3, 3/3]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci

      - name: Cache Playwright
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - run: npx playwright install --with-deps chromium
      - run: npx playwright test --shard=${{ matrix.shard }}

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report-${{ strategy.job-index }}
          path: playwright-report/
          retention-days: 7

  # ── Build Check ────────────────────────────────────────
  build:
    name: Build
    needs: lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: build
          path: dist/
          retention-days: 1

  # ── Gate Check (required status check) ─────────────────
  ci-success:
    name: CI Success
    needs: [lint, unit, integration, e2e, build]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: |
          results=("${{ needs.lint.result }}" "${{ needs.unit.result }}" \
                   "${{ needs.integration.result }}" "${{ needs.e2e.result }}" \
                   "${{ needs.build.result }}")
          for result in "${results[@]}"; do
            if [[ "$result" == "failure" || "$result" == "cancelled" ]]; then
              echo "::error::Job failed with result: $result"
              exit 1
            fi
          done
          echo "All checks passed"
```

## Deployment Pipelines

### Staging to Production

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: build
          path: dist/

  deploy-staging:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: staging
      url: https://staging.example.com
    steps:
      - uses: actions/download-artifact@v4
        with: { name: build, path: dist/ }
      - run: ./deploy.sh staging
        env:
          DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}

  smoke-test:
    needs: deploy-staging
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npx playwright test tests/smoke/
        env:
          BASE_URL: https://staging.example.com

  deploy-production:
    needs: smoke-test
    runs-on: ubuntu-latest
    environment:
      name: production                # Manual approval required
      url: https://example.com
    steps:
      - uses: actions/download-artifact@v4
        with: { name: build, path: dist/ }
      - run: ./deploy.sh production
        env:
          DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

### Blue/Green Deployment

```yaml
deploy:
  runs-on: ubuntu-latest
  environment: production
  steps:
    - run: |
        # Deploy to inactive slot
        ACTIVE=$(curl -s https://example.com/slot)
        INACTIVE=$([[ "$ACTIVE" == "blue" ]] && echo "green" || echo "blue")

        # Deploy to inactive
        deploy --slot "$INACTIVE"

        # Health check on inactive
        curl -sf "https://${INACTIVE}.example.com/health" || exit 1

        # Swap traffic
        swap-slots "$ACTIVE" "$INACTIVE"

        echo "Swapped from $ACTIVE to $INACTIVE"
```

### Canary Deployment

```yaml
deploy:
  runs-on: ubuntu-latest
  environment: production
  steps:
    - name: Deploy canary (10%)
      run: deploy --canary --weight=10

    - name: Monitor canary (5 min)
      run: |
        for i in {1..5}; do
          ERROR_RATE=$(curl -s https://metrics.example.com/error-rate)
          if (( $(echo "$ERROR_RATE > 1.0" | bc -l) )); then
            echo "::error::Error rate ${ERROR_RATE}% exceeds threshold"
            deploy --rollback
            exit 1
          fi
          sleep 60
        done

    - name: Promote canary (100%)
      run: deploy --promote
```

### Rollback Pattern

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to rollback to'
        required: true
        type: string

jobs:
  rollback:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: |
          echo "Rolling back to ${{ inputs.version }}"
          deploy --version "${{ inputs.version }}"

      - run: |
          curl -sf https://example.com/health || {
            echo "::error::Rollback health check failed"
            exit 1
          }
```

### Multi-Region Deployment

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    strategy:
      max-parallel: 1                 # Deploy one region at a time
      matrix:
        region: [us-east-1, eu-west-1, ap-southeast-1]
    steps:
      - run: deploy --region ${{ matrix.region }}

      - name: Region health check
        run: |
          curl -sf "https://${{ matrix.region }}.example.com/health" || {
            echo "::error::Health check failed in ${{ matrix.region }}"
            exit 1
          }
```
