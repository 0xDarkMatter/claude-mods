# Logging Reference

Comprehensive reference for structured logging, log aggregation, correlation, and language-specific implementations.

---

## Structured Logging

### Why Structured Logging

Unstructured logs are human-readable but machine-hostile:

```
# BAD: unstructured
2026-03-09 14:32:01 ERROR Failed to process payment for user 789: timeout after 30s

# GOOD: structured JSON
{"timestamp":"2026-03-09T14:32:01.123Z","level":"ERROR","message":"Failed to process payment","user_id":"789","error":"timeout after 30s","duration_ms":30042}
```

Structured logs enable:
- Machine parsing and indexing
- Filtering by any field (`user_id=789`, `level=ERROR`)
- Aggregation and metric extraction
- Correlation with traces via `trace_id`

### Standard JSON Log Format

```json
{
  "timestamp": "2026-03-09T14:32:01.123Z",
  "level": "ERROR",
  "message": "Failed to process payment",
  "logger": "payment.processor",
  "service": "payment-api",
  "version": "1.4.2",
  "environment": "production",
  "host": "payment-api-7b4d9f-x2k9l",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "request_id": "req-abc123",
  "user_id": "usr-789",
  "error": {
    "type": "PaymentGatewayTimeout",
    "message": "Gateway response timeout after 30s",
    "stack": "PaymentGatewayTimeout: Gateway response timeout...\n  at processPayment (payment.go:142)\n  at handleRequest (handler.go:87)"
  },
  "context": {
    "payment_id": "pay-456",
    "amount_cents": 2500,
    "currency": "USD",
    "gateway": "stripe"
  }
}
```

### Key Conventions

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `timestamp` | ISO 8601 string | Yes | Always UTC, millisecond precision |
| `level` | string | Yes | DEBUG, INFO, WARN, ERROR, FATAL |
| `message` | string | Yes | Human-readable, no variable interpolation in the key |
| `service` | string | Yes | Service name (matches Prometheus job label) |
| `version` | string | Yes | Application version or git SHA |
| `trace_id` | string | When available | OpenTelemetry trace ID (32 hex chars) |
| `span_id` | string | When available | OpenTelemetry span ID (16 hex chars) |
| `request_id` | string | When available | Edge-generated request ID |
| `error` | object | On errors | Include type, message, stack |
| `logger` | string | Recommended | Logger name / module path |
| `host` | string | Recommended | Hostname or pod name |
| `environment` | string | Recommended | production, staging, development |

---

## Log Levels

### Decision Guide

```
Is the process unable to continue?
├─ Yes → FATAL
│        Process must exit. Database unreachable at startup,
│        invalid critical config, out of memory.
│
└─ No → Did an operation fail?
         ├─ Yes → Is it actionable?
         │        ├─ Yes → ERROR
         │        │        Payment failed, API call returned 500,
         │        │        constraint violation, file not found.
         │        │
         │        └─ No  → WARN
         │                 Expected failure, retry will handle it,
         │                 deprecated API used, nearing limit.
         │
         └─ No  → Is it worth recording in production?
                   ├─ Yes → INFO
                   │        Request handled, job completed,
                   │        config loaded, connection established.
                   │
                   └─ No  → DEBUG
                            Variable values, SQL queries,
                            cache hit/miss, internal state.
```

### Level Details

#### FATAL

```json
{"level":"FATAL","message":"Cannot connect to database","error":{"type":"ConnectionRefused","message":"dial tcp 10.0.0.5:5432: connect: connection refused"},"action":"process_exit"}
```

- Process cannot start or must terminate
- Always followed by `os.Exit(1)` or equivalent
- Should trigger immediate alerting
- Very rare in well-designed systems

#### ERROR

```json
{"level":"ERROR","message":"Payment processing failed","payment_id":"pay-456","user_id":"usr-789","error":{"type":"GatewayTimeout","message":"Stripe API timeout after 30s"}}
```

