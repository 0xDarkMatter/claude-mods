# REST Advanced Patterns

## Table of Contents

- [Resource Modeling](#resource-modeling)
- [HTTP Methods Beyond CRUD](#http-methods-beyond-crud)
- [Content Negotiation](#content-negotiation)
- [Pagination Implementations](#pagination-implementations)
- [Filtering, Sorting, Field Selection](#filtering-sorting-field-selection)
- [Bulk Operations](#bulk-operations)
- [Long-Running Operations](#long-running-operations)
- [HATEOAS and Hypermedia](#hateoas-and-hypermedia)
- [API Documentation](#api-documentation)
- [Webhook Design](#webhook-design)
- [Caching](#caching)

---

## Resource Modeling

### Collections vs Singletons

```
/users              # Collection - supports GET (list), POST (create)
/users/{id}         # Singleton  - supports GET, PUT, PATCH, DELETE
/users/{id}/profile # Singleton sub-resource (1:1 relationship)
/users/{id}/orders  # Sub-collection (1:many relationship)
```

### Modeling Relationships

**Approach 1: Sub-resources (strong ownership)**
```
GET /users/{id}/orders          # Orders belong to user
POST /users/{id}/orders         # Create order for user
```

**Approach 2: Top-level with filters (independent entities)**
```
GET /orders?user_id={id}        # Orders exist independently
GET /orders/{order_id}          # Direct access without user context
```

**Approach 3: Relationship endpoints (many-to-many)**
```
GET  /users/{id}/roles          # List user's roles
PUT  /users/{id}/roles/{rid}    # Assign role (no body needed)
DELETE /users/{id}/roles/{rid}  # Remove role
```

### When to Use Sub-Resources

| Use sub-resource | Use top-level |
|------------------|---------------|
| Child can't exist without parent | Entity is independently meaningful |
| Always accessed in parent context | Frequently queried across parents |
| Moderate cardinality (< 1000) | High cardinality |
| Lifecycle tied to parent | Independent lifecycle |

### Resource Naming Patterns

```
# Actions that don't map to CRUD - use sub-resources
POST /orders/{id}/cancel         # State transition
POST /users/{id}/verify-email    # Trigger action
POST /reports/{id}/export        # Async operation

# Avoid: verbs as top-level resources
POST /cancelOrder                # Bad
POST /send-notification          # Bad

# Search as a resource (when GET query string is too complex)
POST /users/search
{ "filters": { "age_range": [18, 30], "location": { "within": "10km", "of": [lat, lng] } } }
```

## HTTP Methods Beyond CRUD

### PATCH Strategies

**JSON Merge Patch (RFC 7396)** - Simple, intuitive:

```
PATCH /users/123
Content-Type: application/merge-patch+json

{ "name": "New Name", "address": null }
```

- Set `name` to "New Name"
- Remove `address` (null = delete)
- Leave all other fields unchanged
- Limitation: cannot set a field TO null vs removing it

**JSON Patch (RFC 6902)** - Precise operations:

```
PATCH /users/123
Content-Type: application/json-patch+json

[
  { "op": "replace", "path": "/name", "value": "New Name" },
  { "op": "remove", "path": "/address" },
  { "op": "add", "path": "/tags/-", "value": "premium" },
  { "op": "test", "path": "/version", "value": 5 }
]
```

- Supports: add, remove, replace, move, copy, test
- `test` enables optimistic concurrency (apply only if value matches)
- More complex but unambiguous

**Recommendation**: Use JSON Merge Patch for most APIs (simpler). Use JSON Patch when you need array manipulation or atomic test-and-set.

### HEAD and OPTIONS

```
# HEAD - metadata without body (same headers as GET)
HEAD /files/report.pdf
# Returns: Content-Length, Content-Type, Last-Modified, ETag
# Use: check existence, get size before download

# OPTIONS - discover allowed methods (CORS preflight uses this)
OPTIONS /users
# Returns: Allow: GET, POST, HEAD, OPTIONS
```

## Content Negotiation

### Accept Header

```
# Client requests specific format
GET /users/123
Accept: application/json              # JSON (default)
Accept: application/xml               # XML
Accept: text/csv                      # CSV export
Accept: application/pdf               # PDF report

# Versioning via media type
Accept: application/vnd.myapi.v2+json  # Version in media type
```

### Content-Type on Requests

```
# Server must validate Content-Type on mutations
POST /users
Content-Type: application/json         # Standard
Content-Type: multipart/form-data      # File uploads
Content-Type: application/x-www-form-urlencoded  # Form data
```

### Implementation (Go)

```go
func handleGetUser(w http.ResponseWriter, r *http.Request) {
    accept := r.Header.Get("Accept")
    user := fetchUser(r)

    switch {
    case strings.Contains(accept, "application/xml"):
        w.Header().Set("Content-Type", "application/xml")
        xml.NewEncoder(w).Encode(user)
    case strings.Contains(accept, "text/csv"):
        w.Header().Set("Content-Type", "text/csv")
        writeCSV(w, user)
    default:
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(user)
    }
}
```

## Pagination Implementations

### Cursor-Based (Recommended for Most Cases)

Encode the cursor as base64 for opacity:

```go
// Encode cursor
type Cursor struct {
    ID        int64     `json:"id"`
    CreatedAt time.Time `json:"created_at"`
}

func encodeCursor(c Cursor) string {
    b, _ := json.Marshal(c)
    return base64.URLEncoding.EncodeToString(b)
}

func decodeCursor(s string) (Cursor, error) {
    b, err := base64.URLEncoding.DecodeString(s)
    if err != nil {
        return Cursor{}, err
    }
    var c Cursor
    return c, json.Unmarshal(b, &c)
}
```

**Request/Response:**

```
GET /users?limit=20&after=eyJpZCI6MTIzLCJjcmVhdGVkX2F0IjoiMjAyNC0wMS0xNVQxMDozMDowMFoifQ==

{
  "data": [...],
  "pagination": {
    "has_more": true,
    "next_cursor": "eyJpZCI6MTQzLCJjcmVhdGVkX2F0IjoiMjAyNC0wMS0xNlQwODoxNTowMFoifQ==",
    "prev_cursor": "eyJpZCI6MTI0LCJjcmVhdGVkX2F0IjoiMjAyNC0wMS0xNVQxMTowMDowMFoifQ=="
  }
}
```

**SQL (keyset pagination under the hood):**

```sql
SELECT * FROM users
WHERE (created_at, id) > ('2024-01-15T10:30:00Z', 123)
ORDER BY created_at ASC, id ASC
LIMIT 21;  -- fetch limit+1 to determine has_more
```

### Link Headers (RFC 8288)

```
Link: <https://api.example.com/users?after=abc123&limit=20>; rel="next",
      <https://api.example.com/users?before=xyz789&limit=20>; rel="prev",
      <https://api.example.com/users?limit=20>; rel="first"
```

### Total Count Considerations

- `total` count requires a separate `COUNT(*)` query - expensive on large tables
- Make it opt-in: `GET /users?limit=20&include_total=true`
- Consider approximate counts: `SELECT reltuples FROM pg_class WHERE relname = 'users'`

## Filtering, Sorting, Field Selection

### Filtering

```
# Simple equality
GET /users?status=active&role=admin

# Operators (LHS brackets style - used by Stripe, Supabase)
GET /users?created_at[gte]=2024-01-01&created_at[lt]=2024-02-01
GET /products?price[lte]=100&category[in]=electronics,books

# Operators (filter syntax)
GET /users?filter=status eq "active" and age gt 18
```

### Sorting

```
# Simple (comma-separated, prefix - for descending)
GET /users?sort=-created_at,name

# Multiple fields
GET /products?sort=category,-price    # category ASC, then price DESC
```

### Sparse Fieldsets

```
# Return only specific fields (reduces payload)
GET /users?fields=id,name,email
GET /users/123?fields=id,name,email,profile.avatar

# Related resource fields
GET /orders?fields=id,total&fields[customer]=id,name
```

## Bulk Operations

### Batch Create

```
POST /users/batch
Content-Type: application/json

{
  "items": [
    { "name": "Alice", "email": "alice@example.com" },
    { "name": "Bob", "email": "bob@example.com" }
  ]
}

# Response: 207 Multi-Status
{
  "results": [
    { "status": 201, "data": { "id": "u1", "name": "Alice" } },
    { "status": 409, "error": { "type": "conflict", "detail": "Email already exists" } }
  ],
  "summary": { "succeeded": 1, "failed": 1 }
}
```

### Batch Actions

```
POST /users/batch-action
{
  "action": "deactivate",
  "ids": ["u1", "u2", "u3"],
  "reason": "Account cleanup"
}
```

### Guidelines

- Set a maximum batch size (100-1000 items)
- Return 207 Multi-Status for partial success
- Include per-item status in response
- Consider async processing for large batches (return 202 + job URL)

## Long-Running Operations

### Polling Pattern

```
# Start operation
POST /reports/generate
{ "type": "annual", "year": 2024 }

# Response: 202 Accepted
{
  "operation_id": "op-abc-123",
  "status": "pending",
  "status_url": "/operations/op-abc-123",
  "estimated_completion": "2024-01-15T10:35:00Z"
}

# Poll for status
GET /operations/op-abc-123
{
  "operation_id": "op-abc-123",
  "status": "completed",          # pending | running | completed | failed
  "progress": 100,
  "result_url": "/reports/rpt-xyz-789",
  "completed_at": "2024-01-15T10:34:12Z"
}
```

### Webhook Callback

```
POST /reports/generate
{
  "type": "annual",
  "year": 2024,
  "callback_url": "https://myapp.com/webhooks/report-ready"
}

# Server POSTs to callback_url when done:
{
  "event": "report.completed",
  "operation_id": "op-abc-123",
  "result_url": "/reports/rpt-xyz-789"
}
```

### Server-Sent Events

```
GET /operations/op-abc-123/stream
Accept: text/event-stream

event: progress
data: {"percent": 25, "stage": "fetching data"}

event: progress
data: {"percent": 75, "stage": "generating charts"}

event: complete
data: {"result_url": "/reports/rpt-xyz-789"}
```

## HATEOAS and Hypermedia

### When It's Worth the Complexity

| Worth it | Not worth it |
|----------|--------------|
| Public API with many consumers | Internal microservice |
| API that evolves frequently | Stable, versioned API |
| Workflow-driven (state machines) | Simple CRUD |
| Discoverability is a feature | Clients are tightly coupled |

### HAL (Hypertext Application Language)

```json
{
  "id": "order-123",
  "status": "pending_payment",
  "total": 5999,
  "_links": {
    "self": { "href": "/orders/order-123" },
    "pay": { "href": "/orders/order-123/pay", "method": "POST" },
    "cancel": { "href": "/orders/order-123", "method": "DELETE" }
  },
  "_embedded": {
    "items": [
      {
        "product_id": "prod-456",
        "quantity": 2,
        "_links": {
          "product": { "href": "/products/prod-456" }
        }
      }
    ]
  }
}
```

## API Documentation

### OpenAPI 3.1 Structure

```yaml
openapi: 3.1.0
info:
  title: My API
  version: 2.0.0
  description: |
    ## Authentication
    All endpoints require Bearer token authentication.
  contact:
    email: api-support@example.com
servers:
  - url: https://api.example.com/v2
    description: Production
  - url: https://sandbox.example.com/v2
    description: Sandbox

paths:
  /users:
    get:
      summary: List users
      operationId: listUsers
      tags: [Users]
      parameters:
        - name: limit
          in: query
          schema:
            type: integer
            default: 20
            maximum: 100
      responses:
        '200':
          description: Success
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/UserList'
```

### Documentation Tools

| Tool | Strength |
|------|----------|
| Redoc | Beautiful single-page docs from OpenAPI |
| Swagger UI | Interactive "try it" playground |
| Stoplight | Design-first with mock servers |
| Mintlify | Modern docs with guides + API reference |

## Webhook Design

### Webhook Payload

```json
{
  "id": "evt_abc123",
  "type": "order.completed",
  "created_at": "2024-01-15T10:30:00Z",
  "api_version": "2024-01-15",
  "data": {
    "id": "order-456",
    "status": "completed",
    "total": 5999
  }
}
```

### Signature Verification

```
# Header
X-Webhook-Signature: sha256=5257a869e7ecebeda32affa62cdca3fa51cad7e77a0e56ff536d0ce8e108d8bd

# Compute: HMAC-SHA256(webhook_secret, raw_body)
```

```go
func verifyWebhookSignature(secret, signature string, body []byte) bool {
    mac := hmac.New(sha256.New, []byte(secret))
    mac.Write(body)
    expected := "sha256=" + hex.EncodeToString(mac.Sum(nil))
    return hmac.Equal([]byte(expected), []byte(signature))
}
```

### Webhook Best Practices

| Practice | Detail |
|----------|--------|
| Retry with backoff | 1s, 5s, 30s, 5m, 30m, 2h, 24h |
| Idempotency | Include event ID, consumers must deduplicate |
| Timeout | 30 second max wait for 2xx response |
| Disable after failures | Disable after N consecutive failures, notify owner |
| Event log | Provide UI/API to replay failed webhooks |
| Thin payloads | Send IDs + event type, let consumer fetch full data |

## Caching

### ETag-Based (Strong Validation)

```
# First request
GET /users/123
ETag: "a1b2c3d4"

# Subsequent request
GET /users/123
If-None-Match: "a1b2c3d4"

# Response if unchanged: 304 Not Modified (no body)
# Response if changed: 200 with new ETag
```

### Last-Modified (Weak Validation)

```
GET /users/123
Last-Modified: Thu, 15 Jan 2024 10:30:00 GMT

# Subsequent request
GET /users/123
If-Modified-Since: Thu, 15 Jan 2024 10:30:00 GMT
```

### Cache-Control Directives

```
# Public, cacheable for 1 hour
Cache-Control: public, max-age=3600

# Private (user-specific), cacheable for 5 minutes
Cache-Control: private, max-age=300

# No caching (real-time data)
Cache-Control: no-store

# Revalidate before using cache
Cache-Control: no-cache

# Stale-while-revalidate (serve stale, refresh in background)
Cache-Control: public, max-age=60, stale-while-revalidate=300
```

### Caching Strategy by Resource Type

| Resource Type | Strategy | Cache-Control |
|---------------|----------|---------------|
| Static assets | Immutable with hash | `public, max-age=31536000, immutable` |
| User profile | Short-lived, private | `private, max-age=60` |
| Product catalog | Medium, public | `public, max-age=300, stale-while-revalidate=600` |
| Search results | No cache or very short | `no-store` or `max-age=10` |
| Real-time data | No cache | `no-store` |
