# Islands Architecture and Rendering Reference

Deep dive into Astro's islands architecture, partial hydration, client directives, framework integration, and server islands.

## How Islands Architecture Works

Astro renders all components to static HTML on the server by default. Interactive components ("islands") are selectively hydrated on the client, shipping JavaScript only for the parts of the page that need interactivity.

```
Traditional SPA:
┌──────────────────────────────────────┐
│           Full JavaScript App         │  ← All JS shipped
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐       │
│  │Nav │ │Hero│ │Card│ │Form│       │
│  └────┘ └────┘ └────┘ └────┘       │
└──────────────────────────────────────┘

Astro Islands:
┌──────────────────────────────────────┐
│           Static HTML (zero JS)       │
│  ┌────┐                              │
│  │Nav │ ← Island (client:load)       │  ← Only island JS shipped
│  └────┘                              │
│  ┌────────────┐                      │
│  │  Hero Text  │ ← Static HTML       │  ← No JS
│  └────────────┘                      │
│  ┌────┐ ┌────┐ ┌────┐              │
│  │Card│ │Card│ │Card│ ← Static      │  ← No JS
│  └────┘ └────┘ └────┘              │
│  ┌──────┐                            │
│  │ Form │ ← Island (client:visible) │  ← JS loaded on scroll
│  └──────┘                            │
└──────────────────────────────────────┘
```

### The Hydration Process

1. **Server**: Astro renders ALL components (including React, Vue, Svelte) to HTML
2. **Client**: Browser receives pure HTML - instant display, zero JS
3. **Hydration**: Based on client directive, island JS is loaded and components become interactive
4. **Result**: Page is visible immediately; interactivity loads progressively

```astro
---
// This component renders to HTML on the server
// Then hydrates with React on the client
import SearchBar from '../components/SearchBar.tsx';
---

<!-- Static HTML (no JS) -->
<header>
  <h1>My Site</h1>
  <!-- React island - hydrates when visible -->
  <SearchBar client:visible placeholder="Search docs..." />
</header>
```

## Client Directives Deep Dive

### client:load

Hydrates immediately when the page loads. Highest priority.

```astro
---
import AuthButton from '../components/AuthButton.tsx';
import NavMenu from '../components/NavMenu.tsx';
---

<!-- Use for: above-fold interactive elements that users interact with immediately -->
<AuthButton client:load />
<NavMenu client:load />
```

**When to use:**
- Navigation menus that must be interactive on page load
- Authentication state indicators
- Critical CTAs above the fold
- Elements that must respond to first user interaction

**When NOT to use:**
- Content below the fold (use `client:visible`)
- Non-critical widgets (use `client:idle`)
- Large components that aren't immediately needed

### client:idle

Hydrates after the page has finished loading and `requestIdleCallback` fires.

```astro
---
import CommentSection from '../components/CommentSection.tsx';
import NewsletterSignup from '../components/NewsletterSignup.vue';
import ShareButtons from '../components/ShareButtons.tsx';
---

<!-- Use for: important but not immediately critical interactivity -->
<CommentSection client:idle postId={post.id} />
<NewsletterSignup client:idle />
<ShareButtons client:idle url={Astro.url} />
```

**When to use:**
- Comment sections
- Newsletter signup forms
- Social share buttons
- Chat widgets
- Analytics dashboards below hero

**Behavior:**
- Waits for `requestIdleCallback` (or `setTimeout` fallback after 200ms)
- Doesn't block initial page render or first paint
- Loads before user scrolls (unlike `client:visible`)

### client:visible

Hydrates when the element enters the viewport (IntersectionObserver).

```astro
---
import ImageCarousel from '../components/ImageCarousel.svelte';
import InteractiveChart from '../components/InteractiveChart.tsx';
import Testimonials from '../components/Testimonials.vue';
---

<!-- Use for: below-fold content that's only needed when scrolled to -->
<ImageCarousel client:visible images={gallery} />
<InteractiveChart client:visible data={chartData} />
<Testimonials client:visible />

<!-- With rootMargin - preload 200px before visible -->
<InteractiveChart client:visible={{rootMargin: "200px"}} data={chartData} />
```

