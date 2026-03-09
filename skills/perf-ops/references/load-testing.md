# Load Testing

Comprehensive guide to load testing tools, methodology, and CI integration.

## k6 (Grafana)

### Script Structure

```javascript
// k6 script: load-test.js
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const responseTime = new Trend('response_time');
const requestCount = new Counter('total_requests');

// Test configuration
export const options = {
  // Scenario-based configuration
  scenarios: {
    // Ramp up and sustain load
    load_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },   // Ramp up
        { duration: '5m', target: 50 },   // Sustain
        { duration: '2m', target: 0 },    // Ramp down
      ],
      gracefulRampDown: '30s',
    },
  },

  // Thresholds (pass/fail criteria)
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],  // ms
    http_req_failed: ['rate<0.01'],                   // <1% error rate
    errors: ['rate<0.05'],                            // Custom metric
  },
};

// Setup: runs once before test
export function setup() {
  const loginRes = http.post('https://api.example.com/login', {
    username: 'testuser',
    password: 'testpass',
  });
  return { token: loginRes.json('token') };
}

// Default function: runs for each VU iteration
export default function (data) {
  group('API endpoints', function () {
    // GET request
    const listRes = http.get('https://api.example.com/items', {
      headers: { Authorization: `Bearer ${data.token}` },
    });

    check(listRes, {
      'status is 200': (r) => r.status === 200,
      'response time < 500ms': (r) => r.timings.duration < 500,
      'has items': (r) => r.json('items').length > 0,
    });

    errorRate.add(listRes.status !== 200);
    responseTime.add(listRes.timings.duration);
    requestCount.add(1);

    // POST request
    const createRes = http.post(
      'https://api.example.com/items',
      JSON.stringify({ name: 'test item', value: Math.random() }),
      {
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${data.token}`,
        },
      }
    );

    check(createRes, {
      'created successfully': (r) => r.status === 201,
    });

    sleep(1); // Think time between requests
  });
}

// Teardown: runs once after test
export function teardown(data) {
  http.post('https://api.example.com/cleanup', null, {
    headers: { Authorization: `Bearer ${data.token}` },
  });
}
```

### k6 Executors

```
Executor selection:
│
├─ shared-iterations
│  └─ Fixed total iterations split across VUs
│     Use: "Run exactly N requests total"
│
├─ per-vu-iterations
│  └─ Each VU runs exactly N iterations
│     Use: "Each user does N actions"
│
├─ constant-vus
│  └─ Fixed number of VUs for a duration
│     Use: "Sustain N concurrent users"
│
├─ ramping-vus
│  └─ VUs ramp up/down in stages
│     Use: Standard load test pattern
│
├─ constant-arrival-rate
│  └─ Fixed request rate regardless of response time
│     Use: "Maintain exactly N RPS" (most realistic)
│
├─ ramping-arrival-rate
│  └─ Request rate ramps up/down
│     Use: "Find breaking point at increasing RPS"
│
└─ externally-controlled
   └─ VUs controlled via k6 REST API
      Use: Dynamic load adjustment during test
```

### k6 CLI Commands

```bash
# Run a test
k6 run script.js

# Run with overrides
k6 run --vus 50 --duration 30s script.js
k6 run --env BASE_URL=https://staging.example.com script.js

# Output to various formats
k6 run --out json=results.json script.js
k6 run --out csv=results.csv script.js
k6 run --out influxdb=http://localhost:8086/k6 script.js

# Cloud execution (requires k6 cloud account)
k6 cloud script.js

# Convert HAR to k6 script
k6 convert recording.har -O generated-script.js

# Inspect script options without running
k6 inspect script.js
```

### k6 Browser Testing

```javascript
import { browser } from 'k6/browser';

export const options = {
  scenarios: {
    browser: {
      executor: 'constant-vus',
      vus: 1,
      duration: '30s',
      options: {
        browser: {
          type: 'chromium',
        },
      },
    },
  },
};

