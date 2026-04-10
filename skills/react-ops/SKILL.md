---
name: react-ops
description: "React development patterns, hooks, state management, Server Components, and performance optimization. Use for: react, hooks, useState, useEffect, jsx, tsx, next.js, nextjs, app router, server components, RSC, zustand, react query, component patterns, react testing library, error boundary, suspense, react 19."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: typescript-ops, testing-ops, tailwind-ops, javascript-ops
---

# React Operations

Comprehensive React skill covering hooks, component architecture, state management, Server Components, and performance optimization.

## Hook Selection Decision Tree

```
What problem are you solving?
│
├─ Storing UI state that triggers re-renders
│  ├─ Simple value (string, number, boolean)
│  │  └─ useState
│  ├─ Complex state with multiple sub-values and logic
│  │  └─ useReducer (actions + reducer = predictable transitions)
│  └─ Derived from existing state
│     └─ Calculate inline or useMemo — not useState
│
├─ Referencing a value WITHOUT triggering re-render
│  ├─ DOM element reference
│  │  └─ useRef<HTMLElement>(null) + ref={ref}
│  └─ Mutable value (timer ID, previous value, counter)
│     └─ useRef (mutate ref.current directly)
│
├─ Running a side effect
│  ├─ After every render (or specific deps)
│  │  ├─ Needs cleanup (subscription, timer, abort)
│  │  │  └─ useEffect with return cleanup function
│  │  └─ No cleanup (logging, analytics)
│  │     └─ useEffect with empty or dep array
│  ├─ Before browser paint (DOM mutation, animation)
│  │  └─ useLayoutEffect
│  └─ Triggered by user action (not render)
│     └─ Call it directly in the event handler — not useEffect
│
├─ Caching an expensive computation
│  └─ useMemo(() => expensiveCalc(a, b), [a, b])
│
├─ Stable callback reference for child props / event handlers
│  └─ useCallback(() => doThing(dep), [dep])
│
├─ Reading shared context value
│  └─ useContext(MyContext)
│
├─ Generating stable unique ID (forms, aria)
│  └─ useId()
│
├─ Syncing external store (Redux, Zustand internals)
│  └─ useSyncExternalStore(subscribe, getSnapshot)
│
└─ React 19+
   ├─ Await a promise or read context
   │  └─ use(promise | context)
   ├─ Form submit state (pending, data, action)
   │  └─ useFormStatus / useActionState
   └─ Optimistic UI before server response
      └─ useOptimistic(state, updateFn)
```

## Component Pattern Decision Tree

```
What's your composition challenge?
│
├─ Group of related components sharing implicit state
│  (Tabs, Accordion, Select, Menu)
│  └─ Compound Components with Context
│     Parent provides state via Context
│     Children consume via useContext
│
├─ Consumer needs to control rendering output
│  └─ Render Props: children(props) or render={fn}
│     Good for: headless UI, flexible layouts
│
├─ Apply cross-cutting concerns (auth, logging, theming)
│  to multiple components
│  └─ Higher-Order Components (HOC)
│     Wrap with withAuth(Component) or withLogging(Component)
│     Prefer custom hooks for pure logic
│
├─ Encapsulate reusable stateful logic
│  └─ Custom Hook — always prefer over HOC when possible
│     Composable, testable, no wrapper hell
│
├─ Need imperative control from parent (focus, scroll, reset)
│  └─ forwardRef + useImperativeHandle
│
├─ Render content outside DOM hierarchy (modal, tooltip, toast)
│  └─ Portal: createPortal(content, document.body)
│
├─ Accept arbitrary children/slots without prop drilling
│  └─ Slot pattern via children, or named props (header, footer)
│
└─ Polymorphic rendering (button that renders as <a> or div)
   └─ as prop pattern with TypeScript generics
```

## State Management Decision Tree

```
Where does this state live and who owns it?
│
├─ Only one component needs it
│  └─ useState or useReducer (local state)
│
├─ A few nearby components need it
│  └─ Lift state to nearest common ancestor + prop drilling
│     (2-3 levels is fine)
│
├─ Many components need it, rarely changes
│  (theme, locale, auth user)
│  └─ React Context API
│     Split contexts by update frequency
│     Avoid single giant context
│
├─ Global client state, changes often
│  (shopping cart, UI preferences, navigation)
│  ├─ Simple/small app → Zustand (minimal boilerplate)
│  ├─ Atomic updates, React Suspense integration → Jotai
│  └─ Large team, time-travel debugging, complex logic → Redux Toolkit
│
├─ Server state (remote data, cache, sync)
│  (API data, database queries)
│  └─ TanStack Query (React Query)
│     Handles: caching, background refetch, loading/error
│     Don't use useState + useEffect for server data
│
└─ Form state
   └─ React Hook Form + Zod validation
      (controlled inputs are fine for simple forms)
```

## React 19 Quick Reference

| Feature | API | Purpose |
|---------|-----|---------|
| `use()` hook | `use(promise)` / `use(context)` | Await promises in render, read context conditionally |
| Actions | `async function action(formData)` | Async transitions with built-in pending state |
| `useActionState` | `useActionState(action, initialState)` | Action result + pending state |
| `useFormStatus` | `useFormStatus()` | Pending/data/method inside form |
| `useOptimistic` | `useOptimistic(state, updateFn)` | Optimistic UI before server response |
| React Compiler | Automatic memoization | Replaces most `memo`, `useMemo`, `useCallback` |
| `ref` as prop | `<Input ref={ref}>` | No more forwardRef wrapper needed |
| `<Context>` as provider | `<MyContext value={val}>` | No more `<MyContext.Provider>` |

