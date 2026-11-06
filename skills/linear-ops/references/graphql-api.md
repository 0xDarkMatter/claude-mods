# GraphQL API

For field-selective reads, reports, bulk changes and apps. `[O]` Linear's developer docs, `[S]` read from the published schema,
`[M]` measured, `[I]` inferred, `[R]` reported by a team in production and not re-tested here. Seen 2026-11-05.

## Contents

- [Calling it](#calling-it)
- [Errors](#errors)
- [Rate limits and complexity](#rate-limits-and-complexity)
- [Pagination and ordering](#pagination-and-ordering)
- [Filtering](#filtering)
- [Bulk writes](#bulk-writes)
- [Retry-safe writes](#retry-safe-writes)
- [Uploads and file storage](#uploads-and-file-storage)
- [SDK](#sdk)
- [Using linear-gql.py](#using-linear-gqlpy)

## Calling it

Endpoint: `https://api.linear.app/graphql` `[O]`.

```bash
curl -s https://api.linear.app/graphql -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" -d '{"query":"{ viewer { id name } }"}'
```

- **Personal API key: `Authorization: <key>`, no `Bearer`.** OAuth: `Authorization: Bearer <token>` `[O]`.
- Keys can be limited to Read, Write, Admin, Create issues or Create comments, and to specific teams. Admins can disallow member
  keys `[O]`.
- `issue(id:)` and `issueUpdate` accept a UUID or `ENG-123`. `issueBatchUpdate.ids` is **`[UUID!]!`** `[S]`.
- The branch field is `Issue.branchName` `[S]`. MCP calls the same value `gitBranchName`.
- Linear has no versioned API. Breaking changes arrive through `@deprecated`, direct outreach or stubs `[O]`. Check the schema, not
  memory.

## Errors

**HTTP 200 with partial success is normal, so always check `errors`.** Each has `message`, `path` and `extensions` `[O]`. Mutations
also return a `success` boolean: read it `[S]`. Validation failures arrive as HTTP 400 with an `errors` body.

## Rate limits and complexity

| Auth | Requests/hour | Complexity/hour | Scope |
|---|---|---|---|
| API key | 2,500 | 3,000,000 | User |
| OAuth app | 5,000 | 2,000,000 | User or app user |
| Unauthenticated | 600 | 100,000 | IP |

- **The budget is per user, across all of that person's keys** `[O]`. An agent that burns the hour also stops that human's other tools. A one-request-per-item
  pass over a few thousand issues is an hours-long job.
- A single query is capped at **10,000 points**, always rejected above it `[O]`.
- Scoring: property 0.1, object 1, connection multiplies children by `first` (default 50), rounded up `[O]`. So `first: 10` beats the
  default: 50 records of three fields is 66; at 10 it is 14. A worked example is in [api-recipes.md](api-recipes.md).
- Limited: **HTTP 429** with `errors[].extensions.code = RATELIMITED` and `Retry-After` in seconds `[O, docs 2026-11]`. An earlier read of the same page recorded HTTP 400,
  so check the code in the body, not just the status. `linear-gql.py` does.
- Linear's advice is webhooks over polling `[O]`.
- Headers: `X-RateLimit-Requests-Limit|Remaining|Reset`, `X-RateLimit-Endpoint-Requests-Limit|Remaining|Reset`,
  `X-RateLimit-Endpoint-Name`, `X-Complexity`, `X-RateLimit-Complexity-Limit|Remaining|Reset`. Reset is UTC epoch ms `[O]`.
- **`searchIssues`, `searchDocuments`, `searchProjects` and `semanticSearch` are limited to 30 requests per minute** `[S]`, far below
  the hourly budget. `issueSearch` is deprecated in favour of `searchIssues` `[S]`.

## Pagination and ordering

Relay style: `first`/`after`, `last`/`before`, `pageInfo { hasNextPage endCursor }`. Default 50 `[S]`. `orderBy` is `createdAt` (default)
or `updatedAt` `[S]`, and note the MCP default differs (`updatedAt`) `[M]`. Archived records are hidden unless `includeArchived: true`
`[S]`. The maximum `first` isn't stated.

## Filtering

- All fields: `eq`, `neq`, `in`, `nin`. Numbers and dates: `lt`, `lte`, `gt`, `gte`. Optional fields: `null: true|false` `[O]`.
- Strings: `eqIgnoreCase`, `neqIgnoreCase`, `startsWith`, `notStartsWith`, `endsWith`, `notEndsWith`, `contains`, `notContains`,
  `containsIgnoreCase`, `notContainsIgnoreCase` `[O]`.
- AND by default. `IssueFilter` has both `and` and `or` `[S]`.
- Relations nest: `assignee: { email: { eq: "user@example.com" } }`. Many-to-many: a plain filter means at least one; `every` means
  all `[O]`.
- Relative dates are ISO 8601 durations: `P2W` ahead, `-P2W` ago `[O]`.

```graphql
query Urgent($teamKey: String!) {
  issues(first: 25, filter: {
    team: { key: { eq: $teamKey } }
    priority: { lte: 2, neq: 0 }
    state: { type: { nin: ["completed", "canceled", "duplicate"] } }
  }) { nodes { identifier title priority } pageInfo { hasNextPage endCursor } }
}
```

## Bulk writes

- `issueBatchUpdate(ids, input)`: up to 50 UUIDs, one partial input for all `[S]`. Teams report that
  more than 50 fails validation with `arrayMaxSize`, and that trashing an active issue fails with
  "cannot be trashed without being archived" `[R]`: read the error, don't retry.
- `issueBatchCreate(input: {issues})`: atomic, up to 50 `[S]`.
- For more, loop in batches, read `success` and `errors` each time, and honour `Retry-After`. Dry-run the id list with the user first.

`assets/queries/issue-batch-update.graphql` is the template.

## Retry-safe writes

No idempotency-key mechanism is documented. Options `[I]` unless tagged:

- `IssueCreateInput.id` is an optional client-supplied UUID v4 `[S]`, so generating one gives a retry-safe create, assuming a repeat is
  rejected as a conflict. That rejection is **untested**, so check before relying on it.
- `attachmentCreate` and the `attachmentLink*` mutations: URL plus issue id is idempotent; re-creating updates in place `[O]`.
- `customerUpsert` is idempotent by domain `[O]`.

Otherwise, after a timeout, search before retrying.

## Uploads and file storage

1. `fileUpload(contentType, filename, size)` returns `uploadUrl`, `assetUrl`, `headers[]` `[O]`.
2. PUT to `uploadUrl` with `Content-Type`, `Cache-Control: public, max-age=31536000`, plus every returned header. It must come from a
   server, because CSP blocks browsers. A 403 usually means the headers weren't copied `[O]`.
3. Use `assetUrl` in later mutations.

**`https://uploads.linear.app` is private.** Fetch with the same `authorization` header as the API, or set request header
`public-file-urls-expire-in: <seconds>` on the GraphQL call to get signed URLs `[O]`. An image URL or base64 data URI in a Markdown
description is uploaded automatically `[O]`.

## SDK

`@linear/sdk` is generated from the schema. **Its major number moves about weekly** (73.0.0 in January 2026 to 101.1.0 in November
2026 `[M]`), which signals schema churn, not hand-written breaking changes `[I]`. Pin an exact version, and expect the 7-day cooldown
from `rules/supply-chain.md` to apply to each bump. Errors are `LinearError` and `InvalidInputLinearError` with `.errors[].userError`,
`.type` and `.status` `[O]`. Linear's rate-limiting page does advise against leaning on it for heavy reads: when fetching many
entities, "especially if you're using our SDK", write your own GraphQL queries and filter narrowly `[O]`
(`/developers/rate-limiting`). For a one-off script, `linear-gql.py` needs no dependency.

## Using linear-gql.py

| Flag | Effect |
|---|---|
| `--query-file F` or `--query S` | The document |
| `--vars JSON` or `--vars-file F` | Variables |
| `--paginate PATH` | Dotted path to a connection, e.g. `issues` or `team.issues`. The query must declare `$after` and select `pageInfo { hasNextPage endCursor }` |
| `--max-pages N` | Default 20. `meta.truncated` says if more remained |
| `--allow-mutation` | Required for any mutation. No automatic retries, because a retried create can duplicate |
| `--dry-run` | Prints the request shape with no token and no network |
| `--validate` | Sends no credentials and checks the shape against the live schema |
| `--schema-type NAME` | Prints a type's fields through introspection, no credentials |
| `--timeout S` | Per-request timeout |

Stdout is a JSON envelope: `{"data":...,"meta":{...}}`, or `{"error":{"code":...}}`. Stderr carries remaining budget from the headers.
`--endpoint` accepts only `https` on `linear.app` hosts, or loopback for tests, so a token can't leak elsewhere.
