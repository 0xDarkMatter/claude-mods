# Composition API Reference

Deep-dive patterns for Vue 3 Composition API: composables, lifecycle, template refs, provide/inject, v-model, slots, transitions, Teleport, Suspense, and custom directives.

---

## Composables

### Naming and structure convention

```ts
// composables/useCounter.ts
import { ref, computed, onUnmounted } from 'vue'

// Rule: always prefix with "use"
export function useCounter(initialValue = 0) {
  // State: return refs so callers can destructure while keeping reactivity
  const count = ref(initialValue)
  const isNegative = computed(() => count.value < 0)

  function increment() { count.value++ }
  function decrement() { count.value-- }
  function reset() { count.value = initialValue }

  // Cleanup: always handle in onUnmounted if you register listeners/timers
  // (onUnmounted is a no-op when called outside a component)

  return { count, isNegative, increment, decrement, reset }
}
```

### Accepting refs as arguments (reactive composable inputs)

```ts
// composables/useDouble.ts
import { computed, toRef, MaybeRefOrGetter, toValue } from 'vue'

// toValue() (Vue 3.3+) unwraps ref, getter, or raw value
export function useDouble(value: MaybeRefOrGetter<number>) {
  return computed(() => toValue(value) * 2)
}

// Usage: works with raw value, ref, or getter
const x = ref(5)
const doubled = useDouble(x)          // reactive
const doubled2 = useDouble(5)         // static
const doubled3 = useDouble(() => x.value + 1)  // getter
```

### useFetch — data fetching with cancellation

```ts
// composables/useFetch.ts
import { ref, watchEffect, toValue, MaybeRefOrGetter } from 'vue'

export function useFetch<T>(url: MaybeRefOrGetter<string>) {
  const data = ref<T | null>(null)
  const error = ref<Error | null>(null)
  const pending = ref(false)

  watchEffect((onCleanup) => {
    const controller = new AbortController()

    // Register cleanup BEFORE the async work
    onCleanup(() => controller.abort())

    pending.value = true
    error.value = null

    fetch(toValue(url), { signal: controller.signal })
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        return res.json()
      })
      .then((json) => { data.value = json })
      .catch((err) => {
        if (err.name !== 'AbortError') error.value = err
      })
      .finally(() => { pending.value = false })
  })

  return { data, error, pending }
}
```

### useLocalStorage — synced persistent state

```ts
// composables/useLocalStorage.ts
import { ref, watch } from 'vue'

export function useLocalStorage<T>(key: string, defaultValue: T) {
  const stored = localStorage.getItem(key)
  const initial = stored ? (JSON.parse(stored) as T) : defaultValue
  const state = ref<T>(initial)

  watch(
    state,
    (value) => localStorage.setItem(key, JSON.stringify(value)),
    { deep: true }
  )

  return state
}

// Usage
const theme = useLocalStorage<'light' | 'dark'>('theme', 'light')
```

### useEventListener — safe event binding

```ts
// composables/useEventListener.ts
import { onMounted, onUnmounted, isRef, watch } from 'vue'
import type { Ref } from 'vue'

export function useEventListener<K extends keyof WindowEventMap>(
  target: Window | Document | Ref<HTMLElement | null>,
  event: K,
  handler: (e: WindowEventMap[K]) => void
) {
  if (isRef(target)) {
    watch(target, (el, _, onCleanup) => {
      el?.addEventListener(event, handler as EventListener)
      onCleanup(() => el?.removeEventListener(event, handler as EventListener))
    })
  } else {
    onMounted(() => target.addEventListener(event, handler as EventListener))
    onUnmounted(() => target.removeEventListener(event, handler as EventListener))
  }
}

// Usage
useEventListener(window, 'resize', () => {
  console.log('window resized')
})
```

### useDark — dark mode toggle

```ts
// composables/useDark.ts
import { ref, watch, onMounted } from 'vue'

export function useDark() {
  const isDark = ref(false)

  onMounted(() => {
    isDark.value = document.documentElement.classList.contains('dark')
      || window.matchMedia('(prefers-color-scheme: dark)').matches
  })

  watch(isDark, (dark) => {
    document.documentElement.classList.toggle('dark', dark)
  })

  function toggle() { isDark.value = !isDark.value }

  return { isDark, toggle }
}
```

### useIntersectionObserver — lazy loading / scroll tracking

```ts
// composables/useIntersectionObserver.ts
import { ref, onMounted, onUnmounted } from 'vue'
import type { Ref } from 'vue'

export function useIntersectionObserver(
  target: Ref<HTMLElement | null>,
  options: IntersectionObserverInit = {}
) {
  const isIntersecting = ref(false)
  let observer: IntersectionObserver | null = null

  onMounted(() => {
    observer = new IntersectionObserver(([entry]) => {
      isIntersecting.value = entry.isIntersecting
    }, options)

    if (target.value) observer.observe(target.value)
  })

  onUnmounted(() => observer?.disconnect())

  return { isIntersecting }
}

// Usage
const el = ref<HTMLElement | null>(null)
const { isIntersecting } = useIntersectionObserver(el, { threshold: 0.1 })
```

