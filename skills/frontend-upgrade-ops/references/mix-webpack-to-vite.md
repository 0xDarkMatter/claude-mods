# Laravel Mix / Webpack to Vite (the bundler side)

The build-tool half of the cutover: what Mix or a hand-rolled `webpack.config.js` was
doing, and the Vite equivalent. The Craft half (plugin, DDEV dev server, Twig tags) is
[craft-vite-twig.md](craft-vite-twig.md). Facts verified as of 2026-10-05.

## Contents

1. [Why move now](#why-move-now)
2. [Translate the Mix API](#translate-the-mix-api)
3. [A vite.config.js for a Craft site](#a-viteconfigjs-for-a-craft-site)
4. [Source rewrites](#source-rewrites)
5. [CSS: Tailwind v3, PostCSS, Sass](#css-tailwind-v3-postcss-sass)
6. [Legacy browser builds](#legacy-browser-builds)
7. [Build output and deploy](#build-output-and-deploy)

## Why move now

| Fact (as of 2026-10-05) | Source |
|---|---|
| "Laravel Mix is a legacy package that is no longer actively maintained." | laravel.com/docs/12.x/mix |
| Last `laravel-mix` release: **6.0.49, 2022-06-09** (webpack 5 underneath) | npm registry |
| Vite current: **Vite 8** (8.0.0 on 2026-03-12, 8.3.2 latest); Node `^20.19.0 \|\| >=22.12.0` | npm registry |
| Vite 8 replaced esbuild + Rollup with Rolldown + Oxc | vite.dev/guide/migration |
| Vite 7.3 still gets important fixes + security patches; 6.4 security only | vite.dev/releases |

Mix is not broken, it is frozen: every webpack, loader and Babel CVE from here on is
yours to work around, and new libraries ship ESM-first. The move is also the gate for
Vue 3 tooling, Tailwind v4's Vite plugin and Vitest.

## Translate the Mix API

Read `webpack.mix.js` line by line; each call maps to one of these.

| Mix call | Vite equivalent | Note |
|---|---|---|
| `mix.js('src/js/app.js', 'js')` | an entry in `build.rolldownOptions.input` | One entry per page bundle; keep the key names stable |
| `.vue()` / `.vue({ version: 2 })` | `@vitejs/plugin-vue` (Vue 3) / `@vitejs/plugin-vue2` (Vue 2.7 only) | plugin-vue2 peers stop at `vite ^7.0.0` - see SKILL.md sequencing |
| `mix.sass(src, out)` | `import './app.scss'` from the JS entry, install `sass-embedded` (or `sass`) | No loader; Vite needs only the compiler package |
| `mix.postCss(src, out, [require('tailwindcss')])` | `postcss.config.js` - auto-applied to all imported CSS | Delete the plugin list from the Mix call |
| `.options({ processCssUrls: false })` | none needed | Vite rewrites relative `url()` and hashes the files |
| `mix.copy()` / `copyDirectory()` | Vite `publicDir`, or keep files in `web/` untouched | craft-vite's docs also mention a copy plugin |
| `.version()` | always on in `vite build` | Hashed names + `.vite/manifest.json` |
| `.extract()` | automatic chunk splitting | Don't hand-split vendors until a bundle report says so |
| `.sourceMaps()` | `build.sourcemap` | |
| `.webpackConfig({ resolve: { alias } })` | `resolve.alias` | |
| `.autoload({ jquery: ['$', 'window.jQuery'] })` | explicit `import $ from 'jquery'; window.$ = window.jQuery = $` in the entry | Vite has no ProvidePlugin |
| `.browserSync()` | Vite HMR + `vite-plugin-restart` reloading on Twig changes | [craft-vite-twig.md](craft-vite-twig.md#hmr-and-twig-reload) |
| `.setPublicPath('web')` | `build.outDir` + `base` | |
| `.babelConfig()` / `.babelrc` | none for modern output | Oxc transforms; Babel survives only inside `@vitejs/plugin-legacy` |
| `process.env.MIX_*` | `import.meta.env.VITE_*` | Rename in `.env` and every deploy environment |

The Laravel team's own Mix-to-Vite steps (github.com/laravel/vite-plugin, `UPGRADE.md`,
"Migrating from Laravel Mix to Vite") are the closest official checklist; skip its Blade
and Inertia items on a Craft site.

## A vite.config.js for a Craft site

Assumes a common Craft layout: sources in `src/`, webroot `web/`, built files in
`web/dist/`. Adjust paths, not shape.

```js
// vite.config.js - ESM. Either set "type": "module" in package.json
// (npm pkg set type="module") or name the file vite.config.mjs.
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'          // omit if no Vue
import ViteRestart from 'vite-plugin-restart'  // full reload on Twig edits

export default defineConfig(({ command }) => ({
  // '' while serving so craft-vite's devServerPublic prefixes paths;
  // '/dist/' in builds because web/dist is served at /dist/.
  base: command === 'serve' ? '' : '/dist/',
  publicDir: false,                 // see "Build output" - opt in deliberately
  build: {
    manifest: true,                 // writes web/dist/.vite/manifest.json
    outDir: 'web/dist',
    emptyOutDir: true,
    rolldownOptions: {              // Vite 8 name; rollupOptions is a deprecated alias
      input: {
        app: 'src/js/app.js',
        // one key per extra page bundle, e.g. checkout: 'src/js/checkout.js'
      },
    },
  },
  plugins: [
    vue(),
    ViteRestart({ reload: ['templates/**/*'] }),
  ],
  resolve: {
    // Absolute path: Vite passes relative alias values through unresolved.
    alias: { '@': fileURLToPath(new URL('./src/js', import.meta.url)) },
  },
  server: {
    // DDEV values live in craft-vite-twig.md - host, port, origin, cors, allowedHosts.
  },
}))
```

## Source rewrites

Do these before the first `vite build`; most failures are one of them.

| Webpack-era code | Vite-era code | Why |
|---|---|---|
| `const x = require('x')` | `import x from 'x'` | Browser source is ESM-only in Vite |
| `module.exports = {...}` in `src/` | `export default {...}` | Same |
| `require.context('./components', true, /\.vue$/)` | `import.meta.glob('./components/**/*.vue', { eager: true })` | Glob import; drop `eager` to lazy-load |
| `import Btn from './Btn'` (a `.vue` file) | `import Btn from './Btn.vue'` | Vite does not guess the `.vue` extension |
| `require(\`./img/${name}.png\`)` | `new URL(\`./img/${name}.png\`, import.meta.url).href` | Static-analysable asset URL |
| `process.env.NODE_ENV === 'production'` | `import.meta.env.PROD` (or `.MODE`) | `process` does not exist in client code |
| `process.env.MIX_API_URL` | `import.meta.env.VITE_API_URL` | Only `VITE_`-prefixed vars reach the client |
| `@import '~bootstrap/scss/bootstrap';` | `@import 'bootstrap/scss/bootstrap';` | `~` is a webpack sass-loader convention |
| `/* webpackChunkName: "x" */` | delete | Ignored; chunk names come from the file |
| `window.Vue = require('vue')` globals | import where used | Globals hide load-order bugs that module scripts expose |

**Never put secrets in `VITE_*` variables** - vite.dev/guide/env-and-mode: they are
inlined into the bundle at build time and readable by anyone.

**CommonJS packages in `node_modules`** are pre-bundled in dev and converted in builds;
your own CJS in `src/` is not. Vite 8 made default-import interop from CJS consistent
(vite.dev/guide/migration); if an old package's default import changes shape after the
upgrade, `legacy.inconsistentCjsInterop: true` is the deprecated stopgap, not the fix.

Find the rewrite sites in one pass:

```bash
rg -n "require\(|require\.context|module\.exports|process\.env|webpackChunkName|@import ['\"]~" src/
rg -n "from ['\"]\.[^'\"]*/[A-Z][A-Za-z]+['\"]" src/   # extensionless component imports
```

## CSS: Tailwind v3, PostCSS, Sass

**Tailwind v3 needs no new plugin.** Vite applies any `postcss.config.js` automatically.

```js
// postcss.config.js  (ESM; rename to .cjs and keep module.exports if you prefer)
export default {
  plugins: { tailwindcss: {}, autoprefixer: {} },
}
```

- Keep `tailwind.config.js`, convert it to `export default` if the package is now
  `"type": "module"`, or rename it `tailwind.config.cjs`.
- `content` must still list `templates/**/*.twig` plus `src/**/*.{js,vue}`. Purge
  misses after the move almost always mean a path that was relative to `webpack.mix.js`.
- Import the CSS from the JS entry (`import '../css/app.css'`) so it lands in the
  manifest; a CSS-only entry also works (`input: { styles: 'src/css/app.css' }`).
- **Do not combine the bundler swap with Tailwind v4.** v3 is frozen at 3.4.19
  (2025-12-10); v4 (current 4.3.3) moves config into CSS and uses `@tailwindcss/vite`.
  It is a separate migration with its own visual diff - see `tailwind-ops`.

**Sass:** install `sass-embedded` (faster) or `sass`; no Vite plugin. Dart Sass warns on
`@import`; silence with `css.preprocessorOptions.scss.silenceDeprecations: ['import']`
only as a stopgap while you move to `@use`.

**`url()` in CSS:** relative paths are resolved, hashed and emitted into `dist/assets/`;
root-absolute paths (`/images/bg.jpg`) are left alone and served from `web/`. Mix copied
referenced files to `/images` and `/fonts`; after the move, check the network panel for
404s on fonts first - they are the usual casualty.

## Legacy browser builds

Decide from analytics, not habit. Vite 8's default `build.target`
(`'baseline-widely-available'`, updated 2026-01-01) is Chrome 111, Firefox 114,
Safari 16.4. Mix builds usually targeted Babel's browserslist defaults, which reached
further back.

If you need older browsers, add `@vitejs/plugin-legacy` (major matches Vite: 8 for
Vite 8, 7 for Vite 7):

```js
import legacy from '@vitejs/plugin-legacy'
// plugins: [ legacy({ targets: ['defaults', 'not IE 11'] }) ]
```

- It emits SystemJS legacy chunks plus a polyfill chunk, loaded through `nomodule`;
  "legacy" means no native ESM dynamic import or `import.meta`.
- Its README says Terser is required for Vite versions before 8.1.4 (`npm add -D terser`).
- Under a strict CSP it needs the inline-script hashes the package exports as
  `cspHashes` - read them from the package, never hard-code.
- craft-vite emits the `nomodule` legacy tags itself once the plugin is present; no Twig
  change.
- `import.meta.env.LEGACY` is `true` only inside legacy chunks.

IE 11 is out of reach either way: Vue 3 dropped it (v3-migration.vuejs.org).

## Build output and deploy

| Concern | Do |
|---|---|
| Where files land | `web/dist/assets/*.{js,css}` + `web/dist/.vite/manifest.json` (Vite 5+ path) |
| Git | ignore `web/dist/`; build in CI or on deploy, never commit hashed files |
| `publicDir` | Vite copies it into `outDir` on every build. Leave it `false` and keep static files in `web/`, or point it at a folder that only holds build-time statics |
| Old Mix output | delete `web/js/`, `web/css/`, `mix-manifest.json` only **after** every template stops referencing them |
| Deploy order | build, upload `dist/`, then switch templates; keep the previous hashed files until any full-page cache (Blitz or a CDN) is cleared, or cached HTML points at deleted files |
| Package scripts | `"dev": "vite"`, `"build": "vite build"`, `"preview"` is not useful behind Craft |
