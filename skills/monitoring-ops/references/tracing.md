# Distributed Tracing Reference

Comprehensive reference for OpenTelemetry, context propagation, sampling, and instrumentation patterns.

---

## OpenTelemetry Architecture

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Application │     │  Application │     │  Application │
│  (SDK + API) │     │  (SDK + API) │     │  (SDK + API) │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │ OTLP              │ OTLP              │ OTLP
       ▼                   ▼                   ▼
┌─────────────────────────────────────────────────────────┐
│                   OTel Collector                         │
│  ┌───────────┐  ┌────────────┐  ┌───────────────────┐  │
│  │ Receivers │→ │ Processors │→ │    Exporters      │  │
│  │ (OTLP,    │  │ (batch,    │  │ (Jaeger, Tempo,   │  │
│  │  Jaeger,  │  │  filter,   │  │  Datadog, OTLP)   │  │
│  │  Zipkin)  │  │  tail      │  │                   │  │
│  │           │  │  sampling) │  │                   │  │
│  └───────────┘  └────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────┘
       │                    │                    │
       ▼                    ▼                    ▼
┌──────────┐        ┌──────────┐        ┌──────────────┐
│  Jaeger  │        │  Tempo   │        │   Datadog    │
│  (UI)    │        │  (store) │        │   (SaaS)     │
└──────────┘        └──────────┘        └──────────────┘
```

### Components

| Component | Role | Notes |
|-----------|------|-------|
| **API** | Stable interfaces for instrumentation | Language-specific, vendor-neutral |
| **SDK** | Implementation of the API | Configures sampling, export, processing |
| **Collector** | Receives, processes, exports telemetry | Deploy as sidecar or gateway |
| **Exporters** | Send data to backends | OTLP (preferred), Jaeger, Zipkin, vendor-specific |
| **Auto-instrumentation** | Automatic span creation for frameworks | HTTP, gRPC, database, messaging |

### Collector Configuration

```yaml
# otel-collector-config.yml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

  memory_limiter:
    check_interval: 1s
    limit_mib: 1024
    spike_limit_mib: 256

  # Tail-based sampling (decide after seeing complete trace)
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      # Always sample errors
      - name: errors
        type: status_code
        status_code:
          status_codes: [ERROR]
      # Always sample slow traces (> 2s)
      - name: slow-traces
        type: latency
        latency:
          threshold_ms: 2000
      # Sample 10% of everything else
      - name: probabilistic
        type: probabilistic
        probabilistic:
          sampling_percentage: 10

  # Add resource attributes
  resource:
    attributes:
      - key: environment
        value: production
        action: upsert

exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, batch, resource]
      exporters: [otlp/jaeger]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
```

---

## Span Model

### Span Anatomy

```
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
│
├─ Span: "GET /api/orders"
│  ├─ Span ID: 00f067aa0ba902b7
│  ├─ Parent: (none - root span)
│  ├─ Start: 2026-03-09T14:32:01.000Z
│  ├─ End:   2026-03-09T14:32:01.245Z
│  ├─ Status: OK
│  ├─ Attributes:
│  │   http.method: GET
│  │   http.url: /api/orders?user_id=789
│  │   http.status_code: 200
│  │   http.response_content_length: 4523
│  ├─ Events:
│  │   └─ "cache.miss" at T+5ms {key: "orders:usr-789"}
│  │
│  ├─ Span: "SELECT orders"
│  │  ├─ Span ID: a1b2c3d4e5f60718
│  │  ├─ Parent: 00f067aa0ba902b7
│  │  ├─ Duration: 45ms
│  │  ├─ Attributes:
│  │  │   db.system: postgresql
│  │  │   db.operation: SELECT
│  │  │   db.statement: SELECT * FROM orders WHERE user_id = $1
│  │  │   db.rows_affected: 12
│  │  └─ Status: OK
│  │
│  └─ Span: "GET payment-service/status"
│     ├─ Span ID: b2c3d4e5f6071829
│     ├─ Parent: 00f067aa0ba902b7
│     ├─ Duration: 120ms
│     ├─ Attributes:
│     │   http.method: GET
│     │   http.url: http://payment-service:8080/status
│     │   http.status_code: 200
│     │   peer.service: payment-service
│     └─ Status: OK
```

### Span Attributes (Semantic Conventions)

#### HTTP Spans

| Attribute | Example | Notes |
|-----------|---------|-------|
| `http.request.method` | `GET` | HTTP method |
| `url.path` | `/api/orders` | URL path |
| `http.response.status_code` | `200` | Response status |
| `http.request.body.size` | `1024` | Request body bytes |
| `http.response.body.size` | `4523` | Response body bytes |
| `server.address` | `api.example.com` | Server hostname |
| `server.port` | `443` | Server port |
| `network.protocol.version` | `1.1` | HTTP version |
| `user_agent.original` | `Mozilla/5.0...` | User agent string |

#### Database Spans

| Attribute | Example | Notes |
|-----------|---------|-------|
| `db.system` | `postgresql` | Database type |
| `db.namespace` | `myapp` | Database name |
| `db.operation.name` | `SELECT` | SQL operation |
| `db.query.text` | `SELECT * FROM...` | Sanitized query |
| `server.address` | `db.example.com` | DB host |
| `server.port` | `5432` | DB port |
| `db.response.rows_affected` | `12` | Rows returned/affected |

#### gRPC Spans

| Attribute | Example | Notes |
|-----------|---------|-------|
| `rpc.system` | `grpc` | RPC system |
| `rpc.service` | `myapp.UserService` | Service name |
| `rpc.method` | `GetUser` | Method name |
| `rpc.grpc.status_code` | `0` | gRPC status code |

### Span Status

| Status | When | Notes |
|--------|------|-------|
| `UNSET` | Default | Operation completed, no explicit status |
| `OK` | Explicitly successful | Use sparingly, UNSET is fine for success |
| `ERROR` | Operation failed | Always set for 5xx responses, exceptions |

---

## SDK Setup

### Go

```go
package main

