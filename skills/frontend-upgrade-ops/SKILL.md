---
name: frontend-upgrade-ops
description: "Upgrade a server-rendered Craft CMS/Twig front end: Laravel Mix or Webpack to Vite via craft-vite (manifest, DDEV dev server, HMR, Tailwind v3, legacy builds, Twig asset URLs) and Vue 2 to Vue 3 (@vue/compat, Vuex to Pinia, plugin swaps, Vue islands in Twig). Use when a site still has webpack.mix.js, mix-manifest.json or Vue 2, or when deciding if a small Vue widget should become Alpine.js or vanilla JS instead."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "migrate-ops, vue-ops, craftcms-ops, ddev-ops, web-perf-ops, tailwind-ops, playwright-ops, security-ops, package-manager-ops"
---

# Frontend Upgrade Operations

The two front-end upgrades a Craft CMS (or any Twig/PHP) agency keeps meeting: an asset
pipeline still on **Laravel Mix or raw Webpack**, and widgets still on **Vue 2**. Both
are frozen - Mix's last release was 6.0.49 in June 2022 and Laravel calls it "a legacy
package that is no longer actively maintained"; Vue 2 reached end of life on
31 December 2023. This skill is the playbook for moving a server-rendered site to
**Vite 8 + craft-vite** and **Vue 3**, or for deciding that a widget should not be Vue
at all.

> Version facts verified as of 2026-10-05 against npm, Packagist, vite.dev,
> v3-migration.vuejs.org and nystudio107.com/docs/vite. Each reference cites its sources.

## Start here: what does this repo need?

