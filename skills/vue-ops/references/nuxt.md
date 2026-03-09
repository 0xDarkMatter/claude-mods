# Nuxt 3 Reference

Production patterns for Nuxt 3: rendering modes, data fetching, server routes, middleware, plugins, modules, SEO, deployment, and Nuxt Content.

---

## Architecture Overview

Nuxt 3 is built on:
- **Nitro** — universal server engine (runs on Node, Cloudflare Workers, Deno, Bun, etc.)
- **Vite** — fast dev server and build tool
- **Vue 3** — Composition API throughout
- **Auto-imports** — no need to import `ref`, `computed`, `useFetch`, etc. — Nuxt imports them automatically
- **File-based routing** — `pages/` directory maps to routes

---

## Rendering Modes

### nuxt.config.ts — rendering configuration

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  // SSR (default) — server renders each request
  ssr: true,

  // SPA mode — no server rendering
  // ssr: false,

  // Hybrid rendering — per-route rules (most powerful)
  routeRules: {
    '/': { prerender: true },                    // SSG — render at build time
    '/blog': { prerender: true },
    '/blog/**': { isr: 3600 },                   // ISR — regenerate every hour
    '/shop/**': { swr: 600 },                    // SWR — stale-while-revalidate 10min
    '/app/**': { ssr: true },                    // SSR — always server rendered
    '/admin/**': { ssr: false },                 // SPA — client-only
    '/api/**': { cors: true, headers: { 'cache-control': 's-maxage=0' } },
  },
})
```

### Prerendering specific routes

```ts
export default defineNuxtConfig({
  nitro: {
    prerender: {
      routes: ['/', '/about', '/contact'],
      crawlLinks: true,         // follow all <a> links and prerender them too
      ignore: ['/admin'],
    },
  },
})
```

---

## Data Fetching

### useFetch — SSR-safe primary fetching

```vue
<script setup lang="ts">
interface Post { id: number; title: string; body: string }

// Automatically de-duplicates on server/client, serializes for hydration
const { data: post, pending, error, refresh } = await useFetch<Post>(
  '/api/posts/1',
  {
    key: 'post-1',                      // deduplicate key (auto-generated if omitted)
    server: true,                       // fetch on server (default)
    lazy: false,                        // await before rendering (default)
    default: () => ({ id: 0, title: '', body: '' } as Post),
    transform: (data) => data,          // transform response before storing
    pick: ['id', 'title'],              // pick only these fields (reduces payload)
    watch: [userId],                    // re-fetch when these refs change
  }
)

// Re-fetch manually
async function reload() {
  await refresh()
}
</script>
```

### useFetch with dynamic URL

```vue
<script setup lang="ts">
const route = useRoute()

// Reactive URL — re-fetches when route param changes
const { data: user } = await useFetch(() => `/api/users/${route.params.id}`)
</script>
```

### useAsyncData — custom async logic

```vue
<script setup lang="ts">
// When you need more than a simple fetch (multiple sources, custom logic)
const { data: stats } = await useAsyncData('dashboard-stats', async () => {
  const [users, orders, revenue] = await Promise.all([
    $fetch<User[]>('/api/users'),
    $fetch<Order[]>('/api/orders'),
    $fetch<number>('/api/revenue'),
  ])
  return { users, orders, revenue }
})
</script>
```

### $fetch — client-side / server-to-server fetching

```ts
// Use $fetch for:
// - Actions triggered by user interaction (form submit, button click)
// - Server route handlers
// - Inside useAsyncData when you need to compose data

// In a component action (not in setup):
async function submitForm(data: FormData) {
  const result = await $fetch('/api/submit', {
    method: 'POST',
    body: data,
  })
}

// With error handling
try {
  const user = await $fetch<User>('/api/user', {
    headers: useRequestHeaders(['cookie']),  // forward cookies for auth
  })
} catch (error) {
  if (error.statusCode === 401) {
    await navigateTo('/login')
  }
}
```

### Lazy fetching — render immediately, load async

```vue
<script setup lang="ts">
// lazy: true — don't block render, data loads async
const { data: comments, pending } = useFetch('/api/comments', { lazy: true })
</script>

<template>
  <div v-if="pending" class="skeleton">Loading comments...</div>
  <CommentList v-else :comments="comments" />
</template>
```

---

## Server Routes

```
server/
├── api/              # Accessible at /api/*
│   ├── users/
│   │   ├── index.get.ts     # GET  /api/users
│   │   ├── index.post.ts    # POST /api/users
│   │   └── [id].get.ts      # GET  /api/users/:id
│   └── auth/
│       ├── login.post.ts
│       └── logout.post.ts
├── routes/           # Accessible at any path
│   └── sitemap.xml.get.ts   # GET /sitemap.xml
└── middleware/       # Runs on every server request
    └── auth.ts