- Operation failed and cannot be completed
- Someone should investigate (now or soon)
- Every ERROR should have an associated alert or dashboard
- **Not for:** User input validation failures (that's WARN or INFO)

#### WARN

```json
{"level":"WARN","message":"Circuit breaker opened for payment gateway","gateway":"stripe","failure_count":5,"retry_after":"30s"}
```

- System is degraded but still functioning
- Worth monitoring but not necessarily immediate action
- Retry succeeded, fallback activated, approaching a limit
- **Not for:** Expected user errors (wrong password → INFO)

#### INFO

```json
{"level":"INFO","message":"Request completed","method":"GET","path":"/api/users","status":200,"duration_ms":45,"request_id":"req-abc123"}
```

- Normal operation, audit trail, business events
- Should not be noisy (aim for 1-5 lines per request)
- Deployments, configuration changes, job completions
- **Not for:** Debugging details (use DEBUG)

#### DEBUG

```json
{"level":"DEBUG","message":"Cache lookup","key":"user:789","hit":true,"ttl_remaining_ms":45200}
```

- Development and troubleshooting only
- Disabled in production by default
- Enable per-service or per-module when debugging
- SQL queries, cache operations, internal state

### Production Log Level Strategy

```
Production default:  INFO
Production debug:    DEBUG (per-service, time-limited, via config change)
Staging:             DEBUG
Development:         DEBUG
CI/Test:             WARN (reduce noise in test output)
```

---

## Correlation IDs

### Generating IDs

```go
// Go: UUID v4
import "github.com/google/uuid"
requestID := uuid.New().String()  // "550e8400-e29b-41d4-a716-446655440000"

// Go: ULID (sortable, timestamp-prefixed)
import "github.com/oklog/ulid/v2"
requestID := ulid.Make().String()  // "01ARZ3NDEKTSV4RRFFQ69G5FAV"
```

```python
# Python: UUID v4
import uuid
request_id = str(uuid.uuid4())

# Python: ULID
import ulid
request_id = str(ulid.new())
```

```javascript
// Node.js: UUID v4
import { randomUUID } from 'crypto';
const requestId = randomUUID();

// Node.js: ULID
import { ulid } from 'ulid';
const requestId = ulid();
```

### Propagation Middleware

#### Go (net/http)

```go
func correlationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Get or generate request ID
        requestID := r.Header.Get("X-Request-ID")
        if requestID == "" {
            requestID = uuid.New().String()
        }

        // Get trace context from OpenTelemetry
        span := trace.SpanFromContext(r.Context())
        traceID := span.SpanContext().TraceID().String()
        spanID := span.SpanContext().SpanID().String()

        // Add to context
        ctx := context.WithValue(r.Context(), "request_id", requestID)

        // Add to response headers
        w.Header().Set("X-Request-ID", requestID)

        // Add to logger context
        logger := slog.With(
            "request_id", requestID,
            "trace_id", traceID,
            "span_id", spanID,
        )
        ctx = context.WithValue(ctx, "logger", logger)

        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

#### Python (FastAPI)

```python
import uuid
from contextvars import ContextVar
from fastapi import FastAPI, Request
from starlette.middleware.base import BaseHTTPMiddleware

request_id_var: ContextVar[str] = ContextVar("request_id", default="")

class CorrelationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        request_id_var.set(request_id)

        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response

app = FastAPI()
app.add_middleware(CorrelationMiddleware)
```

#### Node.js (Express)

```javascript
import { randomUUID } from 'crypto';
import { AsyncLocalStorage } from 'async_hooks';

const asyncLocalStorage = new AsyncLocalStorage();

function correlationMiddleware(req, res, next) {
  const requestId = req.headers['x-request-id'] || randomUUID();
  res.setHeader('X-Request-ID', requestId);

  asyncLocalStorage.run({ requestId }, () => {
    next();
  });
}

// Access anywhere in the request lifecycle
function getRequestId() {
  return asyncLocalStorage.getStore()?.requestId || 'unknown';
}
```

### HTTP Client Propagation

Always forward correlation IDs when making outbound HTTP calls:

```go
// Go
req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
req.Header.Set("X-Request-ID", getRequestID(ctx))
// OpenTelemetry propagation is automatic with instrumented HTTP client
```

```python
# Python
headers = {"X-Request-ID": request_id_var.get()}
response = httpx.get(url, headers=headers)
```

---

## Request Context Logging

### Standard Request/Response Log

```go
func loggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        wrapped := &responseWriter{ResponseWriter: w, statusCode: 200}

        next.ServeHTTP(wrapped, r)

        duration := time.Since(start)
        logger.InfoContext(r.Context(), "Request completed",
            "method", r.Method,
            "path", r.URL.Path,
            "status", wrapped.statusCode,
            "duration_ms", duration.Milliseconds(),
            "bytes_written", wrapped.bytesWritten,
            "remote_addr", r.RemoteAddr,
            "user_agent", r.UserAgent(),
        )
    })
}
```

### What to Log Per Request

| Field | When | Notes |
|-------|------|-------|
| Method, path, status, duration | Always | Core request metadata |
| Request ID, trace ID | Always | Correlation |
| User ID | When authenticated | For audit trail |
| Request body | Selectively | Only for mutations, with size limit |
| Response body | Rarely | Only for debugging, never in production |
| Query parameters | When relevant | Sanitize sensitive params |
| IP address | For security | Respect privacy regulations |
| User-Agent | For analytics | Browser/client identification |

### Body Size Limits

```go
// Never log unbounded request/response bodies
const maxBodyLogSize = 4096 // 4KB

