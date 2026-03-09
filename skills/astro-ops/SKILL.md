---
name: astro-ops
description: "Astro framework patterns, islands architecture, content collections, rendering strategies, and deployment. Use for: astro, islands architecture, content collections, astro cloudflare, view transitions, partial hydration, astrojs, SSG, SSR, hybrid rendering, astro adapter."
allowed-tools: "Read Write Bash"
related-skills: [typescript-ops, tailwind-ops, javascript-ops]
---

# Astro Operations

Comprehensive patterns for Astro framework development: islands architecture, content collections, rendering strategies, view transitions, and multi-platform deployment.

## Rendering Strategy Decision Tree

```
Which rendering strategy?
│
├─ Is content mostly static (blog, docs, marketing)?
│  ├─ YES → Does it change less than daily?
│  │  ├─ YES → SSG (output: 'static')
│  │  │        Fastest TTFB, CDN-cacheable, zero runtime cost
│  │  └─ NO  → Hybrid (output: 'hybrid')
│  │           Default static + opt-in SSR per route
│  └─ NO  → Does every page need personalization?
│     ├─ YES → SSR (output: 'server')
│     │        Dynamic per-request, auth-aware, real-time data
│     └─ NO  → Hybrid (output: 'hybrid')
│              Static shell + server islands for dynamic parts
│
├─ Does the app need real-time interactivity (dashboard, SPA)?
│  ├─ YES → Is it a full SPA with client-side routing?
│  │  ├─ YES → Consider React/Vue SPA instead, or Astro + client:only
│  │  └─ NO  → Hybrid + islands architecture
│  │           Interactive islands in static pages
│  └─ NO  → SSG (output: 'static')
│
├─ Build time concerns (>10k pages)?
│  ├─ YES → Hybrid with on-demand rendering
│  │        Prerender popular pages, SSR the long tail
│  └─ NO  → SSG handles it fine
│
└─ Need edge computing (low latency globally)?
   ├─ YES → SSR + Cloudflare/Vercel Edge adapter
   └─ NO  → SSR + Node adapter or SSG
```

### Configuration

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';

// SSG (default) - all pages prerendered at build time
export default defineConfig({
  output: 'static',
});

// SSR - all pages rendered on request
export default defineConfig({
  output: 'server',
  adapter: cloudflare(), // or vercel(), netlify(), node()
});

// Hybrid - static default, opt-in SSR per page
export default defineConfig({
  output: 'hybrid',
  adapter: cloudflare(),
});
```

```astro
---
// In hybrid mode, opt OUT of prerendering for specific pages:
export const prerender = false;
// In SSR mode, opt IN to prerendering:
export const prerender = true;
---
```

## Islands Architecture Quick Reference

| Directive | Hydrates When | JS Shipped | Use Case |
|-----------|--------------|------------|----------|
| `client:load` | Immediately on page load | Full bundle | Above-fold interactive (nav, hero CTA) |
| `client:idle` | After page is idle (`requestIdleCallback`) | Full bundle | Below-fold interactive (comment form, chat) |
| `client:visible` | When scrolled into viewport | Full bundle | Far-down-page (footer widget, carousel) |
| `client:media` | When media query matches | Full bundle | Mobile-only nav, responsive components |
| `client:only="react"` | Immediately, skip SSR entirely | Full bundle | Components that can't SSR (canvas, WebGL) |
| (none) | Never - static HTML only | Zero JS | Static content, cards, headers |

```astro
---
import NavBar from '../components/NavBar.tsx';
import CommentForm from '../components/CommentForm.tsx';
import ImageCarousel from '../components/ImageCarousel.svelte';
import MobileMenu from '../components/MobileMenu.vue';
import ThreeScene from '../components/ThreeScene.tsx';
---

<!-- Loads immediately - critical interactivity -->
<NavBar client:load />

<!-- Loads after page is idle - non-critical -->
<CommentForm client:idle />

<!-- Loads when scrolled into view - lazy -->
<ImageCarousel client:visible />

<!-- Loads only on mobile -->
<MobileMenu client:media="(max-width: 768px)" />

<!-- Client-only, no SSR (WebGL can't run on server) -->
<ThreeScene client:only="react" />
```

## Content Collections Quick Start

### Define Schema

```typescript
// src/content.config.ts (Astro 5) or src/content/config.ts (Astro 4)
import { defineCollection, z, reference } from 'astro:content';
import { glob } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string().max(160),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    heroImage: z.string().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
    author: reference('authors'), // Reference another collection
  }),
});

