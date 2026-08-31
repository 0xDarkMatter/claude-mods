---
name: payloadcms-ops
description: "Payload CMS 3 (Next.js-native) architecture - collections, globals, fields, access control, hooks, Local API, storage adapters, and database (Postgres/MongoDB/SQLite). Use for: payload, payloadcms, payload cms, payload 3, collection config, access control, payload hooks, local api, payload fields, multi-tenant payload, payload nextjs, payload s3, payload r2, payloadcms architecture, headless cms typescript."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: typescript-ops, react-ops, api-design-ops, auth-ops
---

# Payload CMS Operations

Authoritative reference for **Payload 3.x** — the Next.js-native, TypeScript-first headless CMS. Payload 3 **installs into a Next.js (App Router) app** and gives you an auto-generated admin panel, REST + GraphQL APIs, a typed Local API, authentication, access control, file storage, and live preview — one open-source TypeScript codebase.

> **Version note (verified against payloadcms.com/docs, 2026-06):** Payload 3 is the **Next.js fullstack framework** — there is no standalone Express server anymore. The config lives at `src/payload.config.ts`; Payload mounts into the Next App Router via the installed `(payload)` route group. Don't ship Payload 2.x "standalone Express app" guidance.

---

## Architecture at a glance

| Piece | What it is |
|-------|-----------|
| **payload.config.ts** | Single source of truth: collections, globals, db adapter, plugins, admin, auth |
| **Collections** | Repeatable document groups (Posts, Users, Media) — the core building block |
| **Globals** | Singletons (one document) — site settings, header/footer nav |
| **Fields** | Compose document shape; also drive admin UI, validation, access |
| **Local API** | Typed, in-process data access (`payload.find(...)`) — no HTTP, runs server-side |
| **REST / GraphQL** | Auto-generated HTTP APIs over the same collections |
| **Database adapter** | `@payloadcms/db-postgres`, `db-mongodb`, or `db-sqlite` |
| **Storage adapter** | Local disk (dev) or S3/R2/etc. for uploads |

### Where it lives in a Next.js app

```
src/
├── payload.config.ts          # the config — collections, globals, db, plugins
├── collections/               # one file per CollectionConfig
│   ├── Users.ts
│   ├── Posts.ts
│   └── Media.ts
├── globals/                   # GlobalConfig files
└── app/
    ├── (payload)/             # Payload's admin + API route group (generated)
    └── (frontend)/            # your Next.js front end — uses the Local API
```

---

## Collections — the core shape

```typescript
import type { CollectionConfig } from 'payload'

export const Posts: CollectionConfig = {
  slug: 'posts',                          // required, URL-safe identifier
  admin: { useAsTitle: 'title', defaultColumns: ['title', 'status'] },
  access: {                               // see access-control reference
    read: () => true,
    create: ({ req }) => Boolean(req.user),
    update: ({ req }) => Boolean(req.user),
    delete: ({ req }) => req.user?.role === 'admin',
  },
  versions: { drafts: true },             // draft/publish + revision history
  hooks: { /* lifecycle — see hooks reference */ },
  fields: [
    { name: 'title', type: 'text', required: true },
    { name: 'slug', type: 'text', unique: true, index: true },
    { name: 'content', type: 'richText' },
    { name: 'author', type: 'relationship', relationTo: 'users' },
  ],
}
```

| Collection property | Purpose |
|---------------------|---------|
| `slug` | Required identifier (and REST/GraphQL route base) |
| `fields` | Required — document shape + UI + validation |
| `access` | Per-operation authorization (read/create/update/delete) |
| `hooks` | Lifecycle entry points (before/after change/read/delete) |
| `admin` | Admin-panel UI (title field, columns, components, groups) |
| `auth` | Turns the collection into an auth collection (e.g. Users) |
| `upload` | Makes it an upload collection (file storage, image sizes) |
| `versions` | Drafts + revision history |

### Globals vs Collections

> *"If your Collection is only ever meant to contain a single Document, consider using a Global instead."*

Globals (`GlobalConfig`) are singletons — site settings, main nav. Same `fields`/`access`/`hooks`/`admin` surface, one document.

---

## Fields (the 80/20)

| Type | Use for |
|------|---------|
| `text`, `textarea`, `number`, `email`, `date`, `checkbox` | Scalars |
| `richText` | Lexical-based rich content |
| `select`, `radio` | Enumerations |
| `relationship` | Link to other collections (`relationTo`, `hasMany`) |
| `upload` | Reference an upload collection (media) |
| `array` | Repeatable sub-field groups |
| `blocks` | Flexible content — choose from defined block types per row |
| `group` | Nested namespaced fields |
| `row`, `collapsible`, `tabs` | Admin layout only (no data nesting except `tabs` with `name`) |
| `json`, `code` | Raw structured/code data |

Every field can carry `access`, `hooks`, `validate`, `admin.condition` (conditional display), and `localized: true` for i18n. See `references/hooks-and-fields.md`.

---

## Access control — least privilege by default

Access functions return `boolean` **or a query constraint** (row-level filtering). They run for Local API, REST, and GraphQL uniformly.

```typescript
access: {
  // boolean: can this user perform the op at all?
  delete: ({ req }) => req.user?.role === 'admin',

  // query constraint: WHICH documents can they read? (row-level)
  read: ({ req }) => {
    if (req.user?.role === 'admin') return true
    return { author: { equals: req.user?.id } }  // only their own
  },
}
```

