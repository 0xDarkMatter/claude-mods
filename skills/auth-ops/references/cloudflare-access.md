# Identity-Aware Proxies (Cloudflare Access)

Deep-dive reference for identity-aware proxy (IAP) authentication, worked through Cloudflare Access (Zero Trust). The patterns — verify the proxy's signed identity assertion, close every path around the proxy, layer app authorization on top — generalize to any IAP (Google IAP, AWS Verified Access, Pomerium, oauth2-proxy).

## The Model

An identity-aware proxy moves *authentication* out of your application and into an enforcement edge in front of it:

```
┌─────────┐     ┌──────────────────────┐      ┌───────────────┐
│ Browser  │───>│ Identity-aware proxy  │────> │ Origin (your  │
│          │    │ (Cloudflare Access)   │      │ app/Worker)   │
│          │    │ - IdP login (SSO)     │ JWT  │ - verify JWT  │
│          │    │ - OTP for externals   │ hdr  │ - user lookup │
│          │    │ - session mgmt        │      │ - roles/scope │
│          │    │ - bot mitigation      │      │               │
└─────────┘     └──────────────────────┘      └───────────────┘
```

What the proxy owns: login UI, IdP federation, OTP delivery, session lifetime, rate limiting, bot mitigation. What your origin still owns: **verifying the proxy's assertion, mapping identity to an application user, and every authorization decision.**

The proxy asserts identity to the origin via a signed JWT in a request header — for Access, `Cf-Access-Jwt-Assertion`. Everything below follows from one question: *can you trust that header?* Answer: only after cryptographic verification, and only if the proxy is the sole path to the origin.

### When an IAP is the right call

| Situation | Fit |
|-----------|-----|
| Internal tools / admin panels for staff with an existing IdP (Google Workspace, Entra) | Excellent — SSO for free, no credential storage |
| Small external audiences (partners, counterparties) who need occasional access | Good — one-time PIN policies avoid provisioning them in your IdP |
| Security-critical app where you don't want to own login hardening (rate limits, CSRF, bot defense, OTP delivery) | Excellent — the edge is hardened and audited for you |
| Consumer-facing product with self-signup, thousands of users | Poor — use an auth library or hosted IdP (see `better-auth.md`, `oauth2-oidc.md`) |
| You need a fully branded login experience | Weak — the proxy's hosted login page is minimally themeable |

## Access Application + Policy Anatomy

An Access deployment has four moving parts:

| Part | What it is | Example |
|------|------------|---------|
| **Team domain** | Your Zero Trust tenant; also the JWT issuer | `example.cloudflareaccess.com` → issuer `https://example.cloudflareaccess.com` |
| **Application** | A "self-hosted" app bound to a hostname (or hostname + path) | Domain `app.example.com` |
| **Policies** | Ordered Allow/Deny/Bypass/Service-Auth rules on the application | Allow staff, Allow named partners |
| **AUD tag** | Per-application audience identifier; goes in the JWT's `aud` claim | Copied from the dashboard into origin config |

Typical policy set for an app with staff + external users:

1. **Allow — staff:** identity provider login (e.g. Google), include rule "emails ending in `@example.com`".
2. **Allow — external counterparties:** login method **One-time PIN**, include rule listing the specific partner emails.

Both policies authenticate; neither authorizes. The emails Access admits must still map to rows/roles in your application's user store (see [Fail-Closed Layering](#fail-closed-layering) below).