const authors = defineCollection({
  loader: glob({ pattern: '**/*.json', base: './src/content/authors' }),
  schema: z.object({
    name: z.string(),
    avatar: z.string(),
    bio: z.string(),
    socials: z.object({
      twitter: z.string().optional(),
      github: z.string().optional(),
    }).optional(),
  }),
});

export const collections = { blog, authors };
```

### Query Collections

```astro
---
import { getCollection, getEntry } from 'astro:content';

// Get all non-draft blog posts, sorted by date
const posts = (await getCollection('blog', ({ data }) => !data.draft))
  .sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());

// Get a single entry
const post = await getEntry('blog', 'my-first-post');

// Resolve a reference
const author = await getEntry(post.data.author);

// Render content
const { Content, headings } = await post.render();
---

<Content />
```

## Project Structure Reference

```
project-root/
├── astro.config.mjs          # Astro configuration
├── tsconfig.json              # TypeScript config (extends astro/tsconfigs)
├── package.json
├── public/                    # Static assets (copied as-is)
│   ├── favicon.svg
│   ├── robots.txt
│   └── og-image.png
├── src/
│   ├── pages/                 # File-based routing
│   │   ├── index.astro        # → /
│   │   ├── about.astro        # → /about
│   │   ├── blog/
│   │   │   ├── index.astro    # → /blog
│   │   │   └── [slug].astro   # → /blog/:slug (dynamic)
│   │   ├── api/
│   │   │   └── search.ts      # → /api/search (API endpoint)
│   │   └── [...slug].astro    # → catch-all/404
│   ├── layouts/
│   │   ├── BaseLayout.astro   # HTML shell, <head>, global styles
│   │   └── BlogPost.astro     # Blog post layout
│   ├── components/
│   │   ├── Header.astro       # Static Astro component
│   │   ├── Footer.astro
│   │   ├── NavBar.tsx         # React island
│   │   └── Counter.svelte     # Svelte island
│   ├── content/               # Content collections source files
│   │   ├── blog/
│   │   │   ├── post-one.md
│   │   │   └── post-two.mdx
│   │   └── authors/
│   │       └── jane.json
│   ├── content.config.ts      # Collection schemas (Astro 5)
│   ├── middleware.ts           # Request/response middleware
│   ├── styles/
│   │   └── global.css
│   └── lib/                   # Shared utilities
│       ├── utils.ts
│       └── constants.ts
└── .env                       # Environment variables
```

## View Transitions Quick Reference

```astro
---
// src/layouts/BaseLayout.astro
import { ViewTransitions } from 'astro:transitions';
---

<html>
  <head>
    <ViewTransitions />
  </head>
  <body>
    <slot />
  </body>
</html>
```

### Transition Directives

```astro
<!-- Persist element across pages (keeps state, avoids re-render) -->
<audio transition:persist id="player">
  <source src="/music.mp3" />
</audio>

<!-- Named transition for animation pairing -->
<img transition:name="hero" src={post.heroImage} />

<!-- Custom animation -->
<div transition:animate="slide">Content</div>
<div transition:animate="fade">Content</div>
<div transition:animate="none">No animation</div>

<!-- Persist with name (for multiple persistent elements) -->
<video transition:persist="media-player" />
```

### Lifecycle Events

```astro
<script>
  document.addEventListener('astro:before-preparation', (e) => {
    // Before new page is fetched - cancel navigation, show loading
  });

  document.addEventListener('astro:after-preparation', (e) => {
    // New page fetched, before swap
  });

  document.addEventListener('astro:before-swap', (e) => {
    // Customize DOM swap behavior
  });

  document.addEventListener('astro:after-swap', () => {
    // DOM updated - reinitialize scripts
  });

  document.addEventListener('astro:page-load', () => {
    // Page fully loaded (fires on initial + every navigation)
    // Use this instead of DOMContentLoaded with View Transitions
  });
