---
name: nextjs-ops
description: "Next.js App Router operations - the server/client boundary, the two caching models, Server Actions security, streaming, proxy.ts and deployment. Use for: next.js, nextjs, app router, use cache, cacheComponents, Cache Components, cacheLife, cacheTag, revalidateTag, updateTag, revalidatePath, unstable_cache, PPR, partial prerendering, stale data in production, use client, use server, server actions, RSC payload, serialization boundary, next/headers, async params, cookies not awaited, loading.tsx, Suspense boundary, generateStaticParams, ISR, proxy.ts, middleware.ts deprecated, edge runtime, next build vs next start, self-hosting Next.js, standalone output, Failed to find Server Action, upgrade to Next.js 16, Pages Router to App Router, force-static, force-dynamic, next/font, next/script, bundle size, testing server components."
license: MIT
allowed-tools: "Read Write Bash Grep Glob"
metadata:
  author: claude-mods
  related-skills: "react-ops, typescript-ops, tailwind-ops, payloadcms-ops, cloudflare-ops, hono-ops, auth-ops, testing-ops"
---

# Next.js Operations

The App Router as an operational surface: what crosses the server/client
boundary, which caching model the app is actually on, why a response is stale,
and what a Server Action really is on the wire. React itself belongs to
`react-ops`; styling to `tailwind-ops`; the CMS above to `payloadcms-ops`; the
Workers runtime below to `cloudflare-ops` / `hono-ops`. This skill is the
framework.

> Verified against Next.js 16.x (2026-08-30) — `next@16.3.3`, docs snapshot
> 2026-08-25, React 19. Semantics changed materially at **15.0** (`fetch`
> uncached by default, request APIs async) and again at **16.0** (Cache
> Components, `proxy.ts`, `revalidateTag` signature). **Establish the app's
> version before answering any caching question** — the right answer for 14 is
> the wrong answer for 16.

**Staleness check:** `python scripts/check-nextjs-facts.py --offline` asserts
the version-bearing facts are still named in the prose and that the currency
note above matches the catalog; `--live` confirms each package's npm major.
Catalog: `assets/nextjs-facts.json`.

## Orient first: which model is this app on?

Three greps, before any advice. Getting this wrong is the single largest source
of confidently-wrong Next.js answers.

```bash
node -p "require('next/package.json').version"          # the major decides everything
grep -rn "cacheComponents" next.config.*                # Cache Components on/off
ls proxy.* middleware.* src/proxy.* src/middleware.* 2>/dev/null
```

| Signal | Model in force | Read |
|---|---|---|
| `cacheComponents: true` | **Cache Components** — nothing cached unless `'use cache'` says so; PPR is the default rendering | `references/cache-components.md` |
| No `cacheComponents` (16.x default) | **Previous model** — `fetch` uncached by default, route-segment config, `unstable_cache` | `references/caching-model.md` |
| Next.js ≤ 14 | Legacy — `fetch` cached by *default*; most "why is this stale" bugs live here | `references/caching-model.md` |

## Decision Tree

```
What are you doing with Next.js?
│
├─ "It's serving stale data" / "my change doesn't appear"
│  └─ Orient (above) → references/caching-model.md (debug ladder)
│
├─ Deciding what to cache, for how long, and how to bust it
│  └─ references/cache-components.md (use cache, cacheLife, cacheTag)
│     or references/caching-model.md if cacheComponents is off
│
├─ "use client" errors, serialization failures, context, env leaks
│  └─ Below + references/server-client-boundary.md
│
├─ Mutations: Server Action vs Route Handler, auth, validation
│  └─ Below + references/server-actions.md
│
├─ Data fetching, waterfalls, Suspense/loading.tsx, what streams
│  └─ references/data-fetching-streaming.md
│
├─ Routes, async params, layouts, parallel/intercepting routes, metadata
│  └─ references/routing-and-rendering.md
│
├─ proxy.ts (formerly middleware.ts), matchers, edge vs Node runtime
│  └─ references/proxy-and-runtimes.md
│
├─ Shipping it: self-host, Docker, multi-instance, CDN, Cloudflare
│  └─ references/deployment.md
│
├─ Upgrading 14/15 -> 16, or Pages Router -> App Router
│  └─ references/upgrading.md
│
├─ Fonts, scripts, images, bundle size, build speed
│  └─ references/optimization.md
│
├─ Testing it (and what simply cannot be unit-tested)
│  └─ references/testing.md
│
└─ Auditing an existing app for the known footguns
   └─ python scripts/audit-app-router.py <project-root>
```