**When to use:**
- Image carousels/galleries far down the page
- Interactive charts and data visualizations
- Testimonial sliders
- Footer widgets
- Any interactive content below the fold

**Behavior:**
- Uses IntersectionObserver to detect visibility
- Zero JS loaded until element is about to enter viewport
- Supports `rootMargin` option for preloading

### client:media

Hydrates only when a CSS media query matches.

```astro
---
import MobileMenu from '../components/MobileMenu.tsx';
import DesktopSidebar from '../components/DesktopSidebar.tsx';
import DarkModeToggle from '../components/DarkModeToggle.tsx';
---

<!-- Only hydrate on mobile -->
<MobileMenu client:media="(max-width: 768px)" />

<!-- Only hydrate on desktop -->
<DesktopSidebar client:media="(min-width: 1024px)" />

<!-- Hydrate based on user preference -->
<DarkModeToggle client:media="(prefers-color-scheme: dark)" />
```

**When to use:**
- Mobile-only navigation (hamburger menus)
- Desktop-only sidebars with interactivity
- Responsive components that differ dramatically by viewport
- Reduced motion alternatives

**Behavior:**
- Checks media query on load; hydrates if matched
- Also watches for changes (e.g., viewport resize triggers hydration)
- If media query never matches, JS is never loaded

### client:only

Skips server rendering entirely. Component renders ONLY on the client.

```astro
---
import ThreeScene from '../components/ThreeScene.tsx';
import MapComponent from '../components/Map.tsx';
import CanvasEditor from '../components/CanvasEditor.svelte';
---

<!-- MUST specify the framework -->
<ThreeScene client:only="react" />
<MapComponent client:only="react" />
<CanvasEditor client:only="svelte" />

<!-- Valid framework values: -->
<!-- client:only="react" -->
<!-- client:only="preact" -->
<!-- client:only="vue" -->
<!-- client:only="svelte" -->
<!-- client:only="solid-js" -->
<!-- client:only="lit" -->
```

**When to use:**
- WebGL / Three.js / Canvas components
- Map libraries (Leaflet, Mapbox) that access `window`
- Browser-only APIs (Web Audio, WebRTC, etc.)
- Components that crash during SSR

**Behavior:**
- No HTML rendered on server (shows nothing until JS loads)
- No hydration mismatch possible (no server HTML to diff)
- Framework string is required so Astro knows which renderer to use

### No Directive (Static)

Component renders to HTML only. Zero client-side JavaScript.

```astro
---
import Card from '../components/Card.astro';
import Footer from '../components/Footer.astro';
import BlogPostPreview from '../components/BlogPostPreview.astro';
---

<!-- Pure HTML, no JS ever -->
<Card title="Hello" description="World" />
<Footer />
<BlogPostPreview post={post} />
```

**When to use:**
- Content display (cards, headers, footers)
- Anything that doesn't need user interaction
- Layout components
- Most of your page (aim for 80%+ static)

## Framework Integration

### Multi-framework Setup

```typescript
// astro.config.mjs
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';
import vue from '@astrojs/vue';
import svelte from '@astrojs/svelte';
import solid from '@astrojs/solid-js';
import preact from '@astrojs/preact';

export default defineConfig({
  integrations: [
    react({
      include: ['**/react/**'],    // Only process files in react/ dirs
    }),
    preact({
      include: ['**/preact/**'],   // Disambiguate from React
    }),
    vue(),
    svelte(),
    solid({
      include: ['**/solid/**'],
    }),
  ],
});
```

### File Organization for Multi-framework

