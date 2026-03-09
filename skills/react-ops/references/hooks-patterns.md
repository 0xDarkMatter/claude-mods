# Hooks Patterns

Deep reference for React hooks — built-in hooks, custom hook recipes, React 19 hooks, and composition patterns.

---

## useState

### Initializer Function (Lazy Initial State)

When initial state is expensive to compute, pass a function — it runs only once.

```typescript
import { useState } from 'react';

// BAD: parseExpensiveData runs on every render
const [data, setData] = useState(parseExpensiveData(rawInput));

// GOOD: runs once at mount
const [data, setData] = useState(() => parseExpensiveData(rawInput));

// GOOD: reading from localStorage (sync, only once)
const [theme, setTheme] = useState<'light' | 'dark'>(
  () => (localStorage.getItem('theme') as 'light' | 'dark') ?? 'light'
);
```

### Functional Updates

When new state depends on previous state, always use the functional form to avoid stale closures.

```typescript
function Counter() {
  const [count, setCount] = useState(0);

  // BAD: if called rapidly, `count` might be stale
  const increment = () => setCount(count + 1);

  // GOOD: always receives the latest state
  const increment = () => setCount(prev => prev + 1);

  // GOOD: batch multiple updates
  const incrementBy3 = () => {
    setCount(prev => prev + 1);
    setCount(prev => prev + 1);
    setCount(prev => prev + 1);
  };

  return <button onClick={increment}>{count}</button>;
}
```

### Object State

```typescript
interface FormState {
  name: string;
  email: string;
  age: number;
}

function ProfileForm() {
  const [form, setForm] = useState<FormState>({
    name: '',
    email: '',
    age: 0,
  });

  // Partial update pattern — spread to preserve other fields
  const updateField = <K extends keyof FormState>(
    key: K,
    value: FormState[K]
  ) => setForm(prev => ({ ...prev, [key]: value }));

  return (
    <input
      value={form.name}
      onChange={e => updateField('name', e.target.value)}
    />
  );
}
```

---

## useReducer

Use when state transitions are complex, involve multiple sub-values, or next state depends on previous in non-trivial ways.

```typescript
import { useReducer } from 'react';

// 1. Define state shape
interface CartState {
  items: CartItem[];
  total: number;
  isCheckingOut: boolean;
}

// 2. Define discriminated union of actions
type CartAction =
  | { type: 'ADD_ITEM'; payload: CartItem }
  | { type: 'REMOVE_ITEM'; payload: { id: string } }
  | { type: 'CLEAR_CART' }
  | { type: 'SET_CHECKOUT'; payload: boolean };

// 3. Reducer — pure function, no side effects
function cartReducer(state: CartState, action: CartAction): CartState {
  switch (action.type) {
    case 'ADD_ITEM':
      return {
        ...state,
        items: [...state.items, action.payload],
        total: state.total + action.payload.price,
      };
    case 'REMOVE_ITEM': {
      const removed = state.items.find(i => i.id === action.payload.id);
      return {
        ...state,
        items: state.items.filter(i => i.id !== action.payload.id),
        total: state.total - (removed?.price ?? 0),
      };
    }
    case 'CLEAR_CART':
      return { items: [], total: 0, isCheckingOut: false };
    case 'SET_CHECKOUT':
      return { ...state, isCheckingOut: action.payload };
    default:
      // TypeScript exhaustiveness check
      action satisfies never;
      return state;
  }
}

const initialState: CartState = { items: [], total: 0, isCheckingOut: false };

function Cart() {
  const [state, dispatch] = useReducer(cartReducer, initialState);

  return (
    <div>
      <p>Items: {state.items.length}</p>
      <p>Total: ${state.total}</p>
      <button onClick={() => dispatch({ type: 'CLEAR_CART' })}>Clear</button>
    </div>
  );
}
```

---

## useRef

### DOM Access

```typescript
import { useRef, useEffect } from 'react';

function AutoFocusInput() {
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    // ref.current is the DOM node after mount
    inputRef.current?.focus();
  }, []);

  return <input ref={inputRef} placeholder="Auto-focused" />;
}
```

