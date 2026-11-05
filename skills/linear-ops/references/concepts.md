# Linear's model

What each object is and which rules bite. From Linear's docs and GraphQL schema, seen 2026-11-05. `[I]` marks inference.

## Contents

- [Hierarchy](#hierarchy)
- [Workflow states](#workflow-states)
- [Priority and estimates](#priority-and-estimates)
- [Labels](#labels)
- [Relations](#relations)
- [Moving an issue between teams](#moving-an-issue-between-teams)
- [SLAs](#slas)
- [Customers](#customers)
- [Documents, templates, views, updates](#documents-templates-views-updates)
- [Not confirmed](#not-confirmed)

## Hierarchy

| Concept | Rules |
|---|---|
| Workspace | Container with its own URL. Users can hold accounts in several |
| Team | Owns workflow, triage, cycles, labels, issues. Free plan 2 teams, Basic 5, Business and Enterprise unlimited |
| Team issue cap | **60,000 non-archived issues per team.** Over it, integrations and the API can't create more. Completed issues count until archived |
| Sub-team | Business and Enterprise; multi-level (up to 5) Enterprise only. Members must also be in the parent, except guests. Un-nesting permanently removes inherited items not in use |
| Issue | Exactly one team. Needs a title and status. Consecutive per-team number |
| Sub-issue | Inherits team, priority and project at creation. Labels are not inherited. Cycle only if created in an active status. Team toggles can auto-close parent and children |
| Project | May span teams. One **lead team** sets available project statuses. An issue is in **one project at most**. Deleted projects restorable 30 days |
| Milestone | Within one project |
| Initiative | Statuses Proposed, Planned, Active, Completed, Canceled. One owner |
| Sub-initiative | Enterprise only, up to 5 levels. Can have multiple parents. Rollup includes sub-initiative projects |
| Cycle | Per team, 1 to 8 weeks, up to 15 future cycles. Issues can't be assigned to a cooldown. Unfinished issues roll over. Past dates aren't editable. Starting the next cycle early is irreversible |
| Triage | Team toggle. Issues from integrations, non-members or the Triage view land there. **Hidden from views by default.** Accept, decline, duplicate, snooze. Rules, Intelligence and Responsibility are Business+ |
| Retired team | Read-only. Different from a deleted team, which has a 30-day grace |

## Workflow states

- Type values: `triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`, `duplicate`.
- `duplicate` is reserved and can't be renamed. Marking a duplicate moves the issue there, so "closed" logic and a filter on
  `canceled` need care `[I]`.
- Default statuses: Backlog, Todo, In Progress, Done, Canceled. Categories have a fixed order, and statuses reorder only within a
  category. At least one status remains per category.
- Without a state, create goes to the team's first Backlog status, or to Triage if enabled.
- For an agent starting work: the lowest-`position` `started` state, per Linear's agent guidance. MCP's `list_issue_statuses`
  doesn't return `position` and isn't in order, so use GraphQL if order matters, or pick by name.

## Priority and estimates

Priority: `0` none, `1` urgent, `2` high, `3` medium, `4` low. Not customisable. **`priority: {lte: 2}` includes `0`**, so add
`neq: 0`. Initiatives use the same scale. `CustomerNeed.priority` differs: `0` not important, `1` important.

Estimates: `issueEstimationType` is `notUsed`, `exponential`, `fibonacci`, `linear` or `tShirt`. T-shirt points are XS 1, S 2, M 3,
L 5, XL 8, XXL 13, XXXL 21, so a T-shirt team still writes numbers `[I]`. `issueEstimationAllowZero` and `issueEstimationExtended`
widen the scale.

## Labels

- Workspace or team scope. Groups give **one** level of nesting and hold up to 250 labels. Only one label per single-select group
  on an issue.
- **Same-named team labels act as one in UI filters but not in the API: each team's has its own id.**
- Archiving (MCP "retire") keeps a label on its issues and stops new use. **Deleting is irreversible, even by support**, and strips
  it from issues.
- Reserved names include assignee, cycle, effort, estimate, hours, priority, project, state, status.
- `Type/Bug` or `Type:Bug` in the add-label flow creates group and label.
- Project labels are a separate object.

## Relations

- Schema types: `blocks`, `duplicate`, `related`, `similar`. MCP exposes `blocks`, `blockedBy`, `relatedTo`, `duplicateOf`.
- Referencing an issue in a description or comment makes it related automatically.
- When a blocker resolves, the relationship moves under Related.
- Duplicates go one way, from the duplicate into the canonical. Triage's duplicate action moves attachments and customer requests.

## Moving an issue between teams

A team move issues a **new identifier** (old ones redirect), removes team labels, removes the project unless the destination team
is on it, may clear the cycle, and remaps status. Get the team right at creation.

## SLAs

Business and Enterprise. Defaults: urgent 24 hours, high one week, others remove the SLA. First matching rule wins, and new rules
aren't retroactive. Statuses: Low risk, Medium risk, High risk, Breached, Achieved, Failed. **An issue has a due date or an SLA,
never both; applying an SLA replaces the due date.**

## Customers

The UI says "customer request"; the API and MCP say `CustomerNeed`. `domains` must be unique and not public mail providers.
Integration-managed customers restrict editable fields. Guests see nothing about customer requests. GraphQL `customerUpsert` matches
by domain.

## Documents, templates, views, updates

- Documents live in project resources and elsewhere. Trash through the `trashed` flag in GraphQL.
- Templates are workspace or team level, standard or form. Workspace templates can't preset team labels or statuses. Parent team
  templates reach sub-teams.
- Custom views are saved filters and don't alter data.
- Project and initiative updates carry health `onTrack`, `atRisk` or `offTrack`. The first is by the lead or owner, then any member.
  Only the creator can edit. Edits in the first 3 minutes after creating an issue aren't logged in its activity.

## Not confirmed

Sub-issue nesting depth, the `similar` relation's semantics, the scale values for non-T-shirt estimates, and whether a project can sit in
several initiatives per the docs (the `setInitiatives` tool parameter suggests yes `[I]`).
