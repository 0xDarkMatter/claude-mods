---
name: github-ops
description: "GitHub remote operations and README authoring: repo creation, metadata, releases, issue/PR management with preview-before-send, README as a landing page (badge row, features-as-benefits, screenshots, Recent Updates), and read-only security auditing. Triggers on: write a README, improve the README, README badges, README features section, push to github, ship release, gh release, audit github repo, gh issue, gh pr, merge PR, branch protection, secret scanning, SECURITY.md."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: git-ops, push-preflight, ci-cd-ops
---

# GitHub Ops

GitHub-side operations skill. Owns everything that talks to `api.github.com` via `gh` CLI: repo creation, metadata configuration, releases, and the conventions that govern how 0xDarkMatter repos present on GitHub.

Sits alongside two related skills:

```
LOCAL                          BRIDGE              REMOTE (GitHub)
─────                          ──────              ───────────────
git-ops                        push-preflight      github-ops  (this skill)
```

Ownership by concern, row by row: [references/delegation-and-authorship.md](references/delegation-and-authorship.md).

## Hard rules

1. **Visibility defaults to private.** Pass `--private` to `gh repo create` unless the user has explicitly said "public" / "make it public" for this specific repo. See `references/repo-visibility.md`.
2. **Major version bumps require explicit approval.** Default to minor; patch for fix-only ranges. Never auto-suggest a 1.0.0 from `BREAKING CHANGE:` markers — surface and ask. See `references/release-strategy.md`.
3. **Always run `push-preflight` before any push to a remote.** No exceptions. If push-preflight refuses, do not proceed — fix the cause and re-run.
4. **Delegate local git operations to `git-ops`.** Don't reimplement commit/tag/push logic. github-ops orchestrates the GitHub-side calls (`gh`) and the README/CHANGELOG edits; git-ops handles git itself.
5. **README "Recent Updates" updates on every release.** This is the one README touch that always happens, regardless of how minor the release. See `references/readme-recent-updates.md` for the canonical claude-mods style.
6. **Never push without confirming visibility decision.** When creating a new repo, surface visibility as a flippable line in the plan ("creating as **private** — say 'public' to flip"), not buried in flag soup.
7. **No local-machine paths in committed content.** Never bake `C:\Users\<name>\…`, `/home/<name>/…`, `/Users/<name>/…`, `/tmp/<one-off-test-dir>`, or any other machine-specific path into README entries, Recent Updates bullets, CHANGELOG entries, release notes, tag annotations, or commit messages. Public release artefacts have to read the same on someone else's machine. Use generic placeholders (`~/Temp/`, `<temp-dir>`, "a temp directory") or describe the file's purpose abstractly instead. If a path genuinely is part of the project's public API (install location, config path), state it canonically (`$HOME/.claude/skills/...`), not as a literal absolute that includes a user name.
8. **Preview every public post before sending.** Anything with author voice that lands on a third-party surface — `gh issue create/comment/edit --body`, `gh pr create/comment/review/edit --body`, `gh release create --notes`, merge commit `--subject`/`--body` — must be quoted verbatim in chat with the exact send command named, then await explicit approval before invoking. Mechanical actions with no body (label, assign, milestone, mark-ready, close-without-message) skip preview. See `~/.claude/rules/public-posts.md` for the full rule.

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

2. Draft / refine README intro (2–3 paragraphs) — see references/readme-description.md
   - Tagline only or under 80 words: draft 2–3 paragraphs (what / why / for whom) from
     metadata, CHANGELOG and the entry point, never fabricated; get approval first.
     Detail: references/readme-steps.md
   - Commit via git-ops with: docs: Expand README intro

2b. Build the landing-page layer — see references/readme-landing-page.md
   The intro answers "what is this"; this step answers the other three questions a
   cold visitor asks in their first ten seconds (is it alive / what do I get /
   what does it look like). Benefits before mechanics.

   FIRST pick the register, and surface it as a flippable line like visibility:
     "Laying the README out as **Reference** — say 'showcase' to flip"
   - Showcase — reader is deciding WHETHER to adopt. Apps, dashboards, TUIs,
     generators, anything with visible output. Visual high, Features above Install,
     airier prose.
   - Reference — reader has already decided and needs to USE it. Libraries, SDKs,
     plain-output CLIs, internal tooling. Install + a real usage example in the
     first screenful; Features denser and lower.
   Tie-breakers: output is visible → Showcase. It's a dependency of other code →
   Reference. Register controls emphasis and density, NEVER honesty — Showcase is
   not permission for marketing verbs; the readme-description.md anti-patterns
   apply identically to both. Never mix the two.

   Then, in either register: badge row, Features above Install written as benefits,
   and a screenshot only if there is a visual surface. Rules: references/readme-steps.md
   - Surface the layout to the user with the intro draft; commit together.