```

### Basic API route

```ts
// server/api/users/index.get.ts
import { defineEventHandler, getQuery, H3Event } from 'h3'

export default defineEventHandler(async (event: H3Event) => {
  const query = getQuery(event)
  const page = Number(query.page ?? 1)
  const limit = Number(query.limit ?? 20)

  const users = await db.users.findMany({
    skip: (page - 1) * limit,
    take: limit,
  })

  return users // automatically serialized as JSON
})
```

### POST with validation (zod)

```ts
// server/api/users/index.post.ts
import { defineEventHandler, readBody } from 'h3'
import { z } from 'zod'

const CreateUserSchema = z.object({
  name: z.string().min(2).max(100),
  email: z.string().email(),
  role: z.enum(['user', 'admin']).default('user'),
})

export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  // Validate — throws H3Error 400 on failure
  const data = await CreateUserSchema.parseAsync(body).catch(() => {
    throw createError({ statusCode: 400, statusMessage: 'Invalid request body' })
  })

  const user = await db.users.create({ data })
  setResponseStatus(event, 201)
  return user
})
```

### Dynamic route parameter

```ts
// server/api/users/[id].get.ts
import { defineEventHandler, getRouterParam } from 'h3'

export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')

  if (!id) throw createError({ statusCode: 400, statusMessage: 'ID required' })

  const user = await db.users.findUnique({ where: { id: Number(id) } })

  if (!user) throw createError({ statusCode: 404, statusMessage: 'User not found' })

  return user
})
```

### Server middleware — authentication

```ts
// server/middleware/auth.ts
import { defineEventHandler, getCookie, createError } from 'h3'

export default defineEventHandler(async (event) => {
  // Only run auth check on /api/protected/* routes
  if (!event.node.req.url?.startsWith('/api/protected')) return

  const token = getCookie(event, 'auth_token')
    ?? getHeader(event, 'authorization')?.replace('Bearer ', '')

  if (!token) {
    throw createError({ statusCode: 401, statusMessage: 'Unauthorized' })
  }

  const user = await verifyToken(token)
  event.context.user = user  // attach to context for route handlers
})
```

---

## Nuxt Middleware

### Route middleware (client-side navigation)

```ts
// middleware/auth.ts
export default defineNuxtRouteMiddleware((to, from) => {
  const auth = useAuthStore()

  if (!auth.isLoggedIn) {
    return navigateTo({
      path: '/login',
      query: { redirect: to.fullPath },
    })
  }
})
```

### Using middleware in pages

```vue
<script setup lang="ts">
// Named middleware — run auth.ts middleware
definePageMeta({
  middleware: ['auth'],
  // Or inline:
  // middleware: (to, from) => { ... }
})
</script>
```

### Global middleware (runs on every navigation)

```ts
// middleware/analytics.global.ts  ← '.global' suffix makes it run always
export default defineNuxtRouteMiddleware((to) => {
  if (import.meta.client) {
    trackPageView(to.fullPath)
  }
})
```

### Server middleware (every HTTP request)

```ts
// server/middleware/logger.ts
export default defineEventHandler((event) => {
  console.log(`[${new Date().toISOString()}] ${event.node.req.method} ${event.node.req.url}`)
})
```

---

## Plugins

### Client and server plugins

```ts
// plugins/my-plugin.ts — runs on both server and client
export default defineNuxtPlugin((nuxtApp) => {
  // Provide a helper to all components and composables
  return {
    provide: {
      formatDate: (date: Date) => date.toLocaleDateString(),
    },
  }
})
```

```ts
// plugins/sentry.client.ts — client-only (filename convention)
import * as Sentry from '@sentry/vue'

export default defineNuxtPlugin((nuxtApp) => {
  Sentry.init({
    app: nuxtApp.vueApp,
    dsn: useRuntimeConfig().public.sentryDsn,
  })
})
```

```ts
// plugins/db.server.ts — server-only
import { PrismaClient } from '@prisma/client'

let prisma: PrismaClient

export default defineNuxtPlugin(() => {
  if (!prisma) prisma = new PrismaClient()
  return { provide: { prisma } }
})
```

### Accessing provided values

```vue
<script setup lang="ts">
const { $formatDate, $prisma } = useNuxtApp()
</script>
```

---

## Modules

### Using published modules

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  modules: [
    '@nuxtjs/tailwindcss',
    '@pinia/nuxt',
    '@nuxt/content',
    '@nuxt/image',
    '@nuxtjs/i18n',
    'nuxt-icon',
  ],

  // Module configuration
  pinia: {
    autoImports: ['defineStore', 'storeToRefs'],
  },
})
```

