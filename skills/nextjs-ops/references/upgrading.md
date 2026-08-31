# Upgrading — 14 → 15 → 16, and Pages → App

Verified against Next.js 16.3.3 docs, 2026-08-30.

`migrate-ops` owns generic migration method (dependency audit, codemods,
rollback strategy). This file owns the Next.js-specific deltas: what actually
changes in behaviour, in what order to take it, and which changes are silent.

> **The defining property of these upgrades: the dangerous changes do not
> error.** A 14 → 15 jump compiles and boots, then serves uncached data where it
> used to serve cached. Type errors you will find; semantic inversions you have
> to go looking for.

## Take one major at a time

`14 → 15 → 16`, each landing green before the next. The two majors change
different things — 15 inverts data defaults, 16 changes the rendering and
invalidation model — and a combined jump makes it impossible to attribute a
regression to either.

```bash
npx @next/codemod@canary upgrade latest    # mechanical rewrites
npx @next/codemod@canary middleware-to-proxy .
```

The codemod is necessary and not sufficient. It rewrites call sites it can see;
it does not rewrite your hand-written types, your helper functions, or your
assumptions.

## 14 → 15: the data defaults invert

| Was | Is |
|---|---|
| `fetch()` **cached** by default | `fetch()` **uncached** by default |
| `cookies()`, `headers()`, `draftMode()` sync | async — must be `await`ed |
| `params`, `searchParams` plain objects | `Promise` — must be `await`ed |
| GET Route Handlers cached by default | uncached by default |
| Client Router Cache reused page segments | `staleTimes.dynamic` defaults to 0 |

The async APIs are loud: TypeScript and the runtime both complain. **The `fetch`
default is silent**, and it is the one that matters. Every `fetch` in the
codebase that relied on the implicit cache is now hitting origin on every
request. The visible symptoms are a cost spike and latency, not an error.

The migration is mechanical but must be deliberate — annotate, do not blanket:

```ts
await fetch(url, { cache: 'force-cache' })        // was the old default
await fetch(url, { next: { revalidate: 3600 } })  // usually what you actually wanted
```

Resist `export const fetchCache = 'default-cache'` at the top of every route to
"restore" 14's behaviour. It reinstates the exact implicit caching the upgrade
exists to remove, and you will be debugging it again in a year.

**Check before you finish:** run `next build` and compare the per-route
rendering modes against the 14 build. Routes that silently went from static to
dynamic are the regression.

## 15 → 16: rendering, invalidation, and tooling

Removals and renames (full table in
[routing-and-rendering.md](routing-and-rendering.md)):

- `middleware.ts` → **`proxy.ts`**, Node.js runtime, `runtime` config now throws
- `revalidateTag(tag)` → `revalidateTag(tag, profile)`; `updateTag`/`refresh` added
- `experimental.ppr` / `experimental_ppr` / `experimental.dynamicIO` → `cacheComponents`
- Parallel route slots **require** `default.js` — a hard build failure
- Sync `params`/`cookies()`/`headers()` support removed entirely (15 deprecated, 16 deleted)
- `next lint` gone; `next build` no longer lints — wire ESLint or Biome yourself, or lint silently stops running in CI
- `serverRuntimeConfig`/`publicRuntimeConfig` gone → env vars
- Node 20.9+, TypeScript 5.1+, Turbopack default

Behaviour changes that are silent, and therefore the ones to check:

- `images.minimumCacheTTL` 60s → **14400s** (4h). Images update far less often.
- `images.qualities` → `[75]`, with `quality` **coerced to the nearest listed
  value**. A `quality={90}` prop silently becomes 75 until you list it.
- `images.maximumRedirects` unlimited → 3.
- Local-IP image optimization blocked unless `dangerouslyAllowLocalIP`.
- Prefetching rewritten — more requests, smaller total transfer.

### Turbopack is now the default bundler

