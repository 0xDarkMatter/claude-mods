# OAuth2 and OpenID Connect

Comprehensive reference for OAuth2 grant types, OIDC, provider integration, and social login.

## OAuth2 Core Concepts

### Roles

| Role | Description | Example |
|------|-------------|---------|
| **Resource Owner** | The user who owns the data | End user |
| **Client** | The application requesting access | Your web/mobile app |
| **Authorization Server** | Issues tokens after authentication | Auth0, Keycloak, your auth service |
| **Resource Server** | Hosts the protected API | Your API server |

### Key Terms

| Term | Description |
|------|-------------|
| **Scope** | Permission level requested (e.g., `read:users`, `write:posts`) |
| **Grant Type** | The flow used to obtain tokens |
| **Authorization Code** | Temporary code exchanged for tokens |
| **Access Token** | Token used to call the API |
| **Refresh Token** | Token used to get new access tokens |
| **Redirect URI** | Where the authorization server sends the user back |
| **State** | CSRF protection parameter (random, unguessable) |
| **PKCE** | Proof Key for Code Exchange (prevents code interception) |

## Authorization Code + PKCE

The recommended flow for web applications, mobile apps, and SPAs. PKCE (Proof Key for Code Exchange) protects against authorization code interception.

### Flow

```
┌──────┐          ┌───────────────┐          ┌──────────────┐
│Client│          │ Authorization │          │   Resource   │
│      │          │    Server     │          │    Server    │
└──┬───┘          └───────┬───────┘          └──────┬───────┘
   │                      │                         │
   │ 1. Generate code_verifier (random)             │
   │    code_challenge = SHA256(code_verifier)       │
   │                      │                         │
   │ 2. Redirect to /authorize                      │
   │    ?response_type=code                         │
   │    &client_id=xxx                              │
   │    &redirect_uri=https://app/callback          │
   │    &scope=openid profile email                 │
   │    &state=random_csrf_value                    │
   │    &code_challenge=xxx                         │
   │    &code_challenge_method=S256                 │
   │──────────────>│                                │
   │               │                                │
   │ 3. User authenticates and consents             │
   │               │                                │
   │ 4. Redirect to callback                        │
   │    ?code=authorization_code                    │
   │    &state=random_csrf_value                    │
   │<──────────────│                                │
   │                                                │
   │ 5. POST /token                                 │
   │    grant_type=authorization_code               │
   │    &code=authorization_code                    │
   │    &redirect_uri=https://app/callback          │
   │    &client_id=xxx                              │
   │    &code_verifier=original_random_value        │
   │──────────────>│                                │
   │               │                                │
   │ 6. Response: access_token, refresh_token,      │
   │    id_token (if OIDC)                          │
   │<──────────────│                                │
   │                                                │
   │ 7. GET /api/resource                           │
   │    Authorization: Bearer access_token          │
   │────────────────────────────────────────────────>│
   │                                                │
   │ 8. Response: protected resource                │
   │<────────────────────────────────────────────────│
```

### Implementation: Node.js

```javascript
import crypto from 'crypto';

// Step 1: Generate PKCE values
function generatePKCE() {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto
    .createHash('sha256')
    .update(verifier)
    .digest('base64url');
  return { verifier, challenge };
}

// Step 2: Build authorization URL
function getAuthorizationUrl(config) {
  const { verifier, challenge } = generatePKCE();
  const state = crypto.randomBytes(16).toString('hex');

  // Store verifier and state in session
  // req.session.pkceVerifier = verifier;
  // req.session.oauthState = state;

  const params = new URLSearchParams({
    response_type: 'code',
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    scope: 'openid profile email',
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });

  return `${config.authorizationEndpoint}?${params}`;
}

// Step 5: Exchange code for tokens
async function exchangeCode(code, verifier, config) {
  const response = await fetch(config.tokenEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: config.redirectUri,
      client_id: config.clientId,
      client_secret: config.clientSecret, // Confidential clients only
      code_verifier: verifier,
    }),
  });

  if (!response.ok) {
    throw new Error(`Token exchange failed: ${response.status}`);
  }

  return response.json();
  // Returns: { access_token, refresh_token, id_token, token_type, expires_in }
}
```

### Implementation: Python