3. Add "Recent Updates" section to README if missing
   - Use claude-mods style by default (see references/readme-recent-updates.md)
   - Place after Quickstart, before deep "why this exists" sections — i.e. below the
     Features + visual added in step 2b (see references/readme-landing-page.md for the
     full section order and why liveness sits there, not above Features)
   - For first release, single bullet block describing the initial extraction
   - Commit via git-ops with: docs: Add Recent Updates section

4. Surface the publish plan to user, with visibility as a flippable line:
   "Creating as **private** at github.com/<org>/<repo> — say 'public' to flip"
   Wait for explicit confirmation.

5. Create the repo:
   gh repo create <org>/<repo> --private --source=. --remote=origin \
     --description "<one-line — distilled from the README intro draft in step 2, ≤ 350 chars>" \
     --homepage "<homepage URL or omit>"
   (NEVER pass --push; we want push-preflight to run between)
   Note: the GitHub `--description` is a single line and distinct from the README intro.
   Derive it FROM the intro you just wrote, not from package metadata blindly.

6. Run push-preflight:
   bash $HOME/.claude/skills/push-preflight/scripts/preflight.sh --cwd <repo> origin main
   On any non-zero exit: stop, report, do not push.

7. Push main + tags:
   git -C <repo> push -u origin main
   git -C <repo> push origin --tags

8. Set topics (derived from package keywords + language + frameworks):
   gh repo edit <org>/<repo> --add-topic <t1> --add-topic <t2> ...
   Aim for 6–12 topics. See references/metadata-checklist.md for derivation.

9. Create the release for the latest tag:
   gh release create <tag> --title "<tag> — <one-line headline>" \
     --notes "$(extract from CHANGELOG.md)"

10. Verify:
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

   Minor: Recent Updates, plus body sections only for new commands/config/install.
   Patch: Recent Updates only. Thin or stale intro: propose an expansion. Detail:
   references/readme-steps.md

   Landing-page touch-ups (see references/readme-landing-page.md) — act only on a
   real trigger, never as routine churn. Keep the README's EXISTING register
   (Showcase vs Reference); never switch it silently. A genuine audience change
   (internal tool going public) is worth proposing a switch — done all at once,
   with approval — not drifting into one bullet at a time:
   - Triggers: a new capability, a red or stale badge, a screenshot a UI change made
     wrong, a visual surface with no visual. Detail: references/readme-steps.md

5. Commit README + CHANGELOG via git-ops:
   docs: Recent Updates + CHANGELOG for v<N>

6. Create local tag via git-ops:
   git tag -a v<N> -m "v<N>"

7. Run push-preflight:
   bash $HOME/.claude/skills/push-preflight/scripts/preflight.sh --cwd <repo> origin <branch>
   On any non-zero exit: stop, report, do not push.

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

Triggered by: "audit github repo", "is this repo ready to publish", "check repo metadata", "score this repo", "how healthy is this repo", "score the fleet".

**Start with `bash scripts/repo-scorecard.sh --repo <o>/<r>`** (`--org <org>` for a fleet, `--min-score N` as a CI gate): a strictly read-only 0–100 score and grade per repo with its top 3 fixes. The checklist below is what it rolls up. Rubric and exit codes: [references/auditor-scripts.md](references/auditor-scripts.md).

Below is the underlying checklist the scorecard's dimensions roll up (and what mode `new`/`update` act on). See `references/metadata-checklist.md` for the complete version; the SKILL enforces these:

```
LOCAL FILE CHECKS
  [ ] LICENSE file present + matches metadata
  [ ] README has: tagline, install, quickstart, license link
  [ ] README intro is ≥ 80 words (2–3 paragraphs orienting a cold reader)
  [ ] README has "Recent Updates" section near top

LANDING-PAGE CHECKS — all WARN-level, never a hard fail (references/readme-landing-page.md)
  [~] Infer the README's REGISTER first (Showcase = pitch-forward, visual high, Features
      above Install; Reference = install + usage in the first screenful, denser Features)
      and judge every row below against THAT register. A Reference README is not missing
      a hero — it declined one. WARN if the register is visibly mixed (a Showcase hero
      bolted onto a Reference body, or vice versa): it serves neither reader.
  [~] README has a badge row under the title (≤ 5 badges; license + at least one
      liveness signal — CI or version). WARN if absent; WARN if > 7 badges (badge wall)
      or if a CI badge points at a workflow with no runs / a red default branch.
  [~] README has a "## Features" (or equivalent) section ABOVE Install, with bullets
      that lead with what the reader GETS, not what the software contains. WARN if the
      section is missing, or if it is a component inventory / a flag-by-flag table.
  [~] README has a screenshot or demo — CONDITIONAL. Only warn when the project has a
      visual surface (TUI, GUI, dashboard, web UI, rendered/generated output, or
      colourised CLI output). A plain-text CLI, a library, an SDK, or a config/skill
      bundle legitimately has none: report nothing, do not nag. Where images exist,
      WARN on missing alt text or a light-only capture with no <picture> dark variant.
  [ ] CHANGELOG.md present and has entry for latest tag
  [ ] pyproject.toml / package.json: description, keywords, license, repository URL, homepage
  [ ] Latest tag matches version in package metadata

GITHUB STATE + SECURITY POSTURE CHECKS: description, homepage, topics, main branch,
  releases; security via scripts/check-security-posture.sh. Rows:
  references/auditor-scripts.md; complete list: references/metadata-checklist.md
```