---

## Lifecycle Hooks

```ts
import {
  onBeforeMount,   // before first render, DOM not yet created
  onMounted,       // after first render, DOM available
  onBeforeUpdate,  // before re-render triggered by reactive change
  onUpdated,       // after re-render (DOM updated)
  onBeforeUnmount, // before component teardown (still fully functional)
  onUnmounted,     // after component teardown
  onActivated,     // component re-activated inside <KeepAlive>
  onDeactivated,   // component deactivated inside <KeepAlive>
  onErrorCaptured, // error from descendant component
} from 'vue'

// Pattern: separate concerns into multiple onMounted calls
onMounted(() => { initChart() })
onMounted(() => { attachKeyboardListeners() })

// KeepAlive lifecycle — fetch fresh data on each activation
onActivated(() => { refreshData() })
onDeactivated(() => { pauseAnimations() })

// Error boundary at composable level
onErrorCaptured((err, instance, info) => {
  logError(err)
  return false // prevent propagation
})
```

---

## Template Refs

### Basic ref() approach

```vue
<script setup lang="ts">
import { ref, onMounted } from 'vue'

const inputEl = ref<HTMLInputElement | null>(null)

onMounted(() => {
  inputEl.value?.focus()
})
</script>

<template>
  <input ref="inputEl" type="text" />
</template>
```

### useTemplateRef() — Vue 3.5+

```vue
<script setup lang="ts">
import { useTemplateRef, onMounted } from 'vue'

// String key matches the ref="..." attribute in template
const input = useTemplateRef<HTMLInputElement>('inputEl')

onMounted(() => {
  input.value?.focus()
})
</script>

<template>
  <input ref="inputEl" type="text" />
</template>
```

### Component refs — accessing exposed methods

```vue
<!-- Parent -->
<script setup lang="ts">
import { ref } from 'vue'
import type ChildComponent from './ChildComponent.vue'

const child = ref<InstanceType<typeof ChildComponent> | null>(null)

function focusChild() {
  child.value?.focus() // only works if child uses defineExpose
}
</script>

<template>
  <ChildComponent ref="child" />
</template>
```

```vue
<!-- ChildComponent.vue -->
<script setup lang="ts">
import { ref } from 'vue'

const inputEl = ref<HTMLInputElement | null>(null)

function focus() {
  inputEl.value?.focus()
}

defineExpose({ focus })
</script>
```

### Dynamic template refs in v-for

```vue
<script setup lang="ts">
import { ref } from 'vue'

const itemRefs = ref<HTMLElement[]>([])
const items = ref(['a', 'b', 'c'])
</script>

<template>
  <ul>
    <li
      v-for="item in items"
      :key="item"
      :ref="(el) => { if (el) itemRefs.push(el as HTMLElement) }"
    >
      {{ item }}
    </li>
  </ul>
</template>
```

---

## provide / inject

### Typed injection keys (InjectionKey<T>)

```ts
// keys/injection-keys.ts
import { InjectionKey, Ref } from 'vue'

export interface UserContext {
  user: Ref<User | null>
  logout: () => void
}

// The key carries the type — no casts needed at inject site
export const UserContextKey: InjectionKey<UserContext> = Symbol('UserContext')
```

### Providing values (ancestor component)

```vue
<!-- App.vue or layout component -->
<script setup lang="ts">
import { provide, ref, readonly } from 'vue'
import { UserContextKey } from '@/keys/injection-keys'
import type { User } from '@/types'

const user = ref<User | null>(null)

function logout() {
  user.value = null
}

// Wrap in readonly to prevent descendants from mutating directly
provide(UserContextKey, { user: readonly(user), logout })
</script>
```

### Injecting in descendants

```vue
<script setup lang="ts">
import { inject } from 'vue'
import { UserContextKey } from '@/keys/injection-keys'

// TypeScript knows the type from the InjectionKey
const ctx = inject(UserContextKey)
// ctx is UserContext | undefined — handle the undefined case

// With default value (ensures non-null)
const ctx2 = inject(UserContextKey, {
  user: ref(null),
  logout: () => {},
})
</script>
```

---

## v-model Patterns

### defineModel() — Vue 3.4+

```vue
<!-- SimpleInput.vue -->
<script setup lang="ts">
// Single v-model — replaces modelValue prop + update:modelValue emit
const model = defineModel<string>({ required: true })
</script>

<template>
  <input :value="model" @input="model = ($event.target as HTMLInputElement).value" />
</template>
```

