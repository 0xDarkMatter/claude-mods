# Deployment — self-hosting, multi-instance, CDNs, and Cloudflare

Verified against Next.js 16.3.3 docs, 2026-08-25.

Next.js runs perfectly well off Vercel. What it does *not* do is infer your
infrastructure: several behaviours that are automatic on a platform with
integrated storage and streaming become explicit configuration everywhere else.
Those are the ones below.

## The four deployment shapes

| Shape | Supports | Does not support |
|---|---|---|
| **Node.js server** (`next start`) | everything | — |
| **Docker container** | everything, with the caveats below | — |
| **Static export** (`output: 'export'`) | pure static sites | `use cache`, proxy, ISR, Route Handlers, image optimization (without a custom loader) |
| **Adapters** | platform-specific | — |

For containers, `output: 'standalone'` produces a minimal server bundle with
only the traced dependencies — the difference between a ~1GB image and a small
one. Copy `.next/static` and `public` alongside it; the trace does not include
them.

## Environment variables: build time vs runtime

`NEXT_PUBLIC_*` variables are **inlined into the JavaScript bundle at
`next build`**. They are baked into the image and cannot be changed by the
runtime environment — which is exactly the trap when one image is promoted
through dev → staging → prod.

Server-side variables are read at runtime **during dynamic rendering**. To read
one in a component that would otherwise prerender, defer to request time first:

```tsx
import { connection } from 'next/server'

export default async function Component() {
  await connection()
  const value = process.env.MY_VALUE     // now evaluated per request
}
```

That is what makes a single promotable image possible. `register()` in
`instrumentation.ts` runs code on server startup if you need boot-time setup.

## Caching and ISR when you own the disk

Page cache and ISR share **one Next.js server cache**, stored on the local
filesystem of each instance by default (plus ~50MB in memory). That is correct
for a single `next start` with persistent disk, and wrong for everything else:
on ephemeral compute the disk does not persist, and on Kubernetes every pod
holds its own independent copy.

```js
// next.config.js — one shared cache instead of N private ones
module.exports = {
  cacheHandler: require.resolve('./cache-handler.js'),
  cacheMaxMemorySize: 0,          // disable the in-memory layer
}
```

A handler implements `get`, `set`, `revalidateTag`, and `resetRequestCache`.
The Redis example in the Next.js repo is the usual starting point; production
needs durable storage, eviction, error handling and tag coordination on top.

For `'use cache'` backends specifically, the config key is **`cacheHandlers`**
(plural) — that is what `'use cache: remote'` resolves against. Two different
options with confusingly similar names.

### Automatic `Cache-Control` behaviour

| Response | Header |
|---|---|
| Immutable build assets (hashed filenames) | `public, max-age=31536000, immutable` — cannot be overridden |
| ISR pages | `s-maxage: <revalidate>, stale-while-revalidate` |
| Dynamically rendered pages, and Draft Mode | `private, no-cache, no-store, max-age=0, must-revalidate` |

A CDN in front must respect these *and* the cache-key variability, or you get
either no CDN caching at all or — worse — a personalised page served to the
wrong user. If a page is fully prerendered it emits `public` and is safe to cache
at the edge.

## Multi-instance: the four things that break

