# Server Components

React Server Components (RSC), Server Actions, Next.js App Router patterns, caching, and streaming.

---

## RSC Architecture

Server Components render on the server and send HTML (and a serialized React tree) to the client. They never ship their code to the browser.

```
Request
   │
   ▼
Server Component Tree (renders on server)
   │
   ├─ Async data fetching (db, fs, fetch)
   ├─ Heavy dependencies (never in client bundle)
   └─ Client Component boundaries (marked 'use client')
          │
          ▼
       Hydration (client takes over interactive parts only)
```

**Serialization rules — what can cross the server→client boundary:**
- Strings, numbers, booleans, null, undefined
- Arrays and plain objects of the above
- Promises (unwrapped by `use()` on client)
- JSX / React elements
- **NOT**: functions, class instances, Date objects, Maps, Sets, RegExp (must be serialized or passed differently)

---

## Server Components

```tsx
// app/users/page.tsx — Server Component (default, no directive needed)
import { db } from '@/lib/db';
import { cache } from 'react';

// cache() deduplicates calls within a single render pass
const getUser = cache(async (id: string) => {
  return db.query.users.findFirst({ where: eq(users.id, id) });
});

// Top-level async component — no useEffect, no loading state needed
export default async function UsersPage() {
  // Fetch in parallel — both start simultaneously
  const [users, stats] = await Promise.all([
    db.query.users.findMany({ limit: 50 }),
    db.query.stats.findFirst(),
  ]);

  return (
    <main>
      <h1>Users ({stats?.total ?? 0})</h1>
      <UserList users={users} />
    </main>
  );
}
```

### What You Can Do in Server Components

```tsx
// 1. Database queries (Drizzle, Prisma, raw SQL)
const posts = await db.select().from(postsTable).where(eq(postsTable.published, true));

// 2. File system access
import { readFile } from 'fs/promises';
const content = await readFile('./data/content.md', 'utf8');

// 3. Server-only secrets (never sent to client)
const apiData = await fetch('https://api.example.com/data', {
  headers: { Authorization: `Bearer ${process.env.SECRET_API_KEY}` },
});

// 4. Import heavy libraries without bundle cost
import { parse } from 'some-huge-parser'; // 2MB — never in client bundle
const result = parse(rawData);

// 5. Conditional rendering based on server state/permissions
const session = await auth();
if (!session?.user) redirect('/login');
```

---

## Client Components

```tsx
// components/counter.tsx
'use client'; // marks this module and all its imports as client code

import { useState, useEffect } from 'react';

// Anything requiring hooks, browser APIs, or interactivity
export function Counter({ initialCount = 0 }: { initialCount?: number }) {
  const [count, setCount] = useState(initialCount);

  useEffect(() => {
    document.title = `Count: ${count}`;
  }, [count]);

  return (
    <div>
      <p>{count}</p>
      <button onClick={() => setCount(c => c + 1)}>Increment</button>
    </div>
  );
}
```

### Passing Server Data to Client Components

```tsx
// Server Component (parent)
async function ProductPage({ id }: { id: string }) {
  const product = await db.products.findUnique({ where: { id } });

  // Pass serializable data as props
  return (
    <div>
      <ProductImages images={product.images} /> {/* Server Component */}
      <AddToCart
        productId={product.id}  // string — serializable
        price={product.price}    // number — serializable
        // onAdd={addToCart}     // ERROR: functions can't cross boundary
      />
    </div>
  );
}

// Pattern: pass Server Component output as children to Client Component
async function Layout({ children }: { children: React.ReactNode }) {
  const nav = await buildNavigation(); // server-only fetch
  return (
    <Shell nav={<ServerNav items={nav} />}> {/* Shell is Client Component */}
      {children}
    </Shell>
  );
}
```

---

## Server Actions

```tsx
// app/actions.ts
'use server'; // all exports are server actions

import { revalidatePath, revalidateTag } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';

const createPostSchema = z.object({
  title: z.string().min(1).max(200),
  content: z.string().min(10),
  published: z.coerce.boolean().default(false),
});

export async function createPost(formData: FormData) {
  // Validate
  const parsed = createPostSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { error: parsed.error.flatten().fieldErrors };
  }

  // Auth check
  const session = await auth();
  if (!session?.user) throw new Error('Unauthorized');

  // Persist
  const post = await db.posts.create({
    data: { ...parsed.data, authorId: session.user.id },
  });

  // Invalidate cache
  revalidatePath('/posts');
  revalidateTag('posts');

  // Redirect (throws internally, not caught by try/catch)
  redirect(`/posts/${post.id}`);
}

// Progressive enhancement: works without JS, enhanced with JS
export async function deletePost(id: string) {
  await db.posts.delete({ where: { id } });
  revalidatePath('/posts');
}
```

### Form with Server Action

```tsx
// app/posts/new/page.tsx
import { createPost } from '../actions';

// Server Component — no 'use client' needed
export default function NewPostPage() {
  return (
    <form action={createPost}>
      <input name="title" placeholder="Post title" required />
      <textarea name="content" placeholder="Content" required />
      <label>
        <input type="checkbox" name="published" value="true" />
        Publish immediately
      </label>
      <button type="submit">Create Post</button>
    </form>
  );
}
```

### Server Action with useActionState (React 19)

```tsx
'use client';

import { useActionState } from 'react';
import { createPost } from '../actions';

type ActionState = { error?: Record<string, string[]>; message?: string } | null;

export function CreatePostForm() {
  const [state, action, isPending] = useActionState<ActionState, FormData>(
    createPost,
    null
  );

  return (
    <form action={action}>
      <input name="title" aria-invalid={!!state?.error?.title} />
      {state?.error?.title && <p role="alert">{state.error.title[0]}</p>}

      <textarea name="content" />
      {state?.error?.content && <p role="alert">{state.error.content[0]}</p>}

      <button disabled={isPending}>
        {isPending ? 'Creating...' : 'Create Post'}
      </button>
    </form>
  );
}
```

