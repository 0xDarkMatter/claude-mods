# Infrastructure Monitoring Reference

Comprehensive reference for health checks, infrastructure metrics, APM, cost optimization, capacity planning, and incident response.

---

## Health Checks

### Types of Health Checks

| Type | Question It Answers | Failure Action |
|------|---------------------|----------------|
| **Liveness** | Is the process alive and not deadlocked? | Restart the process |
| **Readiness** | Can this instance serve traffic? | Remove from load balancer |
| **Startup** | Has the process finished initializing? | Wait (don't restart yet) |

### Implementation Patterns

#### Basic Health Check Endpoint

```go
// Go
type HealthStatus struct {
    Status    string            `json:"status"`
    Timestamp string            `json:"timestamp"`
    Version   string            `json:"version"`
    Checks    map[string]Check  `json:"checks"`
}

type Check struct {
    Status  string `json:"status"`
    Message string `json:"message,omitempty"`
    Latency string `json:"latency,omitempty"`
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    health := HealthStatus{
        Status:    "ok",
        Timestamp: time.Now().UTC().Format(time.RFC3339),
        Version:   version,
        Checks:    make(map[string]Check),
    }

    // Check database
    start := time.Now()
    if err := db.PingContext(r.Context()); err != nil {
        health.Status = "degraded"
        health.Checks["database"] = Check{
            Status:  "fail",
            Message: err.Error(),
        }
    } else {
        health.Checks["database"] = Check{
            Status:  "ok",
            Latency: time.Since(start).String(),
        }
    }

    // Check Redis
    start = time.Now()
    if err := redis.Ping(r.Context()).Err(); err != nil {
        health.Status = "degraded"
        health.Checks["redis"] = Check{
            Status:  "fail",
            Message: err.Error(),
        }
    } else {
        health.Checks["redis"] = Check{
            Status:  "ok",
            Latency: time.Since(start).String(),
        }
    }

    statusCode := http.StatusOK
    if health.Status != "ok" {
        statusCode = http.StatusServiceUnavailable
    }

    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)
    json.NewEncoder(w).Encode(health)
}
```

```python
# Python (FastAPI)
from fastapi import FastAPI, Response
from datetime import datetime, timezone
import asyncio

app = FastAPI()

@app.get("/health")
async def health_check():
    checks = {}
    status = "ok"

    # Database check
    try:
        start = datetime.now(timezone.utc)
        await db.execute("SELECT 1")
        checks["database"] = {
            "status": "ok",
            "latency_ms": (datetime.now(timezone.utc) - start).total_seconds() * 1000,
        }
    except Exception as e:
        status = "degraded"
        checks["database"] = {"status": "fail", "message": str(e)}

    # Redis check
    try:
        start = datetime.now(timezone.utc)
        await redis.ping()
        checks["redis"] = {
            "status": "ok",
            "latency_ms": (datetime.now(timezone.utc) - start).total_seconds() * 1000,
        }
    except Exception as e:
        status = "degraded"
        checks["redis"] = {"status": "fail", "message": str(e)}

    response_code = 200 if status == "ok" else 503
    return Response(
        content=json.dumps({
            "status": status,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "checks": checks,
        }),
        status_code=response_code,
        media_type="application/json",
    )

@app.get("/ready")
async def readiness_check():
    """Readiness: can we serve traffic?"""
    try:
        await db.execute("SELECT 1")
        return {"status": "ready"}
    except Exception:
        return Response(
            content='{"status": "not_ready"}',
            status_code=503,
            media_type="application/json",
        )

@app.get("/live")
async def liveness_check():
    """Liveness: is the process alive?"""
    return {"status": "alive"}
```

#### Health Check Response Format

```json
{
  "status": "ok",
  "timestamp": "2026-03-09T14:32:01Z",
  "version": "1.4.2",
  "checks": {
    "database": {
      "status": "ok",
      "latency_ms": 2.3
    },
    "redis": {
      "status": "ok",
      "latency_ms": 0.8
    },
    "external_api": {
      "status": "degraded",
      "message": "Elevated latency",
      "latency_ms": 850
    }
  }
}
```

### Liveness vs Readiness Decision Guide

```
Is the process able to make progress?
├─ No (deadlocked, OOM, infinite loop)
│  └─ Liveness check should FAIL → container gets restarted
│
└─ Yes, but...
   ├─ Database is temporarily unreachable
   │  └─ Readiness FAIL, Liveness PASS → stop sending traffic, don't restart
   │
   ├─ Still loading initial data/cache
   │  └─ Startup FAIL → don't check liveness yet, wait
   │
   └─ Everything is fine
      └─ All checks PASS → serve traffic normally
```

**Common mistake:** Making liveness depend on external dependencies (database, Redis). If the database is down, restarting the application won't help — it will cause a restart storm.

---

## Kubernetes Probes

### Configuration

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
spec:
  template:
    spec:
      containers:
        - name: api
          image: api-server:1.4.2
          ports:
            - containerPort: 8080

          # Startup probe: runs first, disables liveness/readiness until passing
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30     # 30 * 5s = 150s max startup time
            successThreshold: 1

          # Liveness probe: is the process alive?
          livenessProbe:
            httpGet:
              path: /live
              port: 8080
            initialDelaySeconds: 0    # Starts after startup probe passes
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3       # 3 consecutive failures → restart
            successThreshold: 1

          # Readiness probe: can it serve traffic?
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3       # 3 failures → remove from Service
            successThreshold: 1

          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### Probe Types

#### HTTP GET

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
    httpHeaders:
      - name: Authorization
        value: Bearer internal-token
```

#### TCP Socket

```yaml
# For services that don't have HTTP (databases, message brokers)
livenessProbe:
  tcpSocket:
    port: 5432
  periodSeconds: 10
```

#### Exec Command

```yaml
# Run a command inside the container
livenessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - pg_isready -U postgres
  periodSeconds: 10
```

#### gRPC Health Check

```yaml
# gRPC health checking protocol
livenessProbe:
  grpc:
    port: 50051
    service: ""   # Empty string checks overall server health
  periodSeconds: 10
```

### Probe Configuration Guidelines

| Parameter | Liveness | Readiness | Startup |
|-----------|----------|-----------|---------|
| `initialDelaySeconds` | 0 (use startup probe) | 0 | 5-10 |
| `periodSeconds` | 10-15 | 5-10 | 5 |
| `timeoutSeconds` | 3-5 | 3-5 | 3-5 |
| `failureThreshold` | 3 | 3 | 30 (generous) |
| `successThreshold` | 1 | 1-2 | 1 |

---

## Docker HEALTHCHECK

```dockerfile
# Dockerfile
FROM node:20-slim

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
  CMD curl -f http://localhost:8080/health || exit 1

# Or with wget (no curl in alpine)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1
```

### docker-compose Health Check

```yaml
services:
  api:
    image: api-server:1.4.2
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

  worker:
    image: worker:1.2.0
    depends_on:
      api:
        condition: service_healthy
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### Health Check Parameters

| Parameter | Description | Default | Recommendation |
|-----------|-------------|---------|----------------|
| `interval` | Time between checks | 30s | 15-30s for critical services |
| `timeout` | Max time for check | 30s | 3-5s (fail fast) |
| `retries` | Failures before unhealthy | 3 | 3 (avoid flapping) |
| `start_period` | Grace period for startup | 0s | Set to max startup time |

---

## Uptime Monitoring

### Uptime Kuma Setup

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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime.rule=Host(`status.example.com`)"

volumes:
  uptime-kuma-data:
```

**Monitor types supported:**
- HTTP(s) — status code, keyword, response time
- TCP — port open check
- DNS — resolution check
- Docker container — running status
- gRPC — health check protocol
- MQTT — broker connectivity
- Ping (ICMP) — network reachability
- Push — heartbeat endpoint (service pushes to Uptime Kuma)

### Synthetic Monitoring

Scripted checks that simulate real user behavior from multiple regions:

```javascript
// k6 script for synthetic monitoring
import { check, sleep } from 'k6';
import http from 'k6/http';

export const options = {
  scenarios: {
    synthetic: {
      executor: 'constant-vus',
      vus: 1,
      duration: '24h',
      gracefulStop: '0s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],    // 95% under 500ms
    http_req_failed: ['rate<0.01'],       // < 1% failure rate
    checks: ['rate>0.99'],                // 99% checks pass
  },
};

export default function () {
  // Check homepage
  let res = http.get('https://www.example.com');
  check(res, {
    'homepage status 200': (r) => r.status === 200,
    'homepage loads fast': (r) => r.timings.duration < 500,
    'homepage has title': (r) => r.body.includes('<title>'),
  });

  // Check API health
  res = http.get('https://api.example.com/health');
  check(res, {
    'api health 200': (r) => r.status === 200,
    'api reports ok': (r) => JSON.parse(r.body).status === 'ok',
  });

  // Check login flow
  res = http.post('https://api.example.com/auth/login', JSON.stringify({
    email: 'synthetic-user@example.com',
    password: process.env.SYNTHETIC_PASSWORD,
  }), { headers: { 'Content-Type': 'application/json' } });
  check(res, {
    'login succeeds': (r) => r.status === 200,
    'login returns token': (r) => JSON.parse(r.body).token !== undefined,
  });

  sleep(60); // Check every 60 seconds
}
```

### Multi-Region Monitoring

| Provider | Regions | Free Tier | Notes |
|----------|---------|-----------|-------|
| **Uptime Kuma** | Self-hosted (1 region) | Free | Deploy in multiple regions yourself |
| **Betteruptime** | 10+ regions | 5 monitors | Status page included |
| **Grafana Synthetic** | 20+ regions | Part of Grafana Cloud | k6-based scripts |
| **Datadog Synthetic** | 100+ locations | 100 API tests/month | Full browser testing |
| **AWS CloudWatch Synthetics** | All AWS regions | Pay per run | Canary scripts |

---

## Infrastructure Metrics

### CPU Metrics

| Metric | Source | What It Shows |
|--------|--------|---------------|
| `node_cpu_seconds_total{mode="user"}` | node_exporter | Time in user space |
| `node_cpu_seconds_total{mode="system"}` | node_exporter | Time in kernel space |
| `node_cpu_seconds_total{mode="iowait"}` | node_exporter | Time waiting for I/O |
| `node_cpu_seconds_total{mode="idle"}` | node_exporter | Idle time |
| `node_load1` / `node_load5` / `node_load15` | node_exporter | Load average (1/5/15 min) |

**Common queries:**

```promql
# CPU usage percentage (all modes except idle)
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

# CPU usage by mode
sum by (mode) (rate(node_cpu_seconds_total{instance="web01:9100"}[5m]))

# IO wait percentage (high = disk bottleneck)
avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m]))

