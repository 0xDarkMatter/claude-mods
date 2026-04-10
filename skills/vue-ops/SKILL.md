---
name: vue-ops
description: "Vue 3 development patterns, Composition API, Pinia state management, Vue Router, and Nuxt 3. Use for: vue, vuejs, composition api, pinia, vue router, nuxt, nuxt3, script setup, composable, reactive, defineProps, defineEmits, defineModel, v-model, provide inject, vue3."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: typescript-ops, testing-ops, tailwind-ops, javascript-ops
---

# Vue Operations

Comprehensive Vue 3 reference covering Composition API, Pinia, Vue Router, Nuxt 3, and testing — production patterns with TypeScript throughout.

---

## Reactivity Decision Tree

```
What data do I need to make reactive?
│
├─ A single primitive (string, number, boolean)?
│   └─ ref()
│       const count = ref(0)
│       const name = ref('')
│
├─ A plain object or array with deep reactivity?
│   ├─ Will I destructure it or pass properties individually?
│   │   └─ reactive() — but use toRefs() when destructuring
│   └─ Will I replace the whole object at once?
│       └─ ref() — ref.value = newObject
│
├─ Derived/computed state from other reactive sources?
│   └─ computed()
│       const doubled = computed(() => count.value * 2)
│
├─ A large object where only top-level keys change?
│   └─ shallowRef() or shallowReactive()
│       const state = shallowRef({ nested: { big: 'data' } })
│
├─ Side effects that should run when dependencies change?
│   ├─ Don't need to know old value, auto-tracks dependencies?
│   │   └─ watchEffect(() => { ... })
│   └─ Need old/new values, explicit sources, or lazy execution?
│       └─ watch(source, (newVal, oldVal) => { ... })
│
└─ Data that should NOT be reactive (raw DOM, third-party instances)?
    └─ markRaw(obj) or shallowRef(obj)
```

---

## Component Communication Decision Tree

```
How far does data need to travel?
│
├─ Parent → direct child?
│   └─ props (defineProps)
│       Direct, explicit, type-safe
│
├─ Child → parent (user action / data update)?
│   └─ emit (defineEmits)
│       defineEmits<{ change: [value: string] }>()
│
├─ Parent ↔ child bidirectional binding?
│   └─ v-model via defineModel() (Vue 3.4+)
│       const model = defineModel<string>()
│
├─ Ancestor → deep descendant (prop drilling problem)?
│   └─ provide / inject
│       Use InjectionKey<T> for type safety
│
├─ Siblings or unrelated components?
│   ├─ Simple/few shared values?
│   │   └─ provide / inject from a common ancestor
│   └─ Complex shared state or cross-tree communication?
│       └─ Pinia store
│
├─ Truly global state (user session, cart, preferences)?
│   └─ Pinia store
│       defineStore with setup syntax
│
└─ One-time events between distant components (rare)?
    └─ Pinia action + watch, or mitt event bus
        Avoid: Vue removed $emit on root in Vue 3
```

---

## Composition API Quick Reference

### `<script setup>` — the standard

```vue
<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'

// Props — with TypeScript generics (no runtime declaration needed)
const props = defineProps<{
  title: string
  count?: number
}>()

// Props with defaults
const props = withDefaults(defineProps<{
  size: 'sm' | 'md' | 'lg'
  disabled?: boolean
}>(), {
  size: 'md',
  disabled: false,
})

// Emits — type-safe event signatures
const emit = defineEmits<{
  change: [value: string]        // named tuple syntax (Vue 3.3+)
  update: [id: number, data: object]
  close: []
}>()

// Reactive state
const count = ref(0)
const user = reactive({ name: '', email: '' })

// Computed
const doubled = computed(() => count.value * 2)

// Watch
watch(count, (newVal, oldVal) => {
  console.log(`count changed from ${oldVal} to ${newVal}`)
})

// Lifecycle
onMounted(() => {
  console.log('component mounted')
})
</script>
```

### `defineModel` — v-model binding (Vue 3.4+)

