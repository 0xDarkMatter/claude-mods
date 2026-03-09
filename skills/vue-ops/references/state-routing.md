# State Management & Routing Reference

Advanced Pinia patterns and Vue Router configuration with TypeScript.

---

## Pinia — Setup Syntax (Recommended)

The setup syntax mirrors `<script setup>` and is the preferred approach — full TypeScript inference, composables allowed inside, no `this` binding.

```ts
// stores/auth.ts
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { User } from '@/types'

export const useAuthStore = defineStore('auth', () => {
  // --- state (refs) ---
  const user = ref<User | null>(null)
  const token = ref<string | null>(null)
  const loading = ref(false)

  // --- getters (computed) ---
  const isLoggedIn = computed(() => !!token.value)
  const isAdmin = computed(() => user.value?.role === 'admin')
  const displayName = computed(() => user.value?.name ?? 'Guest')

  // --- actions (functions) ---
  async function login(email: string, password: string) {
    loading.value = true
    try {
      const res = await $fetch<{ user: User; token: string }>('/api/auth/login', {
        method: 'POST',
        body: { email, password },
      })
      user.value = res.user
      token.value = res.token
    } finally {
      loading.value = false
    }
  }

  function logout() {
    user.value = null
    token.value = null
  }

  return { user, token, loading, isLoggedIn, isAdmin, displayName, login, logout }
})
```

---

## Pinia — Options Syntax

```ts
// stores/cart.ts
import { defineStore } from 'pinia'
import type { CartItem, Product } from '@/types'

export const useCartStore = defineStore('cart', {
  state: () => ({
    items: [] as CartItem[],
    discount: 0,
  }),

  getters: {
    // Getter with argument — return a function
    itemById: (state) => (id: string) =>
      state.items.find((item) => item.id === id),

    total: (state): number =>
      state.items.reduce((sum, item) => sum + item.price * item.quantity, 0),

    discountedTotal(): number {
      // Can reference other getters via this
      return this.total * (1 - this.discount)
    },
  },

  actions: {
    addItem(product: Product) {
      const existing = this.itemById(product.id)
      if (existing) {
        existing.quantity++
      } else {
        this.items.push({ ...product, quantity: 1 })
      }
    },

    removeItem(id: string) {
      this.items = this.items.filter((item) => item.id !== id)
    },

    clearCart() {
      // $reset() is available in options syntax to reset to initial state
      this.$reset()
    },
  },
})
```

---

## Store Composition — Using One Store Inside Another

```ts
// stores/orders.ts
import { defineStore } from 'pinia'
import { computed } from 'vue'
import { useAuthStore } from './auth'

export const useOrdersStore = defineStore('orders', () => {
  const auth = useAuthStore()

  // Reactive dependency on auth store state
  const userOrders = computed(() =>
    allOrders.value.filter((o) => o.userId === auth.user?.id)
  )

  // Cross-store action
  async function placeOrder(items: CartItem[]) {
    if (!auth.isLoggedIn) throw new Error('Must be logged in')
    return await $fetch('/api/orders', {
      method: 'POST',
      body: { userId: auth.user!.id, items },
    })
  }

  return { userOrders, placeOrder }
})
```

---

## storeToRefs — Destructuring Without Losing Reactivity

```vue
<script setup lang="ts">
import { storeToRefs } from 'pinia'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()

// storeToRefs wraps state/getters in refs — safe to destructure
const { user, isLoggedIn, displayName } = storeToRefs(auth)

// Actions are plain functions — destructure directly from store
const { login, logout } = auth

// BAD — loses reactivity:
// const { user } = auth   // user is now a plain value, not reactive
</script>
```

---

## Pinia Plugins

### Persistence plugin (pinia-plugin-persistedstate)

```ts
// main.ts
import { createApp } from 'vue'
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'
import App from './App.vue'

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

createApp(App).use(pinia).mount('#app')
```

```ts
// Store with selective persistence
export const usePreferencesStore = defineStore('preferences', () => {
  const theme = ref<'light' | 'dark'>('light')
  const language = ref('en')
  const notifications = ref(true)

  return { theme, language, notifications }
}, {
  persist: {
    paths: ['theme', 'language'],     // only persist these
    storage: localStorage,
    serializer: {
      deserialize: JSON.parse,
      serialize: JSON.stringify,
    },
  },
})
```

