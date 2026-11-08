# Writing good Linear work

How to write issues, scope projects and post updates, summarised from Linear's Method (`https://linear.app/method`) and updates docs. The
checklists and templates are this skill's, built on that guidance.

## Contents

- [Issues](#issues)
- [Issue template](#issue-template)
- [Projects](#projects)
- [Cycles](#cycles)
- [Project updates](#project-updates)
- [Triage practice](#triage-practice)

## Issues

- Plain language, a concrete task, a clear outcome. No user stories.
- A scannable title. A description only when the work needs one.
- Quote customer feedback directly and link to it.
- When filing for someone else, state the problem or ask, not a prescribed solution.
- One owner. Small enough to finish several a week. Split large features.
- Keep the backlog lean. Low-priority items may drop off.

Before creating, as an agent:

1. Search for an existing issue, then read the titles.
2. Resolve the team. If it's ambiguous, ask.
3. Check the team's labels and templates (`list_issue_labels`, `list_templates`) rather than inventing either.
4. Leave `assignee`, `priority` and `estimate` unset unless you know them. Guessed metadata is worse than none.
5. Link evidence with `links`, and say that an agent filed it if that matters.

## Issue template

For one person's quick note:

```markdown
**Problem:** what is wrong, and for whom. One or two sentences.

**Evidence:** a link. No logs or secrets.

**Done when:** the observable outcome.
```

Skip any part the title already says. When the issue asks someone else to act, use the five-part shape in
[working-with-agents.md](working-with-agents.md).

## Projects

Scope small: early on about 1 to 3 weeks with 1 to 3 people. If it can't shrink, stage it. One named owner, and a short spec covering why,
what and how. Link it to an initiative where one exists.

## Cycles

Fixed length, typically two weeks. Don't overload them; rollover is automatic. Mix bugs and quality work with features, and leave room for
the unplanned. Linear's cycles belong to teams, and MCP has no cycle write tools beyond `save_issue {cycle}`.

## Project updates

Linear's docs cover the mechanics: a health indicator, formatting, attachments, and a weekly cadence example. "Update Missing" appears when
overdue by one cycle plus 3 days. Progress detail appears only when progress moved more than 2%.

```markdown
**Health:** on track | at risk | off track, and why, in one line.

**Since last update:** what shipped, with links.

**Next:** what happens before the next update.

**Needs:** decisions or help, naming who.
```

Measure before you claim. Pull the counts from `list_issues`, and don't state health an agent can't judge. Leave that to the lead, and offer a
draft. Posting notifies people, so preview it first.

## Triage practice

- Triage issues are hidden from views by default, so check explicitly.
- Options are accept, decline, duplicate and snooze. Triage Intelligence suggestions arrive 1 to 4 minutes after entry on Business+, under the
  `triageIntel` field. They're suggestions, so verify them.
- Mark a duplicate into the canonical issue with `duplicateOf`. **This closes linked open PRs**, so check first.
- An agent should propose triage decisions in a report. Issues delegated by automation stay in triage for a human, per Linear's guidance.