### Building a custom module

```ts
// modules/feature-flags/index.ts
import { defineNuxtModule, addPlugin, addImports, createResolver } from '@nuxt/kit'

interface ModuleOptions {
  flags: Record<string, boolean>
}

export default defineNuxtModule<ModuleOptions>({
  meta: {
    name: 'feature-flags',
    configKey: 'featureFlags',
  },
  defaults: {
    flags: {},
  },
  setup(options, nuxt) {
    const resolver = createResolver(import.meta.url)

    // Add runtime config
    nuxt.options.runtimeConfig.public.featureFlags = options.flags

    // Add a plugin
    addPlugin(resolver.resolve('./runtime/plugin'))

    // Add auto-imports
    addImports({
      name: 'useFeatureFlag',
      from: resolver.resolve('./runtime/composables'),
    })

    // Hook into build process
    nuxt.hook('build:before', () => {
      console.log('Feature flags module: build starting')
    })
  },
})
```

---

## State Management in Nuxt

### useState — SSR-safe shared state

```ts
// composables/useSharedState.ts
// useState() is SSR-safe: same key = same state across components in same request
export const useTheme = () => useState<'light' | 'dark'>('theme', () => 'light')
export const useUser = () => useState<User | null>('user', () => null)
```

```vue
<script setup lang="ts">
const theme = useTheme()
// Reactive and synced — changing in one component updates all others
</script>
```

### Pinia with Nuxt (recommended for complex state)

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  modules: ['@pinia/nuxt'],
  pinia: { autoImports: ['defineStore', 'storeToRefs'] },
})
```

```ts
// stores/user.ts — works in Nuxt with SSR hydration
export const useUserStore = defineStore('user', () => {
  const user = ref<User | null>(null)

  // In Nuxt: fetch on server, hydrate on client
  async function fetchUser() {
    user.value = await $fetch<User>('/api/user')
  }

  return { user, fetchUser }
})
```

---

## Runtime Config & Environment Variables

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  runtimeConfig: {
    // Private — only available on server (server routes, server-only plugins)
    databaseUrl: process.env.DATABASE_URL,
    jwtSecret: process.env.JWT_SECRET,

    // Public — exposed to client via useRuntimeConfig().public
    public: {
      apiBase: process.env.NUXT_PUBLIC_API_BASE ?? '/api',
      sentryDsn: process.env.NUXT_PUBLIC_SENTRY_DSN,
      appVersion: process.env.npm_package_version,
    },
  },
})
```

```ts
// app.config.ts — UI configuration (not secrets, bundled into client)
export default defineAppConfig({
  ui: {
    primary: 'blue',
    notifications: { position: 'top-right' },
  },
})
```

```vue
<script setup lang="ts">
// Client and server: public config
const config = useRuntimeConfig()
const apiBase = config.public.apiBase

// App config
const appConfig = useAppConfig()
const primaryColor = appConfig.ui.primary
</script>
```

---

## SEO

### useHead and useSeoMeta

```vue
<script setup lang="ts">
// useHead — full control
useHead({
  title: 'My Page',
  titleTemplate: '%s — My Site',
  meta: [
    { name: 'description', content: 'Page description' },
    { property: 'og:type', content: 'website' },
  ],
  link: [
    { rel: 'canonical', href: 'https://mysite.com/page' },
  ],
  bodyAttrs: { class: 'dark-mode' },
})

// useSeoMeta — typed, tree-shakeable (preferred for meta tags)
useSeoMeta({
  title: 'My Page',
  ogTitle: 'My Page',
  description: 'Page description for SEO',
  ogDescription: 'Page description for social sharing',
  ogImage: 'https://mysite.com/og-image.png',
  twitterCard: 'summary_large_image',
})
</script>
```

### defineOgImage — dynamic OG images

```vue
<script setup lang="ts">
// @nuxtjs/og-image module
defineOgImage({
  component: 'MyOgImageTemplate',
  props: { title: 'My Page', description: 'Description' },
})
</script>
```

### Dynamic head in layouts

```vue
<!-- layouts/default.vue -->
<script setup lang="ts">
useHead({
  titleTemplate: (title) => title ? `${title} — My App` : 'My App',
  htmlAttrs: { lang: 'en' },
  link: [
    { rel: 'icon', href: '/favicon.ico' },
  ],
})
</script>
```

---

## Error Handling

### Error page (error.vue)

