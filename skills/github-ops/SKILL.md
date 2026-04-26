---
name: github-ops
description: "GitHub remote operations — repo creation, metadata (description/homepage/topics), releases, README 'Recent Updates' enforcement. Companion to git-ops (local) and push-gate (pre-push safety). Three modes: new (first publish), update (subsequent release), audit (read-only checklist). Triggers on: push to github, publish repo, ship release, cut release, gh release, set topics, repo description, github metadata, recent updates section, audit github repo, repo visibility, make repo public, gh repo create."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: git-ops, push-gate, ci-cd-ops
---

# GitHub Ops

GitHub-side operations skill. Owns everything that talks to `api.github.com` via `gh` CLI: repo creation, metadata configuration, releases, and the conventions that govern how 0xDarkMatter repos present on GitHub.

Sits alongside two related skills:

```
LOCAL                          BRIDGE              REMOTE (GitHub)
─────                          ──────              ───────────────
git-ops                        push-gate           github-ops  (this skill)
```

| Concern | Owner |
|---|---|
| Commits, branches, local tags, rebases, worktrees, stash | `git-ops` |
| Pre-push secret scan + dirty-tree refusal + confirm | `push-gate` |
| `gh repo create`, push to remote, tag push | **`github-ops`** |
| Repo description / homepage / topics / visibility | **`github-ops`** |
| `gh release create` + release notes | **`github-ops`** |
| README "Recent Updates" section maintenance | **`github-ops`** |
| Package metadata audit (pyproject/package.json ↔ GH topics ↔ tag ↔ version) | **`github-ops`** |
| Issues / PRs / Actions / secrets | **`github-ops`** (future) |

## Hard rules

1. **Visibility defaults to private.** Pass `--private` to `gh repo create` unless the user has explicitly said "public" / "make it public" for this specific repo. See `references/repo-visibility.md`.
2. **Major version bumps require explicit approval.** Default to minor; patch for fix-only ranges. Never auto-suggest a 1.0.0 from `BREAKING CHANGE:` markers — surface and ask. See `references/release-strategy.md`.
3. **Always run `push-gate` before any push to a remote.** No exceptions. If push-gate refuses, do not proceed — fix the cause and re-run.
4. **Delegate local git operations to `git-ops`.** Don't reimplement commit/tag/push logic. github-ops orchestrates the GitHub-side calls (`gh`) and the README/CHANGELOG edits; git-ops handles git itself.
5. **README "Recent Updates" updates on every release.** This is the one README touch that always happens, regardless of how minor the release. See `references/readme-recent-updates.md` for the canonical claude-mods style.
6. **Never push without confirming visibility decision.** When creating a new repo, surface visibility as a flippable line in the plan ("creating as **private** — say 'public' to flip"), not buried in flag soup.

## Three modes

### Mode `new` — first publish of a repo

Triggered by: "publish to github", "create repo on github", "push to github" (when no `origin` remote exists), "ship this repo".

```
1. Audit (run mode `audit` checklist; abort on critical fail)
   - LICENSE present?
   - README has tagline + install + quickstart?
   - pyproject.toml / package.json has description, keywords, license, repository URL?
   - At least one tag exists (typically v0.1.0)?
   - CHANGELOG.md has an entry for the latest tag?

2. Add "Recent Updates" section to README if missing
   - Use claude-mods style by default (see references/readme-recent-updates.md)
   - Place after Quickstart, before deep "why this exists" sections
   - For first release, single bullet block describing the initial extraction
   - Commit via git-ops with: docs: Add Recent Updates section

3. Surface the publish plan to user, with visibility as a flippable line:
   "Creating as **private** at github.com/<org>/<repo> — say 'public' to flip"
   Wait for explicit confirmation.

4. Create the repo:
   gh repo create <org>/<repo> --private --source=. --remote=origin \
     --description "<derived from package metadata or asked>" \
     --homepage "<homepage URL or omit>"
   (NEVER pass --push; we want push-gate to run between)

5. Run push-gate preflight:
   bash $HOME/.claude/skills/push-gate/scripts/preflight.sh origin main
   On any non-zero exit: stop, report, do not push.

6. Push main + tags:
   git -C <repo> push -u origin main
   git -C <repo> push origin --tags

7. Set topics (derived from package keywords + language + frameworks):
   gh repo edit <org>/<repo> --add-topic <t1> --add-topic <t2> ...
   Aim for 6–12 topics. See references/metadata-checklist.md for derivation.

8. Create the release for the latest tag:
   gh release create <tag> --title "<tag> — <one-line headline>" \
     --notes "$(extract from CHANGELOG.md)"

9. Verify:
   gh repo view <org>/<repo>
   gh release view <tag>
   Report URL to user.
```

### Mode `update` — subsequent release

Triggered by: "ship a release", "cut a release", "release v0.X.Y", "publish update".

