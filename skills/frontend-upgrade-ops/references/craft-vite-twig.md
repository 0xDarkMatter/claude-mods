# craft-vite: manifest, DDEV dev server, HMR and Twig

The Craft half of a Mix/Webpack-to-Vite cutover, using nystudio107's craft-vite plugin.
Bundler config lives in [mix-webpack-to-vite.md](mix-webpack-to-vite.md). Primary
sources: nystudio107.com/docs/vite, vite.dev/config/server-options,
docs.ddev.com (Vite integration). Facts verified as of 2026-10-05.

## Contents

1. [Install and versions](#install-and-versions)
2. [config/vite.php](#configvitephp)
3. [One port, four places](#one-port-four-places)
4. [Dev server through DDEV](#dev-server-through-ddev)
5. [HMR and Twig reload](#hmr-and-twig-reload)
6. [Twig: replacing the Mix tags](#twig-replacing-the-mix-tags)
7. [Asset URLs in Twig](#asset-urls-in-twig)
8. [Production, caching, deploy](#production-caching-deploy)
9. [Troubleshooting](#troubleshooting)

## Install and versions

| Craft | craft-vite | Latest (Packagist, 2026-08-01) |
|---|---|---|
| Craft 5 | `^5.0` | 5.0.2 |
| Craft 4 | `^4.0` | 4.0.11 |

```bash
ddev composer require nystudio107/craft-vite:^5.0   # ^4.0 on Craft 4
ddev craft plugin/install vite                       # or Settings > Plugins > Install
ddev npm install -D vite vite-plugin-restart          # + @vitejs/plugin-vue if Vue
```

What it does: in dev it points `<script type="module">` at the Vite dev server; in
production it reads `.vite/manifest.json` and emits hashed `<script>`,
`<link rel="modulepreload">` and CSS tags (plus `nomodule` legacy tags when
`@vitejs/plugin-legacy` is in the build).

## config/vite.php

```php
<?php
// config/vite.php - DDEV-aware. Port 5173 here must match the other three
// places listed under "One port, four places".
use craft\helpers\App;

return [
    'useDevServer'      => App::env('CRAFT_ENVIRONMENT') === 'dev',
    'checkDevServer'    => true,   // fall back to built assets when Vite isn't running
    'devServerInternal' => 'http://localhost:5173',   // seen from inside the web container
    'devServerPublic'   => preg_replace('/:\d+$/', '', App::env('PRIMARY_SITE_URL')) . ':5173',
    'serverPublic'      => App::env('PRIMARY_SITE_URL') . '/dist/',
    'manifestPath'      => '@webroot/dist/.vite/manifest.json',  // Vite 5+ location
    'errorEntry'        => 'src/js/app.js',  // keeps HMR alive on Twig error pages
];
```

- Use whatever environment variable the project already keys on (`CRAFT_ENVIRONMENT`
  on current installs, `ENVIRONMENT` on older ones); the point is that production
  never has `useDevServer` true.
- `checkDevServer` + `devServerInternal` mean a teammate who never ran `npm run dev`
  still gets a working site from the last build instead of a page of 404s.
- Other settings worth knowing: `criticalPath`/`criticalSuffix` (critical CSS),
  `includeModulePreloadShim`, `cacheKeySuffix`.

## One port, four places

The single most common broken setup is a port that disagrees somewhere. craft-vite's
docs use 3000, DDEV's docs use 5173; either works if all four agree.

| # | File | Setting |
|---|---|---|
| 1 | `.ddev/config.yaml` | `web_extra_exposed_ports[].container_port` / `https_port` |
| 2 | `vite.config.js` | `server.port` (+ `strictPort: true`) |
| 3 | `vite.config.js` | `server.origin` |
| 4 | `config/vite.php` | `devServerPublic`, `devServerInternal` |

## Dev server through DDEV

The DDEV side in general (Node version values, the four `web_extra_exposed_ports`
fields, daemons, `node_modules` and Mutagen) is the ddev-ops skill's
`references/frontend-node.md`; this section is the craft-vite wiring on top of it.

```yaml
# .ddev/config.yaml - then `ddev restart`
nodejs_version: "22"          # Vite 8 needs ^20.19 or >=22.12
web_extra_exposed_ports:
  - name: vite
    container_port: 5173
    http_port: 5172
    https_port: 5173
web_extra_daemons:            # optional: start Vite with the project
  - name: vite
    command: bash -c 'npm install && npm run dev -- --host'
    directory: /var/www/html
```

```js
// vite.config.js - server block for DDEV
server: {
  host: '0.0.0.0',            // listen beyond the container's loopback
  port: 5173,
  strictPort: true,           // fail loudly instead of drifting to 5174
  origin: `${process.env.DDEV_PRIMARY_URL_WITHOUT_PORT}:5173`,
  cors: { origin: /https?:\/\/([A-Za-z0-9\-\.]+)?(\.ddev\.site)(?::\d+)?$/ },
  allowedHosts: ['.ddev.site'],
},
```

Why `cors` and `allowedHosts` are not optional any more: since the January 2025
security releases (Vite 6.0.9), `server.cors` defaults to localhost, `127.0.0.1` and
`::1` only, and `server.allowedHosts` admits only `localhost`, `*.localhost` and IP
addresses. A `*.ddev.site` page loading scripts from the dev server trips both. The
allowedHosts check is skipped when Vite itself serves HTTPS, but under DDEV the router
terminates TLS and Vite serves plain HTTP inside the container, so the check applies.

craft-vite's sample config uses `allowedHosts: true`; Vite's docs warn that `true`
exposes your source to DNS-rebinding attacks. A leading-dot entry (`'.ddev.site'`)
admits the domain and all subdomains - prefer it. Same logic for `cors: true`.

`DDEV_PRIMARY_URL_WITHOUT_PORT` (DDEV's documented form) avoids a doubled port when the
router itself runs on a non-default port. These variables exist inside the web
container, so run Vite there (`ddev npm run dev` or the daemon), not on the host.

File watching inside containers on Windows/WSL2 can miss events; `server.watch.usePolling`
fixes it at a real CPU cost - try keeping the project inside the WSL filesystem first.

## HMR and Twig reload

- CSS imported from JS hot-swaps with no page reload.
- Vue SFCs hot-reload in place. In-DOM (Twig-written) Vue templates do not; they
  reload the page.
- Plain JS entries need an explicit accept, per craft-vite's docs:

```js
// src/js/app.js
if (import.meta.hot) { import.meta.hot.accept() }
```

- Twig edits: `vite-plugin-restart` with `reload: ['templates/**/*']` triggers a full
  reload - the BrowserSync replacement. Point the glob at the real templates folder,
  relative to the Vite root.

## Twig: replacing the Mix tags

Find every Mix reference first:

```bash
rg -n "mix\(|mix-manifest|/js/app\.js|/css/app\.css|\?id=" templates/
```

```twig
{# BEFORE - Mix (via a mix() Twig helper or a hand-rolled manifest reader) #}
<link rel="stylesheet" href="{{ mix('/css/app.css') }}">
<script src="{{ mix('/js/app.js') }}" defer></script>

{# AFTER - one tag; CSS comes from the entry's imports #}
{{ craft.vite.script('src/js/app.js', false) }}
```

`craft.vite.script(path, asyncCss = true, scriptAttrs = {}, cssAttrs = {})`:

- The path is the **source** path as written in `input`, not the built filename.
- `asyncCss` defaults to `true`, which loads CSS with `media="print"
  onload="this.media='all'"`. Without critical CSS that is a flash of unstyled
  content, so pass `false` for the main stylesheet until critical CSS exists.
- Page-specific bundles: `{{ craft.vite.register('src/js/checkout.js') }}` inside the
  template that needs it; Craft places the tags in the layout.

**Module scripts are deferred.** `type="module"` executes after HTML parsing, so inline
`<script>` blocks (and `{% js %}` output) that call `$`, `Vue` or other globals the old
bundle defined synchronously now run first and throw. Move that code into a module, or
wrap it in a `DOMContentLoaded` listener (module scripts run before that event fires).
This is the most common "works in Mix, broken in Vite" bug on Twig sites.

## Asset URLs in Twig

| Asset | How to reference it |
|---|---|
| Imported by JS/CSS (`import logo from './logo.svg'`, `url(./bg.jpg)`) | `{{ craft.vite.asset('src/images/logo.svg') }}` - resolved via the manifest |
| In Vite's `public/` dir | `{{ craft.vite.asset('images/x.svg', true) }}` - second arg means "from public" |
| Plain static file already in `web/` | a normal URL (`{{ url('images/x.svg') }}` or a root path); Vite never touches it |
| Craft Assets (uploads) | unchanged - Craft's asset URLs and transforms, not Vite |
| Inline SVG sprite / small file | `{{ craft.vite.inline('@webroot/dist/sprite.svg') }}` |
| A built entry URL (e.g. for a service worker) | `{{ craft.vite.entry('app.js') }}` - manifest only, never the dev server |

In dev, Vite serves processed assets relative to its own origin; craft-vite's documented
fix for broken relative asset paths is a base tag:

```twig
{% if craft.vite.devServerRunning() %}
  <base href="{{ alias('@viteBaseUrl') }}">
{% endif %}
```

Also available: `craft.vite.integrity()` (SRI hash from the manifest),
`craft.vite.includeCriticalCssTags()`, `craft.vite.getCssInlineTags()`.

## Production, caching, deploy

- `vite build` in CI/deploy writes `web/dist/`; the manifest path in `config/vite.php`
  must match (`@webroot/dist/.vite/manifest.json`). A pre-Vite-5 tutorial's
  `dist/manifest.json` is the classic "fine in dev, unstyled in prod" cause.
- Full-page caches (Blitz, a CDN, Cloudflare) hold HTML with the old hashed URLs. Keep
  the previous build's files until the cache is purged, or purge as part of deploy.
- craft-vite caches manifest lookups; clear Craft's data caches on deploy if tags look
  stale.
- Craft Cloud serves build artifacts from its CDN; craft-vite's docs cover
  `CloudHelper::artifactUrl()` for `serverPublic`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dev page unstyled; console shows a CORS error from `:5173` | `server.cors` default (Vite 6.0.9+) | `cors.origin` regex for `.ddev.site` |
| Dev server answers "Blocked request ... host is not allowed" | `server.allowedHosts` | add `'.ddev.site'` |
| Scripts load from `https://site.ddev.site/src/js/app.js` (no port) | `devServerPublic` missing the port, or `base` not `''` in serve | fix config/vite.php; `base: ''` when serving |
| Vite started on 5174 | port busy, `strictPort` off | `strictPort: true`; find the holder |
| HMR websocket fails, page loads | port exposed over http only | `https_port` in `web_extra_exposed_ports`, `ddev restart` |
| Fine in dev, no CSS/JS in production | `manifestPath` wrong, or build didn't run on deploy | `.vite/manifest.json`; check deploy logs |
| Production HTML points at the dev server | `useDevServer` true in prod env | gate on the environment variable |
| `$ is not defined` / `Vue is not defined` from inline scripts | module scripts are deferred | see "Module scripts are deferred" |
| 404 on old hashed files after deploy | full-page cache | purge cache; keep previous build until then |
| Node version errors inside DDEV | `nodejs_version` | set it; `ddev restart --no-cache` or `ddev utility rebuild` |
