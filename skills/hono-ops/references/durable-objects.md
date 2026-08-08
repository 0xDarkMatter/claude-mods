# Durable Objects + Hono — Per-Object Apps, WebSockets, Alarms

A Durable Object gives one addressable, single-threaded instance with durable
storage — the coordination primitive Workers lack. Hono composes with DOs in
two directions: the main Worker's Hono app *routes into* DOs, and a DO can run
*its own* Hono app for its HTTP surface.

## Routing into a DO from the main app

```typescript
interface Env { ROOM: DurableObjectNamespace }

// Resolve the object id from a stable name (tenant, room, document id) that
// the AUTH MIDDLEWARE verified — never from raw client input, or one caller
// can address another's object.
app.all('/api/rooms/:room/*', (c) => {
  const identity = c.get('identity');
  const id = c.env.ROOM.idFromName(`${identity.tenantId}:${c.req.param('room')}`);
  return c.env.ROOM.get(id).fetch(c.req.raw);   // forward the original request
});
```

- The parent app's middleware (auth, headers) has already run — the DO receives
  a request the boundary vetted. Pass verified identity explicitly (a header
  you set, or rewrite the URL) rather than re-verifying inside every object.
- `idFromName` is deterministic — same name, same object, globally. That's the
  whole coordination model: pick the name so that everything that must agree
  routes to one object (a room, a tenant's rate limiter, a document).

## A Hono app inside the DO

```typescript
import { DurableObject } from 'cloudflare:workers';
import { Hono } from 'hono';

export class Room extends DurableObject<Env> {
  private app = new Hono();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Routes close over `this` — each object instance gets its own app bound
    // to its own storage. Paths are the FULL path as forwarded by the parent.
    this.app.get('/api/rooms/:room/state', async (c) =>
      c.json({ members: await this.ctx.storage.get<string[]>('members') ?? [] }));

    this.app.get('/api/rooms/:room/ws', (c) => {
      const pair = new WebSocketPair();
      // HIBERNATION API — not ws.accept(). The runtime can evict the isolate
      // while sockets stay connected; you stop paying wall-clock for idle rooms.
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    });
  }

  fetch(request: Request) { return this.app.fetch(request); }

  // Hibernation handlers live on the CLASS, not in Hono — a hibernated socket's
  // message may arrive with no Hono request in flight at all.
  webSocketMessage(ws: WebSocket, msg: string | ArrayBuffer) {
    for (const peer of this.ctx.getWebSockets()) peer.send(msg);
  }
  webSocketClose(ws: WebSocket) { /* presence bookkeeping */ }

  // Alarms: the DO-native scheduler (per-object, exact-time — unlike cron).
  async alarm() {
    await this.flushBuffer();
    // Re-arm if the loop should continue; a fired alarm does not repeat itself.
    await this.ctx.storage.setAlarm(Date.now() + 60_000);
  }
}
```

What matters in this shape:

- **Hono handles the HTTP surface; the class handles the lifecycle.** Upgrade
  requests, storage reads, and route parsing go through Hono middleware/routes
  as usual. WebSocket *events* and `alarm()` bypass HTTP entirely and must be
  class methods.
- **Bind identity to the socket at upgrade time** (e.g.
  `this.ctx.acceptWebSocket(ws, [identity.userId])` tags — retrievable via
  `ws.deserializeAttachment()`/tags) — after 101 there is no per-message auth.
- **A DO is single-threaded per object.** No two requests interleave mid-await
  surprise-free by default (input gates); use
  `ctx.blockConcurrencyWhile()` in the constructor for must-finish-first init.
  Don't add mutexes — the platform is the mutex.
- **Storage:** `ctx.storage` KV API, or SQLite-backed DOs (`ctx.storage.sql`)
  for relational per-object state — see `sqlite-ops` for the SQL side.

## Hono-in-DO vs plain RPC methods

Modern DOs support direct RPC: public methods on the class, called as
`stub.increment()` from the Worker — no Request/Response at all.

| Signal | Hono app in the DO | RPC methods |
|---|---|---|
| Surface shape | HTTP-shaped (paths, methods, middleware, WS upgrades) | A typed internal API |
| Callers | Forwarded browser requests, several route shapes | Your own Worker code only |
| Middleware reuse | Yes — same middleware idioms as the parent | n/a |
| Ceremony | Request forwarding, path coupling with the parent | Lowest — plain typed calls |

Rule of thumb: forwarding *client* traffic (especially WebSocket upgrades) →
Hono in the DO. Worker-internal coordination (counters, locks, buffers) → RPC
methods, no Hono inside.

## Testing DOs

vitest-pool-workers provisions DO bindings from the config
(`miniflare.durableObjects`). Route into them through the composed app exactly
like production (`app.fetch(new Request('/api/rooms/x/state'), env)`). For
alarm logic, `runDurableObjectAlarm(stub)` from `cloudflare:test` fires a due
alarm deterministically. `isolatedStorage` resets object storage per test file
(testing.md).