```python
import hashlib
import secrets
import base64
from urllib.parse import urlencode
import httpx

def generate_pkce():
    verifier = secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge

def get_authorization_url(config: dict) -> tuple[str, str, str]:
    verifier, challenge = generate_pkce()
    state = secrets.token_hex(16)

    params = urlencode({
        "response_type": "code",
        "client_id": config["client_id"],
        "redirect_uri": config["redirect_uri"],
        "scope": "openid profile email",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })

    url = f"{config['authorization_endpoint']}?{params}"
    return url, verifier, state

async def exchange_code(code: str, verifier: str, config: dict) -> dict:
    async with httpx.AsyncClient() as client:
        response = await client.post(
            config["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": config["redirect_uri"],
                "client_id": config["client_id"],
                "client_secret": config["client_secret"],
                "code_verifier": verifier,
            },
        )
        response.raise_for_status()
        return response.json()
```

### Redirect URI Validation

**Critical security requirement:** The authorization server must validate redirect URIs exactly.

| Rule | Why |
|------|-----|
| Exact match required | Prevents open redirect attacks |
| No wildcards in production | Attacker could register matching subdomain |
| HTTPS required | Prevent code interception on HTTP |
| No fragments (#) | Fragment not sent to server |
| Pre-register all URIs | Only allow known, trusted redirect targets |

### State Parameter

The `state` parameter prevents CSRF attacks on the OAuth2 flow:

```javascript
// Before redirect: generate and store
const state = crypto.randomBytes(16).toString('hex');
req.session.oauthState = state;

// In callback: validate
if (req.query.state !== req.session.oauthState) {
  throw new Error('State mismatch - possible CSRF attack');
}
delete req.session.oauthState;
```

## Client Credentials Grant

Server-to-server authentication with no user context.

```
┌──────────┐                    ┌───────────────┐
│  Service  │                    │ Authorization │
│  Client   │                    │    Server     │
└─────┬─────┘                    └───────┬───────┘
      │                                  │
      │  POST /token                     │
      │  grant_type=client_credentials   │
      │  &client_id=xxx                  │
      │  &client_secret=yyy             │
      │  &scope=read:data               │
      │─────────────────────────────────>│
      │                                  │
      │  { access_token, expires_in }    │
      │<─────────────────────────────────│
```

```javascript
// Node.js implementation
async function getClientCredentialsToken(config) {
  const response = await fetch(config.tokenEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${Buffer.from(
        `${config.clientId}:${config.clientSecret}`
      ).toString('base64')}`,
    },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      scope: config.scope,
    }),
  });

  const data = await response.json();

  // Cache the token until near expiry
  // tokenCache.set(cacheKey, data.access_token, data.expires_in - 60);

  return data.access_token;
}
```

```python
# Python implementation
async def get_client_credentials_token(config: dict) -> str:
    async with httpx.AsyncClient() as client:
        response = await client.post(
            config["token_endpoint"],
            auth=(config["client_id"], config["client_secret"]),
            data={
                "grant_type": "client_credentials",
                "scope": config["scope"],
            },
        )
        response.raise_for_status()
        data = response.json()
        return data["access_token"]
```

**Best practices:**
- Cache tokens until near expiry (subtract 60 seconds from `expires_in`)
- Use mutual TLS (mTLS) for additional security in high-trust environments
- Rotate client secrets periodically

## Device Code Grant

For CLI tools, smart TVs, and devices without a browser or with limited input.

```
┌──────────┐          ┌───────────────┐          ┌──────────┐
│  Device   │          │ Authorization │          │  User's  │
│ (CLI/TV)  │          │    Server     │          │ Browser  │
└─────┬─────┘          └───────┬───────┘          └────┬─────┘
      │                        │                       │
      │ POST /device/code      │                       │
      │ client_id=xxx          │                       │
      │ scope=profile          │                       │
      │───────────────────────>│                       │
      │                        │                       │
      │ { device_code,         │                       │
      │   user_code: "ABCD-1234",                      │
      │   verification_uri,    │                       │
      │   interval: 5 }        │                       │
      │<───────────────────────│                       │
      │                        │                       │
      │ Display to user:       │                       │
      │ "Visit https://auth.example.com/device"        │
      │ "Enter code: ABCD-1234"│                       │
      │                        │                       │
      │                        │  User visits URL      │
      │                        │  and enters code      │
      │                        │<──────────────────────│
      │                        │                       │
      │                        │  User authenticates   │
      │                        │  and authorizes       │
      │                        │<──────────────────────│
      │                        │                       │
      │ Poll: POST /token      │                       │
      │ grant_type=urn:ietf:   │                       │
      │   params:oauth:        │                       │
      │   grant-type:device_code                       │
      │ device_code=xxx        │                       │
      │───────────────────────>│                       │
      │                        │                       │
      │ { access_token }       │                       │
      │<───────────────────────│                       │
