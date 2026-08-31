# The Previous Caching Model — layers, defaults, and the stale-response ladder

Applies when `cacheComponents` is **not** enabled — which is still the default
in Next.js 16. If it is enabled, read
[cache-components.md](cache-components.md) instead; the two models do not
interleave and advice from one is actively wrong in the other.

Verified against Next.js 16.3.3 docs, 2026-08-25.

## Why this is the expensive area

Caching defaults **inverted** between majors. The same code, unchanged, caches
differently depending on which major it runs under — and the failure mode is a
page that renders perfectly with data from an hour ago.

| Major | `fetch()` with no `cache` option |
|---|---|
| ≤ 14 | **Cached** by default (`force-cache`) |
| 15.x, 16.x | **Not cached** by default |

Most "Next.js caching is broken" reports are a 14-era mental model applied to a
15/16 app, or the reverse. Establish the major first, every time.

## The four layers

| Layer | Where | Caches | Lifetime | Opt out |
|---|---|---|---|---|
| **Request Memoization** | Server, per render pass | Duplicate `fetch` (and `React.cache`) calls with identical arguments | One render pass. Not a cache you tune | Nothing to opt out of — it exists so you can fetch the same data in three components without three round trips |
| **Data Cache** | Server, persistent, across requests and deploys | `fetch` responses and `unstable_cache` results | Until revalidated by time or tag | `cache: 'no-store'` (the default in 15/16) |
| **Full Route Cache** | Server, build/ISR output | The rendered HTML + RSC payload of a statically-rendered route | Until the route revalidates or you redeploy | Any request-time API, `dynamic = 'force-dynamic'`, or `revalidate = 0` |
| **Client Router Cache** | Browser memory | RSC payloads of visited/prefetched routes | Per `staleTimes`; cleared entirely by a revalidation call in an action | `router.refresh()`, a mutation, a full reload |

The layers are *ordered*. A stale value can be held by any one of them, and
clearing the wrong one produces "I invalidated it and nothing happened."

## Opting in and out, deliberately

```ts
// Per request — the only fetches that cache in 15/16 are the ones that ask.
await fetch(url, { cache: 'force-cache' })                 // cache indefinitely
await fetch(url, { next: { revalidate: 3600 } })           // time-based
await fetch(url, { next: { tags: ['products'] } })         // taggable, on-demand
```

```ts
// Non-fetch work (ORM, SDK, computation)
import { unstable_cache } from 'next/cache'

export const getCachedUser = unstable_cache(
  async (id: string) => db.select().from(users).where(eq(users.id, id)),
  ['user'],                                 // key prefix
  { tags: ['user'], revalidate: 3600 },
)
```

**This model's two stores are the ones that survive a deploy.** Both the `fetch`
data cache and `unstable_cache` persist across builds; `'use cache'` entries
never do, because the build id (or `deploymentId`) is part of their key — not
even `remote` ones. If something must outlive a deploy, it belongs in one of
these two, not in a Cache Components scope.

```ts
// Deduplicate non-fetch reads within one render pass
import { cache } from 'react'
export const getPost = cache(async (id: string) => db.query.posts.findFirst(/* … */))
```

### Route segment config

Exported from a `page`, `layout` or `route`. Statically analysable values only —
`revalidate = 600` works, `revalidate = 60 * 10` does not.

| Export | Values | Effect |
|---|---|---|
| `dynamic` | `'auto'` (default) \| `'force-dynamic'` \| `'error'` \| `'force-static'` | `force-dynamic` renders per request and forces every `fetch` to `no-store`. `error` fails the build if anything request-time is used. `force-static` makes `cookies()`/`headers()`/`useSearchParams()` return empty values — a quiet source of "why is the user always logged out" |
| `revalidate` | `false` (default) \| `0` \| `number` | Route-level default in seconds. **The lowest value across the whole route wins**, layouts included, so one impatient child speeds up the entire route |
| `fetchCache` | `'auto'` … `'force-no-store'` | Advanced override of every `fetch` default in the segment. Reach for it only when you need a whole-route guarantee |

`runtime` is also a segment export, but `'edge'` is the deprecated path — see
[proxy-and-runtimes.md](proxy-and-runtimes.md).

### On-demand invalidation

```ts
revalidateTag('products', 'max')   // SWR: serve stale now, refresh in background
updateTag('products')              // read-your-writes; Server Actions only
revalidatePath('/products')        // by URL; a convenience layer over tags
```

In 16, `revalidateTag` takes a `cacheLife` profile (or `{ expire: seconds }`) as
its second argument. The single-argument form still runs but is deprecated —
`'max'` is the recommended profile for long-lived content.

## The stale-response debug ladder

Work down it. Stop at the first rung that explains the symptom; each rung
produces a different fix, which is why guessing is expensive.

1. **Are you testing in `next dev`?** Development never caches pages. A caching
   bug is only observable under `next build && next start`. Half of all reported
   caching mysteries end here.
2. **Which model?** `grep -n cacheComponents next.config.*`. If it is on, this
   file does not apply.
3. **Which major?** `node -p "require('next/package.json').version"`. A 14→15
   upgrade silently un-caches every unannotated `fetch`; a 15→16 upgrade changes
   `revalidateTag`.
4. **Turn on the log.** `NEXT_PRIVATE_DEBUG_CACHE=1 npm run start` reports cache
   hits, misses and ISR activity. This is the cheapest real evidence available.
5. **Is the value in the Data Cache or the Full Route Cache?** If the *page* is
   stale but a fresh API call returns new data, it is the route cache — check for
   a `revalidate` export, or that the route is static when you assumed dynamic.
   `next build` prints the rendering mode of every route; read that output.
6. **Is it the client?** A stale value that disappears on hard reload but
   survives in-app navigation is the Client Router Cache. Mutations that call
   `updateTag`/`revalidatePath`/`refresh` clear it; a bare `revalidateTag` with
   an SWR profile deliberately does not re-render.
7. **Multi-instance?** `revalidateTag` invalidates only the instance that ran
   it. Other pods keep serving their own copy until they independently expire.
   Coordination requires a cache handler implementing `refreshTags()` —
   see [deployment.md](deployment.md).
8. **CDN in front?** Dynamic pages emit `Cache-Control: private, no-cache,
   no-store, max-age=0, must-revalidate`; fully static ones emit `public`. If a
   CDN is caching something marked private, or ignoring `s-maxage`, the stale
   copy is not Next.js's at all.

## Preloading, to kill the waterfall without caching anything

Caching is often reached for when the real problem is sequencing. Start the
fetch before the thing that blocks on it:

```ts
import { cache } from 'react'
import 'server-only'

export const getItem = cache(async (id: string) => { /* … */ })
export const preload = (id: string) => { void getItem(id) }
```

```tsx
preload(id)                        // kick it off
const ok = await checkAvailable()  // do the other await meanwhile
return ok ? <Item id={id} /> : null
```

See [data-fetching-streaming.md](data-fetching-streaming.md) for the fuller
waterfall treatment.

## Migrating to Cache Components

The move is not route-by-route: enabling `cacheComponents` changes the default
for the whole app from "cache what we can infer" to "cache nothing unless told".
Use the official migration guide and the `@next/codemod` upgrade tooling rather
than hand-converting, then read [cache-components.md](cache-components.md) for
the semantics you are converting *to*.