```vue
<!-- Parent usage -->
<SimpleInput v-model="username" />
```

### Multiple v-models

```vue
<!-- RangeInput.vue -->
<script setup lang="ts">
const min = defineModel<number>('min', { default: 0 })
const max = defineModel<number>('max', { default: 100 })
</script>

<template>
  <input type="number" :value="min" @input="min = +($event.target as HTMLInputElement).value" />
  <input type="number" :value="max" @input="max = +($event.target as HTMLInputElement).value" />
</template>
```

```vue
<!-- Parent usage -->
<RangeInput v-model:min="rangeMin" v-model:max="rangeMax" />
```

### v-model with modifiers

```vue
<!-- UpperInput.vue -->
<script setup lang="ts">
const [model, modifiers] = defineModel<string, 'uppercase' | 'trim'>({
  set(value) {
    if (modifiers.trim) value = value.trim()
    if (modifiers.uppercase) value = value.toUpperCase()
    return value
  }
})
</script>
```

```vue
<!-- Parent usage -->
<UpperInput v-model.uppercase.trim="text" />
```

---

## Slots

### Named slots with TypeScript types

```vue
<!-- DataTable.vue -->
<script setup lang="ts">
defineSlots<{
  default?: (props: {}) => any
  header?: (props: { title: string }) => any
  row: (props: { item: User; index: number }) => any
  empty?: (props: {}) => any
}>()

const props = defineProps<{ items: User[] }>()
</script>

<template>
  <div>
    <slot name="header" :title="'Users'" />
    <div v-if="props.items.length === 0">
      <slot name="empty" />
    </div>
    <div v-for="(item, index) in props.items" :key="item.id">
      <slot name="row" :item="item" :index="index" />
    </div>
    <slot />
  </div>
</template>
```

```vue
<!-- Parent usage — scoped slot destructuring -->
<DataTable :items="users">
  <template #header="{ title }">
    <h2>{{ title }}</h2>
  </template>
  <template #row="{ item, index }">
    <div>{{ index + 1 }}. {{ item.name }}</div>
  </template>
  <template #empty>
    <p>No users found.</p>
  </template>
</DataTable>
```

### Renderless components

```vue
<!-- Renderless: MouseTracker.vue -->
<script setup lang="ts">
import { ref } from 'vue'
import { useEventListener } from '@/composables/useEventListener'

const x = ref(0)
const y = ref(0)

useEventListener(window, 'mousemove', (e) => {
  x.value = e.clientX
  y.value = e.clientY
})
</script>

<template>
  <!-- Only renders what's in the default scoped slot -->
  <slot :x="x" :y="y" />
</template>
```

```vue
<!-- Usage -->
<MouseTracker v-slot="{ x, y }">
  Cursor: {{ x }}, {{ y }}
</MouseTracker>
```

### useSlots() in composables

```ts
import { useSlots, computed } from 'vue'

// Check if a named slot is provided
export function useHasSlot(name: string) {
  const slots = useSlots()
  return computed(() => !!slots[name])
}
```

---

## Transitions

### CSS transitions

```vue
<script setup lang="ts">
import { ref } from 'vue'
const show = ref(true)
</script>

<template>
  <button @click="show = !show">Toggle</button>

  <Transition name="fade">
    <div v-if="show" class="box">Hello</div>
  </Transition>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.3s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
```

### JavaScript hooks (GSAP / Web Animations API)

```vue
<template>
  <Transition
    @before-enter="onBeforeEnter"
    @enter="onEnter"
    @leave="onLeave"
    :css="false"
  >
    <div v-if="show" />
  </Transition>
</template>

<script setup lang="ts">
import gsap from 'gsap'

function onBeforeEnter(el: Element) {
  gsap.set(el, { opacity: 0, y: -20 })
}

function onEnter(el: Element, done: () => void) {
  gsap.to(el, { opacity: 1, y: 0, duration: 0.4, onComplete: done })
}

function onLeave(el: Element, done: () => void) {
  gsap.to(el, { opacity: 0, y: 20, duration: 0.3, onComplete: done })
}
</script>
```

### TransitionGroup — list animations

```vue
<template>
  <TransitionGroup name="list" tag="ul">
    <li v-for="item in items" :key="item.id">
      {{ item.name }}
    </li>
  </TransitionGroup>
</template>

<style>
.list-enter-active,
.list-leave-active {
  transition: all 0.3s ease;
}
.list-enter-from {
  opacity: 0;
  transform: translateX(-30px);
}
.list-leave-to {
  opacity: 0;
  transform: translateX(30px);
}
/* Animate position changes of remaining items */
.list-move {
  transition: transform 0.3s ease;
}
/* Ensure leaving items take up no space during animation */
.list-leave-active {
  position: absolute;
}
</style>
```

