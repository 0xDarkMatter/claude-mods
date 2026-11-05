# Git integration

Magic words, branches, PR automation, Linear Reviews and release pipelines. From `https://linear.app/docs/github.md` (read in full) and
sibling pages, seen 2026-11-05. `[I]` marks inference.

## Contents

- [Magic words](#magic-words)
- [Linking rules](#linking-rules)
- [Branch names](#branch-names)
- [Status automation](#status-automation)
- [Things that happen without asking](#things-that-happen-without-asking)
- [Linear Reviews](#linear-reviews)
- [GitLab differences](#gitlab-differences)
- [Release pipelines](#release-pipelines)
- [Other integrations](#other-integrations)

## Magic words

| Effect | Words |
|---|---|
| Closing | `close, closes, closed, closing, fix, fixes, fixed, fixing, resolve, resolves, resolved, resolving, complete, completes, completed, completing, implement, implements, implemented, implementing, linear issue` |
| Non-closing | `ref, refs, references, part of, contributes to, toward, towards` |
| Relation only | `relates to, related to` |
| Opt out | `skip ENG-123`, `ignore ENG-123` |
| Create | `ENG-NEW` in a PR description creates and links an issue, Started, assigned to the author. `Fixes ENG-NEW` also sets a closing link |

Check text before it goes out:

```bash
python "<skill-dir>/scripts/scan-magic-words.py" --kind pr pr-body.md
python "<skill-dir>/scripts/scan-magic-words.py" --kind pr --json pr-body.md | jq '.data[] | select(.effect=="closing")'
```

Exit 10 means something would close. Its reading of prose is `[I]`: a phrase like "does not fix ENG-123" still matches the pattern, so
reword it. The scanner reports that row as `negated-closing`, because whether Linear honours the negation is unverified.

## Linking rules

- Works in a PR title or description, or a commit message. **Magic words in PR comments do not link.**
- Non-closing words still move other statuses but don't apply the "On PR or commit merge" status.
- Several issues: `Fixes ENG-123, DES-5, and ENG-256`.
- Unassigned issues become assigned to whoever links them.
- Commit linking needs a toggle and a webhook, and works with one GitHub org only.
- Squash chains: issues linked only in earlier PRs aren't auto-detected when the aggregate branch merges.
- A branch name relinks even after a manual unlink, unless you write `skip` or `ignore`.

## Branch names

Use the issue's own value: `gitBranchName` in MCP, `Issue.branchName` in GraphQL. The format is a workspace setting, so don't compose it by
hand. Copying the name in the UI can assign the issue and start it, per a personal setting; fetching it through the API won't `[I]`.

## Status automation

Team-level, under Settings > Team > Workflows & automations. Triggers: draft, open, review requested, ready for merge, merged. Defaults: In
Progress on open, Done on merge.

- **With several linked PRs, status changes when the final one reaches the required state.**
- Ready for merge needs review or checks required in GitHub, and any failed check, even a non-required one, blocks it.
- Without branch protection, review-requested is skipped and it goes to ready to merge.
- Branch rules target branches by regex: `staging` to In QA, `main` to Deployed.
- A custom merge queue adds the `externally-merged` label before closing.

An agent doing the work should leave status to this automation where it's on, instead of also setting it, to avoid fighting it `[I]`. Read
the state after merging.

## Things that happen without asking

- **Cancelling an issue, or marking it duplicate, closes open GitHub PRs linked with Closes or Contributes.** Reference links stay open,
  as do PRs also linked to another open issue. Completing an issue doesn't do this.
- Linking a PR assigns an unassigned issue.
- A linkback comment posts on each linked PR.
- One GitHub org connects to only one Linear workspace.

GitHub Issues sync is one-way many-to-one, or two-way for one repo, for new issues only. GitHub Enterprise Server supports magic words in PR
descriptions only.

## Linear Reviews

Also called Linear Diffs. Read diffs, comment inline, approve or request changes, and **merge**, syncing to GitHub.

- `linear.review/owner/repo/pull/123` opens a GitHub PR in Linear.
- **GitHub-native stacks: merging one PR also merges every PR below it.** Linked branch chains merge one at a time.
- Team review requests work only for GitHub teams of 10 or fewer. Draft reviews don't sync. Check annotations aren't shown.
- `.gitattributes` categories such as `review-test`, `review-documentation` and `review-generated` shape the view.
- GraphQL `type Diff` is marked `[Internal]`, so don't build on it. Use the MCP tools or GitHub `[I]`.

`merge_diff` is a real GitHub merge. On an auto-deploying branch it's a deploy, and it stays behind a live OK from the user.

## GitLab differences

Same closing stems; the non-closing list adds `updates`. No links from comments or commit messages. Same triggers. Ready for merge needs
pipeline events and "Pipelines must succeed". Self-managed must be publicly reachable, 15.6+, one instance per workspace. No bot accounts, so
linkbacks post as the token owner: use a dedicated user. Reviews are documented for GitHub only. The scanner's `--gitlab` flag applies these.

## Release pipelines

Business and Enterprise. Pipelines are `continuous` (each sync makes a completed release) or `scheduled` (issues accumulate in a started
release until completed). Issues get in by commit scanning for references like `ENG-123`, with optional path globs.

**Each pipeline has its own access key; personal API keys can't substitute.** The CLI is `linear-release` (`sync`, `complete`, `update --stage`)
with `LINEAR_ACCESS_KEY`, plus the `linear/linear-release-action` action. Suggested pattern: Merged on PR merge, Done when the release lands.
Pin the action to a SHA, as `ci-cd-ops` advises for any action.

## Other integrations

Slack: `@Linear` agent, synced threads, `/linear`. Sentry: create or link issues; resolves on completion. Jira: import and two-way sync.
Intercom, Zendesk, Front: customer requests. Salesforce: Enterprise.