---

## Next.js App Router File Conventions

```
app/
├── layout.tsx          # Shared layout (wraps all pages in segment)
├── page.tsx            # Route UI (publicly accessible at URL)
├── loading.tsx         # Suspense boundary skeleton (automatic)
├── error.tsx           # Error boundary fallback (must be 'use client')
├── not-found.tsx       # 404 UI (shown by notFound() call)
├── route.ts            # API route handler (GET, POST, etc.)
├── template.tsx        # Like layout but re-mounts on navigation
└── (group)/            # Route group — parentheses = no URL segment
    └── dashboard/
        └── page.tsx    # app.com/dashboard
```

```tsx
// app/layout.tsx
import { Inter } from 'next/font/google';
import type { Metadata } from 'next';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: { template: '%s | MyApp', default: 'MyApp' },
  description: 'My application',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={inter.className}>{children}</body>
    </html>
  );
}

// app/posts/[id]/error.tsx — must be Client Component
'use client';

export default function PostError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div role="alert">
      <h2>Failed to load post</h2>
      <p>{error.message}</p>
      <button onClick={reset}>Try again</button>
    </div>
  );
}

// app/api/users/route.ts — API Route Handler
import { NextRequest, NextResponse } from 'next/server';

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const limit = Number(searchParams.get('limit') ?? '20');

  const users = await db.users.findMany({ take: limit });
  return NextResponse.json(users);
}

export async function POST(request: NextRequest) {
  const body = await request.json();
  const user = await db.users.create({ data: body });
  return NextResponse.json(user, { status: 201 });
}
```

---

## Caching

```tsx
// 1. fetch() cache (Next.js extends native fetch)
async function getPost(id: string) {
  const res = await fetch(`https://api.example.com/posts/${id}`, {
    next: {
      revalidate: 3600, // revalidate every 1 hour (ISR)
      tags: ['posts', `post-${id}`], // tag for on-demand revalidation
    },
    // cache: 'no-store'  // disable caching entirely (always fresh)
    // cache: 'force-cache' // always use cache (default for static)
  });
  return res.json();
}

// 2. unstable_cache (for non-fetch data sources like ORMs)
import { unstable_cache } from 'next/cache';

const getCachedUsers = unstable_cache(
  async () => db.users.findMany(),
  ['users-list'],          // cache key
  { revalidate: 300, tags: ['users'] } // 5 min TTL + tag
);

// 3. On-demand revalidation (Server Action or API route)
import { revalidatePath, revalidateTag } from 'next/cache';

export async function updatePost(id: string, data: Partial<Post>) {
  await db.posts.update({ where: { id }, data });

  revalidateTag(`post-${id}`);    // invalidate specific post cache
  revalidateTag('posts');          // invalidate all posts list cache
  revalidatePath('/posts');        // invalidate path-based cache
  revalidatePath(`/posts/${id}`);
}
```

---

## Streaming with Suspense

```tsx
// Wrap slow components in Suspense — page loads instantly,
// slow parts stream in progressively
import { Suspense } from 'react';

// app/dashboard/page.tsx
export default function DashboardPage() {
  return (
    <div className="grid">
      {/* Fast — renders immediately */}
      <WelcomeHeader />

      {/* Slow DB queries stream in independently */}
      <Suspense fallback={<MetricsSkeleton />}>
        <DashboardMetrics /> {/* async Server Component */}
      </Suspense>

      <Suspense fallback={<ActivitySkeleton />}>
        <RecentActivity /> {/* async Server Component */}
      </Suspense>

      <Suspense fallback={<ChartSkeleton />}>
        <RevenueChart /> {/* slow, streams last */}
      </Suspense>
    </div>
  );
}

// loading.tsx provides automatic Suspense for the entire segment
// app/dashboard/loading.tsx
export default function DashboardLoading() {
  return <DashboardSkeleton />;
}
```

---

## Metadata API

```tsx
// Static metadata
export const metadata: Metadata = {
  title: 'My Page',
  description: 'Page description',
  openGraph: {
    title: 'My Page',
    images: [{ url: '/og-image.png', width: 1200, height: 630 }],
  },
};

// Dynamic metadata
export async function generateMetadata(
  { params }: { params: { id: string } }
): Promise<Metadata> {
  const post = await getPost(params.id);
  if (!post) return { title: 'Post Not Found' };

  return {
    title: post.title,
    description: post.excerpt,
    openGraph: {
      title: post.title,
      images: [{ url: post.coverImage }],
    },
    alternates: {
      canonical: `https://mysite.com/posts/${post.slug}`,
    },
  };
}
```

---

## Patterns to Avoid

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| `'use client'` at root layout | Entire app becomes client-side; no RSC benefits | Push `'use client'` to leaf components only |
| Waterfall data fetching in Server Components | Each await blocks the next | `Promise.all()` for parallel fetches |
| No Suspense boundaries | Entire page waits for slowest component | Wrap each async section in `<Suspense>` |
| Server Action without validation | Security risk, bad UX | Always validate with Zod before DB write |
| Fetching same data in multiple Server Components | Multiple DB queries for same data | `cache()` wrapper to deduplicate per request |
| Passing non-serializable data to Client Components | Runtime error | Only pass strings, numbers, plain objects, JSX |
| Large third-party imports in Client Components | Bloated client bundle | Move to Server Component; import only what's needed |
| `cookies()` or `headers()` outside Server Components | Runtime error | Only in Server Components, Route Handlers, Server Actions |
