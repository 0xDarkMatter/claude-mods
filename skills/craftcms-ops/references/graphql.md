# GraphQL & Headless Craft

Load this for decoupled front ends (Next.js, Nuxt, Astro) or any JSON consumer of Craft
content. Facts checked against the Craft 5 docs on 2026-10-05.

## Contents

- [Endpoint setup](#endpoint-setup)
- [Schemas and tokens](#schemas-and-tokens)
- [Query shape (Craft 5 naming)](#query-shape-craft-5-naming)
- [Config that matters](#config-that-matters)
- [When not to use GraphQL](#when-not-to-use-graphql)

## Endpoint setup

GraphQL is a **Craft Pro** feature (`enableGql`, default on). The endpoint always exists
at its action path, `/actions/graphql/api` (or `/index.php?action=graphql/api`); give it
a clean URL with a route ([GraphQL docs](https://craftcms.com/docs/5.x/development/graphql.html)):

```php
// config/routes.php
return [
    'api' => 'graphql/api',
];
```

Routes are **not evaluated** when `headlessMode` is on - then you must call the action
URL. `headlessMode` also hides section template settings, returns JSON by default, and
switches Twig's default escaping to JS/JSON for front-end requests
([general config](https://craftcms.com/docs/5.x/reference/config/general.html#headlessmode)).

## Schemas and tokens

| Schema | Access |
|--------|--------|
| **Public schema** | One per install, **disabled by default**; serves requests with no token |
| **Private schemas** | Any number; each scoped to sections, entry types, volumes, globals, mutations |

Send a token as `Authorization: Bearer <token>`. An invalid token is a 400-level error;
a request with no token falls back to the public schema if it is enabled. Scope each
schema to exactly what its consumer reads - a token in a browser bundle is public.

## Query shape (Craft 5 naming)

Craft 5 names entry types `{entryTypeHandle}_Entry` - the Craft 3/4 form
`{section}_{type}_Entry` is gone (entry types are global now, so the section prefix
went with it). Nested Matrix entries resolve as their own entry types.

```graphql
query Posts {
  entries(section: "blog", limit: 10, orderBy: "postDate DESC") {
    title
    slug
    url
    ... on article_Entry {
      postDate
      featuredImage { url @transform(handle: "card") }
      author { fullName }
      body {
        ... on richText_Entry { text }
        ... on imageBlock_Entry { image { url alt } }
      }
    }
  }
}
```

The `@transform` directive is opt-in per schema as of Craft 5.9 (and can be killed
globally with `disableGraphqlTransformDirective`). Prefer named transforms so the
front end can't request arbitrary sizes.

## Config that matters

| Setting (`config/general.php`) | Why you touch it |
|--------------------------------|------------------|
| `enableGraphqlCaching` | Default on: caches results per token, invalidated on any element save, structure change, or schema save. Leave on |
| `allowedGraphqlOrigins` | Craft sends `Access-Control-Allow-Origin: *` by default; set an array of origins (or `false`) for private APIs |
| `maxGraphqlComplexity` / `maxGraphqlDepth` / `maxGraphqlResults` / `maxGraphqlBatchSize` | DoS guard rails for public schemas; `0` means unlimited |
| `enableGraphqlIntrospection` | Turn off in production for public schemas if you don't want the schema browsable |
| `gqlTypePrefix` / `prefixGqlRootTypes` | Avoid type-name collisions when stitching Craft into a federated graph |

Settings verified in the [general config reference](https://craftcms.com/docs/5.x/reference/config/general.html#graphql).

**Static front ends:** the GraphQL cache is per query+token, not per page. A
Next.js/Astro build that fetches at build time should rebuild on a webhook from Craft
(entry save) rather than polling. SEO meta for headless sites: SEOmatic exposes its meta
containers over GraphQL - see [seomatic.md](seomatic.md).

## When not to use GraphQL

| Situation | Use instead |
|-----------|-------------|
| A server-rendered Twig site | Nothing - Twig queries elements directly |
| A handful of fixed JSON endpoints | The first-party **Element API** plugin (`craftcms/element-api`) |
| Craft Solo / Team edition | GraphQL needs Pro; use Element API or a controller in a module |
| Writes from a public form | A controller action with CSRF ([twig-security.md](twig-security.md)), or Formie for forms |
