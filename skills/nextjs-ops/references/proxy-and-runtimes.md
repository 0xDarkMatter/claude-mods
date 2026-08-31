# `proxy.ts` and the Runtimes

Verified against Next.js 16.3.3 docs, 2026-08-25.

## Middleware is now Proxy

Next.js 16 renamed `middleware.ts` to `proxy.ts`. `middleware.ts` still works
but is deprecated and will be removed. The rename is a statement of intent: the
team considers this feature a last resort, and "middleware" invited Express-style
misuse.

```bash
npx @next/codemod@canary middleware-to-proxy .
```

```ts
// proxy.ts — project root, or src/, alongside app/
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

export function proxy(request: NextRequest) {
  return NextResponse.redirect(new URL('/home', request.url))
}

export const config = { matcher: '/about/:path*' }
```

Default or named `proxy` export; one file per project (import modules into it if
the logic grows); `proxy.page.ts` if you have customised `pageExtensions`.

**Version history worth carrying:** Node.js runtime for middleware became
experimental in 15.2, stable in 15.5, and the **default** in 16.0 when it became
`proxy`.

## What it is for, and what it is not

**Good uses:** header rewriting, A/B rewrites, programmatic redirects based on
request properties, optimistic auth redirects, CORS preflight.

**Not for:** slow data fetching, session management, or authorization as a
security boundary. `fetch` options `cache`, `next.revalidate` and `next.tags`
have **no effect** here. For plain redirects, `redirects` in `next.config.ts` is
cheaper and statically analysable.

It is designed to be deployable to a CDN edge separately from your app, so **do
not rely on shared modules or globals** between proxy and application code. Pass
information forward via headers, cookies, rewrites, redirects, or the URL.

## Matchers — the biggest footgun in the file

**Without a `matcher`, proxy runs on every request** — including
`_next/static`, `_next/image`, and everything in `public/`. Auth logic there
blocks your own CSS and images, and it is a favourite way to make a site
mysteriously unstyled in production.

```js
export const config = {
  matcher: [
    '/((?!api|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)',
  ],
}
```

Rules:

- Matcher values must be **statically analysable constants**. A variable is
  silently ignored.
- `source` must start with `/`; supports named params (`:path`), modifiers
  (`*` zero-or-more, `?` zero-or-one, `+` one-or-more), parenthesised regex, and
  is anchored to the start of the path (path-to-regexp syntax).
- Object form adds `has`, `missing` (header/query/cookie conditions) and
  `locale: false`.
- **`_next/data` still runs proxy even when your negative matcher excludes it.**
  Deliberate: it stops you protecting a page and forgetting its data route.

## Execution order

1. `headers` from `next.config.js`
2. `redirects` from `next.config.js`
3. **Proxy**
4. `beforeFiles` rewrites
5. Filesystem routes (`public/`, `_next/static/`, `pages/`, `app/`)
6. `afterFiles` rewrites
7. Dynamic routes
8. `fallback` rewrites

> **Server Actions are not separate routes in this chain.** They are POSTs to
> the route they are used on, so a matcher that excludes a path also skips proxy
> for that path's actions — and moving an action during a refactor can silently
> remove its coverage. Authenticate inside every action; see
> [server-actions.md](server-actions.md).

## The API surface

```ts
export function proxy(request: NextRequest, event: NextFetchEvent) { … }
export const proxy: NextProxy = (request, event) => { … }   // shorthand type
```

- `request.cookies` — `get`, `getAll`, `set`, `delete`, `has`, `clear`.
- `response.cookies` — `get`, `getAll`, `set`, `delete`.
- `event.waitUntil(promise)` — keep the invocation alive for background work
  (logging, analytics) after the response is sent.
- Return a `Response`/`NextResponse` directly to answer without hitting a route.

**Setting request headers is not the same as setting response headers:**

```ts
const requestHeaders = new Headers(request.headers)
requestHeaders.set('x-user-id', id)

const response = NextResponse.next({ request: { headers: requestHeaders } })  // upstream
response.headers.set('x-served-by', 'proxy')                                  // to the client
```

`NextResponse.next({ headers })` — without the nested `request` — sends them to
the *client* instead. Keep headers small; oversized ones produce 431s at some
backends.

**RSC requests:** Next.js strips internal Flight headers (`rsc`,
`next-router-state-tree`, `next-router-prefetch`) from `request.headers` so you
cannot accidentally treat an RSC request differently from its HTML twin.
`NextResponse.rewrite()` propagates what is needed automatically; a hand-rolled
`fetch()` rewrite does not, and needs `skipProxyUrlNormalize` plus manual header
forwarding.

Advanced flags: `skipTrailingSlashRedirect` and `skipProxyUrlNormalize` in
`next.config.js`, both from 13.1.

### Unit testing (experimental, since 15.1)

```js
import { unstable_doesProxyMatch, isRewrite, getRewrittenUrl } from 'next/experimental/testing/server'

expect(unstable_doesProxyMatch({ config, nextConfig, url: '/test' })).toEqual(false)

const response = await proxy(new NextRequest('https://example.com/docs'))
expect(isRewrite(response)).toEqual(true)
```

Testing the matcher is worth doing: a matcher bug is invisible locally and
catastrophic in production.

## Node.js vs Edge runtime

**The Node.js runtime is the default and, in 16, the runtime for proxy.** The
`runtime` segment config option **is not available in proxy files and throws if
set**. Edge remains available for route segments via `export const runtime = 'edge'`,
but that is the deprecated path — reach for it only with a specific reason.

### What the Edge runtime does not have

- **No native Node.js APIs.** No filesystem, no `node:crypto` (only WebCrypto),
  no `node:net`, no `node:child_process`. Most database drivers that open TCP
  sockets are therefore out; HTTP-based clients are in.
- **No `require()`.** ES Modules only. `node_modules` work only if they ship ESM
  and avoid native APIs — which is where a working dependency suddenly fails
  after a runtime switch.
- **No dynamic code evaluation:** `eval`, `new Function(string)`,
  `WebAssembly.compile`, `WebAssembly.instantiate` are disabled. A transitive
  dependency containing an unreachable `eval` still trips this; relax it
  narrowly with `unstable_allowDynamic` globs.
- **No ISR.**
- `revalidate` segment values are unavailable under `runtime = 'edge'`.

### What it does have

`fetch`, `Request`/`Response`/`Headers`, `FormData`, `File`/`Blob`, `WebSocket`,
`URL`/`URLPattern`/`URLSearchParams`, the stream APIs, `TextEncoder`/`Decoder`,
`atob`/`btoa`, `crypto`/`SubtleCrypto`/`CryptoKey`, `structuredClone`, `Intl`,
`WebAssembly` (instantiation aside), timers, `process.env`, and a polyfilled
`AsyncLocalStorage`.

**The practical rule:** the Edge runtime is a *reduced* JavaScript environment,
not a faster Node. Since Node is now the default everywhere and has no API gaps,
choosing Edge should be a deliberate answer to a latency or placement question —
and if the answer is "I want to run at the edge", the honest comparison is a
Workers-native stack. See `cloudflare-ops` and `hono-ops`, and
[deployment.md](deployment.md) for running Next.js itself there.

## Self-hosting note

Proxy works with zero configuration under `next start`. It is **not** supported
in a static export, since it needs the incoming request. If you need full Node
APIs in request interception, the usual move is to do the work in a layout as a
Server Component (read `headers()`, `redirect()`) rather than in proxy at all,
or express it as a `redirects`/`rewrites` rule with header/cookie/query matching.
