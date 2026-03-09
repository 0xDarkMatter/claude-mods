# Performance

React performance patterns: memoization, code splitting, virtualization, React Compiler, profiling, and Web Vitals.

---

## Memoization

### React.memo

Skips re-render when props haven't changed (shallow equality by default).

```tsx
import { memo, useCallback, useState } from 'react';

interface ListItemProps {
  item: { id: string; name: string; count: number };
  onDelete: (id: string) => void;
}

// Memoize expensive list items so parent re-renders don't cascade
const ListItem = memo(function ListItem({ item, onDelete }: ListItemProps) {
  console.log(`Rendering ${item.name}`); // only logs when item or onDelete changes
  return (
    <li>
      {item.name} ({item.count})
      <button onClick={() => onDelete(item.id)}>Delete</button>
    </li>
  );
});

// Custom comparison — return true to SKIP re-render
const ExpensiveChart = memo(
  function ExpensiveChart({ data, config }: ChartProps) {
    return <Canvas data={data} config={config} />;
  },
  (prevProps, nextProps) => {
    // Only re-render if data length changes or config changes
    return (
      prevProps.data.length === nextProps.data.length &&
      prevProps.config.type === nextProps.config.type
    );
  }
);

// Parent must stabilize callbacks with useCallback to benefit from memo
function ItemList({ items }: { items: Item[] }) {
  const [filter, setFilter] = useState('');

  // Without useCallback, new function reference every render → memo is useless
  const handleDelete = useCallback((id: string) => {
    deleteItem(id);
  }, []); // stable — no deps

  return (
    <ul>
      {items.map(item => (
        <ListItem key={item.id} item={item} onDelete={handleDelete} />
      ))}
    </ul>
  );
}
```

### When NOT to Use React.memo

```tsx
// BAD: memo on a component that almost always re-renders anyway
const SimpleDiv = memo(({ children }: { children: React.ReactNode }) => (
  <div>{children}</div>
));

// BAD: memo where props contain new objects/arrays every render
function Parent() {
  return (
    // options is a new array every render — memo never skips
    <MemoizedChild options={['a', 'b', 'c']} />
  );
}

// GOOD: only memo when:
// 1. Component renders the same output given the same props
// 2. Re-renders frequently with same props (large lists, heavy computation)
// 3. Props are primitives or stable references
```

### useMemo

```tsx
import { useMemo, useState } from 'react';

function ProductList({ products }: { products: Product[] }) {
  const [sortBy, setSortBy] = useState<'price' | 'name'>('name');
  const [filter, setFilter] = useState('');

  // Expensive: filter + sort on every render without memoization
  const processedProducts = useMemo(() => {
    const filtered = products.filter(p =>
      p.name.toLowerCase().includes(filter.toLowerCase())
    );
    return filtered.sort((a, b) =>
      sortBy === 'price' ? a.price - b.price : a.name.localeCompare(b.name)
    );
  }, [products, filter, sortBy]); // only recalculates when these change

  return (
    <ul>
      {processedProducts.map(p => <ProductCard key={p.id} product={p} />)}
    </ul>
  );
}

// When NOT to use useMemo
function BadUsage() {
  // BAD: simple operations don't need memoization — the overhead costs more
  const doubled = useMemo(() => count * 2, [count]);
  const greeting = useMemo(() => `Hello, ${name}`, [name]);

  // GOOD: compute inline
  const doubled = count * 2;
  const greeting = `Hello, ${name}`;
}
```

### useCallback

```tsx
import { useCallback, useState, memo } from 'react';

// useCallback returns a stable function reference
// Only useful when passed to: memo() components, useEffect dep arrays, other callbacks

function SearchPage() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Result[]>([]);

  // Stable reference: won't cause SearchResults to re-render when SearchPage renders
  const handleResultClick = useCallback((id: string) => {
    trackClick(id); // does not depend on any state
  }, []);

  // Correct deps: includeArchived is used inside the callback
  const [includeArchived, setIncludeArchived] = useState(false);
  const search = useCallback(async (q: string) => {
    const data = await fetchResults(q, { includeArchived });
    setResults(data);
  }, [includeArchived]); // re-created when includeArchived changes

  return (
    <>
      <SearchInput value={query} onChange={setQuery} onSearch={search} />
      <MemoizedResults results={results} onResultClick={handleResultClick} />
    </>
  );
}
```