```vue
<!-- Child component: MyInput.vue -->
<script setup lang="ts">
const model = defineModel<string>({ required: true })

// Named v-model: <MyInput v-model:title="..." />
const title = defineModel<string>('title')

// With modifiers
const [modelValue, modifiers] = defineModel<string, 'trim' | 'uppercase'>()
</script>

<template>
  <input :value="model" @input="model = $event.target.value" />
</template>
```

### `defineExpose` — expose to parent refs

```vue
<script setup lang="ts">
const inputRef = ref<HTMLInputElement | null>(null)

function focus() {
  inputRef.value?.focus()
}

// Expose public API for parent template refs
defineExpose({ focus })
</script>
```

### `defineOptions` — component meta (Vue 3.3+)

```vue
<script setup lang="ts">
defineOptions({
  name: 'MyComponent',
  inheritAttrs: false,
})
</script>
```

### `defineSlots` — type slots (Vue 3.3+)

```vue
<script setup lang="ts">
defineSlots<{
  default(props: { item: User }): any
  header(props: {}): any
}>()
</script>
```

---

## Pinia Quick Start

### Setup syntax (recommended — composable style)

```ts
// stores/counter.ts
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

export const useCounterStore = defineStore('counter', () => {
  // state
  const count = ref(0)
  const name = ref('Counter')

  // getters
  const doubled = computed(() => count.value * 2)

  // actions
  function increment() {
    count.value++
  }

  async function fetchData() {
    const data = await api.get('/data')
    count.value = data.total
  }

  return { count, name, doubled, increment, fetchData }
})
```

### Options syntax

```ts
export const useCounterStore = defineStore('counter', {
  state: () => ({ count: 0 }),
  getters: {
    doubled: (state) => state.count * 2,
  },
  actions: {
    increment() { this.count++ },
  },
})
```

### Using stores in components

```vue
<script setup lang="ts">
import { storeToRefs } from 'pinia'
import { useCounterStore } from '@/stores/counter'

const store = useCounterStore()

// storeToRefs preserves reactivity when destructuring state/getters
// Actions can be destructured directly (they're not reactive)
const { count, doubled } = storeToRefs(store)
const { increment } = store
</script>
```

### Pinia plugins — persistence example

```ts
// main.ts
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

// In store:
export const useAuthStore = defineStore('auth', () => { ... }, {
  persist: true, // or { storage: sessionStorage, paths: ['token'] }
})
```

---

## Vue Router Quick Reference

### Basic configuration

```ts
// router/index.ts
import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: () => import('@/views/HomeView.vue'), // lazy load
    },
    {
      path: '/users/:id',
      name: 'user',
      component: () => import('@/views/UserView.vue'),
      props: true,                    // passes :id as prop
      meta: { requiresAuth: true },
    },
    {
      path: '/admin',
      component: () => import('@/layouts/AdminLayout.vue'),
      children: [
        { path: '', component: () => import('@/views/admin/Dashboard.vue') },
        { path: 'users', component: () => import('@/views/admin/Users.vue') },
      ],
    },
    { path: '/:pathMatch(.*)*', name: 'not-found', component: NotFound },
  ],
  scrollBehavior(to, from, savedPosition) {
    if (savedPosition) return savedPosition
    if (to.hash) return { el: to.hash, behavior: 'smooth' }
    return { top: 0 }
  },
})

export default router
```

### Navigation guards

```ts
// Global guard — auth check
router.beforeEach((to, from) => {
  const auth = useAuthStore()
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
})

// Per-route guard
{
  path: '/admin',
  beforeEnter: (to, from) => {
    if (!isAdmin()) return { name: 'forbidden' }
  },
}
```

```vue
<!-- In-component guard -->
<script setup lang="ts">
import { onBeforeRouteLeave, onBeforeRouteUpdate } from 'vue-router'

onBeforeRouteLeave((to, from) => {
  if (hasUnsavedChanges.value) {
    return confirm('Leave without saving?')
  }
})
</script>
```

### TypeScript meta typing

```ts
// router/index.ts — augment RouteMeta
declare module 'vue-router' {
  interface RouteMeta {
    requiresAuth?: boolean
    title?: string
    breadcrumb?: string
  }
}
```

---

## Nuxt 3 Decision Tree

