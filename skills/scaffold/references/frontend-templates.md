# Frontend Project Templates

Complete scaffolds for web applications across frameworks and rendering strategies.

## Next.js 14+ (App Router)

### Full Directory Tree

```
my-app/
├── src/
│   ├── app/
│   │   ├── layout.tsx
│   │   ├── page.tsx
│   │   ├── loading.tsx
│   │   ├── error.tsx
│   │   ├── not-found.tsx
│   │   ├── globals.css
│   │   ├── (auth)/
│   │   │   ├── layout.tsx
│   │   │   ├── login/
│   │   │   │   └── page.tsx
│   │   │   └── register/
│   │   │       └── page.tsx
│   │   ├── dashboard/
│   │   │   ├── layout.tsx
│   │   │   ├── page.tsx
│   │   │   ├── loading.tsx
│   │   │   └── settings/
│   │   │       └── page.tsx
│   │   └── api/
│   │       └── health/
│   │           └── route.ts
│   ├── components/
│   │   ├── ui/
│   │   │   ├── button.tsx
│   │   │   ├── input.tsx
│   │   │   └── card.tsx
│   │   ├── features/
│   │   │   ├── header.tsx
│   │   │   ├── sidebar.tsx
│   │   │   └── user-menu.tsx
│   │   └── providers.tsx
│   ├── lib/
│   │   ├── db.ts
│   │   ├── auth.ts
│   │   ├── utils.ts
│   │   └── validations.ts
│   ├── hooks/
│   │   └── use-debounce.ts
│   └── types/
│       └── index.ts
├── public/
│   ├── favicon.ico
│   └── images/
├── tests/
│   ├── setup.ts
│   ├── components/
│   │   └── button.test.tsx
│   └── e2e/
│       └── home.spec.ts
├── next.config.ts
├── tailwind.config.ts
├── postcss.config.js
├── tsconfig.json
├── package.json
├── .env.local.example
├── .eslintrc.json
└── .gitignore
```

### src/app/layout.tsx

```tsx
import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { Providers } from '@/components/providers';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: {
    default: 'My App',
    template: '%s | My App',
  },
  description: 'A Next.js application',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className={inter.className}>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
```

### src/app/page.tsx

```tsx
export default function HomePage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-24">
      <h1 className="text-4xl font-bold">Welcome</h1>
    </main>
  );
}
```

### src/app/loading.tsx

```tsx
export default function Loading() {
  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="h-8 w-8 animate-spin rounded-full border-4 border-gray-300 border-t-blue-600" />
    </div>
  );
}
```

### src/app/error.tsx

```tsx
'use client';

import { useEffect } from 'react';

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4">
      <h2 className="text-2xl font-bold">Something went wrong</h2>
      <button
        onClick={reset}
        className="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
      >
        Try again
      </button>
    </div>
  );
}
```

### src/app/not-found.tsx

```tsx
import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4">
      <h2 className="text-2xl font-bold">Not Found</h2>
      <p className="text-gray-600">Could not find the requested resource.</p>
      <Link
        href="/"
        className="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
      >
        Return Home
      </Link>
    </div>
  );
}
```

### src/app/api/health/route.ts

```typescript
import { NextResponse } from 'next/server';

export async function GET() {
  return NextResponse.json({ status: 'healthy', timestamp: new Date().toISOString() });
}
```

### src/components/providers.tsx

```tsx
'use client';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            refetchOnWindowFocus: false,
          },
        },
      })
  );

  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}
```

### src/lib/utils.ts

```typescript
import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
```

### next.config.ts

```typescript
import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  experimental: {
    typedRoutes: true,
  },
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**.example.com',
      },
    ],
  },
};

export default nextConfig;
```

### tailwind.config.ts

