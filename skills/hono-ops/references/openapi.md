# OpenAPI — Documented APIs from Hono Routes

Generating an OpenAPI spec (and interactive docs) from the routes themselves,
so the documentation cannot drift from the implementation. Two libraries, one
decision, and the gotchas.

## `@hono/zod-openapi` — schema-first routes

`OpenAPIHono` replaces `Hono`; each route is declared as a `createRoute` object
carrying its request/response schemas, then bound to a handler:

```typescript
import { OpenAPIHono, createRoute, z } from '@hono/zod-openapi';

const UserSchema = z.object({
  id: z.string().openapi({ example: 'u_123' }),
  name: z.string(),
}).openapi('User');                      // named component in the spec

const getUser = createRoute({
  method: 'get',
  path: '/users/{id}',                   // OpenAPI syntax: {id}, NOT :id
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: { content: { 'application/json': { schema: UserSchema } }, description: 'The user' },
    404: { description: 'Not found' },
  },
});

const app = new OpenAPIHono();
app.openapi(getUser, (c) => {
  const { id } = c.req.valid('param');   // typed + validated, as with zValidator
  return c.json({ id, name: 'Ada' }, 200);   // response is checked against the schema TYPE
});

app.doc('/doc', { openapi: '3.1.0', info: { title: 'My API', version: '1' } });
```

Serve interactive docs beside it:

```typescript
import { swaggerUI } from '@hono/swagger-ui';
app.get('/ui', swaggerUI({ url: '/doc' }));   // or Scalar: @scalar/hono-api-reference
```

The gotchas that cost time:

- **Path syntax flips**: `createRoute` paths use `{id}`; everything else in the
  app still uses `:id`. Mixing them silently 404s.
- **Status codes are part of the contract**: `c.json(body, 200)` must name a
  status declared in `responses`, and the body must match that status's schema
  type — this is the drift-proofing, so don't cast around it.
- **Validation-failure shape** defaults to Zod's; set `defaultHook` on the
  `OpenAPIHono` constructor once to emit your `{ error, message }` envelope
  (keep it consistent with `onError` — errors-validation.md).
- **Auth in docs**: register security schemes via
  `app.openAPIRegistry.registerComponent('securitySchemes', 'Bearer', {...})`
  and reference them per-route with `security` — the docs UI's "Authorize"
  button doesn't exist until you do.
- Sub-apps compose with `.route()` as usual, and `hc` RPC still works —
  `OpenAPIHono` is a superset of `Hono`.

## `hono-openapi` — annotate a plain Hono app

The community `hono-openapi` package takes the opposite approach: keep plain
`Hono` + `zValidator`-style validators, and add a `describeRoute` middleware
per route that contributes spec metadata. Less invasive; the spec is only as
complete as the annotations you remember to write.

## Decision

| Signal | `@hono/zod-openapi` | `hono-openapi` annotations | No OpenAPI |
|---|---|---|---|
| API is a public/partner contract | Best — spec can't drift | OK | — |
| Team consumes docs UI daily | Yes | Yes | — |
| Internal API, TS-only consumers | Overkill — `hc` RPC gives types for free (rpc-clients.md) | Overkill | Right call |
| Existing large plain-Hono app | Costly migration (every route becomes `createRoute`) | Incremental fit | — |
| Hand-rolled validation, curated presenters | Poor fit — schemas ARE the contract here | Poor fit | Right call |

The honest default for an internal Worker consumed by your own SPA is **no
OpenAPI**: the typed client (RPC or hand-rolled + wire tests) is the contract.
Reach for `@hono/zod-openapi` the day an external consumer needs docs — and
then adopt it per sub-app (`app.route('/api/public', publicApi)` where only
`publicApi` is an `OpenAPIHono`), not across the whole Worker at once.
