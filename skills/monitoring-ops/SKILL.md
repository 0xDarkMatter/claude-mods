---
name: monitoring-ops
description: "Observability patterns - metrics, logging, tracing, alerting, and infrastructure monitoring. Use for: monitoring, observability, prometheus, grafana, metrics, alerting, structured logging, distributed tracing, opentelemetry, SLO, SLI, dashboard, health check, loki, jaeger, datadog, pagerduty."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: python-observability-ops, docker-ops, ci-cd-ops, nginx-ops
---

# Monitoring Operations

Comprehensive observability patterns covering the three pillars (metrics, logging, tracing), alerting strategies, dashboard design, and infrastructure monitoring for production systems.

---

## Three Pillars Quick Reference

Use this table to decide which observability signal fits your need:

| Pillar | Best For | Tools | Data Type |
|--------|----------|-------|-----------|
| **Metrics** | Aggregated numeric measurements, trends, alerting on thresholds | Prometheus, Datadog, CloudWatch, StatsD | Time-series (numeric) |
| **Logs** | Discrete events, error details, audit trails, debugging context | Loki, ELK, CloudWatch Logs, Fluentd | Unstructured/structured text |
| **Traces** | Request flow across services, latency breakdown, dependency mapping | Jaeger, Tempo, Zipkin, Datadog APM | Span trees (structured) |

**When to use which:**

- **"How many requests per second?"** → Metrics (counter + rate)
- **"Why did this specific request fail?"** → Logs (error message + stack trace)
- **"Where is the latency in this request?"** → Traces (span waterfall)
- **"Is the system healthy right now?"** → Metrics (gauges + alerts)
- **"What happened at 3:42 AM?"** → Logs (timestamped event search)
- **"Which downstream service caused the timeout?"** → Traces (span analysis)

**Correlation is key:** Connect all three by embedding `trace_id` in log entries, recording exemplars in metrics, and linking trace spans to log queries.

---

## Metrics Type Decision Tree

Use this tree to select the correct metric type:

```
What are you measuring?
│
├─ A count of events that only goes up?
│  └─ COUNTER
│     Examples: http_requests_total, errors_total, bytes_sent_total
│     Use rate() or increase() to get per-second or per-interval values
│     Never use a counter's raw value — it resets on restart
│
├─ A current value that goes up AND down?
│  └─ GAUGE
│     Examples: temperature_celsius, active_connections, queue_depth
│     Use for snapshots of current state
│     Can use avg_over_time(), max_over_time() for trends
│
├─ A distribution of values (latency, size)?
│  │
│  ├─ Need aggregatable quantiles across instances?
│  │  └─ HISTOGRAM
│  │     Examples: http_request_duration_seconds, response_size_bytes
│  │     Define buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
│  │     Use histogram_quantile() for percentiles (p50, p95, p99)
│  │     Aggregatable across instances (histograms can be summed)
│  │
│  └─ Need pre-calculated quantiles on a single instance?
│     └─ SUMMARY
│        Examples: go_gc_duration_seconds
│        Pre-calculates quantiles client-side
│        NOT aggregatable across instances
│        Prefer histogram unless you have a specific reason
│
└─ None of the above?
   └─ INFO metric (labels only, value=1)
      Examples: build_info{version="1.2.3", commit="abc123"}
      Use for metadata exposed as metrics
```

**Rule of thumb:** Start with counters and histograms. Add gauges for current state. Avoid summaries unless you have a compelling reason.

---

## Alerting Decision Tree