export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto('https://example.com');
    await page.locator('input[name="username"]').fill('testuser');
    await page.locator('input[name="password"]').fill('testpass');
    await page.locator('button[type="submit"]').click();
    await page.waitForNavigation();

    // Measure Web Vitals
    const lcp = await page.evaluate(() => {
      return new Promise((resolve) => {
        new PerformanceObserver((list) => {
          const entries = list.getEntries();
          resolve(entries[entries.length - 1].startTime);
        }).observe({ type: 'largest-contentful-paint', buffered: true });
      });
    });
    console.log(`LCP: ${lcp}ms`);
  } finally {
    await page.close();
  }
}
```

## Artillery

### YAML Configuration

```yaml
# artillery-config.yml
config:
  target: "https://api.example.com"
  phases:
    - duration: 120    # 2 minutes
      arrivalRate: 10  # 10 new users per second
      name: "Warm-up"
    - duration: 300    # 5 minutes
      arrivalRate: 50  # 50 new users per second
      name: "Sustained load"
    - duration: 60
      arrivalRate: 100
      name: "Spike"

  # Plugins
  plugins:
    expect: {}        # Response validation
    metrics-by-endpoint: {} # Per-endpoint metrics

  # Default headers
  defaults:
    headers:
      Content-Type: "application/json"

  # Variables
  variables:
    baseUrl: "https://api.example.com"

  # Connection settings
  http:
    timeout: 10        # seconds
    pool: 100          # connection pool size

scenarios:
  - name: "Browse and purchase"
    weight: 70         # 70% of traffic
    flow:
      - get:
          url: "/products"
          expect:
            - statusCode: 200
            - hasProperty: "items"
          capture:
            - json: "$.items[0].id"
              as: "productId"
      - think: 3       # 3 second pause
      - get:
          url: "/products/{{ productId }}"
          expect:
            - statusCode: 200
      - post:
          url: "/cart"
          json:
            productId: "{{ productId }}"
            quantity: 1
          expect:
            - statusCode: 201

  - name: "Search"
    weight: 30         # 30% of traffic
    flow:
      - get:
          url: "/search?q={{ $randomString() }}"
          expect:
            - statusCode: 200
```

### Artillery CLI

```bash
# Run load test
artillery run artillery-config.yml

# Quick test (no config needed)
artillery quick --count 100 --num 10 https://api.example.com

# Generate HTML report
artillery run --output report.json artillery-config.yml
artillery report report.json

# Run with environment-specific config
artillery run -e staging artillery-config.yml

# Run with Playwright (browser scenarios)
artillery run --platform playwright artillery-browser.yml
```

## vegeta (Go)

### Attack and Report

```bash
# Basic attack
echo "GET http://localhost:8080/" | vegeta attack -duration=30s -rate=50/s | vegeta report

# Multiple endpoints from file
# targets.txt:
# GET http://localhost:8080/api/users
# GET http://localhost:8080/api/products
# POST http://localhost:8080/api/orders
# Content-Type: application/json
# @body.json
vegeta attack -targets=targets.txt -duration=60s -rate=100/s | vegeta report

# Custom headers
echo "GET http://localhost:8080/api/data" | \
  vegeta attack -header "Authorization: Bearer TOKEN" -duration=30s | \
  vegeta report

# Output formats
echo "GET http://localhost:8080/" | vegeta attack -duration=30s | vegeta report -type=text
echo "GET http://localhost:8080/" | vegeta attack -duration=30s | vegeta report -type=json
echo "GET http://localhost:8080/" | vegeta attack -duration=30s | vegeta report -type=hist[0,50ms,100ms,200ms,500ms,1s]

# Generate latency plot (HDR histogram)
echo "GET http://localhost:8080/" | vegeta attack -duration=60s | vegeta plot > plot.html

# Encode results for later analysis
echo "GET http://localhost:8080/" | vegeta attack -duration=60s | vegeta encode > results.json

# Constant rate vs max rate
echo "GET http://localhost:8080/" | vegeta attack -rate=0 -max-workers=100 -duration=30s | vegeta report
# -rate=0 means "as fast as possible" with max-workers limit
```

### vegeta Report Interpretation

```
Requests      [total, rate, throughput]  3000, 100.03, 99.87
Duration      [total, attack, wait]     30.04s, 29.99s, 49.54ms
Latencies     [min, mean, 50, 90, 95, 99, max]  12.5ms, 48.2ms, 42.1ms, 85.3ms, 120.5ms, 250.1ms, 1.2s
Bytes In      [total, mean]             1500000, 500.00
Bytes Out     [total, mean]             0, 0.00
Success       [ratio]                   99.5%
Status Codes  [code:count]              200:2985  500:15