---

## Code Splitting

### React.lazy + Suspense

```tsx
import { lazy, Suspense, useState } from 'react';

// Dynamic import — loaded only when rendered
const HeavyEditor = lazy(() => import('./HeavyEditor'));
const DataVizChart = lazy(() => import('./DataVizChart'));

// Preload on hover for instant perceived load
function preloadEditor() {
  const promise = import('./HeavyEditor');
  return promise;
}

function Dashboard() {
  const [showEditor, setShowEditor] = useState(false);

  return (
    <div>
      <button
        onClick={() => setShowEditor(true)}
        onMouseEnter={preloadEditor} // start loading before click
      >
        Open Editor
      </button>

      {showEditor && (
        <Suspense fallback={<EditorSkeleton />}>
          <HeavyEditor />
        </Suspense>
      )}

      <Suspense fallback={<ChartSkeleton />}>
        <DataVizChart />
      </Suspense>
    </div>
  );
}
```

### Route-Based Splitting (React Router)

```tsx
import { lazy, Suspense } from 'react';
import { Routes, Route } from 'react-router-dom';

// Each route is its own chunk
const HomePage = lazy(() => import('./pages/Home'));
const DashboardPage = lazy(() => import('./pages/Dashboard'));
const SettingsPage = lazy(() => import('./pages/Settings'));

function App() {
  return (
    <Suspense fallback={<PageLoader />}>
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/dashboard" element={<DashboardPage />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Routes>
    </Suspense>
  );
}
```

---

## Avoiding Re-renders

### State Colocation

```tsx
// BAD: state in parent causes all children to re-render
function Parent() {
  const [inputValue, setInputValue] = useState('');
  return (
    <>
      <input value={inputValue} onChange={e => setInputValue(e.target.value)} />
      <ExpensiveComponent /> {/* re-renders on every keystroke! */}
      <AnotherExpensiveComponent />
    </>
  );
}

// GOOD: colocate state where it's needed
function InputSection() {
  const [inputValue, setInputValue] = useState('');
  return <input value={inputValue} onChange={e => setInputValue(e.target.value)} />;
}

function Parent() {
  return (
    <>
      <InputSection />       {/* only this re-renders */}
      <ExpensiveComponent />  {/* never re-renders */}
      <AnotherExpensiveComponent />
    </>
  );
}
```

### Children Pattern

```tsx
// BAD: wrapping component re-renders on every parent render
function Wrapper() {
  const [count, setCount] = useState(0);
  return (
    <div>
      <button onClick={() => setCount(c => c + 1)}>{count}</button>
      <SlowComponent />  {/* re-renders even though it doesn't use count */}
    </div>
  );
}

// GOOD: pass slow component as children — it's created in parent, not re-rendered
function WrapperWithChildren({ children }: { children: React.ReactNode }) {
  const [count, setCount] = useState(0);
  return (
    <div>
      <button onClick={() => setCount(c => c + 1)}>{count}</button>
      {children} {/* reference is stable, SlowComponent doesn't re-render */}
    </div>
  );
}

function App() {
  return (
    <WrapperWithChildren>
      <SlowComponent />
    </WrapperWithChildren>
  );
}
```

---

## Concurrent Features

### useTransition

```tsx
import { useState, useTransition } from 'react';

function FilterableList({ items }: { items: Item[] }) {
  const [filter, setFilter] = useState('');
  const [filteredItems, setFilteredItems] = useState(items);
  const [isPending, startTransition] = useTransition();

  const handleFilterChange = (value: string) => {
    // Urgent: update input immediately
    setFilter(value);

    // Non-urgent: defer the expensive filtering
    startTransition(() => {
      const filtered = items.filter(item =>
        item.name.toLowerCase().includes(value.toLowerCase())
      );
      setFilteredItems(filtered);
    });
  };

  return (
    <>
      <input
        value={filter}
        onChange={e => handleFilterChange(e.target.value)}
        placeholder="Filter..."
      />
      {/* Show stale content with opacity while pending */}
      <ul style={{ opacity: isPending ? 0.7 : 1 }}>
        {filteredItems.map(item => <li key={item.id}>{item.name}</li>)}
      </ul>
    </>
  );
}
```

