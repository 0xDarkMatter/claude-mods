# Testing a Next.js App

Verified against Next.js 16.3.3 docs, 2026-08-30.

`test-engineering` owns test strategy in general; `playwright-ops` and `cypress-ops`
own their runners. This file owns what is *different* about testing the App
Router — which is mostly a story about what you cannot unit-test and what to do
instead.

## The uncomfortable fact first

**Async Server Components are not supported by the React testing libraries.**
An `async function Page()` returning a promise of an element is not something
React Testing Library or the jsdom-based runners can render. The official
recommendation is end-to-end tests for anything that is an async Server
Component.

This is not a temporary tooling gap to route around with a clever mock — it
falls out of the RSC model. The practical consequence is a **shifted test
pyramid**:

| Layer | What it covers here |
|---|---|
| **Unit** | Pure logic, data-access functions, validators, and Client Components. The bulk of your assertions still live here — but you get there by *extracting* logic out of components |
| **Integration** | Route Handlers, Server Actions called as functions, `proxy.ts` matchers |
| **E2E** | Anything that is an async Server Component, streaming behaviour, navigation, and the whole rendered route |

The design response: **keep components thin and put the logic somewhere
testable.** A Server Component that awaits a well-tested data function and maps
it to JSX barely needs a test of its own; a Server Component with branching
business logic inside it is untestable by construction, and that is the signal
to extract.

## Unit-testable surfaces

### Data access

The highest-value tests in most App Router codebases. A Data Access Layer — one
module owning auth, validation, and projection — is unit-testable in full and is
also where the security guarantees live (see
[server-actions.md](server-actions.md)).

```ts
// lib/items.ts — plain async functions, no framework
export async function completeItemFor(userId: string, itemId: string) { … }
```

Test that, then let the action be a three-line wrapper.

### Server Actions

An action is an exported async function. Import it and call it directly —
runtime imports like `cookies()` are the thing to mock, and *that* is an
argument for reading them in the caller rather than inside the action.

Test the security posture explicitly, because it is the part that has no UI:

- unauthenticated caller → rejected
- authenticated but non-owning caller → rejected (this is the one people skip)
- malformed input → rejected before any write
- happy path → exactly one write, and the returned shape carries no extra columns

Name these tests for the adversary, not the function: `deletes-another-users-item.test.ts`
tells the next reader what evil is being blocked.

### Route Handlers

Ordinary request-in/response-out functions. Construct a `Request`, call `GET`,
assert on the `Response` — status, headers, and body. No framework harness
needed.

### `proxy.ts`

Since 15.1, `next/experimental/testing/server` provides helpers, and the matcher
is worth testing precisely because a matcher bug is invisible locally and
catastrophic in production:

```js
import { unstable_doesProxyMatch, isRewrite, getRewrittenUrl } from 'next/experimental/testing/server'

expect(unstable_doesProxyMatch({ config, nextConfig, url: '/_next/static/chunk.js' })).toEqual(false)

const response = await proxy(new NextRequest('https://example.com/docs'))
expect(isRewrite(response)).toEqual(true)
expect(getRewrittenUrl(response)).toEqual('https://other-domain.com/docs')
```

Assert the **exclusions**, not just the inclusions. "Does it run on `/dashboard`"
is the easy half; "does it stay off `_next/static`" is the half that breaks the
site.

## End-to-end

E2E carries more weight here than in a client-rendered app, so it is worth
building deliberately rather than as an afterthought.

### Test the production build

```bash
next build && next start
```

`next dev` never caches pages, so **every caching behaviour is unobservable in
dev**. An E2E suite pointed at the dev server cannot catch a caching regression
at all — it is testing a different program.

### Guard instant navigation

Instant navigation is easy to lose by accident: a `cookies()` read added to a
shared header, a `<Suspense>` boundary moved during a refactor. The
`@next/playwright` `instant()` helper asserts what is visible **without waiting
for the network**, so the test fails whatever the cause:

```ts
import { expect, test } from '@playwright/test'
import { instant } from '@next/playwright'

test('product title is available immediately', async ({ page }) => {
  await page.goto('/products/shoes')
  await instant(page, async () => {
    await page.click('a[href="/products/hats"]')
    await expect(page.locator('h1')).toContainText('Baseball Cap')
    await expect(page.getByText('Checking inventory...')).toBeVisible()
  })
  await expect(page.getByText('12 in stock')).toBeVisible()
})
```

This is the closest thing the framework offers to a regression gate on rendering
architecture, and it is cheap. The DevTools Navigation Inspector and Instant
Insights panel are the interactive equivalents while developing.

### What else deserves E2E coverage

- **Streaming**: that the fallback appears *before* the slow content, not with it
  — the assertion that catches a buffering proxy (see
  [deployment.md](deployment.md)).
- **Form actions without JavaScript.** Progressive enhancement is a claim; a
  `javaScriptEnabled: false` context is the test that makes it true.
- **The bot path.** Crawlers get a full dynamic render rather than the shell, so
  a shell built from build-time-only data can 500 for Googlebot while working
  for every human. A test with a crawler user agent is the only cheap way to see
  it.

## Client Components

Ordinary React testing — `react-ops` and `test-engineering` own the patterns. Two
Next-specific notes:

- Mock `next/navigation` (`useRouter`, `usePathname`, `useSearchParams`), not
  `next/router` — that is the Pages Router module and mocking it in an App
  Router test silently does nothing.
- A Client Component still renders on the server first. If a test passes but
  production shows a hydration error, the cause is usually `window` or
  `Date`/`Math.random` read during render rather than in an effect.

## What not to test

- **Framework behaviour.** That `revalidateTag` invalidates a tag is Vercel's
  test, not yours. Test *your* invalidation choice — that a mutation makes the
  user's own change visible immediately, which is a `updateTag`-vs-`revalidateTag`
  decision with a real user-facing difference.
- **Cache timings.** Asserting a 15-minute revalidate produces a slow, flaky
  suite. Assert the *tag* is applied and that the mutation path calls the right
  invalidation API.

## Wiring

- **Vitest or Jest** for unit/integration. Async Server Components remain out of
  scope in both.
- **Playwright or Cypress** for E2E; `@next/playwright` only exists for
  Playwright, and `instant()` is a real reason to prefer it here.
- **Gate on the production build in CI**, and run
  `python scripts/audit-app-router.py --min-severity error .` alongside the
  suite — it catches the class of defect that has no natural test (a client
  module reading a secret env var, a `force-static` page silently emptying
  `cookies()`).
