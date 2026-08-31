# Data Fetching, Streaming, and What a Loading State Costs

Verified against Next.js 16.3.3 docs, 2026-08-25.

## Fetch where the data is used

Server Components fetch directly — no client round trip, no exposed
credentials, no `useEffect`. The instinct to lift every fetch to the page and
prop-drill it down is a Pages Router habit that actively hurts here: it moves
the `await` **up**, and everything above an `await` cannot be prerendered.

```tsx
// Fetch in the component that renders it
async function Reviews({ productId }: { productId: string }) {
  const reviews = await getReviews(productId)
  return <ul>{reviews.map((r) => <li key={r.id}>{r.body}</li>)}</ul>
}
```

Duplicate `fetch` calls with identical arguments are memoized within a render
pass; for non-`fetch` reads, wrap with React's `cache()` to get the same
deduplication.

## Waterfalls

Sequential `await`s serialise. Two shapes fix it:

```tsx
// Parallel within one component
const [user, posts] = await Promise.all([getUser(id), getPosts(id)])
```

```tsx
// Or let independent components suspend independently — each streams when ready
<Suspense fallback={<UserSkeleton />}><User id={id} /></Suspense>
<Suspense fallback={<PostsSkeleton />}><Posts id={id} /></Suspense>
```

The second is usually better: it removes the waterfall *and* gets the fast half
onto the screen first. Preloading (see
[caching-model.md](caching-model.md)) covers the case where the two are in the
same component but only one blocks.

## Suspense boundaries define the shell

A `<Suspense>` boundary is the seam between "ships in the initial HTML" and
"streams in later". The fallback goes in the static shell; the content arrives
when it resolves.

```tsx
export default function Page() {
  return (
    <>
      <h1>My Blog</h1>                        {/* static */}
      <CachedPosts />                          {/* 'use cache' → static shell */}
      <Suspense fallback={<p>Loading…</p>}>
        <LatestComments />                     {/* request-time → streams */}
      </Suspense>
    </>
  )
}
```

Two properties worth stating plainly:

- **`<Suspense>` does not make anything dynamic.** A component doing only
  synchronous work completes during prerendering whether or not it is wrapped.
  The boundary describes where a *hole* may appear, not that one will.
- **Under Cache Components, reading `cookies()` inside a boundary no longer
  de-opts the route.** The static and cached parts still ship in the initial
  HTML; only the boundary streams. That is the single biggest behavioural
  difference from the pre-16 model, where one `cookies()` call anywhere turned
  the whole route dynamic.

### `loading.tsx` vs inline `<Suspense>`

`loading.tsx` wraps a whole route segment — one boundary, whole-page granularity.
Inline `<Suspense>` gives per-region granularity and is what lets the rest of the
page be instant. Use `loading.tsx` as a floor, inline boundaries for anything you
want visible immediately.

## What a loading state actually costs

A fallback is not free, and this is where teams over-correct in both directions.

**Costs of a boundary:**

- Content behind it is **excluded from the initial HTML**, so it is invisible to
  anything that does not execute the stream. Bots and crawlers are handled
  separately (see below), but simple scrapers and some previews are not.
- Streaming requires an unbuffered path end to end. Behind a buffering proxy the
  shell and the content arrive together and the boundary bought you nothing —
  see [deployment.md](deployment.md).
- Every boundary is a layout shift risk. A fallback whose dimensions differ from
  the real content trades TTFB for CLS.
- Nested boundaries mean nested reveals; too many produce a page that flickers
  into existence in six stages.

**Costs of no boundary:** the whole route blocks on its slowest read. The user
sees nothing — not a shell, not a nav — until the last query returns.

The rule that follows: **put the boundary around the slow, uncertain, or
personalised region, and only that region.** Cache what is shared; stream what is
per-user; keep the frame static.

### Prefetching is a real bill

With `partialPrefetching` enabled, the router prefetches each route's App Shell
by default. `<Link prefetch={true}>` goes further — Next.js re-renders the
destination with its URL resolved so that `searchParams`/`params`-dependent
cached content joins the prefetch. **That is one server invocation per
prefetchable link.** On a page with fifty product links this is a deliberate
trade, not a free optimisation. 16.3 softened it: prefetches under a size
threshold are bundled, layouts are deduplicated across links, and requests are
cancelled when a link leaves the viewport.

## Runtime APIs and where to await them

`cookies()`, `headers()`, `draftMode()`, `params` and `searchParams` are all
async (since 15.0) and all request-time. Where you await them determines how
much of the page can be prerendered.

```tsx
// ❌ awaiting at the top of the layout — nothing above can be prerendered
export default async function Layout({ params }: LayoutProps<'/shop/[slug]'>) {
  const { slug } = await params
  return <div><Sidebar /><h1>{slug}</h1></div>
}

// ✅ pass the promise down; await inside a boundary
export default function Layout({ children, params }: LayoutProps<'/shop/[slug]'>) {
  return (
    <div>
      <Sidebar />
      <Suspense fallback={<h1>Loading…</h1>}>
        {params.then(({ slug }) => <SlugHeading slug={slug} />)}
      </Suspense>
      {children}
    </div>
  )
}
```

The same move applies to every runtime API and to any slow `await`. "Push the
await down" is the single highest-leverage structural habit in the App Router.

For a per-request value from a non-request source (a UUID, a timestamp), call
`connection()` first and wrap in `<Suspense>` — that is what tells the framework
the work must not run at build time.

## Predictable reads do not need a boundary

Module imports, `fs.readFileSync`, pure computation and synchronous embedded
databases (`better-sqlite3`, `node:sqlite`) complete during prerendering and land
in the static HTML automatically. A config file that never varies per request
belongs at module scope, read once — not awaited inside a component where it
becomes an uncached read that needs a boundary or a cache.

## Error boundaries

`error.js` is the route-level convention. For component-level recovery, 16.3
added `catchError` from `next/error`, which — unlike a plain React error
boundary — does not interfere with `notFound()` or `redirect()`, and hands the
fallback a `retry()` that can re-fetch failed Server Components:

```tsx
'use client'
import { catchError, type ErrorInfo } from 'next/error'

function Fallback(props: { title: string }, { error, retry }: ErrorInfo) {
  return <div><h2>{props.title}</h2><p>{error.message}</p>
    <button onClick={() => retry()}>Try again</button></div>
}

export default catchError(Fallback)
```

Wrap error boundaries around the same subtrees as Suspense boundaries: the
region that can fail independently is the region that should fail independently.

## Bots and crawlers get a different render

Crawlers are detected by user agent and served a **full dynamic render** rather
than the shell, because they need a complete document. The shell's work
therefore runs at *request* time for them. If any part of the shell depends on
build-time-only inputs, the page can render for a human and 500 for Googlebot.
Make sure everything the shell needs is also reachable at request time.

## Guarding against regression

Instant navigation is easy to lose by accident: a `cookies()` read added to a
shared header, a `<Suspense>` boundary moved during a refactor. The
`@next/playwright` `instant()` helper asserts what must be visible *without
waiting for the network*, so the test fails whatever the cause:

```ts
import { instant } from '@next/playwright'

await instant(page, async () => {
  await page.click('a[href="/products/hats"]')
  await expect(page.locator('h1')).toContainText('Baseball Cap')
})
```

The DevTools Instant Insights panel surfaces the same regressions in
development, and the Navigation Inspector pauses a navigation at its shell so
you can see exactly what the user would see. `testing-ops` and `playwright-ops`
own the wider test strategy.
