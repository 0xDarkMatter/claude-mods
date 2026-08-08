# Middleware — Ordering, Auth Boundaries, Response Hardening

The middleware layer is where a Hono app's security topology lives. This file
covers the execution model, the auth-middleware pattern that makes handlers
safe by construction, and the two boundary patterns (skip-lists and
outside-the-pattern mounts).

## The execution model (onion + registration order)

```typescript
app.use('*', async (c, next) => {
  // inbound: runs before any matching handler
  await next();
  // outbound: runs after the handler (and after inner middleware) — c.res is set
});
```

- **Registration order is matching order.** For a request, Hono runs every
  middleware whose path pattern matches, in the order registered, then the
  handler. A middleware registered *after* a matching handler does not run for
  it. This is the single most common Hono bug; `route-inventory.py --check`
  (this skill) flags it statically.
- **Returning without `await next()` short-circuits** — that's how auth rejects
  (`return c.json({ error: 'forbidden' }, 403)`).
- **Outbound code sees `c.res`** and may replace it (`c.res = new Response(...)`).
- `try { await next(); } finally { … }` guarantees outbound bookkeeping runs
  even when a handler throws (e.g. persisting a session cookie regardless of
  outcome). Note `onError` produces the response *after* your `finally` runs.

## The auth middleware pattern: verify, then build the request's world

Verify credentials once, then stash everything downstream code needs — identity
AND pre-scoped resources — so handlers physically can't do unscoped work:

```typescript
app.use('/api/*', async (c, next) => {
  if (c.req.path === '/api/health') return next();   // skip-list (see below)

  // 1. Resolve the tenant/context from the request (host, header…)
  const tenant = await findTenantByHost(c.env.DB, new URL(c.req.url).host.toLowerCase());
  if (!tenant?.active) return c.json({ error: 'unknown tenant' }, 404);

  // 2. Verify the credential. Verification failures are typed and mapped to 403 —
  //    never a 500, never a passthrough.
  let user: UserRow | null;
  try {
    user = await resolveCaller(c.req.raw, c.env, tenant);   // JWT verify + user lookup
  } catch (err) {
    if (err instanceof AuthError) return c.json({ error: 'forbidden' }, 403);
    throw err;
  }
  if (!user) return c.json({ error: 'no access for this user' }, 403);

  // 3. Build the verified world into context. Handlers read c.get(...) only.
  c.set('identity', { userId: user.id, tenantId: tenant.id, role: user.role });
  c.set('repo', createScopedRepository(c.env.DB, c.get('identity')));
  await next();
});
```

Why this shape wins:

- **Identity comes from the verified credential, never the request body.** No
  handler ever reads a `tenantId` out of JSON.
- **Handlers get a scoped data layer, not raw bindings.** A handler that only
  has `c.get('repo')` cannot query another tenant even by bug — the scoping
  argument was bound before the handler existed.
- **One place to extend.** Impersonation, read-replica session selection, and
  audit stamping all layer into this middleware without touching handlers.

### JWT verification specifics

Verify signature + issuer + audience, never just decode. With `jose`,
`createRemoteJWKSet` caches the JWKS per isolate and refetches on unknown `kid`,
so key rotation doesn't cause spurious 403s. Cache the JWKS instance in a
module-level `Map` keyed by issuer — module scope survives across requests in a
Workers isolate.

## Boundary pattern 1: skip-lists (exceptions inside the pattern)

One or two public routes inside an otherwise-protected pattern: register the
route before the middleware AND skip it inside (belt + braces — order protects
it today, the skip-list documents intent and survives reordering):

```typescript
app.get('/api/health', (c) => c.json({ ok: true }));       // before auth
app.use('/api/*', async (c, next) => {
  if (c.req.path === '/api/health') return next();          // explicit exception
  …
});
```

Use a skip-list for a *handful* of exact paths. The moment you're pattern-matching
exceptions (`startsWith`, regex), you want pattern 2 instead.

## Boundary pattern 2: mount OUTSIDE the pattern (different auth model)

Machine-to-machine endpoints (a bearer-key read API, an ingest webhook) must not
inherit interactive session auth. Don't exempt them from the session middleware —
mount them on a path the middleware pattern doesn't cover, with their own auth:

```typescript
// Sub-app with its own bearer auth (own file):
export const vesper = new Hono<{ Bindings: VesperEnv; Variables: VesperVars }>();
vesper.use('*', async (c, next) => {
  const auth = c.req.header('authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const keys = (c.env.VESPER_KEYS ?? '').split(',').map((k) => k.trim()).filter(Boolean);
  if (!(token.length > 0 && keys.some((k) => timingSafeEqual(token, k)))) {
    return c.json({ error: 'unauthorized' }, 401);
  }
  // build this surface's own (narrow) context, then:
  await next();
});

// Root: /vesper and /ingest are NOT under /api/*, so session auth never sees them.
app.route('/vesper', vesper);
app.route('/ingest', ingest);
```

Operational notes for this pattern:

- **Accept two comma-separated keys** so rotation is zero-downtime: add the new
  key, roll clients, remove the old.
- **Compare bearer keys in constant time** over a fixed length (XOR-accumulate
  across `max(len(a), len(b))`, fold in the length difference) — an early-return
  string compare leaks prefix length via timing.
- If the Worker sits behind an edge access product (e.g. Cloudflare Access),
  these paths need an explicit bypass/service-auth policy at the edge too — the
  bearer key is the real gate, but the edge must let the request through.
- Give the bearer sub-app its own narrow `Env`/`Vars` types: it needs the DB and
  its keys, not the whole interactive surface.

## Response-hardening middleware (and the immutable-headers trap)

Global outbound middleware that fills in missing security headers:

```typescript
export function securityHeaders(): MiddlewareHandler {
  return async (c, next) => {
    await next();
    // Responses derived from fetch()/ASSETS.fetch have IMMUTABLE headers in the
    // Workers runtime — mutating them in place throws and 500s every page load.
    // Copy into a fresh Headers and hand back a new Response.
    const headers = new Headers(c.res.headers);
    const setIfMissing = (n: string, v: string) => { if (!headers.has(n)) headers.set(n, v); };
    setIfMissing('x-content-type-options', 'nosniff');
    setIfMissing('x-frame-options', 'DENY');
    setIfMissing('referrer-policy', 'no-referrer');
    setIfMissing('strict-transport-security', 'max-age=31536000; includeSubDomains');
    c.res = new Response(c.res.body, { status: c.res.status, statusText: c.res.statusText, headers });
  };
}
app.use('*', securityHeaders());   // registered FIRST = outermost = sees every response
```

- `setIfMissing` (not `set`) preserves route-owned headers — the layer fills
  gaps, it doesn't override decisions.
- Register it first so the SPA fallback's responses pass through it too.
- Roll out CSP as `content-security-policy-report-only` first; enforce after the
  report stream is quiet.

## Built-in middleware worth knowing

Hono ships `hono/cors`, `hono/logger`, `hono/secure-headers`, `hono/etag`,
`hono/compress` (not useful on Workers — the platform compresses),
`hono/bearer-auth`, `hono/jwt`, `hono/cookie` (helpers: `getCookie`/`setCookie`/
`deleteCookie`). Use them for the generic 80%; write your own (as above) when
the behaviour is a product decision (which headers, which auth failure shape) —
a 20-line middleware you fully own beats configuring around a generic one.
