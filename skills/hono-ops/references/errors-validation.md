# Errors and Validation — onError, Typed Errors, the 404 Split, Boundary Validation

One error boundary, typed error classes, a deliberate 404 strategy, and the
zValidator-vs-hand-rolled decision for request validation.

## Typed error classes → one `onError` mapping

Domain code (data layer, integrations) throws typed errors; the HTTP layer maps
them in exactly one place. Handlers stay thin and no layer needs to know HTTP.

```typescript
// errors.ts — the app's error vocabulary
export class AppError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message); this.name = 'AppError';
  }
}
export const NotFound   = (m = 'not found')   => new AppError(404, 'not_found', m);
export const Forbidden  = (m = 'forbidden')   => new AppError(403, 'forbidden', m);
export const BadRequest = (m = 'bad request') => new AppError(400, 'bad_request', m);
export const Conflict   = (m = 'version conflict, reload and retry') => new AppError(409, 'conflict', m);
```

Design notes:

- **`code` is the machine field, `message` the human one.** Clients branch on
  `code`; never make them parse prose.
- **Mint a distinct code when the client's next action differs.** A retryable
  409 ("reload and retry") and a non-retryable 409 ("this needs manual
  reconciliation") deserve different codes even at the same status — the code
  tells the caller *what to do*, the status tells proxies what happened.
- **Factory functions with default messages** (`NotFound()`) keep call sites
  one-word cheap, which is what makes people actually throw typed errors.
- **Cross-scope reads throw NotFound, not Forbidden.** A 403 on someone else's
  row confirms it exists; 404 doesn't leak existence.

```typescript
app.onError((err, c) => {
  if (err instanceof AppError)       return c.json({ error: err.code, message: err.message }, err.status as 400);
  if (err instanceof AuthError)      return c.json({ error: 'forbidden' }, 403);
  if (err instanceof SyntaxError)    return c.json({ error: 'bad_request', message: 'invalid JSON body' }, 400);
  if (err instanceof UpstreamError && err.code === 'not_configured') {
    return c.json({ error: 'not_configured', message: err.message }, 503);
  }
  console.error('unhandled error', err);     // full detail to logs
  return c.json({ error: 'internal' }, 500); // generic to the wire — never leak stack/message
});
```

- The `err.status as 400` cast satisfies Hono's `StatusCode`-literal typing when
  status is a runtime number; the class constructor is the real guard.
- `SyntaxError` is what an unhandled `await c.req.json()` throws on a malformed
  body — mapping it here turns garbage bodies into a clean 400 for every route
  that didn't bother to `.catch`.
- Map upstream/integration error types by *their* codes to statuses that tell the
  truth: `not_configured` → 503, upstream validation refusal → 422, upstream
  rate-limit → 429, upstream broke → 502.
- Hono also has `HTTPException` (`hono/http-exception`); its `onError` case is
  `err instanceof HTTPException ? err.getResponse() : …`. Prefer your own
  `AppError` vocabulary for domain errors — `HTTPException` couples domain code
  to HTTP and carries no machine `code` field.

## The 404 split: JSON for the API, shell for the SPA

With a SPA served from the same Worker, "not found" means two different things:

```typescript
// After all real routes/mounts:
app.all('/api/*', (c) => c.json({ error: 'not_found' }, 404));   // API typo → JSON 404
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));              // anything else → SPA
```

- Without the explicit `/api/*` 404, a fat-fingered API path falls through to the
  SPA catch-all and returns `index.html` with a 200 — the client then fails on
  `res.json()` three layers away from the actual bug.
- `app.notFound(handler)` only fires when nothing matched; a `*` catch-all means
  nothing is ever unmatched, so it's dead code in this topology. Use the explicit
  route pair.
- Order: the `/api/*` 404 goes after every API mount, and the `*` catch-all is
  the last route in the file.

## Validation at the HTTP boundary

Two viable approaches; pick per-app, not per-route (consistency is a feature).

### Schema middleware: `@hono/zod-validator`

```typescript
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';

const CreateUser = z.object({ email: z.email(), role: z.enum(['admin', 'user']) });

app.post('/api/users', zValidator('json', CreateUser), async (c) => {
  const body = c.req.valid('json');   // fully typed, already validated
  …
});
```

- Targets: `json`, `query`, `param`, `header`, `form`, `cookie`.
- Invalid input → automatic 400 with Zod's error structure; customise the
  response shape with the third `(result, c) => …` hook argument — do this
  once in a wrapped helper so your error envelope (`{ error, message }`) stays
  consistent with `onError`'s.
- `c.req.valid('json')` is the *only* typed accessor; `await c.req.json()` in
  the same handler bypasses validation entirely.
- Valibot/ArkType/effect equivalents exist (`@hono/valibot-validator`, …) —
  same shape; valibot's tree-shaken bundle is materially smaller, which matters
  at Workers' bundle-size limits.

### Hand-rolled: tolerant parse + explicit assertions

```typescript
// Parse failure degrades to {} — the explicit checks below produce the 400s.
const body = await c.req.json<{ email?: string }>().catch(() => ({}) as { email?: string });
if (!body.email) return c.json({ error: 'bad_request', message: 'email is required' }, 400);

// Shared assertion helpers for recurring shapes:
const date = assertDateString(body.date, 'date');   // throws BadRequest('date must be YYYY-MM-DD')
```

The `.catch(() => ({}))` idiom means a malformed body and a missing field take
the same, deliberate 400 path (with your envelope), rather than a `SyntaxError`
surfacing through `onError`.

### Trade-offs

| | zValidator (schema middleware) | Hand-rolled assertions |
|---|---|---|
| Types | Inferred from schema — payload type and validation can't drift | `c.req.json<T>()` is a **cast, not a check** — T drifts from reality silently |
| Error shape | Zod's, unless you customise the hook everywhere | Yours by construction, consistent with `onError` |
| Deps / bundle | zod (or valibot) in the Worker bundle | Zero |
| Cross-field / DB-dependent rules | Awkward — lands in the handler anyway | Same place as everything else |
| RPC | Required — `hc` derives input types from validators (rpc-clients.md) | No input typing on the client |
| Best for | Broad CRUD surfaces, RPC apps, teams | Small/hot Workers, apps whose real invariants are enforced in the data layer |

The honest middle: schema-validate the *shape* at the boundary, keep *business*
invariants (version checks, scoping, state-machine rules) in the domain layer
throwing typed errors. Never let a schema pass for authorization — identity
comes from verified credentials (middleware.md), not from a validated body.
