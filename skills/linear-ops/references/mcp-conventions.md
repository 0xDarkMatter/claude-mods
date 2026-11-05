# MCP conventions

Rules shared across Linear's MCP tools. Tags: `[S]` read from the tool schema, `[M]` measured with read-only
probes on one small workspace (2026-11-05), `[D]` Linear's product docs, `[I]` inferred. **Nothing was written
during measurement**, so write behaviour here is `[S]` or `[I]`.

## Contents

- [Surprises worth remembering](#surprises-worth-remembering)
- [Pagination and sorting](#pagination-and-sorting)
- [Date windows](#date-windows)
- [Identifiers](#identifiers)
- [Bad-value matrix](#bad-value-matrix)
- [Upserts](#upserts)
- [The patch argument](#the-patch-argument)
- [Markdown fields](#markdown-fields)
- [Errors](#errors)
- [Blast radius](#blast-radius)

## Surprises worth remembering

- The same parameter behaves differently per tool. An unknown `team` is a silent empty in `list_issues` and
  `list_issue_statuses`, and a hard error in `list_cycles` and `list_issue_labels` `[M]`.
- `query` is ranked and ignores `orderBy` `[M]`.
- Key presence is uneven in default rows `[M]`: `dueDate`, `archivedAt` and `sla*` come back null, while `assignee`,
  `parentId`, `delegate`, `cycleId`, `estimate` and `projectMilestone` are **absent when unset**. With `fields`, a
  requested empty field is `null`, and `id` is always added.
- Two tool descriptions dangle `[S]`: `prepare_file_upload` names `submit_diff_evidence`, which doesn't exist, and
  `delete_comment` says to resolve the thread, though no tool resolves issue comment threads.

## Pagination and sorting

Standard list parameters, wherever a table says "std list params":

| Param | Type | Default | Notes |
|---|---|---|---|
| `limit` | number | 50 | Max 250. Over it: `limit: Too big: expected number to be <=250` `[M]`. `list_projects` max is **50** `[S][M]` |
| `cursor` | string | none | From the previous response, when `hasNextPage` is true |
| `orderBy` | `createdAt`, `updatedAt` | `updatedAt` | Descending `[M]`. Ignored with `query` on `list_issues` `[M]` |
| `includeArchived` | boolean | false | Only on tools listing it |
| `createdAt`, `updatedAt` | string | none | "After" filters, implemented as `gte` `[M]`. No tool has a "before" bound `[S]` |

Envelope `[M]`: `{"<plural>":[...],"hasNextPage":bool,"cursor":"..."}`. `cursor` is **omitted** on the last page, not
null. Keys are `issues`, `teams`, `users`, `projects`, `documents`, `comments`, `labels`, `customViews`, `customers`,
`customerNeeds`, `releases`, `releasePipelines`, `releaseNotes`, `diffs`, `notifications`, `statusUpdates`,
`initiatives`, `agentSkills`. `get_diff_threads` uses `threads` plus `drafts`.

Not paginated `[M]`: `list_issue_statuses` and `list_cycles` return a bare array, `list_milestones` returns
`{"milestones":[...]}`, and `list_templates` returns `{"templates":[...]}`.

Cursors `[M]`: usually the UUID of the last row; `get_notifications` uses an opaque one. A malformed cursor is a 400
(`after is not a valid pagination cursor identifier.`). A cursor is **not bound to its filters**: it continues under a
different filter without complaint, so keep filters stable yourself.

## Date windows

| Value | Result `[M]` |
|---|---|
| `-P1D`, `-P30D` | Accepted, relative to now |
| `2026-10-22` | Accepted |
| `P30D` | Accepted and **returns empty** (`[I]` read as a future instant) |
| `last week` | 400: `Expected type "DateTimeOrDuration"` |

For a bounded window, filter client-side.

## Identifiers

| Entity | Accepted `[S]` | Measured `[M]` |
|---|---|---|
| Issue | ID or identifier (`ENG-123`) | UUID yes, lowercase `eng-123` yes, full URL **no**. Nonexistent and malformed give the same 400 |
| Project | Name, ID, identifier (`P-ENG-123`), slug | Identifier yes, name case-insensitive, URL slug suffix yes |
| Initiative | Name, ID, identifier (`I-123`), slug | Error text only |
| Team | UUID, key, name | Key and name case-insensitive |
| User | ID, name, email, `me` | Name, display name and email case-insensitive |
| Milestone | Name or ID, always with `project` | Name case-insensitive |
| Document | ID or slug | `slugId` yes |
| Diff | Review URL, slug, PR ID, `owner/repo#N`, GitHub PR URL | `owner/repo#N`, slug and GitHub URL confirmed |
| Custom view | ID, URL, slug, exact name | Exact name yes |

`list_issues` and `get_issue` report the human identifier as **`id`** and the UUID as **`uuid`** `[M]`; projects
likewise. Other entities' `id` is a UUID. GraphQL `issueBatchUpdate` wants the UUID.

Passing a project identifier to `get_issue` gets a helpful error `[M]`.

## Bad-value matrix

| Param | Tool | An unknown value gives `[M]` |
|---|---|---|
| `team` | `list_issues` | **Silent empty** |
| `state` | `list_issues`, `list_projects` | **Silent empty** |
| `assignee`, `creator`, `delegate` | `list_issues` | **Silent empty** |
| `label`, `cycle` | `list_issues` | **Silent empty** |
| `status` | `list_diffs` | **Silent empty** |
| `team` | `list_issue_statuses` | **Silent `[]`** |
| `project` | `list_issues`, `get_project` | `Could not find project "..."` |
| `parentId` | `list_issues` | `Could not find issue "..." for parentId` |
| `release` | `list_issues` | `Could not find release "..."` |
| `customView` | `list_issues` | `Could not find custom view "..."`, with a hint |
| `teamId` | `list_cycles` | `Could not find team "..." for teamId` |
| `team` | `list_issue_labels` | `Could not find team "..."` |
| `query` | `get_team`, `get_user`, `get_milestone`, `get_initiative` | `Could not find ...` |

`state:"triage"` on a team with triage off is also a silent empty `[M]`.

## Upserts

`id` present means update, absent means create, for every `save_*` tool `[S]`. There is no match-by-name and no
idempotency key, so a retried create can duplicate `[I]`. `save_diff_comment` differs: `commentId` or `draftId` picks
the target.

Beware `id` fields that accept a **name**: `save_project`, `save_initiative`, `save_milestone` and the three label
tools `[S]`. What a name matching nothing does was not tested, so pass a real id from a read.

## The patch argument

On `save_issue`, `save_project`, `save_initiative`, `save_document`, `save_release_note`. Update only, in place of the
full `description` or `content`. 1-50 ops, applied in order, **atomic**: one failure aborts the save. Each anchor must
match the current content **exactly once** `[S]`.

| `op` | Required | Effect |
|---|---|---|
| `replace` | `old_string`, `new_string`; optional `replace_all` | Empty `new_string` deletes |
| `insert_before` | `anchor`, `text` | Include your own separators |
| `insert_after` | `anchor`, `text` | Include your own separators |
| `prepend` | `text` | Start of content |
| `append` | `text` | End of content |
| `replace_range` | `from` (inclusive), `to` (exclusive, stays), `new_string` | `to` must match once after `from` |

Copy anchors from a fresh read: returned Markdown wraps URLs as `[text](<url>)` `[M]`, so text from elsewhere may not
match.

## Markdown fields

Pass literal newlines, do not escape them `[S]`. Mention with `@displayName` `[S]`. Embed files through
`prepare_file_upload`, then paste the returned Markdown `[S]`. Referencing an issue in a description or comment makes
it related automatically `[D]`.

## Errors

| Source | Example `[M]` |
|---|---|
| GraphQL pass-through | `{"error":"invalid_request","message":"Could not find referenced Issue.","status":400,"requestId":"..."}` |
| Server resolver | `Error: Could not find project "..."` |
| Argument validation | `Input validation error: Invalid arguments for tool list_issues: ...` |
| Argument rule | `Error: Provide exactly one of issue, project, or initiative` |

GraphQL errors can name internal models: `get_agent_skill` says `Could not find referenced AiPrompt.`.

## Blast radius

| Severity | Tools |
|---|---|
| Irreversible, external | `merge_diff`, `submit_diff_review` (approval), `update_diff` with `close`, `save_diff_comment` without `draft` |
| Irreversible here, no restore tool | `delete_comment`, `delete_customer`, `delete_diff_comment` |
| Archive per its description, no restore tool | `delete_customer_need`, `delete_status_update` |
| Data loss through overwrite | Full `description` or `content`, `labels` on issue, project or initiative, `setTeams`, `setInitiatives`, `setReleases` |
| Link-only removal | `delete_attachment`: the stored file stays |
| Access change | `share_issue`, `unshare_issue` |
| Possible spend | `save_issue.delegate` to the Linear agent `[D][I]` |
| Notifies people `[I]` | `save_comment`, `save_issue` with `assignee` or mentions, `save_status_update`, `update_diff` review requests |
| Reversible | `retire_*_label`, `restore_*_label` |
| No side effect `[M]` | `get_notifications` does not mark read |

Deprecated `[S]`: `create_attachment`, `create_issue_label`, `create_initiative_label`,
`save_status_update.isDiffHidden`.
