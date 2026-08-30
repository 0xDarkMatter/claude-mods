# Routing and Rendering — conventions, async params, advanced routes

Verified against Next.js 16.3.3 docs, 2026-08-25.

## File conventions

| File | Role | Notes |
|---|---|---|
| `layout.tsx` | Shared shell for a segment and everything below | Persists across navigation; does **not** re-render on route change within it. The root layout must render `<html>` and `<body>` |
| `page.tsx` | The route's UI; makes the segment publicly routable | A directory without one is not a route |
| `loading.tsx` | Suspense fallback for the whole segment | Sugar for wrapping the segment in `<Suspense>` |
| `error.tsx` | Route-level error boundary | Client Component by definition; does not catch errors in the *same* segment's layout |
| `not-found.tsx` | Rendered by `notFound()` and for unmatched URLs | |
| `default.tsx` | Fallback for a parallel route slot | **Required for every slot since 16 — builds fail without it** |
| `route.ts` | Route Handler (HTTP verbs) | Cannot coexist with `page.tsx` in the same segment |
| `template.tsx` | Like a layout but remounts per navigation | Reach for it only when you need the remount |
| `proxy.ts` | Request interception, project root | See [proxy-and-runtimes.md](proxy-and-runtimes.md) |

Folders in parentheses `(group)` organise without adding a URL segment; folders
with a leading underscore `_private` are excluded from routing entirely.

## Async params — the 15.0 breaking change

`params`, `searchParams`, `cookies()`, `headers()` and `draftMode()` are all
**Promises**. Synchronous access was removed in 16; there is no fallback path.

```tsx
// ✅
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
}
```

Metadata image routes changed with them: `params` is async there too, and the
`id` from `generateImageMetadata` arrives as `Promise<string>`.

`npx @next/codemod@canary upgrade latest` handles the mechanical half of this
migration. `audit-app-router.py`'s `sync-params-prop` and `sync-request-api`
rules catch what the codemod misses (hand-written types, helper functions).

### Typed route helpers

Next.js generates `PageProps<'/route'>` and `LayoutProps<'/route'>` from your
actual route tree, so the param shape is checked rather than asserted:

```tsx
export default async function PostPage(props: PageProps<'/[lang]/posts/[slug]'>) {
  const { slug } = await props.params
}
```

Types are generated during `next dev`/`next build`, or on demand with
`next typegen` — worth wiring into CI so a renamed segment fails type-check
rather than at runtime.

### Root params

Params defined *above* the root layout (the classic `[lang]`) are effectively
global, and prop-drilling them was the standing complaint. Since 16.3:

```tsx
import { lang } from 'next/root-params'

export default async function Page() {
  const language = await lang()
}
```

Root params work inside `use cache` scopes, and **only the ones a cached
function actually reads join its cache key**. Currently Server Components only —
not route handlers or Server Actions. (The older `unstable_rootParams()` was
removed in 16.)

## Static generation of dynamic routes

```tsx
export async function generateStaticParams() {
  const posts = await getPosts()
  return posts.map((p) => ({ slug: p.slug }))
}
```

Listed URLs are prerendered at build time. What happens to the rest depends on
the model:

- **Previous model:** unlisted params render on demand and are cached per the
  route's `revalidate` (classic ISR).
- **Cache Components:** an unlisted URL is served the **App Shell** instantly on
  first visit, then upgraded in the background with its now-known params and
  cached for the next visitor. You get the loading shell *and* the eventual
  prerender, which the old model made you choose between.

`generateStaticParams` is often the highest-leverage change available on a slow
route: prerendering the top 200 URLs converts the common case from a render into
a file read.

## Parallel and intercepting routes

**Parallel routes** (`@slot`) render several independent subtrees into one
layout, each with its own loading and error states:

```
app/dashboard/
├── layout.tsx        // receives { children, analytics, team }
├── page.tsx
├── @analytics/page.tsx
├── @analytics/default.tsx   ← required
├── @team/page.tsx
└── @team/default.tsx        ← required
```

`default.tsx` is what a slot renders when the current URL does not match it —
on a hard navigation, or a soft one that never activated the slot. **Since 16
every slot needs one and the build fails otherwise.** Returning `null` or
calling `notFound()` reproduces the old implicit behaviour. Note also that
parallel slots are rendered as separate chunks *whether or not they are
displayed*, so an expensive slot costs even when hidden.

**Intercepting routes** (`(.)`, `(..)`, `(...)`) render a route in the current
layout's context on a soft navigation while a hard load gets the real page — the
photo-modal pattern. Combined with a parallel slot, the modal is a slot and the
full page is the fallback.

## Metadata

```tsx
export const metadata: Metadata = { title: 'Static title' }

export async function generateMetadata(props: PageProps<'/blog/[slug]'>) {
  const { slug } = await props.params
  return { title: (await getPost(slug)).title }
}
```

Under Cache Components, uncached fetches and runtime reads inside
`generateMetadata` and `generateViewport` surface the same insights and errors
they would in the page — metadata is not a loophole in the rendering rules.
File conventions (`opengraph-image.tsx`, `icon.tsx`, `sitemap.ts`, `robots.ts`)
cover the asset side.

## Rendering strategy, read off the build

`next build` prints the rendering mode of every route. Read it. It is the
cheapest available answer to "is this page static?", and it is the fastest way
to notice that one added `cookies()` call turned a static marketing page
dynamic.

Under Cache Components, the framework goes further: it *requires* every route to
produce a static shell, and surfaces a validation insight naming the route and
the fix (cache the access, move it behind a `<Suspense>` boundary, or opt the
route out) when one cannot.

## Route Handlers

`route.ts` exports HTTP verb functions. Use them for GETs, webhooks, third-party
callers, custom headers/status, and streaming or binary responses — see
[server-actions.md](server-actions.md) for the full action-vs-handler split.
With Cache Components enabled, **`GET` route handlers follow the same
prerendering model as pages**, which surprises people who expect a handler to be
dynamic by default.

## Notable removals and behaviour changes in 16

| Removed / changed | Replacement |
|---|---|
| Sync `params`/`searchParams`/`cookies()`/`headers()`/`draftMode()` | `await` them |
| `experimental.ppr`, `export const experimental_ppr` | `cacheComponents` |
| `experimental.dynamicIO` | renamed `cacheComponents` |
| `unstable_rootParams()` | `next/root-params` (16.3) |
| `next lint` | Biome or ESLint directly; `next build` no longer lints |
| `serverRuntimeConfig`, `publicRuntimeConfig` | environment variables |
| AMP support | — (fully removed) |
| Automatic `scroll-behavior: smooth` | `data-scroll-behavior="smooth"` on the document |
| Parallel slots without `default.js` | now a build failure |
| Turbopack | now the default bundler (`next build --webpack` to opt out) |
| Node.js 18 | Node.js 20.9+, TypeScript 5.1+ |
