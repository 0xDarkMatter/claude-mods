# RPC and Typed Clients — hc vs Hand-Rolled

Hono ships an end-to-end typed client (`hc`). It is excellent for the apps it
fits and quietly costly for the ones it doesn't. This file covers how it works,
the inference rules that bite, and when a hand-rolled typed client is the
better engineering call.

## The RPC mechanism

Server: export the *type* of your routes. Client: `hc<AppType>` derives a typed
call surface from it — paths, params, validated inputs, and JSON output types.

```typescript
// server.ts
import { Hono } from 'hono';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';

// CHAINED definition — the inference requirement (see below)
const app = new Hono()
  .get('/posts/:id', (c) => c.json({ post: { id: c.req.param('id'), title: 't' } }))
  .post('/posts', zValidator('json', z.object({ title: z.string() })), (c) => {
    const body = c.req.valid('json');
    return c.json({ ok: true, title: body.title }, 201);
  });

export type AppType = typeof app;   // types only cross the boundary
export default app;
```

```typescript
// client.ts
import { hc } from 'hono/client';
import type { AppType } from './server';

const client = hc<AppType>('https://api.example.com');

const res = await client.posts[':id'].$get({ param: { id: '123' } });
if (res.ok) {
  const data = await res.json();   // typed: { post: { id: string, title: string } }
}
await client.posts.$post({ json: { title: 'hello' } });   // input typed from the validator
```

Key mechanics:

- **Input types come from validator middleware.** No `zValidator` (or peer) on a
  route → `$post({ json })` is untyped. RPC and schema validation are a package
  deal (errors-validation.md).
- **Output types come from `c.json(...)` inference**, per status code.
- `res` is a real `Response` — check `res.ok`/status before `.json()`.
- `hc` accepts a custom `fetch` (pass a Service Binding's fetcher for
  Worker-to-Worker calls, or a test app's `app.request`).

## The inference rules that bite

1. **Routes must be CHAINED for inference.** `const app = new Hono().get(...).post(...)`
   captures route types in `typeof app`; separate `app.get(...)` statements
   return types that are never accumulated. A file refactor from chained to
   statement style silently degrades the client to `unknown` — guard the shape
   with a comment at the definition site.
2. **Sub-apps compose via chained `.route()`:**
   `const routes = app.route('/posts', posts).route('/users', users);
   export type AppType = typeof routes;` — same chaining rule, one exported type.
3. **Compile-time cost grows with the surface.** Tens of routes with inferred
   unions can make tsc/editor latency real. Mitigations: split clients per
   sub-app (`hc<typeof postsApp>`), or precompute the client type once
   (`type Client = ReturnType<typeof hc<AppType>>`) and reuse it.
4. **The client imports server types** — the client build must resolve the
   server's TypeScript (monorepo path aliases, project references, or a
   published types package). Type-only imports (`import type`) keep server
   *code* out of the client bundle, but the *type graph* still has to compile
   in the client's tsconfig.

## When a hand-rolled typed client is the better call

`hc` optimizes for "the server's inferred types ARE the contract." That's wrong
for some real apps:

- **The wire contract is curated, not inferred.** When responses pass through a
  serialization boundary (presenters that strip admin-only fields per role), the
  honest client type is the *presented* shape, which inference can't see —
  `c.json(present(row, isAdmin))` infers the union, not the per-role reality.
- **No validator middleware** (hand-rolled validation) → no input typing from
  `hc` anyway, which removes half its value.
- **Statement-style route registration** across a large composition root
  (middleware boundaries, conditional mounts) — restructuring 100+ routes into
  chained style to please inference is the tail wagging the dog.
- **Client and server deliberately decoupled** (separate repos/builds, or a
  public API where the contract is versioned prose/OpenAPI, not your source).

The hand-rolled pattern that scales:

```typescript
// web/src/api/types.ts — the wire contract, stated explicitly (shared file or
// copied deliberately; drift is caught by wire-level tests, not the compiler)
export interface Commission { id: string; period: string; status: CommissionStatus; … }

// web/src/api/client.ts — one tiny fetch wrapper + named functions
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`/api${path}`, { headers: { 'content-type': 'application/json' }, ...init });
  if (!res.ok) throw await toApiError(res);   // parse { error, message } envelope
  return res.json() as Promise<T>;
}

export const getCommissions = (q?: { period?: string }) =>
  request<{ commissions: Commission[] }>(`/commissions${qs(q)}`);
export const settleCommission = (id: string, body: SettleInput) =>
  request<{ commission: Commission }>(`/commissions/${id}/settle`, { method: 'POST', body: JSON.stringify(body) });
```

Pair it with **wire-level contract tests** on the server (assert the exact field
set a non-privileged role receives from the real route) — that's the drift
tripwire the compiler was providing, moved to where the curated contract
actually lives.

## Decision table

| Signal | Use `hc` RPC | Hand-roll |
|---|---|---|
| Validation | zValidator/peer on every route | Hand-rolled assertions |
| Route style | Chained (or willing to be) | Statement-style composition root |
| Response shaping | `c.json` output IS the contract | Presenter/role-based field stripping |
| Repo layout | Monorepo, shared tsconfig | Separate builds/repos, versioned contract |
| Surface size | Small–medium, or split per sub-app | Very large, latency-sensitive tsc |
| Consumers | Your own TS frontend | Multiple/external/non-TS consumers |

Middle path: use `hc` for an *internal* sub-app that fits (chained, validated),
hand-roll the curated public surface. Nothing forces one client for the whole
Worker.