## The boundary is a module graph, not a folder

`'use client'` marks an **entry point into the client module graph**. Everything
that file imports — and everything those files import — is bundled for the
browser, whether or not it carries the directive. Components passed *through* as
`children` or props are not imported by it, so they stay on the server and
arrive as already-rendered output.

That single asymmetry explains most boundary design:

```tsx
// ❌ marking the layout client pulls the whole tree into the bundle
'use client'
export default function Layout({ children }) { /* ... */ }

// ✅ keep the layout on the server; make only the interactive leaf a client entry
export default function Layout({ children }) {
  return <nav><Logo /><Search /></nav>   // Search is the 'use client' file
}
```

**A serialization error at the boundary is the real error.** Props crossing
server → client are serialized into the RSC payload; a class instance, a
function, a `URL`, a Symbol or a `Date`-bearing ORM row cannot make the trip.
The fix is almost never "wrap it in a Client Component" — it is to stop sending
the un-serializable thing and send the shape the UI renders. That is also the
security fix: returning a raw database row to the client publishes every column
on it.

Two more rules that fall out of the same graph:

- **Providers wrap `{children}`, not the tree.** A `'use client'` provider that
  accepts children keeps the subtree on the server. Render it as deep as it can
  go so the static parts stay static.
- **Environment poisoning is silent.** Only `NEXT_PUBLIC_*` variables reach the
  browser; anything else becomes an empty string in a client module — no error,
  just a request that fails at runtime with an empty `Authorization` header.
  `import 'server-only'` turns that into a build error instead. The
  `client-secret-env` rule in `audit-app-router.py` catches it statically.

Depth, interleaving patterns, and the third-party-component wrapper:
`references/server-client-boundary.md`.

## Caching: the reason this skill exists

Caching is where Next.js costs teams the most hours, because the defaults
inverted between majors and the failure mode is a *correct-looking* stale page.

**The mental model that survives version changes:** work is either (a) known at
build time, (b) cached with a stated lifetime, or (c) request-time. Every
caching bug is one of those three misclassified.

### Under Cache Components (`cacheComponents: true`)

```tsx
import { cacheLife, cacheTag } from 'next/cache'

async function BlogPosts() {
  'use cache'          // opt IN — this is the only thing that caches
  cacheLife('hours')   // ALWAYS state it; omitting it means the implicit 'default'
  cacheTag('posts')    // the handle you invalidate by
  return <List posts={await getPosts()} />
}
```

Non-negotiables:

- **Arguments and captured closure variables form the cache key.** Different
  inputs, different entries. That is also why a per-user value in scope silently
  multiplies your entries.
- **Request APIs cannot be read inside a cached scope** — `cookies()`,
  `headers()`, `searchParams`, and dynamic `params` throw
  `next-request-in-use-cache`, *and the restriction follows the call stack* into
  helpers. Read them outside and pass the value in as an argument.
- **Set `cacheLife` explicitly in every scope.** Without it, an inner short-lived
  cache can silently shorten the outer one (and, if the outer has no explicit
  profile, that combination is a prerender-time build error).
- **The default store is per-instance and in-memory** — on serverless it often
  does not survive between requests. `'use cache: remote'` is the durable,
  shared variant, and it costs a network round trip.

| Profile | `stale` (client) | `revalidate` (server) | `expire` |
|---|---|---|---|
| `default` | 5 min | 15 min | never |
| `seconds` | 30 s | 1 s | 1 min |
| `minutes` | 5 min | 1 min | 1 hr |
| `hours` | 5 min | 1 hr | 1 day |
| `days` | 5 min | 1 day | 1 week |
| `weeks` | 5 min | 1 week | 30 days |
| `max` | 5 min | 30 days | 1 year |

`revalidate: 0` or `expire` under 5 minutes drops the content out of the
prerender entirely; `stale` under 30 seconds drops it out of prefetches. Of the
presets only `seconds` trips either. Full semantics, nesting rules,
`use cache: private` / `remote`: `references/cache-components.md`.

### Under the previous model (the 16.x default)

`fetch` is **not** cached unless you ask (`cache: 'force-cache'` or
`next: { revalidate: n }`); non-`fetch` work caches via `unstable_cache`; route
segments are steered by `dynamic`, `revalidate` and `fetchCache` exports. The
layers — request memoization, data cache, full route cache, client router cache
— and the ladder for finding which one is holding the stale value are in
`references/caching-model.md`.

