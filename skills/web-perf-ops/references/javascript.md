# JavaScript: budgets, splitting, third-party tags, offloading

JavaScript costs twice: bytes on the network (LCP, FCP) and **main-thread time** to
parse, compile and run (INP, TBT). On a mid-range phone the second cost dominates.
Package versions checked on npm 2026-10-05.

## Contents

- [Measure first](#measure-first)
- [Budgets](#budgets)
- [Loading: defer, module, split](#loading-defer-module-split)
- [Build-tool levers (Vite, Laravel Mix)](#build-tool-levers-vite-laravel-mix)
- [Third-party tags and GTM](#third-party-tags-and-gtm)
- [Offloading: Partytown-style workers and server-side tagging](#offloading-partytown-style-workers-and-server-side-tagging)
- [Gotchas](#gotchas)

## Measure first

| Question | Tool |
|---|---|
| What is in my bundle? | `rollup-plugin-visualizer` (Vite/Rollup, v7), `webpack-bundle-analyzer` (Mix/webpack, v5), `source-map-explorer` (any build with source maps) |
| How much ships per page, compressed? | DevTools Network (filter JS, read transferred size), Lighthouse `total-byte-weight` |
| How much is unused at load? | DevTools Coverage; Lighthouse `unused-javascript` (still present in Lighthouse 13) |
| Which scripts block the main thread? | Lighthouse `bootup-time`, `mainthread-work-breakdown`, `third-parties-insight`; DevTools Performance (bottom-up by domain) |
| Which script hurt a real interaction? | RUM INP attribution `longestScript` (see [inp.md](inp.md)) |
| Old transpilation shipped to modern browsers? | Lighthouse `legacy-javascript-insight` |

## Budgets

Set a budget **per template type**, from today's numbers, and ratchet down. Starting points
that hold up for content sites on mid-range phones:

| Budget | Starting target | Enforced by |
|---|---|---|
| First-party JS on initial load (compressed) | <= 150-200 KB | `size-limit` (v14) on build output; Lighthouse CI `resource-summary` assertions ([budgets-ci.md](budgets-ci.md)) |
| Third-party JS on initial load | Inventory + an owner for every tag; total tracked | Tag audit; LHCI `resource-summary:third-party:size` assertion |
| Total Blocking Time (lab, mobile) | <= 200 ms | Lighthouse CI |
| Largest single chunk | <= ~100 KB compressed | `size-limit` per entry |

```json
// package.json - size-limit gates the built files in CI (fails the build when over)
"size-limit": [
  { "name": "app entry", "path": "web/dist/assets/app-*.js", "limit": "120 kB" },
  { "name": "vendor",    "path": "web/dist/assets/vendor-*.js", "limit": "80 kB" }
]
```

## Loading: defer, module, split

| Attribute | Behaviour | Use for |
|---|---|---|
| none (classic, in `<head>`) | Blocks parsing and rendering | Almost nothing. Tiny inline config at most |
| `defer` | Downloads in parallel, runs after parsing, in order | Classic scripts that need the DOM |
| `type="module"` | Deferred by default, strict mode, `import` support | Modern bundles (Vite output) |
| `async` | Runs as soon as it arrives, any order | Independent third parties (analytics) |
| `<link rel="modulepreload">` | Fetches and compiles a module early | Imported chunks of the entry (Vite injects these; Baseline: Firefox 115, Safari 17) |

Splitting rules:

- **Route/template-level splits**: a page that has no carousel should not download the
  carousel. Dynamic `import()` per component that is not on every page.
- **Below-the-fold and interaction-only code loads on demand**: modals, maps, video
  players, comment systems, search UIs. Load on visibility (`IntersectionObserver`) or
  first interaction.
- **Don't over-split**: dozens of tiny chunks add request and compile overhead. Aim for
  a few meaningful chunks per template.
- **Hydrate less**: on a server-rendered CMS site, mount Vue only on the islands that need
  it (`createApp` per widget), not on a root `#app` wrapping the whole page.

## Build-tool levers (Vite, Laravel Mix)

| Lever | Vite (8.x) | Laravel Mix (webpack 5) |
|---|---|---|
| Vendor split | Automatic chunking; `build.rollupOptions.output.manualChunks` for control | `mix.extract()` |
| Hashing for long-term caching | Default (`assets/app-[hash].js`) | `mix.version()` |
| Dynamic imports | Native `import()` | Native `import()` (webpack chunks) |
| Modern-only output | Default targets are Baseline-widely-available browsers | Set a modern `browserslist`; drop `core-js` polyfills you don't need |
| Legacy browsers | `@vitejs/plugin-legacy` (v8) adds a `nomodule` bundle. Only if analytics prove you need it | Usually the reason Mix bundles are large: IE-era Babel targets |
| Bundle report | `rollup-plugin-visualizer` | `webpack-bundle-analyzer` |

**Laravel Mix** has had no release since 6.0.49 (2022-06). It still builds, but it
won't get modern defaults. On Mix sites the quick wins are a modern `browserslist`,
`mix.extract()`, and removing unused polyfills. The real fix is moving to Vite; the
migration mechanics belong to `frontend-upgrade-ops` (Craft/Twig sites) or `migrate-ops`
(other stacks), not here. Measure the Mix build first so the cutover has a baseline.

**Vue 2 on a CMS site**: if templates are written in the DOM (Twig outputs `<my-widget>`
markup that Vue compiles in the browser), the page ships the **full build with the
template compiler**, about 30% more Vue. Precompiled single-file components need only
the runtime build. Vue 2 has been end-of-life since 2023-12-31; moving those widgets to
Vue 3 SFC islands, or to Alpine, is `frontend-upgrade-ops`.

## Third-party tags and GTM

Third parties are the most common cause of poor INP and TBT on marketing sites, and
the least owned. Treat each tag as a dependency with a cost and an owner.

| Step | Do |
|---|---|
| 1. Inventory | Export the GTM container; list every tag, trigger, owner, last-reviewed date. DevTools Performance -> bottom-up "by domain" for weight |
| 2. Delete | Paused tags, duplicated analytics (GA4 + a second GA4 config, two pixels for one platform), tags for campaigns that ended |
| 3. Re-trigger | Move non-essential tags from "Page View"/"Consent Initialization" to "Window Loaded" or a timer; replace "All Elements" click triggers with specific ones |
| 4. Consent | Load consent-gated tags only after consent (Google Consent Mode v2 for Google tags in the EEA). Stagger them after "Accept": firing all at once makes that click your worst INP |
| 5. Facades | Chat widgets, YouTube/Vimeo embeds, maps: a static placeholder that loads the real thing on click |
| 6. Custom HTML tags | They run as inline scripts on the main thread and show up as "anonymous" in traces. Replace with native tag templates where possible |

Load GTM itself `async` (the standard snippet does). The container is rarely the
problem; what it fires is.

## Offloading: Partytown-style workers and server-side tagging

| Approach | How | Fit |
|---|---|---|
| **`@qwik.dev/partytown`** (0.14) | Runs third-party scripts in a Web Worker, proxying synchronous DOM access back to the main thread | Analytics-style tags that mostly read the DOM and send beacons. Scripts that need synchronous DOM writes or user events (A/B testers, chat, consent UIs) break. Some vendors need a reverse proxy for CORS. **Still beta**; the old `@builder.io/partytown` package is deprecated (moved to QwikDev). Pilot one tag at a time with RUM before and after |
| **Server-side tagging** (server GTM container) | The browser sends one stream to your tagging server, which fans out to vendors | Removes vendor JS from the page entirely for supported vendors. Costs hosting and setup |
| **Edge-executed third parties** (e.g. Cloudflare Zaraz) | The CDN loads and runs tool integrations at the edge | Good fit when the site is already behind that CDN |
| **Delay until interaction / idle** | Load the tag on first scroll/click or `requestIdleCallback` | Simple and robust for chat, heatmaps and remarketing pixels; you lose data from bounces |

Offloading is a second step. Deleting tags and re-triggering them comes first: it is
free and cannot break anything.

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Lighthouse is fine, field INP is poor | Lighthouse runs consent-free and short; tags fire after consent and on interaction | Reproduce with consent accepted; read RUM `longestScript` |
| A/B testing anti-flicker snippet | Hides the page until the tool loads (up to its timeout) | Remove it, or cap the timeout hard; server-side experiments where possible |
| `defer` added to a script that others call inline | Inline code runs before the deferred file | Move the inline calls into the module, or queue them (`window.q = window.q || []`) |
| Jumping to Partytown first | Debugging gets much harder, savings are uncertain | Delete and re-trigger first; offload what is left |
| Shipping source maps publicly "for debugging" | Exposes source; harmless for perf only if served on demand | Upload to the error tracker; don't link them in production |
| Duplicate libraries across chunks (two lodash copies, moment + date-fns) | Separate entry points bundle their own copies | Shared vendor chunk; Lighthouse `duplicated-javascript-insight` |
