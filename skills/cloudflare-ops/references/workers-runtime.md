# Workers Runtime — handlers, APIs, patterns, limits

The Workers runtime is **workerd** (open source), running V8 isolates at the edge. It implements web-platform APIs (`Request`/`Response`/`fetch`/`URL`/`crypto.subtle`/streams) — not Node, unless `nodejs_compat` is set. Workers use **ES module** format; the legacy service-worker (`addEventListener("fetch")`) format is deprecated.

## Handlers

```javascript
export default {
  async fetch(request, env, ctx)    { /* HTTP requests */ },
  async scheduled(event, env, ctx)  { /* cron triggers */ },
  async queue(batch, env, ctx)      { /* queue consumer */ },
  async email(message, env, ctx)    { /* Email Workers */ },
  async tail(events, env, ctx)      { /* Tail Worker — traces of another Worker */ },
};
```

- **`env`** — all bindings, vars, secrets.
- **`ctx.waitUntil(p)`** — keep the isolate alive for background work after the response is returned (analytics, cache writes).
- **`ctx.passThroughOnException()`** — on an unhandled error, fall through to origin instead of erroring.

### Scheduled (cron)

```jsonc
{ "triggers": { "crons": ["0 0 * * *", "*/15 * * * *"] } }
```

```javascript
async scheduled(event, env, ctx) {
  ctx.waitUntil(cleanup(env));   // event.cron tells you which schedule fired
}
```

Test locally: `wrangler dev --test-scheduled` then `curl "localhost:8787/__scheduled?cron=0+0+*+*+*"`.

## CORS

```javascript
const CORS = {
  "Access-Control-Allow-Origin": "https://app.example.com",   // prefer an explicit origin over "*"
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};
export default {
  async fetch(request) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    const res = Response.json({ ok: true });
    for (const [k, v] of Object.entries(CORS)) res.headers.set(k, v);
    return res;
  },
};
```

If you send credentials, you cannot use `*` — echo a validated origin and add `Access-Control-Allow-Credentials: true`.

## Cache API

```javascript
async fetch(request, env, ctx) {
  const cache = caches.default;
  let res = await cache.match(request);
  if (!res) {
    res = await fetch(request);
    res = new Response(res.body, res);
    res.headers.set("Cache-Control", "public, max-age=3600");
    ctx.waitUntil(cache.put(request, res.clone()));   // clone — body is single-use
  }
  return res;
}
```

The Cache API is per-colo (not global). For global caching use Cloudflare's CDN/Cache Rules at the zone level, or KV for app-controlled cache.

## Streaming

```javascript
// Stream rather than buffer large bodies
const { readable, writable } = new TransformStream();
streamInto(writable);                       // write chunks asynchronously
return new Response(readable, { headers: { "Content-Type": "application/octet-stream" } });
```

`Response` accepts a `ReadableStream`; stream from R2 (`obj.body`) or `fetch` directly to keep memory flat.

## WebSockets

```javascript
async fetch(request) {
  if (request.headers.get("Upgrade") !== "websocket")
    return new Response("expected websocket", { status: 426 });
  const [client, server] = Object.values(new WebSocketPair());
  server.accept();
  server.addEventListener("message", (e) => server.send(`echo: ${e.data}`));
  return new Response(null, { status: 101, webSocket: client });
}
```

For stateful/multi-client sockets (chat, presence) terminate them in a **Durable Object** and use the **WebSocket Hibernation API** so idle connections don't bill compute.

## Body reuse

Streams are single-use. To read a body twice, `clone()` before the first read:

```javascript
const copy = request.clone();
const text = await request.text();
const json = await copy.json();
```

## Error handling

```javascript
async fetch(request, env, ctx) {
  try {
    return Response.json({ data: await work(env) });
  } catch (err) {
    console.error("worker error", err);   // captured by Workers Logs when observability is on
    return Response.json({ error: err.message }, { status: 500 });
  }
}
```

## Subrequests, timeouts, abort

```javascript
const ctrl = new AbortController();
const t = setTimeout(() => ctrl.abort(), 5000);
try {
  return await fetch(url, { signal: ctrl.signal });
} catch (e) {
  if (e.name === "AbortError") return new Response("upstream timeout", { status: 504 });
  throw e;
} finally { clearTimeout(t); }
```

## Limits (check the live limits page — these move)

| Limit | Free | Paid |
|-------|------|------|
| CPU time / invocation | 10 ms default, configurable | up to **30 s** (raised from the old 50 ms; set via limits config) |
| Script size (gzipped) | 3 MB | 10 MB |
| Subrequests / invocation | 50 | 1000+ |
| Memory | 128 MB | 128 MB |
| Env vars + secrets | bounded | bounded |

- CPU time ≠ wall-clock: awaiting I/O doesn't burn CPU budget; a tight compute loop does and gets killed.
- Configure CPU limit explicitly: `"limits": { "cpu_ms": 50 }` (or higher on paid).

## Node compatibility

`"compatibility_flags": ["nodejs_compat"]` enables a subset of Node built-ins (`node:crypto`, `node:buffer`, `node:async_hooks`, streams, etc.). Not everything is polyfilled — verify the specific module is supported rather than assuming. Many "Node" npm packages work once this flag is on; some assume `fs`/native addons and won't.

## Bundling

Wrangler bundles with esbuild. Pitfalls: CommonJS-only packages, packages that reach for Node natives, and large transitive deps blowing the size limit. Prefer Workers-/edge-labelled libraries; dynamic-import heavy modules so they're only pulled when used; inspect the build output if a deploy is unexpectedly large.