Key metrics:
- p50 (median): typical user experience
- p95: 95% of users experience this or better
- p99: tail latency (worst 1%)
- Success ratio: anything below 99% needs investigation
- Throughput vs rate: throughput < rate means server can't keep up
```

## wrk / wrk2

### wrk: Lightweight HTTP Benchmarking

```bash
# Basic usage
wrk -t4 -c100 -d30s http://localhost:8080/
# -t4: 4 threads
# -c100: 100 connections
# -d30s: 30 second duration

# With Lua script
wrk -t4 -c100 -d30s -s script.lua http://localhost:8080/

# wrk2 (constant throughput mode)
wrk2 -t4 -c100 -d30s -R2000 http://localhost:8080/
# -R2000: target 2000 requests/second
```

### wrk Lua Scripts

```lua
-- post-request.lua: POST with JSON body
wrk.method = "POST"
wrk.body   = '{"username":"test","password":"test"}'
wrk.headers["Content-Type"] = "application/json"

-- dynamic-request.lua: different paths per request
counter = 0
request = function()
  counter = counter + 1
  local path = "/api/items/" .. (counter % 1000)
  return wrk.format("GET", path)
end

-- response.lua: validate responses
response = function(status, headers, body)
  if status ~= 200 then
    wrk.thread:stop()
  end
end

-- report.lua: custom reporting
done = function(summary, latency, requests)
  io.write("Latency distribution:\n")
  for _, p in pairs({ 50, 90, 95, 99, 99.9 }) do
    n = latency:percentile(p)
    io.write(string.format("%g%%\t%d ms\n", p, n / 1000))
  end
end
```

## Locust (Python)

### User Classes and Tasks

```python
# locustfile.py
from locust import HttpUser, task, between, events
from locust import LoadTestShape
import json

class WebsiteUser(HttpUser):
    # Wait between requests (simulates think time)
    wait_time = between(1, 5)

    # Run once per user on start
    def on_start(self):
        response = self.client.post("/login", json={
            "username": "testuser",
            "password": "testpass"
        })
        self.token = response.json()["token"]
        self.client.headers.update({
            "Authorization": f"Bearer {self.token}"
        })

    @task(3)  # Weight: 3x more likely than weight-1 tasks
    def browse_items(self):
        with self.client.get("/api/items", catch_response=True) as response:
            if response.status_code == 200:
                items = response.json()["items"]
                if len(items) == 0:
                    response.failure("No items returned")
            else:
                response.failure(f"Status {response.status_code}")

    @task(1)
    def create_item(self):
        self.client.post("/api/items", json={
            "name": f"item-{self.environment.runner.user_count}",
            "value": 42
        })

    @task(2)
    def search(self):
        self.client.get("/api/search?q=test")

    def on_stop(self):
        self.client.post("/logout")


class AdminUser(HttpUser):
    """Separate user class with different behavior"""
    wait_time = between(5, 15)
    weight = 1  # 1 admin for every 10 regular users (if WebsiteUser weight=10)

    @task
    def check_dashboard(self):
        self.client.get("/admin/dashboard")


# Custom load shape
class StagesShape(LoadTestShape):
    """Ramp up, sustain, spike, recover"""
    stages = [
        {"duration": 60,  "users": 10,  "spawn_rate": 2},
        {"duration": 300, "users": 50,  "spawn_rate": 5},
        {"duration": 360, "users": 200, "spawn_rate": 50},  # Spike
        {"duration": 420, "users": 50,  "spawn_rate": 10},  # Recover
        {"duration": 480, "users": 0,   "spawn_rate": 10},  # Ramp down
    ]

    def tick(self):
        run_time = self.get_run_time()
        for stage in self.stages:
            if run_time < stage["duration"]:
                return (stage["users"], stage["spawn_rate"])
        return None
```

### Locust CLI

```bash
# Run with web UI (default port 8089)
locust -f locustfile.py --host https://api.example.com

# Headless mode
locust -f locustfile.py --host https://api.example.com \
  --headless -u 100 -r 10 --run-time 5m
# -u: total users, -r: spawn rate per second

# Distributed mode
# Master:
locust -f locustfile.py --master
# Workers (on each worker machine):
locust -f locustfile.py --worker --master-host=MASTER_IP

# CSV output
locust -f locustfile.py --headless -u 50 -r 5 --run-time 5m \
  --csv=results --csv-full-history

# HTML report
locust -f locustfile.py --headless -u 50 -r 5 --run-time 5m \
  --html=report.html
```

## autocannon (Node.js)

### CLI and Programmatic Usage

```bash
# Basic usage
autocannon -c 100 -d 30 http://localhost:3000
# -c: connections, -d: duration in seconds