# Load average vs CPU count
node_load1 / count without (cpu) (node_cpu_seconds_total{mode="idle"})
```

### Memory Metrics

| Metric | What It Shows |
|--------|---------------|
| `node_memory_MemTotal_bytes` | Total physical memory |
| `node_memory_MemAvailable_bytes` | Memory available for applications |
| `node_memory_Cached_bytes` | Page cache (reclaimable) |
| `node_memory_Buffers_bytes` | Buffer cache |
| `node_memory_SwapTotal_bytes` | Total swap |
| `node_memory_SwapFree_bytes` | Free swap |

```promql
# Memory usage percentage
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Memory breakdown
node_memory_MemTotal_bytes
  - node_memory_MemAvailable_bytes
  - node_memory_Cached_bytes
  - node_memory_Buffers_bytes

# Swap usage (any swap usage may indicate memory pressure)
1 - (node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)
```

### Disk Metrics

```promql
# Disk usage percentage
1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes)

# Disk I/O utilization (percentage of time doing I/O)
rate(node_disk_io_time_seconds_total[5m])

# Read/write throughput
rate(node_disk_read_bytes_total[5m])
rate(node_disk_written_bytes_total[5m])

# IOPS
rate(node_disk_reads_completed_total[5m])
rate(node_disk_writes_completed_total[5m])