```
1. Audit current state vs last release:
   git -C <repo> log $(git describe --tags --abbrev=0)..HEAD --oneline
   Categorise commits by Conventional Commits prefix.

2. Determine version bump (see references/release-strategy.md):
   - Any feat: → minor (default)
   - Only fix:/chore:/docs:/perf:/style:/test: → patch
   - Any BREAKING CHANGE: or !: → STOP, ask user, never auto-major

3. Update CHANGELOG.md:
   New section for the new version with categorised changes (Added/Changed/Fixed/Removed).
   Delegate the file edit + commit to git-ops with: docs: CHANGELOG for v<N>

4. Update README "Recent Updates":
   Prepend a new version block (claude-mods style) at the top of the section.
   Trim oldest if section exceeds 7 versions.
   Bullets per change, emoji + bold tagline + 1-3 sentence prose.
   See references/readme-recent-updates.md for the emoji vocabulary.

   For minor: update Recent Updates AND scan diff for new commands/config/install steps;
              touch README body sections only if found.
   For patch: update Recent Updates ONLY (single bullet); no body changes unless asked.

5. Commit README + CHANGELOG via git-ops:
   docs: Recent Updates + CHANGELOG for v<N>

6. Create local tag via git-ops:
   git tag -a v<N> -m "v<N>"

7. Run push-gate preflight on origin <branch>.

8. Push commits + tag:
   git push origin <branch>
   git push origin v<N>

9. Create GitHub release:
   gh release create v<N> --title "v<N> — <headline>" \
     --notes "$(extract CHANGELOG section for v<N>)"

10. Verify:
    gh release view v<N>
    Report URL to user.
```

### Mode `audit` — read-only checklist

Triggered by: "audit github repo", "is this repo ready to publish", "check repo metadata", "score this repo".

Read-only — produces a report without making changes. See `references/metadata-checklist.md` for the complete checklist; the SKILL enforces these:

```
LOCAL FILE CHECKS
  [ ] LICENSE file present + matches metadata
  [ ] README has: tagline, install, quickstart, license link
  [ ] README has "Recent Updates" section near top
  [ ] CHANGELOG.md present and has entry for latest tag
  [ ] pyproject.toml / package.json: description, keywords, license, repository URL, homepage
  [ ] Latest tag matches version in package metadata

GITHUB STATE CHECKS (skip if no remote)
  [ ] Repo description is set
  [ ] Repo homepage is set (or explicitly N/A)
  [ ] At least 3 topics
  [ ] Topics align with package keywords
  [ ] Default branch is main (not master)
  [ ] Latest tag has a corresponding release
  [ ] Release notes match CHANGELOG entry
```

Output: per-row pass/fail/warn, then a summary score and list of fixes. Fixes are suggested but not applied — the user decides whether to run mode `new` or mode `update` to act on them.

## Conventions enforced (load reference files for detail)

| Convention | File | Default |
|---|---|---|
| Release strategy | `references/release-strategy.md` | minor on `feat:`, patch on `fix:`-only, major requires approval |
| README Recent Updates style | `references/readme-recent-updates.md` | claude-mods per-version blocks (alternate: flarecrawl table) |
| Repo visibility default | `references/repo-visibility.md` | `--private` unless user says "public" |
| Metadata audit checklist | `references/metadata-checklist.md` | full source-of-truth for mode `audit` |

## Git authorship

For 0xDarkMatter repos, set repo-local config before any commit work:

```bash
git -C <repo> config user.name "0xDarkMatter"
git -C <repo> config user.email "0xDarkMatter@users.noreply.github.com"
```

Verify with `git -C <repo> config user.name`. If a commit was made under a different identity *before* publish (no push has happened), rewrite via:

```bash
git -C <repo> rebase --root --exec 'git commit --amend --reset-author --no-edit'
```

After history rewrite, re-create any tags so they point at the new SHAs:

```bash
git -C <repo> tag -d v0.1.0
git -C <repo> tag -a v0.1.0 -m "..."
```

This is safe pre-publish only. After push, treat history as immutable and set authorship correctly going forward.

## Delegation pattern

```
github-ops           git-ops              push-gate
─────────            ───────              ─────────
mode `new`:
  audit
  edit README   ───► commit (T2)
                                          preflight (before push)
  gh repo create
                ───► push -u origin main
                ───► push --tags
  gh repo edit (topics)
  gh release create
  verify

mode `update`:
                ───► CHANGELOG edit + commit (T2)
  edit Recent Updates
                ───► commit (T2)
                ───► tag (T2)
                                          preflight (before push)
                ───► push (T2)
                ───► push tag (T2)
  gh release create
  verify
```

When invoking git-ops T2 operations, dispatch to git-agent with a one-shot prompt — no need to load the full git-ops orchestrator state for these mechanical steps.

## Future expansion (not yet implemented)

- **Issues** — `gh issue create/list/comment/close` workflows
- **PRs** — `gh pr` operations (note: git-ops T2 currently owns PR creation; could migrate or stay split — decide on first need)
- **Actions** — workflow file scaffolding, `gh workflow` operations
- **Secrets** — `gh secret set/list/delete` (with secure handling)
- **Branch protection** — `gh api` calls for protection rules
- **Social preview** — image upload via `gh api`
- **Org-level** — teams, repo templates

When adding any of the above, keep the boundary discipline: anything talking to `api.github.com` belongs here, anything purely local belongs to `git-ops`.

## Files

| File | Role |
|---|---|
| `SKILL.md` | This file — modes, rules, delegation |
| `references/release-strategy.md` | Version bump policy |
| `references/readme-recent-updates.md` | "Recent Updates" section format + emoji vocabulary |
| `references/repo-visibility.md` | Private-by-default policy |
| `references/metadata-checklist.md` | Audit checklist source of truth |
| `scripts/` | (empty; reserved — extract patterns into scripts when they repeat across uses) |
| `assets/` | (empty; reserved for README templates / snippets) |

## Why no scripts yet

Initial implementation uses inline `gh`, `jq`, `git -C` calls rather than wrapping them in scripts. Once usage reveals patterns that repeat verbatim across invocations (CHANGELOG extraction is the most likely candidate), extract those into `scripts/` and reference them here. Premature script extraction obscures what the skill is actually doing.
