---
name: auth-ops
description: "Authentication and authorization patterns - JWT, OAuth2, sessions, RBAC, ABAC, passkeys, and MFA. Use for: authentication, authorization, jwt, oauth, oauth2, session, login, rbac, abac, passkey, mfa, totp, api key, token, auth, cookie, csrf, cors credentials, bearer token, refresh token, oidc."
allowed-tools: "Read Write Bash"
related-skills: [security-ops, api-design-ops, postgres-ops]
---

# Auth Operations

Comprehensive authentication and authorization patterns for secure application development across languages and frameworks.

## Authentication Method Decision Tree

Use this tree to select the right authentication strategy for your use case.

```
What are you building?
│
├─ Traditional web application (server-rendered)?
│  └─ Session-based authentication
│     ├─ Server stores session data (Redis/DB)
│     ├─ Session ID in httpOnly cookie
│     └─ Best for: monoliths, SSR apps, admin panels
│
├─ API consumed by multiple clients?
│  └─ JWT (JSON Web Tokens)
│     ├─ Stateless, self-contained tokens
│     ├─ Access token (short-lived) + refresh token (long-lived)
│     └─ Best for: microservices, mobile apps, SPAs via BFF
│
├─ Service-to-service communication?
│  └─ API keys or Client Credentials (OAuth2)
│     ├─ API keys: simple, scoped, rotatable
│     ├─ Client Credentials: OAuth2 standard, token-based
│     └─ Best for: internal services, third-party integrations
│
├─ Third-party login (Google, GitHub, etc.)?
│  └─ OAuth2 / OpenID Connect
│     ├─ Authorization Code + PKCE for web/mobile
│     ├─ Delegate identity to trusted providers
│     └─ Best for: consumer apps, social login
│
└─ Passwordless authentication?
   └─ Passkeys (WebAuthn) or Magic Links
      ├─ Passkeys: phishing-resistant, biometric/hardware
      ├─ Magic links: email-based, time-limited
      └─ Best for: high-security, modern UX
```

## JWT Quick Reference

### Structure

```
Header.Payload.Signature

Header:  { "alg": "RS256", "typ": "JWT" }
Payload: { "iss": "auth.example.com", "sub": "user_123", ... }
Signature: RSASHA256(base64(header) + "." + base64(payload), privateKey)
```

### Common Claims

| Claim | Name | Purpose | Example |
|-------|------|---------|---------|
| `iss` | Issuer | Who issued the token | `"auth.example.com"` |
| `sub` | Subject | Who the token represents | `"user_123"` |
| `exp` | Expiration | When the token expires | `1700000000` (Unix timestamp) |
| `iat` | Issued At | When the token was created | `1699999100` |
| `aud` | Audience | Intended recipient(s) | `"api.example.com"` |
| `jti` | JWT ID | Unique token identifier | `"a1b2c3d4"` (for revocation) |
| `nbf` | Not Before | Token not valid before this time | `1699999100` |

### Signing Algorithms

| Algorithm | Type | Key | Use When |
|-----------|------|-----|----------|
| **RS256** | Asymmetric (RSA) | Public/private key pair | Distributed systems, multiple verifiers |
| **ES256** | Asymmetric (ECDSA) | Public/private key pair | Same as RS256, smaller keys/signatures |
| **HS256** | Symmetric (HMAC) | Shared secret | Single service, simple setups |

**Rule of thumb:** Use asymmetric (RS256/ES256) when the token issuer and verifier are different services. Use HS256 only when a single service both creates and verifies tokens.

### Access + Refresh Token Pattern

```
┌──────────┐                    ┌──────────┐
│  Client   │─── login ────────>│  Auth    │
│           │<── access (15m) ──│  Server  │
│           │<── refresh (7d) ──│          │
│           │                   └──────────┘
│           │─── API call ─────>┌──────────┐
│           │    (access token) │ Resource │
│           │<── response ──────│  Server  │
│           │                   └──────────┘
│           │─── access expired │          │
│           │─── refresh ──────>│  Auth    │
│           │<── new access ────│  Server  │
│           │<── new refresh ───│  (rotate)│
└──────────┘                    └──────────┘
```

- **Access token:** Short-lived (5-15 minutes), used for API calls
- **Refresh token:** Long-lived (7-30 days), used to get new access tokens
- **Rotation:** Issue a new refresh token with each use, invalidate the old one
- **Family detection:** Track refresh token lineage; if a revoked token is reused, invalidate the entire family

## OAuth2 Flow Decision Tree