# With pipelining (multiple requests per connection)
autocannon -c 100 -p 10 -d 30 http://localhost:3000

# POST with body
autocannon -c 50 -d 30 -m POST \
  -H "Content-Type=application/json" \
  -b '{"key":"value"}' \
  http://localhost:3000/api/data

# HAR file input
autocannon -c 100 -d 30 --har requests.har http://localhost:3000
```

```javascript
// Programmatic usage
const autocannon = require('autocannon');

const result = await autocannon({
  url: 'http://localhost:3000',
  connections: 100,
  duration: 30,
  pipelining: 10,
  headers: {
    'Authorization': 'Bearer TOKEN',
  },
  requests: [
    { method: 'GET', path: '/api/items' },
    { method: 'POST', path: '/api/items', body: JSON.stringify({ name: 'test' }) },
  ],
});

console.log('Avg latency:', result.latency.average, 'ms');
console.log('Req/sec:', result.requests.average);
console.log('Throughput:', result.throughput.average, 'bytes/sec');
```

## Load Testing Methodology

### Test Planning

```
Before running load tests:
│
├─ Define objectives
│  ├─ What SLOs must be met? (p95 < 200ms, 99.9% availability)
│  ├─ What is expected peak traffic? (from analytics/projections)
│  └─ What scenarios matter? (browse, search, checkout, API calls)
│
├─ Prepare environment
│  ├─ Use production-like infrastructure (same specs, same config)
│  ├─ Use realistic data volumes (not empty database)
│  ├─ Isolate from production traffic
│  └─ Ensure monitoring is in place (APM, metrics, logs)
│
├─ Create realistic scenarios
│  ├─ Model real user behavior (browse → search → add to cart → checkout)
│  ├─ Include think time between actions
│  ├─ Mix of read and write operations
│  ├─ Vary request payloads
│  └─ Include authentication flows
│
└─ Establish baselines
   ├─ Run smoke test first (verify test works at low load)
   ├─ Record baseline metrics at known-good load
   └─ Compare subsequent tests against baseline
```

### Test Execution Patterns

```
Ramp-Up Test:
Users ▲
  100 │          ┌──────────────────┐
      │        ╱│                  │╲
   50 │      ╱  │     Sustain      │  ╲
      │    ╱    │                  │    ╲
    0 │──╱─────┼──────────────────┼─────╲──
      └────────────────────────────────────→ Time
      0    2m       5m             7m   9m

Spike Test:
Users ▲
  500 │         ╱╲
      │        ╱  ╲
  100 │───────╱    ╲───────────
      │
    0 │─────────────────────────→ Time

Soak Test:
Users ▲
  100 │  ┌──────────────────────────────┐
      │  │          4-12 hours          │
    0 │──┘                              └──
      └────────────────────────────────────→ Time

Breakpoint Test:
Users ▲
  ??? │                              ╱ ← System breaks here
      │                           ╱
      │                        ╱
      │                     ╱
      │                  ╱
    0 │───────────────╱───────────────→ Time
      Continuously increasing until failure
```

### Results Interpretation

```
Key metrics to analyze:
│
├─ Latency
│  ├─ p50 (median): typical user experience
│  ├─ p95: most users' worst experience
│  ├─ p99: tail latency (1 in 100 requests)
│  ├─ p99.9: extreme tail (important at scale)
│  └─ Compare: p99/p50 ratio > 10x suggests systemic issue
│
├─ Throughput
│  ├─ Requests per second (RPS)
│  ├─ Compare achieved vs target rate
│  ├─ If achieved < target: server saturated
│  └─ Watch for throughput plateau (max capacity reached)
│
├─ Error Rate
│  ├─ HTTP 5xx errors: server failures
│  ├─ HTTP 429 errors: rate limiting
│  ├─ Timeouts: resource exhaustion
│  ├─ Connection refused: port/socket exhaustion
│  └─ Target: <0.1% under normal load
│
├─ Resource Utilization
│  ├─ CPU: >80% sustained = at capacity
│  ├─ Memory: growing = leak, high = needs more RAM
│  ├─ Disk I/O: iowait >20% = I/O bottleneck
│  ├─ Network: check bandwidth, connection count
│  └─ Connection pools: active/waiting/idle ratios
│
└─ Saturation Point
   ├─ Where latency starts increasing non-linearly
   ├─ Where error rate begins climbing
   ├─ Where throughput plateaus despite more load
   └─ This is your system's practical capacity