```typescript
import type { Config } from 'tailwindcss';

const config: Config = {
  content: ['./src/**/*.{js,ts,jsx,tsx,mdx}'],
  theme: {
    extend: {
      colors: {
        border: 'hsl(var(--border))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: {
          DEFAULT: 'hsl(var(--primary))',
          foreground: 'hsl(var(--primary-foreground))',
        },
      },
    },
  },
  plugins: [],
};

export default config;
```

### package.json (Key Dependencies)

```json
{
  "name": "my-app",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev --turbopack",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "test": "vitest",
    "test:e2e": "playwright test"
  },
  "dependencies": {
    "next": "^14.2.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0",
    "@tanstack/react-query": "^5.0.0",
    "clsx": "^2.1.0",
    "tailwind-merge": "^2.2.0",
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "@types/node": "^20.0.0",
    "@types/react": "^18.3.0",
    "typescript": "^5.4.0",
    "tailwindcss": "^3.4.0",
    "postcss": "^8.4.0",
    "autoprefixer": "^10.4.0",
    "eslint": "^8.57.0",
    "eslint-config-next": "^14.2.0",
    "vitest": "^1.6.0",
    "@testing-library/react": "^15.0.0",
    "@vitejs/plugin-react": "^4.2.0",
    "@playwright/test": "^1.43.0"
  }
}
```

### .env.local.example

```env
# Database
DATABASE_URL=postgresql://user:password@localhost:5432/mydb

# Auth
NEXTAUTH_URL=http://localhost:3000
NEXTAUTH_SECRET=change-me

# External APIs
NEXT_PUBLIC_API_URL=http://localhost:8000
```

### Test Setup (Vitest)

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: './tests/setup.ts',
    css: true,
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
});
```

```typescript
// tests/setup.ts
import '@testing-library/jest-dom/vitest';
```

```tsx
// tests/components/button.test.tsx
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';

// import { Button } from '@/components/ui/button';

describe('Button', () => {
  it('renders with text', () => {
    // render(<Button>Click me</Button>);
    // expect(screen.getByRole('button', { name: 'Click me' })).toBeInTheDocument();
  });

  it('calls onClick handler', async () => {
    const onClick = vi.fn();
    // render(<Button onClick={onClick}>Click</Button>);
    // await userEvent.click(screen.getByRole('button'));
    // expect(onClick).toHaveBeenCalledOnce();
  });
});
```

---

## Nuxt 3

### Full Directory Tree

```
my-app/
├── app.vue
├── nuxt.config.ts
├── pages/
│   ├── index.vue
│   ├── login.vue
│   └── dashboard/
│       ├── index.vue
│       └── settings.vue
├── components/
│   ├── ui/
│   │   ├── AppButton.vue
│   │   └── AppCard.vue
│   ├── AppHeader.vue
│   └── AppSidebar.vue
├── composables/
│   ├── useAuth.ts
│   └── useApi.ts
├── server/
│   ├── api/
│   │   ├── health.get.ts
│   │   └── users/
│   │       ├── index.get.ts
│   │       ├── index.post.ts
│   │       └── [id].get.ts
│   ├── middleware/
│   │   └── auth.ts
│   └── utils/
│       └── db.ts
├── stores/
│   └── auth.ts
├── layouts/
│   ├── default.vue
│   └── auth.vue
├── middleware/
│   └── auth.ts
├── plugins/
│   └── api.ts
├── assets/
│   └── css/
│       └── main.css
├── public/
│   └── favicon.ico
├── tests/
│   └── components/
│       └── AppButton.test.ts
├── tailwind.config.ts
├── tsconfig.json
├── package.json
├── .env.example
└── .gitignore
```

### nuxt.config.ts

```typescript
export default defineNuxtConfig({
  devtools: { enabled: true },

  modules: [
    '@nuxtjs/tailwindcss',
    '@pinia/nuxt',
    '@vueuse/nuxt',
  ],

  css: ['~/assets/css/main.css'],

  runtimeConfig: {
    databaseUrl: process.env.DATABASE_URL || '',
    jwtSecret: process.env.JWT_SECRET || '',
    public: {
      apiBase: process.env.NUXT_PUBLIC_API_BASE || '/api',
    },
  },

  typescript: {
    strict: true,
    typeCheck: true,
  },

  compatibilityDate: '2024-04-01',
});
```

### app.vue

```vue
<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>
```

### pages/index.vue

```vue
<script setup lang="ts">
definePageMeta({
  layout: 'default',
});

