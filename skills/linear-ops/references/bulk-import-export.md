# Bulk, import, export, delete

From Linear's docs and schema, seen 2026-11-05. None of this was exercised live. `[I]` marks inference.

## Contents

- [Before any bulk change](#before-any-bulk-change)
- [The retention trap](#the-retention-trap)
- [Verify by id, not by count](#verify-by-id-not-by-count)
- [Importers](#importers)
- [Export](#export)
- [Archive, trash, delete](#archive-trash-delete)
- [Restore paths](#restore-paths)
- [The team cap](#the-team-cap)

## Before any bulk change

1. Build the id list with a read, and show the user the count and a sample. Capture the ids: they're your denominator.
2. Run the smallest batch first and read the result.
3. Use GraphQL `issueBatchUpdate` in batches of 50. It takes UUIDs, and a larger list fails validation.
4. Stop on the first `errors` or `success:false`, and report what already changed.
5. Expect notifications and automation side effects: state changes can close PRs, and assignee changes notify.
6. Mind the shared hourly budget: 2,500 requests across all of a person's keys.
7. Never bulk-edit items you didn't just create without the user's say-so.
8. For coordination work, cancel with a reason rather than deleting.

## The retention trap

**Reported by a team that permanently lost thousands of issues this way, and not re-tested here. Treat it as true until proven otherwise.** Two calls that look equivalent aren't:

- `issueDelete` rewrites `archivedAt` to now. The issue enters trash with a fresh clock and stays recoverable by `issueUnarchive`.
- `issueBatchUpdate` with `trashed: true` does **not** rewrite `archivedAt`. An issue archived long ago enters trash already outside the retention window and is swept permanently, with no warning and no unarchive afterwards. It's also reported to work only on already-archived issues.

So: **never batch-trash a population containing archived records.** If a human approves a real cleanup, back up ids and content first, use the per-item path, and confirm the first old record can be unarchived before continuing.

**A probe on fresh objects proves nothing here.** Creating, archiving, trashing and recovering scratch issues can't show this failure, because a new object can't be outside the window. A destructive procedure is proven only against the age, scale and state of the real population. If you can't probe that safely, it's unproven: use the per-item path.

## Verify by id, not by count

The same team reports that right after a large batch, identical paginated walks returned very different totals, while singular `issue(id)` lookups stayed correct. So check specific ids against a denominator captured **before** the mutation. If you need a count, require two consecutive identical walks.

## Importers

Jira, GitHub Issues, Asana, Shortcut, Linear-to-Linear, plus a CLI importer. Admins only, one-time.

- Re-importing to the same team skips already imported issues.
- Not available into sub-teams that inherit workflow statuses.
- Delete an import from Import/Export settings; the Jira page says within 7 days.
- Jira API import can keep syncing; CSV can't. Custom fields don't import. Matching IDs needs a new or empty team.
- CLI importer: `@linear/import`, CSV, no comments or projects, and not advised where a dedicated importer exists. It handles a key, so
  scan and pin it through `supply-chain-defense`.

## Export

- Workspace CSV by an admin, link emailed, expires after 12 hours.
- View exports: **members 250 issues, admins 2,000.** Projects and initiatives: 200.
- "Copy as Markdown for LLMs": `Cmd+Opt+C`.

For more than those caps, page through GraphQL with `linear-gql.py --paginate`.

## Archive, trash, delete

| | Archive | Delete (trash) | Permanent delete |
|---|---|---|---|
| UI | **Automatic only**; no manual action | Manual | After 30 days |
| GraphQL | `issueArchive(id, trash?)`, `issueUnarchive` | `issueDelete(id)`, with sub-issues | `issueDelete(id, permanentlyDelete: true)`: **admin only, skips grace** |
| MCP | None | None | None |
| Restore | Searchable, restorable | **30 days** through Recently deleted, or undo | None, even by support |
| Team cap | Doesn't count | n/a | n/a |

Auto-close and auto-archive live in Team Settings > Automations. Auto-close skips issues in an active cycle or unfinished project. Projects and
teams have the same 30-day window, and deleting a team deletes its issues. Who may delete an issue, by role, wasn't confirmed.

## Restore paths

Permanence is per object type, so don't generalise from one. Mutations below were confirmed in the published schema on 2026-11-05.

| Object | Remove | Restore |
|---|---|---|
| Issue | `issueDelete`, `issueArchive` | `issueUnarchive`, within retention |
| Project | `projectDelete` | `projectUnarchive` |
| Document | `documentDelete` | `documentUnarchive` |
| Label | `issueLabelRetire` | `issueLabelRestore`. It restores a **retired** label; `issueLabelDelete` is irreversible per Linear's docs. Retire, don't delete |
| **Project milestone** | `projectMilestoneDelete` | **None: treat as permanent** |
| **Custom view** | `customViewDelete` | **None: treat as permanent** |

**Rename a milestone, never delete and recreate it.** `projectMilestoneUpdate` keeps the id, so issues linked to it survive. **Don't delete a shared view**: recreating one needs its filter and its display preferences, which you can't read back afterwards.

## The team cap

**60,000 non-archived issues per team.** Over it, integrations and the API are blocked from creating more, and completed issues count until
archived. If a sync suddenly can't create issues, check this before debugging auth `[I]`.