```tsx
// React 19: use() for data fetching in Server Components
import { use } from 'react';

function UserProfile({ userPromise }: { userPromise: Promise<User> }) {
  const user = use(userPromise); // suspends until resolved
  return <h1>{user.name}</h1>;
}

// React 19: useActionState
import { useActionState } from 'react';

function ContactForm() {
  const [state, action, isPending] = useActionState(
    async (prevState: State, formData: FormData) => {
      const result = await submitContact(formData);
      return result;
    },
    { error: null }
  );

  return (
    <form action={action}>
      <input name="email" type="email" />
      <button disabled={isPending}>
        {isPending ? 'Sending...' : 'Send'}
      </button>
      {state.error && <p>{state.error}</p>}
    </form>
  );
}
```

## Server vs Client Components

```
Does this component need...?
│
├─ useState, useReducer, useContext
│  └─ Client Component ('use client')
│
├─ useEffect, useLayoutEffect
│  └─ Client Component ('use client')
│
├─ Browser APIs (window, document, localStorage)
│  └─ Client Component ('use client')
│
├─ Event handlers (onClick, onChange, onSubmit)
│  └─ Client Component ('use client')
│
├─ Third-party libraries that use hooks/browser APIs
│  └─ Client Component ('use client')
│
├─ Direct database/file system access
│  └─ Server Component (default, no directive)
│
├─ Access to env vars (server-only secrets)
│  └─ Server Component
│
├─ Large dependencies you want to keep off the client bundle
│  └─ Server Component
│
└─ async/await at the top level
   └─ Server Component
```

**Client boundary rules:**
- `'use client'` marks a boundary — everything imported below it becomes client JS
- Server Components can import Client Components (they pass as props/children)
- Client Components CANNOT import Server Components directly
- Pass Server Component output as `children` prop to Client Components
- Server data → Client: pass as serializable props only (no functions, classes, DOM nodes)

## Performance Checklist

| Technique | When to Use | When NOT to Use |
|-----------|-------------|-----------------|
| `React.memo` | Component re-renders often with same props | Nearly everything — adds comparison overhead |
| `useMemo` | Expensive calculation (>1ms), stable dep array | Primitive values, simple expressions |
| `useCallback` | Callback passed to memoized child or in dep array | Inline handlers on DOM elements |
| `React.lazy` + `Suspense` | Large components not needed on initial load | Small components, SSR-critical content |
| `useTransition` | Non-urgent state updates (filtering, sorting) | Time-sensitive UI (typing, hover) |
| `useDeferredValue` | Derived expensive render from fast-changing value | Same as above |
| Virtualization | Lists >100 items | Small lists — overhead not worth it |
| React Compiler (v19) | Automatic — replaces most manual memoization | Opt-out with `"use no memo"` if needed |

## Common Gotchas

| Gotcha | Why It Happens | Fix |
|--------|---------------|-----|
| Stale closure in useEffect | Callback captures old state/prop at definition time | Add value to dep array, or use functional update `setState(prev => ...)` |
| Missing useEffect dependency | Linter disabled or ignored, stale data shown | Never disable exhaustive-deps; use `useCallback` to stabilize functions |
| Index as list key | Keys change on reorder/insert, causing wrong component identity | Use stable unique ID from data (`item.id`) |
| Hydration mismatch | Server HTML doesn't match first client render | Avoid `typeof window`, random values, or dates in render; use `useEffect` for client-only content |
| Unnecessary re-renders from context | All consumers re-render when any context value changes | Split context by concern; memoize context value with `useMemo` |
| useEffect for derived state | State derived from another state causes extra render cycle | Compute derived value during render inline or with `useMemo` |
| Missing cleanup in useEffect | Memory leaks from subscriptions, timers, fetch requests | Always return cleanup function; use AbortController for fetch |
| Strict Mode double invocation | Effects run twice in dev to catch bugs | Design effects to be idempotent; cleanup must fully reverse effect |
| Controlled/uncontrolled switch | `value` prop toggling between defined and `undefined` | Always provide defined value or always use `defaultValue`; never both |
| Object/array in dep array | New reference every render triggers effect repeatedly | Memoize with `useMemo`; use primitive values in deps where possible |
| Async function directly in useEffect | `useEffect(() => async () => {})` returns a Promise, not cleanup | Wrap: `useEffect(() => { async function run() {...}; run(); }, [])` |

## Reference Files

| File | When to Load |
|------|-------------|
| `./references/hooks-patterns.md` | Deep hook usage: custom hooks, React 19 hooks, useEffect patterns, hook composition |
| `./references/component-architecture.md` | Compound components, HOC, render props, portals, forwardRef, polymorphic components |
| `./references/state-management.md` | Context API, Zustand, Jotai, Redux Toolkit, TanStack Query, React Hook Form |
| `./references/server-components.md` | RSC architecture, Server Actions, Next.js App Router, caching, streaming, metadata |
| `./references/performance.md` | React.memo, code splitting, virtualization, React Compiler, Web Vitals, profiling |
| `./references/testing.md` | RTL queries, user-event, MSW, renderHook, Vitest setup, accessibility testing |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `typescript-ops` | TypeScript generics with React props, discriminated unions for state machines, utility types |
| `testing-ops` | Test strategy, mocking patterns, CI integration, snapshot vs behavioral tests |
| `tailwind-ops` | CSS-in-JS alternatives, responsive design with Tailwind in React components |
| `javascript-ops` | Async patterns, Promises, generators, module system fundamentals |
