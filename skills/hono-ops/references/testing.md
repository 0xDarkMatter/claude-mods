# Testing — app.request, vitest-pool-workers, Middleware Isolation

Hono apps are directly invokable — no server, no port. This file covers unit
calls, the full vitest-pool-workers setup (real bindings inside workerd), an
auth-harness pattern for JWT-protected apps, and testing middleware alone.

## `app.request()` / `app.fetch()` — the unit seam

```typescript
// Simple: path + RequestInit + env (the Bindings object)
const res = await app.request('/api/health', {}, env);
expect(res.status).toBe(200);
await expect(res.json()).resolves.toEqual({ ok: true });

// Full control (method, headers, host — needed when auth branches on hostname):
const res2 = await app.fetch(
  new Request('https://app.example.com/api/me', {
    method: 'GET',
    headers: { 'authorization': `Bearer ${key}` },
  }),
  env,
);
```

- The third argument is `c.env` — pass real bindings (pool-workers) or a
  hand-built stub for pure-logic tests.
- `app.fetch(new Request(...))` whenever the URL matters: host-based tenancy,
  absolute-URL parsing, cookies (set a `cookie` header).
- These run the *entire* pipeline — middleware, routing, `onError` — so a test
  asserting a 403 is testing the real boundary, not a mock of it.
- Sub-apps are apps: `timeApi.request('/entries', {}, env)` exercises a feature
  app mount-relative, without the parent's middleware (useful for isolating
  behaviour; not a substitute for at least some through-the-parent tests, since
  the parent's middleware sets the context the sub-app assumes).

## vitest-pool-workers: real bindings inside workerd

`@cloudflare/vitest-pool-workers` runs the test file *inside* the Workers
runtime, with real D1/KV/R2/DO bindings. (A ready-to-adapt copy of the config
below ships as this skill's `assets/vitest.config.template.ts`.)

```typescript
// vitest.config.ts
import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';

export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations('./migrations');
  return {
    test: {
      include: ['test/**/*.test.ts'],
      // Exclude sibling worktrees: .claude/worktrees/* carry their own stale copy
      // of test/ + migrations/ and would double-count / fail this run.
      exclude: ['**/node_modules/**', '**/.claude/**', 'web/**'],
      setupFiles: ['./test/apply-migrations.ts'],
      poolOptions: {
        workers: {
          singleWorker: true,        // one workerd for the suite (faster, shared module state)
          isolatedStorage: true,     // per-TEST-FILE storage; writes don't leak across files
          miniflare: {
            compatibilityDate: '2024-12-01',
            compatibilityFlags: ['nodejs_compat'],
            d1Databases: { DB: 'my-app-test' },
            bindings: {
              TEST_MIGRATIONS: migrations,      // handed to the setup file
              SOME_CONFIG_VAR: 'test-value',    // plain-var bindings for the suite
            },
          },
        },
      },
    },
  };
});
```

```typescript
// test/apply-migrations.ts — run the REAL migrations so tests hit the same
// schema (and CHECK constraints) as production.
import { applyD1Migrations, env } from 'cloudflare:test';
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
```

```typescript
// In tests: `env` is the typed binding set from the config above.
import { env } from 'cloudflare:test';
import { app } from '../src/index';

const res = await app.request('/api/things', {}, { ...env, EXTRA_VAR: 'per-suite override' });
```

Notes:

- Type `env` by declaring `interface ProvidedEnv extends Env {}` in a
  `test/env.d.ts` (`declare module 'cloudflare:test'`).
- Spread-and-override (`{ ...env, KEY: 'x' }`) is the idiom for per-test env
  variation — bindings are just an object at this seam.
- `isolatedStorage` isolation is per test *file*; within a file, use
  `beforeEach` re-seeding for a known DB state.
- **workerd version lag:** the local workerd that pool-workers ships is pinned
  by your `wrangler`/pool-workers package version and can trail (or lead) the
  deployed runtime. Behaviour keyed to `compatibilityDate` matches; brand-new
  runtime features/fixes may not. Keep the config's `compatibilityDate` equal to
  wrangler config's, update the toolchain deliberately, and treat "passes local,
  fails deployed" as a version-skew suspect.
- Cron handlers: pool-workers can't fire real cron; call the export directly —
  `worker.scheduled({ cron: '*/5 * * * *' } as ScheduledController, env, ctx)`
  with a stub `ctx` collecting `waitUntil` promises you then `await`.

## Auth harness: testing behind JWT verification

For an app whose middleware verifies JWTs against a remote JWKS, generate a
throwaway keypair in the suite and intercept the JWKS fetch:

```typescript
// test/access-harness.ts (pattern)
import { SignJWT, exportJWK, generateKeyPair, importJWK } from 'jose';

// 1. beforeAll: generate an RS256 keypair (+ a mismatched "bad" key for
//    negative tests) and build a JWKS from the public key.
// 2. Patch globalThis.fetch: requests to the JWKS URL return the test JWKS;
//    everything else passes through to the original fetch. Restore in afterAll.
// 3. signAccessToken(email, { aud, issuer, expOffsetSec, badKey }): a SignJWT
//    helper with correct defaults and overridable claims for negative cases.
```

The payoff is a **negative-auth matrix** against the real app: missing token,
garbage token, wrong audience, wrong issuer, expired, wrong-key signature,
valid-token-but-unknown-user — each asserted to 403 through `app.fetch`. These
tests pin the security boundary at the wire, where it actually holds; a
repo-layer test can pass while a route leaks.

If the platform verifies for you in production (e.g. Cloudflare Access in front),
your middleware must *still* verify — the harness proves it does.

## Testing middleware in isolation

Mount just the middleware on a throwaway app with a probe route:

```typescript
import { Hono } from 'hono';
import { securityHeaders } from '../src/http/security-headers';

function harness() {
  const app = new Hono();
  app.use('*', securityHeaders());
  app.get('/probe', (c) => c.json({ ok: true }));
  app.get('/custom', (c) => {
    const res = c.json({ ok: true });
    res.headers.set('x-frame-options', 'SAMEORIGIN');   // route-owned header
    return res;
  });
  return app;
}

it('fills missing security headers', async () => {
  const res = await harness().request('/probe');
  expect(res.headers.get('x-content-type-options')).toBe('nosniff');
});

it('preserves route-owned headers', async () => {
  const res = await harness().request('/custom');
  expect(res.headers.get('x-frame-options')).toBe('SAMEORIGIN');
});
```

This is the right level for ordering/onion behaviour (inbound vs outbound,
short-circuits, header merging). Auth middleware is the exception: test it
through the real composed app (above), because its job *is* the composition.

## What to test at which level

| Level | Seam | Use for |
|---|---|---|
| Pure function | direct call | presenters/serializers, error mapping helpers, validators |
| Middleware harness | tiny Hono + probe routes | onion behaviour, header policy, bearer compare |
| Sub-app | `subApp.request()` | feature routes with stubbed context/bindings |
| Composed app | `app.fetch(new Request, env)` | auth matrix, 404 split, mount topology, wire-level field visibility |
| Composed app + real bindings | pool-workers `env` | anything touching D1/KV/R2; migration-schema fidelity |