import (
    "context"
    "log"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
    "go.opentelemetry.io/otel/trace"
)

func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
    // OTLP gRPC exporter (sends to Collector)
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("otel-collector:4317"),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        return nil, err
    }

    // Resource: describes this service
    res, err := resource.Merge(
        resource.Default(),
        resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceName("order-service"),
            semconv.ServiceVersion("1.4.2"),
            attribute.String("environment", "production"),
        ),
    )
    if err != nil {
        return nil, err
    }

    // TracerProvider with batch span processor
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.ParentBased(
            sdktrace.TraceIDRatioBased(0.1), // 10% head sampling
        )),
    )

    // Set global TracerProvider and propagator
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},  // W3C TraceContext
        propagation.Baggage{},       // W3C Baggage
    ))

    return tp, nil
}

func main() {
    ctx := context.Background()
    tp, err := initTracer(ctx)
    if err != nil {
        log.Fatal(err)
    }
    defer tp.Shutdown(ctx)

    // Create spans
    tracer := otel.Tracer("order-service")

    ctx, span := tracer.Start(ctx, "ProcessOrder",
        trace.WithAttributes(
            attribute.String("order.id", "ord-123"),
            attribute.Int("order.items", 3),
        ),
    )
    defer span.End()

    // Add events
    span.AddEvent("order.validated", trace.WithAttributes(
        attribute.Bool("has_discount", true),
    ))

    // Record errors
    if err := processPayment(ctx); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
    }
}
```

### Go Auto-instrumentation

```go
import (
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "go.opentelemetry.io/contrib/instrumentation/github.com/jackc/pgx/v5/otelpgx"
)

// HTTP server: wrap handler
mux := http.NewServeMux()
mux.HandleFunc("/api/orders", handleOrders)
handler := otelhttp.NewHandler(mux, "server")
http.ListenAndServe(":8080", handler)

// HTTP client: wrap transport
client := &http.Client{
    Transport: otelhttp.NewTransport(http.DefaultTransport),
}

// gRPC server: add interceptors
server := grpc.NewServer(
    grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
    grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
)

// gRPC client: add interceptors
conn, _ := grpc.Dial(addr,
    grpc.WithUnaryInterceptor(otelgrpc.UnaryClientInterceptor()),
    grpc.WithStreamInterceptor(otelgrpc.StreamClientInterceptor()),
)

// pgx (PostgreSQL): add tracer
config, _ := pgxpool.ParseConfig(databaseURL)
config.ConnConfig.Tracer = otelpgx.NewTracer()
pool, _ := pgxpool.NewWithConfig(ctx, config)
```

### Python

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.propagators.textmap import DefaultTextMapPropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.baggage.propagation import W3CBaggagePropagator

# Resource
resource = Resource.create({
    SERVICE_NAME: "order-service",
    SERVICE_VERSION: "1.4.2",
    "environment": "production",
})

# TracerProvider
provider = TracerProvider(resource=resource)
provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint="otel-collector:4317", insecure=True)
    )
)
trace.set_tracer_provider(provider)

# Propagator
from opentelemetry import propagate
propagate.set_global_textmap(CompositePropagator([
    TraceContextTextMapPropagator(),
    W3CBaggagePropagator(),
]))

# Create spans
tracer = trace.get_tracer("order-service")

with tracer.start_as_current_span("process_order", attributes={
    "order.id": "ord-123",
    "order.items": 3,
}) as span:
    span.add_event("order.validated", {"has_discount": True})

    try:
        process_payment(order)
    except Exception as e:
        span.record_exception(e)
        span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
        raise
```