### Mutable Value (No Re-render)

```typescript
function Stopwatch() {
  const [elapsed, setElapsed] = useState(0);
  // Store timer ID without triggering re-renders
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const start = () => {
    if (intervalRef.current !== null) return;
    intervalRef.current = setInterval(() => {
      setElapsed(prev => prev + 1);
    }, 1000);
  };

  const stop = () => {
    if (intervalRef.current === null) return;
    clearInterval(intervalRef.current);
    intervalRef.current = null;
  };

  // Clean up on unmount
  useEffect(() => () => stop(), []);

  return (
    <div>
      <p>{elapsed}s</p>
      <button onClick={start}>Start</button>
      <button onClick={stop}>Stop</button>
    </div>
  );
}
```

---

## useEffect

### Cleanup Pattern

Every subscription, timer, or fetch should have a cleanup.

```typescript
import { useEffect, useState } from 'react';

// Pattern: subscription with cleanup
function useWindowSize() {
  const [size, setSize] = useState({
    width: window.innerWidth,
    height: window.innerHeight,
  });

  useEffect(() => {
    const handler = () => {
      setSize({ width: window.innerWidth, height: window.innerHeight });
    };

    window.addEventListener('resize', handler);

    // Cleanup removes listener — runs before next effect and on unmount
    return () => window.removeEventListener('resize', handler);
  }, []); // empty array = run once at mount

  return size;
}
```

### Async in useEffect

```typescript
useEffect(() => {
  // WRONG: async function returns Promise, not cleanup
  // useEffect(async () => { ... }, []);

  // CORRECT: define async function, call it immediately
  const controller = new AbortController();

  async function fetchData() {
    try {
      const res = await fetch(`/api/users/${userId}`, {
        signal: controller.signal,
      });
      const data = await res.json();
      setUser(data);
    } catch (err) {
      if (err instanceof Error && err.name !== 'AbortError') {
        setError(err);
      }
    }
  }

  fetchData();

  // Abort in-flight request if userId changes or component unmounts
  return () => controller.abort();
}, [userId]);
```

### useLayoutEffect vs useEffect

```typescript
import { useLayoutEffect, useEffect, useRef } from 'react';

// useLayoutEffect: fires synchronously AFTER DOM mutations, BEFORE paint
// Use for: measuring DOM, preventing visual flicker
function Tooltip({ anchorRef }: { anchorRef: React.RefObject<HTMLElement> }) {
  const tooltipRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    // Measure anchor position and position tooltip BEFORE browser paints
    const anchor = anchorRef.current;
    const tooltip = tooltipRef.current;
    if (!anchor || !tooltip) return;

    const rect = anchor.getBoundingClientRect();
    tooltip.style.top = `${rect.bottom + 8}px`;
    tooltip.style.left = `${rect.left}px`;
  });

  return <div ref={tooltipRef} className="tooltip">Tooltip</div>;
}

// useEffect: fires asynchronously AFTER paint
// Use for: data fetching, subscriptions, analytics — anything that doesn't
// need to block the browser paint
```

---

## Custom Hooks

### useFetch with AbortController

```typescript
import { useState, useEffect, useCallback } from 'react';

interface FetchState<T> {
  data: T | null;
  error: Error | null;
  isLoading: boolean;
}

function useFetch<T>(url: string) {
  const [state, setState] = useState<FetchState<T>>({
    data: null,
    error: null,
    isLoading: true,
  });

  const refetch = useCallback(() => {
    const controller = new AbortController();
    setState(prev => ({ ...prev, isLoading: true, error: null }));

    fetch(url, { signal: controller.signal })
      .then(res => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json() as Promise<T>;
      })
      .then(data => setState({ data, error: null, isLoading: false }))
      .catch(err => {
        if (err.name !== 'AbortError') {
          setState({ data: null, error: err, isLoading: false });
        }
      });

    return () => controller.abort();
  }, [url]);

  useEffect(() => {
    const cleanup = refetch();
    return cleanup;
  }, [refetch]);

  return { ...state, refetch };
}

// Usage
function UserProfile({ id }: { id: string }) {
  const { data, error, isLoading, refetch } = useFetch<User>(`/api/users/${id}`);

  if (isLoading) return <Spinner />;
  if (error) return <Error message={error.message} onRetry={refetch} />;
  return <div>{data?.name}</div>;
}
```