1. **Server Function encryption key.** Closure variables are encrypted with a
   per-build key. Across instances, one instance cannot decrypt another's
   references. Set a stable
   `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (base64, 16/24/32 bytes) at build time
   for every instance, or expect `Failed to find Server Action` under load with
   no deploy involved.
2. **Version skew.** Set `deploymentId`; static assets then carry `?dpl=…`,
   navigations send `x-deployment-id`, and a mismatch triggers a hard navigation
   instead of a broken one. When `deploymentId` is set, `generateBuildId` is
   inert and the deployment id is what varies `use cache` keys. Without it, use
   `generateBuildId` (e.g. the git hash) so every container in a deployment
   agrees on a build ID.
3. **Shared cache.** As above — `'use cache: remote'` plus a `cacheHandlers`
   backend, or accept per-instance caches.
4. **Tag coordination.** `revalidateTag()` invalidates only the instance that
   ran it; the others keep serving their own copy. Implement `refreshTags()` in
   the cache handler — it is called before each request and should sync tag
   state from shared storage.

## Streaming behind a proxy

Streaming, `loading.tsx`, and PPR all require an unbuffered path **end to end**.
nginx buffers by default:

```js
module.exports = {
  async headers() {
    return [{ source: '/:path*{/}?', headers: [{ key: 'X-Accel-Buffering', value: 'no' }] }]
  },
}
```

Also check load balancers (chunked transfer or HTTP/2 — AWS ALB with Lambda
integration is a known buffering case) and any reverse proxy in between. The
failure is silent and expensive: PPR still "works", the shell and dynamic
content simply arrive together and the entire TTFB benefit you built for
disappears. Test it by watching whether the first bytes arrive before the slow
query finishes, not by checking that the page renders.

## Image optimization

Works with zero configuration under `next start`. On glibc-based Linux, sharp's
memory allocator may need tuning to avoid runaway memory — a common "the
container keeps getting OOM-killed" cause. Alternatives: a custom `loader`
pointing at a dedicated image service, or `unoptimized` while keeping the rest
of `next/image`.

16.x changed several defaults worth restating in your own config so they are
choices: `minimumCacheTTL` 60s → 14400s (4h), `qualities` `[1..100]` → `[75]`
with coercion to the nearest listed value, `maximumRedirects` unlimited → 3, and
local IP optimization blocked unless `dangerouslyAllowLocalIP` is set.

## Graceful shutdown and `after()`

`after()` is fully supported under `next start`. Send `SIGINT`/`SIGTERM` and
**wait** — the server finishes in-flight requests and runs pending `after()`
callbacks before exiting. Give the orchestrator a drain period of 10–30 seconds;
a shorter `terminationGracePeriodSeconds` silently drops background work.

## The Cloudflare path

Next.js runs on Cloudflare Workers through **`@opennextjs/cloudflare`** — an
adapter that transforms the Next.js build output for the Workers Node.js-compat
runtime. As of 2026-08-30 it supports all of Next.js 16 and the latest minors of
14 and 15, covering App Router, Route Handlers, SSG/SSR, PPR, ISR, `after()` and
`'use cache'`. Verify current coverage before committing: the adapter tracks
Next.js releases and this is exactly the fact most likely to have moved.

Two things to decide before taking this route:

- **Is Next.js the right shape for this workload at all?** If the app is
  primarily an API with a thin UI, a Workers-native stack is simpler and
  cheaper — see `hono-ops` for the API and `cloudflare-ops` for bindings, KV/R2/
  D1, and Durable Objects. Choosing the adapter to run a mostly-API Next.js app
  on Workers is usually the expensive path.
- **Where does the cache live?** The whole multi-instance section above applies
  with force: Workers are ephemeral and horizontally scaled, so the default
  in-memory `use cache` store is effectively no cache, and tag revalidation
  needs coordinated storage.

Configuration of the Worker itself — `wrangler.jsonc`, compatibility flags,
bindings, secrets, deployment — is `cloudflare-ops` territory. This skill stops
at the seam.

## Pre-deploy checklist

- [ ] Caching verified against `next build && next start`, never `next dev`
- [ ] `next build` output reviewed — is every route in the rendering mode you expected?
- [ ] `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` set and shared, if multi-instance
- [ ] `deploymentId` (or `generateBuildId`) stable across containers in a deployment
- [ ] Cache handler configured if instances > 1, with `refreshTags()` for tag coordination
- [ ] Streaming unbuffered through every proxy in the path
- [ ] `NEXT_PUBLIC_*` values correct for the environment this image was **built** for
- [ ] Drain period long enough for in-flight `after()` work
- [ ] `python scripts/audit-app-router.py --min-severity error .` clean
