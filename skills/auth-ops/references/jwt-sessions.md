# JWT and Session Management

Deep-dive reference for JSON Web Tokens, session-based authentication, cookie security, and CSRF protection.

## JWT Structure

A JWT consists of three Base64URL-encoded parts separated by dots.

### Header

```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "key-2024-01"
}
```

| Field | Purpose |
|-------|---------|
| `alg` | Signing algorithm (RS256, ES256, HS256) |
| `typ` | Token type (always "JWT") |
| `kid` | Key ID for key rotation (optional but recommended) |

### Payload (Claims)

#### Registered Claims (RFC 7519)

```json
{
  "iss": "https://auth.example.com",
  "sub": "user_abc123",
  "aud": "https://api.example.com",
  "exp": 1700001500,
  "nbf": 1700000600,
  "iat": 1700000600,
  "jti": "unique-token-id-xyz"
}
```

| Claim | Required | Purpose |
|-------|----------|---------|
| `iss` | Recommended | Identifies the token issuer |
| `sub` | Recommended | Identifies the subject (user ID) |
| `aud` | Recommended | Intended recipient(s) of the token |
| `exp` | Required | Expiration time (Unix timestamp) |
| `nbf` | Optional | Token not valid before this time |
| `iat` | Recommended | Time the token was issued |
| `jti` | Optional | Unique identifier for the token (for revocation) |

#### Custom Claims

```json
{
  "role": "admin",
  "permissions": ["read", "write", "delete"],
  "org_id": "org_456",
  "tenant": "acme-corp"
}
```

**Guidelines for custom claims:**
- Namespace custom claims to avoid collisions: `https://example.com/role`
- Keep payload small (< 1KB) -- JWTs are sent with every request
- Never put sensitive data in claims (tokens are encoded, not encrypted)
- Include only what the resource server needs for authorization decisions

### Signature

```
RSASHA256(
  base64UrlEncode(header) + "." + base64UrlEncode(payload),
  privateKey
)
```

The signature ensures the token has not been tampered with. Verification uses the public key (asymmetric) or shared secret (symmetric).

## Signing Algorithms

### RS256 (RSA + SHA-256)

**Type:** Asymmetric (public/private key pair)
**Key size:** 2048 bits minimum (4096 recommended)
**Use when:** Multiple services verify tokens, auth server is separate from resource servers.

```javascript
// Node.js (jose library)
import { SignJWT, jwtVerify, importPKCS8, importSPKI } from 'jose';

// Sign (auth server - has private key)
const privateKey = await importPKCS8(privateKeyPem, 'RS256');
const token = await new SignJWT({ sub: 'user_123', role: 'admin' })
  .setProtectedHeader({ alg: 'RS256', kid: 'key-2024-01' })
  .setIssuedAt()
  .setIssuer('https://auth.example.com')
  .setAudience('https://api.example.com')
  .setExpirationTime('15m')
  .sign(privateKey);

// Verify (resource server - has public key only)
const publicKey = await importSPKI(publicKeyPem, 'RS256');
const { payload } = await jwtVerify(token, publicKey, {
  issuer: 'https://auth.example.com',
  audience: 'https://api.example.com',
});
```

```python
# Python (PyJWT)
import jwt
from datetime import datetime, timedelta, timezone

# Sign
token = jwt.encode(
    {
        "sub": "user_123",
        "role": "admin",
        "iss": "https://auth.example.com",
        "aud": "https://api.example.com",
        "exp": datetime.now(timezone.utc) + timedelta(minutes=15),
        "iat": datetime.now(timezone.utc),
    },
    private_key,
    algorithm="RS256",
    headers={"kid": "key-2024-01"},
)

# Verify
payload = jwt.decode(
    token,
    public_key,
    algorithms=["RS256"],
    issuer="https://auth.example.com",
    audience="https://api.example.com",
)
```

```go
// Go (golang-jwt/jwt/v5)
import (
    "time"
    "github.com/golang-jwt/jwt/v5"
)

// Sign
claims := jwt.MapClaims{
    "sub":  "user_123",
    "role": "admin",
    "iss":  "https://auth.example.com",
    "aud":  "https://api.example.com",
    "exp":  time.Now().Add(15 * time.Minute).Unix(),
    "iat":  time.Now().Unix(),
}
token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
token.Header["kid"] = "key-2024-01"
signedToken, err := token.SignedString(privateKey)

// Verify
parsedToken, err := jwt.Parse(signedToken, func(t *jwt.Token) (interface{}, error) {
    if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
        return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
    }
    return publicKey, nil
}, jwt.WithIssuer("https://auth.example.com"),
   jwt.WithAudience("https://api.example.com"))
```