```
src/components/
├── react/              # React components (.tsx/.jsx)
│   ├── Counter.tsx
│   └── SearchBar.tsx
├── vue/                # Vue components (.vue)
│   ├── TodoList.vue
│   └── Modal.vue
├── svelte/             # Svelte components (.svelte)
│   ├── Carousel.svelte
│   └── Toggle.svelte
├── solid/              # Solid components (.tsx)
│   └── DataGrid.tsx
├── Header.astro        # Astro (static)
└── Footer.astro
```

### Using Multiple Frameworks in One Page

```astro
---
import ReactNav from '../components/react/NavBar.tsx';
import VueForm from '../components/vue/ContactForm.vue';
import SvelteCarousel from '../components/svelte/Carousel.svelte';
import Footer from '../components/Footer.astro';
---

<ReactNav client:load user={user} />

<main>
  <h1>Multi-framework Page</h1>

  <SvelteCarousel client:visible items={images} />

  <VueForm client:idle endpoint="/api/contact" />
</main>

<Footer />
```

## Sharing State Between Islands

Islands are isolated by default. Here are patterns for sharing state.

### Nanostores (Recommended)

```bash
npm install nanostores @nanostores/react @nanostores/vue @nanostores/svelte
```

```typescript
// src/stores/cart.ts
import { atom, map, computed } from 'nanostores';

// Simple atom
export const isMenuOpen = atom(false);

// Map (object store)
export interface CartItem {
  id: string;
  name: string;
  price: number;
  quantity: number;
}

export const cartItems = map<Record<string, CartItem>>({});

// Computed (derived state)
export const cartTotal = computed(cartItems, (items) => {
  return Object.values(items).reduce(
    (sum, item) => sum + item.price * item.quantity,
    0
  );
});

// Actions
export function addToCart(item: CartItem) {
  const existing = cartItems.get()[item.id];
  if (existing) {
    cartItems.setKey(item.id, {
      ...existing,
      quantity: existing.quantity + 1,
    });
  } else {
    cartItems.setKey(item.id, { ...item, quantity: 1 });
  }
}

export function removeFromCart(id: string) {
  const items = { ...cartItems.get() };
  delete items[id];
  cartItems.set(items);
}
```

```tsx
// React component using the store
import { useStore } from '@nanostores/react';
import { cartItems, cartTotal, addToCart } from '../stores/cart';

export function CartButton() {
  const $items = useStore(cartItems);
  const $total = useStore(cartTotal);
  const count = Object.keys($items).length;

  return (
    <button>
      Cart ({count}) - ${$total.toFixed(2)}
    </button>
  );
}
```

```svelte
<!-- Svelte component using same store -->
<script>
  import { cartItems, cartTotal } from '../stores/cart';
</script>

<div>
  {#each Object.values($cartItems) as item}
    <p>{item.name}: ${item.price} x {item.quantity}</p>
  {/each}
  <p>Total: ${$cartTotal.toFixed(2)}</p>
</div>
```

### Custom Events

```astro
---
// For simple one-way communication between islands
---

<script>
  // Dispatch from any island
  document.dispatchEvent(new CustomEvent('cart:add', {
    detail: { id: '123', name: 'Widget', price: 9.99 }
  }));

  // Listen in any island
  document.addEventListener('cart:add', (e: CustomEvent) => {
    console.log('Added to cart:', e.detail);
  });
</script>
```

### URL State

```typescript
// Use URL search params for shareable state
function updateFilter(key: string, value: string) {
  const url = new URL(window.location.href);
  url.searchParams.set(key, value);
  window.history.pushState({}, '', url);

  // Notify other islands
  document.dispatchEvent(new CustomEvent('url:change', {
    detail: Object.fromEntries(url.searchParams),
  }));
}
```

## Performance Budgets

### Measuring Island Size