# Average I/O latency
rate(node_disk_read_time_seconds_total[5m]) / rate(node_disk_reads_completed_total[5m])
```

### Network Metrics

```promql
# Bandwidth (bytes/sec)
rate(node_network_receive_bytes_total{device!="lo"}[5m])
rate(node_network_transmit_bytes_total{device!="lo"}[5m])

# Packet errors
rate(node_network_receive_errs_total[5m])
rate(node_network_transmit_errs_total[5m])

# TCP connections
node_netstat_Tcp_CurrEstab         # Current established connections
rate(node_netstat_Tcp_ActiveOpens[5m])  # New outbound connections/sec
rate(node_netstat_Tcp_PassiveOpens[5m]) # New inbound connections/sec
```

---

## Container Metrics

### cAdvisor Metrics

| Metric | Description |
|--------|-------------|
| `container_cpu_usage_seconds_total` | Total CPU time consumed |
| `container_cpu_cfs_throttled_periods_total` | CPU throttling events |
| `container_memory_working_set_bytes` | Current memory (excludes cache) |
| `container_memory_usage_bytes` | Total memory (includes cache) |
| `container_network_receive_bytes_total` | Network inbound bytes |
| `container_network_transmit_bytes_total` | Network outbound bytes |
| `container_fs_usage_bytes` | Container filesystem usage |
| `container_spec_memory_limit_bytes` | Memory limit |
| `container_spec_cpu_quota` | CPU quota |

```promql
# Container CPU usage percentage (of limit)
sum by (container, pod) (
  rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])
) / sum by (container, pod) (
  container_spec_cpu_quota / container_spec_cpu_period
)

