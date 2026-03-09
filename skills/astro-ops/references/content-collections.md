# Content Collections Reference

Comprehensive guide to Astro content collections: schema definition, querying, references, MDX integration, and the Content Layer API.

## Schema Definition with Zod

### Basic Schema

```typescript
// src/content.config.ts (Astro 5+)
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }),
});

export const collections = { blog };
```

### All Supported Zod Types

```typescript
import { defineCollection, z, reference } from 'astro:content';
import { glob, file } from 'astro/loaders';

const fullSchema = defineCollection({
  loader: glob({ pattern: '**/*.mdx', base: './src/content/posts' }),
  schema: ({ image }) => z.object({
    // String types
    title: z.string(),
    slug: z.string().optional(),
    description: z.string().max(160),
    canonical: z.string().url().optional(),

    // Number types
    readingTime: z.number().positive().optional(),
    order: z.number().int().min(0).default(0),

    // Date types
    pubDate: z.coerce.date(),                    // Accepts string or Date
    updatedDate: z.coerce.date().optional(),

    // Boolean
    draft: z.boolean().default(false),
    featured: z.boolean().default(false),

    // Enum
    category: z.enum(['tutorial', 'guide', 'reference', 'blog']),
    status: z.enum(['draft', 'review', 'published']).default('draft'),

    // Arrays
    tags: z.array(z.string()).default([]),
    relatedSlugs: z.array(z.string()).optional(),

    // Nested objects
    author: z.object({
      name: z.string(),
      email: z.string().email().optional(),
    }),

    // Union types
    layout: z.union([
      z.literal('default'),
      z.literal('wide'),
      z.literal('full'),
    ]).default('default'),

    // Image (validated by Astro, returns optimized metadata)
    heroImage: image().optional(),
    thumbnail: image().refine((img) => img.width >= 200, {
      message: 'Thumbnail must be at least 200px wide',
    }).optional(),

    // References to other collections
    author_ref: reference('authors'),
    relatedPosts: z.array(reference('blog')).default([]),

    // Custom transforms
    title_normalized: z.string().transform((val) => val.toLowerCase().trim()),

    // Passthrough for unknown fields
    // extra: z.record(z.unknown()),
  }),
});
```

### Image Schema

```typescript
// The image() helper validates that referenced images exist at build time
const gallery = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/gallery' }),
  schema: ({ image }) => z.object({
    title: z.string(),
    cover: image(),
    // Refine with dimension constraints
    hero: image().refine((img) => img.width >= 1080, {
      message: 'Hero image must be at least 1080px wide',
    }),
    // Array of images
    photos: z.array(image()).default([]),
  }),
});
```

Usage in frontmatter:

```markdown
---
title: My Gallery
cover: ./images/cover.jpg        # Relative path to image
hero: ../../assets/hero.png      # Can reference shared assets
photos:
  - ./images/photo1.jpg
  - ./images/photo2.jpg
---
```

## References Between Collections

### Defining References

```typescript
// src/content.config.ts
import { defineCollection, z, reference } from 'astro:content';
import { glob, file } from 'astro/loaders';

const authors = defineCollection({
  loader: glob({ pattern: '**/*.json', base: './src/content/authors' }),
  schema: z.object({
    name: z.string(),
    avatar: z.string(),
    bio: z.string(),
    website: z.string().url().optional(),
  }),
});

const categories = defineCollection({
  loader: file('src/data/categories.json'),
  schema: z.object({
    name: z.string(),
    slug: z.string(),
    description: z.string(),
  }),
});

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    // Single reference
    author: reference('authors'),
    // Optional reference
    reviewer: reference('authors').optional(),
    // Array of references
    categories: z.array(reference('categories')).default([]),
    // Self-reference (same collection)
    relatedPosts: z.array(reference('blog')).default([]),
  }),
});

export const collections = { authors, categories, blog };
```

### Blog post frontmatter with references

```markdown
---
title: Getting Started with Astro
author: jane-doe
reviewer: john-smith
categories:
  - tutorials
  - astro
relatedPosts:
  - advanced-astro-patterns
  - astro-vs-next
---
```

### Resolving References

