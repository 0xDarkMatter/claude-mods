---
name: github-ops
description: "GitHub remote operations: repo creation, metadata, releases, issue/PR management with preview-before-send, and read-only security auditing. Triggers on: push to github, ship release, gh release, audit github repo, gh issue, gh pr, merge PR, branch protection, secret scanning, SECURITY.md."
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
| `gh issue` operations (view/list/create/comment/edit/triage/close) | **`github-ops`** |
| `gh pr` operations (view/list/diff/checks/create/comment/review/edit/merge/close) | **`github-ops`** |
| Security posture audit (Dependabot / secret+code scanning / PVR / SECURITY.md / branch protection) — read-only | **`github-ops`** (`scripts/check-security-posture.sh`) |
| Actions / secrets / social preview / branch-protection *writes* | **`github-ops`** (future) |

## Hard rules

1. **Visibility defaults to private.** Pass `--private` to `gh repo create` unless the user has explicitly said "public" / "make it public" for this specific repo. See `references/repo-visibility.md`.
2. **Major version bumps require explicit approval.** Default to minor; patch for fix-only ranges. Never auto-suggest a 1.0.0 from `BREAKING CHANGE:` markers — surface and ask. See `references/release-strategy.md`.
3. **Always run `push-gate` before any push to a remote.** No exceptions. If push-gate refuses, do not proceed — fix the cause and re-run.
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
   - If the README intro is just a tagline or < 80 words, draft a proper 2–3 paragraph
     description: what it is, why it exists, who it's for. Read package metadata, CHANGELOG,
     and the primary entry point first; do not fabricate.
   - Voice: developer-to-developer, concrete, occasional dry wit (earned, never sprayed).
     Anti-patterns ("blazing fast", emoji walls, marketing fluff) listed in the reference.
   - Surface the draft to the user for approval before committing — this is the repo's
     first impression and shouldn't be a one-shot.
   - Commit via git-ops with: docs: Expand README intro

3. Add "Recent Updates" section to README if missing
   - Use claude-mods style by default (see references/readme-recent-updates.md)
   - Place after Quickstart, before deep "why this exists" sections
   - For first release, single bullet block describing the initial extraction
   - Commit via git-ops with: docs: Add Recent Updates section

4. Surface the publish plan to user, with visibility as a flippable line:
   "Creating as **private** at github.com/<org>/<repo> — say 'public' to flip"
   Wait for explicit confirmation.

5. Create the repo:
   gh repo create <org>/<repo> --private --source=. --remote=origin \
     --description "<one-line — distilled from the README intro draft in step 2, ≤ 350 chars>" \
     --homepage "<homepage URL or omit>"
   (NEVER pass --push; we want push-gate to run between)
   Note: the GitHub `--description` is a single line and distinct from the README intro.
   Derive it FROM the intro you just wrote, not from package metadata blindly.

6. Run push-gate preflight:
   bash $HOME/.claude/skills/push-gate/scripts/preflight.sh --cwd <repo> origin main
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

   For minor: update Recent Updates AND scan diff for new commands/config/install steps;
              touch README body sections only if found.
   For patch: update Recent Updates ONLY (single bullet); no body changes unless asked.

   Also: if the README intro is still < 80 words OR the repo's scope has drifted since
   the intro was written, propose an expansion (see references/readme-description.md).
   Don't churn good prose — only act if the intro is genuinely thin or stale.

5. Commit README + CHANGELOG via git-ops:
   docs: Recent Updates + CHANGELOG for v<N>

6. Create local tag via git-ops:
   git tag -a v<N> -m "v<N>"

7. Run push-gate preflight:
   bash $HOME/.claude/skills/push-gate/scripts/preflight.sh --cwd <repo> origin <branch>
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

**Headline: `scripts/repo-scorecard.sh` — one command for a scored repo/fleet health report.** It orchestrates the two read-only auditors (`check-security-posture.sh` + `check-issues.sh`) and adds metadata / release / actions signals, rolling everything into a single **0–100 score + letter grade** per repo, and a **matrix + roll-up** across an org. Reach for it first; drop to the manual checklist below only when you need a specific row the scorecard doesn't surface.

