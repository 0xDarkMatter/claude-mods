# Metrics and Alerting Reference

Comprehensive reference for metrics collection, visualization, alerting, SLOs, and uptime monitoring.

---

## Prometheus

### Architecture Overview

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────┐
│ Application │────▶│  Prometheus  │────▶│  Alertmanager   │
│  /metrics   │pull │  (TSDB)      │push │  (routing/notif) │
└─────────────┘     └──────┬──────┘     └─────────────────┘
                           │query
                    ┌──────▼──────┐
                    │   Grafana    │
                    │ (dashboards) │
                    └─────────────┘
```

**Key characteristics:**
- Pull-based model (Prometheus scrapes targets)
- Local time-series database (TSDB)
- PromQL query language
- Built-in alerting rules evaluated by Prometheus, routed by Alertmanager
- Service discovery (Kubernetes, Consul, DNS, file-based, EC2)

### Prometheus Configuration (prometheus.yml)

```yaml
global:
  scrape_interval: 15s          # Default scrape interval
  evaluation_interval: 15s      # Rule evaluation interval
  scrape_timeout: 10s           # Per-scrape timeout

# Alertmanager configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

# Rule files
rule_files:
  - "rules/*.yml"

# Scrape targets
scrape_configs:
  # Self-monitoring
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # Application with static targets
  - job_name: "api-server"
    metrics_path: /metrics
    scheme: https
    static_configs:
      - targets: ["api1:8080", "api2:8080"]
        labels:
          environment: production

  # Kubernetes service discovery
  - job_name: "kubernetes-pods"
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod

  # Node exporter
  - job_name: "node"
    static_configs:
      - targets: ["node-exporter:9100"]
```

### PromQL Basics

#### Rate and Increase

```promql
# Per-second rate over 5 minutes (use for counters)
rate(http_requests_total[5m])

# Per-second rate for specific status codes
rate(http_requests_total{status_code=~"5.."}[5m])

# Total increase over 1 hour (use for counters)
increase(http_requests_total[1h])

# irate: instant rate using last two data points (more volatile)
irate(http_requests_total[5m])
```

**Rule:** Always use `rate()` or `increase()` with counters. Never display raw counter values.

#### Aggregation Operators

```promql
# Sum across all instances
sum(rate(http_requests_total[5m]))

# Sum by specific label
sum by (method, path) (rate(http_requests_total[5m]))

# Average across instances
avg(node_cpu_seconds_total{mode="idle"})

# Maximum value across instances
max by (instance) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)

# Count number of time series
count(up == 1)

# Top 5 by value
topk(5, rate(http_requests_total[5m]))

# Bottom 5 by value
bottomk(5, rate(http_requests_total[5m]))
```

#### Histogram Quantiles

```promql
# 99th percentile latency
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)

# 95th percentile latency by service
histogram_quantile(0.95,
  sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
)

# 50th percentile (median)
histogram_quantile(0.50,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)

# Average latency from histogram
sum(rate(http_request_duration_seconds_sum[5m]))
/
sum(rate(http_request_duration_seconds_count[5m]))
```

#### Useful Functions

```promql
# Detect missing metrics (target down)
absent(up{job="api-server"})

# Time since last change (staleness)
time() - process_start_time_seconds

# Predict value in 4 hours using linear regression
predict_linear(node_filesystem_avail_bytes[6h], 4*3600)

# Compare to 1 week ago
rate(http_requests_total[5m]) / rate(http_requests_total[5m] offset 7d)

# Clamping values
clamp_min(free_disk_percentage, 0)
clamp_max(cpu_usage_percentage, 100)

# Label manipulation
label_replace(up, "short_instance", "$1", "instance", "(.*):.*")
```

### Recording Rules

Pre-compute expensive queries for dashboards and alerts:

```yaml
# rules/recording-rules.yml
groups:
  - name: http_request_rules
    interval: 15s
    rules:
      # Pre-compute request rate by service and status
      - record: job:http_requests:rate5m
        expr: sum by (job, status_code) (rate(http_requests_total[5m]))

      # Pre-compute error rate percentage
      - record: job:http_request_errors:ratio5m
        expr: |
          sum by (job) (rate(http_requests_total{status_code=~"5.."}[5m]))
          /
          sum by (job) (rate(http_requests_total[5m]))

      # Pre-compute p99 latency
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # Pre-compute availability
      - record: job:availability:ratio5m
        expr: |
          1 - (
            sum by (job) (rate(http_requests_total{status_code=~"5.."}[5m]))
            /
            sum by (job) (rate(http_requests_total[5m]))
          )
