# JSX / SSR — Server-Rendered HTML from the Same Worker

`hono/jsx` renders JSX to HTML on the server with zero client runtime — the
right tool for server-rendered pages, admin one-pagers, HTML emails, and error
pages living beside an API. This file covers setup, the renderer middleware,
async/streaming components, the escaping rules, and — load-bearing — where the
approach stops scaling.

## Scope guard (read first)

**Don't grow an app-scale SPA in JSX inside an API Worker.** hono/jsx has no
client-side state model, no router, no hydration story worth building on by
hand. The ladder:

| Need | Right tool |
|---|---|
| A few server-rendered pages, emails, error pages | `hono/jsx` (this file) |
| Interactive islands on mostly-static pages | **HonoX** (Hono's file-based meta-framework with islands) or Astro |
| A real SPA | Build it separately, serve via the assets binding (workers-runtime.md) |

If a `hono/jsx` page has accumulated three `hono/jsx/dom` islands and a
hand-rolled data-fetch layer, you're past the ladder's first rung — move it.

## Setup

```jsonc
// tsconfig.json
{ "compilerOptions": { "jsx": "react-jsx", "jsxImportSource": "hono/jsx" } }
```

```tsx
import type { FC, PropsWithChildren } from 'hono/jsx';

const Layout: FC<PropsWithChildren<{ title: string }>> = (props) => (
  <html>
    <head><title>{props.title}</title></head>
    <body>{props.children}</body>
  </html>
);

app.get('/status', (c) => c.html(<Layout title="Status"><h1>All good</h1></Layout>));
```

Components are plain functions returning JSX; `Fragment`, `memo`, and a
server-side `createContext`/`useContext` (for threading e.g. the request's
identity through a layout tree without prop-drilling) all exist.

## The renderer middleware

`hono/jsx-renderer` gives every route in a subtree a shared layout:

```tsx
import { jsxRenderer } from 'hono/jsx-renderer';

app.use('/admin/*', jsxRenderer(({ children }) => (
  <Layout title="Admin">{children}</Layout>
)));

app.get('/admin/users', async (c) => c.render(<UserTable users={await load(c)} />));
```

- `c.render(...)` wraps the page in the nearest registered layout; nested
  `jsxRenderer` calls compose (inner receives `Layout` as a prop to extend).
- Declare the extra `c.render` argument types via the `ContextRenderer`
  interface if you pass per-page props (title, meta) through `c.render`.
- Because it's middleware, the ordering rules from middleware.md apply — the
  renderer must be registered before the routes that call `c.render`.

## Async components and streaming

Components may be `async` and awaited data renders inline — no loader
ceremony. For slow sections, stream the shell first:

```tsx
import { Suspense } from 'hono/jsx';

const SlowReport = async () => <pre>{JSON.stringify(await expensiveQuery())}</pre>;

app.get('/report', (c) =>
  c.html(
    <Layout title="Report">
      <h1>Report</h1>
      <Suspense fallback={<p>crunching…</p>}>
        <SlowReport />
      </Suspense>
    </Layout>,
  ),
);
```

With `Suspense` in the tree, `c.html` streams: the shell (with the fallback)
flushes immediately and the resolved content follows in the same response.
Same caveats as any streamed body (streaming-and-realtime.md): the status line
is committed at first flush, so errors inside a suspended component can't
become a 500 — they surface in the streamed content. Keep failure-prone work
*before* `c.html`, and Suspense for genuinely slow-but-safe sections.

## Escaping — the one security rule

Interpolated values are HTML-escaped automatically; the two escape hatches are
the XSS surface:

```tsx
import { raw } from 'hono/html';

<div>{userInput}</div>                          {/* safe — escaped */}
<div>{raw(trustedPrerenderedHtml)}</div>        {/* raw() = you are the sanitizer */}
<div dangerouslySetInnerHTML={{ __html: x }} /> {/* same contract as raw() */}
```

`raw()` on anything user-influenced is stored XSS. If you must render
user-authored rich text, sanitize server-side first and mark the sanitizer
call site with a comment — the next reader can't tell trusted from untrusted
by looking at the JSX. The `html` tagged-template (`hono/html`) follows the
same rule: interpolations escaped, `raw()` opts out.

## Client-side sprinkle: `hono/jsx/dom`

`hono/jsx/dom` is a small (~3KB) React-compatible runtime (`render`,
`useState`, `useEffect`) for mounting an interactive widget into a
server-rendered page. It shares component syntax with the server side, which
makes it tempting — apply the scope guard: one or two self-contained widgets
(a copy button, a live counter) is the intended dose. Bundling per-page client
entries from the same Worker means a build step anyway, at which point HonoX
(which automates exactly this islands pattern, file-routed) is less machinery
than what you'd hand-roll.

## Where it pays off in an API Worker

- **Error/maintenance pages** for the non-API fallthrough — a branded 503 from
  the Worker when the SPA assets are unavailable.
- **HTML emails** — render the same `FC` components to strings for the mail
  provider; JSX beats string concatenation for nested tables, and escaping is
  handled.
- **Admin/status one-pagers** (`/design`, `/status`) that want zero build
  step and live beside the data they render.
- **OG/social preview *markup*** — but rendering OG *images* is satori/resvg
  territory, not hono/jsx.
