# Cloudflare Bindings — config + runtime API

A *binding* is a capability injected into `env` at runtime. You declare it in `wrangler.jsonc`; the runtime hands you a live client. All config snippets are jsonc; the TOML form is a mechanical translation (`kv_namespaces` → `[[kv_namespaces]]`, nested objects → `[table]`).

Verified 2026-06 against developers.cloudflare.com/workers/wrangler/configuration.

## Quick chooser

| Need | Binding |
|------|---------|
| Global cache / config, read-heavy, writes rare | **KV** |
| Relational data, SQL, joins | **D1** |
| Files / blobs / media, no egress fee | **R2** |
| Strong consistency, coordination, realtime state | **Durable Objects** |
| Background jobs, batching, retries | **Queues** |
| Existing external Postgres/MySQL | **Hyperdrive** |
| Model inference (LLM/embeddings/image) | **Workers AI** |
| Vector search / RAG | **Vectorize** |
| Worker-to-Worker RPC | **Service binding** |
| Custom metrics | **Analytics Engine** |
| Static files | **Assets** |

---

## KV — eventually-consistent key-value

```jsonc
{ "kv_namespaces": [{ "binding": "CACHE", "id": "<namespace-id>", "preview_id": "<preview-id>" }] }
```

```javascript
await env.CACHE.put("key", "value", { expirationTtl: 3600, metadata: { v: 1 } });
const v   = await env.CACHE.get("key");                  // string | null
const j   = await env.CACHE.get("key", { type: "json" });
const { value, metadata } = await env.CACHE.getWithMetadata("key");
const list = await env.CACHE.list({ prefix: "user:" });
await env.CACHE.delete("key");
```

- **Eventually consistent**: a write propagates globally in up to ~60s. Reading your own write from another colo may return stale. Not a database — a cache/config store.
- Reads fast (cached at edge); writes + `list` are comparatively expensive. Use TTLs; avoid hot `list` in the request path.
- CLI: `wrangler kv namespace create CACHE`, `wrangler kv key put --binding=CACHE k v`.

## D1 — SQLite at the edge

```jsonc
{ "d1_databases": [{ "binding": "DB", "database_name": "app", "database_id": "<d1-id>" }] }
```

```javascript
const { results } = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).all();
const row = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).first();
await env.DB.prepare("INSERT INTO users (name) VALUES (?)").bind(name).run();
await env.DB.batch([stmt1, stmt2]);   // batched, atomic
```

- Always use **`.bind()`** parameters — never string-interpolate SQL.
- Strong consistency within the primary; read replication (Sessions API / read replicas) is async — opt in when you need it.
- Migrations: `wrangler d1 migrations create` / `apply`. Local: `wrangler d1 execute DB --local --file=schema.sql`.

## R2 — S3-compatible object storage, zero egress

```jsonc
{ "r2_buckets": [{ "binding": "BUCKET", "bucket_name": "uploads" }] }
```

```javascript
await env.BUCKET.put("path/file.png", request.body, { httpMetadata: { contentType: "image/png" } });
const obj = await env.BUCKET.get("path/file.png");
if (obj) return new Response(obj.body, { headers: { "etag": obj.httpEtag } });
await env.BUCKET.delete("path/file.png");
const listed = await env.BUCKET.list({ prefix: "path/" });
```

- **No egress fees** — the reason to move media/backups/static delivery off S3.
- S3 API compatible (use existing S3 SDKs against the R2 endpoint for external access).
- Pair with the Cache API or a custom domain for public serving.

## Durable Objects — strong consistency + coordination

```jsonc
{
  "durable_objects": { "bindings": [{ "name": "ROOM", "class_name": "ChatRoom" }] },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["ChatRoom"] }]
}
```

```javascript
export class ChatRoom {
  constructor(state, env) { this.state = state; this.env = env; }
  async fetch(request) {
    let count = (await this.state.storage.get("count")) || 0;
    await this.state.storage.put("count", ++count);   // serialized — no races
    return Response.json({ count });
  }
}

// From another Worker:
const id   = env.ROOM.idFromName("room-42");
const stub = env.ROOM.get(id);
const res  = await stub.fetch(request);
```

- **Single-threaded per object instance** → operations on one object serialize → strong consistency. This is the answer when KV's eventual consistency hurts (counters, locks, presence, realtime rooms, rate limiters).
- Storage: transactional KV-style API, or **SQLite-backed** DO storage (`new_sqlite_classes` in migrations) for relational state per object.
- Migrations are required to register/rename/delete DO classes — `tag` each migration; never edit an applied one.
- WebSocket hibernation API lets idle connections sleep without billing.

