# Worked case: Astro on Cloudflare Workers

Evidence labels are defined in `SKILL.md`. Code read against `@sentry/astro` 11.10.0,
`@sentry/cloudflare` 11.10.0 and `astro` 7.4.5, on 2026-11-06. **[measured]** here means one real
setup: Route B on Astro 7.3.5, `@sentry/cloudflare` 11.10.0 and wrangler 4.139.0, production build
under local workerd on Windows. No event from that setup has yet been sent to real Sentry.

## Contents

- Pick the route
- Where errors get caught
- Route A: the official integration
- Route B: server only, no client SDK
- Landmines
- Open questions
- Size

## Pick the route

Sentry has a dedicated guide: `docs.sentry.io/platforms/javascript/guides/cloudflare/frameworks/astro/`.
The main Astro guide says Workers aren't covered and points there, so a keyword search of
`@sentry/astro`'s README finds nothing about Cloudflare, even though the package ships a Cloudflare
integration [code].

| Your setup | Route | Server config |
|---|---|---|
| Astro 6+, `@astrojs/cloudflare` v13+ | Custom entry point, `withSentry` around Astro's handler [docs] | In the entry file |
| Astro 3-5, adapter v12 | `@sentry/astro` detects the adapter and wraps the Worker [docs] | **Environment variables only**, so you can't set `beforeSend` or `dataCollection` this way [inferred] |
| Cloudflare Pages | `sentryPagesPlugin` in `functions/_middleware.js` [docs] | In the plugin callback |

If you need the strict baseline, the Astro 3-5 route's env-only config doesn't reach it. That alone
is a reason to upgrade first.

## Where errors get caught

This is the question that decides the design. Astro 7.4.5 [code, not run]:

1. A page or endpoint throws inside `handlePages`, which is the `next` callback at the end of the
   middleware chain, so the throw reaches any middleware awaiting `next()`.
2. Astro's standard request path then catches it and renders the 500 page, returning a `Response`.
3. The Worker's `fetch` therefore resolves normally.

The composable `astro/fetch` pipeline is different. It rethrows errors from the route so the host
framework can handle them [code], so a custom fetch handler may reach `withSentry` directly.

And `withSentry` only captures throws. A returned 500 sends nothing [measured with a stand-in
handler]. So **render errors never reach a bare `withSentry`**. On a real Worker build, a throw in a
page or API route produced no event with `withSentry` alone, while a throw at Worker level, on a
route Astro doesn't handle, and in `scheduled` did reach it [measured]. Capture has to happen in
middleware as well.

`@sentry/astro` adds that: its integration registers a `pre` middleware that captures errors thrown
by `next()`, unless `autoInstrumentation.requestHandler` is `false` [code; not run on Workers]. A throw
during streaming, after the response has started, is a separate case nobody here has checked [open].

**A page throw can reach middleware twice.** On that build, one page throw hit the middleware's catch
twice, as two distinct `Error` objects about 9 ms apart, because Astro re-enters for its error page.
Sentry's dedupe didn't merge them, and neither did an identity check. An API throw was caught once
[measured]. If you write the middleware yourself, drop a repeat of the same name and message within a
short window. Route A's middleware has a `__sentry_wrapped__` guard on `locals` [code], but whether it
prevents this is [open]: look for duplicates in your canary run.

## Route A: the official integration

Follow the guide, using the privacy baseline instead of its demo options. The shape [docs]:

```jsonc
// wrangler.jsonc
{
  "main": "./sentry.server.config.ts",
  "compatibility_flags": ["nodejs_compat"],
  "compatibility_date": "<recent date>"
}
```

```ts
// sentry.server.config.ts
import * as Sentry from "@sentry/cloudflare";
import handler from "@astrojs/cloudflare/entrypoints/server";
import { STRICT_DATA_COLLECTION, makeBeforeSend } from "./src/lib/scrub-event.mjs";

export default Sentry.withSentry(
  (env) => ({
    dsn: env.SENTRY_DSN,
    dataCollection: STRICT_DATA_COLLECTION,
    maxBreadcrumbs: 0,
    beforeSend: makeBeforeSend({ isSensitivePath: (p) => p.startsWith("/contact") }),
  }),
  handler,
);
```

```js
// astro.config.mjs: no org, project or token until you make the source map decision
integrations: [sentry({ sourcemaps: { disable: true }, telemetry: false })],
```

The client SDK loads from `sentry.client.config.ts` if present, and otherwise from a default init
[code]. To have no client SDK, set `enabled: { client: false }` [code].

