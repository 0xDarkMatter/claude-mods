# Server Actions — endpoint model, security, and when not to use one

Verified against Next.js 16.3.3 docs, 2026-08-25.

## What an action is on the wire

`'use server'` tells the compiler to replace the function's implementation in
client bundles with a **reference**: an action ID plus a dispatcher that POSTs
back to the route the action is used on. The implementation never ships. The
*endpoint* does.

So an action is a public HTTP endpoint with a function-call ergonomics wrapper.
Anyone who can send that POST invokes it — no form, no page render, no client
code of yours involved. Treat every action as an untrusted entry point, in the
same way you would treat an unauthenticated `POST /api/...`.

## The response model

When an action triggers an immediate revalidation, Next.js runs the action and
re-renders the current route **inside one HTTP request**. The response carries
both the return value (consumed by `useActionState` or the awaited promise) and
a fresh RSC payload the client commits as a seeded navigation. No follow-up
fetch is needed.

A re-render is included when the action:

- calls `updateTag()` or `revalidatePath()`
- calls `refresh()`
- mutates cookies via `cookies()` (set/delete re-renders automatically)
- calls `redirect()` — which throws a control-flow exception, so **nothing after
  it runs**; put revalidation calls before it

`revalidateTag(tag, profile)` is the deliberate exception: it marks the tag for
background refresh and does **not** re-render in the action response. The change
appears on a later read.

### Sequential dispatch

The client dispatches actions **one at a time**. Three rapid triggers run in
series. `Promise.all` over Server Actions does not parallelise anything — do the
parallel work inside a single action, fetch in parallel from a Server Component,
or use a Route Handler. This is a property of the client dispatcher; server-side
an action is an ordinary async function.

## Security

### What the framework gives you

| Protection | Detail |
|---|---|
| CSRF check | `Origin` compared against `Host` / `X-Forwarded-Host`; mismatches rejected. Proxy/CDN domains need `serverActions.allowedOrigins` |
| Body size limit | 1MB default; raise with `serverActions.bodySizeLimit` |
| Encrypted action IDs | Action references are encrypted at build time |
| Dead code elimination | Unused Server Functions are stripped, so they have no endpoint at all |
| Closure encryption | Variables captured by an inline action are encrypted before reaching the client |

A floor, not a substitute. None of it knows who the caller is.

### What you must do

```ts
'use server'
import { auth } from '@/lib/auth'
import { db } from '@/lib/db'

// ❌ the whole record, including its id, comes from the client
export async function completeItemUnsafe(item: Item) {
  await db.item.update({ where: { id: item.id }, data: { completed: true } })
}

// ✅ take a reference; derive identity from the session; look up by ownership
export async function completeItem(itemId: string) {
  const session = await auth()
  if (!session?.user) return
  const item = await db.item.findFirst({ where: { id: itemId, ownerId: session.user.id } })
  if (!item) return
  await db.item.update({ where: { id: item.id }, data: { completed: true } })
}
```

1. **Authenticate and authorize inside the action.** Rendering a form only for
   admins is not a security boundary. Read auth from cookies/headers — never
   accept a token as a parameter.
2. **A `proxy.ts` matcher is not a gate either.** Actions are POSTs to the route
   they live on, so an excluded path skips proxy for its actions too, and moving
   an action to another route can silently remove coverage.
3. **Schema validation checks shape, not entitlement.** A well-formed `Item`
   object can still name a row the caller does not own. Zod is necessary and
   insufficient.
4. **Constrain return values.** Returns are serialized to the client — shape them
   to what the UI renders, not raw database records.
5. **Escalate for destructive operations.** Elevated session checks or
   re-authentication for deletes, and a loud failure when a check is missed.

With the experimental `authInterrupts` flag you can `throw unauthorized()` /
`forbidden()` from `next/navigation` and let Next.js render `unauthorized.tsx` /
`forbidden.tsx`.

Centralising these guarantees in a Data Access Layer — one module that owns
auth, validation and projection — is what stops the checks drifting apart across
twenty action files.

## Choosing the cache update

| API | Semantics | Reach for it when |
|---|---|---|
| `updateTag(tag)` | Expires the tag; the next read (including this response's re-render) waits for fresh data. **Actions only** | Read-your-own-writes — forms, settings, anything the user expects to see immediately |
| `revalidateTag(tag, profile)` | Stale-while-revalidate against a `cacheLife` profile; no immediate re-render | Shared content that tolerates eventual consistency |
| `revalidatePath(path)` | Invalidate by URL | One route affected, tagging is overkill |
| `refresh()` | Refetch the current route's RSC payload; cache untouched. **Actions only** | The view depends on uncached state the action just changed (a notification count, a live metric) |

None of these throw, so an action can call one and still return a value.
`redirect()` does throw.

## Action or Route Handler?

**Server Action** when: a mutation driven by your own UI, `<form action>` or a
client transition, and you want the re-render in the same round trip.

**Route Handler** when any of these are true:

- it is a GET, or must be cacheable
- a third party calls it (webhooks, mobile clients, cron)
- you need custom status codes, headers, or a streaming/binary response
- you need genuine client-side parallelism (see sequential dispatch above)
- it is a public API surface with a versioned contract

`rest-ops` and `api-design-ops` own the API-design half of that decision.

## Progressive enhancement

`<form action={serverAction}>` submits without JavaScript. Wire state and
pending UI with `useActionState` and `useFormStatus` rather than a bespoke
`useState` dance, so the no-JS path keeps working. React owns those hooks —
`react-ops` for their semantics.

## Configuration

```js
// next.config.js
module.exports = {
  experimental: {
    serverActions: {
      allowedOrigins: ['my-proxy.com', '*.my-proxy.com'],
      bodySizeLimit: '2mb',
    },
  },
}
```

Widening `allowedOrigins` weakens the CSRF check — list exact hosts.

## Deployment: the skew failure

Action IDs are build artifacts. New deployments generate new IDs — **Next.js
rotates them at most every 14 days even when the source is unchanged** — so a
client still running the previous build can invoke an ID the server no longer
knows. It surfaces as
[`Failed to find Server Action`](https://nextjs.org/docs/messages/failed-to-find-server-action).

Mitigations, in order:

- **`NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`** — a stable, base64-encoded AES key
  (16/24/32 bytes; Next.js generates 32) shared across every instance. Without
  it, an action encrypted by one instance cannot be decrypted by another, and
  the error appears even without a deploy.
- **`deploymentId`** — enables version-skew detection so a mismatched client
  gets a hard navigation instead of a broken one.
- **Rolling deployments** rather than abrupt cutovers when users are likely
  mid-mutation.
- **Surface the error as a retry path** in the UI. A refresh recovers the user;
  a stack trace does not.

See [deployment.md](deployment.md) for the multi-instance picture.
