# Ownership, Delegation and Authorship

Who owns which concern across git-ops, push-gate and github-ops; how github-ops delegates the local half; git authorship for 0xDarkMatter repos; and the planned expansions with the boundary rule that governs them.

## Who owns what

| Concern | Owner |
|---|---|
| Commits, branches, local tags, rebases, worktrees, stash | `git-ops` |
| Pre-push secret scan + dirty-tree refusal + confirm | `push-gate` |
| `gh repo create`, push to remote, tag push | **`github-ops`** |
| Repo description / homepage / topics / visibility | **`github-ops`** |
| `gh release create` + release notes | **`github-ops`** |
| README "Recent Updates" section maintenance | **`github-ops`** |
| README as a landing page (badge row, features-as-benefits, screenshots) | **`github-ops`** |
| Package metadata audit (pyproject/package.json ↔ GH topics ↔ tag ↔ version) | **`github-ops`** |
| `gh issue` operations (view/list/create/comment/edit/triage/close) | **`github-ops`** |
| `gh pr` operations (view/list/diff/checks/create/comment/review/edit/merge/close) | **`github-ops`** |
| Security posture audit (Dependabot / secret+code scanning / PVR / SECURITY.md / branch protection) — read-only | **`github-ops`** (`scripts/check-security-posture.sh`) |
| Actions / secrets / social preview / branch-protection *writes* | **`github-ops`** (future) |

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
