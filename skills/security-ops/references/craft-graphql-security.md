# Craft GraphQL Security

Schema scoping, tokens, limits, introspection and CORS for Craft's GraphQL API (Craft Pro,
3.3+). Facts verified 2026-10-05 against
https://craftcms.com/docs/5.x/development/graphql.html (GQL below) and
https://craftcms.com/docs/5.x/reference/config/general.html (G5).

## Contents

- Exposure by Default
- Schemas and Scopes
- Tokens
- Limits and Introspection
- CORS and Transforms
- Review Checklist

## Exposure by Default

- Content is not public until you create a schema and a route: "none of your content is
  publicly accessible via GraphQL" by default, and the Public Schema starts disabled (GQL).
- The endpoint itself always answers at `/actions/graphql/api` (or
  `index.php?action=graphql/api`) while `enableGql` is `true` - its default. If the site
  does not use GraphQL, set `enableGql(false)`; an unused endpoint is still attack surface.
- GraphQL does not use CSRF tokens (https://craftcms.com/docs/5.x/development/forms.html).
  Its protection is the bearer token plus the schema's scope, so scoping *is* the access
  control.
- With `devMode` on, GraphQL returns verbose errors (https://craftcms.com/knowledge-base/what-dev-mode-does).

## Schemas and Scopes

- One schema per consumer (website front end, mobile app, partner feed), each scoped to
  exactly the sections, entry types, volumes, globals and categories it reads. Scopes are
  an allow-list; tick nothing "just in case".
- **Public Schema** = what an anonymous request gets when no token is sent. Scope it to
  content that is already public on the website, nothing more.
- **Mutations** belong only on token-protected schemas, never the Public Schema, and only
  for the element types the consumer must write. Users cannot be created, updated or
  deleted through GraphQL at all (GQL).
- **Users and relations**: since Craft 5.11.0, fields that return users (author, uploader)
  need the schema's "Query for users" scope
  (https://github.com/craftcms/cms/releases/tag/5.11.0). Before 5.11, user relations
  leaked user data across schema scope (GHSA-4w9w-3x96-7ghp).
- **Multi-site**: GHSA-3wcr-p33w-528f let an entry mutation's `siteId` bypass the
  schema's site scope (fixed 5.10.11). Scope by site *and* keep Craft current.
- Admins get a Full Schema in the control panel's GraphiQL; it is never exposed via tokens.

## Tokens

- Clients send `Authorization: Bearer <token>`. An invalid token is rejected; no token
  falls back to the Public Schema if it is enabled (GQL).
- Craft generates random 32-character tokens. Revoke by regenerating; tokens can also be
  disabled or given an expiry date (`craft\models\GqlToken`, 3.4+), and
  `php craft graphql/create-token` accepts `--expiry`.
- Tokens live in the database, **not** project config - each environment has its own, and
  a production token should never be copied to a laptop.
- Craft's docs: "Carefully protect tokens for schemas that allow mutations!" A mutation
  token in front-end JavaScript is a public write credential. Keep it server-side (a
  Next/Nuxt server route or a Craft controller that proxies the mutation).
- Read-only tokens shipped to browsers are effectively public: scope them as if anyone
  can read every field they unlock.

## Limits and Introspection

Defaults are unlimited (G5):

| Setting | Default | Suggested start | Why |
|---|---|---|---|
| `maxGraphqlDepth` | `0` (off) | `10`-`15` | deeply nested relations are a cheap DoS |
| `maxGraphqlComplexity` | `0` | tune from real queries | caps total work per query |
| `maxGraphqlResults` | `0` | `100` | caps result sets per query |
| `maxGraphqlBatchSize` | `0` (4.5.5+) | `5`-`10` | batching multiplies the cost of one request |
| `enableGraphqlIntrospection` | `true` | `false` in production | OWASP: disable introspection on publicly accessible environments (https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html) |
| `enableGraphqlCaching` | `true` | `true` | cached per token; purged on element saves |

```php
// config/general.php
->enableGraphqlIntrospection(App::env('CRAFT_ENVIRONMENT') !== 'production')
->maxGraphqlDepth(12)
->maxGraphqlResults(100)
->maxGraphqlBatchSize(5)
```

Introspection stays available in the control panel regardless, so disabling it in
production costs the front-end team nothing.

## CORS and Transforms

- Craft sends `access-control-allow-origin: *` on GraphQL responses by default (GQL).
  `allowedGraphqlOrigins` was deprecated in Craft 4.11.0; on Craft 5.3+ configure
  `craft\filters\Cors` in `config/app.web.php` with the real front-end origins
  (https://docs.craftcms.com/api/v5/craft-filters-cors.html). With a wildcard origin,
  any website can read whatever the Public Schema exposes from a visitor's browser.
- The `@transform` directive generates image transforms on demand. Since Craft 5.9.0 it is
  a per-schema opt-in (`disableGraphqlTransformDirective` is deprecated); Craft's securing
  guide recommends disabling `@transform` and `@parseRefs` on schemas that do not need
  them (https://craftcms.com/knowledge-base/securing-craft). Transforms are both a DoS
  lever and the surface of CVE-2025-32432 (`craft-uploads-assets.md`).

## Review Checklist

```bash
rg -n 'enableGql|Graphql|allowedGraphqlOrigins' config/
# Tokens that reached front-end code (each hit is a credential shipped to browsers)
rg -n -i 'authorization.*bearer|gqlToken|graphql.*token' src/ assets/ resources/ --type js --type ts
```

Schemas and their scopes are reviewed in the control panel (GraphQL > Schemas), or in the
committed project config (its `graphql` key); tokens are not in project config.

- [ ] `enableGql` false when GraphQL is unused
- [ ] Public Schema disabled, or scoped to already-public content with no mutations
- [ ] One least-privilege schema and token per consumer; mutation tokens only server-side
- [ ] Tokens per environment, with expiry where the consumer allows it
- [ ] Depth, results and batch limits set; introspection off in production
- [ ] CORS restricted to known origins; `@transform` and `@parseRefs` off where unused
- [ ] Craft at or above 5.11 (user-relation scope) and the latest patch
