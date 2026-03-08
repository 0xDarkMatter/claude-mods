---
name: api-design-ops
description: "API design patterns for REST, gRPC, and GraphQL. Use for: api design, REST, gRPC, GraphQL, protobuf, schema design, api versioning, pagination, rate limiting, error format, OpenAPI, API authentication, JWT, OAuth2, API gateway, webhook, idempotency."
allowed-tools: "Read Write Bash"
related-skills: [rest-ops, security-ops, go-ops, rust-ops, typescript-ops]
---

# API Design Ops

Comprehensive API design patterns covering REST (advanced), gRPC, and GraphQL. This skill provides decision frameworks, design patterns, and implementation guidance for building production APIs.

## API Style Decision Tree

```
What kind of API do you need?
|
+-- Internal microservice-to-microservice?
|   +-- High throughput, low latency needed? --> gRPC
|   +-- Streaming (real-time data, logs)? --> gRPC (bidirectional streaming)
|   +-- Simple request/response, team comfort? --> REST
|
+-- Public-facing API?
|   +-- Third-party developers consuming it? --> REST (widest compatibility)
|   +-- Mobile app with varied data needs? --> GraphQL
|   +-- Browser-only, simple CRUD? --> REST
|
+-- Frontend for your own app?
|   +-- Multiple clients with different data shapes? --> GraphQL
|   +-- Single client, straightforward data? --> REST
|   +-- Real-time updates needed? --> GraphQL subscriptions or SSE
|
+-- IoT / embedded / constrained devices?
|   +-- Binary efficiency matters? --> gRPC
|   +-- HTTP-only environments? --> REST
```

### Quick Comparison

| Concern | REST | gRPC | GraphQL |
|---------|------|------|---------|
| Transport | HTTP/1.1+ | HTTP/2 | HTTP (any) |
| Serialization | JSON (text) | Protobuf (binary) | JSON (text) |
| Schema | OpenAPI (optional) | .proto (required) | SDL (required) |
| Browser support | Native | Via gRPC-Web/Connect | Native |
| Caching | HTTP caching built-in | Custom | Custom (normalized) |
| Learning curve | Low | Medium | Medium-High |
| Code generation | Optional | Required | Optional but recommended |
| Streaming | SSE, WebSocket | Native (4 patterns) | Subscriptions |
| Over-fetching | Common problem | No (typed) | Solved by design |
| File uploads | Multipart native | Chunked streaming | Multipart spec (awkward) |

## REST Resource Design Quick Reference

### Resource Naming

```
GET    /users                  # Collection
GET    /users/{id}             # Singleton
GET    /users/{id}/orders      # Sub-collection
POST   /users                  # Create
PUT    /users/{id}             # Full replace
PATCH  /users/{id}             # Partial update
DELETE /users/{id}             # Remove

# Naming rules:
# - Plural nouns for collections: /users NOT /user
# - Kebab-case for multi-word: /line-items NOT /lineItems
# - No verbs in URLs: POST /orders NOT POST /create-order
# - Max 3 levels deep: /users/{id}/orders (not /users/{id}/orders/{oid}/items/{iid}/details)
```

### HTTP Methods and Status Codes

| Method | Success | Empty | Invalid | Not Found | Conflict |
|--------|---------|-------|---------|-----------|----------|
| GET | 200 | 200 (empty array) | 400 | 404 | - |
| POST | 201 + Location | - | 400/422 | - | 409 |
| PUT | 200 | - | 400/422 | 404 | 409 |
| PATCH | 200 | - | 400/422 | 404 | 409 |
| DELETE | 204 | 204 (already gone) | 400 | 404 | 409 |

### HATEOAS (When Worth It)

Use when: public APIs where discoverability matters, long-lived APIs, APIs that evolve frequently.
Skip when: internal microservices, mobile backends, tight coupling is acceptable.

```json
{
  "id": "order-123",
  "status": "shipped",
  "_links": {
    "self": { "href": "/orders/order-123" },
    "track": { "href": "/orders/order-123/tracking" },
    "cancel": { "href": "/orders/order-123", "method": "DELETE" }
  }
}
```

## Pagination Decision Tree

```
What's your data like?
|
+-- Stable data, UI needs "jump to page 5"?
|   --> Offset pagination: ?page=5&per_page=20
|   Tradeoff: Slow on large offsets (OFFSET 10000), inconsistent with inserts
|
+-- Large dataset, forward-only traversal?
|   --> Cursor pagination: ?after=eyJpZCI6MTIzfQ&limit=20
|   Tradeoff: No random page access, but consistent and fast
|
+-- Real-time feed, ordered by timestamp or ID?
|   --> Keyset pagination: ?created_after=2024-01-01T00:00:00Z&limit=20
|   Tradeoff: Requires a unique, sequential column; no page jumping
```

### Response Envelope

```json
{
  "data": [...],
  "pagination": {
    "total": 1432,
    "limit": 20,
    "has_more": true,
    "next_cursor": "eyJpZCI6MTQzMn0="
  }
}
```

## Error Response Format (RFC 7807)

All APIs should use Problem Details (RFC 7807 / RFC 9457):

```json
{
  "type": "https://api.example.com/errors/insufficient-funds",
  "title": "Insufficient Funds",
  "status": 422,
  "detail": "Account xxxx-1234 has a balance of $10.00, but the transfer requires $25.00.",
  "instance": "/transfers/txn-abc-123",
  "balance": 1000,
  "required": 2500
}
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | URI identifying the error type (stable, documentable) |
| `title` | Yes | Human-readable summary (same for all instances of this type) |
| `status` | Yes | HTTP status code |
| `detail` | Yes | Human-readable explanation specific to this occurrence |
| `instance` | No | URI identifying the specific occurrence |
| (extensions) | No | Additional machine-readable fields |

### Validation Errors

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Failed",
  "status": 422,
  "detail": "The request body contains 2 validation errors.",
  "errors": [
    { "field": "email", "message": "Must be a valid email address", "code": "invalid_format" },
    { "field": "age", "message": "Must be at least 18", "code": "out_of_range", "min": 18 }
  ]
}
```