### ES256 (ECDSA + SHA-256)

**Type:** Asymmetric (public/private key pair)
**Curve:** P-256
**Use when:** Same as RS256 but smaller tokens and faster signing. Preferred for new systems.

```javascript
// Node.js (jose)
import { SignJWT, jwtVerify, importPKCS8, importSPKI } from 'jose';

const privateKey = await importPKCS8(ecPrivateKeyPem, 'ES256');
const token = await new SignJWT({ sub: 'user_123' })
  .setProtectedHeader({ alg: 'ES256' })
  .setExpirationTime('15m')
  .sign(privateKey);
```

**ES256 vs RS256:**
- ES256 signatures: 64 bytes vs RS256: 256 bytes
- ES256 key generation: faster
- ES256 signing: faster
- ES256 verification: slightly slower
- Both are equally secure for JWT purposes

### HS256 (HMAC + SHA-256)

**Type:** Symmetric (shared secret)
**Use when:** Single service creates and verifies tokens. Simple internal use.

```javascript
// Node.js (jose)
import { SignJWT, jwtVerify } from 'jose';

const secret = new TextEncoder().encode(process.env.JWT_SECRET);
// Secret must be at least 256 bits (32 bytes) for HS256

const token = await new SignJWT({ sub: 'user_123' })
  .setProtectedHeader({ alg: 'HS256' })
  .setExpirationTime('15m')
  .sign(secret);

const { payload } = await jwtVerify(token, secret);
```

**Warning:** With HS256, anyone who can verify tokens can also create them. Never use HS256 when the verifier should not be able to issue tokens.

### Algorithm Selection Matrix

| Factor | HS256 | RS256 | ES256 |
|--------|-------|-------|-------|
| Key type | Shared secret | RSA key pair | EC key pair |
| Token size | Smallest | Largest | Medium |
| Sign speed | Fast | Slow | Fast |
| Verify speed | Fast | Fast | Medium |
| Key distribution | Secret must be shared | Only public key shared | Only public key shared |
| Best for | Single service | Distributed, legacy | Distributed, modern |

## Access + Refresh Token Pattern

### Flow

1. User authenticates (login with credentials, OAuth2, etc.)
2. Auth server issues access token (short-lived) and refresh token (long-lived)
3. Client uses access token for API requests via `Authorization: Bearer <token>`
4. When access token expires, client sends refresh token to get new tokens
5. Auth server validates refresh token, issues new access + refresh tokens
6. Old refresh token is invalidated (rotation)

### Token Lifetimes

| Token | Lifetime | Storage |
|-------|----------|---------|
| Access token | 5-15 minutes | Memory (SPA), httpOnly cookie (BFF) |
| Refresh token | 7-30 days | httpOnly cookie, secure storage (mobile) |

### Refresh Token Rotation

```javascript
// Auth server: refresh endpoint
app.post('/auth/refresh', async (req, res) => {
  const { refreshToken } = req.cookies;

  // 1. Look up the refresh token
  const storedToken = await db.refreshTokens.findOne({
    token: hash(refreshToken),
  });

  if (!storedToken) {
    // Token not found - might be reuse of revoked token
    // Revoke entire token family as precaution
    await db.refreshTokens.deleteMany({ family: storedToken?.family });
    return res.status(401).json({ error: 'Invalid refresh token' });
  }

  if (storedToken.revoked) {
    // Reuse detected! Revoke entire family
    await db.refreshTokens.deleteMany({ family: storedToken.family });
    return res.status(401).json({ error: 'Token reuse detected' });
  }

  if (storedToken.expiresAt < new Date()) {
    return res.status(401).json({ error: 'Refresh token expired' });
  }

  // 2. Revoke the old refresh token
  await db.refreshTokens.updateOne(
    { token: hash(refreshToken) },
    { revoked: true }
  );

  // 3. Issue new tokens
  const newAccessToken = await createAccessToken(storedToken.userId);
  const newRefreshToken = crypto.randomBytes(32).toString('hex');

  // 4. Store new refresh token in same family
  await db.refreshTokens.insertOne({
    token: hash(newRefreshToken),
    userId: storedToken.userId,
    family: storedToken.family,  // Same family for reuse detection
    expiresAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
    revoked: false,
  });

  // 5. Return new tokens
  res.cookie('refreshToken', newRefreshToken, {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    maxAge: 7 * 24 * 60 * 60 * 1000,
    path: '/auth/refresh',  // Only sent to refresh endpoint
  });

  res.json({ accessToken: newAccessToken });
});
```