### Python Auto-instrumentation

```bash
# Install auto-instrumentation packages
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install  # Installs all detected instrumentors

# Run with auto-instrumentation
opentelemetry-instrument \
    --service_name order-service \
    --exporter_otlp_endpoint http://otel-collector:4317 \
    python app.py
```

```python
# Or configure programmatically
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor

FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()
Psycopg2Instrumentor().instrument()
RedisInstrumentor().instrument()
```

### Node.js

```javascript
// tracing.js - import BEFORE other modules
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { Resource } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [ATTR_SERVICE_NAME]: 'order-service',
    [ATTR_SERVICE_VERSION]: '1.4.2',
    environment: 'production',
  }),
  traceExporter: new OTLPTraceExporter({
    url: 'http://otel-collector:4317',
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Disable fs instrumentation (too noisy)
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk.shutdown().then(() => process.exit(0));
});
```

```javascript
// Manual span creation
const { trace } = require('@opentelemetry/api');

const tracer = trace.getTracer('order-service');

async function processOrder(orderId) {
  return tracer.startActiveSpan('process_order', {
    attributes: { 'order.id': orderId },
  }, async (span) => {
    try {
      span.addEvent('order.validated');
      await processPayment(orderId);
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      throw err;
    } finally {
      span.end();
    }
  });
}
```

---

## Context Propagation

### W3C TraceContext

The standard for propagating trace context across service boundaries.

**Request headers:**
```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate: vendor1=value1,vendor2=value2
```

**Format:** `version-trace_id-parent_id-trace_flags`

| Field | Size | Description |
|-------|------|-------------|
| version | 2 hex | Always `00` |
| trace_id | 32 hex | Unique trace identifier |
| parent_id | 16 hex | Span ID of the caller |
| trace_flags | 2 hex | `01` = sampled, `00` = not sampled |

### B3 Propagation (Zipkin)

Legacy format still used by some systems:

```
# Single header (compact)
b3: 4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1

# Multi-header
X-B3-TraceId: 4bf92f3577b34da6a3ce929d0e0e4736
X-B3-SpanId: 00f067aa0ba902b7
X-B3-ParentSpanId: (parent span)
X-B3-Sampled: 1
```

### Baggage

Propagate arbitrary key-value pairs across service boundaries:

```
baggage: userId=usr-789,region=us-east-1
```

```go
// Go: set baggage
bag, _ := baggage.Parse("userId=usr-789,region=us-east-1")
ctx = baggage.ContextWithBaggage(ctx, bag)

// Go: read baggage
bag := baggage.FromContext(ctx)
userId := bag.Member("userId").Value()
```

**Use sparingly:** Baggage is sent with every request. Don't put large values or sensitive data in baggage.

---

## Sampling Strategies

### Head-based Sampling

Decision made at trace creation, propagated to all downstream services.

| Sampler | Description | Config |
|---------|-------------|--------|
| `AlwaysOn` | Sample everything | Development only |
| `AlwaysOff` | Sample nothing | Disable tracing |
| `TraceIDRatioBased` | Sample N% of traces | `ratio: 0.1` for 10% |
| `ParentBased` | Follow parent's decision | Default, wrap another sampler |

```go
// Go: 10% sampling, respecting parent's decision
sampler := sdktrace.ParentBased(
    sdktrace.TraceIDRatioBased(0.1),
)
```

```python
# Python: 10% sampling
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased, ParentBasedTraceIdRatio
sampler = ParentBasedTraceIdRatio(0.1)
```

### Tail-based Sampling

Decision made after the trace completes. Requires the OTel Collector.

**Advantages:**
- Always captures error traces
- Always captures slow traces
- More representative sampling

**Configuration (Collector):**

```yaml
processors:
  tail_sampling:
    decision_wait: 10s         # Wait for spans to arrive
    num_traces: 100000         # Max traces in memory
    expected_new_traces_per_sec: 1000
    policies:
      # Always keep errors
      - name: errors-policy
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Always keep slow traces (root span > 2s)
      - name: latency-policy
        type: latency
        latency:
          threshold_ms: 2000

      # Keep all traces for specific operations
      - name: critical-operations
        type: string_attribute
        string_attribute:
          key: operation
          values: [payment, refund, account_deletion]

      # Sample 5% of remaining traces
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 5

      # Composite: apply multiple policies with priority
      - name: composite-policy
        type: composite
        composite:
          max_total_spans_per_second: 1000
          policy_order: [errors-policy, latency-policy, probabilistic-policy]
          rate_allocation:
            - policy: errors-policy
              percent: 50
            - policy: latency-policy
              percent: 30
            - policy: probabilistic-policy
              percent: 20
```