### Custom plugin — logging

```ts
// plugins/pinia-logger.ts
import type { PiniaPluginContext } from 'pinia'

export function PiniaLogger({ store }: PiniaPluginContext) {
  store.$onAction(({ name, args, after, onError }) => {
    console.group(`[Pinia] ${store.$id}.${name}`)
    console.log('args:', args)

    after((result) => {
      console.log('result:', result)
      console.groupEnd()
    })

    onError((error) => {
      console.error('error:', error)
      console.groupEnd()
    })
  })
}
```

### Custom plugin — undo/redo

```ts
// plugins/pinia-history.ts
import { ref } from 'vue'
import type { PiniaPluginContext } from 'pinia'

export function PiniaHistory({ store }: PiniaPluginContext) {
  const history: string[] = []
  let historyIndex = -1

  // Snapshot state on every change
  store.$subscribe((mutation, state) => {
    // Drop future history on new action
    history.splice(historyIndex + 1)
    history.push(JSON.stringify(state))
    historyIndex = history.length - 1
  })

  store.undo = () => {
    if (historyIndex > 0) {
      historyIndex--
      store.$patch(JSON.parse(history[historyIndex]))
    }
  }

  store.redo = () => {
    if (historyIndex < history.length - 1) {
      historyIndex++
      store.$patch(JSON.parse(history[historyIndex]))
    }
  }
}
```

---

## Pinia SSR — State Hydration

```ts
// Nuxt: state is automatically serialized and hydrated via useNuxtApp().$pinia
// For custom SSR with Vite/Express:

// server.ts
import { createPinia } from 'pinia'

export async function render(url: string) {
  const pinia = createPinia()
  const app = createApp(App)
  app.use(pinia)

  await renderToString(app)

  // Serialize state to embed in HTML
  const state = JSON.stringify(pinia.state.value)
  return { state }
}

// client.ts
import { createPinia } from 'pinia'

const pinia = createPinia()

// Hydrate from server-serialized state
if (window.__INITIAL_STATE__) {
  pinia.state.value = JSON.parse(
    decodeURIComponent(atob(window.__INITIAL_STATE__))
  )
}

createApp(App).use(pinia).mount('#app')
```

---

## Pinia Store Subscriptions

```ts
const store = useCartStore()

// Subscribe to state changes
const unsubscribe = store.$subscribe((mutation, state) => {
  // mutation.type: 'direct' | 'patch object' | 'patch function'
  // mutation.storeId: store id
  // mutation.payload: patch object (if type is 'patch object')
  console.log('state changed', state)
})

// Subscribe to actions
store.$onAction(({ name, store, args, after, onError }) => {
  after((result) => { /* action succeeded */ })
  onError((error) => { /* action threw */ })
})

// Cleanup
onUnmounted(unsubscribe)
```

---

## Vue Router — Full Configuration

