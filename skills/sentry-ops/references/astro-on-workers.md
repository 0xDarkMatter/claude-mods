# Worked case: Astro on Cloudflare Workers

Evidence labels are defined in `SKILL.md`. Read against `@sentry/astro` 11.10.0,
`@sentry/cloudflare` 11.10.0 and `astro` 7.4.5, on 2026-11-06.

## Contents

- Pick the route
- Where errors get caught
- Route A: the official integration
- Route B: server only, no client SDK
- Landmines
- Open questions

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
handler]. So **render errors never reach a bare `withSentry`**: capture has to happen in middleware
[inferred from the two above]. This is what `@sentry/astro` adds: its integration registers a `pre`
middleware that captures errors thrown by `next()`, unless `autoInstrumentation.requestHandler` is
`false` [code].

Treat that as well supported but unrun until you see it in step 3 of
`references/prove-without-traffic.md`. A throw during streaming, after the response has started, is
a separate case that nobody here has checked [open].

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
Then you write the capture in your own Astro middleware, since nothing else catches render errors:

```ts
// src/middleware.ts: wrap next() so a throw is seen before Astro renders the 500 page
import { captureException } from "@sentry/core";  // see the landmine below
import { defineMiddleware } from "astro:middleware";

export const onRequest = defineMiddleware(async (_ctx, next) => {
  try {
    return await next();
  } catch (error) {
    captureException(error);
    throw error;  // keep Astro's normal 500 handling
  }
});
```

[open] This exact shape is a sketch, not something we've run. `@sentry/core` is the package both
SDKs build on, and `captureException` does nothing without a client [inferred]. It must resolve to
the same copy `@sentry/cloudflare` uses, so pin it to the same exact version.

Wait for the build's own results before you rely on this route over Route A.

## Landmines

- **Middleware also runs in `astro dev` and in any Node target.** Importing `@sentry/cloudflare` in
  middleware pulls a Worker SDK into those [hypothesis from a real setup; not verified here]. Keep
  that import in the Worker entry only.
- **`@sentry/astro` resolves differently by runtime.** Its exports map offers `node`, `browser` and
  `import` conditions and none for workerd, so plain `import "@sentry/astro"` in server code on
  Workers may give you the client build [inferred from the exports map]. On the server, call Sentry
  through `@sentry/cloudflare`.
- **`@sentry/astro` depends on `@sentry/node` and `@sentry/browser`**, and its middleware imports
  from `@sentry/node` [code]. That is expected on this route. Measure your bundle.
- **`astro dev` doesn't prove this setup.** The integration skips wrapping the Worker under `dev`
  [code]. Use the production build.
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
- [open] A real before/after bundle size for this setup, from your build output. The figures in
  `SKILL.md` are minimal entries, not this stack.