</script>
```

### Back/Forward Handling

```typescript
// astro.config.mjs
export default defineConfig({
  prefetch: {
    prefetchAll: true,         // Prefetch all links on hover
    defaultStrategy: 'hover',  // 'hover' | 'tap' | 'viewport' | 'load'
  },
});
```

```astro
<!-- Per-link prefetch control -->
<a href="/about" data-astro-prefetch>Prefetch on hover (default)</a>
<a href="/blog" data-astro-prefetch="viewport">Prefetch when visible</a>
<a href="/contact" data-astro-prefetch="load">Prefetch immediately</a>
<a href="/external" data-astro-prefetch="false">No prefetch</a>
```

## Deployment Decision Tree

```
Where to deploy?
│
├─ Need edge computing + Cloudflare ecosystem (KV, D1, R2)?
│  └─ Cloudflare Pages/Workers
│     Adapter: @astrojs/cloudflare
│     Best for: Global edge, Workers bindings, cost-effective
│
├─ Need serverless + Vercel ecosystem (ISR, analytics)?
│  └─ Vercel
│     Adapter: @astrojs/vercel
│     Best for: Next.js migration, image optimization, ISR
│
├─ Need serverless + Netlify ecosystem (forms, identity)?
│  └─ Netlify
│     Adapter: @astrojs/netlify
│     Best for: JAMstack, built-in forms, split testing
│
├─ Need full server control (Docker, custom runtime)?
│  └─ Node.js (standalone or Express/Fastify)
│     Adapter: @astrojs/node
│     Best for: Self-hosted, WebSocket, long-running processes
│
└─ Pure static site (no SSR needed)?
   └─ Any static host (GitHub Pages, S3, Cloudflare Pages)
      No adapter needed, output: 'static'
      Best for: Blogs, docs, marketing sites
```

### Adapter Installation

```bash
# Cloudflare
npx astro add cloudflare

# Vercel
npx astro add vercel

# Netlify
npx astro add netlify

# Node.js
npx astro add node
```

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Hydration mismatch errors | Server HTML differs from client render (dates, random IDs, browser APIs) | Use `client:only` for browser-dependent components, or ensure deterministic rendering |
| `import.meta.env` undefined in client | Only `PUBLIC_` prefixed vars are exposed to client-side code | Rename to `PUBLIC_MY_VAR` or pass via props from server |
| Dynamic routes 404 in SSG | `getStaticPaths()` not returning all possible params | Ensure `getStaticPaths()` returns every valid path, or switch to hybrid/SSR |
| Images not optimizing | Using `<img>` instead of Astro's `<Image />` component | Import from `astro:assets`: `import { Image } from 'astro:assets'` and use local imports for src |
| SSR fails without adapter | `output: 'server'` or `'hybrid'` requires a deployment adapter | Install adapter: `npx astro add cloudflare` (or vercel, netlify, node) |
| MDX components not rendering | Custom components not passed to MDX content | Pass components via `<Content components={{ MyComponent }} />` or use `astro.config.mjs` MDX config |
| Content collection schema changes not reflected | Type generation is cached, stale `.astro` types | Run `astro sync` to regenerate types, restart dev server |
| `client:*` on Astro components | Client directives only work on framework components (React, Vue, Svelte) | Astro components are static-only; extract interactive parts to a framework component |
| `document` / `window` is not defined | Server-side code cannot access browser globals | Guard with `if (typeof window !== 'undefined')` or move to `client:only` |
| Styles leaking between components | Using global CSS instead of scoped styles | Use `<style>` (scoped by default in .astro) or `<style is:global>` intentionally |
| View Transitions break scripts | `DOMContentLoaded` only fires once with View Transitions | Use `astro:page-load` event instead, which fires on every navigation |
| Env vars missing in production | `.env` not loaded or platform env vars not configured | Use `envField` in astro.config.mjs for validation; set vars in platform dashboard |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/content-collections.md` | Schema patterns, Zod types, querying, MDX, content layer API, migrations | ~500 |
| `references/islands-rendering.md` | Islands deep dive, client directives, framework integration, server islands | ~550 |
| `references/deployment.md` | Cloudflare/Vercel/Netlify/Node adapters, env vars, optimization | ~500 |

## See Also

- **typescript-ops** - TypeScript patterns used throughout Astro projects
- **tailwind-ops** - Tailwind CSS integration with Astro (`@astrojs/tailwind`)
- **javascript-ops** - Core JS patterns for client-side island code
- **container-orchestration** - Docker patterns for self-hosted Astro (Node adapter)
- [Astro Documentation](https://docs.astro.build)
- [Astro Integration Guide](https://docs.astro.build/en/guides/integrations-guide/)
