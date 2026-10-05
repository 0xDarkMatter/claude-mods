# Vue 2 to Vue 3: migration build, breaking changes, testing

How to move a Vue 2 codebase to Vue 3 with the migration build (`@vue/compat`) and
know when it is done. State and plugin replacements are in
[vue-state-and-plugins.md](vue-state-and-plugins.md); Twig-specific mounting is in
[vue-islands-in-twig.md](vue-islands-in-twig.md). Primary source:
v3-migration.vuejs.org. Facts verified as of 2026-10-05.

## Contents

1. [Where things stand](#where-things-stand)
2. [Before the switch](#before-the-switch)
3. [Install the migration build under Vite](#install-the-migration-build-under-vite)
4. [Burn down the warnings](#burn-down-the-warnings)
5. [Breaking changes that bite on Twig sites](#breaking-changes-that-bite-on-twig-sites)
6. [Removing the migration build](#removing-the-migration-build)
7. [Testing the switch](#testing-the-switch)

## Where things stand

| Fact | Value (as of 2026-10-05) | Source |
|---|---|---|
| Vue 2 end of life | **31 December 2023** - no security or browser-compatibility fixes since | v2.vuejs.org/lts |
| Final Vue 2 release | 2.7.16 (2023-12-24) | npm |
| Paid extended support | HeroDevs "Never-Ending Support" is the vendor the Vue team points to | v2.vuejs.org/lts |
| Vue 3 current | 3.5.43; `@vue/compat` is published in lockstep (its peer is the exact same `vue` version) | npm |
| Migration build scope | Vue 2-compatible behaviour, configurable per feature; not for apps depending on Vue 2 internals or undocumented VNode behaviour | v3-migration.vuejs.org/migration-build |
| Browser floor | IE 11 is gone in Vue 3 | v3-migration.vuejs.org |

## Before the switch

On Vue 2, in this order - each step ships on its own:

1. **Bundler first.** Get the site onto Vite with Vue 2.7 + `@vitejs/plugin-vue2`
   (see SKILL.md "Sequencing"). Doing the bundler and the framework in one deploy means
   you can't tell which change broke a page.
2. **Vue 2.7.16.** It backports the Composition API and `<script setup>`, so new code
   written now survives the jump unchanged.
3. **Fix deprecated slot syntax** (`slot="x"` / `slot-scope` to `v-slot`) - the guide's
   own first preparation step.
4. **Optional: Vuex to Pinia 2** while still on 2.7 (Pinia 2 supports Vue 2; Pinia 3+
   does not). Removes a moving part from the Vue 3 deploy.
5. **Inventory third-party Vue plugins** against the replacement table - one plugin with
   no Vue 3 path is the critical path for the whole project.

```bash
# Vue 2 surface area in one pass
rg -n "new Vue\(|Vue\.(use|component|mixin|filter|directive|prototype|set|delete)" src/
rg -n "\\\$on\(|\\\$off\(|\\\$once\(|\\\$children|\\\$listeners|\\\$scopedSlots|\\\$set\(" src/
rg -n "inline-template|\.sync|\.native|slot-scope|beforeDestroy|destroyed\b" src/ templates/
rg -n "\|\s*[a-z]+\s*\}\}" src/ --glob '*.vue'      # Vue 2 filters in SFC templates
```

## Install the migration build under Vite

```bash
npm remove vue-template-compiler @vitejs/plugin-vue2
npm install vue@3 @vue/compat@3          # same exact version - check the lockfile
npm install -D @vitejs/plugin-vue vite@8
```

```js
// vite.config.js
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  resolve: {
    alias: { vue: '@vue/compat' },        // everything that imports 'vue' gets compat
  },
  plugins: [
    vue({
      template: { compilerOptions: { compatConfig: { MODE: 2 } } },
    }),
  ],
})
```

Then port the entry point to the application API - this is mandatory, compat does not
emulate `new Vue()` mounting forever:

```js
// BEFORE (Vue 2)
Vue.use(MyPlugin); Vue.component('site-search', SiteSearch)
new Vue({ el: '#app', store, render: h => h(App) })

// AFTER (Vue 3)
import { createApp } from 'vue'
const app = createApp(App)
app.use(MyPlugin).component('site-search', SiteSearch)
app.mount('#app')
```

TypeScript projects add a shim declaring `vue` as `CompatVue` (the guide gives the
`.d.ts`); drop it with compat.

## Burn down the warnings

The official order (v3-migration.vuejs.org/migration-build, "Upgrade Workflow"):

1. Fix template **compile** errors/warnings first.
2. Rename **transition classes** project-wide (`.v-enter` to `.v-enter-from`,
   `.v-leave` to `.v-leave-from`) - CSS, so no runtime warning catches it.
3. Port the entry to the **global mounting API** (above).
4. **Vuex 3 to 4** (or straight to Pinia), **vue-router 3 to 4**.
5. Work through **runtime warnings** one compat ID at a time.
6. Switch to Vue 3 proper - remove the alias.

Control compat per feature or per component:

```js
import { configureCompat } from 'vue'
configureCompat({ MODE: 3, OPTIONS_BEFORE_DESTROY: true }) // Vue 3 default, opt features back in

export default {                       // per-component, once a component is clean
  compatConfig: { MODE: 3 },
}
```

Work method that keeps the burn-down honest: flip one component at a time to
`compatConfig: { MODE: 3 }`, fix it, commit. When every component carries `MODE: 3`,
set the global `MODE: 3` and delete the per-component flags.

## Breaking changes that bite on Twig sites

The full list is v3-migration.vuejs.org/breaking-changes. These are the ones a
server-rendered site with Vue islands hits most, roughly in order of pain:

| Vue 2 | Vue 3 | Compat flag / note |
|---|---|---|
| `inline-template` attribute (templates written in Twig) | Removed. Use a default scoped slot, or a `<script type="text/html" id="...">` template referenced as `template: '#id'` | `COMPILER_INLINE_TEMPLATE`. Island alternative: see vue-islands-in-twig.md |
| `new Vue({ el })` replaced the element | App renders **inside** the element, replacing its `innerHTML`; container keeps its attributes | `GLOBAL_MOUNT_CONTAINER`. CSS that targeted the replaced element may now miss |
| `Vue.component/use/mixin/directive`, `Vue.prototype.$x` | `app.component/use/mixin/directive`, `app.config.globalProperties.$x` | Per-app now: each island's app needs its own registration |
| Event bus `new Vue()` + `$on/$off/$once` | Removed. `mitt`, provide/inject, or a Pinia store | Cross-island messaging needs a real channel |
| Filters `{{ price \| currency }}` | Removed. Call a function or computed | Twig filters are unaffected; only Vue's |
| Component `v-model` = `value` prop + `input` event; `.sync` | `modelValue` + `update:modelValue`; `v-model:title` replaces `.sync` | Custom inputs need prop/event renames |
| `$listeners` | Merged into `$attrs`; `$attrs` now includes `class` and `style` | Wrapper components double-apply classes |
| `.native` modifier | Removed; declare `emits` | Undeclared events fall through to the root element |
| `<transition>` classes `v-enter`, `v-leave` | `v-enter-from`, `v-leave-from` | CSS-only; grep for it |
| `v-if` + `v-for` on one element: `v-for` won | `v-if` wins | Move the `v-if` to a wrapper or computed |
| `keyCode` modifiers `@keyup.13` | Removed; use key names `@keyup.enter` | |
| `beforeDestroy` / `destroyed` | `beforeUnmount` / `unmounted` | Rename only |
| `$set`, `$delete`, `Vue.set` | Removed; Proxy reactivity tracks additions | Delete the calls |
| `$children` | Removed; template refs | |
| Async component `() => import()` | `defineAsyncComponent(() => import())` | |
| Watching an array fires on mutation | Fires on replacement only unless `deep: true` | Silent behaviour change |
| `<TransitionGroup>` rendered a `<span>` | No wrapper unless `tag` set | Layout shifts |
| `is` on any element (`<tr is="row">`) | Only on `<component>`; in-DOM use `is="vue:row"` | Matters for in-DOM Twig templates |

## Removing the migration build

1. Global `MODE: 3`, zero compat warnings across a full click-through of every page
   type.
2. Remove the `vue` alias and uninstall `@vue/compat`.
3. **Landmine:** `@vue/compat` resolves to a **full** build (template compiler
   included); plain `vue` resolves to the **runtime-only** build. Islands whose template
   is Twig-rendered HTML go blank the moment compat is removed. If you still rely on
   in-DOM templates, alias `vue` to `vue/dist/vue.esm-bundler.js` (vuejs.org, "Note on
   In-Browser Template Compilation") - or finish converting them to SFCs first.
4. Remove the TypeScript `CompatVue` shim and any `compatConfig` options.

## Testing the switch

| Layer | Tool (as of 2026-10-05) | What it proves |
|---|---|---|
| Component | Vitest 5 + `@vue/test-utils` 2.x | Props/events contracts survived the API changes |
| Compat cleanliness | a console spy that fails on Vue warnings | No compat ID is silently still in use |
| Page | Playwright (see `playwright-ops`), one test per Craft page type that mounts an island | Islands mount, hydrate props, respond to input |
| Visual | screenshot diff of those same pages, Vue 2 build vs Vue 3 build | Transition-class and `$attrs` class regressions nobody wrote a test for |

`@vue/test-utils` 1 to 2 (test-utils.vuejs.org/migration): `propsData` becomes
`props`; `createLocalVue` is gone - pass plugins as `global: { plugins: [pinia] }`;
`mocks` and `stubs` move under `global`; `destroy()` becomes `unmount()`;
`findAll().at(0)` becomes `findAll()[0]`.

```js
// vitest.setup.js - make compat leftovers fail loudly
import { beforeEach, afterEach, vi, expect } from 'vitest'
let warn
beforeEach(() => { warn = vi.spyOn(console, 'warn').mockImplementation(() => {}) })
afterEach(() => {
  const vueWarnings = warn.mock.calls.filter(([m]) => String(m).includes('[Vue warn]'))
  expect(vueWarnings).toEqual([])
  warn.mockRestore()
})
```

Build the page-type list from Craft, not from memory: every section/entry type whose
template renders an island element is one Playwright target. A Twig grep finds them:

```bash
rg -l "data-vue-island|id=\"app\"|<[a-z]+-[a-z-]+[ >]" templates/
```
