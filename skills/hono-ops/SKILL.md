---
name: hono-ops
description: "Hono on Cloudflare Workers - composition, middleware, typed bindings, validation, RPC, streaming, testing. Use for: hono, hono middleware, app.route, hono rpc, c.env bindings, onError, zValidator, vitest-pool-workers, spa fallback worker."
license: MIT
allowed-tools: "Read Write Bash Grep Glob"
metadata:
  author: claude-mods
  related-skills: "cloudflare-ops, typescript-ops, sqlite-ops, rest-ops, testing-ops, auth-ops"
---

# Hono Operations

Hono on Cloudflare Workers: composing multi-app APIs in one Worker, middleware
discipline, typed errors, validation at the HTTP boundary, SPA co-serving, RPC
clients, and testing under vitest-pool-workers. Patterns here are distilled from a
production multi-tenant Worker (one Hono app, 6+ mounted sub-apps, ~1350 tests).

> Verified against Hono v4 (2026). Hono also runs on Bun/Deno/Node — this skill is
> Workers-first; non-Workers deltas are noted where they matter.

**Staleness check:** `python scripts/check-hono-facts.py --offline` asserts the
version-bearing facts (Hono major, `@hono/zod-validator`,
`@cloudflare/vitest-pool-workers`) are still named in the prose and the dated
currency note above is present; `--live` confirms each package's npm major still
matches. Catalog: `assets/hono-facts.json`.

## Decision Tree

```
What are you doing with Hono?
│
├─ Structuring an app (generics, sub-apps, env typing)
│  └─ Below + references/app-composition.md
│
├─ Middleware (ordering, auth, headers, exclusion boundaries)
│  └─ Below + references/middleware.md
│
├─ Errors / 404s / request validation
│  └─ Below + references/errors-validation.md
│
├─ Path syntax, routers, c.req/c.res surface, cookies
│  └─ references/routing-and-request.md
│
├─ Serving a SPA / static assets from the same Worker
│  └─ references/workers-runtime.md
│
├─ Cron / queues alongside fetch; runtime gotchas
│  └─ references/workers-runtime.md
│
├─ Streaming / SSE / WebSockets / proxying / service bindings
│  └─ references/streaming-and-realtime.md
│
├─ Typed client (hc RPC vs hand-rolled)
│  └─ references/rpc-clients.md
│
├─ Testing (app.request, pool-workers, middleware isolation)
│  └─ references/testing.md
│
├─ Starting a new Worker from scratch
│  └─ assets/worker-template.ts (commented composition-root skeleton)
│
└─ Auditing an existing app's routes / middleware order
   └─ scripts/route-inventory.py (below)
```

## App Composition (the 80%)

Type the app once with `Bindings` (wrangler-provided env) and `Variables`
(per-request context you `c.set`):

```typescript
import { Hono } from 'hono';

interface Env {
  DB: D1Database;
  ASSETS: Fetcher;          // static assets binding (SPA)
  API_KEYS?: string;        // optional secret: gate features on presence, 503 when unset
}
type Vars = { identity: Identity; repo: ScopedRepository };

export const app = new Hono<{ Bindings: Env; Variables: Vars }>();
```

- `c.env.DB` — bindings, typed via `Bindings`.
- `c.set('identity', id)` / `c.get('identity')` / `c.var.identity` — per-request
  state, typed via `Variables`. Middleware writes it; handlers read it.
- Prefer the per-app `Variables` generic over global `ContextVariableMap`
  augmentation; the map is app-wide and leaks types across unrelated sub-apps
  (see [references/app-composition.md](references/app-composition.md)).

**Sub-app mounting** — one Worker, many feature apps, each its own file:

```typescript
// src/time/api.ts
export const timeApi = new Hono<{ Bindings: Env; Variables: Vars }>();
timeApi.get('/entries', (c) => { /* identity + repo already in context */ });

// src/index.ts — mounted under the auth middleware (see Middleware below)
app.route('/api/time', timeApi);       // timeApi sees paths relative to the mount
app.route('/api/time', billingApi);    // two sub-apps on one base is fine when
                                       // their paths are disjoint — Hono matches across both
```

The mounted sub-app inherits nothing implicitly except position: whatever
middleware was registered on a matching path *before* the mount runs first.
Position IS the security boundary — see Middleware.

## Middleware: Order Is the Contract