```bash
bash scripts/repo-scorecard.sh --repo 0xDarkMatter/flarecrawl     # single repo: score + dimensions + top 3 fixes
bash scripts/repo-scorecard.sh --org 0xDarkMatter                 # fleet matrix + roll-up (avg/median/worst, fleet open-alert total)
bash scripts/repo-scorecard.sh --org 0xDarkMatter --min-score 75  # CI gate: exit 10 if ANY repo scores < 75
bash scripts/repo-scorecard.sh --repo <o>/<r> --json | jq '.data[0].top_fixes'
```

Five weighted dimensions — **security (35)** highest, then **metadata (25)**, **release (15)**, **issues (15)**, **actions (10)**. Each scores its weight in full (ok) / half (warn) / zero (gap **or** unreadable n/a — an unreadable dimension never counts as healthy). Grade: A≥90 B≥75 C≥60 D≥40 F<40. The full rubric is documented in the script header (`--help`). It surfaces the **top 3 fixes per repo**, highest-severity first, each with the exact remediation pointer (e.g. `→ check-security-posture.sh --repo … --commands`, "add CHANGELOG.md", "cut a GitHub release"). Exit `0` healthy · `10` gaps / below `--min-score` · `7` unavailable (graceful) · `5` gh missing · `2` usage. **Strictly read-only** — only GET `gh api` calls + the read-only siblings; the remediation pointers are text, never executed.

Below is the underlying checklist the scorecard's dimensions roll up (and what mode `new`/`update` act on). See `references/metadata-checklist.md` for the complete version; the SKILL enforces these:

```
LOCAL FILE CHECKS
  [ ] LICENSE file present + matches metadata
  [ ] README has: tagline, install, quickstart, license link
  [ ] README intro is ≥ 80 words (2–3 paragraphs orienting a cold reader)
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

SECURITY POSTURE CHECKS (run scripts/check-security-posture.sh — read-only)
  [ ] Dependabot alerts enabled
  [ ] Dependabot security updates enabled
  [ ] Secret scanning + push protection on   (free on public; needs GHAS on private)
  [ ] Code scanning default setup configured  (free on public; needs GHAS on private)
  [ ] Private vulnerability reporting enabled
  [ ] SECURITY.md present (root / .github/ / docs/)
  [ ] Branch protection on the default branch
  [ ] No OPEN dependabot / secret / code-scanning alerts on enabled scanners
```

Output: per-row pass/fail/warn, then a summary score and list of fixes. Fixes are suggested but not applied — the user decides whether to run mode `new` or mode `update` to act on them. For the security-posture rows, run `scripts/check-security-posture.sh --repo <o>/<r>` and fold its checklist in; the enable commands it emits are surfaced for the user to approve, never auto-run.

## Operations

Atomic GH-side actions that don't fit the three multi-step modes. Each operation that writes author voice to a third-party surface (issue/PR body, comment, review body, release notes, merge commit subject/body) is governed by **hard rule 8** and [public-posts](~/.claude/rules/public-posts.md): quote the exact body in chat, name the send command, wait for explicit approval, then send. Mechanical actions (labels, assign, close-without-message, mark-ready) skip preview.

### Issues

Reads (no preview): `gh issue view <n>`, `gh issue view <n> --comments`, `gh issue list`, `gh api repos/<o>/<r>/issues/<n>` (for fields not in the default view).

Writes:

| Op | Command | Preview? |
|---|---|---|
| Create | `gh issue create --title --body` | **Yes** (title + body) |
| Comment | `gh issue comment <n> --body` | **Yes** (body) |
| Edit title/body | `gh issue edit <n> --title --body` | **Yes** |
| Triage (label/assign/milestone) | `gh issue edit <n> --add-label … --assignee … --milestone …` | No (mechanical) |
| Close / reopen | `gh issue close <n>` / `gh issue reopen <n>` | No, **unless** closing with a comment — preview the comment |
| Transfer | `gh issue transfer <n> <target-repo>` | No (mechanical), but confirm target with user |

See `references/issue-ops.md` for full playbooks, triage flow, and closing-comment templates.

### Pull Requests

Reads (no preview): `gh pr view <n>`, `gh pr view <n> --comments`, `gh pr list`, `gh pr diff <n>`, `gh pr checks <n>`, `gh pr checks <n> --watch`, `gh api repos/<o>/<r>/pulls/<n>/comments` (inline review comments).

Writes:

| Op | Command | Preview? |
|---|---|---|
| Create | `gh pr create --title --body` | **Yes** (title + body) |
| Comment | `gh pr comment <n> --body` | **Yes** |
| Review (approve / request changes / comment) | `gh pr review <n> --approve --body …` | **Yes** (body, if any) |
| Edit title/body | `gh pr edit <n> --title --body` | **Yes** |
| Edit labels / reviewers | `gh pr edit <n> --add-label … --add-reviewer …` | No (mechanical) |
| Mark ready (un-draft) | `gh pr ready <n>` | No (mechanical) |
| Merge | `gh pr merge <n> --squash` (or `--merge` / `--rebase`) | No body to preview by default, but **explicit user approval required** + run pre-merge gate first. If passing `--subject` / `--body`, preview those (they become the commit message on `main`) |
| Close | `gh pr close <n>` | No, **unless** closing with a comment — preview the comment |

**PR creation lives here, not in git-ops.** git-ops handles local commits/branches/push; the `gh pr create` call itself talks to `api.github.com` and belongs in this skill. (Existing git-ops T2 PR-create still works; new flows should route through github-ops.)

**Pre-merge gate** — never invoke `gh pr merge` without first confirming:

1. `gh pr view <n> --json mergeable,mergeStateStatus` → `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`
2. `gh pr checks <n>` → every check passed (or explicitly ignored with user approval)
3. `gh pr diff <n>` reviewed — confirm no surprise scope, no committed secrets/local paths, no stale PR-body claims
4. Merge strategy picked — **default squash** for fix/feature branches with multiple WIP commits; `--merge` only when individual commits matter; `--rebase` for linear-history repos. Ask if uncertain.
5. Branch deletion is a **separate explicit step**, not bundled. Default to keeping the branch; delete remote + local after merge only on explicit user OK (it's destructive enough to warrant its own confirmation, and a checked-out branch can't be deleted).

See `references/pr-ops.md` for full playbooks, review-flow templates, and the merge-strategy decision tree.

## Conventions enforced (load reference files for detail)

| Convention | File | Default |
|---|---|---|
| Release strategy | `references/release-strategy.md` | minor on `feat:`, patch on `fix:`-only, major requires approval |
| README intro (2–3 paragraphs) | `references/readme-description.md` | what it is / why it exists / who it's for; concrete, dry, no marketing fluff |
| README Recent Updates style | `references/readme-recent-updates.md` | claude-mods per-version blocks (alternate: flarecrawl table) |
| Repo visibility default | `references/repo-visibility.md` | `--private` unless user says "public" |
| Metadata audit checklist | `references/metadata-checklist.md` | full source-of-truth for mode `audit` |
| Issue operations | `references/issue-ops.md` | view → triage → comment (with preview) → close; closing comments preview-gated |
| PR operations | `references/pr-ops.md` | create (preview body) → review → pre-merge gate → squash by default; branch deletion separate explicit step |

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
| `references/readme-description.md` | 2–3 paragraph README intro — voice, structure, anti-patterns |
| `references/readme-recent-updates.md` | "Recent Updates" section format + emoji vocabulary |
| `references/repo-visibility.md` | Private-by-default policy |
| `references/metadata-checklist.md` | Audit checklist source of truth |
| `references/issue-ops.md` | Issue operation playbooks (view/triage/comment/create/close) + preview templates |
| `references/pr-ops.md` | PR operation playbooks (create/review/merge) + pre-merge gate + merge-strategy decision tree |
| `scripts/repo-scorecard.sh` | **Capstone audit tool.** Scored, read-only repo-health matrix — orchestrates `check-security-posture.sh` + `check-issues.sh` and adds metadata/release/actions signals into a 0–100 score + grade per repo; `--org` for a fleet matrix + roll-up; `--min-score N` to gate CI; `--json` envelope. Surfaces top-3 fixes per repo. Never mutates |
| `scripts/check-issues.sh` | Surface open issues you may not have seen (externally-authored + stale) for a repo or remote. Read-only `gh issue list`; flags author≠owner and untouched-for-N-days |
| `scripts/check-security-posture.sh` | Read-only repo security-posture auditor. Per-feature checklist (Dependabot alerts/updates, secret scanning + push protection, code scanning, private vuln reporting, SECURITY.md, branch protection), visibility-aware severity, open-alert exposure where a scanner is on, `--org` fleet sweep. Emits enable commands as text — never applies a change |
| `assets/SECURITY.md.template` | Copy-ready vulnerability-disclosure policy (supported versions, private reporting via GitHub PVR, response SLAs, scope, safe harbor) — what `check-security-posture.sh` points at when SECURITY.md is absent |

