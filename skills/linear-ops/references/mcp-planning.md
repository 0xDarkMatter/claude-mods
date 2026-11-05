# MCP tools: planning objects

Projects, milestones, initiatives, status updates, cycles, documents, customers and releases. Conventions and tags are in
[mcp-conventions.md](mcp-conventions.md). Tables are `[S]` unless marked `[M]`. **Initiatives, customers, releases, cycles
and project labels were empty in the probed workspace**, so their response shapes are unmeasured.

## Contents

- [Projects](#projects)
- [Milestones](#milestones)
- [Initiatives](#initiatives)
- [Status updates](#status-updates)
- [Cycles](#cycles)
- [Documents](#documents)
- [Customers](#customers)
- [Releases](#releases)

## Projects

`list_projects`: **`limit` max 50**. Plus `cursor`, `orderBy`, `includeArchived`, `createdAt`, `updatedAt`, `query` (name),
`team`, `includeSubTeams`, `member`, `state`, `initiative`, `label`, `customView`, `includeMembers`, `includeMilestones`,
`fields`.

`fields` values: `id uuid name summary description url trashed createdAt updatedAt startedAt completedAt canceledAt startDate
startDateResolution targetDate targetDateResolution priority sortOrder labels initiatives lead leadTeam status teams members
milestones`.

Row `[M]`: `id` is `P-ENG-123`, plus `uuid`, `icon`, `color`, `name`, `summary`, truncated `description`, `url`, dates,
`priority {value,name}`, `labels`, `initiatives`, `lead` (**`{}` when unset, not null**), `leadTeam {id,name,key}`,
`status {id,name,type}`, `teams`.

`get_project`: `query` (req), `includeMembers`, `includeMilestones`, `includeResources`, `includeCustomerNeeds`,
`customerNeedsLimit` (1-50, default 10), `customerNeedsCursor`. Adds full `description` and `resourceCount` `[M]`. Customer
needs paginate through `customerNeedsPageInfo {hasNextPage,endCursor}` `[M]`.

`save_project`: create requires `name` and a team through `addTeams` or `setTeams`.

| Param | Notes |
|---|---|
| `id` | Name, ID, identifier, slug |
| `name`, `summary` (max 255), `description`, `patch`, `icon`, `color` | `icon` is a name or `:code:`, not raw Unicode |
| `template` | Create only |
| `state` | Status name, type or ID. Names resolve within the **lead team's** statuses |
| `priority` | 0-4 |
| `lead` | Null removes |
| `leadTeam` | Added to the project's teams if missing. No null form |
| `addTeams`, `removeTeams`, `setTeams` | `setTeams` is exclusive |
| `addInitiatives`, `removeInitiatives`, `setInitiatives` | `setInitiatives` is exclusive |
| `labels` | **Replaces the set**. No add or remove variants |
| `links` | `[{url,title}]`, append-only |
| `startDate`, `targetDate` | ISO or null |
| `startDateResolution`, `targetDateResolution` | `halfYear`, `month`, `quarter`, `year`, or null for exact day. Omitted keeps the current resolution and **snaps the date to it** |

## Milestones

| Tool | Params | Notes |
|---|---|---|
| `list_milestones` | `project` (req) | Not paginated |
| `get_milestone` | `project` (req), `query` (req) | Name or ID |
| `save_milestone` | `project` (**req, even to update**), `id`, `name` (req on create), `description`, `targetDate` (null removes) | `id` accepts a name |

Same data, two shapes `[M]`: `list_milestones` gives numeric `progress` and no null `targetDate`; `list_projects` with
`milestones` gives `progress:"0%"` as a string. No delete tool.

## Initiatives

| Tool | Params |
|---|---|
| `list_initiatives` | Std list params with `includeArchived`, plus `query`, `owner`, `status`, `label`, `leadTeam`, `parentInitiative`, `customView`, `includeProjects`, `includeSubInitiatives`, `fields` |
| `get_initiative` | `query` (req), `includeProjects`, `includeSubInitiatives` |
| `save_initiative` | `id`, `name` (req on create), `summary` (max 255), `description`, `patch`, `icon`, `color`, `priority` 0-4, `status` (Proposed, Planned, Active, Completed, Canceled), `owner` (null removes), `leadTeam` (null removes), `targetDate` (null removes), `labels` (replaces), `parentInitiatives` (appends; no removal parameter) |

`fields` values: `id uuid name summary description url status priority targetDate health createdAt updatedAt owner creator
leadTeam parentInitiatives labels projects subInitiatives`.

## Status updates

| Tool | Params |
|---|---|
| `get_status_updates` | `type` (**req, even with `id`**: `project`, `initiative`), `id`, `project`, `initiative`, `user`, `createdAt`, `updatedAt`, `includeArchived`, `limit`, `cursor`, `orderBy` |
| `save_status_update` | `type` (req), `id`, `body` (req on create, replaces on update), `health` (`onTrack`, `atRisk`, `offTrack`), `project`, `initiative`, `isDiffHidden` (deprecated) |
| `delete_status_update` | `type` (req), `id` (req). Described as delete **(archive)** |

Row `[M]`: `{id,body,health,url,createdAt,updatedAt,editedAt,archivedAt,diffMarkdown,isDiffHidden,user:{id,name},type,project:{id,name}}`.
With `id`, the object comes back bare. On update, `project` and `initiative` are ignored. Only the creator can edit an
update in the product `[D]`.

## Cycles

`list_cycles`: `teamId` (req: name, key or ID), `type` (`current`, `previous`, `next`). Bare array, no pagination `[M]`.
Includes issue and scope histories per its schema, so it may be large. No write tools: set an issue's cycle with
`save_issue {cycle}`, and attach a document with `save_document {cycle,team}`.

## Documents

| Tool | Params |
|---|---|
| `list_documents` | Std list params with `includeArchived`, plus `query`, `creatorId`, `projectId`, `initiativeId`, `teamId` (ID only per its schema), `fields` (`id title content url createdAt updatedAt archivedAt creator updatedBy project initiative team issue`) |
| `get_document` | `id` (req: ID or slug). Full `content` |
| `save_document` | `id`, `title` (req on create), `content`, `patch`, `icon`, `color`, and one parent: `project`, `issue`, `initiative`, `cycle`, `team` |

On create, **exactly one parent**. On update, **passing a parent moves the document**. `cycle` by name or number needs
`team`. List rows truncate `content`. No delete tool.

## Customers

The UI says "customer request"; the API and MCP say `CustomerNeed` `[D]`.

| Tool | Params | Notes |
|---|---|---|
| `list_customers` | Std list params with `includeArchived`, plus `query`, `domain` (exact), `externalIds`, `owner`, `status`, `tier`, `includeNeeds` | |
| `save_customer` | `id`, `name` (req on create), `domains`, `externalIds`, `owner`, `revenue`, `size`, `status`, `tier` | `domains` and `externalIds` **append-only** |
| `delete_customer` | `id` (req) | **Irreversible in this tool set** |
| `list_customer_needs` | Exactly one of `issue`, `project`, `initiative`; `limit`, `cursor`, `orderBy` | Includes closed work and rolled-up needs |
| `save_customer_need` | `id`, `body` (req on create), `customer`, `issue`, `project`, `priority` (0, 1 = important), `source` (URI) | Priority scale differs from issues |
| `delete_customer_need` | `id` (req) | Described as **archive** |

## Releases

| Tool | Params |
|---|---|
| `list_releases` | Std list params with `includeArchived`, plus `query`, `pipeline`, `stage`, `stageType` (`planned`, `started`, `completed`, `canceled`), `version` (exact), `hasReleaseNotes`, `includeReleaseNotes` |
| `get_release` | `id` (req), `includeReleaseNotes` |
| `save_release` | `id`, `name`, `pipeline` (both req on create), `version`, `description`, `stage`, `commitSha`, `createdAt`, `startDate`, `targetDate`, `startedAt`, `completedAt` (last four nullable) |
| `list_release_pipelines` | Std list params with `includeArchived`, plus `query`, `team`, `type` (`continuous`, `scheduled`), `isProduction`, `includeStages`, `includeTeams` |
| `list_release_notes` | Std list params with `includeArchived`, plus `query`, `pipeline`, `release`, `includeContent`, `includeReleases`. Omits content by default |
| `get_release_note` | `id` (req), `includeReleases` |
| `save_release_note` | `id`, `title`, `content`, `patch`, `pipeline` (req on create), and `releases` or `rangeFromRelease` + `rangeToRelease` (one required on create) |

Release status is the pipeline stage. Link issues with `save_issue {addReleases}`. No delete tools. CI tracking is in
[git-integration.md](git-integration.md).