func truncateBody(body []byte) string {
    if len(body) > maxBodyLogSize {
        return string(body[:maxBodyLogSize]) + "... [truncated]"
    }
    return string(body)
}
```

---

## Log Aggregation

### Loki

**Architecture:** Like Prometheus, but for logs. Index-free design — indexes labels only, not log content.

#### Loki Configuration

```yaml
# loki-config.yml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 30d
  max_query_length: 721h
  max_entries_limit_per_query: 5000
```

#### LogQL Basics

```logql
# Filter by label
{job="api-server"} |= "error"

# JSON parsing
{job="api-server"} | json | level="ERROR"

# Pattern matching
{job="api-server"} | json | status_code >= 500

# Rate of log lines (like Prometheus rate)
rate({job="api-server"} |= "error" [5m])

# Count errors by path
sum by (path) (
  count_over_time({job="api-server"} | json | level="ERROR" [5m])
)

# Latency percentile from log field
quantile_over_time(0.99, {job="api-server"} | json | unwrap duration_ms [5m])

# Top error messages
topk(10,
  sum by (message) (count_over_time({job="api-server"} | json | level="ERROR" [1h]))
)
```

#### Label Design for Loki

```yaml
# GOOD: Low-cardinality labels
labels:
  job: "api-server"
  environment: "production"
  namespace: "default"

# BAD: High-cardinality labels (will kill Loki performance)
labels:
  user_id: "12345"       # Millions of unique values
  request_id: "abc-123"  # Every request is unique
  path: "/api/users/123" # Include path in log content, not labels
```

**Rule:** Labels in Loki are for stream selection (which container/service), not for filtering log content. Use `| json | field="value"` for content filtering.

#### Promtail (Log Collector)

```yaml
# promtail-config.yml
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  # Docker container logs
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        target_label: container
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: stream

  # Kubernetes pod logs
  - job_name: kubernetes
    kubernetes_sd_configs:
      - role: pod
    pipeline_stages:
      - docker: {}
      - json:
          expressions:
            level: level
            trace_id: trace_id
      - labels:
          level:
      - timestamp:
          source: timestamp
          format: RFC3339Nano
```

### ELK Stack (Elasticsearch, Logstash, Kibana)

#### Logstash Pipeline

```ruby
# logstash.conf
input {
  beats {
    port => 5044
  }
}

filter {
  # Parse JSON logs
  json {
    source => "message"
  }

  # Parse timestamp
  date {
    match => ["timestamp", "ISO8601"]
    target => "@timestamp"
  }

  # Add geoip from remote_addr
  if [remote_addr] {
    geoip {
      source => "remote_addr"
    }
  }

  # Redact sensitive fields
  mutate {
    remove_field => ["password", "token", "authorization"]
  }

  # Parse user-agent
  if [user_agent] {
    useragent {
      source => "user_agent"
      target => "ua"
    }
  }
}