### Token Family Detection

Token families track lineage of refresh tokens. If a revoked refresh token is reused (indicating theft), all tokens in the family are invalidated.

```
Login → RT1 (family: F1)
    RT1 → RT2 (family: F1, RT1 revoked)
        RT2 → RT3 (family: F1, RT2 revoked)

If attacker uses stolen RT1:
    RT1 is revoked → ALERT → revoke all in family F1
    User must re-authenticate
```

## Token Revocation Strategies

### Strategy 1: Short Expiry + No Revocation

- Access tokens expire in 5-15 minutes
- No revocation mechanism needed
- Revoke refresh token to prevent renewal
- **Trade-off:** Cannot immediately invalidate access tokens

### Strategy 2: Blocklist (Redis)

```javascript
// Add to blocklist on logout/revocation
await redis.set(`blocklist:${jti}`, '1', 'EX', tokenRemainingTTL);

// Check on every request
const isRevoked = await redis.get(`blocklist:${jti}`);
if (isRevoked) return res.status(401).json({ error: 'Token revoked' });
```

- Entries auto-expire when the token would have expired
- **Trade-off:** Requires Redis, adds latency to every request

### Strategy 3: Version-Based Revocation

```javascript
// User record has a tokenVersion
// JWT includes tokenVersion claim
// On password change/logout-all: increment tokenVersion
// On verification: compare JWT version with stored version

const user = await db.users.findOne({ id: payload.sub });
if (payload.tokenVersion !== user.tokenVersion) {
  return res.status(401).json({ error: 'Token revoked' });
}
```

- Revokes all tokens for a user at once
- **Trade-off:** Requires DB lookup per request (but can cache)

## Session-Based Authentication

### Server-Side Sessions

```javascript
// Express + express-session + connect-redis
import session from 'express-session';
import RedisStore from 'connect-redis';
import { createClient } from 'redis';

const redisClient = createClient({ url: process.env.REDIS_URL });
await redisClient.connect();

app.use(session({
  store: new RedisStore({ client: redisClient }),
  name: '__Host-session',           // Cookie name with secure prefix
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: true,                   // HTTPS only
    httpOnly: true,                 // No JS access
    sameSite: 'lax',                // CSRF protection
    maxAge: 24 * 60 * 60 * 1000,    // 24 hours
    path: '/',
  },
  rolling: true,                    // Reset expiry on each request
}));
```

```python
# FastAPI + Redis sessions
from fastapi import FastAPI, Request, Response
from uuid import uuid4
import redis.asyncio as redis
import json

r = redis.from_url("redis://localhost:6379")

async def create_session(response: Response, user_id: str, data: dict):
    session_id = str(uuid4())
    session_data = {"user_id": user_id, **data}
    await r.setex(f"session:{session_id}", 86400, json.dumps(session_data))

    response.set_cookie(
        key="__Host-session",
        value=session_id,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=86400,
        path="/",
    )
    return session_id

async def get_session(request: Request) -> dict | None:
    session_id = request.cookies.get("__Host-session")
    if not session_id:
        return None
    data = await r.get(f"session:{session_id}")
    if data:
        # Reset TTL (sliding window)
        await r.expire(f"session:{session_id}", 86400)
        return json.loads(data)
    return None
```

### Session Storage Backends

| Backend | Scalability | Persistence | Latency | Use When |
|---------|-------------|-------------|---------|----------|
| Memory | Single server | None (lost on restart) | Fastest | Development only |
| Redis | Horizontal | Optional (AOF/RDB) | ~1ms | Production default |
| PostgreSQL | Horizontal | Full | ~5ms | Already using Postgres, need durability |
| MongoDB | Horizontal | Full | ~3ms | Already using MongoDB |

