---
name: rest-patterns
description: "Quick reference for RESTful API design patterns, HTTP semantics, caching, and rate limiting. Triggers on: rest api, http methods, status codes, api design, endpoint design, api versioning, rate limiting, caching."
allowed-tools: "Read Write"
---

# REST Patterns

Quick reference for RESTful API design patterns, HTTP semantics, caching, and rate limiting.

## HTTP Methods

| Method | Purpose | Idempotent | Cacheable |
|--------|---------|------------|-----------|
| **GET** | Retrieve resource(s) | Yes | Yes |
| **POST** | Create new resource | No | No |
| **PUT** | Replace entire resource | Yes | No |
| **PATCH** | Partial update | Maybe | No |
| **DELETE** | Remove resource | Yes | No |
| **HEAD** | GET headers only | Yes | Yes |
| **OPTIONS** | CORS preflight | Yes | No |

## Status Codes Quick Reference

### Success (2xx)

| Code | When to Use |
|------|-------------|
| **200 OK** | GET, PUT, PATCH, DELETE success |
| **201 Created** | POST success (include `Location` header) |
| **202 Accepted** | Request queued for async processing |
| **204 No Content** | Success with no response body |
| **206 Partial Content** | Range request fulfilled |

### Redirection (3xx)

| Code | When to Use |
|------|-------------|
| **301 Moved Permanently** | Resource permanently relocated |
| **302 Found** | Temporary redirect (avoid in APIs) |
| **304 Not Modified** | Client cache is valid (ETag match) |
| **307 Temporary Redirect** | Redirect preserving method |
| **308 Permanent Redirect** | Like 301, preserves method |

### Client Errors (4xx)

| Code | When to Use |
|------|-------------|
| **400 Bad Request** | Invalid syntax, malformed JSON |
| **401 Unauthorized** | Missing or invalid auth |
| **403 Forbidden** | Authenticated but not authorized |
| **404 Not Found** | Resource doesn't exist |
| **405 Method Not Allowed** | HTTP method not supported |
| **409 Conflict** | State conflict (duplicate, version mismatch) |
| **410 Gone** | Resource permanently removed |
| **412 Precondition Failed** | If-Match header condition failed |
| **422 Unprocessable Entity** | Validation errors (valid syntax, bad semantics) |
| **429 Too Many Requests** | Rate limit exceeded |

### Server Errors (5xx)

| Code | When to Use |
|------|-------------|
| **500 Internal Server Error** | Generic server failure |
| **502 Bad Gateway** | Upstream returned invalid response |
| **503 Service Unavailable** | Temporarily unavailable |
| **504 Gateway Timeout** | Upstream timeout |

## Resource Design Patterns

```
# Collections (plural nouns)
GET    /users              # List all
POST   /users              # Create one
GET    /users/{id}         # Get one
PUT    /users/{id}         # Replace one
PATCH  /users/{id}         # Update one
DELETE /users/{id}         # Delete one

# Nested resources (max 2-3 levels)
GET    /users/{id}/orders           # User's orders
GET    /users/{id}/orders/{orderId} # Specific order

# Query parameters
GET /users?role=admin&status=active     # Filtering
GET /users?page=2&limit=20              # Pagination
GET /users?sort=created_at&order=desc   # Sorting
GET /users?fields=id,name,email         # Sparse fieldsets
```

## Caching Headers

### Response Headers

```http
# Time-based caching
Cache-Control: max-age=3600              # Cache for 1 hour
Cache-Control: max-age=0, must-revalidate # Always revalidate
Cache-Control: no-store                  # Never cache (sensitive data)
Cache-Control: private, max-age=600      # Browser only, not CDN

# Validation
ETag: "abc123"                           # Content fingerprint
Last-Modified: Wed, 21 Oct 2024 07:28:00 GMT
```

### Request Headers

```http
# Conditional requests
If-None-Match: "abc123"                  # Validate ETag
If-Modified-Since: Wed, 21 Oct 2024 07:28:00 GMT

# Bypass cache
Cache-Control: no-cache                  # Force revalidation
```

### Caching Strategy by Resource Type

| Resource | Strategy | Headers |
|----------|----------|---------|
| Static assets | Long-lived | `max-age=31536000, immutable` |
| API responses | Short/revalidate | `max-age=60, must-revalidate` |
| User data | Private | `private, max-age=0` |
| Sensitive data | Never | `no-store` |
| Public lists | Shared | `public, max-age=300` |