To add a cron handler, put `scheduled` on the handler object before wrapping. `withSentry`
instruments the methods it finds on that object [code]. Astro's handler exports `fetch` only, so a
cron is yours to add.

## Route B: server only, no client SDK

`@sentry/cloudflare` alone, no `@sentry/astro`, gives you a smaller install and no browser bundle.
Then you write the capture in your own Astro middleware, since nothing else catches render errors.
This is the route that was measured.

The middleware also runs in Astro's Node target, so it must not import the Cloudflare SDK. The
measured setup has the module the Worker entry loads set a hook on `globalThis`, and the middleware
calls the hook if it exists. Elsewhere there is no hook, and nothing happens:

```ts
// In the module the Worker entry loads, which is the only place that imports the SDK
import * as Sentry from "@sentry/cloudflare";
globalThis.__reportError = (error: unknown) => Sentry.captureException(error);
```

```ts
// src/middleware.ts: the catch sees the throw before Astro renders the 500 page
import { defineMiddleware } from "astro:middleware";

const SEEN_WINDOW_MS = 2000;  // a page throw can arrive twice, as two distinct Error objects
let last = { key: "", at: 0 };

export const onRequest = defineMiddleware(async (_ctx, next) => {
  try {
    return await next();
  } catch (error) {
    const key = error instanceof Error ? `${error.name}:${error.message}` : String(error);
    const now = Date.now();
    if (key !== last.key || now - last.at > SEEN_WINDOW_MS) {
      globalThis.__reportError?.(error);
    }
    last = { key, at: now };
    throw error;  // keep Astro's normal 500 handling
  }
});
```

The approach is measured: report, rethrow, and a 2 s drop on name and message. This listing is a
reduced version of it, so test your own. The module-level `last` is shared by concurrent requests in
an isolate, so two requests hitting the same error within the window report once, which is usually
fine for a low-traffic site [inferred].

Choosing no DSN: the measured setup skips the `withSentry` wrap per request when `SENTRY_DSN` is unset,
so the SDK is never initialised. Seven requests sent nothing [measured].

## Landmines

- **Middleware also runs in any Node target.** So keep `@sentry/cloudflare` out of it, as in Route B
  [measured in a real setup].
- **A crash can look like a 404.** With a root catch-all route and no `500.astro`, production Astro
  matched `/500` against the catch-all, which answered 404. Dev matches exactly and answers 500, so
  dev hides it [measured]. Add a `500.astro`, and test crashes on the production build.
- **`@sentry/astro` resolves differently by runtime.** Its exports map offers `node`, `browser` and
  `import` conditions and none for workerd, so plain `import "@sentry/astro"` in server code on
  Workers may give you the client build [inferred from the exports map]. On the server, call Sentry
  through `@sentry/cloudflare`.
- **`@sentry/astro` depends on `@sentry/node` and `@sentry/browser`**, and its middleware imports
  from `@sentry/node` [code]. That is expected on this route. Measure your bundle.
- **`astro dev` doesn't prove this setup.** It doesn't exercise the Worker entry [measured], and the
  integration skips wrapping under `dev` [code]. Use the production build under `wrangler dev`.
- **Installing the integration on Cloudflare without `@sentry/cloudflare` exits the build** with an
  error [code]. Install both.

## Open questions

- [open] `sentry.server.config.ts` plays two roles here. It is the Worker entry, and the integration
  also finds that default filename and imports it into SSR pages and the middleware [code]. The docs
  tell you to use this name, so it presumably works, but we haven't seen whether it runs twice or
  what a circular import does here. Watch for a doubled init.
- [open] The integration's Vite plugin also wraps entries named `virtual:cloudflare/worker-entry`
  with `withSentry(() => undefined, ...)` [code]. Whether that applies on top of a custom entry isn't
  established. `ensureInstrumented` suggests double wrapping is guarded [inferred].
- [open] Whether `getClient()` inside the auto middleware finds the client `withSentry` created.
  The middleware passes through silently without one [code], so a missing capture would look like no
  error. A canary thrown from a page answers this at once.

## Size

Route B on a real site added about 411 KB raw and 100 KB gzipped: 17,286,807 to 17,698,166 bytes raw,
and 4,220,785 to 4,320,522 bytes gzipped [measured]. That sums the `.js`, `.mjs` and `.wasm` files
under `dist/server`, gzipped per file, so it isn't wrangler's final bundle. Startup time wasn't
measured. Measure yours from build output.