### Session Fixation Prevention

Always regenerate the session ID after authentication state changes:

```javascript
// Express
app.post('/login', async (req, res) => {
  const user = await authenticate(req.body.email, req.body.password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });

  // CRITICAL: Regenerate session ID to prevent fixation
  req.session.regenerate((err) => {
    if (err) return res.status(500).json({ error: 'Session error' });
    req.session.userId = user.id;
    req.session.role = user.role;
    req.session.save((err) => {
      if (err) return res.status(500).json({ error: 'Session error' });
      res.json({ user: { id: user.id, email: user.email } });
    });
  });
});
```

## Cookie Security

### Cookie Attributes Deep Dive

#### SameSite

| Value | Behavior | CSRF Protection | Use Case |
|-------|----------|-----------------|----------|
| `Strict` | Cookie never sent cross-site | Strongest | Internal tools, admin panels |
| `Lax` | Sent on top-level navigation (GET) | Good (default) | General-purpose sessions |
| `None` | Sent on all cross-site requests | None (requires `Secure`) | Embedded widgets, cross-origin APIs |

**Lax vs Strict:** Lax allows the session cookie to be sent when a user clicks a link to your site from an external page. Strict does not, so users would appear logged out after clicking a link from an email or social media.

#### Secure Prefix Cookies

```
// __Host- prefix (strictest, recommended)
Set-Cookie: __Host-session=abc123; Secure; HttpOnly; SameSite=Lax; Path=/

// Requirements for __Host-:
// - Must have Secure flag
// - Must NOT have Domain attribute
// - Must have Path=/
// - Only sent to exact host (no subdomains)

// __Secure- prefix (less strict)
Set-Cookie: __Secure-session=abc123; Secure; HttpOnly; SameSite=Lax; Path=/

// Requirements for __Secure-:
// - Must have Secure flag
// - Can have Domain attribute
```

Use `__Host-` prefix for session cookies. It prevents a subdomain takeover from overwriting your session cookie.

### Cookie vs Authorization Header

| Aspect | Cookie | Authorization Header |
|--------|--------|---------------------|
| Automatic sending | Yes (browser sends automatically) | No (must attach manually) |
| CSRF risk | Yes (unless SameSite) | No |
| XSS theft risk | No (if HttpOnly) | Yes (if in accessible storage) |
| Cross-origin | Configurable (SameSite, CORS) | Simple (just add header) |
| Best for | Server-rendered apps, BFF | Pure APIs, mobile apps |

## CSRF Protection

### Synchronizer Token Pattern

```javascript
// Generate CSRF token and store in session
import crypto from 'crypto';

app.use((req, res, next) => {
  if (!req.session.csrfToken) {
    req.session.csrfToken = crypto.randomBytes(32).toString('hex');
  }
  res.locals.csrfToken = req.session.csrfToken;
  next();
});

// Validate on state-changing requests
app.use((req, res, next) => {
  if (['POST', 'PUT', 'DELETE', 'PATCH'].includes(req.method)) {
    const token = req.headers['x-csrf-token'] || req.body._csrf;
    if (!token || token !== req.session.csrfToken) {
      return res.status(403).json({ error: 'Invalid CSRF token' });
    }
  }
  next();
});
```

### Double-Submit Cookie Pattern

```javascript
// Set CSRF token as a separate cookie (NOT httpOnly, so JS can read it)
res.cookie('csrf-token', csrfToken, {
  secure: true,
  sameSite: 'strict',
  // httpOnly: false -- intentionally readable by JS
  path: '/',
});

// Client reads cookie value and sends in header
// fetch('/api/data', {
//   method: 'POST',
//   headers: { 'X-CSRF-Token': getCookie('csrf-token') },
// });

// Server validates: cookie value === header value
```

### SameSite as Defense-in-Depth

`SameSite=Lax` prevents most CSRF attacks because the cookie is not sent on cross-site POST requests. However, it does not protect against:
- Subdomain attacks
- GET-based state changes (which you should not have)
- Browser bugs

**Recommendation:** Use `SameSite=Lax` AND a CSRF token for defense-in-depth.

## Stateless vs Stateful Authentication