```ts
// router/index.ts
import { createRouter, createWebHistory, createWebHashHistory } from 'vue-router'
import type { RouteRecordRaw } from 'vue-router'

// TypeScript meta augmentation
declare module 'vue-router' {
  interface RouteMeta {
    requiresAuth?: boolean
    roles?: string[]
    title?: string
    breadcrumb?: string
    transition?: string
    keepAlive?: boolean
  }
}

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: () => import('@/views/HomeView.vue'),
    meta: { title: 'Home' },
  },
  {
    path: '/about',
    name: 'about',
    // Route-level code splitting — this route is lazy loaded
    component: () => import('@/views/AboutView.vue'),
  },
  {
    path: '/users/:id(\\d+)',      // only match numeric ids
    name: 'user',
    component: () => import('@/views/UserView.vue'),
    props: true,                    // route params passed as props
    meta: { requiresAuth: true, title: 'User Profile' },
  },
  {
    path: '/users/:id/settings',
    name: 'user-settings',
    component: () => import('@/views/UserSettingsView.vue'),
    props: (route) => ({ id: Number(route.params.id) }), // transform params
  },
  {
    path: '/blog/:slug?',           // optional param
    name: 'blog-post',
    component: () => import('@/views/BlogView.vue'),
  },
  {
    path: '/admin',
    redirect: '/admin/dashboard',
    component: () => import('@/layouts/AdminLayout.vue'),
    meta: { requiresAuth: true, roles: ['admin'] },
    children: [
      {
        path: 'dashboard',
        name: 'admin-dashboard',
        component: () => import('@/views/admin/DashboardView.vue'),
      },
      {
        path: 'users',
        name: 'admin-users',
        component: () => import('@/views/admin/UsersView.vue'),
        alias: '/users-admin',       // accessible at both paths
      },
    ],
  },
  {
    path: '/:pathMatch(.*)*',
    name: 'not-found',
    component: () => import('@/views/NotFoundView.vue'),
  },
]

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  // history: createWebHashHistory() — for hash-based routing (#/path)
  routes,
  scrollBehavior(to, from, savedPosition) {
    if (savedPosition) {
      // Restore scroll position when using browser back/forward
      return savedPosition
    }
    if (to.hash) {
      return { el: to.hash, behavior: 'smooth', top: 80 }
    }
    // Scroll to top on navigation, but only if path changed
    if (to.path !== from.path) {
      return { top: 0 }
    }
  },
})
```

---

## Navigation Guards

### Global guards — auth and title

```ts
// router/guards.ts
import { router } from './index'
import { useAuthStore } from '@/stores/auth'

router.beforeEach(async (to, from) => {
  // Set page title
  document.title = to.meta.title ? `${to.meta.title} — MyApp` : 'MyApp'

  const auth = useAuthStore()

  // Wait for auth to initialize (e.g., token check from localStorage)
  if (!auth.initialized) {
    await auth.initialize()
  }

  // Auth guard
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return {
      name: 'login',
      query: { redirect: to.fullPath },
    }
  }

  // Role guard
  if (to.meta.roles?.length && !to.meta.roles.includes(auth.user?.role ?? '')) {
    return { name: 'forbidden' }
  }
})

router.afterEach((to, from, failure) => {
  if (!failure) {
    // Analytics, etc.
    trackPageView(to.fullPath)
  }
})
```

### Per-route beforeEnter guard

```ts
{
  path: '/checkout',
  name: 'checkout',
  component: () => import('@/views/CheckoutView.vue'),
  beforeEnter: [
    // Multiple guards as array — executed in order
    requireAuth,
    requireNonEmptyCart,
  ],
}

function requireAuth(to, from) {
  const auth = useAuthStore()
  if (!auth.isLoggedIn) return { name: 'login', query: { redirect: to.fullPath } }
}

function requireNonEmptyCart(to, from) {
  const cart = useCartStore()
  if (cart.items.length === 0) return { name: 'cart' }
}
```

### In-component guards (Composition API)

```vue
<script setup lang="ts">
import {
  onBeforeRouteLeave,
  onBeforeRouteUpdate,
  useRoute,
  useRouter,
} from 'vue-router'
import { ref, watch } from 'vue'

const route = useRoute()
const router = useRouter()
const isDirty = ref(false)

// Guard: prevent navigating away with unsaved changes
onBeforeRouteLeave((to, from) => {
  if (isDirty.value) {
    const confirmed = window.confirm('Leave without saving?')
    if (!confirmed) return false
  }
})

// Guard: refetch data when param changes (e.g., /users/1 → /users/2)
onBeforeRouteUpdate(async (to, from) => {
  if (to.params.id !== from.params.id) {
    await fetchUser(to.params.id as string)
  }
})

// Alternative: watch route params reactively
watch(() => route.params.id, async (newId) => {
  if (newId) await fetchUser(newId as string)
}, { immediate: true })
</script>
```

---

## Dynamic Routes

```ts
// Programmatic navigation
const router = useRouter()

// Navigate to named route
router.push({ name: 'user', params: { id: 42 } })

// Navigate with query params
router.push({ name: 'search', query: { q: 'vue', page: 2 } })

// Replace current history entry (no back button)
router.replace({ name: 'login' })

// Navigate back/forward
router.go(-1)
router.back()
router.forward()
```