Setup sequence (order matters — the AUD tag doesn't exist until the app does):

```
1. Zero Trust dashboard -> Access -> Applications -> Add -> Self-hosted
2. Set the application domain (the exact hostname the origin serves)
3. Add Allow policies (IdP for staff, OTP for externals)
4. Copy the application AUD tag
5. Configure the origin with team domain + AUD
   (Workers: wrangler secret put CF_ACCESS_AUD, then redeploy)
```

One application per hostname is the natural multi-tenant shape: each tenant hostname gets its own Access app, its own AUD, and its own policy set — onboarding a tenant is dashboard config plus data, no code change.

## Verifying the JWT at the Origin

The proxy injects `Cf-Access-Jwt-Assertion` (also available as the `CF_Authorization` cookie). Verify it on **every request** — signature, issuer, and audience — against the team's public JWKS at `https://<team-domain>/cdn-cgi/access/certs`.

```typescript
// Cloudflare Access JWT verification (Workers / jose).
// Never trust the Cf-Access-Jwt-Assertion header without verifying
// signature, issuer, and audience.
import { createRemoteJWKSet, jwtVerify } from 'jose';

export interface AccessConfig {
  /** Access team domain, e.g. "example.cloudflareaccess.com" (no scheme). */
  teamDomain: string;
  /** The Access application AUD tag for this hostname. */
  aud: string;
}

export class AccessAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AccessAuthError';
  }
}

// One JWKS per team domain, cached for the process/isolate lifetime.
// createRemoteJWKSet caches keys and refetches on an unknown `kid`,
// so Access key rotation does not cause a 403 storm.
const jwksByIssuer = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

function jwksFor(issuer: string) {
  let jwks = jwksByIssuer.get(issuer);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
    jwksByIssuer.set(issuer, jwks);
  }
  return jwks;
}

/**
 * Verify an Access JWT and return the caller's email (lower-cased).
 * Throws AccessAuthError on any failure — missing token, bad signature,
 * wrong issuer/audience, expired, or no email claim. Map to 403.
 */
export async function verifyAccessJwt(
  token: string | undefined,
  config: AccessConfig,
): Promise<string> {
  if (!token) throw new AccessAuthError('missing Access token');
  if (!config.teamDomain || !config.aud) {
    throw new AccessAuthError('Access is not configured');
  }

  const issuer = `https://${config.teamDomain}`;
  try {
    const { payload } = await jwtVerify(token, jwksFor(issuer), {
      issuer,
      audience: config.aud,
      algorithms: ['RS256'],
    });
    const email =
      typeof payload.email === 'string' ? payload.email.trim().toLowerCase() : '';
    if (!email) throw new AccessAuthError('Access token has no email claim');
    return email;
  } catch (err) {
    if (err instanceof AccessAuthError) throw err;
    throw new AccessAuthError(
      `Access token verification failed: ${(err as Error).message}`,
    );
  }
}
```

The details that matter:

| Detail | Why |
|--------|-----|
| Verify `iss` against the team domain | Rejects tokens signed by any *other* Access tenant — the JWKS URL alone doesn't pin the tenant |
| Verify `aud` against **this application's** AUD tag | A valid token for a different app on the same team must not open this one. With per-hostname apps, resolve the expected AUD from the request hostname |
| Pin `algorithms: ['RS256']` | Never accept whatever `alg` the token declares |
| Cache the JWKS per process/isolate | The JWKS endpoint is remote; fetching it per-request adds latency and a availability dependency |
| Refetch on unknown `kid` (jose's `createRemoteJWKSet` does this) | Access rotates signing keys; without kid-triggered refetch, rotation causes a spurious-403 storm until the cache expires |
| Lower-case + trim the email before lookup | Email comparison against your user store must be canonical — `Alice@Example.com` and `alice@example.com` are the same person |
| Fail closed: any error → 403 | Misconfigured team domain or missing AUD must deny, never pass through |

## THE Trust Precondition: the Proxy Must Be the Only Path

**An identity-aware proxy header is worthless if the origin is directly reachable.** The header is just a request header; anyone who can reach the origin without going through the proxy can set it themselves. Signature verification protects against *forged tokens*, not against a *forged unverified header* on a code path that skips verification — and more subtly, an open origin invites "trust the header, skip the JWT" shortcuts that turn into real vulnerabilities.

On Cloudflare Workers, closing the origin means:

```toml
# wrangler.toml / wrangler.jsonc
workers_dev = false   # no <name>.workers.dev origin exists
# routes/custom domains: only the Access-protected hostname(s)
```

With `workers_dev = false` and routes only on Access-protected hostnames, there is no unproxied URL on which the header could be forged — the classic prototype bug (trusting `Cf-Access-*` headers, then discovering anyone hitting the `*.workers.dev` origin could claim any email and become admin) is structurally impossible.

Generalized, for any IAP:

| Deployment | How to close the side door |
|------------|---------------------------|
| Cloudflare Workers | `workers_dev = false`; routes only on protected hostnames |
| Origin server behind Cloudflare | Firewall the origin to Cloudflare IP ranges + authenticated origin pulls (mTLS); otherwise anyone who finds the origin IP bypasses Access entirely |
| `cloudflared` tunnel | Best case — the origin has no public inbound at all; only the tunnel reaches it |
| Google IAP / AWS ALB + OIDC | Security groups / ingress rules so only the load balancer reaches the backends; verify the signed-identity header (`x-goog-iap-jwt-assertion` etc.), not the plain email header |
| Kubernetes + oauth2-proxy / Pomerium | NetworkPolicy so app pods accept traffic only from the proxy |

If you cannot close the side door, JWT verification is your only line of defense — which is exactly why you verify the JWT even when you *think* the origin is closed. Defense in depth: closed origin **and** verified assertion.

## Fail-Closed Layering

The proxy authenticates; it must never implicitly authorize. Layer strictly, each step failing closed:

```
1. Verify the Access JWT            -> verified email, or 403
2. Look up the email in YOUR users  -> application user + role, or 403
   store (active users only)