### useLocalStorage (SSR-safe)

```typescript
import { useState, useEffect, useCallback } from 'react';

function useLocalStorage<T>(key: string, initialValue: T) {
  // Read from localStorage with SSR safety
  const readValue = useCallback((): T => {
    if (typeof window === 'undefined') return initialValue;
    try {
      const item = window.localStorage.getItem(key);
      return item ? (JSON.parse(item) as T) : initialValue;
    } catch {
      console.warn(`Error reading localStorage key "${key}"`);
      return initialValue;
    }
  }, [key, initialValue]);

  const [storedValue, setStoredValue] = useState<T>(readValue);

  const setValue = useCallback(
    (value: T | ((val: T) => T)) => {
      try {
        const valueToStore =
          value instanceof Function ? value(storedValue) : value;
        setStoredValue(valueToStore);
        if (typeof window !== 'undefined') {
          window.localStorage.setItem(key, JSON.stringify(valueToStore));
        }
      } catch {
        console.warn(`Error setting localStorage key "${key}"`);
      }
    },
    [key, storedValue]
  );

  // Sync across tabs
  useEffect(() => {
    const handleStorageChange = (event: StorageEvent) => {
      if (event.key === key) {
        setStoredValue(readValue());
      }
    };
    window.addEventListener('storage', handleStorageChange);
    return () => window.removeEventListener('storage', handleStorageChange);
  }, [key, readValue]);

  return [storedValue, setValue] as const;
}
```

### useDebounce

```typescript
import { useState, useEffect } from 'react';

function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState<T>(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debouncedValue;
}

// Usage: debounce search input before firing API call
function SearchBar() {
  const [query, setQuery] = useState('');
  const debouncedQuery = useDebounce(query, 300);

  useEffect(() => {
    if (debouncedQuery) {
      searchApi(debouncedQuery);
    }
  }, [debouncedQuery]);

  return (
    <input
      value={query}
      onChange={e => setQuery(e.target.value)}
      placeholder="Search..."
    />
  );
}
```

### useMediaQuery

```typescript
import { useState, useEffect } from 'react';

function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState<boolean>(() => {
    if (typeof window === 'undefined') return false;
    return window.matchMedia(query).matches;
  });

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const mql = window.matchMedia(query);
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches);

    // Use addEventListener (deprecated addListener removed in modern browsers)
    mql.addEventListener('change', handler);
    return () => mql.removeEventListener('change', handler);
  }, [query]);

  return matches;
}

// Predefined breakpoints matching Tailwind defaults
export const useIsTablet = () => useMediaQuery('(min-width: 768px)');
export const useIsDesktop = () => useMediaQuery('(min-width: 1024px)');
export const usePrefersDark = () => useMediaQuery('(prefers-color-scheme: dark)');
export const usePrefersReducedMotion = () =>
  useMediaQuery('(prefers-reduced-motion: reduce)');
```

### useIntersectionObserver