```
What type of alert do you need?
│
├─ Known threshold with a fixed boundary?
│  └─ THRESHOLD-BASED
│     Example: CPU > 90% for 5 minutes
│     Pros: Simple, predictable, easy to understand
│     Cons: Requires manual tuning, doesn't adapt to patterns
│     Best for: Resource limits, error rate spikes, queue depth
│
├─ Normal behavior varies by time/season?
│  └─ ANOMALY-BASED
│     Example: Traffic 3 standard deviations below normal for this hour
│     Pros: Adapts to patterns, catches novel failures
│     Cons: Noisy during transitions, requires training data
│     Best for: Traffic patterns, business metrics, gradual degradation
│
└─ Defined reliability targets?
   └─ SLO-BASED (PREFERRED)
      Example: Error budget burn rate > 14.4x for 1 hour
      Pros: Aligned with user impact, reduces noise, principled
      Cons: Requires SLI/SLO definition, more complex setup
      Best for: User-facing services, platform reliability
```

### Severity Levels

| Severity | Response | Examples | Routing |
|----------|----------|----------|---------|
| **Critical (P1)** | Page on-call immediately | Service down, data loss risk, security breach | PagerDuty high-urgency, phone call |
| **Warning (P2)** | Investigate within hours | Elevated error rate, disk 80% full, SLO burn rate elevated | PagerDuty low-urgency, Slack alert channel |
| **Info (P3)** | Review next business day | Deployment completed, certificate expiring in 30 days | Slack info channel, ticket auto-created |

### When to Page vs When to Ticket

**Page (wake someone up) when:**
- Users are currently impacted
- Data loss is occurring or imminent
- Security incident is active
- Error budget will be exhausted within hours