```

### Common Findings and Fixes

| Finding | Symptom | Root Cause | Fix |
|---------|---------|------------|-----|
| Latency spike at load | p99 jumps at N users | Connection pool exhaustion | Increase pool size, optimize queries |
| Throughput plateau | RPS flat despite more VUs | CPU saturation | Optimize hot paths, scale horizontally |
| Error rate climbs gradually | 5xx increases with load | Memory leak under load | Fix leak, increase memory, add limits |
| Timeout cascade | Many timeouts after first | No circuit breaker | Add circuit breaker, retry with backoff |
| Uneven distribution | Some pods idle, some overloaded | Bad load balancing | Fix health checks, use least-connections |
| GC pauses | Periodic latency spikes | Large heap, GC pressure | Reduce allocations, tune GC, smaller heap |
| DNS resolution | Intermittent slow requests | DNS lookup on every request | Connection pooling, DNS caching |
| TLS handshake overhead | High latency on first request | No connection reuse | Keep-alive, connection pooling |

## CI Integration

### Performance Budgets

```yaml
# k6 thresholds as CI gates
export const options = {
  thresholds: {
    http_req_duration: [
      { threshold: 'p(95)<500', abortOnFail: true },
      { threshold: 'p(99)<1500', abortOnFail: true },
    ],
    http_req_failed: [
      { threshold: 'rate<0.01', abortOnFail: true },
    ],
    checks: [
      { threshold: 'rate>0.99', abortOnFail: true },
    ],
  },
};
```

### GitHub Actions Example

```yaml
# .github/workflows/load-test.yml
name: Load Test
on:
  pull_request:
    paths: ['src/**', 'package.json']

jobs:
  load-test:
    runs-on: ubuntu-latest
    services:
      app:
        image: myapp:${{ github.sha }}
        ports:
          - 8080:8080
    steps:
      - uses: actions/checkout@v4

      - name: Install k6
        run: |
          sudo gpg -k
          sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68
          echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
          sudo apt-get update
          sudo apt-get install k6

      - name: Run load test
        run: k6 run --out json=results.json tests/load/api-test.js

      - name: Compare with baseline
        run: |
          # Extract p95 from results
          P95=$(jq -r '.data.metrics.http_req_duration.values["p(95)"]' results.json)
          BASELINE=450  # ms
          if (( $(echo "$P95 > $BASELINE" | bc -l) )); then
            echo "::error::p95 latency regression: ${P95}ms > ${BASELINE}ms baseline"
            exit 1
          fi

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: load-test-results
          path: results.json
```

### Baseline Comparison Strategy

```
Performance regression detection:
│
├─ Establish baseline
│  ├─ Run load test on main branch after each merge
│  ├─ Store results in a time-series DB or artifact storage
│  └─ Track p50, p95, p99, throughput, error rate
│
├─ PR comparison
│  ├─ Run same test on PR branch
│  ├─ Compare against baseline
│  ├─ Alert if metrics degrade beyond threshold
│  └─ Common thresholds: >10% p95 increase, >5% throughput decrease
│
├─ Statistical significance
│  ├─ Run test multiple times (3-5x) to account for noise
│  ├─ Use statistical tests (t-test) to confirm regression
│  └─ Avoid false positives from system noise
│
└─ Trend tracking
   ├─ Plot metrics over time across releases
   ├─ Catch gradual degradation that per-PR tests miss
   └─ Set alerts for multi-week trends
```

### Test Data Management

```
Realistic test data:
│
├─ Data volume
│  ├─ Match production data volume (or representative subset)
│  ├─ Empty DB gives misleadingly good results
│  └─ Index effectiveness depends on data distribution
│
├─ Data variety
│  ├─ Use parameterized inputs (not same request every time)
│  ├─ Vary payload sizes
│  ├─ Include edge cases (long strings, Unicode, special chars)
│  └─ Distribute IDs to avoid cache hot-spotting
│
├─ Data isolation
│  ├─ Each test run should use clean or isolated data
│  ├─ Tests that modify data should not affect next run
│  ├─ Use database transactions/rollback or test-specific namespaces
│  └─ Avoid accumulating data across test runs
│
└─ Data generation
   ├─ k6: use SharedArray for CSV/JSON data files
   ├─ Artillery: use CSV feeders, custom functions
   ├─ Locust: use Python libraries (Faker) for realistic data
   └─ General: pre-generate data, load before test
```