---

## Jaeger

### Deployment

#### All-in-One (Development)

```yaml
# docker-compose.yml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.54
    ports:
      - "16686:16686"   # UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
      - "14250:14250"   # Jaeger gRPC
    environment:
      COLLECTOR_OTLP_ENABLED: true
```

#### Production (with Elasticsearch)

```yaml
services:
  jaeger-collector:
    image: jaegertracing/jaeger-collector:1.54
    environment:
      SPAN_STORAGE_TYPE: elasticsearch
      ES_SERVER_URLS: http://elasticsearch:9200
      COLLECTOR_OTLP_ENABLED: true
    ports:
      - "4317:4317"
      - "14250:14250"

  jaeger-query:
    image: jaegertracing/jaeger-query:1.54
    environment:
      SPAN_STORAGE_TYPE: elasticsearch
      ES_SERVER_URLS: http://elasticsearch:9200
    ports:
      - "16686:16686"

  elasticsearch:
    image: elasticsearch:8.12.0
    environment:
      discovery.type: single-node
      xpack.security.enabled: false
      ES_JAVA_OPTS: "-Xms512m -Xmx512m"
    volumes:
      - es-data:/usr/share/elasticsearch/data

volumes:
  es-data:
```

### Jaeger UI Features

| Feature | Description |
|---------|-------------|
| **Search** | Find traces by service, operation, tags, duration, time range |
| **Trace View** | Waterfall visualization of spans with timing |
| **Compare** | Compare two traces side by side |
| **Dependencies** | Service dependency graph (DAG) |
| **Deep Dependency** | Trace-aware dependency analysis |
| **Monitor** | RED metrics derived from traces |

---

## Async Trace Propagation

### Go: context.Context

```go
// Context carries trace information automatically
func processOrder(ctx context.Context, orderID string) error {
    // Start child span — automatically linked to parent via ctx
    ctx, span := tracer.Start(ctx, "processOrder")
    defer span.End()

    // Pass context to goroutines
    g, ctx := errgroup.WithContext(ctx)
    g.Go(func() error {
        return validateOrder(ctx, orderID)  // ctx carries trace
    })
    g.Go(func() error {
        return checkInventory(ctx, orderID) // ctx carries trace
    })
    return g.Wait()
}
```

### Python: contextvars

```python
import asyncio
from opentelemetry import trace, context

tracer = trace.get_tracer("order-service")

async def process_order(order_id: str):
    with tracer.start_as_current_span("process_order") as span:
        # asyncio tasks automatically inherit context
        results = await asyncio.gather(
            validate_order(order_id),
            check_inventory(order_id),
        )
        return results

async def validate_order(order_id: str):
    # This span is automatically a child of process_order
    with tracer.start_as_current_span("validate_order"):
        pass
```

### Node.js: AsyncLocalStorage

```javascript
const { trace, context } = require('@opentelemetry/api');

// OpenTelemetry SDK uses AsyncLocalStorage internally
// Spans are automatically propagated through async operations

async function processOrder(orderId) {
  return tracer.startActiveSpan('process_order', async (span) => {
    try {
      // Promise.all preserves context
      const [validation, inventory] = await Promise.all([
        validateOrder(orderId),  // context propagated
        checkInventory(orderId), // context propagated
      ]);
      return { validation, inventory };
    } finally {
      span.end();
    }
  });
}
```

---

## Database Query Tracing

### Span Attributes for Database Queries

```json
{
  "name": "SELECT users",
  "attributes": {
    "db.system": "postgresql",
    "db.namespace": "myapp",
    "db.operation.name": "SELECT",
    "db.query.text": "SELECT id, name, email FROM users WHERE id = $1",
    "server.address": "db.example.com",
    "server.port": 5432,
    "db.response.rows_affected": 1
  }
}
```

### Query Parameter Sanitization

**Never log actual parameter values** — they may contain PII:

```go
// GOOD: sanitized
span.SetAttributes(
    attribute.String("db.query.text", "SELECT * FROM users WHERE id = $1 AND email = $2"),
)

// BAD: contains PII
span.SetAttributes(
    attribute.String("db.query.text", "SELECT * FROM users WHERE id = 789 AND email = 'john@example.com'"),
)
```

### N+1 Query Detection

