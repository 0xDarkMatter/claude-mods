# Cache Components — `use cache`, lifetimes, and Partial Prerendering

The explicit caching model, enabled with `cacheComponents: true` in
`next.config.ts`. Introduced in Next.js 16.0 (`'use cache'` shipped
experimentally in 15.0 under `experimental.dynamicIO`, since renamed).

Verified against Next.js 16.3.3 docs, 2026-08-25.

> This is a whole-app semantic change, not a per-route flag: every dynamic read
> executes at request time unless a cache directive says otherwise, and Partial
> Prerendering becomes the default rendering strategy. The old
> `experimental.ppr` flag and the `experimental_ppr` route export were removed
> in favour of it.

## The directive

`'use cache'` caches the return value of an **async** function or component. It
sits at the top of a function body, or at the top of a file (in which case every
export is cached and every one of them must be async — including framework
exports like `generateMetadata` and `generateStaticParams`).

```tsx
import { cacheLife, cacheTag } from 'next/cache'

export async function getProducts(categoryId: string) {
  'use cache'
  cacheLife('hours')
  cacheTag(`category-${categoryId}`)
  return db.products.findMany({ where: { categoryId } })
}
```

Two levels, and the choice matters:

- **Data-level** — cache the function. Reuse the same data across components,
  independent of the UI that renders it.
- **UI-level** — cache the component/page/layout. The cached output is an RSC
  payload, so the *rendered markup* is what gets reused.

## Cache keys — what actually varies an entry

The key is built from:

1. **Build ID** (or `deploymentId` when configured) — so no entry survives a
   deploy, `remote` ones included.
2. **Function ID** — a hash of the function's location and signature.
3. **Serializable arguments** — props for components, arguments for functions.
4. **HMR refresh hash**, in development only.

**Closure captures become arguments.** A variable referenced from an enclosing
scope is bound in automatically and joins the key:

```tsx
async function Component({ userId }: { userId: string }) {
  const getData = async (filter: string) => {
    'use cache'
    // key includes BOTH userId (captured) and filter (passed)
    return fetch(`/api/users/${userId}/data?filter=${filter}`).then((r) => r.json())
  }
  return getData('active')
}
```

That is the mechanism behind the most common capacity surprise: a per-user value
in scope turns one logical entry into one entry per user.

## Serialization — the constraint that shapes the API

Arguments use **Server Component** serialization; return values use **Client
Component** serialization. The former is stricter, which is why you can *return*
JSX but not *accept* it as an inspected argument.

| | Supported |
|---|---|
| **Arguments** | primitives, plain objects, arrays, `Date`, `Map`, `Set`, TypedArrays, `ArrayBuffer`, React elements as pass-through only |
| **Return values** | all of the above, plus JSX elements |
| **Neither** | class instances, functions (except pass-through), Symbols, `WeakMap`/`WeakSet`, `URL` instances |

### Pass-through: composition without polluting the key

A non-serializable value is fine **as long as the cached body never introspects
it**. This is what keeps `children` composition alive:

```tsx
async function CachedWrapper({ header, children }: { header: ReactNode; children: ReactNode }) {
  'use cache'
  const data = await getCachedData()
  return <div>{header}<Rendered data={data} />{children}</div>   // placed, never read
}
```

Server Actions pass through the same way — hand one to a Client Component
through a cached component, just never *call* it inside the cached body. A
cached `layout` therefore does not cache its `children`; slots pass through.

## Constraints inside a cached scope