### Invalidating after a mutation — pick by what must change

| API | Semantics | Use when |
|---|---|---|
| `updateTag(tag)` | expires **and** re-reads in the same response | read-your-own-writes; the user must see their change now. Actions only |
| `revalidateTag(tag, profile)` | stale-while-revalidate; **no** immediate re-render | shared content that tolerates eventual consistency |
| `revalidatePath(path)` | invalidate one URL | a single route is affected and tagging is overkill |
| `refresh()` | refetch uncached data only, cache untouched | the view depends on state outside the cache. Actions only |

The single-argument `revalidateTag('x')` form is deprecated in 16 — that is the
`revalidate-tag-single-arg` finding.

## Server Actions are public endpoints

An action is not a function call. `'use server'` compiles the implementation
away from the client bundle and leaves an **action ID that POSTs back to the
route**. Anyone who can send that POST can invoke it, with no form, no page
render, and no UI-level gate in the way.

```ts
'use server'
export async function completeItem(itemId: string) {
  const session = await auth()                       // 1. authenticate
  if (!session?.user) throw new Error('Unauthorized')
  const item = await db.item.findFirst({             // 2. authorize by ownership,
    where: { id: itemId, ownerId: session.user.id }, //    re-read from a trusted source
  })
  if (!item) return
  await db.item.update({ where: { id: item.id }, data: { completed: true } })
}
```

- **Take a reference, not the record.** A client legitimately says *which* item;
  it does not get to supply the row's contents or its ownership. Schema
  validation checks shape, never entitlement.
- **Rendering is not a gate.** "The form only renders for admins" is not
  authorization, and neither is a `proxy.ts` matcher — actions are POSTs to the
  route they live on, so moving one to another route can silently drop it out of
  matcher coverage.
- Framework protections you get for free: `Origin`-vs-`Host` CSRF check, a 1MB
  body cap, encrypted action IDs, dead-code elimination of unused actions, and
  closure-variable encryption. They are a floor, not a substitute.
- **Prefer a Route Handler** for GETs, webhooks, third-party callers, file
  streaming, anything needing custom status/headers, and anything that must run
  in parallel — the client dispatches actions **one at a time**, so
  `Promise.all` over actions is sequential.

Deployment, `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, and the "Failed to find Server
Action" skew failure: `references/server-actions.md`.

## Landmines

The non-obvious ones, in rough order of hours lost.

1. **`next dev` never caches pages.** Development renders on demand, so every
   caching bug is invisible until `next build && next start`. Verify caching
   against a production build, or you are testing a different program.
2. **A cached scope reading request data can pass `next build` and fail under
   `next start`.** On a dynamically-rendered route the `next-request-in-use-cache`
   error only surfaces when the route actually runs.
3. **The build hangs for 50 seconds, then dies.** A Promise created outside a
   `'use cache'` boundary (a `cookies()` store passed as a prop, a shared `Map`
   of in-flight fetches) is being awaited inside one. It cannot resolve during
   prerender. The error names the timeout, not the prop that caused it.
4. **`await params` at the top of a layout de-opts the whole subtree.** Awaiting
   request data high in the tree shrinks the static shell to nothing. Pass the
   promise down and await it inside a `<Suspense>` boundary instead — the same
   move applies to `cookies()`, `headers()` and `searchParams`.
5. **`proxy.ts` without a `matcher` runs on every request** — including
   `_next/static`, `_next/image` and `public/`. Auth logic there blocks your own
   CSS. Conversely, `_next/data` still runs proxy even when excluded, on purpose.
6. **Parallel route slots now require `default.js`.** Since 16, a `@slot`
   without one fails the build outright.
7. **Bots get a different render.** Crawlers are detected by user agent and
   served a full dynamic render instead of the static shell — so a shell built
   from build-time-only data can 500 for Googlebot while working for every human.
8. **Streaming dies quietly behind a buffering proxy.** nginx, and some cloud
   load balancers, buffer by default: PPR still "works", but the shell and the
   dynamic content land together and the entire TTFB benefit disappears.
9. **New deploy, "Failed to find Server Action".** Action IDs rotate per build
   (at most every 14 days even when source is unchanged). Multi-instance
   deployments need a shared `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`; clients
   mid-mutation need a retry path, not a stack trace.
10. **`revalidateTag()` only invalidates the instance it ran on.** Across pods,
    tag state must be synced by a cache handler implementing `refreshTags()`.
11. **`unstable_cache` and `'use cache'` are not the same store.** `use cache`
    entries are keyed by build id and never survive a deploy — even `remote`
    ones. If something must persist across deploys, it is not a `use cache` job.
12. **`Math.random()`/`Date.now()` inside a cached scope freeze one value for
    everyone.** Call `connection()` first and wrap in `<Suspense>` for a
    per-request value; cache it deliberately if one shared value is what you want.

## Bundled resources

| Resource | Use it when |
|---|---|
| [`scripts/audit-app-router.py`](scripts/audit-app-router.py) | Auditing or inheriting an app — 16 static rules for the landmines above, **gated on the project's detected Next.js major** |
| [`scripts/check-nextjs-facts.py`](scripts/check-nextjs-facts.py) | CI / freshness: are this skill's version facts still true? |
| [`assets/next.config.template.ts`](assets/next.config.template.ts) | Starting a 16.x config, or auditing an inherited one |
| [`assets/nextjs-facts.json`](assets/nextjs-facts.json) | The dated fact catalog the verifier reads |

The audit script takes this skill's own advice: it reads the project's Next.js
major from `node_modules/next` (or `package.json`) and **suppresses the rules
that postdate it** — eight of the sixteen describe breakages introduced in 15 or
16, so running them against a 14-era app would flag correct code. The verdict
line always states the major it gated on. Use `--assume-major N` when scanning a
bare subdirectory where the version cannot be read.

```bash
# Inherit an unfamiliar app: what will bite, worst first
python scripts/audit-app-router.py /path/to/project

