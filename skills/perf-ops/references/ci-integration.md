# Performance CI Integration

Patterns for enforcing performance budgets, detecting regressions, and integrating profiling into CI/CD pipelines.

## Performance Budgets

### Bundle Size Budgets (Frontend)

**size-limit** - Enforce JavaScript bundle budgets in CI:

```json
// package.json
{
  "size-limit": [
    { "path": "dist/index.js", "limit": "50 kB" },
    { "path": "dist/vendor.js", "limit": "150 kB" },
    { "path": "dist/**/*.css", "limit": "30 kB" }
  ]
}
```

```yaml
# GitHub Actions
- name: Check bundle size
  run: npx size-limit
  # Fails if any bundle exceeds limit
```

**bundlewatch** - Track bundle sizes across PRs:

```yaml
- name: Bundle size check
  uses: jackyef/bundlewatch-gh-action@master
  with:
    bundlewatch-config: .bundlewatch.config.js
    bundlewatch-github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Lighthouse CI (Web Performance)

```yaml
# .lighthouserc.json
{
  "ci": {
    "collect": {
      "url": ["http://localhost:3000/", "http://localhost:3000/dashboard"],
      "numberOfRuns": 3
    },
    "assert": {
      "assertions": {
        "categories:performance": ["error", { "minScore": 0.9 }],
        "first-contentful-paint": ["warn", { "maxNumericValue": 2000 }],
        "largest-contentful-paint": ["error", { "maxNumericValue": 2500 }],
        "cumulative-layout-shift": ["error", { "maxNumericValue": 0.1 }],
        "total-blocking-time": ["error", { "maxNumericValue": 300 }]
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

```yaml
# GitHub Actions
- name: Lighthouse CI
  run: |
    npm install -g @lhci/cli
    lhci autorun
```

### API Response Time Budgets

**k6 thresholds** - Fail CI if response times exceed SLOs:

```javascript
// perf-test.js
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    iterations: ['rate>100'],
  },
};
```

```yaml
- name: API performance test
  run: k6 run --out json=results.json perf-test.js
- name: Upload results
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: k6-results
    path: results.json
```

## Regression Detection

### Benchmark Baselines

**Store benchmarks in git** for cross-commit comparison:

```yaml
# Go benchmarks with benchstat
- name: Run benchmarks
  run: go test -bench=. -benchmem -count=5 ./... > new.txt

- name: Compare with baseline
  run: |
    git stash
    go test -bench=. -benchmem -count=5 ./... > old.txt
    git stash pop
    benchstat old.txt new.txt
```

**Python with pytest-benchmark:**

```yaml
- name: Run benchmarks
  run: pytest --benchmark-only --benchmark-json=benchmark.json

- name: Compare with baseline
  run: pytest --benchmark-only --benchmark-compare=0001_baseline.json
```

**Rust with criterion:**

```yaml
- name: Benchmark
  run: cargo bench -- --save-baseline pr-${{ github.event.number }}

- name: Compare
  run: cargo bench -- --baseline main --save-baseline pr-compare
  # criterion outputs comparison automatically
```

**hyperfine for CLI tools:**

```yaml
- name: Benchmark CLI
  run: |
    hyperfine --export-json bench.json \
      --warmup 3 \
      './target/release/mytool process data.csv'
```

### Statistical Comparison

When comparing benchmarks, avoid naive percentage comparison. Use statistical tests:

```
Good: "p95 latency increased from 45ms to 52ms (benchstat: p=0.003, statistically significant)"
Bad:  "latency increased 15%" (no sample size, no confidence interval)
```

**benchstat** (Go) computes significance automatically:

```
name        old time/op  new time/op  delta
Parse-8     45.2ms +- 2%  52.1ms +- 3%  +15.27% (p=0.003 n=5+5)
```

**pytest-benchmark** comparison output:

```
Name                 Min      Max     Mean    StdDev   Rounds
test_parse        42.1ms   48.3ms   45.2ms    1.8ms       10
test_parse (base) 38.9ms   42.1ms   40.5ms    1.1ms       10
```

### Alerting on Regressions

**GitHub Actions comment on PR:**

```yaml
- name: Comment benchmark results
  uses: benchmark-action/github-action-benchmark@v1
  with:
    tool: 'go'
    output-file-path: bench.txt
    github-token: ${{ secrets.GITHUB_TOKEN }}
    comment-on-alert: true
    alert-threshold: '150%'  # Alert if 50%+ regression
    fail-on-alert: true
```

## CI Pipeline Patterns

### Pre-merge Performance Gate

```yaml
name: Performance Gate
on: pull_request

jobs:
  bundle-size:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run build
      - run: npx size-limit

  api-perf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose up -d
      - run: sleep 10  # Wait for services
      - run: k6 run --out json=results.json tests/perf/smoke.js
      - uses: actions/upload-artifact@v4
        with:
          name: perf-results
          path: results.json

  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Need history for baseline
      - run: |
          # Run current benchmarks
          go test -bench=. -benchmem -count=5 ./... > new.txt
          # Run baseline benchmarks
          git checkout main
          go test -bench=. -benchmem -count=5 ./... > old.txt
          git checkout -
          # Compare
          benchstat old.txt new.txt | tee comparison.txt
```

### Scheduled Soak Test

```yaml
name: Nightly Soak Test
on:
  schedule:
    - cron: '0 2 * * 1-5'  # 2 AM weekdays

jobs:
  soak:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
      - run: docker compose up -d
      - name: Run soak test (1 hour)
        run: k6 run --duration 1h tests/perf/soak.js
      - name: Check for memory leaks
        run: |
          # Compare start vs end memory usage
          docker stats --no-stream --format "{{.MemUsage}}" app
```

### Performance Dashboard Integration

```yaml
# Push metrics to Grafana Cloud / InfluxDB
- name: Push to dashboard
  run: |
    k6 run \
      --out influxdb=http://influxdb:8086/k6 \
      tests/perf/load.js
```

## Tool-Specific CI Patterns

### k6 in CI

```yaml
- name: Install k6
  run: |
    sudo gpg -k
    sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
      --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
      | sudo tee /etc/apt/sources.list.d/k6.list
    sudo apt-get update && sudo apt-get install k6
- name: Run load test
  run: k6 run tests/perf/load.js
```

### Artillery in CI

```yaml
- name: Run Artillery
  run: npx artillery run tests/perf/config.yml --output report.json
- name: Generate report
  run: npx artillery report report.json --output report.html
```

### Lighthouse in CI

```yaml
- name: Audit with Lighthouse
  run: |
    npm install -g @lhci/cli
    lhci autorun --config=.lighthouserc.json
```

## Budget Sizing Guidelines

| Metric | Good | Acceptable | Poor |
|--------|------|------------|------|
| JS bundle (gzipped) | <50 kB | <150 kB | >300 kB |
| CSS (gzipped) | <20 kB | <50 kB | >100 kB |
| LCP | <1.5s | <2.5s | >4.0s |
| FCP | <1.0s | <1.8s | >3.0s |
| CLS | <0.05 | <0.1 | >0.25 |
| TBT | <150ms | <300ms | >600ms |
| API p95 | <200ms | <500ms | >1000ms |
| API p99 | <500ms | <1000ms | >3000ms |
| API error rate | <0.1% | <1% | >5% |