useHead({
  title: 'Home',
});
</script>

<template>
  <main class="flex min-h-screen flex-col items-center justify-center p-24">
    <h1 class="text-4xl font-bold">Welcome</h1>
  </main>
</template>
```

### composables/useApi.ts

```typescript
export function useApi() {
  const config = useRuntimeConfig();

  async function $fetch<T>(url: string, options?: RequestInit): Promise<T> {
    const response = await fetch(`${config.public.apiBase}${url}`, {
      headers: { 'Content-Type': 'application/json', ...options?.headers },
      ...options,
    });
    if (!response.ok) throw new Error(`API error: ${response.status}`);
    return response.json();
  }

  return { $fetch };
}
```

### stores/auth.ts (Pinia)

```typescript
import { defineStore } from 'pinia';

interface User {
  id: string;
  email: string;
  name: string;
}

export const useAuthStore = defineStore('auth', () => {
  const user = ref<User | null>(null);
  const isAuthenticated = computed(() => !!user.value);

  async function login(email: string, password: string) {
    const { $fetch } = useApi();
    const data = await $fetch<{ user: User; token: string }>('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
    user.value = data.user;
  }

  function logout() {
    user.value = null;
    navigateTo('/login');
  }

  return { user, isAuthenticated, login, logout };
});
```

### server/api/health.get.ts

```typescript
export default defineEventHandler(() => {
  return { status: 'healthy', timestamp: new Date().toISOString() };
});
```

### server/api/users/index.get.ts

```typescript
export default defineEventHandler(async (event) => {
  const query = getQuery(event);
  const skip = Number(query.skip) || 0;
  const limit = Number(query.limit) || 20;

  // Replace with actual database query
  return { items: [], total: 0 };
});
```

---

## Astro

### Full Directory Tree

```
my-site/
├── src/
│   ├── layouts/
│   │   ├── BaseLayout.astro
│   │   └── PostLayout.astro
│   ├── pages/
│   │   ├── index.astro
│   │   ├── about.astro
│   │   ├── blog/
│   │   │   ├── index.astro
│   │   │   └── [...slug].astro
│   │   └── api/
│   │       └── health.ts
│   ├── components/
│   │   ├── Header.astro
│   │   ├── Footer.astro
│   │   ├── Card.astro
│   │   └── react/
│   │       └── Counter.tsx
│   ├── content/
│   │   ├── config.ts
│   │   └── blog/
│   │       ├── first-post.md
│   │       └── second-post.md
│   ├── styles/
│   │   └── global.css
│   └── env.d.ts
├── public/
│   ├── favicon.svg
│   └── images/
├── astro.config.mjs
├── tailwind.config.mjs
├── tsconfig.json
├── package.json
├── .gitignore
└── .env.example
```

### astro.config.mjs

```javascript
import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';
import react from '@astrojs/react';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://example.com',
  integrations: [tailwind(), react(), mdx(), sitemap()],
  output: 'static', // or 'server' for SSR, 'hybrid' for mixed
});
```

### src/layouts/BaseLayout.astro

```astro
---
import Header from '../components/Header.astro';
import Footer from '../components/Footer.astro';
import '../styles/global.css';

interface Props {
  title: string;
  description?: string;
}

const { title, description = 'My Astro site' } = Astro.props;
---

<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="description" content={description} />
    <title>{title}</title>
  </head>
  <body class="min-h-screen bg-white text-gray-900">
    <Header />
    <main class="container mx-auto px-4 py-8">
      <slot />
    </main>
    <Footer />
  </body>
