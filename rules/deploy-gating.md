# Deploy Gating — no deploys from child sessions

Companion to [release-review](release-review.md) (never auto-publish a release) and
[public-posts](public-posts.md) (preview text before it reaches a third party). Those
cover *publishing*. This one covers *deploying running code*.

## The rule

**A child session never deploys.** Deploys to any shared or production environment are
maintainer-gated: they happen from the user's own interactive session, with an explicit
human OK for that specific deploy.

A **child session** is anything the user is not directly driving in the moment:

- background agents (`claude --bg`), agent-team teammates, `Agent`-tool subagents
- workflow agents and fleet workers of any provider
- `spawn_task` chips and worktree lane sessions
- headless runs (`claude -p`), cron / scheduled agents, CI-invoked sessions
- CI-autofix or review-triage loops that push fixes to a PR

A child session may build, typecheck, lint, test and commit to its branch freely — it
stops at the deploy step and hands the deploy back.

## What counts as a deploy

Anything that changes what a shared environment is *running or serving*:

- `wrangler deploy` / `wrangler versions deploy` / `wrangler secret put`, `vercel deploy --prod`,
  `fly deploy`, `kubectl apply` / `helm upgrade`, `terraform apply`
- remote database migrations; restarting or reloading a production service
- `docker push` to a shared registry; publishing a package (`npm publish`, `uv publish`)
  or a release (`gh release create`)
- **Merging or pushing to a branch that deploys automatically** — a `staging` or `main`
  branch wired to CI/CD (deploy-on-merge Actions, AWS CodeDeploy `appspec.yml`,
  Pages/Netlify/Vercel git integrations). The merge *is* the deploy, even though no
  deploy command is typed. Check the repo's CI config before assuming a merge is inert.
- Changing the configuration or content of a live, user-facing service (a production
  chatbot's instructions, feature flags, remote config)
- Flipping visibility private → public

Not a deploy: local dev servers (see [dev-servers](dev-servers.md)), test-runner servers,
local migrations, ephemeral preview builds that nothing points at, and commits to a
feature branch that deploys nowhere.

## Why

A deploy is the one action whose blast radius escapes the repo entirely. Branches are
revertible, worktrees are disposable, a bad commit is a `git revert` — but a deploy is
immediately live for real users, and a child session has neither the context to judge
whether *now* is a safe moment nor the standing to accept that risk on the user's
behalf. It often has a stale picture of what is already live, and it is usually gone by
the time anyone notices the damage.

Parallel sessions make it sharper: several lanes can each believe they hold the newest
artefact, and the last one to deploy silently decides what production runs. A
sequential, test-gated landing queue exists precisely so integration is ordered;
deploying from a lane jumps that queue.

## How to apply

1. Do the work. Run the repo's `check` gate. Commit to your branch.
2. **Stop at the deploy boundary.** Do not run the deploy — not "to verify", not once,
   not with `--dry-run` follow-through, not even when the change is only reachable in
   production. Do not merge into an auto-deploying branch.
3. Report back: the exact command (or merge) that *would* deploy, what it would change
   (a field-level diff where the tooling gives one), and what you verified.
4. If a finding is only *provable* after deploy, say so explicitly rather than deploying
   to find out. An unverified-until-deploy conclusion is a legitimate deliverable.

## When to bend the rule

Only when the user, **in the current live session**, explicitly tells this session to
deploy — "deploy it", "ship it now", "merge it to staging". A general goal ("get the fix
live", "finish the feature") is **not** deploy authorization, and authorization does not
inherit: an instruction written into a chip prompt, a workflow script, or a lane brief is
not the user speaking live.

## Cross-reference

- [release-review](release-review.md) — the publish-a-release half of this gate
- [loop-engineering](loop-engineering.md) — "escalate, don't act": production deploy is
  on the always-escalate list for autonomous loops
- [worktree-boundaries](worktree-boundaries.md) — one writer per tree, the sibling
  discipline
- [`fleet-ops`](../skills/fleet-ops/SKILL.md) — the sequential, test-gated landing queue