Output: per-row pass/fail/warn, then a summary score and list of fixes. Fixes are suggested but not applied — the user decides whether to run mode `new` or mode `update` to act on them. For the security-posture rows, run `scripts/check-security-posture.sh --repo <o>/<r>` and fold its checklist in; the enable commands it emits are surfaced for the user to approve, never auto-run.

## Operations

Atomic GH-side actions that don't fit the three multi-step modes. Each operation that writes author voice to a third-party surface (issue/PR body, comment, review body, release notes, merge commit subject/body) is governed by **hard rule 8** and [public-posts](../../rules/public-posts.md): quote the exact body in chat, name the send command, wait for explicit approval, then send. Mechanical actions (labels, assign, close-without-message, mark-ready) skip preview.

### Issues

Reads need no preview. Author-voice writes (create, comment, edit title/body, a closing comment) are preview-gated; label, assign, milestone, close/reopen and transfer are mechanical. Table: [references/operations-preview.md](references/operations-preview.md); playbooks: `references/issue-ops.md`.

### Pull Requests

Reads need no preview. Create, comment, review and edit title/body are preview-gated; labels, reviewers and mark-ready are mechanical. **Merge needs explicit user approval and the pre-merge gate below.** Table: [references/operations-preview.md](references/operations-preview.md).

**PR creation lives here, not in git-ops.** git-ops handles local commits/branches/push; the `gh pr create` call itself talks to `api.github.com` and belongs in this skill. (Existing git-ops T2 PR-create still works; new flows should route through github-ops.)

**Pre-merge gate** — never invoke `gh pr merge` without first confirming:

1. `gh pr view <n> --json mergeable,mergeStateStatus` → `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`
2. `gh pr checks <n>` → every check passed (or explicitly ignored with user approval)
3. `gh pr diff <n>` reviewed — confirm no surprise scope, no committed secrets/local paths, no stale PR-body claims
4. Merge strategy picked — **default squash** for fix/feature branches with multiple WIP commits; `--merge` only when individual commits matter; `--rebase` for linear-history repos. Ask if uncertain.
5. Branch deletion is a **separate explicit step**, not bundled. Default to keeping the branch; delete remote + local after merge only on explicit user OK (it's destructive enough to warrant its own confirmation, and a checked-out branch can't be deleted).

See `references/pr-ops.md` for full playbooks, review-flow templates, and the merge-strategy decision tree.

## Conventions enforced (load reference files for detail)

Defaults: minor on `feat:`, patch on `fix:`-only, major only with approval; README intro of 2–3 concrete paragraphs; landing page register-first, never mixed; Recent Updates in per-version blocks; `--private` unless told public; preview-gated issue/PR bodies, squash by default, branch deletion a separate step. The reference behind each: [references/files.md](references/files.md).

## Authorship, delegation, expansion

For 0xDarkMatter repos set repo-local `user.name` / `user.email` before any commit; rewriting authorship is safe only before the first push. github-ops runs the `gh` calls and README/CHANGELOG edits, git-ops the commits, tags and pushes, push-preflight the preflight. Unbuilt expansions (Actions, secrets, branch-protection writes) follow the same boundary: `api.github.com` here, purely local to `git-ops`. Commands and diagram: [references/delegation-and-authorship.md](references/delegation-and-authorship.md).

## Files

| File | Role |
|---|---|
| `references/readme-landing-page.md` | The layer between intro and changelog — the Showcase/Reference register choice, section order for each, badge row (shields.io + `labelColor`), features-as-benefits with a before/after rewrite, screenshot/demo policy, landing-page anti-patterns |
| Every other reference, script and asset | The role of each: [references/files.md](references/files.md) |

## Read-only auditors (the blind spots)

`bash scripts/check-issues.sh --repo <o>/<r>` surfaces external and stale open issues you would otherwise miss (push-preflight runs it advisory on every push). `bash scripts/check-security-posture.sh --repo <o>/<r>` (`--org`, `--commands`) audits Dependabot, secret and code scanning, private vulnerability reporting, SECURITY.md and branch protection. **Neither applies a change**: enable commands are text you review and run under hard rule 8. Exit 10 = something to look at. Detail: [references/auditor-scripts.md](references/auditor-scripts.md).