```

### Alerting Rules

```yaml
# rules/alerting-rules.yml
groups:
  - name: service_alerts
    rules:
      # High error rate
      - alert: HighErrorRate
        expr: job:http_request_errors:ratio5m > 0.01
        for: 5m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "High error rate on {{ $labels.job }}"
          description: "Error rate is {{ $value | humanizePercentage }} (threshold: 1%)"
          runbook_url: "https://runbooks.example.com/high-error-rate"
          dashboard_url: "https://grafana.example.com/d/service-overview?var-service={{ $labels.job }}"

      # Critical error rate
      - alert: CriticalErrorRate
        expr: job:http_request_errors:ratio5m > 0.05
        for: 2m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Critical error rate on {{ $labels.job }}"
          description: "Error rate is {{ $value | humanizePercentage }} (threshold: 5%)"
          runbook_url: "https://runbooks.example.com/critical-error-rate"

      # High latency
      - alert: HighLatencyP99
        expr: job:http_request_duration_seconds:p99_5m > 2.0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "P99 latency above 2s on {{ $labels.job }}"
          description: "P99 latency is {{ $value | humanizeDuration }}"

      # Target down
      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} is down"
          description: "Prometheus cannot scrape {{ $labels.job }}/{{ $labels.instance }}"

  - name: infrastructure_alerts
    rules:
      # Disk space prediction
      - alert: DiskWillFillIn24Hours
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24*3600) < 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} will fill within 24 hours"

      # High memory usage
      - alert: HighMemoryUsage
        expr: |
          (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage above 90% on {{ $labels.instance }}"

      # High CPU usage
      - alert: HighCPUUsage
        expr: |
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "CPU usage above 85% on {{ $labels.instance }}"
```

---

## Grafana

### Dashboard JSON Structure

```json
{
  "dashboard": {
    "title": "Service Overview",
    "uid": "service-overview",
    "tags": ["production", "services"],
    "timezone": "browser",
    "refresh": "30s",
    "time": {
      "from": "now-6h",
      "to": "now"
    },
    "templating": {
      "list": [
        {
          "name": "service",
          "type": "query",
          "datasource": "Prometheus",
          "query": "label_values(up, job)",
          "refresh": 2,
          "multi": true,
          "includeAll": true
        },
        {
          "name": "interval",
          "type": "interval",
          "options": [
            {"text": "1m", "value": "1m"},
            {"text": "5m", "value": "5m"},
            {"text": "15m", "value": "15m"}
          ],
          "current": {"text": "5m", "value": "5m"}
        }
      ]
    },
    "panels": []
  }
}
```

### Panel Types

#### Time Series Panel

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
  "targets": [
    {
      "expr": "sum by (status_code) (rate(http_requests_total{job=~\"$service\"}[$interval]))",
      "legendFormat": "{{status_code}}"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "custom": {
        "drawStyle": "line",
        "fillOpacity": 10,
        "stacking": {"mode": "none"}
      }
    }
  }
}
```

#### Stat Panel

```json
{
  "type": "stat",
  "title": "Current Error Rate",
  "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
  "targets": [
    {
      "expr": "sum(rate(http_requests_total{job=~\"$service\",status_code=~\"5..\"}[5m])) / sum(rate(http_requests_total{job=~\"$service\"}[5m]))",
      "instant": true
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "percentunit",
      "thresholds": {
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 0.001},
          {"color": "red", "value": 0.01}
        ]
      }
    }
  }
}
```

#### Gauge Panel

```json
{
  "type": "gauge",
  "title": "CPU Usage",
  "targets": [
    {
      "expr": "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\",instance=~\"$instance\"}[5m]))",
      "instant": true
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "percentunit",
      "min": 0,
      "max": 1,
      "thresholds": {
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 0.7},
          {"color": "red", "value": 0.9}
        ]
      }
    }
  }
}
```

#### Table Panel

```json
{
  "type": "table",
  "title": "Top Endpoints by Error Rate",
  "targets": [
    {
      "expr": "topk(10, sum by (method, path) (rate(http_requests_total{status_code=~\"5..\"}[5m])))",
      "instant": true,
      "format": "table"
    }
  ],
  "transformations": [
    {"id": "organize", "options": {"excludeByName": {"Time": true}}}
  ]
}
```

### Grafana Variables

| Type | Use Case | Example |
|------|----------|---------|
| **Query** | Dynamic from datasource | `label_values(up, job)` |
| **Custom** | Fixed list of values | `production,staging,development` |
| **Interval** | Time range intervals | `1m,5m,15m,1h` |
| **Datasource** | Multiple Prometheus instances | Type: datasource, Query: Prometheus |
| **Text box** | Free-form input | Filter by custom string |

### Annotations

```json
{
  "annotations": {
    "list": [
      {
        "name": "Deployments",
        "datasource": "Prometheus",
        "enable": true,
        "expr": "changes(process_start_time_seconds{job=\"api-server\"}[1m]) > 0",
        "tagKeys": "job",
        "titleFormat": "Deployment: {{job}}"
      },
      {
        "name": "Alerts",
        "datasource": "-- Grafana --",
        "enable": true,
        "type": "alert"
      }
    ]
  }
}
```

---

## OpenTelemetry Metrics

### Go SDK Setup

```go
package main

import (
    "context"
    "log"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/prometheus"
    "go.opentelemetry.io/otel/metric"
    sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

func initMeterProvider() (*sdkmetric.MeterProvider, error) {
    exporter, err := prometheus.New()
    if err != nil {
        return nil, err
    }

    mp := sdkmetric.NewMeterProvider(
        sdkmetric.WithReader(exporter),
    )
    otel.SetMeterProvider(mp)
    return mp, nil
}

func main() {
    mp, err := initMeterProvider()
    if err != nil {
        log.Fatal(err)
    }
    defer mp.Shutdown(context.Background())

    meter := otel.Meter("myapp")

    // Counter
    requestCounter, _ := meter.Int64Counter(
        "http.server.request.total",
        metric.WithDescription("Total HTTP requests"),
        metric.WithUnit("{request}"),
    )

    // Histogram
    latencyHistogram, _ := meter.Float64Histogram(
        "http.server.request.duration",
        metric.WithDescription("HTTP request latency"),
        metric.WithUnit("s"),
        metric.WithExplicitBucketBoundaries(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
    )

    // UpDownCounter (gauge-like)
    activeConnections, _ := meter.Int64UpDownCounter(
        "http.server.active_connections",
        metric.WithDescription("Active HTTP connections"),
    )

    // Usage
    ctx := context.Background()
    requestCounter.Add(ctx, 1, metric.WithAttributes(
        attribute.String("method", "GET"),
        attribute.String("path", "/api/users"),
        attribute.Int("status_code", 200),
    ))

    start := time.Now()
    // ... handle request ...
    latencyHistogram.Record(ctx, time.Since(start).Seconds())

    activeConnections.Add(ctx, 1)   // connection opened
    activeConnections.Add(ctx, -1)  // connection closed
}
```

### Python SDK Setup

```python
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from prometheus_client import start_http_server

# Prometheus exporter
reader = PrometheusMetricReader()
provider = MeterProvider(metric_readers=[reader])
metrics.set_meter_provider(provider)

# Start Prometheus HTTP server on port 8000
start_http_server(8000)

meter = metrics.get_meter("myapp")

# Counter
request_counter = meter.create_counter(
    name="http.server.request.total",
    description="Total HTTP requests",
    unit="{request}",
)

# Histogram
latency_histogram = meter.create_histogram(
    name="http.server.request.duration",
    description="HTTP request latency",
    unit="s",
)

# UpDownCounter
active_connections = meter.create_up_down_counter(
    name="http.server.active_connections",
    description="Active HTTP connections",
)

# Usage
request_counter.add(1, {"method": "GET", "path": "/api/users", "status_code": 200})
latency_histogram.record(0.045, {"method": "GET", "path": "/api/users"})
active_connections.add(1)
```

### Node.js SDK Setup

```javascript
const { MeterProvider } = require('@opentelemetry/sdk-metrics');
const { PrometheusExporter } = require('@opentelemetry/exporter-prometheus');
const { metrics } = require('@opentelemetry/api');

const exporter = new PrometheusExporter({ port: 9464 });
const meterProvider = new MeterProvider({
  readers: [exporter],
});
metrics.setGlobalMeterProvider(meterProvider);

const meter = metrics.getMeter('myapp');

// Counter
const requestCounter = meter.createCounter('http.server.request.total', {
  description: 'Total HTTP requests',
  unit: '{request}',
});

// Histogram
const latencyHistogram = meter.createHistogram('http.server.request.duration', {
  description: 'HTTP request latency',
  unit: 's',
  advice: {
    explicitBucketBoundaries: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  },
});

// UpDownCounter
const activeConnections = meter.createUpDownCounter('http.server.active_connections', {
  description: 'Active HTTP connections',
});

// Usage
requestCounter.add(1, { method: 'GET', path: '/api/users', status_code: 200 });
latencyHistogram.record(0.045, { method: 'GET', path: '/api/users' });
activeConnections.add(1);
```

---

## StatsD

### Protocol Format

```
<metric_name>:<value>|<type>|@<sample_rate>|#<tags>
```

| Type | Code | Example |
|------|------|---------|
| Counter | `c` | `page.views:1\|c` |
| Gauge | `g` | `fuel.level:0.5\|g` |
| Timer | `ms` | `request.duration:320\|ms` |
| Set | `s` | `users.uniques:user123\|s` |
| Histogram | `h` | `request.size:512\|h` (DogStatsD) |
| Distribution | `d` | `request.duration:320\|d` (DogStatsD) |

### DogStatsD Extensions (Datadog)

```
# Counter with tags
http.requests:1|c|#method:GET,path:/api/users,status:200

# Histogram with sample rate
http.request.duration:45.2|h|@0.5|#service:api

# Gauge
system.cpu.usage:72.5|g|#host:web01

# Service check
_sc|myservice.health|0|#env:production|m:Service is healthy
```

**When to use StatsD over Prometheus:**
- Existing StatsD infrastructure
- Simple counter/gauge/timer needs without complex queries
- Push model required (ephemeral jobs, serverless)
- Language/framework has StatsD client but no Prometheus client

---

## Custom Metrics Design

### Naming Conventions

Follow OpenMetrics/Prometheus naming:

```
<namespace>_<subsystem>_<name>_<unit>_<suffix>
```

| Component | Rules | Examples |
|-----------|-------|---------|
| Namespace | Application or domain | `myapp`, `payment`, `auth` |
| Subsystem | Component within app | `http`, `db`, `cache`, `queue` |
| Name | What is measured | `request`, `connection`, `query` |
| Unit | SI unit (base, not milli/micro) | `seconds`, `bytes`, `ratio` |
| Suffix | Metric type | `_total` (counter), `_info` (metadata), `_bucket` (histogram) |

**Good names:**
```
http_server_request_duration_seconds          # histogram
http_server_requests_total                    # counter
db_connection_pool_active_connections         # gauge
cache_hit_ratio                               # gauge (0-1)
queue_messages_total                          # counter
payment_processing_duration_seconds           # histogram
```

**Bad names:**
```
requestCount          # No namespace, no suffix, camelCase
latency_ms            # Milliseconds (use seconds), no namespace
errors                # Vague, no namespace, no suffix
HttpRequests          # PascalCase
```

### Label Best Practices

**Do:**
- Use labels for dimensions you will filter/aggregate by
- Keep label cardinality bounded (< 100 unique values per label)
- Use consistent label names across metrics (`method`, not `http_method` in some and `request_method` in others)

**Don't:**
- Use user IDs, email addresses, or request IDs as labels (unbounded cardinality)
- Use full URL paths as labels (use route templates: `/api/users/{id}`, not `/api/users/12345`)
- Use error messages as labels (unbounded text)
- Create more than 5-7 labels per metric

### Avoiding Cardinality Bombs

```
# BAD: unbounded path label
http_requests_total{path="/api/users/12345"}    # Millions of unique series
http_requests_total{path="/api/users/67890"}

# GOOD: use route template
http_requests_total{route="/api/users/{id}"}    # One series per route

# BAD: error message as label
errors_total{message="connection refused to 10.0.0.5:5432"}

# GOOD: error category as label
errors_total{type="connection_refused", target="postgres"}
```

**Cardinality check query:**
```promql
# Find high-cardinality metrics
topk(10, count by (__name__) ({__name__=~".+"}))

# Check specific metric cardinality
count(http_requests_total)
```

---

## SLI / SLO / SLA

### Definitions

| Term | Definition | Example |
|------|------------|---------|
| **SLI** (Service Level Indicator) | Quantitative measure of service behavior | 99.2% of requests complete in < 500ms |
| **SLO** (Service Level Objective) | Target value for an SLI | 99.5% of requests should complete in < 500ms |
| **SLA** (Service Level Agreement) | Business contract with consequences | 99.9% availability or credit issued |

**Relationship:** SLI measures reality → SLO sets the target → SLA defines business consequences.

### Error Budget Calculation

```
Error budget = 1 - SLO target

Example:
  SLO = 99.9% availability
  Error budget = 0.1% = 43.2 minutes/month

  In a 30-day month:
  - Total minutes: 43,200
  - Allowed downtime: 43.2 minutes
  - Allowed error requests: 0.1% of total
```

### Burn Rate Alerting

Burn rate = rate at which error budget is being consumed relative to the budget period.

```
burn_rate = error_rate / (1 - SLO_target)
```

| Burn Rate | Budget Exhaustion | Alert? |
|-----------|-------------------|--------|
| 1x | 30 days (full period) | No |
| 2x | 15 days | No |
| 6x | 5 days | Ticket (warning) |
| 14.4x | 2 days | Page (critical) |
| 36x | 20 hours | Page immediately |

**Multi-window burn rate alert (recommended):**

```yaml
# Fast burn: 14.4x burn rate over 1-hour window, confirmed by 5-minute window
- alert: SLOHighBurnRate
  expr: |
    (
      sum(rate(http_requests_total{status_code=~"5.."}[1h]))
      /
      sum(rate(http_requests_total[1h]))
    ) > (14.4 * 0.001)
    and
    (
      sum(rate(http_requests_total{status_code=~"5.."}[5m]))
      /
      sum(rate(http_requests_total[5m]))
    ) > (14.4 * 0.001)
  labels:
    severity: critical
  annotations:
    summary: "High error budget burn rate"

# Slow burn: 6x burn rate over 6-hour window, confirmed by 30-minute window
- alert: SLOSlowBurnRate
  expr: |
    (
      sum(rate(http_requests_total{status_code=~"5.."}[6h]))
      /
      sum(rate(http_requests_total[6h]))
    ) > (6 * 0.001)
    and
    (
      sum(rate(http_requests_total{status_code=~"5.."}[30m]))
      /
      sum(rate(http_requests_total[30m]))
    ) > (6 * 0.001)
  labels:
    severity: warning
```

### SLO Document Template

```markdown
# SLO: [Service Name] - [SLO Name]

## Overview
- **Service:** payment-api
- **Owner:** payments-team
- **Last reviewed:** 2026-03-01

## SLI Definition
- **Type:** Availability (success rate)
- **Good events:** HTTP responses with status < 500
- **Total events:** All HTTP responses
- **Measurement:** `sum(rate(http_requests_total{status<500}[5m])) / sum(rate(http_requests_total[5m]))`

## SLO Target
- **Target:** 99.9%
- **Window:** 30 days (rolling)
- **Error budget:** 0.1% = ~43 minutes of downtime

## Alerting
- **Fast burn (page):** 14.4x burn rate for 1 hour
- **Slow burn (ticket):** 6x burn rate for 6 hours

## Consequences of Missing SLO
- Freeze non-critical deployments
- Allocate sprint capacity to reliability
- Review in next SLO review meeting
```

---

## Alert Routing

### Alertmanager Configuration

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m
  slack_api_url: "https://hooks.slack.com/services/T00/B00/XXX"
  pagerduty_url: "https://events.pagerduty.com/v2/enqueue"

route:
  receiver: "default-slack"
  group_by: ["alertname", "job"]
  group_wait: 30s        # Wait before sending first notification
  group_interval: 5m     # Wait before sending updates
  repeat_interval: 4h    # Resend if not resolved

  routes:
    # Critical alerts → PagerDuty
    - match:
        severity: critical
      receiver: "pagerduty-critical"
      group_wait: 10s
      repeat_interval: 1h

    # Warning alerts → Slack
    - match:
        severity: warning
      receiver: "slack-warnings"
      repeat_interval: 4h

    # Info alerts → Slack info channel
    - match:
        severity: info
      receiver: "slack-info"
      repeat_interval: 24h

    # Team-specific routing
    - match:
        team: database
      receiver: "pagerduty-database"
      routes:
        - match:
            severity: critical
          receiver: "pagerduty-database"
        - match:
            severity: warning
          receiver: "slack-database"

receivers:
  - name: "default-slack"
    slack_configs:
      - channel: "#alerts"
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

  - name: "pagerduty-critical"
    pagerduty_configs:
      - service_key: "<integration-key>"
        severity: critical
        description: '{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}'
        details:
          description: '{{ .CommonAnnotations.description }}'
          runbook: '{{ .CommonAnnotations.runbook_url }}'

  - name: "slack-warnings"
    slack_configs:
      - channel: "#alerts-warning"
        title: ':warning: {{ .GroupLabels.alertname }}'
        text: '{{ .CommonAnnotations.description }}'

  - name: "slack-info"
    slack_configs:
      - channel: "#alerts-info"

inhibit_rules:
  # Suppress warning if critical is already firing
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: ["alertname", "job"]
```

### Runbook Template

```markdown
# Runbook: [Alert Name]

## Alert Details
- **Alert:** HighErrorRate
- **Severity:** Warning / Critical
- **Team:** backend

## Symptom
What the user/system is experiencing when this alert fires.

## Investigation Steps
1. Check the Grafana dashboard: [link]
2. Check recent deployments: `kubectl rollout history deployment/api`
3. Check error logs: `kubectl logs -l app=api --tail=100 | jq 'select(.level=="ERROR")'`
4. Check downstream dependencies: [dashboard link]

## Mitigation
Immediate actions to reduce impact:
1. If caused by recent deploy: `kubectl rollout undo deployment/api`
2. If caused by downstream: Enable circuit breaker / failover
3. If caused by traffic spike: Scale horizontally

## Resolution
Steps to fully resolve:
1. Identify root cause from logs/traces
2. Create fix PR
3. Deploy fix through normal pipeline
4. Verify error rate returns to baseline

## Escalation
- Level 1: On-call engineer (this runbook)
- Level 2: Team lead (@team-lead)
- Level 3: VP Engineering (for customer-impacting incidents)
```

---

## Uptime Monitoring

### Uptime Kuma (Self-hosted)

```yaml
# docker-compose.yml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - uptime-kuma-data:/app/data

volumes:
  uptime-kuma-data:
```

**Features:**
- HTTP(s), TCP, DNS, Docker, gRPC, MQTT monitors
- Status pages (public-facing)
- Notifications: Slack, Discord, Telegram, PagerDuty, email, webhooks
- Certificate expiry monitoring
- Multi-language support

### Synthetic Monitoring

Run scripted checks from multiple regions to verify end-to-end functionality:

```javascript
// Example: Grafana synthetic monitoring check
import { check } from 'k6';
import http from 'k6/http';

export default function () {
  const res = http.get('https://api.example.com/health');
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
    'body contains ok': (r) => r.body.includes('"status":"ok"'),
  });
}
```

### Status Pages

Communicate service health to users:

| Tool | Type | Features |
|------|------|----------|
| **Uptime Kuma** | Self-hosted | Free, built-in status page |
| **Betteruptime** | SaaS | Incident management + status page |
| **Cachet** | Self-hosted | PHP-based, mature |
| **Instatus** | SaaS | Modern, integrations |
| **Statuspage (Atlassian)** | SaaS | Enterprise, expensive |

**Status page best practices:**
- Show individual component status (API, database, CDN, auth)
- Include historical uptime percentage (30/90 day)
- Post incident updates promptly (investigating → identified → monitoring → resolved)
- Subscribe option for email/SMS/RSS notifications