Hono middleware is an onion — code before `await next()` runs inbound, code
after runs outbound — and **registration order is matching order**. A middleware
registered after a matching handler never runs for it.

```typescript
app.use('*', securityHeaders());        // 1. outermost: response hardening
app.get('/api/health', (c) => c.json({ ok: true }));  // 2. before auth = unauthenticated

app.use('/api/*', async (c, next) => {  // 3. auth: verify, then stash identity
  if (c.req.path === '/api/health') return next();   // skip-list for exceptions
  const user = await verifyAndResolve(c.req.raw, c.env);   // throws/403s on failure
  if (!user) return c.json({ error: 'forbidden' }, 403);
  c.set('identity', user);
  c.set('repo', scopedRepo(c.env.DB, user));  // handlers never touch raw bindings
  await next();
});

app.route('/api/time', timeApi);        // 4. inside the auth boundary
app.route('/vesper', vesper);           // 5. OUTSIDE /api/* — bearer-key auth, on purpose
app.route('/ingest', ingest);           // machine-to-machine, own auth in the sub-app

app.all('/api/*', (c) => c.json({ error: 'not_found' }, 404));  // JSON 404 for API
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));             // SPA fallback, LAST
```

Two load-bearing rules:

1. **Auth middleware verifies, then builds the request's whole world** (identity,
   scoped repo/session) into context. Handlers read `c.get(...)` and can't reach
   unscoped resources by construction.
2. **Routes with a different auth model mount OUTSIDE the middleware's path
   pattern** (`/vesper`, `/ingest/*` above), each carrying its own auth middleware.
   Don't punch exemptions through session auth with flags — move the mount.

Depth (skip-lists vs path shape, security headers + the immutable-headers trap,
timing-safe bearer compare): [references/middleware.md](references/middleware.md).

## Errors: One Typed Boundary

Throw typed errors anywhere below the handler; map them to HTTP in exactly one
place:

```typescript
export class AppError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message); this.name = 'AppError';
  }
}
export const NotFound  = (m = 'not found')  => new AppError(404, 'not_found', m);
export const Forbidden = (m = 'forbidden')  => new AppError(403, 'forbidden', m);
export const Conflict  = (m = 'version conflict, reload and retry') => new AppError(409, 'conflict', m);

app.onError((err, c) => {
  if (err instanceof AppError)    return c.json({ error: err.code, message: err.message }, err.status as 400);
  if (err instanceof SyntaxError) return c.json({ error: 'bad_request', message: 'invalid JSON body' }, 400);
  console.error('unhandled error', err);          // log the real thing…
  return c.json({ error: 'internal' }, 500);      // …never leak it to the wire
});
```

- Cross-scope access returns **404, not 403** — a 403 confirms the row exists in
  someone else's scope.
- Unmatched `/api/*` gets a JSON 404; everything else falls through to the SPA
  shell. Never let an API typo return `index.html`.
- `app.notFound()` exists but only fires when *nothing* matched — with a
  catch-all SPA route it never runs; use the explicit two-route split above.

Validation at the boundary (zValidator vs hand-rolled assertions, and when each
wins): [references/errors-validation.md](references/errors-validation.md).

## Testing Quickstart

`app.request()` / `app.fetch()` run the real app — middleware, routing, errors —
with no server:

```typescript
import { env } from 'cloudflare:test';   // vitest-pool-workers: real bindings
import { app } from '../src/index';

const res = await app.request('/api/health', {}, env);   // env = 3rd arg (Bindings)
expect(res.status).toBe(200);
```

Under `@cloudflare/vitest-pool-workers` the test runs inside workerd with real
D1/KV/R2 bindings from `defineWorkersConfig`. Full setup — migrations into the
test DB, isolated storage, an Access-JWT signing harness, testing one middleware
in isolation, and the workerd-version-lag trap:
[references/testing.md](references/testing.md).

## Route Inventory Script