output {
  elasticsearch {
    hosts => ["elasticsearch:9200"]
    index => "logs-%{[service]}-%{+YYYY.MM.dd}"
  }
}
```

### CloudWatch Logs

```python
# Python: CloudWatch Logs with structlog
import structlog
import watchtower
import logging

# CloudWatch handler
cw_handler = watchtower.CloudWatchLogHandler(
    log_group="production/api-server",
    stream_name="{hostname}-{datetime}",
    use_queues=True,
    create_log_group=True,
)

# Configure structlog to output JSON
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    logger_factory=structlog.stdlib.LoggerFactory(),
)

logging.basicConfig(handlers=[cw_handler], level=logging.INFO)
```

#### CloudWatch Metric Filters

Extract metrics from log patterns:

```json
{
  "filterPattern": "{ $.level = \"ERROR\" }",
  "metricTransformations": [
    {
      "metricName": "ErrorCount",
      "metricNamespace": "ApiServer",
      "metricValue": "1",
      "defaultValue": 0
    }
  ]
}
```

```json
{
  "filterPattern": "{ $.duration_ms > 1000 }",
  "metricTransformations": [
    {
      "metricName": "SlowRequests",
      "metricNamespace": "ApiServer",
      "metricValue": "$.duration_ms"
    }
  ]
}
```

---

## Log Retention Policies

### Tiered Storage Strategy

| Tier | Duration | Resolution | Storage | Cost |
|------|----------|------------|---------|------|
| **Hot** | 0-7 days | Full fidelity | SSD / fast storage | $$$ |
| **Warm** | 7-30 days | Full fidelity | Standard storage | $$ |
| **Cold** | 30-90 days | Sampled or compressed | Object storage (S3) | $ |
| **Archive** | 90 days - 7 years | Compressed | Glacier / archive | ¢ |

### Compliance Retention Requirements

| Regulation | Minimum Retention | Notes |
|------------|-------------------|-------|
| PCI DSS | 1 year (3 months immediately available) | Audit logs for card data access |
| HIPAA | 6 years | Access logs for health data |
| SOX | 7 years | Financial system audit trails |
| GDPR | "No longer than necessary" | Right to erasure applies |
| SOC 2 | 1 year typical | Security event logs |

### Cost Optimization

1. **Set appropriate log levels:** DEBUG off in production saves 50-80% volume
2. **Sample verbose paths:** Log 10% of health check requests
3. **Truncate large fields:** Limit request/response body logging to 4KB
4. **Use log-based metrics:** Extract counts/rates, then archive raw logs
5. **Compress early:** Enable gzip on log transport (Promtail, Fluentd)
6. **Delete test/staging logs aggressively:** 7-day retention for non-production

---

## Sensitive Data Handling

### PII Masking

```go
// Go: mask sensitive fields before logging
func maskEmail(email string) string {
    parts := strings.Split(email, "@")
    if len(parts) != 2 {
        return "***"
    }
    name := parts[0]
    if len(name) > 2 {
        name = name[:2] + strings.Repeat("*", len(name)-2)
    }
    return name + "@" + parts[1]
}

func maskCreditCard(cc string) string {
    if len(cc) < 4 {
        return "****"
    }
    return strings.Repeat("*", len(cc)-4) + cc[len(cc)-4:]
}
```

```python
# Python: structlog processor for PII masking
import re

