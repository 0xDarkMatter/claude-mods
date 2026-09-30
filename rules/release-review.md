# Release Review — never auto-publish

Companion to [github-ops](../skills/github-ops/SKILL.md), the
release flows in `cli-tools.md`, and [public-posts](public-posts.md)
(the broader sibling — preview text before sending it to any third-party
surface, not just the release page).

## The rule

**Never run `gh release create` without explicit user approval.** Push the
commit + tag if the user has authorised the publish flow, but stop at the
release step and surface the diff for review.

This applies to:

- `gh release create`
- `gh release edit --draft=false` (publishing a previously drafted release)
- Any other action that creates a public, externally-visible release page
- Force-pushing tags that already have a release

## Why

A GitHub release is a one-way visibility commitment. Once published:

- The release page shows up in the user's profile feed
- Any `uv tool install <pkg>@<tag>` / `pip install <pkg>==<version>` resolves
  to the published artefacts
- People watching the repo get a "new release" notification
- Search engines index the release notes
- "Yanking" a release leaves a 410 / "this release was deleted" trace

Pushing a commit + tag is *also* visible, but it's a much smaller signal
than a release page. The user can review the pushed state on GitHub
before creating the release.

This rule exists because the failure is easy and quiet: an agent told to "run the
release flow" reads that as authority to publish, and the first human look at the
release notes then happens *after* strangers have seen them. A human review step is
required *before* the release is published.

## How to apply — the right release flow

When invoking the github-ops `update` mode (or any equivalent flow):

1. Bump the version, update CHANGELOG / README "Recent Updates"
2. `git commit` + `git tag` (these stay local until step 4)
3. Run push-gate preflight on the commit
4. `git push origin <branch>` + `git push origin <tag>` — OK to do
   without separate confirmation when the user has authorised the publish
5. **Stop here.** Surface the pushed state to the user:
   - Link to the tag's diff: `https://github.com/<org>/<repo>/compare/<prev>...<tag>`
   - Link to the tag's tree: `https://github.com/<org>/<repo>/tree/<tag>`
   - The CHANGELOG section that would become the release notes
6. Wait for explicit user approval before running `gh release create`
7. If the user wants edits to the release notes, apply them, then ask
   again

## What to surface for the review

When you stop at step 5, give the user:

- The exact `gh release create` command you'd run, with the `--notes` content
- The git diff URL for the tag
- A reminder that the tag + commit are already pushed, so review can
  happen on GitHub directly

Example:

```
v1.4.0 commit + tag pushed. Ready to create the GitHub release.

Diff: https://github.com/acme/widget-cli/compare/v1.3.0...v1.4.0
Tree: https://github.com/acme/widget-cli/tree/v1.4.0

Proposed release command:
  gh release create v1.4.0 \
    --repo acme/widget-cli \
    --title "v1.4.0 — Reporting refactor" \
    --notes-file /tmp/v140-notes.md

Want me to run it, or do you want to review on GitHub first?
```

## When to bend the rule

If the user has already explicitly said "create the release" / "publish
v0.X.Y" / "ship it" in the same turn that authorises the push, you can
skip the separate confirmation step. The rule is about *implicit*
authorisation — the user saying "use github-ops update mode" is not
the same as saying "publish the release page".

If unsure, ask. The cost of asking is low; the cost of an unwanted
release is real.

## Cross-reference

- `~/.claude/skills/github-ops/SKILL.md` — release flow modes
- `~/.claude/skills/push-gate/scripts/preflight.sh` — pre-push secret scan
- `~/.claude/rules/cli-tools.md` — `gh` CLI usage patterns