**Create ticket (don't page) when:**
- Issue is not user-facing yet
- Automated remediation is possible
- Degradation is slow and has runway
- Issue is during business hours and can be triaged normally

---

## Structured Logging Quick Reference

### Standard JSON Log Format

```json
{
  "timestamp": "2026-03-09T14:32:01.123Z",
  "level": "ERROR",
  "message": "Failed to process payment",
  "service": "payment-api",
  "version": "1.4.2",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "request_id": "req-abc123",
  "user_id": "usr-789",
  "error": {
    "type": "PaymentGatewayTimeout",
    "message": "Gateway response timeout after 30s",
    "stack": "..."
  },
  "duration_ms": 30042,
  "http": {
    "method": "POST",
    "path": "/api/v1/payments",
    "status_code": 504
  }
}
```

### Log Level Decision Guide

| Level | When to Use | Examples |
|-------|-------------|---------|
| **DEBUG** | Development only, verbose internal state | Variable values, SQL queries, cache hits/misses |
| **INFO** | Normal operations worth recording | Request completed, job started/finished, config loaded |
| **WARN** | Degraded but still functioning | Retry succeeded, fallback used, approaching limit |
| **ERROR** | Operation failed, needs attention | Payment failed, API call error, constraint violation |
| **FATAL** | Process cannot continue, must exit | Database unreachable at startup, invalid config, OOM |

**Rules:**
- Never log at ERROR for expected conditions (user input validation → WARN)
- Every ERROR should be actionable — if no one will act on it, use WARN
- DEBUG should be off in production by default
- INFO should not be noisy — 1-5 log lines per request, not 50

### Correlation IDs

- Generate a `request_id` (UUID v4 or ULID) at the edge/gateway
- Propagate through all internal services via headers (`X-Request-ID`)
- Include `trace_id` and `span_id` from distributed tracing
- Log all three IDs in every log entry for cross-referencing

---

## Distributed Tracing Quick Reference

### Core Concepts

- **Trace:** End-to-end journey of a request across all services
- **Span:** A single unit of work (HTTP call, DB query, function execution)
- **Context propagation:** Passing trace/span IDs between services via headers

### W3C TraceContext Header

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
              │  │                                  │                  │
              │  │                                  │                  └─ flags (01=sampled)
              │  │                                  └─ parent span ID (16 hex)
              │  └─ trace ID (32 hex)
              └─ version (00)
```

### Sampling Strategies

| Strategy | How It Works | Use When |
|----------|--------------|----------|
| **Head-based (ratio)** | Decide at trace start, propagate decision | Low traffic, need predictable volume |
| **Always-on** | Sample everything | Development, low-traffic services |
| **Parent-based** | Follow parent's sampling decision | Default for most services |
| **Tail-based** | Decide after trace completes (at Collector) | Need error/slow traces, high traffic |

**Recommendation:** Use parent-based + tail-based at the Collector. This captures all error traces and slow traces while controlling volume.

### Trace ID in Logs

Always include `trace_id` in structured log entries. This enables jumping from a log line to the full trace view:

```
Log entry → trace_id → Jaeger/Tempo → full request waterfall
```

---

## Tool Selection Matrix

| Feature | Prometheus + Grafana | Datadog | Grafana Cloud | CloudWatch |
|---------|---------------------|---------|---------------|------------|
| **Cost** | Free (infra costs) | $$$$ (per host/metric) | $$ (usage-based) | $$ (AWS-native) |
| **Setup complexity** | High (self-managed) | Low (SaaS agent) | Medium (managed) | Low (AWS-native) |
| **Metrics** | Prometheus (excellent) | Built-in (excellent) | Mimir (excellent) | Built-in (good) |
| **Logs** | Loki (good) | Built-in (excellent) | Loki (good) | CloudWatch Logs (good) |
| **Traces** | Jaeger/Tempo (good) | APM (excellent) | Tempo (good) | X-Ray (adequate) |
| **Alerting** | Alertmanager (good) | Built-in (excellent) | Grafana Alerting (good) | CloudWatch Alarms (adequate) |
| **Dashboards** | Grafana (excellent) | Built-in (excellent) | Grafana (excellent) | Dashboards (adequate) |
| **Retention** | Configurable (unlimited) | 15 months default | Configurable | Up to 15 months |
| **Multi-cloud** | Yes | Yes | Yes | AWS only |
| **Best for** | Cost-conscious, control | Full-featured, enterprise | Open-source + managed | AWS-native shops |

**Recommendation path:**
- **Starting out / budget-conscious:** Prometheus + Grafana + Loki + Tempo (all free, self-hosted)
- **Small team, want managed:** Grafana Cloud free tier (10k metrics, 50GB logs, 50GB traces)
- **Enterprise, need everything:** Datadog (expensive but comprehensive)
- **AWS-only shop:** CloudWatch + X-Ray (simplest if already on AWS)

---

## Dashboard Design

### USE Method (Infrastructure)

For every resource (CPU, memory, disk, network):

| Signal | Question | Metric Example |
|--------|----------|----------------|
| **Utilization** | How busy is it? | `node_cpu_seconds_total` (% busy) |
| **Saturation** | How overloaded is it? | `node_load1` (run queue length) |
| **Errors** | Are there error events? | `node_network_receive_errs_total` |

### RED Method (Services)

For every service endpoint:

| Signal | Question | Metric Example |
|--------|----------|----------------|
| **Rate** | How many requests per second? | `rate(http_requests_total[5m])` |
| **Errors** | How many are failing? | `rate(http_requests_total{status=~"5.."}[5m])` |
| **Duration** | How long do they take? | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` |

### Four Golden Signals (Google SRE)

| Signal | What to Measure | Alert Threshold Guidance |
|--------|-----------------|--------------------------|
| **Latency** | Time to serve a request (distinguish success vs error latency) | p99 > 2x baseline |
| **Traffic** | Demand on the system (requests/sec, sessions, transactions) | Anomaly detection |
| **Errors** | Rate of failed requests (explicit 5xx, implicit policy violations) | > 0.1% of traffic |
| **Saturation** | How "full" the service is (CPU, memory, queue depth) | > 80% capacity |

### Dashboard Layout Best Practices

1. **Top row:** Key health indicators (error rate, latency p99, availability %)
2. **Second row:** Traffic and throughput (requests/sec, active users)
3. **Third row:** Resource utilization (CPU, memory, disk, network)
4. **Bottom rows:** Detailed breakdowns (by endpoint, by status code, by region)
5. **Use variables:** Service, environment, time range as dropdown selectors
6. **Include annotations:** Deployments, incidents, config changes as vertical markers

---

## Common Gotchas

| Gotcha | Why It Happens | Fix |
|--------|----------------|-----|
| **Cardinality explosion** | Using unbounded label values (user ID, request path, query string) | Use bounded labels only; aggregate high-cardinality data in logs, not metrics |
| **Alert fatigue** | Too many alerts, too sensitive thresholds, alerts on non-actionable symptoms | Require runbook for every alert; tune thresholds; use SLO-based alerting |
| **Missing correlation IDs** | Logs, metrics, and traces not linked together | Include trace_id in all log entries; use exemplars in metrics |
| **Sampling bias** | Head-based sampling drops error/slow traces at high sample rates | Use tail-based sampling at the Collector to always capture errors and slow traces |
| **Log volume costs** | DEBUG or verbose INFO in production, logging full request/response bodies | Set production to INFO minimum; truncate large payloads; use sampling for verbose paths |
| **Metric naming inconsistency** | Different teams use different naming conventions | Adopt OpenMetrics naming: `namespace_subsystem_unit_suffix` (e.g., `http_server_request_duration_seconds`) |
| **Dashboard sprawl** | Everyone creates dashboards, nobody maintains them | Standardize with USE/RED templates; review quarterly; delete unused dashboards |
| **SLO too aggressive** | Setting 99.99% availability without the budget or architecture for it | Start with 99.5% or 99.9%; tighten only when consistently meeting targets with margin |
| **Missing baseline** | Alerting on absolute thresholds without understanding normal behavior | Collect 2-4 weeks of baseline data before setting alert thresholds |
| **Over-instrumentation** | Instrumenting every function, creating too many spans/metrics | Instrument at service boundaries; use auto-instrumentation for HTTP/DB/gRPC; add manual spans selectively |
| **Ignoring metric staleness** | Assuming a metric that stops reporting means zero | Use `absent()` or `up == 0` to detect missing scrapers; distinguish "zero" from "not reporting" |
| **Alerting on cause not symptom** | Alerting on CPU usage instead of user-facing error rate | Alert on symptoms (error rate, latency); use cause metrics (CPU, memory) for investigation |
| **No retention policy** | Storing all metrics/logs at full resolution forever | Define retention tiers: 15s resolution for 2 weeks, 1m for 3 months, 5m for 1 year |
| **Dashboard without context** | Graphs with no units, no description, no threshold lines | Add units to Y-axis, threshold lines for SLOs, panel descriptions explaining what "good" looks like |

---

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| [metrics-alerting.md](references/metrics-alerting.md) | Prometheus, Grafana, OpenTelemetry metrics, SLI/SLO/SLA, alert routing, runbooks, uptime monitoring | ~650 |
| [logging.md](references/logging.md) | Structured logging, log levels, correlation IDs, aggregation (Loki, ELK), retention, PII masking, language-specific | ~550 |
| [tracing.md](references/tracing.md) | OpenTelemetry, spans, context propagation, sampling, Jaeger, async tracing, DB/HTTP/gRPC instrumentation | ~600 |
| [infrastructure.md](references/infrastructure.md) | Health checks, K8s probes, Docker HEALTHCHECK, infra metrics, APM, cost optimization, incident response | ~550 |

---

## See Also

- **docker-ops** — Container monitoring with cAdvisor, Docker stats, and health checks
- **ci-cd-ops** — Pipeline observability, deployment tracking, build metrics
- **nginx-ops** — Nginx access/error log parsing, request metrics, upstream monitoring
- **python-observability-ops** — Python-specific instrumentation with structlog, opentelemetry-python
- [OpenTelemetry documentation](https://opentelemetry.io/docs/)
- [Prometheus best practices](https://prometheus.io/docs/practices/)
- [Google SRE Book — Monitoring chapter](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Grafana dashboards library](https://grafana.com/grafana/dashboards/)