```astro
---
import { getEntry, getCollection } from 'astro:content';

// Get the blog post
const post = await getEntry('blog', 'getting-started');

// Resolve single reference
const author = await getEntry(post.data.author);
// author.data.name, author.data.avatar, etc.

// Resolve optional reference
const reviewer = post.data.reviewer
  ? await getEntry(post.data.reviewer)
  : null;

// Resolve array of references
const categories = await Promise.all(
  post.data.categories.map((ref) => getEntry(ref))
);

// Resolve self-references
const relatedPosts = await Promise.all(
  post.data.relatedPosts.map((ref) => getEntry(ref))
);
---

<article>
  <h1>{post.data.title}</h1>
  <p>By {author.data.name}</p>
  {reviewer && <p>Reviewed by {reviewer.data.name}</p>}
  <div class="categories">
    {categories.map((cat) => <span>{cat.data.name}</span>)}
  </div>
</article>
```

## Querying Collections

### getCollection

```typescript
import { getCollection } from 'astro:content';

// Get all entries
const allPosts = await getCollection('blog');

// Filter with callback (type-safe)
const publishedPosts = await getCollection('blog', ({ data }) => {
  return !data.draft && data.pubDate <= new Date();
});

// Sort by date (descending)
const sortedPosts = (await getCollection('blog'))
  .sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());

// Filter by tag
const astroTagged = await getCollection('blog', ({ data }) => {
  return data.tags.includes('astro');
});

// Paginate
const pageSize = 10;
const page = 1;
const paginatedPosts = sortedPosts.slice(
  (page - 1) * pageSize,
  page * pageSize
);
```

### getEntry

```typescript
import { getEntry } from 'astro:content';

// Get single entry by collection + id
const post = await getEntry('blog', 'my-first-post');

// Returns null if not found (in Astro 5, throws if not found by default)
if (!post) {
  return Astro.redirect('/404');
}

// Access data
console.log(post.data.title);   // Type-safe frontmatter
console.log(post.id);           // Entry ID (filename without extension)

// Render content
const { Content, headings, remarkPluginFrontmatter } = await post.render();
```

### Dynamic Routes with Collections

```astro
---
// src/pages/blog/[slug].astro
import { getCollection, render } from 'astro:content';

export async function getStaticPaths() {
  const posts = await getCollection('blog', ({ data }) => !data.draft);
  return posts.map((post) => ({
    params: { slug: post.id },
    props: { post },
  }));
}

const { post } = Astro.props;
const { Content, headings } = await render(post);
---

<article>
  <h1>{post.data.title}</h1>
  <time datetime={post.data.pubDate.toISOString()}>
    {post.data.pubDate.toLocaleDateString()}
  </time>
  <Content />
</article>
```

### Pagination with Collections

```astro
---
// src/pages/blog/[...page].astro
import type { GetStaticPaths } from 'astro';
import { getCollection } from 'astro:content';

export const getStaticPaths = (async ({ paginate }) => {
  const posts = (await getCollection('blog', ({ data }) => !data.draft))
    .sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());

  return paginate(posts, { pageSize: 10 });
}) satisfies GetStaticPaths;

const { page } = Astro.props;
// page.data       - current page entries
// page.currentPage - current page number
// page.lastPage   - total pages
// page.url.prev   - previous page URL
// page.url.next   - next page URL
// page.total      - total entries
---

{page.data.map((post) => (
  <article>
    <a href={`/blog/${post.id}`}>{post.data.title}</a>
  </article>
))}

<nav>
  {page.url.prev && <a href={page.url.prev}>Previous</a>}
  <span>Page {page.currentPage} of {page.lastPage}</span>
  {page.url.next && <a href={page.url.next}>Next</a>}
</nav>
```

## MDX Integration

### Setup

```bash
npx astro add mdx
```

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';

export default defineConfig({
  integrations: [mdx()],
});
```

### Custom Components in MDX

```mdx
---
title: Interactive Tutorial
---

import Counter from '../../components/Counter.tsx';
import Callout from '../../components/Callout.astro';
import { Code } from 'astro:components';

# {frontmatter.title}

Here's a live counter:

<Counter client:visible initialCount={5} />

<Callout type="warning">
  Remember to hydrate interactive components with a `client:*` directive!
