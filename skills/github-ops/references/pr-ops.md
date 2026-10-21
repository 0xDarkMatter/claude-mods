# Pull Request Operations Reference

Per-operation playbooks for `gh pr` workflows. Every write op with author voice (`--body` / `--title` / merge `--subject` / `--body`) is **preview-gated** per hard rule 8 — quote the draft verbatim in chat, name the send command, wait for explicit user approval, then send.

## Contents

- Reads (no preview)
- Create (preview required — title AND body)
- Comment (preview required)
- Review (preview required for body)
- Edit title / body (preview required)
- Pre-merge gate, then red checks and bot findings: [review-bot-triage.md](review-bot-triage.md)
- Merge strategy decision tree
- Merge — the final call
- Branch deletion (separate explicit step)
- Close (without merging)
- Common workflows
- Anti-patterns

## Reads (no preview)

```bash
# Single PR with metadata
gh pr view <n> --repo <o>/<r>

# PR + comment thread (the discussion is half the story)
gh pr view <n> --repo <o>/<r> --comments

# Diff (use this — not local git diff — to see exactly what the PR proposes)
gh pr diff <n> --repo <o>/<r>

# CI checks (snapshot)
gh pr checks <n> --repo <o>/<r>

# CI checks (block until all complete — for use during merge gate)
gh pr checks <n> --repo <o>/<r> --watch --interval 10

# List with filters
gh pr list --repo <o>/<r> --state open --base main --limit 20

# Inline review comments on specific lines (default --comments shows top-level only)
gh api repos/<o>/<r>/pulls/<n>/comments --jq '.[] | {path,line,user:.user.login,body}'

# Detailed merge-readiness fields
gh pr view <n> --repo <o>/<r> --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

## Create (preview required — title AND body)

PR title shows in lists, notifications, and (for squash merges) becomes the commit message subject on `main`. Body should explain *why* + how to verify. Always preview both.

### Chat preview

> Drafted PR for `<o>/<r>`:
>
> **Title:** `<title>`
>
> **Base:** main ← **Head:** `<branch>`
>
> **Body:**
> ```markdown
> <body>
> ```
>
> Command: `gh pr create --base main --head <branch> --title "..." --body "..."`
>
> Send?

### Send

```bash
gh pr create --repo <o>/<r> \
  --base main \
  --head <branch> \
  --title "<approved title>" \
  --body "$(cat <<'EOF'
<approved body>
EOF
)"
```

### Body shape (claude-mods convention)

```markdown
## Summary

<1-3 bullets — what changed and why>

## Test plan

- [x] <thing that was tested>
- [ ] <thing the reviewer should test>

Closes #<n>   <!-- if this PR resolves an issue, link it so merge auto-closes -->
```

The "Closes #N" / "Fixes #N" footer is load-bearing — it triggers GitHub's auto-close on merge. Without it the issue stays open after the PR lands and someone has to clean up.

### Draft vs ready

For work-in-progress or pre-review polish, create as draft:

```bash
gh pr create … --draft
```

Promote later (mechanical, no preview): `gh pr ready <n>`.

## Comment (preview required)

Same discipline as issue comments. Top-level PR comments are different from inline review comments (next section).

### Send

```bash
gh pr comment <n> --repo <o>/<r> --body "$(cat <<'EOF'
<approved body>
EOF
)"
```

## Review (preview required for body)

Three flavours: `--approve`, `--request-changes`, `--comment` (review-level, not inline). All three may include a body; if they do, **preview the body**.

```bash
# Approve with no message — preview not required (the action itself is the signal)
gh pr review <n> --repo <o>/<r> --approve

# Approve with a parting comment — preview the body
gh pr review <n> --repo <o>/<r> --approve --body "<approved body>"

# Request changes — body is required and definitely preview-gated
gh pr review <n> --repo <o>/<r> --request-changes --body "<approved body>"

# Comment-only review (no approve/block) — preview the body
gh pr review <n> --repo <o>/<r> --comment --body "<approved body>"
```

Posting new inline-line comments (`gh api repos/<o>/<r>/pulls/<n>/comments`) is heavier — currently out of scope; use the GitHub UI or extend this reference when first needed. Replying to an existing inline thread, such as a review bot's finding, is covered in [review-bot-triage.md](review-bot-triage.md#3-replying-safely).

## Edit title / body (preview required)

```bash
gh pr edit <n> --repo <o>/<r> \
  --title "<new title>" \
  --body "$(cat <<'EOF'
<new body>
EOF
)"
```

Mechanical edits (labels, reviewers, milestone, base branch) don't need preview:

```bash
gh pr edit <n> --repo <o>/<r> \
  --add-label "ready-for-review" \
  --remove-label "wip" \
  --add-reviewer <user> \
  --milestone "v2.11.0"
```

## Pre-merge gate

**Never invoke `gh pr merge` without running this gate first.** This is the discipline distilled from PR #11.

```bash
# 1. Merge-readiness JSON
gh pr view <n> --repo <o>/<r> --json mergeable,mergeStateStatus,reviewDecision \
  --jq '{mergeable,mergeStateStatus,reviewDecision}'
# Need: mergeable=MERGEABLE, mergeStateStatus=CLEAN (or UNSTABLE if non-required checks fail)

# 2. All checks pass (use --watch to block during a CI run)
gh pr checks <n> --repo <o>/<r>

# 3. Review the actual diff one more time
gh pr diff <n> --repo <o>/<r> | less

