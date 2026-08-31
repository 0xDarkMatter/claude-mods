# The Server/Client Boundary

What `'use client'` actually does, what crosses, and why the serialization error
is the real error. React's own component model is `react-ops`; this is the
Next.js boundary as an operational surface.

Verified against Next.js 16.3.3 docs (React 19), 2026-08-25.

## `'use client'` marks a module graph entry point

Not a component. Not a folder. Once a file carries the directive, **every module
it imports, and every component it renders directly, is in the client bundle** —
whether or not those files repeat the directive.

The exception is the whole design space: components passed *as props* (including
`children`) are not part of that module graph. They are rendered on the server
and handed over as already-rendered output.

```
Server Component tree
  └── <Modal> ............................ 'use client' — bundled, hydrated
        └── {children} = <Cart /> ........ Server Component — rendered on the server,
                                            arrives as RSC payload, never bundled
```

Consequences to design around:

- **Push the directive to the leaf.** A `'use client'` layout drags its whole
  subtree into the browser. Mark the search box, not the nav that contains it.
- **A "client" component still renders on the server first.** It is prerendered
  to HTML, then hydrated. Code that touches `window` at module scope or in the
  render body breaks; put it in an effect or behind a mount check.
- **Directives can be stripped by bundlers.** Library authors must configure the
  build to preserve them (the tsup/esbuild banner pattern) or every consumer
  needs a wrapper.

## What crosses, and what the error really means

Props from server to client are serialized into the **RSC payload**. The
supported set is React's, not JSON's:

| Crosses | Does not cross |
|---|---|
| primitives, plain objects, arrays | class instances |
| `Date`, `Map`, `Set`, TypedArrays, `ArrayBuffer` | functions (except Server Actions) |
| React elements / `children` | Symbols, `WeakMap`/`WeakSet`, `URL` instances |
| Promises (read on the client with `use()`) | anything with methods you intend to call |
| Server Actions (as a reference) | — |

> **The serialization error is a design signal, not an obstacle.** The instinct
> — "make the parent a Client Component so the prop stops crossing" — usually
> makes the bundle worse and the data exposure larger. The right read is: this
> object is not the shape the UI needs. An ORM row is a class instance carrying
> every column; a `Decimal`, a `Buffer`, a Mongoose document all fail for the
> same reason. Project it down to the fields the component renders. That is
> simultaneously the serialization fix, the bundle fix and the data-exposure fix.

## Interleaving patterns

### The `children` slot

```tsx
'use client'
export default function Modal({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false)
  return open ? <div className="modal">{children}</div> : null
}
```

```tsx
// Server Component parent — <Cart /> stays on the server
export default function Page() {
  return <Modal><Cart /></Modal>
}
```

Any prop position works, not just `children`; `header`, `footer`, `sidebar`
slots behave identically. This is the escape hatch for "I need client state
around server-rendered content".

### Context providers

React context does not exist in Server Components. Wrap `{children}`:

```tsx
'use client'
export const ThemeContext = createContext({})
export default function ThemeProvider({ children }: { children: React.ReactNode }) {
  return <ThemeContext.Provider value="dark">{children}</ThemeContext.Provider>
}
```

Render it **as deep in the tree as it can go**. A provider wrapping `<html>`
does not make the tree client-side (children pass through), but it does move the
boundary earlier than necessary and constrains what can be optimised above it.

### Streaming a promise instead of awaiting it

```tsx
// Server: start the work, don't block the shell
export default function Page() {
  const dataPromise = getData()          // no await
  return <Suspense fallback={<Skeleton />}><Client dataPromise={dataPromise} /></Suspense>
}
```

```tsx
'use client'
import { use } from 'react'
export function Client({ dataPromise }: { dataPromise: Promise<Data> }) {
  const data = use(dataPromise)          // suspends here, not in the parent
  return <List data={data} />
}
```

### Third-party components without the directive

A package using `useState` but shipping no `'use client'` errors when rendered
directly from a Server Component. Re-export it through your own client module:

```tsx
'use client'
import { Carousel } from 'acme-carousel'
export default Carousel
```

## Environment poisoning — the silent one

Modules are shared between both graphs, so server code can be imported into the
client by accident. Next.js inlines only `NEXT_PUBLIC_*` variables into the
browser bundle; **every other `process.env.X` becomes an empty string** — no
error, no warning, just a request that fails at runtime with an empty
credential.

```ts
import 'server-only'                     // turn the accident into a build error

export async function getData() {
  return fetch(url, { headers: { authorization: process.env.API_KEY! } })
}
```

`server-only` and its counterpart `client-only` are marker packages; Next.js
handles the imports internally and installing them is optional (do it if your
lint rules object to extraneous deps). Next.js also ships type declarations for
both, which matters under `noUncheckedSideEffectImports`.

`audit-app-router.py` flags both halves of this: `client-secret-env` for the
non-public variable in a client module, `client-imports-server-only` for the
import that will fail the build.

## Where things actually run

| Phase | What happens |
|---|---|
| Server render | Server Components → RSC payload (rendered output, Client Component placeholders + JS references, props passed across) |
| Server render | Client Components prerendered to HTML using that payload |
| First load | HTML paints a non-interactive preview → RSC payload reconciles the trees → JS hydrates |
| Later navigations | RSC payload is prefetched and cached; Client Components render entirely on the client, no server HTML |

Rendering is split per route segment — layouts, pages, and **every parallel
route slot, displayed or not**.

## Checklist for a boundary that stays cheap

- [ ] Is the directive on the smallest interactive leaf, not a layout?
- [ ] Does anything crossing the boundary carry more data than the UI renders?
- [ ] Do server-only modules import `server-only`?
- [ ] Are providers wrapping `{children}` rather than the document?
- [ ] Does any client module reference a non-`NEXT_PUBLIC_` env var?
- [ ] Does a "make this a Client Component" fix exist only to silence a
      serialization error? Reshape the data instead.