# Container memory usage percentage (of limit)
container_memory_working_set_bytes{container!="POD",container!=""}
/
container_spec_memory_limit_bytes{container!="POD",container!=""} > 0

# CPU throttling percentage
sum by (container, pod) (
  rate(container_cpu_cfs_throttled_periods_total[5m])
) / sum by (container, pod) (
  rate(container_cpu_cfs_periods_total[5m])
)

# OOMKill detection
increase(kube_pod_container_status_restarts_total[1h]) > 0
and
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
```

### Kubernetes Metrics (kube-state-metrics)

```promql
# Pod status
kube_pod_status_phase{phase="Running"}
kube_pod_status_phase{phase="Pending"}
kube_pod_status_phase{phase="Failed"}

# Deployment replicas
kube_deployment_status_replicas_available
kube_deployment_spec_replicas

# HPA status
kube_horizontalpodautoscaler_status_current_replicas
kube_horizontalpodautoscaler_spec_max_replicas
```

---

## Node Exporter

### Setup

```yaml
# docker-compose.yml
services:
  node-exporter:
    image: prom/node-exporter:v1.7.0
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
```

### Kubernetes DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
    spec:
      hostPID: true
      hostNetwork: true
      containers:
        - name: node-exporter
          image: prom/node-exporter:v1.7.0
          ports:
            - containerPort: 9100
              hostPort: 9100
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
      tolerations:
        - effect: NoSchedule
          operator: Exists
```

---

## APM Tools

### Comparison

| Feature | Datadog APM | New Relic | Elastic APM | Sentry |
|---------|-------------|-----------|-------------|--------|
| **Type** | Full APM | Full APM | Full APM | Error tracking + perf |
| **Pricing** | Per host ($31+/mo) | Per user + data | Free (self-host) or Cloud | Per event volume |
| **Traces** | Yes | Yes | Yes | Transaction traces |
| **Error tracking** | Yes | Yes | Yes | Excellent |
| **Profiling** | Yes (continuous) | Yes | No | No |
| **Log correlation** | Yes | Yes | Yes | Breadcrumbs |
| **Dashboards** | Built-in | Built-in | Kibana | Limited |
| **Setup** | Agent-based | Agent-based | Agent or OTel | SDK-based |
| **Best for** | Enterprise, full stack | Full observability | Self-hosted, ELK users | Error-focused teams |

### Sentry Error Tracking

```python
# Python
import sentry_sdk
from sentry_sdk.integrations.fastapi import FastApiIntegration

sentry_sdk.init(
    dsn="https://key@sentry.io/project",
    traces_sample_rate=0.1,  # 10% of transactions
    profiles_sample_rate=0.1,
    environment="production",
    release="1.4.2",
    integrations=[FastApiIntegration()],
)
```

```javascript
// Node.js
const Sentry = require('@sentry/node');

Sentry.init({
  dsn: 'https://key@sentry.io/project',
  tracesSampleRate: 0.1,
  environment: 'production',
  release: '1.4.2',
});
```

```go
// Go
import "github.com/getsentry/sentry-go"

sentry.Init(sentry.ClientOptions{
    Dsn:              "https://key@sentry.io/project",
    TracesSampleRate: 0.1,
    Environment:      "production",
    Release:          "1.4.2",
})
defer sentry.Flush(2 * time.Second)
```