Use traces to identify N+1 queries — they appear as many identical DB spans under one parent:

```
GET /api/orders (250ms)
├── SELECT orders WHERE user_id = $1 (5ms)
├── SELECT product WHERE id = $1 (3ms)    ← N+1
├── SELECT product WHERE id = $1 (3ms)    ← N+1
├── SELECT product WHERE id = $1 (4ms)    ← N+1
├── SELECT product WHERE id = $1 (3ms)    ← N+1
└── ... (20 more identical queries)
```

**Fix:** Use `SELECT * FROM products WHERE id IN ($1, $2, ...)` or JOIN.

---

## HTTP Client/Server Tracing

### Automatic Instrumentation

Most OpenTelemetry auto-instrumentation libraries create spans automatically for:
- HTTP server requests (incoming)
- HTTP client requests (outgoing)
- gRPC server/client calls
- Database queries
- Redis operations
- Message queue operations (Kafka, RabbitMQ)

### Custom Attributes on Auto-instrumented Spans

```go
// Add business context to auto-created spans
span := trace.SpanFromContext(ctx)
span.SetAttributes(
    attribute.String("user.id", userID),
    attribute.String("order.id", orderID),
    attribute.String("tenant.id", tenantID),
)
```

### Error Recording

```go
// Proper error recording
if err != nil {
    span.RecordError(err)  // Creates an event with exception details
    span.SetStatus(codes.Error, err.Error())  // Marks span as error
    return err
}

// For HTTP handlers
if statusCode >= 500 {
    span.SetStatus(codes.Error, fmt.Sprintf("HTTP %d", statusCode))
}
// Note: 4xx is NOT an error from the server's perspective
```

---

## gRPC Tracing

### Server Interceptors

```go
import "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"

server := grpc.NewServer(
    grpc.StatsHandler(otelgrpc.NewServerHandler()),
)
```

### Client Interceptors

```go
conn, err := grpc.Dial(addr,
    grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
)
```

### Streaming Spans

For streaming RPCs, spans cover the entire stream lifecycle:

```
ServerStream (user.ListUsers) — 2.5s
├─ stream.message.sent (1) — T+10ms
├─ stream.message.sent (2) — T+50ms
├─ stream.message.sent (3) — T+120ms
└─ stream.message.sent (4) — T+200ms
```

### Metadata Propagation

Context is automatically propagated via gRPC metadata when using OTel interceptors:

```go
// Automatic: OTel interceptors inject/extract from gRPC metadata
// metadata equivalent to HTTP headers:
//   traceparent → grpc-metadata-traceparent
//   tracestate  → grpc-metadata-tracestate
```

---

## Trace-Based Testing

### Asserting Span Structure

```go
// Go: using in-memory exporter for testing
import (
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    "go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestOrderProcessing(t *testing.T) {
    exporter := tracetest.NewInMemoryExporter()
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithSyncer(exporter),
    )
    otel.SetTracerProvider(tp)

    // Run the operation
    processOrder(context.Background(), "ord-123")

    // Assert spans
    spans := exporter.GetSpans()
    assert.Len(t, spans, 3)

    rootSpan := spans[0]
    assert.Equal(t, "processOrder", rootSpan.Name)
    assert.Equal(t, codes.Ok, rootSpan.Status.Code)

    dbSpan := spans[1]
    assert.Equal(t, "SELECT orders", dbSpan.Name)
    assert.Equal(t, "postgresql", dbSpan.Attributes["db.system"])

    // Verify parent-child relationship
    assert.Equal(t, rootSpan.SpanContext.SpanID(), dbSpan.Parent.SpanID())
}
```

```python
# Python: using in-memory exporter
from opentelemetry.sdk.trace.export.in_memory import InMemorySpanExporter

exporter = InMemorySpanExporter()
provider = TracerProvider()
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)

# Run operation
process_order("ord-123")

# Assert
spans = exporter.get_finished_spans()
assert len(spans) == 3
assert spans[0].name == "process_order"
assert spans[1].name == "SELECT orders"
assert spans[1].parent.span_id == spans[0].context.span_id
```

### Verifying Context Propagation

```go
func TestContextPropagation(t *testing.T) {
    // Create a trace context
    ctx, span := tracer.Start(context.Background(), "test-root")
    traceID := span.SpanContext().TraceID()

    // Call service that makes outbound HTTP call
    handler.ServeHTTP(recorder, req.WithContext(ctx))

    // Verify all spans share the same trace ID
    spans := exporter.GetSpans()
    for _, s := range spans {
        assert.Equal(t, traceID, s.SpanContext.TraceID())
    }

    span.End()
}
```