```typescript
import { useEffect, useRef, useState } from 'react';

interface UseIntersectionOptions extends IntersectionObserverInit {
  freezeOnceVisible?: boolean;
}

function useIntersectionObserver(options: UseIntersectionOptions = {}) {
  const { threshold = 0, root = null, rootMargin = '0%', freezeOnceVisible = false } = options;
  const elementRef = useRef<HTMLElement>(null);
  const [entry, setEntry] = useState<IntersectionObserverEntry | null>(null);

  const frozen = entry?.isIntersecting && freezeOnceVisible;

  useEffect(() => {
    const element = elementRef.current;
    if (!element || frozen) return;

    const observer = new IntersectionObserver(
      ([entry]) => setEntry(entry),
      { threshold, root, rootMargin }
    );

    observer.observe(element);
    return () => observer.disconnect();
  }, [threshold, root, rootMargin, frozen]);

  return { ref: elementRef, entry, isIntersecting: !!entry?.isIntersecting };
}

// Usage: lazy load images
function LazyImage({ src, alt }: { src: string; alt: string }) {
  const { ref, isIntersecting } = useIntersectionObserver({
    threshold: 0.1,
    freezeOnceVisible: true,
  });

  return (
    <div ref={ref as React.RefObject<HTMLDivElement>} style={{ minHeight: 200 }}>
      {isIntersecting && <img src={src} alt={alt} loading="lazy" />}
    </div>
  );
}
```

### usePrevious

```typescript
import { useRef, useEffect } from 'react';

function usePrevious<T>(value: T): T | undefined {
  const ref = useRef<T | undefined>(undefined);

  // Runs after render — ref holds value from previous render
  useEffect(() => {
    ref.current = value;
  }, [value]);

  // Returns value from before this render
  return ref.current;
}

// Usage: animate on value change
function AnimatedCounter({ count }: { count: number }) {
  const prevCount = usePrevious(count);
  const direction = prevCount !== undefined && count > prevCount ? 'up' : 'down';

  return (
    <span className={`animate-${direction}`}>
      {count}
    </span>
  );
}
```

### useEventListener

```typescript
import { useEffect, useRef } from 'react';

function useEventListener<K extends keyof WindowEventMap>(
  eventType: K,
  handler: (event: WindowEventMap[K]) => void,
  element: EventTarget = window
): void {
  // Use ref so handler changes don't cause re-subscription
  const handlerRef = useRef(handler);
  useEffect(() => { handlerRef.current = handler; });

  useEffect(() => {
    const listener = (event: Event) =>
      handlerRef.current(event as WindowEventMap[K]);
    element.addEventListener(eventType, listener);
    return () => element.removeEventListener(eventType, listener);
  }, [eventType, element]);
}

// Usage
function KeyboardShortcut() {
  useEventListener('keydown', event => {
    if (event.key === 'Escape') closeModal();
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') openSearch();
  });
}
```

---

## Hook Composition

Build complex hooks by composing simpler ones. Each hook should do one thing well.

```typescript
// Compose useFetch + useDebounce for a search hook
function useSearch<T>(endpoint: string) {
  const [query, setQuery] = useState('');
  const debouncedQuery = useDebounce(query, 300);

  // Only fetch when query is non-empty
  const url = debouncedQuery ? `${endpoint}?q=${encodeURIComponent(debouncedQuery)}` : null;
  const { data, isLoading, error } = useFetch<T[]>(url ?? '');

  return {
    query,
    setQuery,
    results: data ?? [],
    isLoading: isLoading && !!debouncedQuery,
    error,
  };
}

// Compose local storage + media query for responsive theme
function useTheme() {
  const prefersDark = useMediaQuery('(prefers-color-scheme: dark)');
  const [savedTheme, setSavedTheme] = useLocalStorage<'light' | 'dark' | 'system'>(
    'theme',
    'system'
  );

  const resolvedTheme: 'light' | 'dark' =
    savedTheme === 'system' ? (prefersDark ? 'dark' : 'light') : savedTheme;

  return { theme: resolvedTheme, savedTheme, setTheme: setSavedTheme };
}
```

---

## Rules of Hooks

Only call hooks at the top level of a React function component or another custom hook. Never inside conditions, loops, or nested functions.