</html>
```

### src/pages/index.astro

```astro
---
import BaseLayout from '../layouts/BaseLayout.astro';
import Card from '../components/Card.astro';
import { getCollection } from 'astro:content';

const posts = (await getCollection('blog')).sort(
  (a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf()
);
---

<BaseLayout title="Home">
  <h1 class="text-4xl font-bold mb-8">Welcome</h1>
  <section class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
    {posts.map((post) => (
      <Card
        title={post.data.title}
        description={post.data.description}
        href={`/blog/${post.slug}`}
      />
    ))}
  </section>
</BaseLayout>
```

### src/content/config.ts

```typescript
import { defineCollection, z } from 'astro:content';

const blogCollection = defineCollection({
  type: 'content',
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    heroImage: z.string().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

export const collections = {
  blog: blogCollection,
};
```

### src/pages/api/health.ts

```typescript
import type { APIRoute } from 'astro';

export const GET: APIRoute = () => {
  return new Response(
    JSON.stringify({ status: 'healthy', timestamp: new Date().toISOString() }),
    { headers: { 'Content-Type': 'application/json' } }
  );
};
```

---

## SvelteKit

### Full Directory Tree

```
my-app/
├── src/
│   ├── app.html
│   ├── app.css
│   ├── app.d.ts
│   ├── hooks.server.ts
│   ├── lib/
│   │   ├── components/
│   │   │   ├── Button.svelte
│   │   │   ├── Card.svelte
│   │   │   └── Header.svelte
│   │   ├── server/
│   │   │   └── db.ts
│   │   └── utils.ts
│   ├── routes/
│   │   ├── +layout.svelte
│   │   ├── +layout.server.ts
│   │   ├── +page.svelte
│   │   ├── +page.server.ts
│   │   ├── +error.svelte
│   │   ├── login/
│   │   │   ├── +page.svelte
│   │   │   └── +page.server.ts
│   │   ├── dashboard/
│   │   │   ├── +layout.svelte
│   │   │   ├── +page.svelte
│   │   │   └── +page.server.ts
│   │   └── api/
│   │       └── health/
│   │           └── +server.ts
│   └── params/
│       └── id.ts
├── static/
│   └── favicon.png
├── tests/
│   └── home.test.ts
├── svelte.config.js
├── vite.config.ts
├── tailwind.config.ts
├── postcss.config.js
├── tsconfig.json
├── package.json
├── .env.example
└── .gitignore
```

### svelte.config.js

```javascript
import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    alias: {
      $components: 'src/lib/components',
    },
  },
};

export default config;
```

### src/routes/+layout.svelte

```svelte
<script lang="ts">
  import '../app.css';
  import Header from '$components/Header.svelte';

  let { children } = $props();
</script>

<Header />
<main class="container mx-auto px-4 py-8">
  {@render children()}
</main>
```

### src/routes/+page.svelte

```svelte
<script lang="ts">
  let { data } = $props();
</script>

<svelte:head>
  <title>Home</title>
</svelte:head>

<h1 class="text-4xl font-bold">Welcome</h1>
```

### src/routes/+page.server.ts

```typescript
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
  return {
    title: 'Home',
  };
};
```

### src/routes/login/+page.server.ts

```typescript
import { fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
  if (locals.user) throw redirect(303, '/dashboard');
};

export const actions: Actions = {
  default: async ({ request }) => {
    const data = await request.formData();
    const email = data.get('email');
    const password = data.get('password');

    if (!email || !password) {
      return fail(400, { email: email?.toString(), missing: true });
    }

    // Authenticate user
    throw redirect(303, '/dashboard');
  },
};
```

### src/routes/api/health/+server.ts

```typescript
import { json } from '@sveltejs/kit';

