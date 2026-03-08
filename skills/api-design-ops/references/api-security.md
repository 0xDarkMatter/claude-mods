# API Security Patterns

## Table of Contents

- [API Key Management](#api-key-management)
- [JWT (JSON Web Tokens)](#jwt-json-web-tokens)
- [OAuth2 Flows](#oauth2-flows)
- [CORS](#cors)
- [Rate Limiting Implementation](#rate-limiting-implementation)
- [Input Validation](#input-validation)
- [API Versioning and Deprecation](#api-versioning-and-deprecation)
- [Transport Security](#transport-security)
- [OWASP API Security Top 10](#owasp-api-security-top-10)

---

## API Key Management

### Generation

```go
import "crypto/rand"

func generateAPIKey() (string, error) {
    // 32 bytes = 256 bits of entropy
    b := make([]byte, 32)
    if _, err := rand.Read(b); err != nil {
        return "", err
    }
    // Prefix for easy identification and revocation
    return "sk_live_" + base64.URLEncoding.EncodeToString(b), nil
}
```

### Storage

```
NEVER store API keys in plaintext.

Store: hash(api_key) in database
Lookup: hash(incoming_key), compare to stored hashes
Display: show only last 4 chars to user ("sk_live_...a1b2")
```

```go
import "crypto/sha256"

func hashAPIKey(key string) string {
    h := sha256.Sum256([]byte(key))
    return hex.EncodeToString(h[:])
}
```

### Scoping

```json
{
  "key_id": "key_abc123",
  "name": "Production Read-Only",
  "permissions": ["read:users", "read:orders"],
  "rate_limit": 1000,
  "allowed_ips": ["203.0.113.0/24"],
  "expires_at": "2025-01-15T00:00:00Z",
  "created_at": "2024-01-15T00:00:00Z"
}
```

### Rotation Strategy

1. Generate new key
2. Both old and new keys work (grace period: 24-72 hours)
3. Client updates to new key
4. Old key is revoked
5. Log all key usage for audit

## JWT (JSON Web Tokens)

### Structure

```
header.payload.signature

# Header
{
  "alg": "RS256",          # Algorithm (RS256, ES256 - avoid HS256 for APIs)
  "typ": "JWT",
  "kid": "key-2024-01"    # Key ID for rotation
}

# Payload (Claims)
{
  "iss": "https://auth.example.com",     # Issuer
  "sub": "user-123",                      # Subject (user ID)
  "aud": "https://api.example.com",       # Audience
  "exp": 1705312200,                      # Expires (15 min from now)
  "iat": 1705311300,                      # Issued at
  "jti": "unique-token-id",               # JWT ID (for revocation)
  "scope": "read:users write:orders",     # Permissions
  "org_id": "org-456"                     # Custom claim
}
```

### Signing and Verification (Go)

```go
import "github.com/golang-jwt/jwt/v5"

// Sign (auth service)
func createAccessToken(userID string, scopes []string) (string, error) {
    claims := jwt.MapClaims{
        "sub":   userID,
        "scope": strings.Join(scopes, " "),
        "exp":   time.Now().Add(15 * time.Minute).Unix(),
        "iat":   time.Now().Unix(),
        "iss":   "https://auth.example.com",
    }

    token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
    token.Header["kid"] = currentKeyID

    return token.SignedString(privateKey)
}

// Verify (API service)
func verifyToken(tokenString string) (*jwt.Token, error) {
    return jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
        // Validate algorithm
        if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
            return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
        }

        // Look up public key by kid
        kid, _ := token.Header["kid"].(string)
        pubKey, err := getPublicKey(kid)
        if err != nil {
            return nil, fmt.Errorf("unknown key ID: %s", kid)
        }

        return pubKey, nil
    },
        jwt.WithValidMethods([]string{"RS256"}),
        jwt.WithIssuer("https://auth.example.com"),
        jwt.WithAudience("https://api.example.com"),
    )
}
```

### Refresh Token Flow

```
1. Login: POST /auth/login
   Response: { access_token (15 min), refresh_token (7 days) }

2. API calls: Authorization: Bearer <access_token>

3. Token expired (401): POST /auth/refresh
   Body: { refresh_token }
   Response: { access_token (new, 15 min), refresh_token (rotated) }

4. Refresh token expired/revoked: redirect to login
```

### Token Storage

| Environment | Access Token | Refresh Token |
|-------------|-------------|---------------|
| Browser SPA | Memory (JS variable) | HttpOnly Secure cookie |
| Mobile app | Secure storage (Keychain/Keystore) | Secure storage |
| Server-to-server | Environment variable | Environment variable |

**Never store tokens in:**
- localStorage (XSS vulnerable)
- sessionStorage (XSS vulnerable)
- Non-HttpOnly cookies (XSS vulnerable)
- URL parameters (logged, cached, leaked via Referer)

## OAuth2 Flows

### Authorization Code + PKCE (SPAs, Mobile)

```
1. Client generates: code_verifier (random 43-128 chars)
   code_challenge = BASE64URL(SHA256(code_verifier))

2. Redirect to authorization server:
   GET /authorize?
     response_type=code&
     client_id=app-123&
     redirect_uri=https://app.example.com/callback&
     scope=read:profile write:orders&
     state=random-csrf-token&
     code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&
     code_challenge_method=S256

3. User authenticates, consents

4. Redirect back with code:
   GET /callback?code=auth-code-xyz&state=random-csrf-token

5. Exchange code for tokens:
   POST /token
   {
     "grant_type": "authorization_code",
     "code": "auth-code-xyz",
     "redirect_uri": "https://app.example.com/callback",
     "client_id": "app-123",
     "code_verifier": "the-original-random-string"
   }

6. Response:
   {
     "access_token": "eyJ...",
     "token_type": "Bearer",
     "expires_in": 900,
     "refresh_token": "rt_...",
     "scope": "read:profile write:orders"
   }
```

### Client Credentials (Server-to-Server)

```
POST /token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&
client_id=service-abc&
client_secret=secret-xyz&
scope=read:users

Response:
{
  "access_token": "eyJ...",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

### Device Flow (CLI Tools, Smart TVs)

```
1. Device requests code:
   POST /device/code
   { "client_id": "cli-app", "scope": "read:profile" }

   Response:
   {
     "device_code": "device-code-abc",
     "user_code": "ABCD-1234",
     "verification_uri": "https://auth.example.com/device",
     "expires_in": 600,
     "interval": 5
   }

2. Display to user: "Go to https://auth.example.com/device and enter ABCD-1234"

3. Device polls (every 5 seconds):
   POST /token
   { "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
     "device_code": "device-code-abc", "client_id": "cli-app" }

   While pending: { "error": "authorization_pending" }
   When approved: { "access_token": "eyJ...", ... }
```

### Flow Selection Guide

| Scenario | Flow |
|----------|------|
| SPA (browser) | Authorization Code + PKCE |
| Mobile app | Authorization Code + PKCE |
| Server-to-server | Client Credentials |
| CLI tool | Device Flow |
| Legacy (avoid) | Implicit (deprecated), ROPC (deprecated) |

## CORS

### Configuration

```go
func corsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        origin := r.Header.Get("Origin")

        // Whitelist specific origins (NEVER use * with credentials)
        allowedOrigins := map[string]bool{
            "https://app.example.com":     true,
            "https://staging.example.com": true,
        }

        if allowedOrigins[origin] {
            w.Header().Set("Access-Control-Allow-Origin", origin)
            w.Header().Set("Access-Control-Allow-Credentials", "true")
            w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
            w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Request-ID, Idempotency-Key")
            w.Header().Set("Access-Control-Expose-Headers", "X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset")
            w.Header().Set("Access-Control-Max-Age", "86400")  // Cache preflight for 24h
        }

        // Handle preflight
        if r.Method == "OPTIONS" {
            w.WriteHeader(http.StatusNoContent)
            return
        }

        next.ServeHTTP(w, r)
    })
}
```

### Common CORS Mistakes

| Mistake | Risk | Fix |
|---------|------|-----|
| `Access-Control-Allow-Origin: *` with credentials | Credential theft | Whitelist specific origins |
| Reflecting `Origin` header without validation | Any origin allowed | Check against whitelist |
| Missing `Vary: Origin` | Cache poisoning | Add `Vary: Origin` header |
| Not handling preflight (OPTIONS) | Mutations blocked | Return 204 for OPTIONS |
| Allowing all headers | Header injection | Whitelist specific headers |

## Rate Limiting Implementation

### Token Bucket (Go + Redis)

```go
import "github.com/redis/go-redis/v9"

type RateLimiter struct {
    redis    *redis.Client
    limit    int           // Max tokens
    window   time.Duration // Refill window
}

func (rl *RateLimiter) Allow(ctx context.Context, key string) (bool, RateLimitInfo, error) {
    now := time.Now().Unix()
    windowKey := fmt.Sprintf("ratelimit:%s:%d", key, now/int64(rl.window.Seconds()))

    pipe := rl.redis.Pipeline()
    incr := pipe.Incr(ctx, windowKey)
    pipe.Expire(ctx, windowKey, rl.window)
    _, err := pipe.Exec(ctx)
    if err != nil {
        return false, RateLimitInfo{}, err
    }

    count := incr.Val()
    remaining := rl.limit - int(count)
    if remaining < 0 {
        remaining = 0
    }

    info := RateLimitInfo{
        Limit:     rl.limit,
        Remaining: remaining,
        Reset:     time.Unix(((now/int64(rl.window.Seconds()))+1)*int64(rl.window.Seconds()), 0),
    }

    return count <= int64(rl.limit), info, nil
}

type RateLimitInfo struct {
    Limit     int
    Remaining int
    Reset     time.Time
}
```

### Middleware

```go
func rateLimitMiddleware(limiter *RateLimiter) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // Key by API key, user ID, or IP
            key := extractRateLimitKey(r)

            allowed, info, err := limiter.Allow(r.Context(), key)
            if err != nil {
                http.Error(w, "Internal Server Error", 500)
                return
            }

            // Always set rate limit headers
            w.Header().Set("X-RateLimit-Limit", strconv.Itoa(info.Limit))
            w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(info.Remaining))
            w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(info.Reset.Unix(), 10))

            if !allowed {
                retryAfter := int(time.Until(info.Reset).Seconds())
                w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
                w.WriteHeader(http.StatusTooManyRequests)
                json.NewEncoder(w).Encode(map[string]interface{}{
                    "type":        "https://api.example.com/errors/rate-limit",
                    "title":       "Rate Limit Exceeded",
                    "status":      429,
                    "detail":      fmt.Sprintf("Rate limit of %d requests per hour exceeded", info.Limit),
                    "retry_after": retryAfter,
                })
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

### Tiered Rate Limits

| Tier | Requests/Hour | Burst | Use Case |
|------|---------------|-------|----------|
| Free | 100 | 10/min | Trial users |
| Basic | 1,000 | 100/min | Paid individuals |
| Pro | 10,000 | 500/min | Teams |
| Enterprise | 100,000 | 2,000/min | Custom SLA |

## Input Validation

### Validate at the Boundary

```go
// Use a validation library, not manual checks
import "github.com/go-playground/validator/v10"

type CreateUserRequest struct {
    Name     string `json:"name" validate:"required,min=2,max=100"`
    Email    string `json:"email" validate:"required,email"`
    Age      int    `json:"age" validate:"omitempty,min=13,max=150"`
    Website  string `json:"website" validate:"omitempty,url"`
    Role     string `json:"role" validate:"required,oneof=admin member viewer"`
    Password string `json:"password" validate:"required,min=8,max=128"`
}

var validate = validator.New()

func handleCreateUser(w http.ResponseWriter, r *http.Request) {
    var req CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        respondError(w, 400, "Invalid JSON body")
        return
    }

    if err := validate.Struct(req); err != nil {
        validationErrors := err.(validator.ValidationErrors)
        respondValidationErrors(w, validationErrors)
        return
    }

    // Input is now validated - proceed
}
```

### Validation Checklist

| Check | Why |
|-------|-----|
| Max request body size | Prevent memory exhaustion |
| String length limits | Prevent storage abuse |
| Enum validation | Reject unknown values |
| URL validation | Prevent SSRF (whitelist schemes) |
| Email format | Reject obviously invalid |
| Numeric bounds | Prevent overflow, nonsensical values |
| Array max length | Prevent excessive processing |
| Nested object depth | Prevent deep recursion |
| Content-Type validation | Ensure expected format |
| UTF-8 validation | Prevent encoding attacks |

### Schema Validation (OpenAPI)

```go
import "github.com/getkin/kin-openapi/openapi3filter"

// Validate requests against OpenAPI spec automatically
router, _ := gorillamux.NewRouter(spec)

func validationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        route, pathParams, _ := router.FindRoute(r)

        input := &openapi3filter.RequestValidationInput{
            Request:    r,
            PathParams: pathParams,
            Route:      route,
        }

        if err := openapi3filter.ValidateRequest(r.Context(), input); err != nil {
            respondError(w, 400, err.Error())
            return
        }

        next.ServeHTTP(w, r)
    })
}
```

## API Versioning and Deprecation

### Deprecation Timeline

```
1. Announce deprecation (minimum 6 months before removal)
   - Add Deprecation header to responses
   - Update API documentation
   - Email API key owners

2. Warning period (3-6 months)
   Deprecation: true
   Sunset: Sat, 15 Jun 2025 00:00:00 GMT
   Link: <https://docs.example.com/migration-guide>; rel="deprecation"

3. Migration support
   - Provide migration guide
   - Offer parallel running of old and new versions
   - Log deprecated endpoint usage for targeted outreach

4. Removal
   - Return 410 Gone with migration info
   - Keep 410 response for 6+ months
```

### Sunset Header (RFC 8594)

```
HTTP/1.1 200 OK
Sunset: Sat, 15 Jun 2025 00:00:00 GMT
Deprecation: true
Link: <https://api.example.com/v3/users>; rel="successor-version"
```

## Transport Security

### TLS Configuration

```go
tlsConfig := &tls.Config{
    MinVersion: tls.VersionTLS12,
    CipherSuites: []uint16{
        tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    },
    PreferServerCipherSuites: true,
}

server := &http.Server{
    TLSConfig: tlsConfig,
    // ...
}
```

### Security Headers

```go
func securityHeaders(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        w.Header().Set("X-Content-Type-Options", "nosniff")
        w.Header().Set("X-Frame-Options", "DENY")
        w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        w.Header().Set("Cache-Control", "no-store")   // For API responses with sensitive data
        w.Header().Set("X-Request-ID", generateRequestID())
        next.ServeHTTP(w, r)
    })
}
```

## OWASP API Security Top 10

### 2023 Edition

| # | Risk | Description | Prevention |
|---|------|-------------|------------|
| 1 | **Broken Object-Level Auth (BOLA)** | User accesses other users' objects via ID manipulation | Check ownership in every endpoint: `WHERE id = ? AND user_id = ?` |
| 2 | **Broken Authentication** | Weak auth, credential stuffing, missing rate limits on login | Rate limit login, use strong password hashing (argon2id), MFA |
| 3 | **Broken Object Property-Level Auth** | Mass assignment, excessive data exposure | Explicit allowlists for input fields, separate input/output DTOs |
| 4 | **Unrestricted Resource Consumption** | No rate limits, unbounded queries, large payloads | Rate limiting, pagination limits, request size limits, timeouts |
| 5 | **Broken Function-Level Auth** | Admin endpoints accessible to regular users | Role-based access control, deny by default, test auth on every endpoint |
| 6 | **Unrestricted Access to Sensitive Business Flows** | Automated abuse (ticket scalping, spam) | Rate limiting, CAPTCHA, device fingerprinting, business logic limits |
| 7 | **Server-Side Request Forgery (SSRF)** | API fetches attacker-controlled URLs | Validate/whitelist URLs, block internal networks, use allowlists |
| 8 | **Security Misconfiguration** | Default configs, verbose errors, missing CORS | Harden defaults, strip stack traces in production, audit configs |
| 9 | **Improper Inventory Management** | Shadow APIs, deprecated endpoints still active | API gateway, version inventory, automated discovery, sunset old versions |
| 10 | **Unsafe Consumption of APIs** | Trusting third-party API responses without validation | Validate all external API responses, set timeouts, use TLS |

### BOLA Prevention (Most Common API Vulnerability)

```go
// BAD: Only checks if resource exists
func getOrder(w http.ResponseWriter, r *http.Request) {
    orderID := chi.URLParam(r, "id")
    order, _ := db.GetOrder(orderID)  // Anyone can access any order!
    json.NewEncoder(w).Encode(order)
}

// GOOD: Checks ownership
func getOrder(w http.ResponseWriter, r *http.Request) {
    orderID := chi.URLParam(r, "id")
    userID := r.Context().Value(userIDKey).(string)

    order, err := db.GetOrderForUser(orderID, userID)
    // SQL: SELECT * FROM orders WHERE id = $1 AND user_id = $2
    if err != nil {
        respondError(w, 404, "Order not found")  // 404, not 403 (don't leak existence)
        return
    }
    json.NewEncoder(w).Encode(order)
}
```

### Mass Assignment Prevention

```go
// BAD: Binding all fields from request
func updateUser(w http.ResponseWriter, r *http.Request) {
    var user User
    json.NewDecoder(r.Body).Decode(&user)  // Attacker sets role=admin!
    db.Save(&user)
}

// GOOD: Explicit allowlist of updatable fields
type UpdateUserInput struct {
    Name   *string `json:"name"`
    Email  *string `json:"email"`
    // role is NOT here - cannot be set via API
}

func updateUser(w http.ResponseWriter, r *http.Request) {
    var input UpdateUserInput
    json.NewDecoder(r.Body).Decode(&input)

    user, _ := db.GetUser(userID)
    if input.Name != nil {
        user.Name = *input.Name
    }
    if input.Email != nil {
        user.Email = *input.Email
    }
    db.Save(&user)
}
```