3. Bind role/tenant scope           -> scoped data access, enforced
   server-side                         server-side on every query
```

Rules for the layering:

- **Never trust identity from a request body, query param, or client-set header.** The only identity input is the verified JWT. A `{"email": ...}` field in a POST body is display data at most.
- **Access admitting an email ≠ the email having an account.** Policies are coarse (a whole staff domain, a PIN list that lags reality). The user-store lookup is the fine-grained gate: no active row → 403, regardless of a valid JWT.
- **Roles and scopes live in your database, never in the assertion.** The Access JWT tells you *who*; your `users` table tells you *what they may do*. (Access can forward IdP group claims, but treating those as app roles couples your authorization to dashboard/IdP config — keep authorization in the app.)
- **Enforce scope at the data layer**, not per-handler: resolve `{user, role, tenant}` once in middleware, then have every query go through a repository that is constructed with — and cannot escape — that scope. See `authorization.md` for the RBAC/scoping patterns.

### Auto-provisioning vs explicit user rows

Two workable enrollment models, often combined:

| Model | How | Use for |
|-------|-----|---------|
| **Auto-provision on first login** | A verified email at the org's staff domain with no user row gets a real, **audited** user row created on first request (e.g. as an admin of their tenant) | Staff — the IdP domain is the trust anchor; removes a bootstrap/onboarding step |
| **Explicit rows for everyone else** | External emails (OTP policies) must be pre-created by an admin; unknown email → 403 | Partners, clients, contractors — OTP proves mailbox control, nothing more |

If you auto-provision, gate it on the *IdP-backed* staff domain only (never on OTP logins), write an audit record for the provisioning event, and create a real row — don't synthesize a virtual admin per request.

## Service Auth and Bypass: Non-Human Routes

Webhooks, ingest endpoints, and machine callers can't complete a human login. They need to pass the edge *and* skip your session/JWT middleware — two separate allowances that must both be made deliberately:

**At the edge**, add a separate Access application (or path-scoped app) for the machine path, e.g. `app.example.com/webhooks/*`, with one of:

| Policy type | Mechanism | Use when |
|-------------|-----------|----------|
| **Service Auth** | Caller presents Access **service token** headers (`CF-Access-Client-Id` / `CF-Access-Client-Secret`); Access validates them and still issues a (non-identity) JWT | The caller is yours to configure — internal services, partner systems that can send custom headers |
| **Bypass** | Access waves the route through entirely (optionally restricted by IP) | Third-party webhook senders you can't give headers to (Stripe, GitHub) — their signature scheme is then the only gate |

**At the origin**, mount bearer-token routes **outside** the human-auth middleware — not as an `if` inside it:

```
/api/*        -> Access JWT middleware -> user lookup -> scoped handlers
/webhooks/*   -> bearer-key check      -> pinned-scope handlers   (never sees JWT middleware)
/ingest/*     -> bearer-key check      -> pinned-scope handlers
/health       -> unauthenticated       (the only fully open route)
```

The bearer key is the real gate on these routes — treat it accordingly:

- Long random secrets, stored hashed or in the platform secret store, rotatable.
- Constant-time comparison.
- Pin each key to a scope/tenant server-side (e.g. `tenantId:key` — a request whose body claims a different tenant than its key is rejected).
- For third-party webhooks behind a Bypass policy, verify the sender's HMAC signature (Stripe-Signature etc.) — Bypass means the edge does nothing for you.

Keeping machine routes outside `/api/*` (rather than exempting paths inside the middleware) makes the security model auditable: the route table *is* the policy.

## The Local-Dev Problem

Only the real Access edge injects `Cf-Access-Jwt-Assertion`. `wrangler dev` / `vite dev` on localhost never sees the header, so with a fail-closed origin, local UI work gets a 403 wall. Two legitimate solutions, one trap:

| Approach | How | Trade-off |
|----------|-----|-----------|
| **Tunnel behind Access** | `cloudflared` tunnel from a dev hostname (in the Zero Trust dashboard) to localhost; put an Access app + policy on the dev hostname | Real end-to-end auth, real header; needs dashboard setup and a login per session |
| **Deliberate auth stub** | A dev-only middleware branch takes the identity from a local env var (e.g. `DEV_AUTH_EMAIL` in a gitignored `.dev.vars`) instead of a JWT | Fast; must be *structurally* incapable of shipping (see below) |
| ~~Disable the check~~ | `if (env.SKIP_AUTH) return next()` | **Never.** A boolean that turns auth off is one bad deploy away from an open production origin |

A stub that can't ship is **doubly gated** and changes nothing downstream:

1. Active only when the dev env var is set — and the var lives in a gitignored local file, never in deployed secrets/vars.
2. Active only when the request hostname is loopback (or another hostname no deployed instance can be reached on) — so even a leaked var is inert in production.
3. It substitutes the *identity input only*: the stubbed email still goes through the same user lookup, role binding, and scoping as a verified JWT. It can assume an existing user, never mint one (exclude it from auto-provisioning).
4. Pin it with a test asserting it is inert when the gates are absent.

## OTP vs IdP Policies

| | IdP login (Google, Entra, SAML) | One-time PIN (email OTP) |
|---|---|---|
| Proves | Account in an org directory (+ the IdP's own MFA/device posture) | Control of a mailbox, at that moment |
| Provisioning | None beyond the include rule (domain/group) | Someone must list the emails in the policy *and* usually in your user store |
| Offboarding | Automatic — IdP account disabled → login dies | Manual — remove from policy and user store; the mailbox outlives the relationship |
| Assurance | Higher (org-managed identity) | Lower (mailbox compromise = access) |
| Fit | Staff, anyone in your directory | External counterparties too few/transient to federate |
| Privileges | Can justify elevated roles, auto-provisioning | Least privilege; never auto-provision from OTP |

Mixed audiences on one app is normal: an IdP Allow policy for staff plus an OTP Allow policy enumerating externals. Keep the *role ceiling* of OTP identities low in your app-level authorization regardless of what the edge admits.

## Common Gotchas

| Gotcha | Why It's Dangerous | Fix |
|--------|--------------------|-----|
| Trusting `Cf-Access-Authenticated-User-Email` (or any plain identity header) without JWT verification | Headers are attacker-settable on any unproxied path | Verify `Cf-Access-Jwt-Assertion` cryptographically; ignore the convenience headers |
| `workers_dev` left `true` (or origin IP reachable) | An unproxied origin exists — forged headers, no Access at all | `workers_dev = false`; firewall/tunnel non-Workers origins to the proxy only |
| Validating signature but not `aud` | A valid token for *another* app on your team opens this one | Verify the per-application AUD tag, resolved per hostname |
| Validating signature but not `iss` | A token from a different Access tenant could pass | Pin issuer to `https://<your-team-domain>` |
| Fetching the JWKS on every request | Latency + hard availability dependency on the certs endpoint | Cache per process/isolate; refetch on unknown `kid` |
| No `kid`-triggered refetch | Access key rotation → spurious 403 storm until cache expiry | Use jose's `createRemoteJWKSet` (does this) or replicate the behaviour |
| Treating an Access-admitted email as an authorized user | Policies are coarse; ex-partners linger in PIN lists | App-level user lookup is mandatory; no row → 403 |
| Bypass/Service-Auth path with a weak or unpinned bearer key | The edge is open there; the key is the only gate | Long random keys, hashed at rest, constant-time compare, tenant-pinned |
| Webhook route inside the session middleware with an exemption flag | Exemption logic rots; one refactor away from exposed | Mount machine routes structurally outside the human-auth middleware |
| `SKIP_AUTH`-style dev flag | Ships to production eventually | Doubly gated dev stub (env var in gitignored file + loopback-only hostname), pinned by a test |
| Auto-provisioning users from OTP logins | Mailbox control alone mints an account | Auto-provision only from IdP-backed staff-domain emails, audited |
| Case-sensitive email matching | Same person, two identities; lookup misses | Canonicalize (trim + lower-case) before every lookup and store |

## See Also

- `jwt-sessions.md` — JWT structure, claims, and verification fundamentals
- `authorization.md` — RBAC/tenant scoping to layer on top of the verified identity
- `better-auth.md` — when you own the login flow instead of delegating it to a proxy
- **cloudflare-ops** skill — Workers runtime, wrangler config, secrets, deploy mechanics