### ETag Workflow

```
# First request
GET /users/123
→ 200 OK
→ ETag: "v1-abc123"

# Subsequent request
GET /users/123
If-None-Match: "v1-abc123"
→ 304 Not Modified (no body, use cached)

# Or if changed
→ 200 OK
→ ETag: "v2-def456"
```

## Rate Limiting

### Standard Headers

```http
# Response headers
X-RateLimit-Limit: 1000          # Max requests per window
X-RateLimit-Remaining: 847       # Requests left
X-RateLimit-Reset: 1698415200    # Unix timestamp when limit resets
Retry-After: 60                  # Seconds to wait (on 429)
```

### Rate Limit Response (429)

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many requests",
    "retry_after": 60
  }
}
```

### Rate Limiting Strategies

| Strategy | Use Case | Example |
|----------|----------|---------|
| **Fixed window** | Simple limits | 100 req/minute |
| **Sliding window** | Smoother limits | 100 req in rolling 60s |
| **Token bucket** | Burst allowance | 10 req/s, 100 burst |
| **Per-endpoint** | Expensive operations | /search: 10/min |
| **Per-user tier** | Freemium APIs | Free: 100/hr, Pro: 10000/hr |

## Error Response Format

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input data",
    "details": [
      {"field": "email", "message": "Invalid email format"},
      {"field": "age", "message": "Must be 18 or older"}
    ],
    "request_id": "abc-123",
    "documentation_url": "https://api.example.com/docs/errors#validation"
  }
}
```

## Versioning Strategies

| Strategy | Example | Pros/Cons |
|----------|---------|-----------|
| **URI** | `/v1/users` | Clear, easy to implement, URL pollution |
| **Header** | `Accept: application/vnd.api.v1+json` | Clean URLs, harder to test |
| **Query** | `/users?version=1` | Easy to implement, less RESTful |

## Bulk Operations

### Batch Endpoint

```http
POST /batch
Content-Type: application/json

{
  "operations": [
    {"method": "POST", "path": "/users", "body": {"name": "Alice"}},
    {"method": "PATCH", "path": "/users/123", "body": {"status": "active"}},
    {"method": "DELETE", "path": "/users/456"}
  ]
}

Response:
{
  "results": [
    {"status": 201, "body": {"id": 789, "name": "Alice"}},
    {"status": 200, "body": {"id": 123, "status": "active"}},
    {"status": 204, "body": null}
  ]
}
```

### Bulk Create/Update

```http
POST /users/bulk
Content-Type: application/json

[
  {"name": "Alice", "email": "alice@example.com"},
  {"name": "Bob", "email": "bob@example.com"}
]

Response:
{
  "created": 2,
  "errors": []
}
```

## HATEOAS Links

```json
{
  "id": 123,
  "name": "Alice",
  "email": "alice@example.com",
  "_links": {
    "self": {"href": "/users/123"},
    "orders": {"href": "/users/123/orders"},
    "profile": {"href": "/users/123/profile"},
    "update": {"href": "/users/123", "method": "PATCH"},
    "delete": {"href": "/users/123", "method": "DELETE"}
  }
}
```

### Collection with Pagination Links

```json
{
  "data": [...],
  "meta": {
    "total": 150,
    "page": 2,
    "per_page": 20
  },
  "_links": {
    "self": {"href": "/users?page=2"},
    "first": {"href": "/users?page=1"},
    "prev": {"href": "/users?page=1"},
    "next": {"href": "/users?page=3"},
    "last": {"href": "/users?page=8"}
  }
}
```

## Security Checklist

- Always HTTPS/TLS
- OAuth 2.0 or JWT for auth
- API keys for service-to-service
- Validate all inputs
- Rate limit per client
- CORS headers configured
- No sensitive data in URLs
- Security headers (HSTS, CSP)
- Use `no-store` for sensitive responses

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using verbs in URLs | `/getUsers` → `/users` |
| Deep nesting | `/a/1/b/2/c/3/d` → flatten or use query params |
| 200 for errors | Return appropriate 4xx/5xx |
| POST for everything | Use proper HTTP methods |
| Returning 500 for client errors | 4xx for client, 5xx for server |
| No pagination on lists | Always paginate collections |
| Ignoring caching | Add ETag, Cache-Control headers |
| Missing rate limits | Protect against abuse |
| No versioning strategy | Plan for breaking changes |