SENSITIVE_KEYS = {"password", "token", "secret", "authorization", "cookie", "ssn"}
EMAIL_PATTERN = re.compile(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}")
CC_PATTERN = re.compile(r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b")

def mask_sensitive_data(logger, method_name, event_dict):
    for key, value in list(event_dict.items()):
        if key.lower() in SENSITIVE_KEYS:
            event_dict[key] = "***REDACTED***"
        elif isinstance(value, str):
            value = EMAIL_PATTERN.sub("[EMAIL]", value)
            value = CC_PATTERN.sub("[CREDIT_CARD]", value)
            event_dict[key] = value
    return event_dict

structlog.configure(
    processors=[
        mask_sensitive_data,
        structlog.processors.JSONRenderer(),
    ]
)
```

### Fields to Never Log

| Field | Risk | Alternative |
|-------|------|-------------|
| Passwords | Credential exposure | Log "password changed" event, not the value |
| API keys / tokens | Service compromise | Log last 4 characters only |
| Credit card numbers | PCI violation | Log last 4 digits, masked |
| SSN / national ID | Identity theft | Never log, even masked |
| Full request bodies with auth | Token leakage | Strip Authorization header |
| Database connection strings | DB credential exposure | Log host:port only |

---

## Log-Based Metrics

### Loki Recording Rules

```yaml
# loki-rules.yml
groups:
  - name: log_metrics
    interval: 1m
    rules:
      - record: log:errors:rate5m
        expr: |
          sum by (service) (
            rate({job=~".+"} | json | level="ERROR" [5m])
          )

      - record: log:requests:duration_p99_5m
        expr: |
          quantile_over_time(0.99,
            {job="api-server"} | json | unwrap duration_ms [5m]
          ) by (service)
```

### Extracting Metrics from Logs

When full metrics instrumentation isn't available, derive metrics from structured logs:

```promql
# Error rate from logs (Loki)
sum(rate({job="api-server"} | json | level="ERROR" [5m]))

# Slow request rate from logs
sum(rate({job="api-server"} | json | duration_ms > 1000 [5m]))

# Unique users from logs (approximate)
count(
  count by (user_id) (
    {job="api-server"} | json | user_id != "" [1h]
  )
)
```

---

## Language-Specific Logging

### Go (slog - standard library, Go 1.21+)

```go
package main

import (
    "context"
    "log/slog"
    "os"
)

func main() {
    // JSON handler for production
    handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: slog.LevelInfo,
        AddSource: true,  // Add file:line to log entries
    })
    logger := slog.New(handler)
    slog.SetDefault(logger)

    // Basic logging
    slog.Info("Server starting", "port", 8080, "version", "1.4.2")

    // With context (includes trace_id if using OpenTelemetry bridge)
    ctx := context.Background()
    slog.InfoContext(ctx, "Request handled",
        "method", "GET",
        "path", "/api/users",
        "status", 200,
        "duration_ms", 45,
    )

    // Error logging with error value
    slog.Error("Database query failed",
        "error", err,
        "query", "SELECT * FROM users WHERE id = $1",
        "user_id", userID,
    )

    // Create child logger with bound attributes
    userLogger := slog.With("user_id", "usr-789", "session_id", "sess-abc")
    userLogger.Info("User action", "action", "login")
}
```

### Python (structlog)

```python
import structlog

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
)

log = structlog.get_logger()

# Basic logging
log.info("server_starting", port=8080, version="1.4.2")

# Bind context for the request
log = log.bind(request_id="req-abc123", user_id="usr-789")
log.info("request_handled", method="GET", path="/api/users", status=200, duration_ms=45)

# Error with exception
try:
    process_payment(payment_id)
except Exception:
    log.error("payment_failed", payment_id="pay-456", exc_info=True)

# Context variables (available across async calls)
structlog.contextvars.bind_contextvars(request_id="req-abc123")
```

### Node.js (pino)

```javascript
import pino from 'pino';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    level: (label) => ({ level: label.toUpperCase() }),
  },
  serializers: {
    err: pino.stdSerializers.err,
    req: pino.stdSerializers.req,
    res: pino.stdSerializers.res,
  },
  redact: ['req.headers.authorization', 'req.headers.cookie', 'password'],
});

// Basic logging
logger.info({ port: 8080, version: '1.4.2' }, 'Server starting');

// Child logger with bound context
const reqLogger = logger.child({ requestId: 'req-abc123', userId: 'usr-789' });
reqLogger.info({ method: 'GET', path: '/api/users', status: 200, durationMs: 45 }, 'Request handled');