- **Collection-level** (read/create/update/delete) and **field-level** (`field.access.read/create/update`) both exist — use field-level to hide/lock individual fields.
- **Never bypass access control in custom endpoints.** Use `req` context; don't hand-roll DB calls that skip it.
- The Local API can run with `overrideAccess: true` for trusted server code — use deliberately, not by default.

Full patterns (RBAC, multi-tenant isolation, field-level): `references/access-control.md`.

---

## Hooks — lifecycle entry points

```typescript
hooks: {
  beforeChange: [({ data, req, operation }) => { /* mutate before save */ return data }],
  afterChange:  [({ doc, req, operation }) => { /* side effects: revalidate, notify */ return doc }],
  beforeRead:   [/* ... */],
  afterRead:    [/* shape outgoing doc */],
  beforeDelete: [/* ... */],
  afterDelete:  [/* cleanup */],
}
```

Common use: in `afterChange`, call Next.js `revalidatePath()` / `revalidateTag()` to bust the front-end cache on publish. Since Next.js 16 that is `revalidateTag('posts', 'max')` — the second argument is a cacheLife profile, and the single-argument form is deprecated (on Next 15 it is the only form, and passing two arguments is a TypeScript error). Full hook catalog (collection, field, global, auth hooks) and the version table: `references/hooks-and-fields.md`.

---

## Local API (the Next.js superpower)

In server components / route handlers, fetch data in-process — no HTTP round trip, fully typed:

```typescript
import { getPayload } from 'payload'
import config from '@payload-config'

const payload = await getPayload({ config })

const { docs } = await payload.find({
  collection: 'posts',
  where: { status: { equals: 'published' } },
  depth: 1,             // auto-populate relationships one level deep
  limit: 10,
})
```

`payload.find / findByID / create / update / delete / findGlobal` mirror the REST surface. Access control still applies unless `overrideAccess: true`.

### Caching in Next.js

- Tag Local API reads — `'use cache'` + `cacheTag` on Next 16, `unstable_cache(..., { tags })` on 15 — then invalidate from an `afterChange` hook via `revalidateTag(tag, 'max')`.
- Don't use `updateTag()` in a Payload hook: it is Server-Actions-only, and Payload's REST/GraphQL writes run in a Route Handler where it throws.
- `depth` controls relationship population — keep it low to avoid over-fetching.

---

## Decision tables

### Database adapter

| Choice | Pick when |
|--------|-----------|
| **Postgres** (`db-postgres`) | Relational data, SQL reporting, Vercel Postgres/Neon/Supabase; migrations matter |
| **MongoDB** (`db-mongodb`) | Document-shaped data, flexible schema, existing Mongo infra |
| **SQLite** (`db-sqlite`) | Local/edge, small footprint, simple deploys |

### Storage adapter

| Choice | Pick when |
|--------|-----------|
| Local disk | Dev only — not for serverless (ephemeral FS) |
| S3 / R2 (`@payloadcms/storage-s3`) | Production; put a CDN (CloudFront/Cloudflare) in front; signed URLs for private media; handle 403 on the frontend |

### Multi-tenancy

| Approach | Pick when |
|----------|-----------|
| `@payloadcms/plugin-multi-tenant` | Standard tenant isolation by a tenant field |
| Custom access constraints | Bespoke isolation rules; enforce via row-level `read`/`update` constraints |

---

## Common gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Users see data they shouldn't | `read` access returns `true` (no row filter) | Return a **query constraint** from `read`, not just `true` |
| Local disk uploads vanish on Vercel | Serverless FS is ephemeral | Use S3/R2 storage adapter |
| Stale front-end after publish | Next.js caches the read | `revalidateTag(tag, 'max')` / `revalidatePath` in an `afterChange` hook |
| `updateTag` throws in a hook | It is Server-Actions-only; Payload's API writes run in a Route Handler | Use `revalidateTag(tag, 'max')`, or `{ expire: 0 }` if it must not serve stale |
| S3 signed URL 403s on frontend | URLs expire | Handle 403 gracefully; refresh URL |
| Over-deep relationship fetch | High `depth` populates everything | Keep `depth` minimal; populate explicitly |
| Custom endpoint leaks data | Bypassed access control | Go through Local API with access on; reserve `overrideAccess` for trusted paths |
| Env not validated | Misconfig fails at runtime | Validate env (zod) at boot |
| No real-time collab | Payload has no built-in CRDT | Pair with Liveblocks/Yjs; Payload stays source of truth for final state |

---

## Assets

| File | Use |
|------|-----|
| `assets/collection.config.template.ts` | Heavily commented Payload 3 CollectionConfig starter (access + hooks + fields), with adapt-points marked |

---

## See also

- `typescript-ops` — typing config, generated types (`payload generate:types`)
- `react-ops` — custom admin components, server components consuming the Local API
- `api-design-ops` — REST/GraphQL surface design, pagination, versioning
- `auth-ops` — auth collections, sessions/JWT, RBAC/ABAC patterns behind access control

### Key external resources

- [What is Payload](https://payloadcms.com/docs/getting-started/what-is-payload)
- [Collections](https://payloadcms.com/docs/configuration/collections) · [Fields](https://payloadcms.com/docs/fields/overview)
- [Access control](https://payloadcms.com/docs/access-control/overview)
- [Hooks](https://payloadcms.com/docs/hooks/overview)
- [Local API](https://payloadcms.com/docs/local-api/overview)
- [Database](https://payloadcms.com/docs/database/overview) · [Storage adapters](https://payloadcms.com/docs/upload/storage-adapters)
- [Multi-tenant plugin](https://payloadcms.com/docs/plugins/multi-tenant)