---

## Teleport

### Modal pattern

```vue
<!-- Modal.vue -->
<script setup lang="ts">
defineProps<{ open: boolean }>()
const emit = defineEmits<{ close: [] }>()
</script>

<template>
  <Teleport to="body">
    <Transition name="fade">
      <div v-if="open" class="modal-overlay" @click.self="emit('close')">
        <div class="modal-content" role="dialog" aria-modal="true">
          <slot />
          <button @click="emit('close')">Close</button>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>
```

### Disabling Teleport conditionally

```vue
<!-- Disable teleport in SSR or based on prop -->
<Teleport to="#modals" :disabled="!isMounted">
  <div>Content</div>
</Teleport>
```

---

## Suspense

### Async setup with Suspense

```vue
<!-- AsyncUserProfile.vue — top-level await allowed in <script setup> -->
<script setup lang="ts">
const { data: user } = await useFetch<User>('/api/user')
//     ^ Component is now async — must be wrapped in <Suspense>
</script>

<template>
  <div>{{ user?.name }}</div>
</template>
```

```vue
<!-- Parent wraps async component -->
<template>
  <Suspense>
    <template #default>
      <AsyncUserProfile />
    </template>
    <template #fallback>
      <div class="skeleton" aria-busy="true">Loading...</div>
    </template>
  </Suspense>
</template>
```

### Error handling with Suspense

```vue
<script setup lang="ts">
import { ref } from 'vue'

const error = ref<Error | null>(null)

function handleError(e: Error) {
  error.value = e
}
</script>

<template>
  <div v-if="error">Error: {{ error.message }}</div>
  <Suspense v-else @resolve="onResolved" @fallback="onFallback" @pending="onPending">
    <AsyncComponent />
    <template #fallback>Loading...</template>
  </Suspense>
</template>
```

---

## Custom Directives

### vFocus — auto-focus on mount

```ts
// directives/vFocus.ts
import type { Directive } from 'vue'

export const vFocus: Directive<HTMLElement> = {
  mounted(el) {
    el.focus()
  }
}
```

```vue
<script setup lang="ts">
import { vFocus } from '@/directives/vFocus'
// Directives imported in <script setup> are automatically available
</script>

<template>
  <input v-focus type="text" />
</template>
```

### vClickOutside — dismiss on outside click

```ts
// directives/vClickOutside.ts
import type { Directive } from 'vue'

type ClickOutsideHandler = (event: MouseEvent) => void

export const vClickOutside: Directive<HTMLElement, ClickOutsideHandler> = {
  mounted(el, binding) {
    el._clickOutside = (event: MouseEvent) => {
      if (!el.contains(event.target as Node)) {
        binding.value(event)
      }
    }
    document.addEventListener('click', el._clickOutside)
  },
  unmounted(el) {
    document.removeEventListener('click', el._clickOutside)
    delete el._clickOutside
  },
}
```

### vIntersect — visibility tracking

```ts
// directives/vIntersect.ts
import type { Directive } from 'vue'

interface IntersectBinding {
  handler: (isIntersecting: boolean) => void
  options?: IntersectionObserverInit
}

export const vIntersect: Directive<HTMLElement, IntersectBinding> = {
  mounted(el, { value }) {
    const observer = new IntersectionObserver(
      ([entry]) => value.handler(entry.isIntersecting),
      value.options
    )
    observer.observe(el)
    el._intersectObserver = observer
  },
  unmounted(el) {
    el._intersectObserver?.disconnect()
  },
}
```

### Registering directives globally

```ts
// main.ts
import { createApp } from 'vue'
import { vFocus } from '@/directives/vFocus'
import { vClickOutside } from '@/directives/vClickOutside'

const app = createApp(App)
app.directive('focus', vFocus)
app.directive('click-outside', vClickOutside)
app.mount('#app')
```

### Directive lifecycle hooks reference

```ts
const myDirective: Directive = {
  created(el, binding, vnode) {},       // before component attrs/events applied
  beforeMount(el, binding, vnode) {},   // before element inserted into DOM
  mounted(el, binding, vnode) {},       // after element inserted, children mounted
  beforeUpdate(el, binding, vnode, prevVnode) {},  // before parent component updates
  updated(el, binding, vnode, prevVnode) {},        // after parent and children updated
  beforeUnmount(el, binding, vnode) {},  // before element removed
  unmounted(el, binding, vnode) {},     // after element removed
}

// binding object shape:
// binding.value   — value passed to directive (v-my-dir="value")
// binding.oldValue — previous value (updated hook only)
// binding.arg    — argument (v-my-dir:arg)
// binding.modifiers — object { lazy: true } for v-my-dir.lazy
// binding.instance — component instance
```
