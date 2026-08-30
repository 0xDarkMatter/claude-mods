/**
 * next.config.ts starter — Next.js 16.x, App Router, Cache Components.
 *
 * Every option below is either a deliberate default this skill recommends or an
 * ADAPT point marked as such. Delete what you do not need; an unexplained flag
 * in a config file is how a team inherits behaviour nobody chose.
 *
 * Verified against Next.js 16.3.3 (2026-08-30). The version-gated names here
 * (cacheComponents, partialPrefetching, cacheLife, cacheHandlers) are asserted
 * by scripts/check-nextjs-facts.py.
 */
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  // --- Rendering + caching model -------------------------------------------
  // Cache Components is the explicit model: nothing is cached unless a
  // `'use cache'` scope says so, and Partial Prerendering becomes the default
  // rendering strategy. Turning this ON is a semantic change to every route —
  // read references/cache-components.md before flipping it on an existing app,
  // and migrate with the guide rather than route-by-route guesswork.
  // Leave it OFF and you are on the previous model (references/caching-model.md).
  cacheComponents: true,

  // Prefetches each route's App Shell so client navigations render instantly.
  // Pairs with cacheComponents; this is opt-in in 16.x and slated to become the
  // default in a later major.
  partialPrefetching: true,

  // ADAPT: name the cache lifetimes your domain actually has, rather than
  // scattering inline `cacheLife({ revalidate: 900 })` objects across the tree.
  // Built-in profiles (default/seconds/minutes/hours/days/weeks/max) still work;
  // redefining one changes it everywhere, so prefer a new name over overloading
  // `hours` — a reader expects `hours` to mean hours.
  cacheLife: {
    editorial: {
      stale: 600, //      10 min — how long the CLIENT reuses it without asking
      revalidate: 3600, //  1 hr — how often the SERVER refreshes in background
      expire: 86400, //     1 day — after this with no traffic, next read blocks
    },
  },

  // ADAPT (multi-instance only): the default `use cache` store is per-instance
  // and in-memory, so on serverless it rarely survives between requests and on
  // Kubernetes every pod holds its own copy. Point `'use cache: remote'` at a
  // shared handler (Redis/KV) when a high hit rate justifies the round trip.
  // cacheHandlers: {
  //   remote: require.resolve('./cache-handler.mjs'),
  // },

  // --- Images ---------------------------------------------------------------
  images: {
    // remotePatterns, never the deprecated `domains` array: patterns constrain
    // protocol, port and pathname, so a compromised host can't serve arbitrary
    // paths through your optimizer.
    remotePatterns: [
      { protocol: 'https', hostname: 'images.example.com', pathname: '/media/**' },
    ],
    // 16.x defaults, restated so they are a choice and not an accident:
    // qualities defaults to [75] and the `quality` prop is coerced to the
    // nearest listed value; minimumCacheTTL defaults to 14400 (4 hours).
    qualities: [75],
    minimumCacheTTL: 14400,
  },

  // --- Deployment identity --------------------------------------------------
  // ADAPT (multi-instance / rolling deploys): a stable deployment id is what
  // lets Next.js detect version skew and fall back to a hard navigation instead
  // of serving a client assets from a build that no longer exists. When set, it
  // also replaces the build id in `use cache` keys, so generateBuildId is inert.
  deploymentId: process.env.DEPLOYMENT_VERSION,

  // --- Self-hosting behind a buffering proxy --------------------------------
  // Streaming only works end to end if nothing buffers the response. nginx
  // buffers by default; this header switches that off. Without it PPR still
  // "works" but the shell and the dynamic content arrive together, which
  // silently removes the entire TTFB benefit you enabled PPR for.
  async headers() {
    return [
      {
        source: '/:path*{/}?',
        headers: [{ key: 'X-Accel-Buffering', value: 'no' }],
      },
    ]
  },

  // --- Server Actions -------------------------------------------------------
  // ADAPT: only when you actually terminate TLS on another domain (proxy/CDN)
  // or accept payloads over the 1MB default. Widening allowedOrigins weakens
  // the Origin-vs-Host CSRF check, so list exact hosts, never a bare wildcard.
  // experimental: {
  //   serverActions: {
  //     allowedOrigins: ['my-proxy.example.com'],
  //     bodySizeLimit: '2mb',
  //   },
  // },
}

export default nextConfig
