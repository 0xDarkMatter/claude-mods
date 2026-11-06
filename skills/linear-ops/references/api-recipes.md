# GraphQL recipes

Runnable operations for the jobs agents do most, each with the trap that bites first. Every operation here was validated against
the live schema with `linear-gql.py --validate` on 2026-11-05. **Validation proves the shape, not the behaviour**: the writes
were not run. `[R]` marks behaviour reported by a team using these in production and not re-tested here.

## Contents

- [Set up once](#set-up-once)
- [Resolve ids first](#resolve-ids-first)
- [Reads](#reads)
- [Create an issue](#create-an-issue)
- [Update an issue](#update-an-issue)
- [Comment](#comment)
- [Record a dependency](#record-a-dependency)
- [Link source work](#link-source-work)
- [Post a project update](#post-a-project-update)
- [Check the schema without a key](#check-the-schema-without-a-key)
- [Keep the cost down](#keep-the-cost-down)

## Set up once

```bash
G="<skill-dir>/scripts/linear-gql.py"; Q="<skill-dir>/assets/queries"
python "$G" --query-file "$Q/ground.graphql"
```

If you can't use the script, the equivalent is a POST to `https://api.linear.app/graphql` with `Authorization: $LINEAR_API_KEY`, raw
for a personal key. Check `.errors` on every response whatever the status.

## Resolve ids first

Nearly every mutation takes ids, not names. `assets/queries/ground.graphql` gets them in one request. Run it once a session, not once
a write.

- `viewer` is the account every write is attributed to. If it's unexpected, stop.
- Labels are a tree. Use child ids, never a group's.
- `projectStatuses` and `workflowStates` are connections, so they need `first` and `nodes`.

To find an issue you already know by its exact title, ask for a few and require exactly one. Zero means it's missing; more than one is a
duplicate to resolve before you write anything:

```graphql
query IssueByTitle($team: String!, $title: String!) {
  issues(first: 10, filter: { team: { key: { eq: $team } }, title: { eq: $title } }) {
    nodes { id identifier title state { name } }
  }
}
```

## Reads

```graphql
query MyWork {
  viewer {
    assignedIssues(first: 25, filter: { state: { type: { eq: "started" } } }) {
      nodes { identifier title url state { name } }
    }
  }
}
```

```graphql
query IssueInFull($id: String!) {
  issue(id: $id) {
    identifier title description branchName
    state { name type }
    assignee { name }
    children(first: 50) { nodes { identifier title } }
    relations(first: 20) { nodes { type relatedIssue { identifier title } } }
    comments(first: 50) { nodes { body createdAt user { name } } }
    attachments(first: 20) { nodes { title url } }
  }
}
```

```graphql
query RecentlyChanged($teamKey: String!) {
  issues(first: 50, orderBy: updatedAt, filter: {
    team: { key: { eq: $teamKey } }
    updatedAt: { gt: "-P7D" }
  }) {
    nodes { identifier title updatedAt state { name } }
    pageInfo { hasNextPage endCursor }
  }
}
```

Reading a shared view keeps your report and a human's screen in agreement, unlike a rebuilt filter:

```graphql
query View($id: String!) {
  customView(id: $id) {
    name
    issues(first: 50) { nodes { identifier title state { name } } pageInfo { hasNextPage endCursor } }
  }
}
```

List views with `customViews(first: 50) { nodes { id name } }`. `searchIssues`, limited to 30 requests a minute, is ranked: read the titles.

## Create an issue

`assets/queries/create-issue.graphql`:

```bash
python "$G" --allow-mutation --query-file "$Q/create-issue.graphql" --vars '{"input":{"teamId":"<uuid>","title":"Do the thing","description":"...","priority":3}}'
```

- `IssueCreateInput.priority` is an **Int**, while `Issue.priority` reads back as a **Float**, so don't round-trip a read value blindly.
- Omitted `stateId` lands in the team's first Backlog status, or Triage if enabled.
- Writing `ENG-123` in a description auto-adds it as related. Leave it out if you don't want the relation.
- Linear normalises Markdown, so a read won't be byte-identical. Compare meaning.
- `IssueCreateInput.id` takes a client-generated UUID v4, which may make a create retry-safe. What a repeat does is **untested**.

## Update an issue

```graphql
mutation Update($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { identifier state { name } labels(first: 20) { nodes { name } } }
  }
}
```

`labelIds` replaces the set; `addedLabelIds` and `removedLabelIds` change it. Read the current state immediately before writing, because
the later write silently wins. A bulk version is `assets/queries/issue-batch-update.graphql`: UUIDs, 50 at most, and see
[bulk-import-export.md](bulk-import-export.md) first.

## Comment

`assets/queries/comment.graphql`. Show the body to the user first. Check `success`, then open the returned URL. To reply in a thread, add
`parentId` to the input.

A personal key attributes the comment to its owner, so sign it as [working-with-agents.md](working-with-agents.md) describes.

## Record a dependency

`assets/queries/relation.graphql`. **`issueId` is the blocker; `relatedIssueId` is the blocked.** Swapped, Linear records a valid relation
pointing the wrong way, and nothing errors `[R]`. State the direction in words before you create it, and read it back. Types are `blocks`,
`duplicate`, `related`, `similar`.

## Link source work

```graphql
mutation LinkUrl($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment { id url title }
  }
}
```

`assets/queries/link-github-pr.graphql` does a PR; `attachmentLinkGitHubIssue` an issue.

**URL plus issue is an idempotency pair**: re-creating updates in place, so a triage run that dies halfway can be rerun safely. To go the other
way, from a URL to its issues:

```graphql
query FromUrl($url: String!) {
  attachmentsForURL(url: $url, first: 5) {
    nodes { title url issue { identifier title } }
  }
}
```

Zero results means no linked issue; one is normal; more than one is a duplicate to resolve, not to pick from.

## Post a project update

`assets/queries/project-update.graphql`. `health` is `onTrack`, `atRisk` or `offTrack`.

- **Milestones have no settable status.** Linear derives what it shows, so state the current milestone in the update text.
- A project's status is an entity: resolve `statusId` from `projectStatuses`. A string fails.
- `ProjectCreateInput` has no repositories field, so put repository URLs in the description.

## Check the schema without a key

Linear answers introspection unauthenticated, within its own 600-an-hour per-IP budget:

```bash
python "$G" --schema-type IssueRelationCreateInput
```

An operation can be shape-checked the same way. `--validate` sends no credentials and treats the answers as measured on 2026-11-05: `AUTHENTICATION_ERROR`
means the shape is valid, and `GRAPHQL_VALIDATION_FAILED` means it isn't (exit 10). Returned data from a non-introspection operation means a credential got in,
so it exits 1.

```bash
python "$G" --validate --query-file "$Q/relation.graphql"
```

This catches plausible-looking mistakes such as `projectStatuses { id }` (a connection, so it needs `first` and `nodes`) or `issueRelationCreate { relation { id } }`
(the field is `issueRelation`). It can't check permissions or behaviour.

Doing this by hand instead, use `curl -q`, which skips `~/.curlrc`, and never a wrapper that may add a stored credential: a check meant to send
nothing should provably send nothing.

## Keep the cost down

Rule: property 0.1, object 1, a connection multiplies its children by `first`, and an omitted `first` counts as 50 at every level.

```graphql
query Bounded($after: String) {
  issues(first: 25, after: $after, orderBy: updatedAt) {
    nodes {
      id title updatedAt
      comments(first: 5) { nodes { id body createdAt user { id name } } }
      attachments(first: 5) { nodes { id url title } }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

That costs about 509 points by the published formula. The same shape with no page sizes, plus `history`, costs about 12,800 and is rejected outright `[R]`. Read `X-Complexity` on your
first call for the real figure. Order by `updatedAt` to stop early. Filter server-side instead of paging and discarding. Don't poll.