```ts
// Adding routes dynamically (e.g., from plugin or feature flag)
const removeRoute = router.addRoute({
  path: '/feature-x',
  name: 'feature-x',
  component: () => import('@/views/FeatureX.vue'),
})

// Remove the route when feature is disabled
removeRoute()
```

### useRoute — accessing route state

```vue
<script setup lang="ts">
import { useRoute } from 'vue-router'
import { computed } from 'vue'

const route = useRoute()

// Params — always strings or arrays of strings
const userId = computed(() => Number(route.params.id))

// Query params
const search = computed(() => route.query.q as string ?? '')
const page = computed(() => Number(route.query.page ?? 1))

// Route meta
const pageTitle = computed(() => route.meta.title)

// Full path and matched routes (breadcrumb data)
const breadcrumbs = computed(() =>
  route.matched.map((r) => ({ name: r.name, label: r.meta.breadcrumb }))
)
</script>
```

---

## Route Transitions

### Per-route transition names

```vue
<!-- App.vue -->
<script setup lang="ts">
import { useRoute } from 'vue-router'
const route = useRoute()
</script>

<template>
  <RouterView v-slot="{ Component, route }">
    <Transition :name="route.meta.transition ?? 'fade'" mode="out-in">
      <component :is="Component" :key="route.path" />
    </Transition>
  </RouterView>
</template>

<style>
.fade-enter-active,
.fade-leave-active { transition: opacity 0.2s ease; }
.fade-enter-from,
.fade-leave-to { opacity: 0; }

.slide-enter-active,
.slide-leave-active { transition: transform 0.3s ease; }
.slide-enter-from { transform: translateX(100%); }
.slide-leave-to { transform: translateX(-100%); }
</style>
```

```ts
// Route definition with transition
{
  path: '/users',
  component: () => import('@/views/UsersView.vue'),
  meta: { transition: 'slide' },
}
```

### View Transitions API (Chrome 111+)

```ts
router.beforeEach(() => {
  if (!document.startViewTransition) return

  return new Promise((resolve) => {
    document.startViewTransition(resolve)
  })
})
```

---

## Lazy Loading

### Route-level code splitting

```ts
// Each () => import() creates a separate chunk
const routes = [
  { path: '/dashboard', component: () => import('@/views/Dashboard.vue') },
  { path: '/settings', component: () => import('@/views/Settings.vue') },
]
```

### defineAsyncComponent with loading and error states

```ts
import { defineAsyncComponent } from 'vue'
import Spinner from '@/components/Spinner.vue'
import ErrorDisplay from '@/components/ErrorDisplay.vue'

const AsyncHeavyChart = defineAsyncComponent({
  loader: () => import('@/components/HeavyChart.vue'),
  loadingComponent: Spinner,
  errorComponent: ErrorDisplay,
  delay: 200,           // show loading after 200ms (avoids flash)
  timeout: 10000,       // error if not loaded within 10s
  onError(error, retry, fail, attempts) {
    if (attempts <= 3) retry()  // retry up to 3 times
    else fail()
  },
})
```

### Grouping chunks with magic comments

```ts
// Vite: chunks are auto-split, but you can group with same chunk name
const UserProfile = () => import(/* @vite-ignore */ '@/views/UserProfile.vue')

// Prefetch on hover (manual)
function prefetchDashboard() {
  import('@/views/Dashboard.vue')
}
```

---

## Scroll Behavior Patterns

```ts
scrollBehavior(to, from, savedPosition) {
  // 1. Browser back/forward → restore exact position
  if (savedPosition) return savedPosition

  // 2. Hash link → scroll to element
  if (to.hash) {
    return {
      el: to.hash,
      top: 80,              // offset for sticky header
      behavior: 'smooth',
    }
  }

  // 3. New page → scroll to top
  return { top: 0, left: 0 }
}
```

### Async scroll (wait for transition)

```ts
scrollBehavior(to, from, savedPosition) {
  return new Promise((resolve) => {
    // Wait for page transition to complete
    setTimeout(() => {
      resolve(savedPosition ?? { top: 0 })
    }, 300)
  })
}
```