| Constraint | Behaviour |
|---|---|
| **Request APIs** | `cookies()`, `headers()`, `searchParams`, dynamic `params` throw [`next-request-in-use-cache`](https://nextjs.org/docs/messages/next-request-in-use-cache). **The restriction follows the call stack** — a helper that reads them fails identically. On a dynamically-rendered route this can pass `next build` and only fail under `next start` |
| **Draft Mode** | `draftMode()`'s `isEnabled` *is* readable inside a cached scope; while draft mode is on, cached functions re-execute every request and results are not stored. `enable()`/`disable()` throw |
| **`React.cache`** | Runs in an isolated scope inside the boundary. Values stored outside are invisible inside — you cannot smuggle data in that way. Use arguments |
| **Non-determinism** | `Math.random()`, `Date.now()`, `crypto.randomUUID()` are guarded. Call `connection()` and wrap in `<Suspense>` for a per-request value, or cache deliberately so everyone shares one. `performance.now()` is exempt — it is telemetry |

The sanctioned pattern for request-dependent data is to read it **outside** and
pass the value in:

```tsx
async function ProfileContent() {                 // not cached: reads the cookie
  const session = (await cookies()).get('session')?.value
  return <CachedContent sessionId={session} />
}

async function CachedContent({ sessionId }: { sessionId: string }) {
  'use cache'                                     // sessionId joins the key
  return <div>{await fetchUserData(sessionId)}</div>
}
```

## Lifetimes: `cacheLife`

Three properties, three different audiences:

- **`stale`** — how long the *client* reuses it without asking the server.
- **`revalidate`** — how often the *server* regenerates in the background.
- **`expire`** — after this long with no traffic, the next read blocks on a
  fresh render. Must be greater than `revalidate`; Next.js validates this.

| Profile | `stale` | `revalidate` | `expire` |
|---|---|---|---|
| `default` | 5 min | 15 min | never |
| `seconds` | 30 s | 1 s | 1 min |
| `minutes` | 5 min | 1 min | 1 hr |
| `hours` | 5 min | 1 hr | 1 day |
| `days` | 5 min | 1 day | 1 week |
| `weeks` | 5 min | 1 week | 30 days |
| `max` | 5 min | 30 days | 1 year |

Custom and overridden profiles live in `next.config.ts` under `cacheLife`;
omitted properties inherit from `default`. Redefining `default` also changes
what every un-annotated scope does. Inline objects (`cacheLife({ revalidate: 900 })`)
are for one-offs, including lifetimes computed from fetched data.

`cacheLife` cannot be called at module scope, and only one call should execute
per invocation (branching between two calls is fine).

### Nesting — the rule worth memorising

- **Outer scope with an explicit `cacheLife`:** its own lifetime wins, always,
  longer or shorter than the inner one.
- **Outer scope without one:** it uses `default` (15 min revalidate), and an
  inner *shorter* lifetime drags it down. A longer inner one cannot extend it.
- **A short-lived inner cache nested in an outer scope with no explicit
  lifetime is a prerender-time build error** — deliberately, because the
  propagation would otherwise be silent. The nested cache may be in an imported
  module or a dependency, which is what makes it hard to spot.

This is the entire argument for the house rule: **state `cacheLife` in every
scope.** It makes a cached function readable in isolation.

### Prerendering thresholds

A short lifetime changes *where* content can be served from:

- `revalidate: 0`, or `expire` under 5 minutes → excluded from prerenders;
  becomes a dynamic hole resolved at request time.
- `stale` under 30 seconds → excluded from prefetches (a prefetch would expire
  before the user could click). The client enforces a 30-second floor.
- `stale` ≥ 30 s but < 5 min → in the prerender, out of the App Shell.

Of the presets, only `seconds` trips any of these.

## Where a cached result lives

| Store | What | Notes |
|---|---|---|
| **Prerendered HTML** | The payload rendered to HTML | On disk when self-hosting, or platform storage behind a CDN. `revalidate`/`expire` control rebuilds |
| **Shared server store** | The RSC payload | **Per-instance and in-memory by default** — ephemeral on serverless, persistent when self-hosted (`cacheMaxMemorySize`). `'use cache: remote'` moves it to a `cacheHandlers` backend shared across instances, at the cost of a network round trip that only pays off at a high hit rate |
| **Browser** | The payload in a navigation or prefetch | Fresh for its `stale` window. `'use cache: private'` results live only here |

All stores are scoped to one deployment.

### The three directives

| Directive | Reads request data? | Stored | Use when |
|---|---|---|---|
| `'use cache'` | No | Server (in-memory by default) + prerender + client | The default choice |
| `'use cache: remote'` | No | A durable shared cache handler | Multi-instance, and the hit rate justifies the round trip |
| `'use cache: private'` | **Yes** — cookies, headers, searchParams directly | Client only, per session | Compliance constraints, or code that genuinely cannot be refactored to pass values as arguments |

## Revalidation

Time-based via `cacheLife`; on-demand via `cacheTag` plus one of:

```ts
'use server'
import { updateTag, revalidateTag, refresh } from 'next/cache'

updateTag('products')              // expire + re-read in the same response
revalidateTag('products', 'max')   // stale-while-revalidate, no immediate re-render
refresh()                          // refetch uncached data only; cache untouched
```

They are commonly paired: a long `cacheLife('max')` with a `cacheTag`, busted on
demand when an editor saves. See [server-actions.md](server-actions.md) for
which one a given mutation wants.

## Rendering: PPR, the App Shell, and prefetching

At build time Next.js renders the tree and sorts it:

- `'use cache'` output → the **static shell** (if its lifetime is long enough).
- `<Suspense>` → the fallback ships in the shell, the content streams at request
  time.
- Module imports, `fs.readFileSync`, pure computation → resolved into the shell
  automatically.
- Random values/timestamps → `connection()` + `<Suspense>`, or cache them.

When a route's dynamic params are known, the shell contains concrete content.
When they are not, the reusable URL-independent version is the **App Shell** —
served instantly on first visit and upgraded in the background with the now-known
params, which is what ISR looks like under this model.

**Maximise the shell by pushing awaits down the tree.** A layout that awaits
`params` at the top cannot be prerendered at all; pass the promise down and
await inside a boundary:

```tsx
export default function Layout({ children, params }: LayoutProps<'/shop/[slug]'>) {
  return (
    <div>
      <Sidebar />
      <Suspense fallback={<h1>Loading...</h1>}>
        {params.then(({ slug }) => <SlugHeading slug={slug} />)}
      </Suspense>
      {children}
    </div>
  )
}
```

**Prefetching costs a server invocation per prefetchable link.** With
`partialPrefetching`, the router prefetches each route's App Shell by default;
`<Link prefetch={true}>` re-renders the destination with its URL resolved so
`searchParams`- and `params`-dependent cached content joins the prefetch. That
is a real bill — see [data-fetching-streaming.md](data-fetching-streaming.md).

## Debugging

```bash
NEXT_PRIVATE_DEBUG_CACHE=1 npm run dev     # verbose cache logging (also ISR)
NEXT_PRIVATE_DEBUG_CACHE=1 npm run start
```

In development, console logs replayed from cached functions are prefixed
`Cache`. The dev overlay surfaces named insights — `blocking-route`,
`blocking-prerender-random`, `blocking-prerender-current-time`,
`blocking-prerender-crypto` — each with a concrete fix; Instant Insights flags
navigations that are not instant.

### "Filling a cache during prerender timed out"

A 50-second build hang, then that error. Cause: a Promise created **outside** a
cached boundary is awaited **inside** one, so it can never resolve during
prerender. The usual routes in are passing a `cookies()` store as a prop,
closing over a request-scoped promise, or sharing a `Map` of in-flight fetches
between cached and uncached code. Calling `cookies()` directly inside the scope
fails immediately with `next-request-in-use-cache` instead — a different error
for a related mistake.
