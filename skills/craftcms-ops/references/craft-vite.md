# craft-vite (Front-end Build)

craft-vite (`nystudio107/craft-vite`) connects Craft's Twig to a Vite build: dev-server
URLs with HMR locally, hashed manifest URLs in production. Versions: craft-vite 5 for
Craft 5, 4.x for Craft 4, 1.x for Craft 3 (Packagist, 2026-10-05; Vite itself is at 8.x).
Source for everything below unless noted: [craft-vite docs](https://nystudio107.com/docs/vite/).

## Contents

- [Config (`config/vite.php`)](#config-configvitephp)
- [Twig API](#twig-api)
- [The Vite side](#the-vite-side)
- [Running the dev server in DDEV](#running-the-dev-server-in-ddev)
- [Critical CSS](#critical-css)
- [Legacy builds](#legacy-builds)
- [Moving off Laravel Mix](#moving-off-laravel-mix)

## Config (`config/vite.php`)

```php
use craft\helpers\App;

return [
    'useDevServer' => App::env('CRAFT_ENVIRONMENT') === 'dev',
    // Vite 5+ writes the manifest under .vite/ - the plugin default is still
    // @webroot/dist/manifest.json, so set this or builds 404 every asset.
    'manifestPath' => '@webroot/dist/.vite/manifest.json',
    'devServerPublic' => App::env('PRIMARY_SITE_URL') . ':3000/',
    'serverPublic' => App::env('PRIMARY_SITE_URL') . '/dist/',
    'errorEntry' => '',
    'cacheKeySuffix' => '',
    'devServerInternal' => 'http://localhost:3000/',
    'checkDevServer' => true,
    'includeReactRefreshShim' => false,
    'includeModulePreloadShim' => true,
    'criticalPath' => '@webroot/dist/criticalcss',
    'criticalSuffix' => '_critical.min.css',
];
```

| Key | What it does |
|-----|--------------|
| `useDevServer` | Serve from the Vite dev server (HMR) instead of the manifest |
| `manifestPath` | Where the build's `manifest.json` lives (see the `.vite/` note above) |
| `devServerPublic` / `serverPublic` | Browser-facing URL of the dev server / of built assets |
| `devServerInternal` + `checkDevServer` | PHP-side URL used to check the dev server is up; if it isn't, fall back to the manifest - stops a blank page when nobody ran `npm run dev` |
| `errorEntry` | Entry injected into Twig error pages so HMR works on them (dev only) |
| `criticalPath` / `criticalSuffix` | Where per-template critical CSS files live |

The `.vite/` default mismatch is the number-one "worked locally, unstyled in production"
bug on Vite 5+ upgrades. Alternative fix: set Vite `build.manifest: 'manifest.json'`.

## Twig API

```twig
{# Entry script + its CSS. Second arg asyncCss defaults to TRUE: CSS loads async, so
   without critical CSS you get a flash of unstyled content - pass false then #}
{{ craft.vite.script('src/js/app.ts', false) }}

{# Same, but registered with the view (lands in head/end-of-body like registerJsFile) #}
{% do craft.vite.register('src/js/app.ts', false) %}

{{ craft.vite.asset('src/img/logo.svg') }}      {# URL of a Vite-processed asset #}
{{ craft.vite.inline('@webroot/dist/icons.svg') }}
{{ craft.vite.entry('src/js/app.ts') }}         {# manifest URL, never the dev server #}
{{ craft.vite.includeCriticalCssTags() }}
{% if craft.vite.devServerRunning() %}...{% endif %}
```

Full signature: `script(path, asyncCss = true, scriptTagAttrs = {}, cssTagAttrs = {})`.
`craft.vite.integrity(path)` returns an SRI hash. `<link rel="modulepreload">` tags for
imported chunks are emitted **automatically**; `includeModulePreloadShim` only controls
the polyfill.

## The Vite side

```js
// vite.config.js (minimal, Craft layout: source in src/, output in web/dist)
import { defineConfig } from 'vite';

export default defineConfig(({ command }) => ({
  base: command === 'serve' ? '' : '/dist/',
  build: {
    manifest: true,          // -> web/dist/.vite/manifest.json
    outDir: 'web/dist',
    // Vite 8 bundles with Rolldown: `rollupOptions` is now `rolldownOptions`
    // (old name deprecated). On Vite <= 7 use `rollupOptions`.
    rolldownOptions: { input: { app: 'src/js/app.ts' } },
  },
  server: { host: '0.0.0.0', port: 3000, strictPort: true },
}));
```

Source for the rename: [Vite 8 migration guide](https://vite.dev/guide/migration).
Tailwind plugs in as normal for the Tailwind version in use; make sure its content
sources include `templates/**/*.twig` or classes used only in Twig get purged.

## Running the dev server in DDEV

Expose the port in `.ddev/config.yaml`, then `ddev restart`:

```yaml
web_extra_exposed_ports:
  - name: vite
    container_port: 3000
    http_port: 3000     # pick free host ports if 3000 is taken
    https_port: 3001
```

In `vite.config.js`, point `server.origin` at the DDEV URL (it rewrites asset URLs to
the dev server) and allow the `.ddev.site` origin:

```js
server: {
  host: '0.0.0.0', port: 3000, strictPort: true,
  origin: `${process.env.DDEV_PRIMARY_URL}:3000`,
  cors: { origin: /https?:\/\/([A-Za-z0-9\-\.]+)?(\.ddev\.site)(?::\d+)?$/ },
},
```

In `config/vite.php`: `checkDevServer => true`, `devServerInternal =>
'http://localhost:3000'` (always http, it's container-internal), `devServerPublic =>`
the site URL on port 3000. Run it with `ddev npm run dev`. Sources:
[craft-vite DDEV notes](https://nystudio107.com/docs/vite/#using-ddev),
[DDEV blog: Vite](https://ddev.com/blog/working-with-vite-in-ddev/). More DDEV in
[ddev.md](ddev.md).

## Critical CSS

craft-vite pairs with `rollup-plugin-critical`, which renders pages and writes
above-the-fold CSS per template. `{{ craft.vite.includeCriticalCssTags() }}` (no
argument = the template currently rendering) inlines
`<criticalPath>/<template path>_critical.min.css` - e.g. `about/index_critical.min.css`
for `templates/about/index.twig`. With critical CSS inlined, keep `asyncCss = true` so
the full stylesheet doesn't block render. Regenerate critical CSS whenever layouts
change - stale critical CSS causes layout shift (CLS), not just a flash.

Check `rollup-plugin-critical`'s compatibility with the Vite major you're on before
upgrading Vite (Vite 8 swapped Rollup for Rolldown); pin both together.

## Legacy builds

Add `@vitejs/plugin-legacy` and craft-vite detects the `-legacy` chunks automatically,
emitting module/nomodule pairs plus the Safari 10.1 nomodule fix and the polyfills
chunk. Most agency browser targets no longer need it in 2026 - each legacy bundle is
extra build time and bytes; drop it unless analytics show real traffic from
non-module browsers.

## Moving off Laravel Mix

Laravel Mix is still the most common build tool on older Craft codebases, but its last
release was 6.0.49 in June 2022 (npm, checked 2026-10-05) - effectively unmaintained. There is no official migration
guide; nystudio107's
[Vite + Craft article](https://nystudio107.com/blog/using-vite-js-next-generation-frontend-tooling-with-craft-cms)
covers the target architecture. The practical path:

1. Map each `mix.js()` / `mix.postCss()` call to a Vite `rollupOptions.input` entry.
2. Replace `{{ mix('/css/app.css') }}` (or a manifest-reading macro) with
   `craft.vite.script()` for each entry.
3. Move `public/`-style static copies (`mix.copy`) to Vite's `publicDir` or keep them
   outside the build.
4. Delete `webpack.mix.js` and `mix-manifest.json`; add `web/dist/` to `.gitignore`
   (build in CI/deploy, don't commit artifacts).
5. Compare output in a browser at each breakpoint - PostCSS plugin order and
   autoprefixer targets are the usual sources of visual diffs.