```typescript
// VIOLATION: conditional hook call
function BadComponent({ isLoggedIn }: { isLoggedIn: boolean }) {
  if (isLoggedIn) {
    const user = useUser(); // ERROR: conditional
  }
}

// FIX: always call hooks, conditionally use their values
function GoodComponent({ isLoggedIn }: { isLoggedIn: boolean }) {
  const user = useUser();
  if (!isLoggedIn) return null;
  return <div>{user.name}</div>;
}

// VIOLATION: hook in a loop
function BadList({ ids }: { ids: string[] }) {
  return ids.map(id => {
    const data = useFetch(`/api/${id}`); // ERROR: in loop
    return <Item key={id} data={data} />;
  });
}

// FIX: move hook logic into a child component
function GoodList({ ids }: { ids: string[] }) {
  return ids.map(id => <ListItem key={id} id={id} />);
}

function ListItem({ id }: { id: string }) {
  const data = useFetch(`/api/${id}`); // CORRECT: top level
  return <Item data={data} />;
}
```

---

## React 19 Hooks

### use() — Promises and Context

```typescript
import { use, Suspense } from 'react';

// Await a promise directly in render (must be wrapped in Suspense)
async function fetchUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  return res.json();
}

function UserCard({ userPromise }: { userPromise: Promise<User> }) {
  // Suspends until promise resolves; throws on rejection (ErrorBoundary handles it)
  const user = use(userPromise);
  return <div>{user.name}</div>;
}

function Page({ id }: { id: string }) {
  const userPromise = fetchUser(id); // start fetch, pass promise down

  return (
    <Suspense fallback={<Skeleton />}>
      <UserCard userPromise={userPromise} />
    </Suspense>
  );
}

// use() can also read context conditionally (unlike useContext)
function ConditionalTheme({ showLabel }: { showLabel: boolean }) {
  if (!showLabel) return null;
  const theme = use(ThemeContext); // conditional — allowed with use()
  return <span style={{ color: theme.primary }}>Label</span>;
}
```

### useFormStatus

```typescript
import { useFormStatus } from 'react-dom';

// Must be used inside a <form> with an action
function SubmitButton() {
  const { pending, data, method } = useFormStatus();
  return (
    <button type="submit" disabled={pending}>
      {pending ? 'Saving...' : 'Save'}
    </button>
  );
}

function ProfileForm() {
  return (
    <form action={updateProfileAction}>
      <input name="bio" />
      <SubmitButton /> {/* useFormStatus works here */}
    </form>
  );
}
```

### useOptimistic

```typescript
import { useOptimistic, useTransition } from 'react';

interface Message {
  id: string;
  text: string;
  sending?: boolean;
}

function MessageList({ messages }: { messages: Message[] }) {
  const [optimisticMessages, addOptimisticMessage] = useOptimistic(
    messages,
    // Reducer: how to merge optimistic update into current state
    (currentMessages, newMessage: Message) => [
      ...currentMessages,
      { ...newMessage, sending: true },
    ]
  );

  async function sendMessage(formData: FormData) {
    const text = formData.get('text') as string;
    const tempMessage = { id: crypto.randomUUID(), text };

    // Update UI immediately
    addOptimisticMessage(tempMessage);

    // Send to server (optimistic update reverts on error)
    await saveMessage(text);
  }

  return (
    <>
      {optimisticMessages.map(msg => (
        <div key={msg.id} style={{ opacity: msg.sending ? 0.5 : 1 }}>
          {msg.text}
        </div>
      ))}
      <form action={sendMessage}>
        <input name="text" />
        <button type="submit">Send</button>
      </form>
    </>
  );
}
```

---

## Anti-patterns

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| `useEffect` with no dep array syncing props to state | Runs every render | Compute derived value during render |
| Calling hooks from event handlers | Violates rules of hooks | Move hook to component top level |
| `useState` for server data | Manual loading/error state, stale data | Use TanStack Query |
| Large single `useEffect` doing multiple things | Hard to reason about, wrong deps | Split into separate `useEffect` calls per concern |
| `useCallback` on everything | Adds overhead, no benefit without memoized children | Only when callback is a dep or passed to `memo` component |
| Forgetting cleanup | Memory leaks, stale updates on unmounted component | Always return cleanup from `useEffect` |