## Versioning Strategies

| Strategy | Example | Pros | Cons |
|----------|---------|------|------|
| URL path | `/v2/users` | Obvious, cacheable, easy routing | URL pollution, hard to sunset |
| Accept header | `Accept: application/vnd.api.v2+json` | Clean URLs, content negotiation | Hidden, harder to test |
| Query param | `/users?version=2` | Easy to add | Pollutes query string, caching issues |
| Date-based | `API-Version: 2024-01-15` | Granular evolution (Stripe style) | Complex implementation |

### Recommendation

- **Public APIs**: URL path versioning (`/v1/`) - simplicity wins
- **Internal APIs**: Header or no versioning (deploy in lockstep)
- **Evolving APIs**: Date-based (Stripe model) if you have the engineering investment

### Breaking Change Rules

A breaking change is anything that can cause existing clients to fail:
- Removing a field from a response
- Renaming a field
- Changing a field's type
- Adding a required field to a request
- Changing URL structure
- Changing error formats
- Removing an endpoint

Non-breaking (safe):
- Adding optional fields to requests
- Adding fields to responses
- Adding new endpoints
- Adding new enum values (if client handles unknown values)

## Rate Limiting Design

### Algorithms

| Algorithm | Behavior | Use When |
|-----------|----------|----------|
| Token bucket | Allows bursts, refills at steady rate | General API rate limiting |
| Sliding window | Smooth distribution, no burst | Strict fairness needed |
| Fixed window | Simple, potential burst at boundary | Low-stakes limiting |
| Leaky bucket | Constant output rate | Queue processing |

### Response Headers

```
X-RateLimit-Limit: 1000          # Max requests per window
X-RateLimit-Remaining: 743       # Requests left in current window
X-RateLimit-Reset: 1672531200    # Unix timestamp when window resets
Retry-After: 30                  # Seconds to wait (on 429)
```

### 429 Response Body

```json
{
  "type": "https://api.example.com/errors/rate-limit-exceeded",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "You have exceeded 1000 requests per hour. Try again in 30 seconds.",
  "retry_after": 30
}
```

## Idempotency

### Which Methods Need Idempotency Keys?

| Method | Idempotent by spec? | Needs key? |
|--------|---------------------|------------|
| GET | Yes | No |
| PUT | Yes | No (full replacement is naturally idempotent) |
| DELETE | Yes | No |
| PATCH | No | Recommended for critical operations |
| POST | No | **Yes** (always for payments, orders, transfers) |

### Implementation

```
POST /payments
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
Content-Type: application/json

{ "amount": 2500, "currency": "usd", "customer": "cust_123" }
```

Server-side:
1. Receive request with `Idempotency-Key` header
2. Check if key exists in store (Redis, DB)
3. If exists: return stored response (same status code + body)
4. If not: process request, store response keyed by idempotency key
5. Keys expire after 24-48 hours

## Authentication Overview

| Method | Use When | Security Level |
|--------|----------|----------------|
| API Key | Server-to-server, internal, simple | Low-Medium |
| JWT (Bearer) | Stateless auth, microservices | Medium-High |
| OAuth2 + PKCE | Third-party access, user delegation | High |
| mTLS | Service mesh, zero-trust infra | Very High |

### Decision Guide

```
Who is authenticating?
|
+-- Your own frontend? --> JWT (short-lived access + refresh token)
+-- Third-party developer? --> OAuth2 (client credentials for server, PKCE for SPA)
+-- Another internal service? --> mTLS or JWT with service accounts
+-- Quick prototype? --> API key (but plan migration)
```

## Gotchas Table

| Gotcha | Problem | Prevention |
|--------|---------|------------|
| Breaking changes in "non-breaking" release | Client crashes | Additive-only policy, contract tests |
| N+1 in REST APIs | 100 users = 101 queries | Compound documents, `?include=`, or GraphQL |
| Over-fetching | Mobile gets 50 fields, needs 3 | Sparse fieldsets `?fields=id,name` or GraphQL |
| Under-fetching | 3 requests to build one view | Composite endpoints or BFF pattern |
| CORS misconfiguration | Frontend can't reach API | Explicit allowed origins, never `*` with credentials |
| Missing Content-Type | 415 or silent parsing failure | Validate Content-Type on every mutation endpoint |
| Large payloads without pagination | OOM, timeouts | Always paginate collections, set max page size |
| Inconsistent date formats | Parsing hell | ISO 8601 everywhere: `2024-01-15T10:30:00Z` |
| No request IDs | Impossible to debug | Generate `X-Request-ID`, propagate through services |
| Enum evolution | New value breaks old client | Document that enums may grow, clients must handle unknown |
| Missing idempotency | Duplicate charges, orders | Idempotency keys on all POST endpoints with side effects |
| Unbounded query complexity | GraphQL DoS | Depth limiting, cost analysis, persisted queries |

## Reference Files

| File | Contents |
|------|----------|
| `references/rest-advanced.md` | Resource modeling, PATCH strategies, caching, webhooks, bulk ops |
| `references/grpc.md` | Protobuf, service definitions, Go/Rust, streaming, error handling |
| `references/graphql.md` | Schema design, resolvers, DataLoader, federation, performance |
| `references/api-security.md` | JWT, OAuth2, CORS, rate limiting, OWASP API Top 10 |