```vue
<!-- error.vue — root level, replaces app.vue on error -->
<script setup lang="ts">
const props = defineProps<{
  error: {
    statusCode: number
    statusMessage: string
    message: string
  }
}>()

function handleError() {
  clearError({ redirect: '/' })
}
</script>

<template>
  <div>
    <h1>{{ error.statusCode }}</h1>
    <p>{{ error.statusMessage }}</p>
    <button @click="handleError">Go Home</button>
  </div>
</template>
```

### NuxtErrorBoundary — catch errors in subtree

```vue
<template>
  <NuxtErrorBoundary @error="onError">
    <AsyncComponent />
    <template #error="{ error, clearError }">
      <div>
        <p>Something went wrong: {{ error.message }}</p>
        <button @click="clearError()">Retry</button>
      </div>
    </template>
  </NuxtErrorBoundary>
</template>
```

### Throwing errors in server routes

```ts
// server/api/users/[id].get.ts
export default defineEventHandler(async (event) => {
  const user = await db.findUser(getRouterParam(event, 'id'))

  if (!user) {
    throw createError({
      statusCode: 404,
      statusMessage: 'User not found',
      data: { id: getRouterParam(event, 'id') },
    })
  }

  return user
})
```

---

## Deployment

### Cloudflare Workers / Pages

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  nitro: {
    preset: 'cloudflare-pages', // or 'cloudflare'
  },
})
```

```toml
# wrangler.toml (if using Workers)
name = "my-nuxt-app"
main = ".output/server/index.mjs"
compatibility_date = "2024-01-01"
compatibility_flags = ["nodejs_compat"]

[[kv_namespaces]]
binding = "KV"
id = "your-kv-namespace-id"
```

### Vercel (auto-detected)

```ts
// nuxt.config.ts — Vercel detects automatically, no preset needed
// But you can be explicit:
export default defineNuxtConfig({
  nitro: { preset: 'vercel' },
})
```

### Node.js server

```bash
# Build
npx nuxi build

# Run
node .output/server/index.mjs

# With PM2
pm2 start .output/server/index.mjs --name my-app
```

### Static hosting (full SSG)

```bash
# Generate static files
npx nuxi generate

# Output in .output/public/ — deploy to any static host
```

```ts
// nuxt.config.ts for full static
export default defineNuxtConfig({
  ssr: true,
  nitro: {
    prerender: {
      crawlLinks: true,
      routes: ['/sitemap.xml'],
    },
  },
})
```

---

## Nuxt Content

### Setup

```bash
npx nuxi module add content
```

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  modules: ['@nuxt/content'],
  content: {
    highlight: {
      theme: 'github-dark',
      langs: ['ts', 'vue', 'bash'],
    },
    markdown: {
      anchorLinks: true,
    },
  },
})
```

### Querying content

```vue
<!-- pages/blog/[slug].vue -->
<script setup lang="ts">
const route = useRoute()

// Query a single document
const { data: post } = await useAsyncData(
  `blog-${route.params.slug}`,
  () => queryContent('blog').where({ _path: `/blog/${route.params.slug}` }).findOne()
)

if (!post.value) throw createError({ statusCode: 404 })

// SEO from frontmatter
useSeoMeta({
  title: post.value.title,
  description: post.value.description,
})
</script>

<template>
  <!-- Renders markdown with MDC components -->
  <ContentRenderer :value="post" />
</template>
```

```vue
<!-- Blog listing page -->
<script setup lang="ts">
const { data: posts } = await useAsyncData('blog-list', () =>
  queryContent('blog')
    .where({ published: true })
    .sort({ date: -1 })
    .only(['_path', 'title', 'description', 'date'])
    .find()
)
</script>
```

### MDC — Markdown Components

```md
<!-- content/blog/my-post.md -->
---
title: My Post
description: Post description
date: 2024-01-15
published: true
---

Regular markdown with **bold** and `code`.

::alert{type="warning"}
This renders the Alert.vue component from components/content/
::

:MyInlineComponent{prop="value"}
```

---

## Performance Patterns

### Component islands (selective hydration)

```vue
<!-- Heavy chart that only runs client-side -->
<template>
  <NuxtIsland name="HeavyChart" :props="{ data: chartData }" />
</template>
```

### Payload optimization

```vue
<script setup lang="ts">
// clearNuxtData removes payload after navigation (saves memory)
onBeforeRouteLeave(() => {
  clearNuxtData('heavy-data-key')
})
</script>
```

### Client-only components

```vue
<template>
  <!-- Only renders on client — no SSR attempt -->
  <ClientOnly>
    <MapComponent />
    <template #fallback>
      <div class="map-skeleton" />
    </template>
  </ClientOnly>
</template>
```
