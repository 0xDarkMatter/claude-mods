# Hooks & Fields — deep dive (Payload 3)

Load when wiring lifecycle side effects (cache revalidation, derived data, notifications)
or composing non-trivial field structures (blocks, arrays, conditional/localized fields).

## Hooks

Hooks are arrays of functions run at lifecycle points. They exist at four levels:
**collection**, **field**, **global**, and **auth**.

### Collection hooks

| Hook | Fires | Typical use |
|------|-------|-------------|
| `beforeValidate` | Before validation | Normalize/derive input |
| `beforeChange` | Before create/update write | Mutate `data`, set derived fields |
| `afterChange` | After write | Revalidate cache, send notifications, sync external |
| `beforeRead` | Before a doc is read | Inject query context |
| `afterRead` | After read, before return | Shape outgoing doc, computed fields |
| `beforeDelete` / `afterDelete` | Around deletion | Cascade cleanup, remove files |
| `afterOperation` | After any operation | Generic post-processing |

```typescript
hooks: {
  beforeChange: [
    ({ data, req, operation }) => {
      if (operation === 'create') data.createdBy = req.user?.id
      return data
    },
  ],
  afterChange: [
    async ({ doc, req }) => {
      // bust Next.js cache for this content on publish (Next 16 two-arg form)
      const { revalidateTag } = await import('next/cache')
      revalidateTag(`posts`, 'max')
      return doc
    },
  ],
}
```

### Field hooks

Same `beforeValidate / beforeChange / afterChange / afterRead` lifecycle but scoped to a
single field — use for per-field derivation (e.g. auto-slug from title):

```typescript
{
  name: 'slug',
  type: 'text',
  hooks: {
    beforeValidate: [({ value, data }) =>
      value || data?.title?.toLowerCase().replace(/\s+/g, '-')],
  },
}
```

### Auth hooks

`beforeLogin`, `afterLogin`, `afterLogout`, `afterMe`, `afterRefresh`, `afterForgotPassword`
— hook into the auth collection's session lifecycle.

### Cache-invalidation pattern (the canonical Next.js use)

1. Tag the front-end read: `'use cache'` + `cacheTag('posts')` on Next 16, or
   `unstable_cache(..., { tags: ['posts'] })` on 15 (`unstable_cache` still runs
   on 16, but the docs now point at `use cache`).
2. In the collection's `afterChange` (and `afterDelete`), call
   `revalidateTag('posts', 'max')`.
3. Publish/edit now busts exactly the affected cache entry.

#### Which Next.js major (verified against nextjs.org, Next 16.3.3, 2026-08)

`revalidateTag` takes a **cacheLife profile as a second argument since Next.js 16**.
The single-argument form still runs but is deprecated.

| Next.js | Call | Behaviour |
|---|---|---|
| 16 | `revalidateTag('posts', 'max')` | Stale-while-revalidate — readers are served the old page for up to a year while the rebuild runs. The recommended default. |
| 16 | `revalidateTag('posts', { expire: 0 })` | No stale content; the next request blocks on a fresh fetch. Use when the edit must be visible immediately. |
| 15 | `revalidateTag('posts')` | The only signature 15 has. Passing a second argument is a **TypeScript error** on 15, so don't ship the two-arg form to a 15 app. |

**Do not reach for `updateTag()` here.** It is the Next 16 read-your-own-writes API,
but it can *only* be called from inside a Server Action and throws anywhere else.
Payload mounts its REST and GraphQL surface under a Route Handler, so an
`afterChange` triggered by the admin panel or an API write is not in a Server
Action — `revalidateTag` is the correct call in a Payload hook. `updateTag` only
applies when *your own* Server Action calls the Local API directly.

Payload 3 does not pin a Next.js major, so check the host app's `next` version
before copying either form. The `nextjs-ops` skill carries the full caching model.

## Fields — composition patterns

### Blocks (flexible content)

```typescript
{
  name: 'layout',
  type: 'blocks',
  blocks: [
    {
      slug: 'hero',
      fields: [
        { name: 'heading', type: 'text' },
        { name: 'image', type: 'upload', relationTo: 'media' },
      ],
    },
    {
      slug: 'richText',
      fields: [{ name: 'content', type: 'richText' }],
    },
  ],
}
```

Each row stores a `blockType`; branch on it when rendering. This is Payload's equivalent
of flexible page builders.

### Array fields

```typescript
{
  name: 'features',
  type: 'array',
  minRows: 1,
  fields: [
    { name: 'label', type: 'text' },
    { name: 'icon', type: 'text' },
  ],
}
```

### Conditional display

```typescript
{
  name: 'externalUrl',
  type: 'text',
  admin: { condition: (data) => data.linkType === 'external' },
}
```

### Localization (i18n)

Set `localized: true` on any field; Payload stores per-locale values. Configure `locales`
in `payload.config.ts`. Query a locale via Local API `locale` param.

### Field access & validation

Every field accepts:
- `access: { read, create, update }` — field-level authorization (see access-control.md)
- `validate: (value, { data, req }) => true | 'error message'`
- `defaultValue`, `required`, `unique`, `index`
- `hooks` — field-scoped lifecycle (above)

## Generated types

Run `payload generate:types` after schema changes to produce a typed `payload-types.ts`.
Import the generated interfaces in front-end code so Local API results are fully typed.