```typescript
// astro.config.mjs - analyze bundle
import { defineConfig } from 'astro/config';
import { visualizer } from 'rollup-plugin-visualizer';

export default defineConfig({
  vite: {
    plugins: [
      visualizer({
        filename: './dist/stats.html',
        gzipSize: true,
        brotliSize: true,
      }),
    ],
  },
});
```

### Bundle Size Guidelines

| Component Type | Target Size (gzipped) | Strategy |
|---------------|----------------------|----------|
| Critical island (client:load) | < 20 KB | Minimize dependencies |
| Deferred island (client:idle) | < 50 KB | Acceptable, loads after paint |
| Lazy island (client:visible) | < 100 KB | OK for rich interactive content |
| Full SPA island (client:only) | < 200 KB | Consider code splitting |

### Optimization Strategies

```typescript
// 1. Prefer Preact over React for smaller islands
import preact from '@astrojs/preact';

// 2. Dynamic imports for heavy dependencies
const Chart = lazy(() => import('./HeavyChart'));

// 3. Tree-shakeable imports
import { format } from 'date-fns/format';        // Good: specific import
// import { format } from 'date-fns';             // Bad: imports everything

// 4. Use Astro's built-in Image optimization
import { Image } from 'astro:assets';
```

## Server Islands (Astro 5)

Server islands allow you to defer rendering of specific components to after the initial page response, enabling personalized content within cached pages.

### How Server Islands Work

```
Request Flow:
1. Edge/CDN serves cached static HTML instantly
2. Page displays with fallback content for server islands
3. Server islands fetch their content via separate requests
4. Dynamic content streams in and replaces fallbacks

┌─────────────────────────────────┐
│  Cached Static Page (CDN)       │
│                                 │
│  ┌──────────────────────┐      │
│  │ Static Header         │      │  ← Cached
│  └──────────────────────┘      │
│  ┌──────────────────────┐      │
│  │ server:defer          │      │  ← Fetched separately
│  │ (user-specific data)  │      │     after page load
│  └──────────────────────┘      │
│  ┌──────────────────────┐      │
│  │ Static Content        │      │  ← Cached
│  └──────────────────────┘      │
└─────────────────────────────────┘
```

### Basic Usage

```astro
---
// src/components/UserGreeting.astro
const user = await getUser(Astro.cookies.get('session'));
---

<div>
  <p>Welcome back, {user.name}!</p>
  <p>You have {user.notifications} new notifications.</p>
</div>
```

```astro
---
// src/pages/index.astro
import UserGreeting from '../components/UserGreeting.astro';
import ProductRecommendations from '../components/ProductRecommendations.astro';
---

<html>
  <body>
    <h1>Welcome to our Store</h1>

    <!-- This component renders on the server AFTER the page is sent -->
    <UserGreeting server:defer>
      <!-- Fallback shown while server island loads -->
      <p slot="fallback">Loading your profile...</p>
    </UserGreeting>

    <!-- Another server island -->
    <ProductRecommendations server:defer>
      <div slot="fallback" class="skeleton-grid">
        <!-- Skeleton placeholder -->
      </div>
    </ProductRecommendations>

    <!-- This is static, served from cache -->
    <footer>Static footer content</footer>
  </body>
</html>
```

### Server Islands with Props

```astro
---
// Server islands can receive serializable props
import PricingTable from '../components/PricingTable.astro';
---

<!-- Props are encrypted and sent with the deferred request -->
<PricingTable
  server:defer
  productId="abc123"
  region={Astro.locals.region}
>
  <p slot="fallback">Loading pricing...</p>
</PricingTable>
```

### Caching Strategy with Server Islands

```typescript
// astro.config.mjs
export default defineConfig({
  output: 'server',
  adapter: cloudflare(),
});
```