### useDeferredValue

```tsx
import { useState, useDeferredValue, memo } from 'react';

// useDeferredValue: defer a value derived from props/state
// Unlike useTransition, works when you don't own the state setter

function SearchResults({ query }: { query: string }) {
  // Defer the slow part — input stays responsive
  const deferredQuery = useDeferredValue(query);

  return (
    <div style={{ opacity: query !== deferredQuery ? 0.7 : 1 }}>
      <SlowResultsList query={deferredQuery} />
    </div>
  );
}

// Must be memoized for useDeferredValue to have effect
const SlowResultsList = memo(function SlowResultsList({ query }: { query: string }) {
  // Expensive rendering — now deferred
  const results = heavySearch(query);
  return results.map(r => <Result key={r.id} result={r} />);
});
```

---

## Virtualization

For lists with more than 100 items, only render what's visible.

```tsx
import { useVirtualizer } from '@tanstack/react-virtual';
import { useRef } from 'react';

function VirtualList({ items }: { items: Item[] }) {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 60, // estimated row height in px
    overscan: 5,            // render 5 extra items outside viewport
  });

  return (
    // Scrollable container — must have a fixed height
    <div ref={parentRef} style={{ height: 600, overflow: 'auto' }}>
      {/* Total height spacer so scrollbar is sized correctly */}
      <div style={{ height: virtualizer.getTotalSize(), position: 'relative' }}>
        {virtualizer.getVirtualItems().map(virtualItem => (
          <div
            key={virtualItem.key}
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              width: '100%',
              height: `${virtualItem.size}px`,
              transform: `translateY(${virtualItem.start}px)`,
            }}
          >
            <ListItem item={items[virtualItem.index]} />
          </div>
        ))}
      </div>
    </div>
  );
}

// Grid virtualizer
function VirtualGrid({ items, columnCount = 3 }: { items: Item[]; columnCount?: number }) {
  const parentRef = useRef<HTMLDivElement>(null);
  const rowCount = Math.ceil(items.length / columnCount);

  const rowVirtualizer = useVirtualizer({
    count: rowCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 200,
  });

  const columnVirtualizer = useVirtualizer({
    horizontal: true,
    count: columnCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 300,
  });

  return (
    <div ref={parentRef} style={{ height: 600, overflow: 'auto' }}>
      <div
        style={{
          height: rowVirtualizer.getTotalSize(),
          width: columnVirtualizer.getTotalSize(),
          position: 'relative',
        }}
      >
        {rowVirtualizer.getVirtualItems().map(row =>
          columnVirtualizer.getVirtualItems().map(col => {
            const index = row.index * columnCount + col.index;
            if (index >= items.length) return null;
            return (
              <div
                key={`${row.key}-${col.key}`}
                style={{
                  position: 'absolute',
                  top: row.start,
                  left: col.start,
                  width: col.size,
                  height: row.size,
                }}
              >
                <GridItem item={items[index]} />
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
```

---

## React Compiler (React 19)

The React Compiler automatically applies memoization — most manual `memo`, `useMemo`, and `useCallback` calls become unnecessary.

```tsx
// Before React Compiler — manual memoization
const ExpensiveList = memo(function ExpensiveList({ items, onDelete }: Props) {
  const sorted = useMemo(() => [...items].sort((a, b) => a.name.localeCompare(b.name)), [items]);
  const handleDelete = useCallback((id: string) => onDelete(id), [onDelete]);
  return sorted.map(item => <Item key={item.id} item={item} onDelete={handleDelete} />);
});

// After React Compiler — compiler adds memoization automatically
function ExpensiveList({ items, onDelete }: Props) {
  const sorted = [...items].sort((a, b) => a.name.localeCompare(b.name));
  return sorted.map(item => <Item key={item.id} item={item} onDelete={onDelete} />);
}

// Opt out specific components if compiler breaks them
function ProblematicComponent() {
  "use no memo";
  // ... compiler skips this component
}
```

### Enabling React Compiler (Next.js)

```javascript
// next.config.js
const nextConfig = {
  experimental: {
    reactCompiler: true,
  },
};

// babel.config.js (for non-Next.js setups)
module.exports = {
  plugins: [['babel-plugin-react-compiler', {}]],
};
```

---

## Bundle Analysis