`next build --webpack` opts out. Custom webpack config, unusual loaders, or a
Babel-dependent toolchain are the cases that need it. Note 16 *auto-enables*
Babel when it finds a Babel config rather than erroring — convenient, and a quiet
build-time cost if that config is a leftover.

## Adopting Cache Components

`cacheComponents: true` is **not** a 16 upgrade step. It is a separate project,
taken deliberately after 16 is stable. Enabling it changes the default for the
whole app from "cache what we can infer" to "cache nothing unless told", and
turns PPR on as the rendering model.

Expect the framework to start *failing the build* on things it previously
tolerated: uncached reads with no `<Suspense>` boundary, request APIs inside
cached scopes, short-lived caches nested in unlabelled ones. That is the feature
— it is refusing to let a route exist that cannot produce a static shell.

Order that works:

1. Land 16 without the flag. Stabilise.
2. Turn the flag on in a branch and read the dev overlay's insights; each names
   a route and a fix.
3. Work outside-in: give every uncached/runtime read either a `<Suspense>`
   boundary or a `'use cache'` scope with an explicit `cacheLife`.
4. Replace `unstable_cache`/`fetch`-cache usage **only where it should not
   survive a deploy** — those two stores persist across builds and `'use cache'`
   deliberately does not.
5. Re-check `revalidateTag` call sites: under the new model, `updateTag` is what
   gives read-your-own-writes.

Use the official *migrating to Cache Components* guide for the route-by-route
mechanics; the semantics you are converting *to* are in
[cache-components.md](cache-components.md).

## Pages Router → App Router

The two routers **coexist** in one app, which is the whole migration strategy:
move route by route, verify, repeat. Do not attempt a big-bang rewrite.

| Pages | App |
|---|---|
| `getServerSideProps` | `async` Server Component, or request-time read |
| `getStaticProps` + `revalidate` | `'use cache'` + `cacheLife`, or `fetch` revalidate |
| `getStaticPaths` | `generateStaticParams` |
| `_app` / `_document` | root `layout.tsx` |
| `next/head` | `metadata` / `generateMetadata` |
| `pages/api/*` | `route.ts` handlers (or Server Actions for UI mutations) |
| `useRouter` from `next/router` | `next/navigation`: `useRouter`, `usePathname`, `useSearchParams` |

Sequencing that avoids the usual pain:

1. **Leaf routes first.** Something self-contained with real traffic, so you
   learn the boundary on a page you can actually observe.
2. **Shared layout last.** Moving `_app` early forces every child to move with it.
3. **Expect the boundary tax up front.** Component libraries without
   `'use client'`, context providers, and anything touching `window` all need
   handling before the first route lands — see
   [server-client-boundary.md](server-client-boundary.md).
4. **Keep `pages/api` until the consumers move.** Route Handlers are a
   like-for-like replacement, so there is no reason to do it in the same change.

## Rollback

Every one of these is revertible **only if the cache state is**. A deploy that
changes the caching model changes what is in the shared store; rolling the code
back does not roll the store back, and `use cache` entries are keyed by build id
so they vanish anyway.

- Keep the previous build deployable, and change one variable per deploy.
- Have a cache-invalidation lever ready (`revalidatePath('/', 'layout')`, a
  handler flush, or a `deploymentId` bump) so "roll back the code" can be
  followed by "and clear what it wrote".
- Watch origin request volume, not just error rate. The 15 upgrade's failure
  mode is a working site that costs five times more.

## Verification checklist

- [ ] `next build` rendering modes diffed against the previous major
- [ ] Origin/database request volume compared before and after
- [ ] `python scripts/audit-app-router.py .` clean at `--min-severity error`
- [ ] Every `revalidateTag` call site reviewed for the two-argument form
- [ ] Lint still actually runs in CI (`next lint` no longer exists)
- [ ] Image quality/TTL props still produce what you expect
- [ ] `proxy.ts` matcher still excludes static assets after the rename
