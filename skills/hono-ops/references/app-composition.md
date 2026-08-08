# App Composition — Typing, Sub-Apps, Mount Semantics

How to structure a Hono app that stays navigable at 6+ feature areas in one
Worker. Companion to SKILL.md's "App Composition" section; this file owns the
depth.

## The generics: `Bindings` and `Variables`

```typescript
import { Hono } from 'hono';

interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  /** Comma-separated bearer keys (two during rotation). Optional: absence
   *  disables the dependent surface (503), it never crashes boot. */
  VESPER_KEYS?: string;
}

type Vars = {
  identity: Identity;        // set by auth middleware
  repo: ScopedRepository;    // set by auth middleware; handlers use ONLY this
};

export const app = new Hono<{ Bindings: Env; Variables: Vars }>();
```

- `Bindings` types `c.env`. Keep the `Env` interface in one place and make
  every optional integration key genuinely optional (`?:`) — the route gates on
  presence and 503s, the cron no-ops. A required key that isn't bound crashes
  every request, not just the feature.
- `Variables` types `c.set` / `c.get` / `c.var`. `c.var.identity` is the
  property-style accessor for `c.get('identity')`.
- Document each env key at its declaration (what it is, whether it's a secret,
  what happens when unset). The `Env` interface is the Worker's configuration
  contract — treat it like one.

### `ContextVariableMap` vs the `Variables` generic

```typescript
// Global augmentation — every Hono instance in the process sees this:
declare module 'hono' {
  interface ContextVariableMap {
    requestId: string;
  }
}
```

| | `Variables` generic | `ContextVariableMap` |
|---|---|---|
| Scope | One app (and sub-apps you type the same) | Every Hono app in the build |
| Fit | App-specific state (identity, repo) | Truly cross-cutting values set by a shared middleware package (request id, logger) |
| Risk | Repeating the type in each sub-app file | Type leakage: unrelated apps "have" variables nothing set |

Default to the generic. Reach for `ContextVariableMap` only when you publish a
middleware whose consumers shouldn't have to thread a generic through.

### Typing middleware helpers

A standalone middleware factory uses `MiddlewareHandler` (optionally with the
same env shape):

```typescript
import type { MiddlewareHandler } from 'hono';

export function securityHeaders(): MiddlewareHandler {
  return async (c, next) => { await next(); /* … */ };
}
```

Use `createMiddleware<{ Bindings: Env; Variables: Vars }>()` (from
`hono/factory`) when the middleware body needs the typed `c.env`/`c.var`.

## Sub-app mounting with `app.route()`

```typescript
// Feature file exports a Hono instance typed with the SAME env shape:
export const timeApi = new Hono<{ Bindings: Env; Variables: Vars }>();
timeApi.get('/entries', (c) => c.json({ entries: [] }));   // path is mount-relative

// Root file mounts it:
app.route('/api/time', timeApi);   // serves GET /api/time/entries
```

Semantics that matter in practice:

- **Paths are mount-relative.** The sub-app never knows its prefix; you can
  remount it elsewhere (or in a test) without edits.
- **Two sub-apps on one base path is legal** — Hono matches across both. Keep
  their route sets disjoint; when they are, registration order between them is
  irrelevant (say so in a comment where you mount them, or the next reader will
  assume order is load-bearing).
- **Mount position decides which middleware applies.** `app.route()` inside a
  `app.use('/api/*', auth)` pattern's coverage runs behind auth; a mount at
  `/vesper` outside it does not. There is no "inherit auth" flag — position is
  the mechanism (see middleware.md).
- **Context typing is by convention.** If the parent's middleware `c.set`s
  `identity`, the sub-app's handlers read it because both declare the same
  `Variables` type. TypeScript won't stop you mounting a sub-app that assumes
  variables no middleware sets — a mount-site comment ("identity + repo already
  set by the /api/* middleware") is the cheap guard, and an integration test
  through the real parent app is the real one (testing.md).

## `basePath`

```typescript
const api = new Hono().basePath('/api');
api.get('/health', …);   // matches /api/health
```

`basePath` bakes the prefix into the app itself; `app.route(prefix, sub)` keeps
the sub-app relocatable. Prefer `route()` for feature composition; use
`basePath` when an entire deployment is served under a prefix (e.g. behind a
gateway that doesn't strip it).

## One composition-root file

Keep every `app.use` / `app.route` / fallback / `onError` registration in one
root file (`src/index.ts`), ordered top-to-bottom as the request flows:

1. Global outbound middleware (security headers)
2. Unauthenticated exceptions (health)
3. Auth middleware for the protected pattern
4. Protected routes + sub-app mounts
5. Alternate-auth mounts (bearer sub-apps) outside the pattern
6. JSON 404 for the API pattern
7. SPA/asset catch-all — always last
8. `app.onError`

A reader (or `route-inventory.py`) can then audit the entire security topology
by reading one file in order. Scattering `app.use` calls across feature files
destroys that property — sub-apps may register their *own* interior middleware,
but boundary middleware belongs to the root.

## Growing to "many apps in one Worker"

The scale pattern (from a production 7-app Worker):

- Each feature = one exported sub-app in its own file/directory
  (`src/time/api.ts`, `src/pulse-api.ts`), typed with the shared `Env`/`Vars`.
- Feature-specific gates (e.g. an app-enabled check, an extra role gate) are
  registered as `app.use('/api/pulse/*', gate)` in the root, directly above that
  mount — visible in the composition root, not hidden in the feature file.
- Sub-apps double-enforce their own authorization (a role check inside the
  sub-app AND the data layer scoping) — mounts move, defence-in-depth survives.
