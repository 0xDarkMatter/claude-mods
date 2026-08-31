/**
 * Payload 3 CollectionConfig starter — copy into src/collections/<Name>.ts and adapt.
 *
 * ADAPT-POINTS are marked with  // ADAPT:
 * Register the export in src/payload.config.ts under `collections: [ ... ]`.
 * After editing schema, run `payload generate:types`.
 *
 * Verified against payloadcms.com/docs (Payload 3.x, Next.js-native). 2026-06.
 */
import type { CollectionConfig } from 'payload'

export const Posts: CollectionConfig = {
  // ADAPT: URL-safe identifier; also the REST/GraphQL route base + relationTo target.
  slug: 'posts',

  admin: {
    useAsTitle: 'title', // ADAPT: which field labels rows in the admin list
    defaultColumns: ['title', 'status', 'updatedAt'],
    group: 'Content', // optional sidebar grouping
  },

  // Draft/publish + revision history. Remove if you don't need drafts.
  versions: { drafts: true },

  /**
   * Access control runs uniformly across Local API, REST, and GraphQL.
   * Return a boolean OR a `where` query constraint (row-level filtering).
   * A `read` returning `true` exposes EVERY row — return a constraint to scope.
   */
  access: {
    read: ({ req }) => {
      if (req.user?.role === 'admin') return true
      if (req.user) return { author: { equals: req.user.id } } // ADAPT: ownership rule
      return { _status: { equals: 'published' } } // anon: published only
    },
    create: ({ req }) => Boolean(req.user),
    update: ({ req }) =>
      req.user?.role === 'admin' ? true : { author: { equals: req.user?.id } },
    delete: ({ req }) => req.user?.role === 'admin', // ADAPT: who may delete
  },

  hooks: {
    beforeChange: [
      ({ data, req, operation }) => {
        if (operation === 'create' && req.user) data.author = req.user.id
        return data
      },
    ],
    afterChange: [
      async ({ doc }) => {
        // Bust the Next.js front-end cache on publish/edit.
        //
        // Next.js 16 signature: revalidateTag(tag, cacheLifeProfile). 'max' gives
        // stale-while-revalidate - readers keep getting the old page while the
        // rebuild runs. Use { expire: 0 } instead when the edit must be visible
        // on the very next request and a blocking revalidate is acceptable.
        //
        // NOT updateTag(): that is Server-Actions-only and throws elsewhere.
        // Payload mounts its REST/GraphQL under a Route Handler, so a hook fired
        // from the admin panel or the REST API is not in a Server Action.
        //
        // On Next.js 15, drop the second argument - the two-arg call is a
        // TypeScript error there (the single-arg form is what 15 ships).
        const { revalidateTag } = await import('next/cache')
        revalidateTag('posts', 'max') // ADAPT: tag your front end reads with
        return doc
      },
    ],
  },

  fields: [
    { name: 'title', type: 'text', required: true },
    {
      name: 'slug',
      type: 'text',
      unique: true,
      index: true,
      hooks: {
        beforeValidate: [
          ({ value, data }) =>
            value || data?.title?.toLowerCase().replace(/\s+/g, '-'),
        ],
      },
    },
    { name: 'content', type: 'richText' },
    {
      name: 'author',
      type: 'relationship',
      relationTo: 'users', // ADAPT: must match your auth collection slug
    },
    // Field-level access: lock a field independent of the document.
    {
      name: 'internalNotes',
      type: 'textarea',
      access: {
        read: ({ req }) => req.user?.role === 'admin',
        update: ({ req }) => req.user?.role === 'admin',
      },
    },
  ],
}