// Error logging
reqLogger.error({ err, paymentId: 'pay-456' }, 'Payment failed');

// Express/Fastify integration
import pinoHttp from 'pino-http';
app.use(pinoHttp({ logger }));
```

### Rust (tracing crate)

```rust
use tracing::{info, error, warn, instrument, Level};
use tracing_subscriber::{fmt, EnvFilter};

fn main() {
    // JSON subscriber for production
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(true)
        .with_thread_ids(true)
        .with_file(true)
        .with_line_number(true)
        .init();

    info!(port = 8080, version = "1.4.2", "Server starting");
}

#[instrument(skip(db), fields(user_id = %user_id))]
async fn get_user(db: &Pool, user_id: &str) -> Result<User, Error> {
    info!("Fetching user from database");

    match db.query_one("SELECT * FROM users WHERE id = $1", &[&user_id]).await {
        Ok(row) => {
            info!("User found");
            Ok(User::from_row(row))
        }
        Err(e) => {
            error!(error = %e, "Database query failed");
            Err(e.into())
        }
    }
}
```

### Java (Logback + Structured Logging)

```xml
<!-- logback.xml -->
<configuration>
  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
      <includeMdcKeyName>request_id</includeMdcKeyName>
      <includeMdcKeyName>trace_id</includeMdcKeyName>
      <includeMdcKeyName>user_id</includeMdcKeyName>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="STDOUT" />
  </root>
</configuration>
```

```java
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import net.logstash.logback.argument.StructuredArguments;
import static net.logstash.logback.argument.StructuredArguments.*;

Logger log = LoggerFactory.getLogger(PaymentService.class);

// Set MDC for request context
MDC.put("request_id", requestId);
MDC.put("trace_id", traceId);
MDC.put("user_id", userId);

// Structured logging with key-value pairs
log.info("Request handled", kv("method", "GET"), kv("path", "/api/users"),
         kv("status", 200), kv("duration_ms", 45));

// Error logging
log.error("Payment failed", kv("payment_id", paymentId), kv("error", e.getMessage()), e);

// Clean up MDC
MDC.clear();
```

---

## Common Patterns

### Error Logging with Stack Traces

Always include the full stack trace for errors, but consider truncation for very deep stacks:

```go
// Go
slog.Error("Operation failed",
    "error", err.Error(),
    "stack", fmt.Sprintf("%+v", err),  // With pkgs/errors stack
)
```

```python
# Python - structlog handles exc_info automatically
log.error("operation_failed", exc_info=True)
```

### Audit Logging

For compliance-required operations:

```json
{
  "timestamp": "2026-03-09T14:32:01.123Z",
  "level": "INFO",
  "type": "audit",
  "action": "user.role.changed",
  "actor": {"id": "usr-admin-1", "type": "user", "ip": "10.0.0.5"},
  "target": {"id": "usr-789", "type": "user"},
  "changes": {"role": {"from": "viewer", "to": "editor"}},
  "result": "success",
  "request_id": "req-abc123"
}
```

### Request/Response Logging

```go
// Log request on entry, response on exit
func loggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()

        // Log request (don't log body for GET, limit body size for POST)
        slog.InfoContext(r.Context(), "Request received",
            "method", r.Method,
            "path", r.URL.Path,
            "remote_addr", r.RemoteAddr,
        )

        wrapped := wrapResponseWriter(w)
        next.ServeHTTP(wrapped, r)

        slog.InfoContext(r.Context(), "Request completed",
            "method", r.Method,
            "path", r.URL.Path,
            "status", wrapped.Status(),
            "duration_ms", time.Since(start).Milliseconds(),
            "bytes", wrapped.BytesWritten(),
        )
    })
}
```

### Health Check Log Suppression

Don't fill logs with health check noise:

```go
func loggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Skip logging for health checks
        if r.URL.Path == "/health" || r.URL.Path == "/ready" {
            next.ServeHTTP(w, r)
            return
        }
        // ... normal logging
    })
}
```