| Aspect | Stateless (JWT) | Stateful (Sessions) |
|--------|-----------------|---------------------|
| **Server storage** | None (token is self-contained) | Session store (Redis, DB) |
| **Scalability** | Easy (any server can verify) | Requires shared session store |
| **Revocation** | Hard (need blocklist) | Easy (delete session) |
| **Token size** | Larger (contains claims) | Smaller (just session ID) |
| **Offline verification** | Yes (with public key) | No (must query session store) |
| **Information leakage** | Claims visible (base64) | Server-side only |
| **Performance** | No DB lookup for verification | DB/cache lookup per request |
| **Logout** | Complex (blocklist or wait for expiry) | Simple (delete session) |
| **Best for** | Microservices, APIs, mobile | Monoliths, server-rendered apps |

### Hybrid Approach

Many production systems use both:

```
User login → Session created (server-side)
           → JWT issued for API calls
           → Session manages refresh tokens
           → JWT used for stateless API authorization
```

## Token Storage for SPAs

### Option 1: BFF Pattern (Recommended)

```
Browser ←→ BFF (Backend-for-Frontend) ←→ API
  │                  │
  │ session cookie   │ JWT in Authorization header
  │ (httpOnly)       │ (server-to-server)
```

The BFF holds tokens server-side and proxies API calls. The browser only has a session cookie.

### Option 2: HttpOnly Cookie

Access token stored in httpOnly cookie. Requires CSRF protection. Works well for same-origin APIs.

### Option 3: In-Memory (JavaScript Variable)

Access token stored in a JavaScript variable. Lost on page refresh (must re-authenticate via refresh token in httpOnly cookie). Safest browser storage for tokens but impacts UX.

### What NOT to Do

| Storage | Problem |
|---------|---------|
| localStorage | Accessible via XSS, persists across tabs |
| sessionStorage | Accessible via XSS |
| Non-httpOnly cookie | Accessible via XSS |
| URL parameters | Logged by servers, proxies, browser history |

## Key Rotation

### Why Rotate Keys

- Limit exposure if a key is compromised
- Compliance requirements
- Cryptographic best practice

### Rotation Process

```
1. Generate new key pair (kid: "key-2025-01")
2. Add new key to JWKS endpoint
3. Start signing new tokens with new key
4. Old tokens still verify (old key still in JWKS)
5. After max token lifetime, remove old key from JWKS
```

### JWKS (JSON Web Key Set) Endpoint

```json
// GET /.well-known/jwks.json
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "key-2025-01",
      "use": "sig",
      "alg": "RS256",
      "n": "...",
      "e": "AQAB"
    },
    {
      "kty": "RSA",
      "kid": "key-2024-01",
      "use": "sig",
      "alg": "RS256",
      "n": "...",
      "e": "AQAB"
    }
  ]
}
```

```javascript
// Verify JWT with JWKS (jose library)
import { createRemoteJWKSet, jwtVerify } from 'jose';

const JWKS = createRemoteJWKSet(
  new URL('https://auth.example.com/.well-known/jwks.json')
);

const { payload } = await jwtVerify(token, JWKS, {
  issuer: 'https://auth.example.com',
  audience: 'https://api.example.com',
});
```

## JWT Validation Checklist

Every JWT verification should check:

- [ ] **Signature** is valid
- [ ] **Algorithm** matches expected (prevent `alg: none` attack)
- [ ] **Expiration** (`exp`) has not passed
- [ ] **Not Before** (`nbf`) has passed (if present)
- [ ] **Issuer** (`iss`) matches expected value
- [ ] **Audience** (`aud`) matches your service
- [ ] **Token type** is correct (access vs refresh)
- [ ] **Key ID** (`kid`) maps to a known key

### Common JWT Attacks

| Attack | Description | Prevention |
|--------|-------------|------------|
| `alg: none` | Attacker removes signature | Always validate alg against allowlist |
| Key confusion (RS256→HS256) | Attacker signs with public key as HMAC secret | Explicitly specify expected algorithm |
| Token substitution | Access token used as refresh (or vice versa) | Include token type in claims |
| JWK injection | Attacker includes key in JWT header | Only trust keys from your JWKS endpoint |
| Expired token replay | Attacker replays old token | Always validate `exp` claim |