# 4. Confirm the PR body still accurately describes the diff
#    (PRs that grew during review often have stale descriptions — edit first if so)
gh pr view <n> --repo <o>/<r> --json title,body --jq '.body' | head -50
```

Surface the result in chat as a green/red checklist before proposing the merge command. If anything is red, **stop and report** — don't merge through a failing gate.

Red is not yet a diagnosis. Before rerunning a failed check or answering an automated reviewer, triage it with [review-bot-triage.md](review-bot-triage.md): one fresh rebuild for a suspected flake, the stale-base check for a failure outside the diff, and fix / dismiss with evidence / ask a human for each bot finding.

## Merge strategy decision tree

| Situation | Strategy | Why |
|---|---|---|
| Fix or feature branch with multiple WIP commits all serving one logical change | **Squash** (`--squash`) | Clean single-line history on main; the PR is the unit, individual commits were drafts |
| Each commit on the branch is independently meaningful and worth preserving in `git log` | **Merge commit** (`--merge`) | Preserves authorship and intermediate steps; useful for collaborative branches |
| Repo enforces linear history (`gh api repos/<o>/<r> --jq .allow_rebase_merge`) and commits are individually clean | **Rebase** (`--rebase`) | Each commit lands on main as a separate commit, no merge bubble |
| Mixed / unclear | Ask the user | Don't guess; the project's history style is theirs to decide |

**Default for one-off PRs in this project family (claude-mods, etc.):** `--squash`.

Check repo allowance once via `gh api repos/<o>/<r> --jq '{allow_squash_merge,allow_merge_commit,allow_rebase_merge}'`. If only some are enabled, that constrains the choice.

### Squash with custom subject/body

When using `--squash`, the merge commit's subject and body land on `main` as a public commit. If passing `--subject` / `--body`, **preview both** (hard rule 8):

```bash
gh pr merge <n> --repo <o>/<r> --squash \
  --subject "<approved subject — typically: PR title (#<n>)>" \
  --body "$(cat <<'EOF'
<approved body — typically: one-paragraph summary of the change>
EOF
)"
```

Without `--subject` / `--body`, `gh` uses the PR title and the concatenated commit messages — no preview required, but state in chat which you're using.

## Merge — the final call

After the pre-merge gate is green and the strategy is chosen:

> Pre-merge gate green:
> - mergeable: MERGEABLE / mergeStateStatus: CLEAN
> - All 3 checks pass (validate 18s, Socket x2)
> - Diff reviewed, PR body matches
>
> Proposing: `gh pr merge <n> --repo <o>/<r> --squash --subject "<…>" --body "<…>"`
>
> Branch deletion: **not bundled** — separate step after merge if you want it.
>
> Merge?

Then on approval:

```bash
gh pr merge <n> --repo <o>/<r> --squash --subject "..." --body "..."
```

## Branch deletion (separate explicit step)

`gh pr merge --delete-branch` exists but couples merge + delete. **Keep them separate.** Delete branches as a discrete operation after merge, with its own confirmation — both because branch deletion is destructive and because a currently-checked-out branch can't be deleted at all (relevant if the operating worktree is on the PR branch).

```bash
# After merge + user OK:
git -C <local-repo> fetch origin --prune
git -C <local-repo> checkout --detach origin/main   # leave the branch if it's checked out
git -C <local-repo> branch -D <branch>              # local
git push origin --delete <branch>                   # remote
```

## Close (without merging)

```bash
# Plain close — no preview
gh pr close <n> --repo <o>/<r>

# Close with a parting comment — preview the comment first
gh pr comment <n> --repo <o>/<r> --body "..."   # preview-gated
gh pr close <n> --repo <o>/<r>
```

### Closing-comment templates

**Superseded:**
> Closing in favour of #<m>, which takes a different approach: <one sentence>. Thanks for the work here — pieces of the idea live on in the new PR.

**Won't merge:**
> Closing — after discussion, decided not to land this because <reason>. Detailed why in the thread above. Not a rejection of the code quality, just the direction.

## Common workflows

### Standard fix flow

```
1. Branch off origin/main
2. Commit; push branch
3. Draft PR body in chat, preview with user, gh pr create (preview-gated)
4. CI runs; gh pr checks --watch (red: classify per review-bot-triage.md before any rerun)
5. Address review feedback if any (responses preview-gated; bot threads: review-bot-triage.md)
6. Pre-merge gate
7. Merge (squash by default; explicit user OK)
8. Branch cleanup (separate step, explicit OK)
```

### Reviewing a PR

```
1. gh pr view <n> --comments     # full context including prior discussion
2. gh pr diff <n>                # what actually changed
3. gh pr checks <n>              # CI status
4. Read the linked issue(s) for original intent
5. Draft review body in chat → preview → gh pr review (preview-gated)
```

### Hotfix with auto-close

```
1. Branch off main, fix, commit, push
2. PR body includes "Fixes #<bug-issue>" (auto-closes on merge)
3. Standard merge flow
4. After merge: post a closing-credit comment on #<bug-issue> with version + PR link
```

## Anti-patterns

- ❌ Merging without running the pre-merge gate (`mergeStateStatus` / checks / diff).
- ❌ Bundling `--delete-branch` into the merge command — couples two destructive decisions into one.
- ❌ Defaulting to `--merge` (merge-commit) when squash gives a cleaner history; only use it when individual commits matter.
- ❌ Sending a review body, PR description, or comment without showing the draft to the user first (hard rule 8).
- ❌ Promising follow-up work in a PR description and not capturing it as an issue.
- ❌ Skipping the "Closes #N" footer in PR body — leaves issues unclosed after merge.
- ❌ Treating `mergeable: UNKNOWN` as green — wait for GitHub to compute (re-poll).
- ❌ Rerunning a red check until it passes, or acting on a review bot's finding without verifying it (see `review-bot-triage.md`).