```

```javascript
// CLI implementation
async function deviceCodeFlow(config) {
  // 1. Request device code
  const codeResponse = await fetch(`${config.authServer}/device/code`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: config.clientId,
      scope: 'openid profile',
    }),
  });

  const { device_code, user_code, verification_uri, interval } =
    await codeResponse.json();

  // 2. Display to user
  console.log(`Visit: ${verification_uri}`);
  console.log(`Enter code: ${user_code}`);

  // 3. Poll for completion
  while (true) {
    await new Promise((r) => setTimeout(r, interval * 1000));

    const tokenResponse = await fetch(`${config.authServer}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        device_code,
        client_id: config.clientId,
      }),
    });

    const data = await tokenResponse.json();

    if (data.error === 'authorization_pending') continue;
    if (data.error === 'slow_down') {
      interval += 5;
      continue;
    }
    if (data.error) throw new Error(data.error_description);

    return data; // { access_token, refresh_token, ... }
  }
}
```

## Token Exchange (RFC 8693)

Allows a service to exchange one token for another, maintaining user context across microservices.

```javascript
// Service A has user's token, needs to call Service B
async function exchangeToken(userToken, targetAudience, config) {
  const response = await fetch(config.tokenEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
      subject_token: userToken,
      subject_token_type: 'urn:ietf:params:oauth:token-type:access_token',
      audience: targetAudience, // Service B's identifier
      scope: 'read:data',
    }),
  });

  return response.json();
  // Returns token with `act` claim showing delegation chain:
  // { "sub": "user_123", "act": { "sub": "service_a" } }
}
```

## OpenID Connect (OIDC)

OIDC is an identity layer on top of OAuth2. While OAuth2 handles authorization (access to resources), OIDC handles authentication (who the user is).

### What OIDC Adds to OAuth2

| OAuth2 Only | OIDC Adds |
|-------------|-----------|
| Access token (opaque) | ID token (JWT with user info) |
| Resource access | User identity |
| Scopes for permissions | Standard identity scopes |
| No user info standard | UserInfo endpoint |
| No discovery | `.well-known/openid-configuration` |

### ID Token

The ID token is a JWT containing user identity information.

```json
{
  "iss": "https://auth.example.com",
  "sub": "user_abc123",
  "aud": "client_id_xyz",
  "exp": 1700001500,
  "iat": 1700000600,
  "nonce": "random_nonce_value",
  "auth_time": 1700000500,
  "name": "Alice Smith",
  "email": "alice@example.com",
  "email_verified": true,
  "picture": "https://example.com/alice.jpg"
}
```

### Standard OIDC Scopes

| Scope | Claims Returned |
|-------|----------------|
| `openid` | `sub` (required scope for OIDC) |
| `profile` | `name`, `family_name`, `given_name`, `picture`, `locale` |
| `email` | `email`, `email_verified` |
| `address` | `address` (structured object) |
| `phone` | `phone_number`, `phone_number_verified` |

### Discovery Document

```
GET https://auth.example.com/.well-known/openid-configuration
```

```json
{
  "issuer": "https://auth.example.com",
  "authorization_endpoint": "https://auth.example.com/authorize",
  "token_endpoint": "https://auth.example.com/token",
  "userinfo_endpoint": "https://auth.example.com/userinfo",
  "jwks_uri": "https://auth.example.com/.well-known/jwks.json",
  "scopes_supported": ["openid", "profile", "email"],
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "client_credentials"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256", "ES256"],
  "code_challenge_methods_supported": ["S256"]
}
```

### UserInfo Endpoint

```javascript
// Fetch additional user info
const userInfo = await fetch('https://auth.example.com/userinfo', {
  headers: { Authorization: `Bearer ${accessToken}` },
}).then((r) => r.json());

// Response:
// {
//   "sub": "user_abc123",
//   "name": "Alice Smith",
//   "email": "alice@example.com",
//   "email_verified": true,
//   "picture": "https://example.com/alice.jpg"
// }
```

## Provider Integration

### Auth0

```javascript
// Next.js with Auth0 SDK
// npm install @auth0/nextjs-auth0

// app/api/auth/[auth0]/route.ts
import { handleAuth } from '@auth0/nextjs-auth0';
export const GET = handleAuth();

// app/layout.tsx
import { UserProvider } from '@auth0/nextjs-auth0/client';
export default function RootLayout({ children }) {
  return <UserProvider>{children}</UserProvider>;
}

// Protected page
import { withPageAuthRequired, getSession } from '@auth0/nextjs-auth0';
export default withPageAuthRequired(async function Dashboard() {
  const session = await getSession();
  return <div>Welcome {session.user.name}</div>;
});

// API route protection
import { withApiAuthRequired, getSession } from '@auth0/nextjs-auth0';
export const GET = withApiAuthRequired(async (req) => {
  const session = await getSession();
  return Response.json({ user: session.user });
});
```

### Clerk

```javascript
// Next.js with Clerk
// npm install @clerk/nextjs

// middleware.ts
import { clerkMiddleware, createRouteMatcher } from '@clerk/nextjs/server';

const isProtectedRoute = createRouteMatcher(['/dashboard(.*)']);

export default clerkMiddleware(async (auth, request) => {
  if (isProtectedRoute(request)) {
    await auth.protect();
  }
});

// app/layout.tsx
import { ClerkProvider } from '@clerk/nextjs';
export default function RootLayout({ children }) {
  return <ClerkProvider>{children}</ClerkProvider>;
}

// Components
import { SignIn, SignUp, UserButton } from '@clerk/nextjs';
// <SignIn /> - full sign-in component
// <UserButton /> - user avatar with dropdown
```

### Supabase Auth

```javascript
// Supabase Auth with Row Level Security
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Sign up
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'secure-password',
});

// Sign in
const { data, error } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'secure-password',
});

// OAuth (Google)
const { data, error } = await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: 'https://app.example.com/callback' },
});

// Get current session
const { data: { session } } = await supabase.auth.getSession();

// RLS policy (in PostgreSQL)
// CREATE POLICY "Users can read own data"
// ON profiles FOR SELECT
// USING (auth.uid() = user_id);
```

### AWS Cognito

```javascript
// AWS Cognito with Amplify
import { Amplify } from 'aws-amplify';
import { signIn, signUp, getCurrentUser } from 'aws-amplify/auth';

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: 'us-east-1_xxxxx',
      userPoolClientId: 'xxxxx',
      loginWith: {
        oauth: {
          domain: 'auth.example.com',
          scopes: ['openid', 'profile', 'email'],
          redirectSignIn: ['https://app.example.com/callback'],
          redirectSignOut: ['https://app.example.com/'],
          responseType: 'code',
        },
      },
    },
  },
});

const { isSignedIn } = await signIn({
  username: 'user@example.com',
  password: 'secure-password',
});
```

### Keycloak

```javascript
// Keycloak with keycloak-js
import Keycloak from 'keycloak-js';

const keycloak = new Keycloak({
  url: 'https://keycloak.example.com',
  realm: 'my-realm',
  clientId: 'my-app',
});

await keycloak.init({
  onLoad: 'check-sso',
  pkceMethod: 'S256',
});

if (keycloak.authenticated) {
  const token = keycloak.token;
  const userInfo = await keycloak.loadUserInfo();
}

// Token refresh
keycloak.onTokenExpired = () => {
  keycloak.updateToken(30).catch(() => keycloak.login());
};
```

## Social Login

### Google

```javascript
// Google OAuth2 specifics
const googleConfig = {
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
  scopes: 'openid email profile',
  // Quirks:
  // - Use `prompt=consent` to force consent screen (get refresh token)
  // - Use `access_type=offline` for refresh tokens
  // - Google ID tokens include `hd` (hosted domain) for Google Workspace
};
```

### GitHub

```javascript
// GitHub OAuth2 specifics
const githubConfig = {
  authorizationEndpoint: 'https://github.com/login/oauth/authorize',
  tokenEndpoint: 'https://github.com/login/oauth/access_token',
  userEndpoint: 'https://api.github.com/user',
  emailEndpoint: 'https://api.github.com/user/emails',
  // Quirks:
  // - No OIDC support (no ID token)
  // - Must fetch user info separately
  // - Email may be private; use /user/emails endpoint
  // - Token endpoint returns form-encoded by default
  //   (set Accept: application/json header)
  // - No refresh tokens (tokens don't expire unless revoked)
};
```

### Apple

```javascript
// Apple Sign In specifics
const appleConfig = {
  authorizationEndpoint: 'https://appleid.apple.com/auth/authorize',
  tokenEndpoint: 'https://appleid.apple.com/auth/token',
  // Quirks:
  // - Client secret is a JWT signed with your Apple private key
  // - User info (name, email) only returned on FIRST sign-in
  //   (must store it immediately)
  // - Users can hide email (relay address)
  // - Must validate ID token, Apple doesn't have UserInfo endpoint
  // - response_mode=form_post for web
};

// Generate Apple client secret (JWT)
import { SignJWT, importPKCS8 } from 'jose';

async function generateAppleClientSecret(config) {
  const privateKey = await importPKCS8(config.privateKey, 'ES256');

  return new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: config.keyId })
    .setIssuer(config.teamId)
    .setSubject(config.clientId)
    .setAudience('https://appleid.apple.com')
    .setIssuedAt()
    .setExpirationTime('180d')
    .sign(privateKey);
}
```

## Scope Design

### Naming Conventions

```
# Resource-based (recommended)
read:users
write:users
delete:users
admin:users

# Action-based
users.read
users.write
users.delete

# Hierarchical (coarse to fine)
users           # Full access to users
users:read      # Read-only access
users:profile   # Access to profile only
```

### Scope Design Principles

| Principle | Description |
|-----------|-------------|
| Least privilege | Request only needed scopes |
| Granularity balance | Too fine = user confusion, too coarse = over-permission |
| Hierarchical | Broader scope implies narrower ones |
| Descriptive | Scope name should be self-explanatory |
| Documented | Each scope has a user-facing description |

### Consent Management

```javascript
// Scope validation middleware
function requireScopes(...requiredScopes) {
  return (req, res, next) => {
    const tokenScopes = req.auth.scope?.split(' ') || [];
    const hasAll = requiredScopes.every((s) => tokenScopes.includes(s));
    if (!hasAll) {
      return res.status(403).json({
        error: 'insufficient_scope',
        required: requiredScopes,
        granted: tokenScopes,
      });
    }
    next();
  };
}

// Usage
app.get('/api/users', requireScopes('read:users'), getUsers);
app.post('/api/users', requireScopes('write:users'), createUser);
app.delete('/api/users/:id', requireScopes('delete:users'), deleteUser);
```

## Token Lifecycle

### Token Endpoint Responses

```json
// Successful token response
{
  "access_token": "eyJhbGciOi...",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "dGhpcyBpcyBh...",
  "id_token": "eyJhbGciOi...",
  "scope": "openid profile email"
}

// Error response
{
  "error": "invalid_grant",
  "error_description": "The authorization code has expired"
}
```

### Token Introspection (RFC 7662)

Allows a resource server to check if a token is still valid (useful for opaque tokens).

```javascript
// Resource server checks token validity
async function introspectToken(token, config) {
  const response = await fetch(config.introspectionEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${Buffer.from(
        `${config.clientId}:${config.clientSecret}`
      ).toString('base64')}`,
    },
    body: new URLSearchParams({
      token,
      token_type_hint: 'access_token',
    }),
  });

  const data = await response.json();
  // { active: true, sub: "user_123", scope: "read:users", exp: 1700001500 }
  // { active: false } -- token is invalid/expired/revoked
  return data;
}
```

### Token Revocation (RFC 7009)

```javascript
// Revoke a token (on logout)
async function revokeToken(token, tokenType, config) {
  await fetch(config.revocationEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${Buffer.from(
        `${config.clientId}:${config.clientSecret}`
      ).toString('base64')}`,
    },
    body: new URLSearchParams({
      token,
      token_type_hint: tokenType, // 'access_token' or 'refresh_token'
    }),
  });
  // Always returns 200 (even if token was already invalid)
}
```

## Implementation Libraries

### Auth.js (NextAuth.js)

```javascript
// app/api/auth/[...nextauth]/route.ts
import NextAuth from 'next-auth';
import Google from 'next-auth/providers/google';
import GitHub from 'next-auth/providers/github';
import Credentials from 'next-auth/providers/credentials';

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Google({
      clientId: process.env.GOOGLE_CLIENT_ID,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET,
    }),
    GitHub({
      clientId: process.env.GITHUB_CLIENT_ID,
      clientSecret: process.env.GITHUB_CLIENT_SECRET,
    }),
    Credentials({
      credentials: {
        email: { label: 'Email' },
        password: { label: 'Password', type: 'password' },
      },
      authorize: async (credentials) => {
        const user = await verifyCredentials(
          credentials.email,
          credentials.password
        );
        return user || null;
      },
    }),
  ],
  callbacks: {
    async jwt({ token, user, account }) {
      if (user) {
        token.role = user.role;
      }
      return token;
    },
    async session({ session, token }) {
      session.user.role = token.role;
      return session;
    },
  },
  pages: {
    signIn: '/login',
    error: '/auth/error',
  },
});
```

### Passport.js (Express)

```javascript
import passport from 'passport';
import { Strategy as GoogleStrategy } from 'passport-google-oauth20';

passport.use(
  new GoogleStrategy(
    {
      clientID: process.env.GOOGLE_CLIENT_ID,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET,
      callbackURL: '/auth/google/callback',
    },
    async (accessToken, refreshToken, profile, done) => {
      const user = await db.users.upsert({
        where: { googleId: profile.id },
        create: {
          googleId: profile.id,
          email: profile.emails[0].value,
          name: profile.displayName,
        },
        update: { name: profile.displayName },
      });
      done(null, user);
    }
  )
);

// Routes
app.get('/auth/google', passport.authenticate('google', {
  scope: ['profile', 'email'],
}));

app.get('/auth/google/callback',
  passport.authenticate('google', { failureRedirect: '/login' }),
  (req, res) => res.redirect('/dashboard')
);
```

### Python: Authlib / python-social-auth

```python
# FastAPI with Authlib
from authlib.integrations.starlette_client import OAuth
from starlette.config import Config

oauth = OAuth()
oauth.register(
    name="google",
    server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
    client_id=config("GOOGLE_CLIENT_ID"),
    client_secret=config("GOOGLE_CLIENT_SECRET"),
    client_kwargs={"scope": "openid email profile"},
)

@app.get("/auth/google")
async def google_login(request: Request):
    redirect_uri = request.url_for("google_callback")
    return await oauth.google.authorize_redirect(request, redirect_uri)

@app.get("/auth/google/callback")
async def google_callback(request: Request):
    token = await oauth.google.authorize_access_token(request)
    userinfo = token.get("userinfo")
    # Create or update user, establish session
    return RedirectResponse(url="/dashboard")
```

### Go: golang.org/x/oauth2

```go
import (
    "golang.org/x/oauth2"
    "golang.org/x/oauth2/google"
)

var googleOAuthConfig = &oauth2.Config{
    ClientID:     os.Getenv("GOOGLE_CLIENT_ID"),
    ClientSecret: os.Getenv("GOOGLE_CLIENT_SECRET"),
    RedirectURL:  "https://app.example.com/auth/google/callback",
    Scopes:       []string{"openid", "profile", "email"},
    Endpoint:     google.Endpoint,
}

func handleGoogleLogin(w http.ResponseWriter, r *http.Request) {
    state := generateRandomState() // Store in session
    url := googleOAuthConfig.AuthCodeURL(state, oauth2.AccessTypeOffline)
    http.Redirect(w, r, url, http.StatusTemporaryRedirect)
}

func handleGoogleCallback(w http.ResponseWriter, r *http.Request) {
    // Validate state parameter
    code := r.URL.Query().Get("code")
    token, err := googleOAuthConfig.Exchange(r.Context(), code)
    if err != nil {
        http.Error(w, "Token exchange failed", http.StatusInternalServerError)
        return
    }

    // Use token to get user info
    client := googleOAuthConfig.Client(r.Context(), token)
    resp, _ := client.Get("https://www.googleapis.com/oauth2/v2/userinfo")
    // Parse response, create/update user, establish session
}
```

## Deprecated: Implicit Grant

The OAuth2 Implicit grant (`response_type=token`) is **deprecated** and should not be used for new applications.

**Why it was deprecated:**
- Access token exposed in URL fragment (browser history, referer headers)
- No refresh tokens (user must re-authenticate)
- No mechanism to verify the token was intended for your client
- Vulnerable to token injection attacks

**Migration:** Use Authorization Code + PKCE instead, with a BFF for SPAs.