# CI gate: block only on the errors
python scripts/audit-app-router.py --min-severity error .

# Machine-readable, for triage or a report
python scripts/audit-app-router.py --json . | jq '.data[] | select(.severity=="error")'

# Scanning a subtree with no package.json in reach
python scripts/audit-app-router.py --assume-major 15 ./packages/web/app

# Is this skill still describing reality?
python scripts/check-nextjs-facts.py --offline
```

## References

| File | Covers |
|---|---|
| [references/caching-model.md](references/caching-model.md) | The previous model: four cache layers, defaults per major, the stale-response debug ladder |
| [references/cache-components.md](references/cache-components.md) | `use cache`, cache keys, `cacheLife`/`cacheTag`, `private` vs `remote`, PPR and prefetch |
| [references/server-client-boundary.md](references/server-client-boundary.md) | `use client` graph, serialization, interleaving, context, environment poisoning |
| [references/server-actions.md](references/server-actions.md) | Endpoint model, auth/validation, action vs route handler, config, skew |
| [references/data-fetching-streaming.md](references/data-fetching-streaming.md) | Fetch patterns, waterfalls, Suspense/`loading.tsx`, what a loading state costs |
| [references/routing-and-rendering.md](references/routing-and-rendering.md) | File conventions, async `params`, dynamic/parallel/intercepting routes, metadata |
| [references/proxy-and-runtimes.md](references/proxy-and-runtimes.md) | `proxy.ts`, matchers, execution order, Node vs Edge runtime API gaps |
| [references/deployment.md](references/deployment.md) | Self-hosting, Docker, multi-instance, CDN behaviour, the Cloudflare path |
| [references/upgrading.md](references/upgrading.md) | 14 -> 15 -> 16 deltas (which are silent), Cache Components adoption, Pages -> App |
| [references/optimization.md](references/optimization.md) | `next/font`, `next/script` strategies, image props, bundle and build speed |
| [references/testing.md](references/testing.md) | The shifted pyramid: async Server Components are E2E-only; action security tests; `instant()` |

## Cross-references

- **`react-ops`** — React itself: hooks, component architecture, state, the
  React-level Server Components model.
- **`typescript-ops`** — the type system behind `PageProps`/`LayoutProps` and
  strict-mode discipline.
- **`tailwind-ops`** — styling; **`payloadcms-ops`** — Payload 3, which is
  Next.js-native and inherits every boundary rule here.
- **`cloudflare-ops`** / **`hono-ops`** — the Workers runtime, bindings and
  Hono-based APIs. Next.js on Cloudflare goes through `@opennextjs/cloudflare`;
  see `references/deployment.md` for the seam, and those skills for the platform.
- **`auth-ops`** — session and token design that Server Actions depend on;
  **`testing-ops`** — the test strategy this framework's boundaries need.