| You find | Do | Read |
|---|---|---|
| `webpack.mix.js`, `mix-manifest.json`, `mix()` in Twig | Replace Mix with Vite + craft-vite | [mix-webpack-to-vite.md](references/mix-webpack-to-vite.md), then [craft-vite-twig.md](references/craft-vite-twig.md) |
| A hand-written `webpack.config.js` | Same move; translate loaders and plugins one by one | [mix-webpack-to-vite.md](references/mix-webpack-to-vite.md) |
| craft-vite already, but the dev server fails behind DDEV | CORS / `allowedHosts` / one port in four places | [craft-vite-twig.md](references/craft-vite-twig.md#troubleshooting) |
| `"vue": "^2` in `package.json` | Decide per widget: migrate or replace (table below) | this file, then [vue2-to-vue3.md](references/vue2-to-vue3.md) |
| Mix **and** Vue 2 | Bundler first, framework second - never one deploy | [Sequencing](#sequencing-both-upgrades) |
| `vuex`, `vue-router` 3, Vue 2-only plugins | Pinia; check every plugin for a Vue 3 path before estimating | [vue-state-and-plugins.md](references/vue-state-and-plugins.md) |
| Vue templates written in Twig (`inline-template`, in-DOM) | Convert to SFC islands; mind the compiler build and template injection | [vue-islands-in-twig.md](references/vue-islands-in-twig.md) |
| Vue 3 + Vite already | Out of scope here - steady-state Vue is `vue-ops`, steady-state Craft is `craftcms-ops` | - |

## Migrate Vue, or replace it?

Most agency Vue 2 code is not an app; it is a handful of widgets. Migrating a widget
that a dozen lines of Alpine would do costs more than replacing it. Decide **per
island**, before estimating the migration.

| The widget is... | Verdict | Why |
|---|---|---|
| Toggle, accordion, tabs, mobile nav, show/hide | **Native HTML or Alpine.js** | `<details>`, `<dialog>`, `popover` cover much of it with zero JS; the rest is a boolean in `x-data` written straight into Twig |
| A form with validation and a submit spinner | **Alpine** + native constraint validation | No component tree, no store; Alpine keeps the markup in Twig where editors expect it |
| A thin wrapper around a framework-free library (slider, date picker, map, lightbox) | **Vanilla JS or Alpine** calling the library directly | The Vue wrapper was the only Vue 2-specific part |
| Renders server data and never changes it | **Delete it; render in Twig** | It's a template, not an app |
| Filtering/sorting a list with derived counts, several child components | **Vue 3** | Computed state and components earn their weight |
| Several islands sharing state (cart, saved items, auth) | **Vue 3 + Pinia** | A shared store across apps is what Vue + Pinia does well |
| Routing inside a section (multi-step tool, dashboard) | **Vue 3** (+ vue-router) | Alpine has no answer for this |
| Built on a Vue 2 UI kit with no Vue 3 release | **Rewrite budget**, Vue 3 or Alpine, decided by the rows above | The kit, not Vue, is the migration |

Rules of thumb for the grey zone: under ~150 lines with one level of state, Alpine
wins; any use of Vuex, a router, or more than two child components, Vue 3 wins. A site
that ends up with both is normal - see the Alpine coexistence rules in
[vue-islands-in-twig.md](references/vue-islands-in-twig.md#coexisting-with-alpine-sprig-and-page-caches).

## Sequencing both upgrades

Each numbered step is a separate deploy with its own parity check. Combining the
bundler swap with the framework swap is the classic mistake: when a page breaks you
cannot tell which change did it.

```
0. Inventory      rg the repo (below); list page types that render JS widgets
1. Vue 2.7.16     if on Vue 2.6 - backports Composition API + <script setup>
2. Mix -> Vite    still on Vue 2: Vite 7.3 + @vitejs/plugin-vue2
                  (plugin-vue2's peer range ends at vite ^7.0.0 as of 2026-10-05;
                   Vite 7.3 still gets important fixes + security patches)
3. Replace        widgets the table above says shouldn't be Vue -> Alpine/vanilla
4. Vuex -> Pinia 2 (optional, still on Vue 2.7; Pinia 3+ dropped Vue 2)
5. Vue 3          @vue/compat on Vite 8 + @vitejs/plugin-vue; burn down warnings
6. Drop compat    then Pinia 4, then remove @vitejs/plugin-legacy if analytics allow
```

No Vue on the site? Steps 1, 3-6 vanish: go straight to Vite 8.

If Vue 2 must die first (a security finding, a hosting rule), the order flips: Vue 3
via `@vue/compat` **on Webpack** is supported by the migration guide, then Vite. It is
the slower path - two configurations of Vue 3 tooling instead of one.

```bash
# Step 0 - inventory in one pass
fd -H "webpack.mix.js|webpack.config.js|mix-manifest.json|vite.config" -E node_modules
jq '{vue:.dependencies.vue, mix:.devDependencies["laravel-mix"], webpack:.devDependencies.webpack, vite:.devDependencies.vite, vuex:.dependencies.vuex}' package.json
rg -n "mix\(|craft\.vite|data-vue-island|inline-template|new Vue\(" templates/ src/ | head -50
```

## Cutover checklist: Mix/Webpack to Vite

Work top to bottom; each line links to the detail.

- [ ] Branch from a green build; record a **parity baseline** - screenshots of every
      page type + the network panel's JS/CSS list on the Mix build, plus lab LCP/CLS/TBT
      for the key templates (median of 5 runs, method in `web-perf-ops`)
- [ ] `npm pkg set type="module"` (or name configs `.mjs`/`.cjs` explicitly)
- [ ] `vite.config.js`: `base`, `build.manifest`, `outDir: web/dist`, entries in
      `build.rolldownOptions.input` ([config](references/mix-webpack-to-vite.md#a-viteconfigjs-for-a-craft-site))
- [ ] Every `webpack.mix.js` call mapped ([translation table](references/mix-webpack-to-vite.md#translate-the-mix-api))
- [ ] Source rewrites: `require`, `require.context`, `.vue` extensions, `process.env`,
      `MIX_` to `VITE_`, Sass `~` imports ([rewrites](references/mix-webpack-to-vite.md#source-rewrites))
- [ ] `postcss.config.js` + `tailwind.config.js` load; `content` globs still find
      `templates/**/*.twig` - **stay on Tailwind v3** for this deploy
- [ ] `composer require nystudio107/craft-vite` (5.x Craft 5, 4.x Craft 4); `config/vite.php`
      with `manifestPath` = `@webroot/dist/.vite/manifest.json`
- [ ] DDEV: the same port in `web_extra_exposed_ports`, `server.port`, `server.origin`,
      `devServerPublic`; `cors` + `allowedHosts` for `.ddev.site`
      ([DDEV](references/craft-vite-twig.md#dev-server-through-ddev))
- [ ] Twig: every `mix()` / hard-coded `/js/`, `/css/` tag replaced with
      `craft.vite.script(...)`; main CSS with `asyncCss = false` unless critical CSS exists
- [ ] Inline scripts that used bundle globals at parse time fixed (module scripts are
      deferred) ([why](references/craft-vite-twig.md#twig-replacing-the-mix-tags))
- [ ] Twig-referenced images resolved via `craft.vite.asset()` or left in `web/`
- [ ] Legacy build: decided from analytics, `@vitejs/plugin-legacy` only if needed
      ([legacy](references/mix-webpack-to-vite.md#legacy-browser-builds))
- [ ] HMR works for CSS + JS; Twig edits reload (`vite-plugin-restart`)
- [ ] `vite build` in CI/deploy; `web/dist/` gitignored; no hashed files committed
- [ ] Parity check against the baseline: every page type, fonts, icons, console clean,
      and the lab metrics - async CSS and `modulepreload` move LCP and CLS
      (`web-perf-ops` has the LCP/CLS fixes)
- [ ] Deploy keeps the previous build until full-page caches are purged
- [ ] Delete `webpack.mix.js`, `mix-manifest.json`, old `web/js` + `web/css`,
      `laravel-mix` and webpack-only devDependencies - in a follow-up commit

## Vue 2 to 3 at a glance

The full workflow, the breaking-change table and testing live in
[vue2-to-vue3.md](references/vue2-to-vue3.md). The shape:

1. Alias `vue` to `@vue/compat`, set `compatConfig: { MODE: 2 }` in `@vitejs/plugin-vue`.
2. Port `new Vue({ el })` to `createApp(...).mount(el)` - per island.
3. Fix compile errors, rename transition classes, upgrade Vuex/router, then runtime
   warnings one compat ID at a time (`compatConfig: { MODE: 3 }` per clean component).
4. Global `MODE: 3`, zero warnings, remove compat.

Three Twig-site landmines worth knowing before you start:

- **`inline-template` is removed** - Twig-authored templates need a scoped slot, a
  `<script type="text/html">` template, or conversion to an SFC island.
- **Removing compat removes the template compiler.** `@vue/compat` resolves to the full
  build, plain `vue` to runtime-only; in-DOM islands go blank unless `vue` is aliased to
  `vue/dist/vue.esm-bundler.js`.
- **In-DOM templates execute `{{ }}` from content** - client-side template injection.
  SFC islands with props avoid it ([security](references/vue-islands-in-twig.md#security-client-side-template-injection)).

## Common gotchas

| Gotcha | Prevention |
|---|---|
| Bundler and framework upgraded in one deploy | Sequencing above; one parity check per step |
| Tailwind v4 "while we're at it" | Separate migration with its own visual diff (`tailwind-ops`) |
| `cors: true` / `allowedHosts: true` copied from a sample | Regex + `.ddev.site`; `true` opens the dev server to DNS rebinding |
| Each island calls `createPinia()` | One exported instance, `app.use(pinia)` everywhere |
| `@vitejs/plugin-vue2` on Vite 8 | Its peer range ends at Vite 7; finish Vue 3 before Vite 8, or stay on Vite 7.3 meanwhile |
| Secrets moved from `MIX_` to `VITE_` vars | `VITE_*` is inlined into public JS - keep secrets server-side |
| Old Mix files deleted in the cutover deploy | Delete in a follow-up once nothing references them |
| Estimating Vue 3 before checking plugins | One Vue 2-only plugin can be the critical path - inventory first |

## Reference files

| File | Contents | Lines |
|---|---|---|
| [references/mix-webpack-to-vite.md](references/mix-webpack-to-vite.md) | Mix API to Vite map, `vite.config.js` for Craft, source rewrites, Tailwind v3/PostCSS/Sass, legacy builds, output | ~200 |
| [references/craft-vite-twig.md](references/craft-vite-twig.md) | craft-vite install + `config/vite.php`, DDEV dev server/HMR, Twig tags, asset URLs, deploy, troubleshooting | ~220 |
| [references/vue2-to-vue3.md](references/vue2-to-vue3.md) | Migration build under Vite, warning burn-down, Twig-relevant breaking changes, removing compat, testing | ~190 |
| [references/vue-state-and-plugins.md](references/vue-state-and-plugins.md) | Vuex to Pinia (2 vs 4), shared store across islands, Vue 2 plugin replacement table | ~170 |
| [references/vue-islands-in-twig.md](references/vue-islands-in-twig.md) | Island bootstrap, props from Twig, in-DOM templates, template injection, Alpine/Sprig/cache coexistence | ~190 |

## Staleness verifier

The versions above move. [`scripts/check-frontend-upgrade-facts.py`](scripts/check-frontend-upgrade-facts.py)
guards them against silent drift; the catalogue is
[`assets/frontend-upgrade-facts.json`](assets/frontend-upgrade-facts.json).

```bash
# Structural (PR CI, no network): every catalogued package/fact is still named in the
# prose, and SKILL.md keeps a dated "as of" note.
python scripts/check-frontend-upgrade-facts.py --offline   # exit 0 consistent, 10 drift

# Live (freshness job, never blocks a PR): npm + Packagist majors vs documented majors.
python scripts/check-frontend-upgrade-facts.py --live      # exit 10 a major moved, 7 unreachable
```

A `--live` drift means the world moved (say, Vite 9 or Pinia 5): re-verify the affected
reference against its cited source, then bump `documented_major` - never just the number.

## See also

| Skill | When to combine |
|---|---|
| `migrate-ops` | Generic upgrade strategy, rollback, codemods, other frameworks |
| `vue-ops` | Steady-state Vue 3: Composition API, Pinia, Vue Router, testing |
| `craftcms-ops` | Steady-state Craft 5: Twig, element queries, Matrix-as-entries |
| `ddev-ops` | DDEV itself: Node pinning and EOL majors, exposed ports and daemons, Mutagen and `node_modules` |
| `web-perf-ops` | Before/after Core Web Vitals for the cutover; LCP/INP/CLS fixes once on Vite |
| `tailwind-ops` | The separate Tailwind v3 to v4 migration |
| `playwright-ops` | Page-type smoke tests for the parity checks |
| `security-ops` | Reviewing in-DOM template injection and `VITE_*` exposure |
| `package-manager-ops` | The install side: one lockfile, `npm ci` in CI and deploy, the Node pin, node-sass to Dart Sass, Bower to npm |