</Callout>
```

### Passing Components to Rendered Content

```astro
---
import { getEntry, render } from 'astro:content';
import Callout from '../components/Callout.astro';
import CodeBlock from '../components/CodeBlock.astro';

const post = await getEntry('blog', 'my-post');
const { Content } = await render(post);
---

<!-- Override default HTML elements with custom components -->
<Content components={{
  h1: 'h2',                    <!-- Remap h1 to h2 -->
  blockquote: Callout,         <!-- Replace blockquotes with Callout -->
  pre: CodeBlock,              <!-- Replace code blocks -->
}} />
```

### Remark and Rehype Plugins

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import remarkToc from 'remark-toc';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import rehypeSlug from 'rehype-slug';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';

export default defineConfig({
  integrations: [mdx()],
  markdown: {
    remarkPlugins: [
      remarkToc,
      remarkMath,
    ],
    rehypePlugins: [
      rehypeSlug,
      [rehypeAutolinkHeadings, { behavior: 'wrap' }],
      rehypeKatex,
    ],
    // Syntax highlighting
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
  },
});
```

## Content Layer API (Astro 5)

The Content Layer API replaces the filesystem-coupled collection system with a flexible loader-based approach.

### Built-in Loaders

```typescript
// src/content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

// Glob loader - load from filesystem with glob patterns
const blog = defineCollection({
  loader: glob({
    pattern: '**/*.{md,mdx}',
    base: './src/content/blog',
    // Optional: generate ID from filename
    generateId: ({ entry, base, data }) => {
      return entry.replace(/\.mdx?$/, '');
    },
  }),
  schema: z.object({
    title: z.string(),
    pubDate: z.coerce.date(),
  }),
});

// File loader - load from a single JSON/YAML file
const navigation = defineCollection({
  loader: file('src/data/navigation.json'),
  schema: z.object({
    label: z.string(),
    href: z.string(),
    order: z.number(),
  }),
});

// File loader with nested data
const settings = defineCollection({
  loader: file('src/data/settings.yaml', {
    // Extract array from nested path
    parser: (text) => {
      const yaml = parseYaml(text);
      return yaml.site.menuItems;
    },
  }),
  schema: z.object({
    label: z.string(),
    url: z.string(),
  }),
});

export const collections = { blog, navigation, settings };
```

### Custom Loaders

```typescript
// src/loaders/api-loader.ts
import type { Loader } from 'astro/loaders';

export function apiLoader(options: { url: string; apiKey: string }): Loader {
  return {
    name: 'api-loader',
    load: async ({ store, logger, parseData, generateDigest }) => {
      logger.info('Fetching data from API...');

      const response = await fetch(options.url, {
        headers: { Authorization: `Bearer ${options.apiKey}` },
      });
      const items = await response.json();

      // Clear previous data
      store.clear();

      for (const item of items) {
        const digest = generateDigest(item);

        // Parse and validate data against schema
        const data = await parseData({
          id: String(item.id),
          data: item,
        });

        store.set({
          id: String(item.id),
          data,
          digest,
          // Optional: rendered HTML content
          rendered: {
            html: item.content_html ?? '',
          },
        });
      }

      logger.info(`Loaded ${items.length} items`);
    },
  };
}
```

```typescript
// src/content.config.ts
import { defineCollection, z } from 'astro:content';
import { apiLoader } from '../loaders/api-loader';

const products = defineCollection({
  loader: apiLoader({
    url: 'https://api.example.com/products',
    apiKey: import.meta.env.API_KEY,
  }),
  schema: z.object({
    name: z.string(),
    price: z.number(),
    description: z.string(),
    inStock: z.boolean(),
  }),
});

export const collections = { products };
```

### CMS Integration Loaders

```typescript
// Example: Notion loader (community package)
import { notionLoader } from '@notionhq/astro-loader';

const docs = defineCollection({
  loader: notionLoader({
    databaseId: import.meta.env.NOTION_DB_ID,
    auth: import.meta.env.NOTION_API_KEY,
  }),
  schema: z.object({
    title: z.string(),
    status: z.enum(['Draft', 'Published']),
    lastEdited: z.coerce.date(),
  }),
});
```

### Incremental Builds

