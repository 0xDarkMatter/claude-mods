# Metadata Checklist

Source of truth for mode `audit`. Ordered by criticality.

## Critical (mode `new` aborts on fail)

| Check | How |
|---|---|
| LICENSE file present | `[ -f LICENSE ]` |
| LICENSE matches package metadata | grep license field in pyproject.toml/package.json, compare to LICENSE header |
| README.md present | `[ -f README.md ]` |
| README has tagline | first non-empty paragraph is < 200 chars and not a heading |
| README intro ≥ 80 words | word-count of prose between title and first `##` heading; see `readme-description.md` |
| README has install section | `grep -iE '^##\\s+(install|installation|getting started|quickstart)' README.md` |
| Package metadata file present | `pyproject.toml` (Python) OR `package.json` (Node) OR `Cargo.toml` (Rust) etc. |
| Package metadata: description set | `jq -r .description` / `tomlq` equivalent |
| Package metadata: license set | match SPDX identifier |
| At least one tag | `git tag -l \| head -1` |

## Important (mode `new` warns; mode `update` requires)

| Check | How |
|---|---|
| README has "Recent Updates" section | `grep -iE '^##\\s+recent updates' README.md` |
| CHANGELOG.md present | `[ -f CHANGELOG.md ]` |
| CHANGELOG has entry for latest tag | `grep -E "^##?\\s*\\[?v?$(latest_tag)" CHANGELOG.md` |
| Package version matches latest tag | strip `v` prefix from tag, compare to package version field |
| Package metadata: keywords ≥ 3 | for topic derivation |
| Package metadata: repository URL | so install instructions work post-publish |
| Default branch is `main` | `git symbolic-ref refs/remotes/origin/HEAD` (post-push) or local `git branch --show-current` (pre-push) |

## GitHub state (skip if no remote yet)

| Check | How |
|---|---|
| Repo description set | `gh repo view --json description` |
| Repo homepage set OR explicitly N/A | `gh repo view --json homepageUrl` |
| ≥ 3 topics | `gh repo view --json repositoryTopics` |
| Topics align with package keywords | set comparison; warn on divergence |
| Latest tag has a release | `gh release view <tag>` exit code |
| Release notes present (not empty) | `gh release view <tag> --json body` |
| Release notes match CHANGELOG entry | substring match (allow formatting differences) |

## Topic derivation

For a fresh publish without explicit topics, derive 6–12 from:

1. **Language** — `python`, `typescript`, `rust`, `go` (from primary language)
2. **Package keywords** — direct copy from `pyproject.toml` `[project] keywords` or `package.json` `keywords`
3. **Frameworks** — detected from dependencies (e.g. `react`, `fastapi`, `django`, `astro`, `vue`)
4. **Domain** — from README headings or package description (e.g. `cli`, `agents`, `ai`, `automation`, `mcp`, `claude-code`)
5. **Pattern** — recognisable shapes (`job-queue`, `orchestrator`, `daemon`, `headless`, `worktree`)

Cap at 12 (GitHub's limit is 20 but >12 dilutes signal). Validate each topic against GitHub's rules: lowercase, alphanumeric + hyphens, ≤ 50 chars, must start with a letter or number.

## Output format

For mode `audit`, present results as:

```
GITHUB-OPS AUDIT — <repo path>

CRITICAL
  ✓ LICENSE present (MIT)
  ✓ README has tagline + install + quickstart
  ✗ pyproject.toml missing 'description' field

IMPORTANT
  ✓ Recent Updates section present
  ✓ CHANGELOG has entry for v0.1.0
  ⚠ Package keywords: only 2 (recommend ≥ 3 for topic derivation)

GITHUB STATE
  - skipped (no origin remote)

SCORE: 8/11 (1 critical, 1 warning)

NEXT ACTIONS
  1. Add 'description' to pyproject.toml [project] section
  2. Add 1+ keyword to pyproject.toml
  Then: re-run audit, or run mode `new` to publish
```

Critical fails block publish. Warnings surface but don't block. GitHub state checks skipped pre-publish.
