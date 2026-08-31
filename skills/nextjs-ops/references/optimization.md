# Optimization — fonts, scripts, images, bundle

Verified against Next.js 16.3.3 docs, 2026-08-30.

`perf-ops` owns profiling method (how to measure, flamegraphs, load testing).
This file owns the Next.js-specific levers and the order to pull them in.

> **Order matters more than any individual lever.** The rendering and caching
> decisions in [cache-components.md](cache-components.md) and
> [data-fetching-streaming.md](data-fetching-streaming.md) dominate everything
> here: a route that blocks on an uncached database read is not going to be
> rescued by a smaller bundle. Fix what the page *waits* for, then what it
> *ships*, then trim.

## Fonts — `next/font`

`next/font` downloads font files at **build time** and self-hosts them from your
own origin. That removes the third-party request to Google Fonts entirely, which
is a privacy property as much as a performance one.

```tsx
// app/layout.tsx — load once at module scope, never inside a component
import { Inter } from 'next/font/google'

const inter = Inter({ subsets: ['latin'], display: 'swap' })

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en" className={inter.className}><body>{children}</body></html>
}
```

The details that matter:

- **Module scope, always.** A font call inside a component body re-runs per
  render and defeats the build-time handling.
- **`subsets` is not optional in practice.** Without it you ship glyph ranges
  nobody on the page will use.
- **Zero layout shift is the headline feature**: Next.js computes a size-adjusted
  fallback so the swap does not reflow. That only holds if you let it manage the
  fallback rather than hand-writing a `font-family` stack that bypasses it.
- **Local fonts** use `next/font/local` and get the same treatment.
- **Variable fonts** are usually the smaller total download when you use more
  than two weights — one file instead of four.

## Scripts — `next/script`

Four strategies. Picking the wrong one is how a tag manager ends up blocking
first paint.

| Strategy | When it loads | For |
|---|---|---|
| `beforeInteractive` | Injected into the initial HTML, before any Next.js module | Bot detectors, cookie-consent managers. **Root layout only** |
| `afterInteractive` | **Default.** Client-side, after some hydration | Tag managers, analytics |
| `lazyOnload` | Browser idle time, after everything else | Chat widgets, social embeds |
| `worker` | A web worker | **Experimental, and does not work in the App Router** — `pages/` only, behind `experimental.nextScriptWorkers` |

- `beforeInteractive` scripts are always injected into `<head>` regardless of
  where you place the component, and run **once per document load** — a client
  navigation does not re-run them, including one that only changes a root param
  such as `/en` → `/fi`.
- `onLoad`, `onReady` and `onError` are **Client Component only**. `onLoad` and
  `onError` cannot be combined with `beforeInteractive`; use `onReady` there.
- `onReady` fires on first load *and* every subsequent remount — the right hook
  for anything that must re-instantiate after a route change (a map embed).

The most common real win is demoting a script nobody needs early from the
default `afterInteractive` down to `lazyOnload`.

## Images — `next/image`

The component's job is to stop the three classic image failures: no layout
shift, no oversized download, no render-blocking decode.

- **`sizes` is the one people skip and the one that matters.** Without an
  accurate `sizes`, the browser assumes full viewport width and picks a far
  larger source than the layout needs.
- **`priority`** on the LCP image only. On everything else it competes with the
  content that actually matters.
- **`fill` + a positioned parent** for unknown intrinsic dimensions; otherwise
  give real `width`/`height` so the box is reserved.
- **`placeholder="blur"`** is free for static imports; remote images need
  `blurDataURL`.

16.x defaults worth restating in your own config so they are choices (see
[deployment.md](deployment.md) for the full list): `qualities` is `[75]` and the
`quality` prop is **coerced to the nearest listed value**, so `quality={90}`
silently becomes 75 until you list it; `minimumCacheTTL` is 14400s.

Use `remotePatterns`, never the deprecated `images.domains` — that is the
`images-domains-config` finding in `audit-app-router.py`.

## Bundle

### The boundary is the biggest lever

Everything a `'use client'` module imports ships to the browser, transitively.
The single largest bundle win in most App Router apps is moving the directive
from a layout to the interactive leaf — which is why
`client-component-route-file` is a rule in the audit script. See
[server-client-boundary.md](server-client-boundary.md).

### `next/dynamic`

For genuinely heavy, genuinely optional client code — a rich text editor, a
charting library, a modal's contents:

```tsx
const Chart = dynamic(() => import('./chart'), { ssr: false, loading: () => <Skeleton /> })
```

`ssr: false` is only legal in a Client Component. Reach for this when the code
is both large and not needed for first paint; used reflexively it just adds
request waterfalls.

### `experimental.optimizePackageImports`

Barrel-file packages export hundreds of modules; importing one named export can
pull the lot. This makes the import load only what you use.

```js
// next.config.js
module.exports = {
  experimental: {
    optimizePackageImports: ['my-barrel-package'],
  },
}
```

**Still `experimental` in 16.3.3, and the docs explicitly say it is not
recommended for production** — treat it as a measured experiment, not a default.
A long list is already optimized automatically (`lucide-react`, `date-fns`,
`lodash-es`, `@mui/material`, `@mui/icons-material`, `recharts`,
`@headlessui/react`, `@heroicons/react/*`, `react-icons/*`, `rxjs`, `antd`,
`effect`, and more), so check before adding one: you may be configuring
something you already have.

### Measuring

```bash
npx @next/bundle-analyzer     # wire it into next.config, then build
next build                    # per-route First Load JS, and the rendering mode
```

Read the `next build` table before reaching for tooling. It gives First Load JS
per route *and* whether each route is static or dynamic — and the rendering mode
is usually the more expensive of the two problems.

## Build and dev speed

16.x moved most of this into defaults; the remaining knobs are small:

- **Turbopack is the default bundler.** `--webpack` opts out, which also opts
  out of the speedups.
- **Filesystem caching is on by default in 16.3** for both dev and build; CI
  gains need the cache directory to persist between runs to matter.
- **TypeScript 7** can be used for `next build` type-checking by bumping the
  local dependency — a large win on big codebases.
- **React Compiler** (`reactCompiler: true`) auto-memoizes and is stable, but is
  **not** on by default and *increases* build time via Babel. The experimental
  `turbopackRustReactCompiler` removes the Babel round trip, with the gain
  conditional on having no other Babel transforms.

## What to check, in order

1. `next build` — is every route in the rendering mode you expect?
2. Does anything block the shell that should be behind `<Suspense>` or `'use cache'`?
3. Is the `'use client'` boundary at the leaf, or at a layout?
4. Fonts at module scope with `subsets`; LCP image with `priority` and `sizes`.
5. Third-party scripts demoted to the latest strategy that still works.
6. Only then: analyzer, `next/dynamic`, package-import optimization.
