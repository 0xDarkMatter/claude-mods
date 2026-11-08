# MCP tools: issues and their metadata

Parameters for issues, comments, statuses, triage, labels and templates. Conventions and tags are in
[mcp-conventions.md](mcp-conventions.md). Tables are `[S]` (tool schema) unless a line says `[M]` (measured).

## Contents

- [list_issues](#list_issues)
- [get_issue](#get_issue)
- [save_issue](#save_issue)
- [Sharing](#sharing)
- [Comments](#comments)
- [Statuses and triage](#statuses-and-triage)
- [Labels](#labels)
- [Templates](#templates)

## list_issues

List and search, including Triage Intelligence suggestions. Std list params with `includeArchived`, plus:

| Param | Type | Notes |
|---|---|---|
| `query` | string | Title or description. Not combinable with `customView` (error `[M]`) |
| `team` | string | Name, key or ID |
| `includeSubTeams` | boolean, default false | Team ID filters already include descendants; this also expands name and key filters |
| `assignee` | string or null | ID, name, email, `me`. `"null"` returned unassigned issues `[M]` |
| `creator` | string | ID, name, email, `me` |
| `delegate` | string | Agent name or ID |
| `state` | string | Type, name (case-insensitive `[M]`) or ID |
| `priority` | number | 0 none, 1 urgent, 2 high, 3 medium, 4 low |
| `label` | string | Name or ID. One only |
| `project` | string | Name, ID, identifier, slug |
| `parentId` | string | Parent identifier. **The way to list sub-issues** |
| `cycle` | string | Name, number, ID |
| `release` | string | ID or slug |
| `customView` | string | Applies saved filters and scope; uses list ordering, not saved display settings |
| `completedAt` | string | Excludes uncompleted issues |
| `triagedAt` | string | Left triage after. Issues still in triage have none; use `state:"triage"` |
| `fields` | enum array | Below |

`fields` values: `id uuid title description projectMilestone priority estimate url gitBranchName createdAt updatedAt
archivedAt completedAt startedAt canceledAt startedTriageAt triagedAt dueDate slaStartedAt slaMediumRiskAt slaHighRiskAt
slaBreachesAt slaType status statusType labels triageIntel createdBy createdById assignee assigneeId delegate delegateId
project projectId parentId team teamId cycleId`.

`attachments documents stateHistory relations customerNeeds releases` are get-only: a validation error here `[M]`.

No milestone or due-date filter exists, and every filter takes one value. Use `fields:["projectMilestone"]` and filter
client-side, or a saved `customView`.

Measured `[M]`:

- Default row: `id`, `uuid`, `title`, `description`, `priority {value,name}`, `url`, `gitBranchName`, dates, `status`,
  `statusType`, `labels` (names), `createdBy`, `createdById`, `project`, `projectId`, `team`, `teamId`.
- Long descriptions cut at about 450-500 characters ending `... (truncated, use get_issue for full description)`, with or
  without `fields`.
- Filters AND together. Default sort is `updatedAt` descending.
- `query` with an identifier returned exactly that issue. A real word plus a nonsense word still returned hits, so it is
  **not AND across terms**. A phrase present only in a comment did not surface in the top results.
- `state` matches a name or a type; a type returns any state of that type. A custom state named like a type was not tested.
- `creator:"me"` worked. `assignee:"me"` returned empty on a user with no assigned issues, so a positive match is unproven.

## get_issue

| Param | Type | Req | Notes |
|---|---|---|---|
| `id` | string | yes | Identifier or UUID, not a URL |
| `fields` | enum array | no | List values plus the get-only ones. Nonempty overrides include flags |
| `includeRelations`, `includeCustomerNeeds`, `includeReleases` | boolean | no | Default false |

Adds to a list row `[M]`: full `description`, `attachments[] {id,title,subtitle,url}`, `documents`,
`stateHistory[] {state:{id,name,type},startedAt,endedAt}`. When requested:
`relations {blocks:[{id,title}],blockedBy:[],relatedTo:[],duplicateOf:null}`. There is no children or comments field.

## save_issue

Create requires `team`, and `title` unless `template`.

| Param | Type | Notes |
|---|---|---|
| `id` | string | Only for updating |
| `team` | string | Required on create. A team change blocks `addLabels` and `removeLabels`, and has side effects (see [concepts.md](concepts.md)) |
| `title` | string | |
| `description` | string | Full replace. Use `patch` for edits |
| `patch` | op array | See [mcp-conventions.md](mcp-conventions.md) |
| `template` | string | Create only. A `description` replaces the template body, empty keeps it; labels merge |
| `state` | string | Type, name or ID |
| `priority` | number | 0-4 |
| `assignee` | string or null | **Not `assigneeId`**. Null removes |
| `delegate` | string or null | Agent. `Linear` is the Linear app user, and may start billed work |
| `estimate` | number or null | Omit leaves unchanged, null clears. 0 only on teams allowing zero. T-shirt teams still write point numbers `[I]` |
| `dueDate` | string or null | Null removes on update |
| `labels` | string array | **Replaces the whole set**. Not combinable with add or remove |
| `addLabels`, `removeLabels` | string arrays | Append, or remove on update |
| `project` | string or null | Null removes |
| `milestone` | string | Name or ID. No null form, so clearing it isn't described |
| `cycle` | string or null | Null removes |
| `parentId` | string or null | Null removes. Sub-issues inherit the parent's project when eligible `[D]` |
| `blocks`, `blockedBy`, `relatedTo` | string arrays | **Append-only** |
| `removeBlocks`, `removeBlockedBy`, `removeRelatedTo` | string arrays | The only way to drop relations |
| `duplicateOf` | string or null | Null removes |
| `links` | `[{url,title}]` | Append-only. Remove with `delete_attachment` |
| `addReleases`, `removeReleases`, `setReleases` | string arrays | `setReleases` is exclusive |
| `slaBreachesAt` | date-time or null | Null removes the SLA. Applying an SLA clears the due date `[D]` |
| `slaType` | `all`, `onlyBusinessDays`, null | Only with `slaBreachesAt` |

## Sharing

`share_issue` and `unshare_issue` take `issue` and `user` (both required), and are described for use only when the user
explicitly asks. They grant or remove one workspace user's access to an issue they can't otherwise see. The `user` text
contradicts itself, so use an email or UUID.

## Comments

`list_comments`: exactly one of `issueId`, `projectId`, `initiativeId`, `documentId`, `milestoneId` (UUID),
`statusUpdateId` (UUID). `statusUpdateType` (`project`, `initiative`) only with `statusUpdateId`. Plus `limit`, `cursor`,
`orderBy`.

Row `[M]`: `{id,body,attachments,createdAt,updatedAt,parentId,resolvedAt,quotedText,author:{id,name},onBehalfOf}`. Flat
with `parentId`, not nested. A non-null `quotedText` marks an inline comment. Signed attachment URLs last five minutes;
refetch to renew.

`save_comment`: `id` updates, otherwise creates. `body` required. New thread: one parent as above. Reply: `parentId`.
Parent refs are ignored when `id` or `parentId` is set. A status update holds one thread, so a further comment is a reply.

`delete_comment`: `id` required. Irreversible in this tool set. The root of an inline comment can't be deleted.

## Statuses and triage

| Tool | Params | Notes |
|---|---|---|
| `list_issue_statuses` | `team` (req) | Bare array of `{id,type,name}`, **not in workflow order** `[M]` |
| `get_issue_status` | `id`, `name`, `team` (**all req**) | `{id:"",name:"Done",team:"TEAM"}` works `[M]` |
| `get_triage_responsibility` | `team` (req), `user`, `limit` (1-50, default 10) | Triage off gives `{team,triageEnabled:false,currentUser:null}` `[M]`. Triage-on shape unmeasured |

Triage issues are hidden from views by default `[D]`. List them with `state:"triage"`, after confirming triage is on.

## Labels

| Tool | Params | Notes |
|---|---|---|
| `list_issue_labels` | `name`, `team`, `includeGroups`, `includeArchived`, std paging | Row `{id,name,color,description,archivedAt}` `[M]` |
| `list_project_labels` | same | Workspace labels by default; `team` adds that team's |
| `list_initiative_labels` | `name`, `includeGroups`, `includeArchived`, std paging | No `team` |
| `save_issue_label`, `save_project_label` | `id`, `name` (req on create), `color`, `description` (null clears), `isGroup`, `groupType`, `parent` (null ungroups), `teamId` | Team fixed after create |
| `save_initiative_label` | as above, no `teamId` | |
| `create_issue_label`, `create_initiative_label` | `name` (req), `color`, `description`, `isGroup`, `parent`, `teamId` (issue only) | **Deprecated**: use `save_*` |
| `retire_issue_label`, `retire_project_label`, `retire_initiative_label` | `id` (req) | Reversible. Stays on existing items and blocks new use. Groups cascade to children |
| `restore_issue_label`, `restore_project_label`, `restore_initiative_label` | `id` (req) | A group restore also restores children retired **separately** |

`groupType` is `singleSelect` (default) or `multiSelect`. Groups can't be applied directly. Project labels can share a
name across teams, so check `team` before using an ID. No MCP tool deletes labels, and deleting one in the UI is
irreversible `[D]`.

## Templates

| Tool | Params | Notes |
|---|---|---|
| `list_templates` | `team`, `type` (`issue`, `project`, `document`) | `{"templates":[]}` when none `[M]` |
| `get_template` | `id` (req: ID or name) | Content, applied ids, sub-issues, form fields |

Apply through `save_issue` or `save_project` with `template`. A form template applied this way creates an issue with its
form unanswered.
