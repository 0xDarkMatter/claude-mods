# Mounting Vue 3 islands in server-rendered Twig pages

Craft renders the page; Vue owns a few interactive regions ("islands"). This file is
the mounting contract for Vue 3 on that kind of page - most Vue docs assume a
single-page app and get several of these wrong for Twig. Sources: vuejs.org (API,
tooling), v3-migration.vuejs.org, alpinejs.dev. Facts verified as of 2026-10-05.

## Contents

1. [Two island styles](#two-island-styles)
2. [The bootstrap: one entry, many islands](#the-bootstrap-one-entry-many-islands)
3. [Passing data from Twig](#passing-data-from-twig)
4. [In-DOM templates: compiler, delimiters, parsing](#in-dom-templates-compiler-delimiters-parsing)
5. [Security: client-side template injection](#security-client-side-template-injection)
6. [Coexisting with Alpine, Sprig and page caches](#coexisting-with-alpine-sprig-and-page-caches)
7. [Checklist per island](#checklist-per-island)

## Two island styles

| Style | Template lives in | Needs the runtime compiler? | Verdict |
|---|---|---|---|
| **SFC island** | a `.vue` file; Twig renders only an empty mount point + data | No (runtime-only build) | Default. Smaller bundle, HMR works, no injection risk |
| **In-DOM island** | Twig markup inside the mount point, compiled by Vue in the browser | Yes - full build (+~14 kB per vuejs.org) | Legacy pattern; acceptable while migrating, convert over time |

Vue 2 sites often used `inline-template` or in-DOM templates so content editors' markup
stayed in Twig. `inline-template` is gone in Vue 3; in-DOM templates still work but
carry the compiler cost and the security caveat below.

## The bootstrap: one entry, many islands

Register islands by name, discover mount points in the DOM, lazy-load each island's
code so pages only download what they render:

```js
// src/js/islands.js
import { createApp } from 'vue'
import { pinia } from './pinia'        // one shared instance - see vue-state-and-plugins.md

const registry = {
  'site-search':  () => import('./islands/SiteSearch.vue'),
  'mini-cart':    () => import('./islands/MiniCart.vue'),
  'store-finder': () => import('./islands/StoreFinder.vue'),
}

export function mountIslands(root = document) {
  root.querySelectorAll('[data-vue-island]').forEach(async (el) => {
    if (el.__vueApp !== undefined) return   // claimed synchronously: no double mount
    el.__vueApp = null                       // while the import below is in flight
    const load = registry[el.dataset.vueIsland]
    if (!load) return console.warn(`Unknown island "${el.dataset.vueIsland}"`)
    const { default: component } = await load()
    const props = el.dataset.props ? JSON.parse(el.dataset.props) : {}
    const app = createApp(component, props)
    app.use(pinia)
    app.mount(el)
    el.__vueApp = app                  // so a later DOM swap can unmount it
  })
}

mountIslands()
```

```twig
{# templates/_components/site-search.twig #}
<div data-vue-island="site-search"
     data-props="{{ { endpoint: url('api/search'), placeholder: 'Search'|t }|json_encode|e('html_attr') }}">
  {# Optional server-rendered fallback; Vue replaces innerHTML on mount #}
  <form action="{{ url('search') }}"><input name="q" type="search"></form>
</div>
```

Why this shape:

- The `__vueApp` claim is set **before** the `await`, so a second `mountIslands()`
  call (two quick partial-page swaps) skips islands whose code is still loading. Vue 3
  also marks mounted containers with `data-v-app` (v3-migration.vuejs.org, mount
  changes), but only once mounting finishes - too late to guard an async loader.
- Vue 3 renders **inside** the element and replaces its `innerHTML`, so a no-JS
  fallback inside the mount point is free progressive enhancement.
- Each `import()` becomes its own chunk; craft-vite's manifest handling emits the
  preload tags. Keep the `registry` keys identical to the Twig `data-vue-island` values.
- Global registrations are per app in Vue 3. Anything registered with `app.component`,
  `app.directive` or `app.config.globalProperties` must be applied to **each** island's
  app - wrap it in one `installCommon(app)` helper.

## Passing data from Twig

| Data | Method |
|---|---|
| Small props (ids, URLs, labels, flags) | `data-props="{{ obj\|json_encode\|e('html_attr') }}"` + `JSON.parse` |
| Larger payload (entry list, config) | `<script type="application/json" id="store-data">{{ data\|json_encode\|raw }}</script>` read with `JSON.parse(el.textContent)` - **only** for data you control; `json_encode` escapes `/` by default so `</script>` can't close the tag, but check your Twig `json_encode` flags if you changed them |
| Per-user data (cart, login state) on a statically cached page | Fetch it client-side after mount (an action URL or GraphQL), never bake it into HTML that Blitz/a CDN will serve to everyone |
| Translations | Pass the few strings the island needs as props via `\|t`; a full i18n library is rarely worth it for an island |

`e('html_attr')` is the escaping strategy for attribute values; plain `|e` is the HTML
body strategy and is the wrong one inside an attribute.

## In-DOM templates: compiler, delimiters, parsing

If an island's template is Twig-rendered markup (no `template`/`render` on the
component), `app.mount()` uses the container's `innerHTML` as the template - but only
"if the runtime compiler is available" (vuejs.org/api/application). Three consequences:

**1. Alias the full build.** The default `vue` import is runtime-only:

```js
// vite.config.js
resolve: { alias: { vue: 'vue/dist/vue.esm-bundler.js' } }
```

During migration `@vue/compat` already resolves to a full build, which is why in-DOM
islands keep working right up until compat is removed.

**2. Twig and Vue both use `{{ }}`.** Pick one fix per project:

```twig
{# Option A: keep Vue's delimiters, stop Twig parsing the block #}
{% verbatim %}<p>{{ results.length }} results</p>{% endverbatim %}
```

```js
// Option B: change Vue's delimiters - full build only (vuejs.org/api/application)
app.config.compilerOptions.delimiters = ['${', '}']
```

Option B keeps Twig readable but confuses every Vue snippet copied from docs; Option A
is explicit at the site. Don't mix both in one codebase.

**3. The browser parses the HTML before Vue sees it** (in-DOM template caveats):

| Pitfall | Do |
|---|---|
| HTML lowercases attributes and tags | kebab-case: `<search-result :result-count="n">`, never `<SearchResult :resultCount>` |
| Self-closing custom tags are not valid HTML | `<search-result></search-result>` |
| `<table>`, `<ul>`, `<select>` reject unknown children | `<tr is="vue:result-row">` |
| `<template>` without a directive renders as a native element in Vue 3 | Only use `<template>` with `v-if`/`v-for`/`v-slot` |

## Security: client-side template injection

With in-DOM templates **every `{{ }}` inside the mount point is executed by Vue** -
including ones that arrived in content: an entry title, a comment, a search term echoed
back. Twig's auto-escaping does not help; `{{` is not an HTML-special character.

- Never render user-controlled text inside an in-DOM island without `v-pre` on its
  wrapper: `<span v-pre>{{ entry.title }}</span>` (Twig output, Vue skips it).
- Prefer SFC islands with data in props - the template is compiled at build time and
  content never reaches the Vue compiler.
- Changing delimiters (Option B above) narrows but does not remove the risk.

This is the strongest argument for converting in-DOM islands to SFCs during the Vue 3
move rather than after it. See `security-ops` for the wider review.

## Coexisting with Alpine, Sprig and page caches

**Alpine.js on the same page** (common once small widgets move off Vue - see SKILL.md):

- Never let both own one subtree. Mark a Vue mount point inside an Alpine component
  with `x-ignore` (Alpine then skips the whole subtree - alpinejs.dev/directives/ignore).
- Alpine's `@click` and `:class` shorthands are also valid Vue syntax: Alpine markup
  inside an **in-DOM** Vue template gets compiled by Vue. Wrap it in `v-pre`, or move the
  Alpine widget outside the island.

**Partial page updates** (Sprig, htmx, Swup, Turbo): swapped-in HTML is not mounted, and
swapped-out islands leak their apps. Unmount before, remount after:

```js
document.addEventListener('htmx:beforeSwap', (e) => {
  e.detail.target.querySelectorAll('[data-v-app]').forEach((el) => el.__vueApp?.unmount())
})
document.addEventListener('htmx:afterSwap', (e) => mountIslands(e.detail.target))
```

Sprig is built on htmx, so the htmx events apply; for other libraries use their
equivalent before/after-swap hooks.

**Static page caches** (Blitz, CDN): the cached HTML is shared by every visitor. Props
must be visitor-neutral; anything personal loads after mount. A cached page with a
stale hashed script URL is a deploy issue - see craft-vite-twig.md.

## Checklist per island

- [ ] SFC, not in-DOM template (or a dated ticket to convert it)
- [ ] Registered in `registry`; Twig `data-vue-island` value matches
- [ ] Props via `json_encode|e('html_attr')`; no personal data on cached pages
- [ ] Uses the shared Pinia instance if it touches shared state
- [ ] Server-rendered fallback inside the mount point where the island is
      content-critical (search, forms)
- [ ] No user-controlled `{{ }}` reaches the Vue compiler
- [ ] Unmounts/remounts correctly if the page uses Sprig/htmx swaps
- [ ] One Playwright test on a real Craft page that renders it