---

## Cost Optimization

### Metric Cardinality Review

High cardinality is the most common cost driver in metrics systems:

```promql
# Find metrics with the most time series
topk(20, count by (__name__) ({__name__=~".+"}))

# Find labels with high cardinality
count(group by (path) (http_requests_total))   # How many unique paths?
count(group by (user_id) (api_calls_total))    # Unbounded!
```

**Reduction strategies:**
1. Remove unused metrics (if nobody dashboards/alerts on it, drop it)
2. Replace high-cardinality labels with bounded categories
3. Use recording rules to pre-aggregate, drop raw metrics
4. Use metric relabeling in Prometheus to drop at scrape time

```yaml
# Drop unused metrics at scrape time
metric_relabel_configs:
  - source_labels: [__name__]
    regex: "go_.*"           # Drop Go runtime metrics if unused
    action: drop
```

### Log Volume Reduction

| Strategy | Savings | Implementation |
|----------|---------|----------------|
| Set production to INFO | 50-80% | Logger config |
| Sample health check logs | 90% for /health | Middleware filter |
| Truncate large payloads | 20-40% | Body size limit (4KB) |
| Drop duplicate errors | 30-50% | Rate-limit per error type |
| Compress in transit | 60-80% bandwidth | Enable gzip on log shipper |

### Trace Sampling

| Sampling Rate | Monthly Cost (est.) | Suitability |
|---------------|---------------------|-------------|
| 100% | $$$$ | Development, < 100 req/s |
| 10% | $$$ | Staging, medium traffic |
| 1% | $$ | Production, high traffic |
| Tail-based (errors + slow) | $$ | Production (recommended) |
| 0.1% | $ | Very high traffic (> 100k req/s) |

### Retention Tiers

| Tier | Metrics | Logs | Traces |
|------|---------|------|--------|
| Hot (0-14 days) | 15s resolution | Full fidelity | All sampled traces |
| Warm (14-90 days) | 1m resolution | Full fidelity | Error + slow traces only |
| Cold (90 days - 1 year) | 5m resolution | Compressed | None (rely on metrics) |
| Archive (1-7 years) | 1h resolution | Compliance logs only | None |

---

## Capacity Planning

### Load Testing Correlation

Run load tests while monitoring infrastructure metrics to establish scaling thresholds:

```
Load Test Results:
┌─────────┬──────────┬────────┬─────────┬──────────────┐
│ RPS     │ p99 (ms) │ CPU %  │ Mem %   │ Error Rate   │
├─────────┼──────────┼────────┼─────────┼──────────────┤
│ 100     │ 45       │ 15     │ 30      │ 0%           │
│ 500     │ 85       │ 35     │ 45      │ 0%           │
│ 1000    │ 150      │ 55     │ 55      │ 0%           │
│ 2000    │ 320      │ 75     │ 65      │ 0.1%         │
│ 3000    │ 850      │ 90     │ 72      │ 1.5%         │  ← degradation
│ 4000    │ 2500     │ 98     │ 78      │ 12%          │  ← failure
└─────────┴──────────┴────────┴─────────┴──────────────┘

Scaling trigger: 75% CPU → add instance
Target capacity: 2x expected peak traffic
```

### Scaling Triggers

```yaml
# Kubernetes HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-server
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70    # Scale up at 70% CPU
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"       # Scale at 1000 RPS per pod
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50                  # Max 50% increase per scale-up
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300  # Wait 5 min before scaling down
      policies:
        - type: Percent
          value: 25
          periodSeconds: 120
```

### Resource Forecasting

```promql
# Predict disk full in N hours
predict_linear(node_filesystem_avail_bytes[7d], 30*24*3600) < 0
# "Disk will be full within 30 days"

# Predict memory usage trend
predict_linear(
  avg_over_time(container_memory_working_set_bytes[7d]),
  30*24*3600
)

# Growth rate of database size
rate(pg_database_size_bytes[7d])
# Convert to "GB per month"
rate(pg_database_size_bytes[7d]) * 86400 * 30 / 1e9
```

---

## Incident Response

### Incident Lifecycle