```
What rendering strategy does my app need?
│
├─ Public content (blogs, marketing, docs)?
│   ├─ Content rarely changes (< daily)?
│   │   └─ SSG — prerender: { routes: ['/', '/about'] }
│   └─ Content updated frequently?
│       └─ ISR — routeRules: { '/blog/**': { isr: 3600 } }
│
├─ Dynamic per-user content (dashboards, apps)?
│   └─ SSR — ssr: true (Nuxt default)
│       Best for SEO + authenticated data
│
├─ Admin panel / internal tool (no SEO needed)?
│   └─ SPA — ssr: false in nuxt.config.ts
│
├─ Mixed needs (marketing pages + app)?
│   └─ Hybrid — routeRules per path
│       routeRules: {
│         '/': { prerender: true },
│         '/blog/**': { isr: 3600 },
│         '/app/**': { ssr: true },
│         '/admin/**': { ssr: false },
│       }
│
└─ Deploying to...
    ├─ Cloudflare Workers/Pages → preset: 'cloudflare'
    ├─ Vercel → preset: 'vercel' (auto-detected)
    ├─ Netlify → preset: 'netlify' (auto-detected)
    └─ Node.js server → preset: 'node-server'
```

---

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Reactivity lost after destructuring `reactive()` | Destructuring extracts plain values, not refs | Use `toRefs(state)` when destructuring, or use `ref()` instead of `reactive()` |
| `ref.value` needed in `<script>`, not in `<template>` | Template auto-unwraps top-level refs | Access as `count` in template, `count.value` in script |
| `watch` doesn't fire on nested object changes | Default is shallow watch | Add `{ deep: true }` or watch a specific nested path `() => obj.nested.prop` |
| Async setup breaks SSR in Nuxt | `await` in `setup()` suspends the component | Use `useAsyncData` or `useFetch` — never raw `await fetch()` in Nuxt setup |
| `watchEffect` runs immediately and tracks lazily | Tracks dependencies at runtime, not statically | Use `watch` with explicit sources when you need control over what's tracked |
| Template refs are `null` before mount | `ref()` is null until component is mounted | Access template refs inside `onMounted` or use `watch` with `{ immediate: false }` |
| Pinia store state lost when destructuring | State properties are not reactive when pulled out directly | Always use `storeToRefs(store)` for state/getters; destructure actions directly |
| Props are readonly — mutating causes warning | Vue enforces one-way data flow | Emit event to parent and let parent update; or use `defineModel()` for two-way binding |
| `computed` setter not called on direct assignment | Computed with no setter is read-only by default | Define `get` and `set`: `computed({ get: () => ..., set: (v) => ... })` |
| `v-model` on component uses wrong prop/event name | Default v-model uses `modelValue` prop and `update:modelValue` event | Use `defineModel()` (Vue 3.4+) or manually wire `modelValue` prop + `update:modelValue` emit |
| `provide` value is not reactive | Providing a raw value instead of a ref | Provide `ref()` or `reactive()` so injectors see updates: `provide('key', ref(value))` |
| `defineAsyncComponent` error not caught | Async component rejects without error boundary | Add `errorComponent` option or wrap in `<Suspense>` with error slot |

---

## Reference Files

| File | When to Load |
|------|-------------|
| [./references/composition-api.md](./references/composition-api.md) | Composables, provide/inject, template refs, custom directives, Teleport, Suspense, slots, transitions, v-model deep patterns |
| [./references/state-routing.md](./references/state-routing.md) | Pinia advanced patterns (plugins, SSR, store composition), Vue Router (guards, meta typing, scroll behavior, transitions) |
| [./references/nuxt.md](./references/nuxt.md) | Nuxt 3 data fetching, server routes, middleware, plugins, modules, SEO, deployment, Nuxt Content |
| [./references/testing.md](./references/testing.md) | Vitest setup, Vue Test Utils, Pinia/Router testing, composable testing, MSW, Playwright, Nuxt test utils |

---

## See Also

- **typescript-ops** — TypeScript generics, utility types, strict mode configuration
- **testing-ops** — General testing patterns, TDD, mocking strategies, CI integration
- **tailwind-ops** — Tailwind CSS with Vue component patterns, dark mode, responsive design
- **javascript-ops** — Modern JS patterns used alongside Vue (async/await, modules, iterators)
