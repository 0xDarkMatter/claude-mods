# Streaming, SSE, WebSockets, and Worker-to-Worker Calls

Long-lived and incremental responses from a Hono Worker: streamed bodies,
server-sent events, WebSockets (and when a Durable Object must own them), plus
proxying and service-binding calls.

## Streamed responses (`hono/streaming`)

```typescript
import { stream, streamText, streamSSE } from 'hono/streaming';

// Raw bytes — e.g. piping a generated file without buffering it
app.get('/export.csv', (c) =>
  stream(c, async (s) => {
    await s.write(header);
    for await (const row of rows()) await s.write(encode(row));
  }),
);

// Incremental text (LLM token relays, progress logs)
app.post('/api/generate', (c) =>
  streamText(c, async (s) => {
    for await (const chunk of model.generate(prompt)) await s.write(chunk);
  }),
);
```

- The handler returns immediately; the callback keeps writing on the open body.
  Errors mid-stream can't change the status line (it's already sent) — write an
  in-band error sentinel the client understands, and pass an `onError` third
  argument to close cleanly.
- `s.writeln`, `s.sleep`, `s.close`, and `c.req.raw.signal.aborted` /
  `s.onAbort(cb)` cover pacing and client-disconnect cleanup. Check abort in
  long loops — writing to a gone client is wasted CPU time.
- Workers streams responses natively; there's no buffering to disable, but the
  invocation is still bounded by Workers CPU/duration limits — streaming is for
  minutes at most, not persistent connections (that's WebSockets/DO territory).

## Server-sent events

```typescript
app.get('/api/events', (c) =>
  streamSSE(c, async (s) => {
    let id = 0;
    while (!c.req.raw.signal.aborted) {
      const events = await pollSource(c.env);          // or a queue/DO handoff
      for (const e of events) {
        await s.writeSSE({ data: JSON.stringify(e), event: e.type, id: String(++id) });
      }
      await s.sleep(5000);
    }
  }),
);
```

- SSE through a plain Worker is a **poll relay** — each connected client holds
  an invocation open. Fine for admin dashboards (few clients); wrong for fanning
  out to thousands (that's a Durable Object with hibernatable WebSockets, or a
  push service).
- Send a retry hint (`s.writeSSE({ data: '', event: 'ping' })` heartbeats every
  ~30s) so intermediaries don't reap the idle connection.
- `EventSource` can't set headers — cookie auth works, bearer auth doesn't;
  for token auth use a query-string ticket minted by an authenticated call
  (short-lived, single-use), not the long-lived token in the URL.

## WebSockets

Plain Worker upgrade (stateless per-socket, no cross-socket coordination):

```typescript
import { upgradeWebSocket } from 'hono/cloudflare-workers';

app.get('/ws', upgradeWebSocket((c) => ({
  onMessage(evt, ws) { ws.send(`echo ${evt.data}`); },
  onClose() {},
})));
```

Reality check before shipping that:

- A Worker-held socket ties an invocation to the connection and cannot share
  state with other sockets. **Any feature described as "broadcast", "room",
  "presence", or "sync" is a Durable Object feature**: route the upgrade to a
  DO (`c.env.ROOM.get(id).fetch(c.req.raw)`) and use the DO WebSocket API —
  with hibernation (`state.acceptWebSocket(ws)` + `webSocketMessage` handlers)
  so idle sockets don't bill wall-clock duration.
- Auth happens at upgrade time (it's a GET through your normal middleware);
  after upgrade there is no per-message auth — bind identity to the socket at
  accept and treat the connection as a session.
- The `upgradeWebSocket` import is per-runtime (`hono/cloudflare-workers`,
  `hono/deno`, `hono/bun`, `@hono/node-ws`) — one of the few non-portable
  seams; the full per-runtime map is runtime-adapters.md.

## Proxying and Worker-to-Worker (service bindings)

```typescript
// Pass-through proxy of an upstream (rewrite path, forward body/headers):
app.all('/upstream/*', (c) => {
  const url = new URL(c.req.url);
  url.hostname = 'internal.example.com';
  url.pathname = url.pathname.replace(/^\/upstream/, '');
  // New Request from the original: method/headers/body carry over; mutate a COPY
  // of headers (the original's are immutable).
  const headers = new Headers(c.req.raw.headers);
  headers.delete('cookie');                       // never leak session cookies upstream
  return fetch(new Request(url, { method: c.req.method, headers, body: c.req.raw.body }));
});

// Service binding: call another Worker with zero network hop
interface Env { REPORTS: Fetcher }                // [[services]] binding in wrangler config
app.get('/api/report', (c) => c.env.REPORTS.fetch(c.req.raw));
```

- A returned upstream `Response` is streamed through — no buffering — but its
  headers are immutable; rebuild if you must edit (middleware.md).
- Service bindings invoke the target Worker directly (same thread, no egress):
  prefer them over public-URL `fetch` between your own Workers — faster, free of
  DNS/TLS, and the target can trust the caller. An `hc` RPC client accepts a
  binding's fetcher: `hc<AppType>('https://internal', { fetch: c.env.REPORTS.fetch.bind(c.env.REPORTS) })`
  — note the `.bind()`: an unbound method reference throws "Illegal invocation"
  (workers-runtime.md).
- Forwarding `c.req.raw.body` consumes it — a proxy handler can't also read the
  body; decide per route.

## Choosing the mechanism

| Need | Use |
|---|---|
| Incremental one-shot response (LLM tokens, big export) | `stream` / `streamText` |
| Server→client event feed, few clients, reconnect-tolerant | `streamSSE` (+ heartbeat) |
| Bidirectional, or many clients, or shared room state | WebSockets **in a Durable Object** (hibernation) |
| Client polling an expensive read | Plain GET + per-colo `caches` collapse (workers-runtime.md) |
| Worker calling your other Worker | Service binding, not public fetch |
