# Runtime Adapters — Node, Bun, Deno Deltas (and Porting Off Workers)

Hono's core is Web-standard `Request`/`Response`, so routes, middleware,
validation, errors, and RPC are portable verbatim. Everything that differs
lives at the edges: how the server starts, env access, static files,
WebSockets, and the platform services Workers provides that other runtimes
don't. This file is the delta map, plus a porting checklist.

## Starting the server

```typescript
// Cloudflare Workers (this skill's default)
export default { fetch: app.fetch } satisfies ExportedHandler<Env>;

// Node — the one runtime needing a real adapter package
import { serve } from '@hono/node-server';
serve({ fetch: app.fetch, port: 3000 });

// Bun — Bun.serve speaks fetch natively
export default { port: 3000, fetch: app.fetch };

// Deno
Deno.serve({ port: 3000 }, app.fetch);
```

Node's adapter translates Node's `IncomingMessage`/`ServerResponse` to Web
`Request`/`Response`; Node 18+ required. Bun and Deno need no translation.

## The per-runtime seams

| Concern | Workers | Node | Bun | Deno |
|---|---|---|---|---|
| Env/config | `c.env` bindings | `process.env` | `process.env` / `Bun.env` | `Deno.env` |
| Static files | assets binding (workers-runtime.md) | `serveStatic` from `@hono/node-server/serve-static` | `serveStatic` from `hono/bun` | `serveStatic` from `hono/deno` |
| WebSockets | `upgradeWebSocket` from `hono/cloudflare-workers` (or a DO) | `@hono/node-ws` (`createNodeWebSocket` + `injectWebSocket` on the server) | `createBunWebSocket` from `hono/bun` (pass its `websocket` to `Bun.serve`) | `upgradeWebSocket` from `hono/deno` |
| Cron | `scheduled()` handler | system cron / node-cron / your scheduler | same as Node | `Deno.cron` |
| Post-response work | `ctx.waitUntil` | just don't await (process persists) | same | same |
| `caches` API | per-colo cache | absent — in-memory LRU / Redis | absent | partial (`caches` exists on Deploy) |
| Install | `npm i hono` | `npm i hono @hono/node-server` | `bun add hono` | JSR: `deno add jsr:@hono/hono` |

Two `hono/adapter` helpers keep shared code honest:

```typescript
import { env, getRuntimeKey } from 'hono/adapter';

const key = env<{ API_KEY: string }>(c).API_KEY;  // reads c.env OR process.env OR Deno.env
getRuntimeKey();                                   // 'workerd' | 'node' | 'bun' | 'deno' | ...
```

Use `env(c)` in any middleware you intend to publish or reuse across runtimes;
keep runtime branching (`getRuntimeKey()`) out of route handlers — isolate it
in the composition root or an adapter module, or portability rots one `if` at
a time.

## Porting a Workers app to Node (the common direction)

1. **Bindings → constructed dependencies.** `c.env.DB`/`c.env.FILES` have no
   Node equivalent; construct clients (Postgres/SQLite driver, S3 client) at
   boot and hand them to the app — a `createApp(deps)` factory that `c.set`s
   them in a first middleware is the least-invasive shape, and it makes the
   Workers build cleaner too.
2. **`ASSETS.fetch` catch-all → `serveStatic`.** Replace the SPA fallback pair
   with `serveStatic({ root: './web/dist' })` + a `serveStatic({ path: 'index.html' })`
   fallback. Keep the JSON-404-for-`/api/*` route — that split is
   runtime-independent.
3. **`waitUntil` → fire-and-forget or a queue.** On Node the process outlives
   the response, so `void promise.catch(log)` works; anything needing
   guaranteed delivery was queue-shaped on Workers anyway.
4. **`scheduled()` → a scheduler.** The cron branches become named jobs
   invoked by node-cron/systemd — keep them as the same exported functions the
   Workers `scheduled()` dispatcher called, and only the dispatcher changes.
5. **Per-colo `caches` → explicit cache.** An in-memory LRU reproduces the
   per-instance semantics honestly; Redis upgrades it to shared.
6. **Re-run the same tests.** `app.request()` tests are runtime-neutral;
   only the pool-workers suite (real bindings) needs a Node-side equivalent
   for whatever replaced the bindings.

Porting *to* Workers reverses the list — the usual sticking points are
long-lived sockets (→ Durable Objects, durable-objects.md), filesystem access
(→ R2/KV), and unbounded background work (→ queues + `waitUntil`).

## Bun/Deno notes worth knowing

- **Bun:** `bun test` runs `app.request()` suites directly and fast; Vitest
  also works. `createBunWebSocket` returns both the middleware and the
  `websocket` handler object you must pass to `Bun.serve` — forgetting the
  second half compiles and then 500s on upgrade.
- **Deno:** import Hono from JSR (`jsr:@hono/hono`), not the npm shim, for
  first-class types; permissions apply (`--allow-net`, `--allow-env`) — a
  middleware reading env without `--allow-env` throws at request time, not
  boot.
- Both runtimes run the same `app.request()` test suites unchanged — which is
  the practical payoff of keeping runtime branching out of handlers.