```bash
# Next.js bundle analyzer
npm install @next/bundle-analyzer

# next.config.js
const withBundleAnalyzer = require('@next/bundle-analyzer')({
  enabled: process.env.ANALYZE === 'true',
});
module.exports = withBundleAnalyzer({});

# Run
ANALYZE=true npm run build
```

```bash
# source-map-explorer (framework-agnostic)
npm install --save-dev source-map-explorer
npx source-map-explorer 'build/static/js/*.js'
```

---

## React DevTools Profiler

```tsx
// Mark component interactions for DevTools
import { Profiler } from 'react';

function onRenderCallback(
  id: string,          // component tree id
  phase: 'mount' | 'update',
  actualDuration: number,  // time spent rendering
  baseDuration: number,    // estimated full render time
  startTime: number,
  commitTime: number
) {
  if (actualDuration > 16) { // flag renders > 1 frame (16ms)
    console.warn(`Slow render: ${id} took ${actualDuration.toFixed(2)}ms`);
  }
}

function App() {
  return (
    <Profiler id="Dashboard" onRender={onRenderCallback}>
      <Dashboard />
    </Profiler>
  );
}
```

---

## Web Vitals

| Metric | Meaning | React Impact | Target |
|--------|---------|-------------|--------|
| LCP (Largest Contentful Paint) | When main content loads | Large component trees, unoptimized images | < 2.5s |
| FID / INP (Interaction to Next Paint) | Response time to user input | Long tasks blocking main thread | < 200ms |
| CLS (Cumulative Layout Shift) | Visual stability | Dynamic content without reserved space | < 0.1 |
| TTFB (Time to First Byte) | Server response time | RSC data fetching efficiency | < 800ms |

```tsx
// Measure Web Vitals in Next.js
// app/layout.tsx
export function reportWebVitals(metric: NextWebVitalsMetric) {
  if (metric.label === 'web-vital') {
    // Send to analytics
    analytics.track('web_vital', {
      name: metric.name,
      value: metric.value,
      rating: metric.rating, // 'good' | 'needs-improvement' | 'poor'
    });
  }
}

// Avoiding CLS: always reserve space for dynamic content
function Avatar({ src }: { src: string }) {
  return (
    // Fixed dimensions prevent layout shift when image loads
    <div style={{ width: 40, height: 40 }}>
      <img src={src} width={40} height={40} alt="" />
    </div>
  );
}
```

---

## Image Optimization

```tsx
import Image from 'next/image';

// Optimized image with automatic WebP conversion, lazy loading, CLS prevention
function ProductImage({ product }: { product: Product }) {
  return (
    <div style={{ position: 'relative', aspectRatio: '16/9' }}>
      <Image
        src={product.imageUrl}
        alt={product.name}
        fill                    // fills parent container
        sizes="(max-width: 768px) 100vw, 50vw"  // responsive sizes hint
        priority={false}        // true for above-fold LCP images
        placeholder="blur"      // or "empty"
        blurDataURL={product.blurDataUrl}
      />
    </div>
  );
}

// LCP image — must be priority
function HeroImage() {
  return (
    <Image
      src="/hero.jpg"
      alt="Hero"
      width={1200}
      height={600}
      priority          // preload this image — no lazy loading
    />
  );
}
```

---

## Performance Anti-patterns

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| `memo` on everything | Comparison overhead, false optimization | Profile first; only memo when re-renders are measured problem |
| `useMemo` for cheap computations | Overhead of memoization > cost of computation | Only memoize if computation takes >1ms |
| `useCallback` without memoized consumers | Stable reference with no benefit | Only use when callback is dep in `useEffect` or passed to `memo` component |
| No `key` strategy for lists | React unmounts/remounts on reorder | Stable unique IDs from data |
| Inline object/array props on `memo` components | New reference every render defeats memo | `useMemo` the value or move outside component |
| Not virtualizing long lists | Renders thousands of DOM nodes | Use `@tanstack/react-virtual` for 100+ items |
| All JS in single bundle | Slow initial load | Route-based code splitting with `lazy` |
| `useEffect` polling instead of WebSocket/SSE | Constant network requests | Switch to real-time transport |
| Importing full lodash/moment | Huge bundle impact | Use tree-shakeable alternatives or native APIs |