export function GET() {
  return json({ status: 'healthy', timestamp: new Date().toISOString() });
}
```

---

## Vite + React SPA

### Full Directory Tree

```
my-app/
├── src/
│   ├── main.tsx
│   ├── App.tsx
│   ├── vite-env.d.ts
│   ├── components/
│   │   ├── ui/
│   │   │   ├── Button.tsx
│   │   │   └── Input.tsx
│   │   ├── Layout.tsx
│   │   └── ProtectedRoute.tsx
│   ├── pages/
│   │   ├── Home.tsx
│   │   ├── Login.tsx
│   │   ├── Dashboard.tsx
│   │   └── NotFound.tsx
│   ├── hooks/
│   │   ├── useAuth.ts
│   │   └── useApi.ts
│   ├── lib/
│   │   ├── api.ts
│   │   └── utils.ts
│   ├── stores/
│   │   └── auth.ts
│   ├── types/
│   │   └── index.ts
│   └── styles/
│       └── index.css
├── public/
│   └── favicon.ico
├── tests/
│   ├── setup.ts
│   └── pages/
│       └── Home.test.tsx
├── index.html
├── vite.config.ts
├── vitest.config.ts
├── tailwind.config.ts
├── postcss.config.js
├── tsconfig.json
├── tsconfig.node.json
├── package.json
├── .env.example
└── .gitignore
```

### src/main.tsx

```tsx
import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import App from './App';
import './styles/index.css';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 60_000, refetchOnWindowFocus: false },
  },
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>
);
```

### src/App.tsx

```tsx
import { Routes, Route } from 'react-router-dom';
import { Layout } from './components/Layout';
import { ProtectedRoute } from './components/ProtectedRoute';
import { Home } from './pages/Home';
import { Login } from './pages/Login';
import { Dashboard } from './pages/Dashboard';
import { NotFound } from './pages/NotFound';

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/" element={<Home />} />
        <Route path="/login" element={<Login />} />
        <Route element={<ProtectedRoute />}>
          <Route path="/dashboard" element={<Dashboard />} />
        </Route>
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  );
}
```

### src/lib/api.ts

```typescript
const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:8000';

class ApiClient {
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  async request<T>(path: string, options?: RequestInit): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const response = await fetch(url, {
      headers: {
        'Content-Type': 'application/json',
        ...options?.headers,
      },
      ...options,
    });

    if (!response.ok) {
      throw new Error(`API error: ${response.status} ${response.statusText}`);
    }

    return response.json();
  }

  get<T>(path: string) {
    return this.request<T>(path);
  }

  post<T>(path: string, data: unknown) {
    return this.request<T>(path, {
      method: 'POST',
      body: JSON.stringify(data),
    });
  }
}

export const api = new ApiClient(API_BASE);
```

### vite.config.ts

```typescript
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
});
```

### Deployment Configurations

#### Next.js - Dockerfile

```dockerfile
FROM node:20-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-slim
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "server.js"]
```

Requires `output: 'standalone'` in next.config.ts.

#### Astro - Cloudflare Pages

```javascript
// astro.config.mjs
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  output: 'server',
  adapter: cloudflare(),
});
```

#### SvelteKit - Node Adapter

```javascript
// svelte.config.js
import adapter from '@sveltejs/adapter-node';

const config = {
  kit: {
    adapter: adapter({ out: 'build' }),
  },
};
```

### Common Dependencies by Framework

| Framework | Essential | Recommended |
|-----------|-----------|-------------|
| **Next.js** | react, react-dom, next | @tanstack/react-query, zod, clsx, tailwind-merge |
| **Nuxt 3** | nuxt | @pinia/nuxt, @vueuse/nuxt, @nuxtjs/tailwindcss |
| **Astro** | astro | @astrojs/tailwind, @astrojs/react or @astrojs/vue, @astrojs/sitemap |
| **SvelteKit** | @sveltejs/kit, svelte | @sveltejs/adapter-auto, svelte-headlessui |
| **Vite+React** | react, react-dom, vite | react-router-dom, @tanstack/react-query, zustand, zod |