```
What type of client?
│
├─ Web app with backend (Next.js, Rails, Django)?
│  └─ Authorization Code + PKCE
│     ├─ Redirect user to authorization server
│     ├─ Receive code at callback URL
│     ├─ Exchange code for tokens server-side
│     └─ PKCE prevents code interception attacks
│
├─ SPA (React, Vue) without backend?
│  └─ Authorization Code + PKCE (via BFF)
│     ├─ Use a Backend-for-Frontend to handle tokens
│     ├─ Never store tokens in browser-accessible storage
│     └─ BFF proxies API calls with token attached
│
├─ Mobile app (iOS, Android)?
│  └─ Authorization Code + PKCE
│     ├─ Use custom URI scheme or universal links for redirect
│     ├─ PKCE is mandatory (public client)
│     └─ Store tokens in secure enclave/keystore
│
├─ Server-to-server (no user)?
│  └─ Client Credentials
│     ├─ Authenticate with client_id + client_secret
│     ├─ No user context, service-level access
│     └─ Token cached until expiry
│
├─ CLI tool or smart TV?
│  └─ Device Code
│     ├─ Display code and URL to user
│     ├─ User authenticates on another device
│     ├─ CLI/TV polls for completion
│     └─ Good UX for input-constrained devices
│
└─ Microservice acting on behalf of a user?
   └─ Token Exchange (RFC 8693)
      ├─ Exchange user's token for a scoped downstream token
      ├─ Maintains user context across services
      └─ Use `act` claim for delegation chain
```

## Authorization Model Decision Tree

```
How complex are your access control needs?
│
├─ Simple: just "can user X do action Y"?
│  └─ Permission-based (direct)
│     ├─ user_permissions table
│     ├─ Simple to implement, hard to scale
│     └─ Good for: small apps, prototypes
│
├─ Users grouped into roles with fixed permissions?
│  └─ RBAC (Role-Based Access Control)
│     ├─ Roles: admin, editor, viewer
│     ├─ Each role has a set of permissions
│     ├─ Users assigned one or more roles
│     └─ Good for: most apps, admin panels, team tools
│
├─ Decisions depend on attributes (time, location, resource owner)?
│  └─ ABAC (Attribute-Based Access Control)
│     ├─ Policies evaluate subject + resource + environment attributes
│     ├─ "Allow if user.department == resource.department AND time < 17:00"
│     ├─ Flexible but complex
│     └─ Good for: enterprise, compliance-heavy, context-dependent access
│
└─ Access based on relationships (owner, parent, shared with)?
   └─ ReBAC (Relationship-Based Access Control)
      ├─ Google Zanzibar model
      ├─ Tuples: user:alice#viewer@document:report
      ├─ Supports inheritance: folder viewer → document viewer
      ├─ Tools: OpenFGA, SpiceDB, Ory Keto
      └─ Good for: file sharing, nested resources, social features
```

## Session Management Quick Reference

### Cookie Security Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `SameSite` | `Strict` | Cookie sent only for same-site requests (best CSRF protection) |
| `SameSite` | `Lax` | Cookie sent for top-level navigations (good default) |
| `SameSite` | `None` | Cookie sent for cross-site requests (requires `Secure`) |
| `Secure` | `true` | Cookie only sent over HTTPS |
| `HttpOnly` | `true` | Cookie not accessible via JavaScript (prevents XSS theft) |
| `__Host-` prefix | N/A | Requires Secure, no Domain, Path=/ (strictest) |
| `__Secure-` prefix | N/A | Requires Secure flag |
| `Max-Age` | seconds | Cookie lifetime (prefer over `Expires`) |
| `Path` | `/` | Scope cookie to path (usually `/`) |

### Recommended Cookie Configuration

```
Set-Cookie: __Host-session=abc123;
  Secure;
  HttpOnly;
  SameSite=Lax;
  Max-Age=86400;
  Path=/
```

### Session Expiry Strategies

| Strategy | Typical Value | Notes |
|----------|---------------|-------|
| **Idle timeout** | 15-30 minutes | Reset on each request |
| **Absolute timeout** | 8-24 hours | Force re-authentication |
| **Sliding window** | 30 min idle, 8h max | Best balance |
| **Remember me** | 30 days | Extended session, reduced privileges |

## Password Handling Quick Reference

### Hashing Algorithms

| Algorithm | Verdict | Notes |
|-----------|---------|-------|
| **argon2id** | BEST | Memory-hard, resists GPU attacks, recommended by OWASP |
| **bcrypt** | GOOD | Battle-tested, cost factor 12+, 72-byte input limit |
| **scrypt** | GOOD | Memory-hard, less common library support |
| **PBKDF2** | ACCEPTABLE | FIPS compliant, use 600k+ iterations with SHA-256 |
| **SHA-256/512** | BAD | Too fast, no salt built-in, easily brute-forced |
| **MD5** | NEVER | Broken, rainbow tables widely available |

### Password Rules (NIST 800-63B)

