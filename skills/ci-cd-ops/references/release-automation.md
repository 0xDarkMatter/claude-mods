# Release Automation Reference

## Table of Contents

- [Semantic Versioning](#semantic-versioning)
- [Conventional Commits](#conventional-commits)
- [Tool Comparison](#tool-comparison)
- [semantic-release](#semantic-release)
- [changesets](#changesets)
- [release-please](#release-please)
- [goreleaser](#goreleaser)
- [Changelog Generation](#changelog-generation)
- [GitHub Releases](#github-releases)
- [NPM Publishing](#npm-publishing)
- [Docker Image Tagging](#docker-image-tagging)
- [Monorepo Release Strategies](#monorepo-release-strategies)

---

## Semantic Versioning

Format: `MAJOR.MINOR.PATCH` (e.g., `2.4.1`)

| Increment | When | Example |
|-----------|------|---------|
| MAJOR | Breaking API changes | `1.9.0` -> `2.0.0` |
| MINOR | New features (backward compatible) | `2.0.0` -> `2.1.0` |
| PATCH | Bug fixes (backward compatible) | `2.1.0` -> `2.1.1` |

Pre-release versions: `2.0.0-alpha.1`, `2.0.0-beta.3`, `2.0.0-rc.1`

Build metadata: `2.0.0+build.123` (ignored in version precedence)

## Conventional Commits

Format: `<type>(<scope>): <description>`

| Type | Version Bump | Example |
|------|-------------|---------|
| `fix` | PATCH | `fix(auth): handle expired tokens` |
| `feat` | MINOR | `feat(api): add user search endpoint` |
| `feat` + `BREAKING CHANGE:` | MAJOR | `feat(api)!: change response format` |
| `docs`, `chore`, `ci`, `style`, `refactor`, `test`, `perf` | None | `docs: update API reference` |

Breaking changes can be indicated two ways:

```
feat(api)!: remove legacy endpoint

BREAKING CHANGE: The /v1/users endpoint has been removed. Use /v2/users instead.
```

## Tool Comparison

| Feature | semantic-release | changesets | release-please | goreleaser |
|---------|-----------------|------------|----------------|------------|
| Language | Any (Node-based) | Any (Node-based) | Any | Go projects |
| Versioning | Automatic from commits | Manual (developer intent) | Automatic from commits | From git tags |
| Changelog | Auto-generated | Manual + auto | Auto-generated | Auto-generated |
| Monorepo | Via plugins | Native | Native | N/A |
| CI integration | Deep | Moderate | GitHub-native | Deep |
| NPM publish | Built-in | Built-in | Via workflow | N/A |
| GitHub Release | Built-in | Via script | Built-in | Built-in |
| Human review | No (fully auto) | Yes (PR-based) | Yes (PR-based) | No |
| Best for | Full automation | Monorepos, team review | Google-style, simple setup | Go binaries |

## semantic-release

Fully automated versioning and publishing based on commit messages.

### Configuration

```json
// .releaserc.json
{
  "branches": [
    "main",
    { "name": "next", "prerelease": true },
    { "name": "beta", "prerelease": true }
  ],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/changelog",
    ["@semantic-release/npm", {
      "npmPublish": true
    }],
    ["@semantic-release/github", {
      "assets": ["dist/*.tar.gz"]
    }],
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]"
    }]
  ]
}
```

### GitHub Actions Workflow

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main, next, beta]

permissions:
  contents: write
  issues: write
  pull-requests: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Custom Commit Analyzer Rules

```json
// .releaserc.json
{
  "plugins": [
    ["@semantic-release/commit-analyzer", {
      "preset": "conventionalcommits",
      "releaseRules": [
        { "type": "perf", "release": "patch" },
        { "type": "refactor", "release": "patch" },
        { "type": "docs", "scope": "api", "release": "patch" }
      ]
    }]
  ]
}
```

## changesets

Developer-driven versioning with PR-based workflow. Ideal for monorepos.

### Setup

```bash
npx @changesets/cli init
# Creates .changeset/ directory with config.json
```

### Configuration

```json
// .changeset/config.json
{
  "$schema": "https://unpkg.com/@changesets/config@3.0.0/schema.json",
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "fixed": [],
  "linked": [["@myorg/core", "@myorg/utils"]],
  "access": "public",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "ignore": ["@myorg/docs", "@myorg/dev-tools"]
}
```

### Developer Workflow

```bash
# 1. Create a changeset (interactive)
npx changeset

# 2. This creates a file like .changeset/brave-dogs-dance.md:
# ---
# "@myorg/core": minor
# "@myorg/utils": patch
# ---
#
# Add search functionality to core package

# 3. Commit the changeset with your PR
git add .changeset/brave-dogs-dance.md
git commit -m "feat: add search functionality"
```

### GitHub Actions Workflow

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]

permissions:
  contents: write
  pull-requests: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      - name: Create Release PR or Publish
        uses: changesets/action@v1
        with:
          publish: npx changeset publish
          version: npx changeset version
          title: 'chore: version packages'
          commit: 'chore: version packages'
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

## release-please

Google's release automation. Creates release PRs automatically from conventional commits.

### GitHub Actions Workflow

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]

permissions:
  contents: write
  pull-requests: write

jobs:
  release:
    runs-on: ubuntu-latest
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
      tag_name: ${{ steps.release.outputs.tag_name }}
    steps:
      - uses: googleapis/release-please-action@v4
        id: release
        with:
          release-type: node           # or python, go, simple, etc.

      # Steps that only run on release
      - uses: actions/checkout@v4
        if: ${{ steps.release.outputs.release_created }}

      - uses: actions/setup-node@v4
        if: ${{ steps.release.outputs.release_created }}
        with:
          node-version: 20
          registry-url: https://registry.npmjs.org

      - run: npm ci && npm publish
        if: ${{ steps.release.outputs.release_created }}
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Configuration

```json
// release-please-config.json
{
  "packages": {
    ".": {
      "release-type": "node",
      "changelog-path": "CHANGELOG.md",
      "bump-minor-pre-major": true,
      "bump-patch-for-minor-pre-major": true
    }
  }
}
```

## goreleaser

Release automation for Go projects: cross-compilation, archives, Docker images, and more.

### Configuration

```yaml
# .goreleaser.yml
version: 2

before:
  hooks:
    - go mod tidy
    - go generate ./...

builds:
  - id: myapp
    main: ./cmd/myapp
    binary: myapp
    env:
      - CGO_ENABLED=0
    goos: [linux, darwin, windows]
    goarch: [amd64, arm64]
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}

archives:
  - id: default
    format: tar.gz
    format_overrides:
      - goos: windows
        format: zip
    name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"

dockers:
  - image_templates:
      - "ghcr.io/owner/myapp:{{ .Version }}"
      - "ghcr.io/owner/myapp:latest"
    dockerfile: Dockerfile
    build_flag_templates:
      - "--build-arg=VERSION={{.Version}}"

checksum:
  name_template: 'checksums.txt'

changelog:
  sort: asc
  filters:
    exclude:
      - '^docs:'
      - '^chore:'
      - '^ci:'

release:
  github:
    owner: myorg
    name: myapp
  draft: false
  prerelease: auto
```

### GitHub Actions Workflow

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: goreleaser/goreleaser-action@v6
        with:
          version: '~> v2'
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Local Testing

```bash
# Dry run (no publish)
goreleaser release --snapshot --clean

# Check config
goreleaser check

# Build only (no release)
goreleaser build --snapshot --clean
```

## Changelog Generation

### Standalone Changelog Tools

```bash
# conventional-changelog-cli
npx conventional-changelog -p conventionalcommits -i CHANGELOG.md -s

# git-cliff (Rust, fast)
git cliff -o CHANGELOG.md
git cliff --latest                    # Only latest release
git cliff --unreleased                # Only unreleased changes
```

### git-cliff Configuration

```toml
# cliff.toml
[changelog]
header = "# Changelog\n\n"
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | upper_first }}
{% for commit in commits %}
- {{ commit.message | upper_first }} ({{ commit.id | truncate(length=7, end="") }})\
{% endfor %}
{% endfor %}
"""

[git]
conventional_commits = true
filter_unconventional = true
commit_parsers = [
  { message = "^feat", group = "Features" },
  { message = "^fix", group = "Bug Fixes" },
  { message = "^perf", group = "Performance" },
  { message = "^refactor", group = "Refactoring" },
]
```

## GitHub Releases

### Creating Releases with `gh`

```bash
# Auto-generate notes from commits
gh release create v1.2.0 --generate-notes

# With title and custom notes
gh release create v1.2.0 \
  --title "v1.2.0" \
  --notes "## What's New
- Feature A
- Bug fix B"

# Upload assets
gh release create v1.2.0 dist/*.tar.gz checksums.txt

# Create draft release
gh release create v1.2.0 --draft

# Create pre-release
gh release create v2.0.0-beta.1 --prerelease

# Edit existing release
gh release edit v1.2.0 --draft=false
```

### GitHub Actions Release

```yaml
- run: |
    gh release create "$TAG" \
      --title "$TAG" \
      --generate-notes \
      dist/*
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    TAG: ${{ github.ref_name }}
```

## NPM Publishing

### Complete NPM Release Workflow

```yaml
name: Publish to NPM
on:
  push:
    tags: ['v*']

permissions:
  contents: write
  id-token: write                     # For npm provenance

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          registry-url: https://registry.npmjs.org

      - run: npm ci
      - run: npm test
      - run: npm publish --provenance --access public
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Publishing to GitHub Packages

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    registry-url: https://npm.pkg.github.com
    scope: '@myorg'

- run: npm publish
  env:
    NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Docker Image Tagging

### Tagging Strategy

| Tag | Source | Example | Purpose |
|-----|--------|---------|---------|
| `latest` | Main branch | `myapp:latest` | Most recent stable |
| `x.y.z` | Git tag | `myapp:1.2.3` | Immutable release |
| `x.y` | Git tag | `myapp:1.2` | Latest patch |
| `x` | Git tag | `myapp:1` | Latest minor |
| `sha-abc1234` | Commit SHA | `myapp:sha-abc1234` | Exact build |
| `pr-42` | PR number | `myapp:pr-42` | PR preview |
| `edge` | Main branch | `myapp:edge` | Bleeding edge |

### docker/metadata-action

```yaml
- uses: docker/metadata-action@v5
  id: meta
  with:
    images: |
      ghcr.io/${{ github.repository }}
      docker.io/myorg/myapp
    tags: |
      type=semver,pattern={{version}}
      type=semver,pattern={{major}}.{{minor}}
      type=semver,pattern={{major}}
      type=sha,prefix=
      type=ref,event=branch
      type=ref,event=pr
      type=raw,value=latest,enable={{is_default_branch}}
```

## Monorepo Release Strategies

### Independent Versioning (changesets)

Each package has its own version. Best for library monorepos.

```json
// .changeset/config.json
{
  "fixed": [],
  "linked": [["@myorg/client-*"]],   # These move together
  "access": "public"
}
```

### Fixed Versioning (release-please)

All packages share one version. Best for application monorepos.

```json
// release-please-config.json
{
  "packages": {
    "packages/core": { "release-type": "node" },
    "packages/cli": { "release-type": "node" },
    "packages/web": { "release-type": "node" }
  },
  "group-pull-requests-pattern": "chore: release main"
}
```

### Path-Filtered Releases

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'packages/api/**'

jobs:
  release-api:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: packages/api
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm publish
```

### Turborepo + changesets

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npx turbo run build --filter='...[origin/main]'
      - uses: changesets/action@v1
        with:
          publish: npx changeset publish
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```
