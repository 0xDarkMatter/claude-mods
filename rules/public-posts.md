# Public Posts — preview before sending

Companion to [release-review](release-review.md). That rule covers the
release page; this one covers the rest of the same family: anything that
posts text to a third-party surface other humans will read.

## The rule

**Quote the draft body in chat and wait for explicit approval before
invoking any command that posts to a public surface.** The user's
authorisation to *do the post* ("comment on #4", "open a PR", "draft the
release") is not authorisation to *send the specific words* you came up
with — those they still need to see and approve.

Applies to (non-exhaustive):

- `gh issue comment`, `gh issue create`, `gh issue edit`
- `gh pr comment`, `gh pr create`, `gh pr edit` (title and body)
- `gh release create`, `gh release edit` (covered also by release-review)
- Slack / Discord / email sends
- Any MCP tool that publishes a comment / message / canvas to an external
  service (Asana, Notion, Apollo, Linear, Tessitura, etc.)

Does **not** apply to:

- Local git operations (`git commit`, `git tag`) — commit messages are
  reviewable in the diff before push, and the user authorises the push
  separately.
- `git push` itself — that's covered by the push-gate skill and per-task
  authorisation.
- Reading public surfaces (`gh issue view`, `gh pr checks`, etc.).

## Why

A comment, PR description, or release note is a one-way visibility
commitment. Once sent it shows up in someone else's notifications, gets
indexed by search engines, and stays in the project's history. Editing it
later leaves a visible "edited" marker; deleting it leaves a gap.

The cost of pausing to surface the draft is one extra message. The cost
of sending the wrong tone, a misattribution, a stale claim, or a typo to
a third party is real and not fully reversible.

The user (2026-05-29) corrected this on a `gh issue comment` to issue #4
that they had authorised in concept but had not seen the text of.

## How to apply

1. Compose the post in chat as a quoted block (the exact body that would
   be sent, verbatim — not paraphrased).
2. Name the command that would send it (`gh issue comment 4 ...`,
   `gh pr create ...`, etc.).
3. Wait for explicit approval ("yes", "send it", "looks good", an edit
   request, etc.). Silence is not approval.
4. If the user edits, apply the edit and re-surface — don't ship a
   guess.
5. Only then run the send command.

## When to bend the rule

If the user has already pasted the exact body they want sent, or said
something like "post this verbatim" / "ship it as-is" / "send my words",
the approval is in-band — proceed.

If the post is a trivial mechanical action with no author voice (e.g.
`gh pr edit --add-label ready`, `gh issue close`), no preview needed.
The rule is about *text Claude wrote* hitting a public surface.

## Cross-reference

- `~/.claude/rules/release-review.md` — the release-creation specific
  half of this pattern
- `~/.claude/skills/push-gate/SKILL.md` — pre-push gate (different
  concern: secrets / forbidden files, not message review)