```typescript
// Custom loader with incremental update support
export function incrementalLoader(options: { url: string }): Loader {
  return {
    name: 'incremental-loader',
    load: async ({ store, logger, parseData, meta }) => {
      // meta.store persists between builds
      const lastSync = meta.get('lastSync');

      const url = lastSync
        ? `${options.url}?since=${lastSync}`
        : options.url;

      const response = await fetch(url);
      const items = await response.json();

      // Only update changed items (don't clear store)
      for (const item of items) {
        if (item.deleted) {
          store.delete(String(item.id));
        } else {
          const data = await parseData({
            id: String(item.id),
            data: item,
          });
          store.set({ id: String(item.id), data });
        }
      }

      meta.set('lastSync', new Date().toISOString());
    },
  };
}
```

## Type Generation and InferEntrySchema

### Generating Types

```bash
# Manually regenerate types after schema changes
npx astro sync
```

### Using InferEntrySchema

```typescript
// src/lib/types.ts
import type { InferEntrySchema, CollectionEntry } from 'astro:content';

// Infer the schema type for a collection
type BlogPost = InferEntrySchema<'blog'>;
// { title: string; description: string; pubDate: Date; ... }

// Full collection entry type (includes id, data, render, etc.)
type BlogEntry = CollectionEntry<'blog'>;

// Use in utility functions
function formatPost(post: CollectionEntry<'blog'>) {
  return {
    title: post.data.title,
    url: `/blog/${post.id}`,
    date: post.data.pubDate.toLocaleDateString(),
  };
}

// Use in component props
interface PostListProps {
  posts: CollectionEntry<'blog'>[];
  showDrafts?: boolean;
}
```

### Type-safe Frontmatter in Layouts

```astro
---
// src/layouts/BlogPost.astro
import type { CollectionEntry } from 'astro:content';

interface Props {
  post: CollectionEntry<'blog'>;
}

const { post } = Astro.props;
const { title, description, pubDate, heroImage, author } = post.data;
---

<html>
  <head>
    <title>{title}</title>
    <meta name="description" content={description} />
  </head>
  <body>
    <article>
      <h1>{title}</h1>
      <time datetime={pubDate.toISOString()}>
        {pubDate.toLocaleDateString('en-US', {
          year: 'numeric', month: 'long', day: 'numeric'
        })}
      </time>
      <slot />
    </article>
  </body>
</html>
```

## Migration Guide: Astro 2/3/4 to Astro 5

### Collection Config Location

```
# Astro 4 (legacy)
src/content/config.ts

# Astro 5 (Content Layer API)
src/content.config.ts        # Note: moved to src root
```

### Adding Loaders (Required in Astro 5)

```typescript
// Astro 4 - implicit filesystem loading
const blog = defineCollection({
  type: 'content',               // Remove this
  schema: z.object({ ... }),
});

// Astro 5 - explicit loaders
import { glob, file } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({                  // Add loader
    pattern: '**/*.{md,mdx}',
    base: './src/content/blog',
  }),
  schema: z.object({ ... }),
});
```

### Data Collections Migration

```typescript
// Astro 4 - data collections
const authors = defineCollection({
  type: 'data',                   // Remove this
  schema: z.object({ ... }),
});

// Astro 5 - use file loader
import { file } from 'astro/loaders';

const authors = defineCollection({
  loader: file('src/data/authors.json'),  // Or glob for multiple files
  schema: z.object({ ... }),
});
```

### Entry ID Changes

```typescript
// Astro 4
post.slug;           // Used for routing
post.id;             // Included file extension: "my-post.md"

// Astro 5
post.id;             // Slug-like, no extension: "my-post"
// post.slug removed - use post.id instead
```

### Rendering Changes

```typescript
// Astro 4
const { Content } = await post.render();

// Astro 5
import { render } from 'astro:content';
const { Content } = await render(post);
```

### Checklist for Migration

1. Move `src/content/config.ts` to `src/content.config.ts`
2. Add `loader` property to every collection (use `glob()` or `file()`)
3. Remove `type: 'content'` and `type: 'data'` from collections
4. Replace `post.slug` with `post.id` in routing
5. Replace `post.render()` with `render(post)` from `astro:content`
6. Run `npx astro sync` to regenerate types
7. Update `getStaticPaths()` to use `post.id` instead of `post.slug`
8. Test all content pages and dynamic routes
