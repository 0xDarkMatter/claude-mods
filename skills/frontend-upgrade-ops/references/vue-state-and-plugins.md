# Vuex to Pinia, and replacing Vue 2 plugins

The two dependency questions that decide a Vue 3 migration's length: where the state
goes, and whether every Vue 2 plugin has a Vue 3 path. Sources: pinia.vuejs.org
(cookbook/migration-vuex), vuex.vuejs.org, github.com/vuejs/pinia releases, the npm
registry. Versions verified as of 2026-10-05.

## Contents

1. [Which Pinia, when](#which-pinia-when)
2. [Converting a Vuex module](#converting-a-vuex-module)
3. [Components and outside-component code](#components-and-outside-component-code)
4. [One store across many islands](#one-store-across-many-islands)
5. [Plugin replacement table](#plugin-replacement-table)
6. [Plugins with no Vue 3 path](#plugins-with-no-vue-3-path)

## Which Pinia, when

| Situation | Store library | Why |
|---|---|---|
| Still on Vue 2.7 | **Pinia 2** | "Pinia also works with Vue 2.x" (vuex.vuejs.org); Pinia 3 dropped Vue 2 |
| On Vue 3, want the smallest diff today | Vuex 4 | Vue 3-compatible, maintained, "unlikely to add new functionalities" |
| On Vue 3 | **Pinia 4** (4.0.0 on 2026-07-14, 4.0.3 latest) | The official default |

Pinia release facts that change install commands:

- **Pinia 3** (2025-02-11): dropped Vue 2; removed `defineStore({ id })` (use
  `defineStore('id', ...)`); `PiniaStorePlugin` became `PiniaPlugin`.
- **Pinia 4**: "only technically breaking changes: ESM only and upgrading
  `@vue/devtools-api`" - v8 of which "now must be installed alongside pinia". Peer
  ranges: `vue ^3.5.11`, `typescript >=5.6.0` (if you use TS).

```bash
npm install pinia@4 @vue/devtools-api@8
```

Vuex and Pinia **can run side by side** (the official guide says so), so convert one
module at a time behind green tests instead of one big-bang store rewrite.

## Converting a Vuex module

Each Vuex module becomes one store; the module namespace becomes the store id.

```js
// BEFORE - store/modules/cart.js (Vuex, namespaced)
export default {
  namespaced: true,
  state: () => ({ items: [] }),
  getters: { count: (state) => state.items.length },
  mutations: { ADD(state, item) { state.items.push(item) }, CLEAR(state) { state.items = [] } },
  actions: {
    async add({ commit, rootState }, sku) {
      const item = await fetchItem(sku, rootState.site.currency)
      commit('ADD', item)
    },
  },
}

// AFTER - stores/cart.js (Pinia)
import { defineStore } from 'pinia'
import { useSiteStore } from './site'

export const useCartStore = defineStore('cart', {
  state: () => ({ items: [] }),
  getters: { count: (state) => state.items.length },
  actions: {
    async add(sku) {
      const site = useSiteStore()                 // was rootState.site
      this.items.push(await fetchItem(sku, site.currency))
    },
  },
})
```

Rules from the official cookbook:

- **Mutations disappear.** Their bodies move into actions (or direct assignment).
- **`rootState` / `rootGetters` become imports** of the other store, called inside the
  action, not at module top level.
- Actions get `this`, not a `context` object; drop `commit`/`dispatch`.
- A "reset to initial state" mutation is built in: `store.$reset()` (Options stores).
- Getters that only expose a state field are redundant - delete them.

## Components and outside-component code

```js
// Options API components keep working with map helpers
import { mapState, mapActions } from 'pinia'
export default {
  computed: { ...mapState(useCartStore, ['items', 'count']) },
  methods: { ...mapActions(useCartStore, ['add']) },
}

// Composition API
const cart = useCartStore()
cart.add('SKU-1')
```

Outside components (router guards, plain modules, an Alpine handler): call
`useCartStore()` **inside** the function that needs it, never at module top level -
Pinia must be installed on an app first, and calling early throws.

## One store across many islands

Server-rendered sites mount several small apps, not one. Install the **same** Pinia
instance into each so a "mini cart" island and a "product" island share state:

```js
// src/js/pinia.js - a module singleton: every importer gets this instance
import { createPinia } from 'pinia'
export const pinia = createPinia()

// in each island bootstrap
import { pinia } from './pinia'
createApp(MiniCart).use(pinia).mount(el)
```

Two islands with two `createPinia()` calls have two separate carts - the most common
"state doesn't update in the header" bug after a migration. Mounting is covered in
[vue-islands-in-twig.md](vue-islands-in-twig.md).

## Plugin replacement table

Versions are npm `latest` as of 2026-10-05. "Rewrite" means the API changed enough that
call sites need touching, not just an install.

| Vue 2 dependency | Vue 3 path | Current | Effort |
|---|---|---|---|
| `vue-router` 3 | `vue-router` 4+ (the version the migration guide names); 5.x is current - read its notes before jumping two majors | 5.3.1 | Moderate: `createRouter`, `createWebHistory` |
| `vuex` 3 | `vuex` 4 (bridge) or Pinia | 4.1.0 / Pinia 4.0.3 | Low / per-module |
| `vue-template-compiler` | `@vue/compiler-sfc`, version-locked to `vue` | 3.5.43 | Install only |
| `vue-loader` 15 | none under Vite - `@vitejs/plugin-vue` | 6.0.9 | Config only |
| `@vue/test-utils` 1 | `@vue/test-utils` 2 | 2.5.1 | Moderate (see vue2-to-vue3.md) |
| Event bus (`new Vue()`) | `mitt`, provide/inject, or a Pinia store | mitt 3.0.1 | Low |
| `Vue.filter(...)` | plain functions or `app.config.globalProperties` | - | Low |
| `Vue.prototype.$http = axios` | `app.config.globalProperties.$http`, or import axios where used | - | Low |
| `portal-vue` | built-in `<Teleport>` | - | Low |
| `vue-i18n` 8 | `vue-i18n` 9+ (`createI18n`) | 11.4.13 | Moderate |
| `vee-validate` 3 | `vee-validate` 4 | 4.15.1 | Rewrite (new `useForm`/`<Form>` model) |
| `vuedraggable` 2 | `vuedraggable@next` (dist-tag `next`) | 4.1.0 | Low-moderate |
| `vue-select` 3 | `vue-select@beta` | 4.0.0-beta.6 - **still beta** | Risk: budget a fallback |
| `vue-meta` | `@unhead/vue` - or delete it: on Craft, meta tags belong to Twig/SEO plugins | 3.4.2 | Usually delete |
| `vue-the-mask` / `v-mask` | `maska` | 3.2.2 | Low |
| `vue-lazyload` | native `loading="lazy"` + Craft image transforms | - | Delete |
| `vue-awesome-swiper` | Swiper's own Vue components (`swiper/vue`) or Swiper core without Vue | swiper 14.3.0 | Low-moderate |

Check every row against the library's own changelog before committing to it - this
table is a starting inventory, not a guarantee.

## Plugins with no Vue 3 path

Search npm and the repo for a Vue 3 major or a named successor; if neither exists:

1. **Wrapper around a framework-free library** (date picker, slider, map, chart)?
   Use the underlying library directly from a small Vue 3 component, or from Alpine.
   This is the usual case and usually the cheapest.
2. **Component library** (UI kits built for Vue 2)? Treat the island as a rewrite and
   cost it separately; if it is one widget, see SKILL.md "Migrate Vue, or replace it?".
3. **Abandoned and load-bearing**? That plugin is the project's critical path - spike
   it first, before any other migration work, because its answer can change the plan.

```bash
# List Vue-ecosystem deps and their peer ranges in one pass
jq -r '.dependencies + .devDependencies | keys[]' package.json | rg -i "vue" \
  | while read -r p; do printf '%-28s ' "$p"; npm view "$p" peerDependencies.vue 2>/dev/null || echo; done
```
