# Deployment Reference

Comprehensive guide to deploying Astro applications across platforms: Cloudflare, Vercel, Netlify, Node.js, and static hosting.

## Cloudflare Workers / Pages

### Setup

```bash
npx astro add cloudflare
```

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  output: 'server',           // or 'hybrid'
  adapter: cloudflare({
    imageService: 'cloudflare', // Use Cloudflare Image Resizing
    platformProxy: {
      enabled: true,           // Enable local bindings in dev
    },
  }),
  site: 'https://example.com',
});
```

### Wrangler Configuration

```toml
# wrangler.toml
name = "my-astro-site"
compatibility_date = "2024-11-01"
compatibility_flags = ["nodejs_compat"]
pages_build_output_dir = "./dist"

# KV Namespace binding
[[kv_namespaces]]
binding = "CACHE"
id = "abc123"

# D1 Database binding
[[d1_databases]]
binding = "DB"
database_name = "my-db"
database_id = "def456"

# R2 Bucket binding
[[r2_buckets]]
binding = "ASSETS"
bucket_name = "my-assets"

# Environment variables
[vars]
API_URL = "https://api.example.com"

# Secrets (set via wrangler secret put)
# SECRET_KEY - set via `wrangler secret put SECRET_KEY`
```

### Accessing Cloudflare Bindings

```typescript
// Type definitions for Cloudflare bindings
// src/env.d.ts
/// <reference types="astro/client" />

type Runtime = import('@astrojs/cloudflare').Runtime<Env>;

interface Env {
  CACHE: KVNamespace;
  DB: D1Database;
  ASSETS: R2Bucket;
  API_URL: string;
  SECRET_KEY: string;
}

declare namespace App {
  interface Locals extends Runtime {}
}
```

```astro
---
// src/pages/api/data.ts
import type { APIContext } from 'astro';