## Open-issue awareness (the blind spot)

You don't see issues other people file — your own you know about; a stranger's bug report from two months ago is the gap. `scripts/check-issues.sh` closes it:

```bash
bash scripts/check-issues.sh --repo 0xDarkMatter/flarecrawl   # one repo
bash scripts/check-issues.sh --remote origin --stale-days 14  # derive from a remote
bash scripts/check-issues.sh --json | jq '.data[] | select(.external)'
```

Exit `0` = nothing you're missing (no open issues, or all are yours and fresh); `10` = external/stale issues present (the things to look at); `7` = unavailable (not a GitHub remote, gh unauthed/offline) — advisory, never a hard failure; `2` usage; `5` gh not installed.

**Wired into the pre-push gate** ([push-gate](../push-gate/)): `preflight.sh` calls this in `--advisory` mode as a post-gate step, so every push surfaces unseen external/stale issues for the target remote. It is **read-only, timeout-bounded, and never affects the gate verdict** — silent when gh is absent/unauthed or the remote isn't GitHub. Run it standalone any time, or across repos, to find what you've missed. For acting on what it surfaces (view/triage/comment/close), see `references/issue-ops.md`.

## Security posture (the other blind spot)

GitHub ships a stack of free security features — Dependabot alerts, security updates, secret scanning + push protection (free on **public** repos), code scanning default setup, private vulnerability reporting, branch protection — and most are **off by default**. You don't see the gap until something leaks. `scripts/check-security-posture.sh` audits it, read-only:

```bash
bash scripts/check-security-posture.sh --repo 0xDarkMatter/flarecrawl   # one repo
bash scripts/check-security-posture.sh --remote origin                  # derive from a remote
bash scripts/check-security-posture.sh --org 0xDarkMatter               # fleet sweep + roll-up
bash scripts/check-security-posture.sh --repo <o>/<r> --commands        # copy-paste enable cmds
bash scripts/check-security-posture.sh --repo <o>/<r> --json | jq '.data[]|select(.state=="off")'
```

It prints a per-feature checklist — `✓ on` / `✗ off [severity]` / `— n/a (needs GHAS)` — and, **where a scanner is enabled**, the count + max severity of OPEN alerts (the real exposure, not just the toggle). The alert endpoints degrade gracefully: a `403` (token lacks `security_events`) or `404` (feature off) becomes "n/a — couldn't read", **never a false "0 / secure"**.

**Visibility-aware severity** is the judgment that makes it usable:

- **public** repo → secret scanning, push protection, code scanning are **free** → a gap is a real finding.
- **private** repo *without* Advanced Security → those three need paid GHAS → reported as a **note (n/a)**, not a nag.
- Free-on-any-repo (Dependabot alerts/updates, private vuln reporting, SECURITY.md, branch protection) → always a finding when off.
- Tiers: `critical` (open critical alerts) · `high` (open high alerts; push-protection or Dependabot-alerts off on public/active) · `medium` (secret/code scanning off on public; security-updates off; no branch protection) · `low` (SECURITY.md absent; private vuln reporting off). Full mapping in the script header.

**It never applies a change.** It is strictly read-only (only GET `gh api` calls); the enable commands are **emitted as text** — `gh api -X PUT …` for Dependabot alerts/security-updates/private-vuln-reporting/code-scanning, a `PATCH` body for secret scanning + push protection (push protection requires secret scanning on first), and a pointer to `assets/SECURITY.md.template` for the policy file. **You review and run them yourself**, governed by the same preview discipline as any other repo mutation (hard rule 8 — these change repo settings). `--commands` prints just the enable commands with a `# review before running` banner on stderr.

Exit `0` = posture clean (all applicable features on, no open alerts); `10` = gaps and/or open alerts (a CI/audit step can branch on it); `7` = unavailable (non-github remote, gh unauthed/offline/timeout) — advisory, never a hard failure; `2` usage; `5` gh not installed. Folds into mode `audit` (see the Security Posture checklist there).
