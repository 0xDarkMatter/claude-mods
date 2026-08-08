# Routing and the Request/Response Surface

Router internals, path syntax, matching precedence, and the `c.req` / response
helper surface — the mechanics under every route you write.

## Routers (what Hono picks and why you care)

Hono selects a router automatically (`SmartRouter`):

| Router | Character | When it's used |
|---|---|---|
| `RegExpRouter` | Compiles ALL routes into one regex — fastest match | Default when the route set allows it |
| `TrieRouter` | General tree walk — supports everything | Fallback for patterns RegExpRouter can't compile |
| `LinearRouter` / `PatternRouter` | Fast-register, small | `hono/quick` / `hono/tiny` presets for one-shot environments |

Practical consequences:

- On Workers, routes register per isolate boot; matching happens every request.
  The defaults are right — don't hand-pick a router without a measured reason.
- `hono/tiny` (`PatternRouter`) cuts bundle size when you're near the Workers
  compressed-size limit and have few routes.

## Path syntax

```typescript
app.get('/users/:id', …);                 // named param        c.req.param('id')
app.get('/users/:id/posts/:postId', …);   // multiple params    c.req.param() -> object
app.get('/files/:name{.+\\.png}', …);     // regex-constrained param
app.get('/posts/:date{[0-9]+}/:title', …);// digits-only param
app.get('/api/*', …);                     // wildcard (any depth)
app.get('/about/:lang?', …);              // optional param: /about and /about/en
app.on('PURGE', '/cache', …);             // custom method
app.on(['PUT', 'DELETE'], '/thing', …);   // several methods, one handler
```

Matching rules that surprise people:

- **Registration order wins among equally-matching routes** — the first
  registered match handles the request. `app.get('/*', …)` registered early
  shadows everything after it (handlers don't fall through like middleware).
- A handler matches its exact pattern only; middleware (`app.use`) matches by
  prefix pattern. `app.get('/api')` does not match `/api/`.
- Params are URL-decoded; a `:param` never matches across `/`.

## `c.req` — the request surface

| Accessor | Returns | Notes |
|---|---|---|
| `c.req.param('id')` | `string` | Route params; `c.req.param()` for all as an object |
| `c.req.query('q')` | `string \| undefined` | First value; `c.req.query()` for all |
| `c.req.queries('tag')` | `string[] \| undefined` | Repeated keys (`?tag=a&tag=b`) |
| `c.req.header('x-foo')` | `string \| undefined` | Case-insensitive |
| `await c.req.json<T>()` | `T` | **`T` is a cast, not a check** — validate (errors-validation.md) |
| `await c.req.text()` / `.arrayBuffer()` / `.blob()` | body | Raw body reads — body is consumable once |
| `await c.req.parseBody()` | form fields | `multipart/form-data` + urlencoded; files as `File` |
| `c.req.valid('json')` | validated type | Only after validator middleware |
| `c.req.raw` | `Request` | The real Request — pass to `ASSETS.fetch`, JWT verifiers, anything platform-level |
| `c.req.path` / `c.req.url` / `c.req.method` | strings | `path` excludes query; `url` is absolute |

- **Uploads:** for raw-body uploads read `c.req.raw.body` (a stream) and hand it
  straight to R2 (`bucket.put(key, body)`) — don't buffer whole files through
  `arrayBuffer()` unless you must enforce a byte cap by inspection. Enforce
  content-type against an **allowlist** and cap size before writing.
- The body is a one-shot stream: reading it twice throws. If middleware must
  inspect the body, `c.req.raw.clone()` — and know that clones buffer.

## Responses

| Helper | Produces |
|---|---|
| `c.json(obj, status?)` | `application/json`; status defaults 200 |
| `c.text(s)` / `c.html(s)` | text/plain, text/html |
| `c.body(data, status, headers?)` | raw body — `c.body(null, 204)` for no-content |
| `c.redirect(url, status?)` | 302 default |
| `c.notFound()` | delegates to `app.notFound` handler |
| `new Response(...)` returned directly | fully manual — Hono passes it through |

- Status codes are typed literals (`StatusCode`); a runtime number needs a cast
  (`status as 400`) — accept the cast at the single onError mapping site, not
  scattered through handlers.
- Set response headers with `c.header('x-foo', 'bar')` *before* returning the
  helper, or build a manual `Response`.
- `c.json` serialises with plain `JSON.stringify` — `Date` becomes an ISO
  string, `undefined` fields vanish, `BigInt` throws. Shape rows through a
  presenter function first (one place deciding what leaves the Worker per role,
  rather than serialising DB rows raw).

## Cookies

```typescript
import { getCookie, setCookie, deleteCookie, getSignedCookie, setSignedCookie } from 'hono/cookie';

setCookie(c, 'session_hint', value, {
  httpOnly: true, secure: true, sameSite: 'Strict', path: '/', maxAge: 60 * 60,
});
const v = getCookie(c, 'session_hint');
deleteCookie(c, 'session_hint', { path: '/' });   // path must match the set
```

- Default to `httpOnly + secure + sameSite: 'Strict'`; loosen deliberately.
- `deleteCookie` must repeat the `path` (and `domain`) used at set time or the
  browser keeps the original.
- **A cookie the client can write is a hint, not a fact.** Re-verify authority
  server-side on every request (e.g. an impersonation cookie only takes effect
  when the *verified* identity is an admin — a forged cookie is then inert).
  Signed cookies (`setSignedCookie` with a secret) make tampering detectable,
  but signing doesn't replace the authority check: sign what you must trust
  client-side, re-verify what the server can decide itself.

## HTML / JSX

`hono/jsx` renders server-side JSX (`c.html(<Page/>)`) with zero client
runtime — fine for small server-rendered pages and emails from the same Worker.
For an actual SPA, build it separately and serve via the assets binding
(workers-runtime.md); don't grow a JSX app inside an API Worker past a page or
two. `hono/html` offers a `html` template literal with auto-escaping for
one-off snippets — never string-concatenate HTML with user input.