`scripts/route-inventory.py` statically scans a Hono TypeScript source tree and
lists every route, middleware registration, and `app.route()` mount with
`file:line` — plus `--check`, a middleware-order linter that flags handlers
registered *before* a middleware whose path pattern covers them (those handlers
silently bypass it: the #1 Hono ordering bug).

```bash
# Inventory a Worker's HTTP surface (TSV: kind, method, path, file:line)
python skills/hono-ops/scripts/route-inventory.py src/

# JSON envelope for downstream tooling
python skills/hono-ops/scripts/route-inventory.py --json src/ | jq '.data[] | select(.kind=="mount")'

# Lint middleware ordering: exit 10 = findings (routes that dodge a later middleware)
python skills/hono-ops/scripts/route-inventory.py --check src/
```

Exit codes: `0` clean, `2` usage, `3` path not found, `10` order findings
(`--check`). Regex-based on purpose — it needs no TypeScript compiler API and
works on any checkout.

## Gotchas (Workers-Specific)

| Gotcha | Why | Fix |
|---|---|---|
| "Illegal invocation" on fetch | Calling `this.fetchImpl(...)` binds `this` to your object; global fetch requires no receiver | Detach first: `const doFetch = this.fetchImpl; await doFetch(url, ...)` |
| Mutating `ASSETS.fetch` response headers throws | Any `fetch()`-derived Response has immutable headers in workerd | Rebuild: `new Response(res.body, { status, headers: new Headers(res.headers) })` |
| `caches` API "cache" misses constantly | It's per-colo, not global — every PoP has its own | Treat as a short-TTL local collapse (poll-storm absorber), never as KV |
| `waitUntil` work vanishes | Post-response work must be registered before the handler returns; unregistered promises are cancelled | `c.executionCtx.waitUntil(promise)` inside the handler |
| Middleware doesn't run for a route | Registered after the handler — order is matching order | Register middleware first; verify with `route-inventory.py --check` |
| `wrangler dev` host surprises | Dev rewrites the request host to the `[[routes]]` pattern | Pin `[dev] host` in wrangler config when auth branches on hostname |
| Optional secret unset | Route depends on an env secret that isn't configured | Gate on presence: `if (!c.env.KEY) return c.json({ error: 'unavailable' }, 503)` |

More depth (SPA assets config, `run_worker_first`, scheduled/queue handlers,
per-cron branching): [references/workers-runtime.md](references/workers-runtime.md).

## Reference Files

| Reference | When to Load |
|-----------|-------------|
| [references/app-composition.md](references/app-composition.md) | Generics (`Bindings`/`Variables`), `ContextVariableMap` trade-offs, sub-app mounting semantics, `basePath`, env-shape design |
| [references/middleware.md](references/middleware.md) | Onion model, ordering proofs, auth middleware that builds context, security headers, bearer-auth sub-apps outside the session boundary |
| [references/errors-validation.md](references/errors-validation.md) | `onError` mapping, typed error classes, 404 strategy, zValidator vs hand-rolled validation trade-offs |
| [references/routing-and-request.md](references/routing-and-request.md) | Router internals, path syntax (params/regex/optional/wildcards), matching precedence, `c.req`/response helpers, cookies (incl. signed), JSX/html |
| [references/testing.md](references/testing.md) | `app.request()` patterns, vitest-pool-workers config (D1 migrations, bindings, isolation), JWT test harness, middleware-in-isolation |
| [references/rpc-clients.md](references/rpc-clients.md) | `hc<AppType>` RPC client, chained-route inference requirement, when a hand-rolled typed client is the better call |
| [references/workers-runtime.md](references/workers-runtime.md) | SPA/static assets from one Worker, `scheduled()` + queue handlers beside `fetch`, `waitUntil`, `caches`, detached fetch |
| [references/streaming-and-realtime.md](references/streaming-and-realtime.md) | `stream`/`streamText`/`streamSSE`, WebSockets (plain Worker vs Durable Object hibernation), proxying, service bindings |

**Starter asset:** [assets/worker-template.ts](assets/worker-template.ts) — a
commented composition-root skeleton (typed env, security headers, auth
middleware, bearer sub-app, 404 split, `onError`, cron) with adapt-points
marked. Copy it as the seed of a new Worker; every section cross-refs the
reference that explains it.

## See Also

- `cloudflare-ops` — wrangler config, bindings provisioning, deploy/CI
- `sqlite-ops` — D1 specifics (sessions/bookmarks, batch semantics, query plans)
- `typescript-ops` — generics, Zod 4, type-narrowing the payloads you validate
- `rest-ops` / `api-design-ops` — endpoint and contract design above the framework
- `auth-ops` — JWT/session/token theory behind the auth middleware patterns