```astro
---
// src/pages/product/[id].astro
// The page itself can be cached aggressively
Astro.response.headers.set('Cache-Control', 'public, max-age=3600');

import ProductDetails from '../components/ProductDetails.astro';
import UserReviews from '../components/UserReviews.astro';
import AddToCart from '../components/AddToCart.astro';
---

<!-- Static product info (cached) -->
<ProductDetails productId={Astro.params.id} />

<!-- Dynamic, personalized (server island) -->
<AddToCart server:defer productId={Astro.params.id}>
  <button slot="fallback" disabled>Loading...</button>
</AddToCart>

<!-- Dynamic, frequently updated (server island) -->
<UserReviews server:defer productId={Astro.params.id}>
  <p slot="fallback">Loading reviews...</p>
</UserReviews>
```

## Slot Patterns

### Passing Astro Content into Framework Islands

```astro
---
import ReactAccordion from '../components/react/Accordion.tsx';
---

<!-- Astro content becomes children in React -->
<ReactAccordion client:visible title="FAQ">
  <p>This HTML is passed as children to the React component.</p>
  <ul>
    <li>Static content rendered by Astro</li>
    <li>Hydrated by React when visible</li>
  </ul>
</ReactAccordion>
```

```tsx
// React component receiving Astro slot content
interface AccordionProps {
  title: string;
  children: React.ReactNode;  // Astro slot content arrives as children
}

export function Accordion({ title, children }: AccordionProps) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <div>
      <button onClick={() => setIsOpen(!isOpen)}>{title}</button>
      {isOpen && <div>{children}</div>}
    </div>
  );
}
```

### Named Slots with Framework Components

```astro
---
import ReactCard from '../components/react/Card.tsx';
---

<!-- Named slots map to props in React -->
<ReactCard client:idle>
  <h2 slot="header">Card Title</h2>
  <p>Default slot content (becomes children)</p>
  <span slot="footer">Card footer</span>
</ReactCard>
```

```tsx
// React component with named slots
interface CardProps {
  header?: React.ReactNode;
  footer?: React.ReactNode;
  children: React.ReactNode;
}

export function Card({ header, footer, children }: CardProps) {
  return (
    <div className="card">
      {header && <div className="card-header">{header}</div>}
      <div className="card-body">{children}</div>
      {footer && <div className="card-footer">{footer}</div>}
    </div>
  );
}
```

### Nested Islands

```astro
---
import ReactWrapper from '../components/react/Wrapper.tsx';
import SvelteWidget from '../components/svelte/Widget.svelte';
---

<!-- Nested islands hydrate independently -->
<ReactWrapper client:load>
  <!-- This Svelte component hydrates separately from the React wrapper -->
  <SvelteWidget client:visible count={5} />
</ReactWrapper>
```

**Important:** Nested islands are NOT nested in the JavaScript sense. Each island hydrates independently. The React wrapper doesn't "own" the Svelte widget - they just happen to be visually nested in the HTML.

## Advanced Patterns

### Conditional Hydration

```astro
---
import HeavyEditor from '../components/react/Editor.tsx';
const isEditor = Astro.url.searchParams.has('edit');
---

<!-- Only include the island if editing -->
{isEditor ? (
  <HeavyEditor client:load content={content} />
) : (
  <div class="content" set:html={renderedContent} />
)}
```

### Island with Loading State

```tsx
// React island with built-in loading state
import { useState, useEffect } from 'react';

export function DataWidget({ endpoint }: { endpoint: string }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(endpoint)
      .then((r) => r.json())
      .then((d) => { setData(d); setLoading(false); });
  }, [endpoint]);

  if (loading) return <div class="skeleton" />;
  return <div>{/* render data */}</div>;
}
```

### Transition-aware Islands

```tsx
// React island that reinitializes on View Transition navigation
import { useEffect } from 'react';

export function PageTracker() {
  useEffect(() => {
    // This runs on initial hydration AND after View Transition navigations
    const handler = () => {
      console.log('Page changed:', window.location.pathname);
    };

    document.addEventListener('astro:page-load', handler);
    return () => document.removeEventListener('astro:page-load', handler);
  }, []);

  return null;
}
```
