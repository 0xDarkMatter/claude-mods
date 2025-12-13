# REST Patterns Skill

Quick reference for RESTful API design patterns, HTTP semantics, and status codes.

## Triggers

rest api, http methods, status codes, api design, endpoint design, rest patterns, api versioning

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
| **204 No Content** | Success with no response body |

### Client Errors (4xx)

| Code | When to Use |
|------|-------------|
| **400 Bad Request** | Invalid syntax, malformed JSON |
| **401 Unauthorized** | Missing or invalid auth |
| **403 Forbidden** | Authenticated but not authorized |
| **404 Not Found** | Resource doesn't exist |
| **405 Method Not Allowed** | HTTP method not supported |
| **409 Conflict** | State conflict (duplicate, version mismatch) |
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
```

## Error Response Format

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input data",
    "details": [
      {"field": "email", "message": "Invalid email format"}
    ],
    "request_id": "abc-123"
  }
}
```

## Versioning Strategies

| Strategy | Example | Pros/Cons |
|----------|---------|-----------|
| **URI** | `/v1/users` | Clear, easy to implement, URL pollution |
| **Header** | `Accept: application/vnd.api.v1+json` | Clean URLs, harder to test |
| **Query** | `/users?version=1` | Easy to implement, less RESTful |

## Security Checklist

- Always HTTPS/TLS
- OAuth 2.0 or JWT for auth
- API keys for service-to-service
- Validate all inputs
- Rate limit per client
- CORS headers configured
- No sensitive data in URLs
- Security headers (HSTS, CSP)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using verbs in URLs | `/getUsers` → `/users` |
| Deep nesting | `/a/1/b/2/c/3/d` → flatten or use query params |
| 200 for errors | Return appropriate 4xx/5xx |
| POST for everything | Use proper HTTP methods |
| Returning 500 for client errors | 4xx for client, 5xx for server |
| No pagination on lists | Always paginate collections |