## Queues — async background work

```jsonc
{
  "queues": {
    "producers": [{ "binding": "JOBS", "queue": "jobs" }],
    "consumers": [{ "queue": "jobs", "max_batch_size": 10, "max_batch_timeout": 30, "dead_letter_queue": "jobs-dlq" }]
  }
}
```

```javascript
export default {
  async fetch(req, env)  { await env.JOBS.send({ task: "resize", id: 7 }); return new Response("queued"); },
  async queue(batch, env) {
    for (const msg of batch.messages) {
      try { await handle(msg.body); msg.ack(); }
      catch { msg.retry(); }            // retried; exhausted → dead-letter queue
    }
  },
};
```

- Decouples spikes from processing; guaranteed delivery with retries + DLQ.
- Batch settings tune throughput vs latency. `ack()`/`retry()` per message or per batch.

## Hyperdrive — pooled, cached access to external SQL

```jsonc
{
  "compatibility_flags": ["nodejs_compat"],
  "hyperdrive": [{ "binding": "HYPERDRIVE", "id": "<hyperdrive-config-id>" }]
}
```

```javascript
import postgres from "postgres";
const sql = postgres(env.HYPERDRIVE.connectionString);
const rows = await sql`SELECT * FROM orders WHERE id = ${id}`;
```

- Fronts an **existing** regional Postgres/MySQL with connection pooling + edge query caching, so a far-away DB feels fast from Workers.
- Requires `nodejs_compat`. Use a Workers-compatible driver (`postgres`, `pg` with compat, `mysql2`).
- Not a database itself — it's an accelerator for one you already run (RDS, Neon, Supabase, etc.).

## Workers AI — inference on Cloudflare GPUs

```jsonc
{ "ai": { "binding": "AI" } }
```

```javascript
const out = await env.AI.run("@cf/meta/llama-3.1-8b-instruct", { prompt: "Hello" });
const emb = await env.AI.run("@cf/baai/bge-base-en-v1.5", { text: ["doc one", "doc two"] });
```

- Single `ai` object binding (no array). Run text-gen, embeddings, image, speech models by ID.
- Feed embeddings into **Vectorize** for RAG.

## Vectorize — vector database

```jsonc
{ "vectorize": [{ "binding": "INDEX", "index_name": "docs" }] }
```

```javascript
await env.INDEX.upsert([{ id: "1", values: embedding, metadata: { url } }]);
const matches = await env.INDEX.query(queryEmbedding, { topK: 5, returnMetadata: true });
```

- Store + similarity-search embeddings for semantic search / RAG. Commonly fed by Workers AI embeddings.
- CLI: `wrangler vectorize create docs --dimensions=768 --metric=cosine`.

## Service bindings — Worker-to-Worker RPC

```jsonc
{ "services": [{ "binding": "AUTH", "service": "auth-worker", "entrypoint": "AuthEntrypoint" }] }
```

```javascript
const ok = await env.AUTH.verify(token);          // RPC method (WorkerEntrypoint) — no network hop
const res = await env.AUTH.fetch(internalRequest); // or HTTP-style
```

- Zero-latency internal calls; compose a system as multiple Workers. Supports RPC method calls (via `WorkerEntrypoint`) or `fetch`-style.

## Analytics Engine — custom metrics

```jsonc
{ "analytics_engine_datasets": [{ "binding": "AE", "dataset": "my_metrics" }] }
```

```javascript
env.AE.writeDataPoint({ blobs: [country], doubles: [latencyMs], indexes: [route] });
```

- Write high-cardinality time-series from a Worker; query via the GraphQL/SQL Analytics API. Cheap, sampled, fast.

## Assets — static files

```jsonc
{ "assets": { "directory": "./public", "binding": "ASSETS",
              "html_handling": "auto-trailing-slash", "not_found_handling": "single-page-application" } }
```

```javascript
// In a Worker with both `main` and `assets`:
export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname.startsWith("/api/")) return handleApi(request, env);
    return env.ASSETS.fetch(request);   // serve static files
  },
};
```

- Asset-only (omit `main`) = pure static host; matching requests never invoke Worker code (and aren't billed as invocations).
- `not_found_handling: "single-page-application"` serves `index.html` for unmatched routes (SPA routing); `"404-page"` serves a custom 404.
- `run_worker_first: true` runs your Worker before asset matching (for auth gates, rewrites).