```
Detection → Triage → Mitigate → Resolve → Postmortem
    │          │         │          │          │
    │          │         │          │          └─ Blameless review
    │          │         │          └─ Root cause fix deployed
    │          │         └─ User impact reduced/eliminated
    │          └─ Severity assigned, team engaged
    └─ Alert fires or user reports issue
```

### Severity Classification

| Severity | Impact | Response Time | Examples |
|----------|--------|---------------|---------|
| **SEV1 (Critical)** | Service down, data loss, security breach | < 15 minutes | Complete outage, payment processing failure |
| **SEV2 (Major)** | Significant degradation, partial outage | < 30 minutes | One region down, 50%+ error rate |
| **SEV3 (Minor)** | Limited impact, workaround exists | < 4 hours | Single feature broken, elevated latency |
| **SEV4 (Low)** | Minimal impact, cosmetic | Next business day | UI glitch, non-critical alert firing |

### Incident Commander Checklist

```markdown
## Initial Response (first 15 minutes)
- [ ] Acknowledge the alert / report
- [ ] Assess severity (SEV1-4)
- [ ] Open incident channel (#inc-YYYYMMDD-description)
- [ ] Page relevant team members
- [ ] Post initial status update

## Triage (15-30 minutes)
- [ ] Identify affected services and scope
- [ ] Check recent deployments: any changes in last 2 hours?
- [ ] Check dashboards for anomalies
- [ ] Check external dependencies (status pages)
- [ ] Determine if rollback is feasible

## Mitigation
- [ ] Implement immediate fix (rollback, feature flag, scaling)
- [ ] Verify user impact is reduced
- [ ] Update status page
- [ ] Communicate ETA for full resolution

## Resolution
- [ ] Confirm root cause
- [ ] Deploy fix
- [ ] Verify metrics return to baseline
- [ ] Clear incident status
- [ ] Schedule postmortem within 48 hours
```

### Postmortem Template

```markdown
# Incident Postmortem: [TITLE]

**Date:** 2026-03-09
**Duration:** 45 minutes (14:15 - 15:00 UTC)
**Severity:** SEV2
**Author:** [Name]
**Status:** Complete

## Summary
One-paragraph description of what happened and impact.

## Impact
- Users affected: ~5,000
- Revenue impact: ~$2,500
- SLO budget consumed: 3.2 hours of the monthly 43-minute budget

## Timeline (all times UTC)
| Time | Event |
|------|-------|
| 14:12 | Deploy v1.4.3 to production |
| 14:15 | Error rate alert fires (5% → 15%) |
| 14:17 | On-call acknowledges, starts investigation |
| 14:22 | Root cause identified: new query missing index |
| 14:25 | Decision: rollback v1.4.3 |
| 14:30 | Rollback complete |
| 14:35 | Error rate returns to baseline |
| 15:00 | All-clear declared |

## Root Cause
The v1.4.3 deployment added a new API endpoint that queried the orders
table without an index on `user_id + created_at`. Under load, this caused
connection pool exhaustion, which cascaded to other endpoints.

## Detection
Alert fired 3 minutes after deploy. Detection was effective.

## Contributing Factors
1. No load test for the new endpoint
2. Missing index not caught in code review
3. No query performance checks in CI

## Action Items
| Action | Owner | Due | Status |
|--------|-------|-----|--------|
| Add index on orders(user_id, created_at) | @backend | 2026-03-10 | Done |
| Add slow query detection to CI pipeline | @platform | 2026-03-15 | TODO |
| Add load test for new endpoints to deploy checklist | @backend | 2026-03-12 | TODO |
| Set up query performance alerting (> 100ms avg) | @sre | 2026-03-14 | TODO |

## Lessons Learned
- What went well: Fast detection (3 min), fast rollback (8 min)
- What went poorly: No pre-production load test caught the issue
- Where we got lucky: Happened during business hours, not at 3 AM
```

### Communication During Incidents

| Audience | Channel | Frequency | Content |
|----------|---------|-----------|---------|
| Engineering | Slack #incident | Real-time | Technical details, commands run |
| Management | Slack #incidents-summary | Every 15-30 min | Impact, ETA, escalation needs |
| Customers | Status page | Every 15-30 min | User-facing impact, workarounds |
| Support | Slack #support-escalation | On status change | Scripted responses, known workarounds |
