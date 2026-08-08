# Workers Runtime Integration — SPA Serving, Cron/Queues, Runtime Gotchas

One Worker frequently serves an API, a SPA, cron jobs, and queue consumers.
This file covers wiring all of them around one Hono app, plus the Workers
runtime behaviours that bite Hono code specifically.

## Serving a SPA + API from one Worker (static assets binding)

```jsonc
// wrangler.jsonc
{
  "assets": {
    "directory": "./web/dist",                    // built SPA
    "binding": "ASSETS",                          // exposes env.ASSETS (Fetcher)
    "not_found_handling": "single-page-application",  // unknown paths -> index.html
    "run_worker_first": ["/api/*", "/vesper/*", "/ingest/*"]  // Worker sees these BEFORE assets
  }
}
```

```typescript
interface Env { ASSETS: Fetcher; /* … */ }

// After all API routes:
app.all('/api/*', (c) => c.json({ error: 'not_found' }, 404));  // JSON 404, never the shell
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));             // hand everything else to assets
```

- Without `run_worker_first`, requests matching an asset path are served
  directly from the asset layer and your middleware (auth, security headers)
  never runs for them. List every non-asset pattern the Worker owns; keep the
  asset platform serving the rest (it's free and cached).
- `not_found_handling: "single-page-application"` gives deep links
  (`/app/settings`) the shell with a 200; the SPA router takes over.
- Responses from `ASSETS.fetch` have **immutable headers** — outbound middleware
  must rebuild the Response to add headers (middleware.md).
- Cache behaviour: the asset layer sets sane defaults (hashed assets long-lived,
  HTML no-cache). Add app-owned headers via the outbound middleware if needed.

## `fetch` + `scheduled` + `queue` in one export

Hono owns HTTP; the other handlers sit beside it in the default export:

```typescript
export default {
  fetch: app.fetch,

  scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    // Branch on the cron expression — one Worker, many schedules (all listed in
    // wrangler config `triggers.crons`). Keep each branch a thin dispatcher.
    if (controller.cron === '*/5 * * * *') {
      ctx.waitUntil(drainNotifications(env));
      ctx.waitUntil(generateRecurring(env));   // self-guarded: no-op when already done
    } else if (controller.cron === '0 2 * * *') {
      ctx.waitUntil(nightlySync(env));
    } else {
      ctx.waitUntil(weeklyJobs(env));
    }
  },

  async queue(batch: MessageBatch<JobMsg>, env: Env, ctx: ExecutionContext) {
    for (const msg of batch.messages) {
      try { await handleJob(msg.body, env); msg.ack(); }
      catch { msg.retry(); }
    }
  },
} satisfies ExportedHandler<Env>;
```

Discipline that keeps this maintainable:

- **`satisfies ExportedHandler<Env>`** typechecks the whole export against the
  runtime contract without widening.
- **Independent `ctx.waitUntil` per job**, not one chained promise — one job's
  failure must not suppress its siblings.
- **Cron jobs are self-guarding**: gate on config presence (no token → no-op),
  on state ("already generated this month"), and wrap per-item work in
  try/catch so one bad item doesn't kill the sweep. Crons re-run; make them
  idempotent.
- Cron/queue code shares the domain layer with HTTP handlers — it just isn't
  behind Hono, so nothing from the middleware context (identity, scoped repo)
  exists. Build the equivalent explicitly (a system identity, per-tenant loops).
- Local testing: `wrangler dev --test-scheduled` exposes
  `GET /__scheduled?cron=*+*+*+*+*`; in vitest, call `scheduled()` directly with
  a stub controller/ctx (testing.md).

## `waitUntil` semantics

`ctx.waitUntil(p)` (in Hono: `c.executionCtx.waitUntil(p)`) keeps the invocation
alive until `p` settles, *after* the response is sent.

- Register **before returning** — a floating promise not passed to `waitUntil`
  is cancelled when the response completes.
- Use it for: notification fan-out, cache writes, audit logs — anything the
  caller shouldn't wait for and can survive losing.
- Don't use it for work the response's correctness depends on, or anything
  needing a guaranteed outcome (that's a queue's job — `waitUntil` work is lost
  on isolate eviction/crash and has a post-response time budget).
- Errors inside a `waitUntil` promise don't affect the response; they surface in
  logs/tail only. Wrap in try/catch that records failure somewhere durable if
  you'd need to know.

## The `caches` API is per-colo

`caches.default` / `caches.open()` is a **per-data-center** cache, not a global
store:

- A `cache.put` in one colo is invisible in every other; hit rate follows
  traffic locality.
- Correct uses: collapsing a poll storm (many clients, one upstream call per
  ~45s window per colo), response caching where recomputation is cheap-but-annoying.
- Wrong uses: anything that must be seen globally after a write (that's KV — 
  eventually consistent — or D1/DO for strong consistency). There is no
  cross-colo invalidation; design for TTL expiry, not purge.
- Cache keys must be derived from **trusted, resolved** values (e.g. the
  post-authorization resource id), never raw client input — a key built from an
  unvalidated query param lets one caller poison another's cache line.

## Detached fetch — "Illegal invocation"

Storing the global `fetch` on an object (the injectable-fetch testing pattern)
and calling it as a method throws in workerd:

```typescript
class ApiClient {
  constructor(private fetchImpl: typeof fetch = fetch) {}

  async call(url: string) {
    // BROKEN in Workers: this.fetchImpl(url) invokes fetch with `this` bound to
    // the ApiClient instance -> TypeError: Illegal invocation.
    // FIX: detach to a bare local so the receiver is stripped:
    const doFetch = this.fetchImpl;
    return doFetch(url);
  }
}
```

Notes: mock `fetchImpl`s in tests are plain functions and never trip this — the
bug ships to production while the suite stays green, which is exactly why the
detach idiom should be unconditional. `const doFetch = this.fetchImpl ?? fetch`
and `fetch.bind(globalThis)` also work; the bare-local detach is the
lowest-ceremony fix. (Node ≥18 has the same receiver rule, so the idiom is
portable.)

## Assorted runtime traps

| Trap | Detail |
|---|---|
| Module state ≠ per-request state | Module-level variables persist across requests in an isolate (good: JWKS cache; bad: anything request-scoped — that's `c.set`) |
| No timers between requests | An isolate may be evicted anytime after the response (+`waitUntil` budget); never rely on `setInterval`/background loops — that's cron's job |
| `wrangler dev` host rewrite | Dev rewrites the request host to your route pattern; pin `[dev] host` when middleware branches on hostname |
| Bundle size | Workers has a compressed-size limit; validator libs and polyfills add up — prefer tree-shakeable deps (valibot, `zod/mini`) when close to it |
| Secrets gating | Optional secrets (`KEY?: string`): the dependent route returns 503 and the cron no-ops while unset. Never log secret values; log presence booleans |
| Subrequest limits | Each request has a subrequest budget; per-item external calls inside a big loop belong in a queue consumer, not a request handler |