export async function GET({ locals }: APIContext) {
  const { env } = locals.runtime;

  // KV operations
  const cached = await env.CACHE.get('my-key');
  if (cached) {
    return new Response(cached, {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // D1 database query
  const { results } = await env.DB
    .prepare('SELECT * FROM posts WHERE published = ?')
    .bind(true)
    .all();

  // R2 object storage
  const object = await env.ASSETS.get('images/hero.jpg');

  // Cache the result
  await env.CACHE.put('my-key', JSON.stringify(results), {
    expirationTtl: 3600,
  });

  return new Response(JSON.stringify(results), {
    headers: { 'Content-Type': 'application/json' },
  });
}
```

### Cloudflare Middleware

```typescript
// src/middleware.ts
import { defineMiddleware } from 'astro:middleware';

export const onRequest = defineMiddleware(async ({ locals, request, cookies }, next) => {
  const { env } = locals.runtime;

  // Auth check using KV
  const session = cookies.get('session')?.value;
  if (session) {
    const user = await env.CACHE.get(`session:${session}`);
    if (user) {
      locals.user = JSON.parse(user);
    }
  }

  // Rate limiting with KV
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const rateKey = `rate:${ip}`;
  const count = parseInt(await env.CACHE.get(rateKey) ?? '0');

  if (count > 100) {
    return new Response('Rate limited', { status: 429 });
  }

  await env.CACHE.put(rateKey, String(count + 1), { expirationTtl: 60 });

  return next();
});
```

### Deployment

```bash
# Build and deploy to Cloudflare Pages
npm run build
npx wrangler pages deploy dist

# Or connect to Git for automatic deploys via Cloudflare Dashboard
# Settings > Build > Framework preset: Astro
```

## Vercel

### Setup

```bash
npx astro add vercel
```

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import vercel from '@astrojs/vercel';

export default defineConfig({
  output: 'server',           // or 'hybrid'
  adapter: vercel({
    imageService: true,        // Use Vercel Image Optimization
    isr: {
      expiration: 60,          // ISR: revalidate every 60 seconds
    },
    webAnalytics: {
      enabled: true,           // Enable Vercel Web Analytics
    },
    maxDuration: 30,           // Serverless function timeout (seconds)
  }),
});
```

### Serverless vs Edge

```typescript
// Default: serverless function
export default defineConfig({
  output: 'server',
  adapter: vercel(),
});

// Edge function (faster cold start, limited APIs)
export default defineConfig({
  output: 'server',
  adapter: vercel({
    edgeMiddleware: true,      // Run middleware at the edge
  }),
});
```

### ISR (Incremental Static Regeneration)

```astro
---
// Per-page ISR configuration
// src/pages/blog/[slug].astro
export const prerender = false;

// Set ISR headers
Astro.response.headers.set(
  'Cache-Control',
  's-maxage=60, stale-while-revalidate=600'
);
---
```

### Vercel Environment Variables

```bash
# Set via Vercel CLI
vercel env add PRIVATE_KEY
vercel env add PUBLIC_API_URL

# Or via vercel.json
```

```json
// vercel.json
{
  "framework": "astro",
  "buildCommand": "astro build",
  "outputDirectory": "dist",
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        { "key": "Cache-Control", "value": "s-maxage=60" }
      ]
    }
  ],
  "redirects": [
    { "source": "/old-path", "destination": "/new-path", "permanent": true }
  ]
}
```

### Deployment

```bash
# Deploy to Vercel
npx vercel

# Production deploy
npx vercel --prod

# Or connect to Git for automatic deploys
```

## Netlify

### Setup

```bash
npx astro add netlify
```

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import netlify from '@astrojs/netlify';

export default defineConfig({
  output: 'server',           // or 'hybrid'
  adapter: netlify({
    edgeMiddleware: true,      // Run middleware at the edge
    imageCDN: true,            // Use Netlify Image CDN
  }),
});
```

### Netlify Configuration

```toml
# netlify.toml
[build]
  command = "astro build"
  publish = "dist"

[build.environment]
  NODE_VERSION = "20"

# Redirects
[[redirects]]
  from = "/old-path"
  to = "/new-path"
  status = 301

# Custom headers
[[headers]]
  for = "/api/*"
  [headers.values]
    Access-Control-Allow-Origin = "*"
    Cache-Control = "public, max-age=60"

# Netlify Forms
# Forms are auto-detected in static builds
# For SSR, use Netlify Forms API
```

### Netlify Edge Functions

```typescript
// netlify/edge-functions/geolocation.ts
import type { Context } from '@netlify/edge-functions';

export default async function (request: Request, context: Context) {
  const { country, city } = context.geo;

  // Add geo data to request headers for Astro middleware
  request.headers.set('x-country', country?.code ?? 'US');
  request.headers.set('x-city', city ?? 'Unknown');

  return context.next();
}

export const config = { path: '/*' };
```

### Netlify Forms with Astro

```astro
---
// Static output - Netlify auto-detects forms
---

<form name="contact" method="POST" data-netlify="true">
  <input type="hidden" name="form-name" value="contact" />
  <input type="text" name="name" required />
  <input type="email" name="email" required />
  <textarea name="message" required></textarea>
  <button type="submit">Send</button>
</form>
```

### Deployment

```bash
# Deploy to Netlify
npx netlify deploy

# Production deploy
npx netlify deploy --prod

# Or connect to Git for automatic deploys
```

## Node.js (Self-hosted)

### Setup

```bash
npx astro add node
```

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import node from '@astrojs/node';

export default defineConfig({
  output: 'server',
  adapter: node({
    mode: 'standalone',        // or 'middleware'
  }),
});
```

### Standalone Mode

```bash
# Build
npm run build

# Run (starts built-in HTTP server)
HOST=0.0.0.0 PORT=4321 node dist/server/entry.mjs
```

### Middleware Mode (Express/Fastify)

```typescript
// astro.config.mjs
import node from '@astrojs/node';

export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'middleware' }),
});
```

```typescript
// server.mjs - Custom Express server
import express from 'express';
import { handler as astroHandler } from './dist/server/entry.mjs';

const app = express();

// Custom middleware before Astro
app.use('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Serve static files
app.use(express.static('dist/client'));

// Astro handles everything else
app.use(astroHandler);

const port = process.env.PORT || 4321;
app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
```

```typescript
// server-fastify.mjs - Custom Fastify server
import Fastify from 'fastify';
import fastifyStatic from '@fastify/static';
import { handler as astroHandler } from './dist/server/entry.mjs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const app = Fastify({ logger: true });

// Static files
app.register(fastifyStatic, {
  root: path.join(__dirname, 'dist/client'),
});

// Health check
app.get('/health', async () => ({ status: 'ok' }));

// Astro handler
app.use(astroHandler);

app.listen({ port: 4321, host: '0.0.0.0' });
```

### Docker Deployment

```dockerfile
# Dockerfile
FROM node:20-slim AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM node:20-slim AS runtime

WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

ENV HOST=0.0.0.0
ENV PORT=4321

EXPOSE 4321

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:4321/health || exit 1

CMD ["node", "dist/server/entry.mjs"]
```

```yaml
# docker-compose.yml
services:
  astro:
    build: .
    ports:
      - "4321:4321"
    environment:
      - DATABASE_URL=postgres://db:5432/app
      - SECRET_KEY=${SECRET_KEY}
    restart: unless-stopped
    depends_on:
      - db
  db:
    image: postgres:16-alpine
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: app
      POSTGRES_PASSWORD: ${DB_PASSWORD}

volumes:
  pgdata:
```

## Static Hosting

### Configuration

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';

export default defineConfig({
  output: 'static',           // Default - all pages prerendered
  site: 'https://example.com',
  base: '/my-app',            // If hosted at a subpath
});
```

### GitHub Pages

```yaml
# .github/workflows/deploy.yml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - uses: actions/upload-pages-artifact@v3
        with:
          path: dist

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

```typescript
// astro.config.mjs for GitHub Pages
export default defineConfig({
  site: 'https://username.github.io',
  base: '/repo-name',         // For project pages (not needed for user pages)
});
```

### S3 + CloudFront

```bash
# Build and sync to S3
npm run build
aws s3 sync dist s3://my-bucket --delete
aws cloudfront create-invalidation --distribution-id DIST_ID --paths "/*"
```

## Environment Variables

### Astro Environment Variable Rules

```
# .env
# Private (server-only) - NOT available in client-side code
DATABASE_URL=postgres://localhost:5432/mydb
API_SECRET=sk-12345
SESSION_KEY=abc

# Public (available in client-side code) - MUST start with PUBLIC_
PUBLIC_API_URL=https://api.example.com
PUBLIC_SITE_NAME=My Site
PUBLIC_GA_ID=G-12345
```

### Accessing Environment Variables

```typescript
// Server-side (pages, middleware, API routes, server islands)
const dbUrl = import.meta.env.DATABASE_URL;        // Works
const apiKey = import.meta.env.API_SECRET;          // Works
const publicUrl = import.meta.env.PUBLIC_API_URL;   // Works

// Client-side (browser, client:* components)
const publicUrl = import.meta.env.PUBLIC_API_URL;   // Works
const dbUrl = import.meta.env.DATABASE_URL;         // undefined!
```

### envField Schema Validation (Astro 5)

```typescript
// astro.config.mjs
import { defineConfig, envField } from 'astro/config';

export default defineConfig({
  env: {
    schema: {
      // Server-only variables
      DATABASE_URL: envField.string({
        context: 'server',
        access: 'secret',
        optional: false,
      }),
      API_KEY: envField.string({
        context: 'server',
        access: 'secret',
      }),
      PORT: envField.number({
        context: 'server',
        access: 'public',
        default: 4321,
      }),

      // Client-accessible variables
      PUBLIC_API_URL: envField.string({
        context: 'client',
        access: 'public',
      }),
      PUBLIC_FEATURE_FLAG: envField.boolean({
        context: 'client',
        access: 'public',
        default: false,
      }),
    },
  },
});
```

```typescript
// Type-safe env access with validation
import { DATABASE_URL, PORT } from 'astro:env/server';
import { PUBLIC_API_URL, PUBLIC_FEATURE_FLAG } from 'astro:env/client';

// These are typed and validated at build time
console.log(DATABASE_URL);     // string (required)
console.log(PORT);             // number (defaults to 4321)
console.log(PUBLIC_API_URL);   // string (required)
```

### Platform-specific Environment Variables

```bash
# Cloudflare - set in wrangler.toml or dashboard
wrangler secret put API_KEY

# Vercel
vercel env add API_KEY production

# Netlify
netlify env:set API_KEY "value"

# Docker
docker run -e DATABASE_URL=... my-astro-app
```

## Headers and Redirects

### Middleware-based Headers

```typescript
// src/middleware.ts
import { defineMiddleware, sequence } from 'astro:middleware';

const securityHeaders = defineMiddleware(async (context, next) => {
  const response = await next();

  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.headers.set('X-Frame-Options', 'DENY');
  response.headers.set('X-XSS-Protection', '1; mode=block');
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  response.headers.set(
    'Content-Security-Policy',
    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
  );

  return response;
});

const cacheHeaders = defineMiddleware(async (context, next) => {
  const response = await next();

  // Cache static assets aggressively
  if (context.url.pathname.startsWith('/_astro/')) {
    response.headers.set('Cache-Control', 'public, max-age=31536000, immutable');
  }

  return response;
});

export const onRequest = sequence(securityHeaders, cacheHeaders);
```

### Static File Headers

```
# public/_headers (Cloudflare Pages / Netlify)
/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY

/_astro/*
  Cache-Control: public, max-age=31536000, immutable

/api/*
  Cache-Control: no-cache
  Access-Control-Allow-Origin: *
```

### Redirects

```
# public/_redirects (Cloudflare Pages / Netlify)
/old-blog/*    /blog/:splat    301
/legacy        /               302
/docs          https://docs.example.com  301
```

```typescript
// Programmatic redirects in middleware
import { defineMiddleware } from 'astro:middleware';

const redirects: Record<string, { to: string; status: 301 | 302 }> = {
  '/old-path': { to: '/new-path', status: 301 },
  '/legacy': { to: '/', status: 302 },
};

export const onRequest = defineMiddleware(async ({ url, redirect }, next) => {
  const rule = redirects[url.pathname];
  if (rule) {
    return redirect(rule.to, rule.status);
  }
  return next();
});
```

## SSR Streaming

### Response Streaming

```astro
---
// Astro streams HTML by default in SSR mode
// Components render top-to-bottom, streaming chunks to the client

// Slow data fetch - page header already visible while this loads
const slowData = await fetch('https://slow-api.example.com/data')
  .then(r => r.json());
---

<html>
  <body>
    <!-- This streams immediately -->
    <h1>Page Title</h1>

    <!-- This streams after slowData resolves -->
    <div>{slowData.content}</div>
  </body>
</html>
```

### Streaming with Server Islands

```astro
---
// Combine streaming with server islands for optimal loading
import SlowWidget from '../components/SlowWidget.astro';
import UserDashboard from '../components/UserDashboard.astro';
---

<!-- Streams immediately -->
<header>Fast static content</header>

<!-- Server island: page sends without waiting for this -->
<SlowWidget server:defer>
  <div slot="fallback">Loading widget...</div>
</SlowWidget>

<!-- This also streams immediately (doesn't wait for SlowWidget) -->
<main>More fast content</main>

<UserDashboard server:defer>
  <div slot="fallback" class="skeleton">Loading dashboard...</div>
</UserDashboard>
```

## Build Optimization

### Bundle Analysis

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';

export default defineConfig({
  vite: {
    build: {
      // Analyze bundle
      rollupOptions: {
        output: {
          manualChunks: {
            // Group vendor chunks
            'react-vendor': ['react', 'react-dom'],
            'utils': ['date-fns', 'lodash-es'],
          },
        },
      },
    },
  },
});
```

### Prefetch Strategies

```typescript
// astro.config.mjs
export default defineConfig({
  prefetch: {
    // Prefetch links on hover (default for View Transitions)
    defaultStrategy: 'hover',

    // Or be more aggressive
    // defaultStrategy: 'viewport',  // Prefetch when link enters viewport
    // defaultStrategy: 'load',      // Prefetch all links on page load

    // Prefetch all same-origin links
    prefetchAll: false,
  },
});
```

```astro
<!-- Per-link prefetch control -->
<a href="/about" data-astro-prefetch="hover">Hover to prefetch</a>
<a href="/important" data-astro-prefetch="viewport">Prefetch when visible</a>
<a href="/critical" data-astro-prefetch="load">Prefetch immediately</a>
<a href="/external" data-astro-prefetch="false">Never prefetch</a>
```

### Image Service Configuration

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';

export default defineConfig({
  image: {
    // Use Sharp (default, best quality)
    service: { entrypoint: 'astro/assets/services/sharp' },

    // Remote image domains
    domains: ['cdn.example.com', 'images.unsplash.com'],

    // Remote patterns (more granular)
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**.example.com',
        pathname: '/images/**',
      },
    ],
  },
});
```

```astro
---
import { Image, Picture } from 'astro:assets';
import heroImage from '../assets/hero.jpg';
---

<!-- Optimized image with automatic format conversion -->
<Image
  src={heroImage}
  alt="Hero image"
  width={1200}
  height={600}
  quality={80}
  format="avif"
  loading="eager"             <!-- Above fold: eager, below fold: lazy (default) -->
/>

<!-- Responsive picture with multiple formats -->
<Picture
  src={heroImage}
  formats={['avif', 'webp']}
  widths={[400, 800, 1200]}
  sizes="(max-width: 768px) 100vw, 1200px"
  alt="Responsive hero"
/>

<!-- Remote image (must be in domains/remotePatterns) -->
<Image
  src="https://cdn.example.com/photo.jpg"
  alt="Remote image"
  width={800}
  height={400}
  inferSize                   <!-- Auto-detect dimensions -->
/>
```

### Compression and Performance

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import compress from 'astro-compress';

export default defineConfig({
  integrations: [
    compress({
      CSS: true,
      HTML: true,
      Image: true,
      JavaScript: true,
      SVG: true,
    }),
  ],
  compressHTML: true,          // Built-in HTML minification
  build: {
    inlineStylesheets: 'auto', // Inline small CSS (<4KB)
  },
  vite: {
    build: {
      cssMinify: 'lightningcss',  // Faster CSS minification
    },
  },
});
```

### Sitemap and SEO

```bash
npx astro add sitemap
```

```typescript
// astro.config.mjs
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://example.com',
  integrations: [
    sitemap({
      filter: (page) => !page.includes('/admin'),
      changefreq: 'weekly',
      priority: 0.7,
      lastmod: new Date(),
      i18n: {
        defaultLocale: 'en',
        locales: {
          en: 'en-US',
          es: 'es-ES',
        },
      },
    }),
  ],
});
```

```astro
---
// src/layouts/BaseLayout.astro - SEO head tags
interface Props {
  title: string;
  description: string;
  image?: string;
  canonicalURL?: string;
}

const {
  title,
  description,
  image = '/og-default.png',
  canonicalURL = Astro.url.href,
} = Astro.props;
---

<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
    <meta name="description" content={description} />
    <link rel="canonical" href={canonicalURL} />

    <!-- Open Graph -->
    <meta property="og:title" content={title} />
    <meta property="og:description" content={description} />
    <meta property="og:image" content={new URL(image, Astro.site)} />
    <meta property="og:url" content={canonicalURL} />
    <meta property="og:type" content="website" />

    <!-- Twitter -->
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={title} />
    <meta name="twitter:description" content={description} />
    <meta name="twitter:image" content={new URL(image, Astro.site)} />

    <!-- Sitemap -->
    <link rel="sitemap" href="/sitemap-index.xml" />
  </head>
  <body>
    <slot />
  </body>
</html>
```