| Rule | Guidance |
|------|----------|
| Minimum length | 8 characters (12+ recommended) |
| Maximum length | At least 64 characters |
| Complexity rules | Do NOT require special chars/uppercase/numbers |
| Breached password check | Check against known breached passwords (HaveIBeenPwned API) |
| Password hints | Do NOT allow |
| Forced rotation | Do NOT force periodic changes (only on breach) |
| Paste into password field | ALLOW (supports password managers) |

### Rate Limiting Login Attempts

| Attempt | Response |
|---------|----------|
| 1-5 | Normal login |
| 6-10 | CAPTCHA required |
| 11-20 | Progressive delays (2s, 4s, 8s...) |
| 20+ | Temporary account lockout (15-30 min) |

**Important:** Use consistent response times for both success and failure to prevent timing-based username enumeration.

## MFA Quick Reference

### Methods Ranked by Security

| Method | Security | UX | Notes |
|--------|----------|----|-------|
| **WebAuthn/Passkeys** | Highest | Good | Phishing-resistant, hardware-backed |
| **TOTP (Authenticator)** | High | Medium | App-based (Google/Microsoft Authenticator) |
| **Push notifications** | High | Good | Requires mobile app |
| **Email OTP** | Medium | Medium | Depends on email security |
| **SMS OTP** | Low | Easy | SIM swap vulnerable, use as fallback only |

### TOTP Implementation Checklist

- [ ] Generate 160-bit secret (base32 encoded)
- [ ] Build otpauth:// URI with issuer and account
- [ ] Display QR code for authenticator scanning
- [ ] Require verification of first code before enabling
- [ ] Accept current window +/- 1 (30-second steps)
- [ ] Generate 8-10 single-use backup codes
- [ ] Hash backup codes before storing
- [ ] Allow recovery via verified identity

### Passkey/WebAuthn Checklist

- [ ] Generate cryptographic challenge on server
- [ ] Set relying party ID (your domain)
- [ ] Store credential public key and ID
- [ ] Verify signature on authentication
- [ ] Support multiple credentials per user
- [ ] Handle platform vs cross-platform authenticators
- [ ] Provide fallback auth method

## Common Gotchas

| Gotcha | Why It's Dangerous | Fix |
|--------|--------------------|-----|
| JWT stored in localStorage | XSS can steal tokens, no expiry enforcement by browser | Use httpOnly cookies or BFF pattern |
| Missing PKCE in OAuth2 | Authorization code interception attacks possible | Always use PKCE, even for confidential clients |
| Role explosion in RBAC | Hundreds of roles become unmanageable | Move to ABAC or ReBAC for complex scenarios |
| String comparison for tokens | Timing attacks reveal token value character by character | Use constant-time comparison (`crypto.timingSafeEqual`) |
| No token revocation strategy | Cannot invalidate compromised JWTs before expiry | Short expiry + refresh tokens, or maintain a blocklist |
| CORS with `credentials: true` | `Access-Control-Allow-Origin: *` does not work with credentials | Specify exact origin, set `Access-Control-Allow-Credentials: true` |
| `SameSite=None` without `Secure` | Browser silently rejects the cookie | Always pair `SameSite=None` with `Secure` flag |
| Refresh token reuse without detection | Stolen refresh tokens grant indefinite access | Rotate refresh tokens, detect reuse (token families) |
| Using OAuth2 Implicit grant | Tokens exposed in URL fragment, no refresh tokens | Use Authorization Code + PKCE instead (Implicit is deprecated) |
| Password in URL or logs | URLs are logged by proxies, browsers, and servers | Always send credentials in request body or headers |
| Missing CSRF protection with cookies | Cookie-based auth is vulnerable to cross-site request forgery | Use SameSite cookies + CSRF tokens for state-changing ops |
| Long-lived access tokens (hours/days) | Large attack window if token is compromised | Keep access tokens to 5-15 minutes, use refresh tokens |
| Storing API keys in plaintext | Database breach exposes all keys | Hash stored keys (SHA-256 of key), store prefix for lookup |
| Not validating JWT `aud` claim | Token meant for Service A accepted by Service B | Always validate `aud` matches your service identifier |
| Session fixation | Attacker sets session ID before login, then hijacks it | Regenerate session ID after authentication |
| Hardcoded secrets in code | Secrets leak via source control | Use environment variables or secret managers (Vault, AWS SSM) |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/jwt-sessions.md` | JWT structure, signing, sessions, cookies, CSRF, storage | ~650 |
| `references/oauth2-oidc.md` | OAuth2 flows, OIDC, provider integration, social login | ~700 |
| `references/authorization.md` | RBAC, ABAC, ReBAC, RLS, multi-tenant, audit logging | ~600 |
| `references/implementation.md` | Password hashing, MFA, rate limiting, API keys, reset flows | ~550 |

## See Also

- **security-ops** - Broader security patterns: OWASP, headers, input validation, encryption
- **api-design-ops** - API design including authentication endpoints, rate limiting
- **postgres-ops** - Row-level security (RLS) policies for database authorization
