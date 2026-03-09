---
name: migrate-ops
description: "Framework and language migration patterns - version upgrades, breaking changes, dependency audit, safe rollback. Use for: migrate, migration, upgrade, version bump, breaking changes, deprecation, dependency audit, npm audit, pip-audit, codemod, jscodeshift, rector, rollback, semver, changelog, framework upgrade, language upgrade, React 19, Vue 3, Next.js App Router, Laravel 11, Angular, Python 3.12, Node 22, TypeScript 5, Go 1.22, Rust 2024, PHP 8.4."
allowed-tools: "Read Edit Write Bash Glob Grep Agent"
related-skills: [testing-ops, debug-ops, git-workflow, refactor-ops]
---

# Migrate Operations

Comprehensive migration skill covering framework upgrades, language version bumps, dependency auditing, breaking change detection, codemods, and rollback strategies.

## Migration Strategy Decision Tree

```
What kind of migration are you performing?
│
├─ Small library update (patch/minor version)
│  └─ In-place upgrade
│     Update dependency, run tests, deploy
│
├─ Major framework version (React 18→19, Vue 2→3, Laravel 10→11)
│  │
│  ├─ Codebase < 50k LOC, good test coverage (>70%)
│  │  └─ Big Bang Migration
│  │     Upgrade everything at once in a feature branch
│  │     Pros: clean cutover, no dual-version complexity
│  │     Cons: high risk, long branch life, merge conflicts
│  │
│  ├─ Codebase > 50k LOC, partial test coverage
│  │  └─ Incremental Migration
│  │     Upgrade module by module, use compatibility layers
│  │     Pros: lower risk per step, continuous delivery
│  │     Cons: dual-version code, longer total duration
│  │
│  ├─ Monolith → microservice or complete architecture shift
│  │  └─ Strangler Fig Pattern
│  │     Route new features to new system, migrate old features gradually
│  │     Pros: zero-downtime, reversible, production-validated
│  │     Cons: routing complexity, data sync challenges
│  │
│  └─ High-risk data pipeline or financial system
│     └─ Parallel Run
│        Run old and new systems simultaneously, compare outputs
│        Pros: highest confidence, catch subtle differences
│        Cons: double infrastructure cost, comparison logic
│
└─ Language version upgrade (Python 3.9→3.12, Node 18→22)
   └─ In-place upgrade with CI matrix
      Test against both old and new versions in CI
      Drop old version support once all tests pass
```

## Framework Upgrade Decision Tree

```
Which framework are you upgrading?
│
├─ React 18 → 19
│  ├─ Check: Remove forwardRef wrappers (ref is now a regular prop)
│  ├─ Check: Replace <Context.Provider> with <Context>
│  ├─ Check: Adopt useActionState / useFormStatus for forms
│  ├─ Check: Replace manual memoization if using React Compiler
│  ├─ Codemod: npx codemod@latest react/19/migration-recipe
│  └─ Load: ./references/framework-upgrades.md
│
├─ Next.js Pages Router → App Router
│  ├─ Check: Move pages/ to app/ with new file conventions
│  ├─ Check: Replace getServerSideProps/getStaticProps with async components
│  ├─ Check: Convert _app.tsx and _document.tsx to layout.tsx
│  ├─ Check: Update data fetching to use fetch() with caching options
│  ├─ Codemod: npx @next/codemod@latest
│  └─ Load: ./references/framework-upgrades.md
│
├─ Vue 2 → 3
│  ├─ Check: Replace Options API with Composition API (optional but recommended)
│  ├─ Check: Replace Vuex with Pinia
│  ├─ Check: Replace event bus with mitt or provide/inject
│  ├─ Check: Update v-model syntax (modelValue prop)
│  ├─ Tool: Migration build (@vue/compat) for incremental migration
│  └─ Load: ./references/framework-upgrades.md
│
├─ Laravel 10 → 11
│  ├─ Check: Adopt slim application skeleton
│  ├─ Check: Update config file structure (consolidated configs)
│  ├─ Check: Review per-second scheduling changes
│  ├─ Check: Update Dumpable trait usage
│  ├─ Tool: laravel shift (automated upgrade service)
│  └─ Load: ./references/framework-upgrades.md
│
├─ Angular (any major version)
│  ├─ Check: Run ng update for guided migration
│  ├─ Check: Review Angular Update Guide (update.angular.io)
│  ├─ Tool: ng update @angular/core @angular/cli
│  └─ Load: ./references/framework-upgrades.md
│
└─ Django (any major version)
   ├─ Check: Run python -Wd manage.py test for deprecation warnings
   ├─ Check: Review Django release notes for removals
   ├─ Tool: django-upgrade (automatic fixer)
   └─ Load: ./references/framework-upgrades.md
```

## Dependency Audit Workflow

```
Ecosystem?
│
├─ JavaScript / Node.js
│  ├─ npm audit / npm audit fix
│  ├─ npx audit-ci --moderate (CI integration)
│  └─ Socket.dev for supply chain analysis
│
├─ Python
│  ├─ pip-audit
│  ├─ safety check
│  └─ pip-audit --fix (auto-update vulnerable packages)
│
├─ Rust
│  ├─ cargo audit
│  └─ cargo deny check advisories
│
├─ Go
│  ├─ govulncheck ./...
│  └─ go list -m -u all (list available updates)
│
├─ PHP
│  ├─ composer audit
│  └─ composer outdated --direct
│
└─ Multi-ecosystem
   └─ Trivy, Snyk, or Dependabot across all
```

## Pre-Migration Checklist

```
[ ] Test coverage measured and documented (target: >70% for critical paths)
[ ] CI pipeline green on current version
[ ] All dependencies up to date (or pinned with rationale)
[ ] Database backup taken (if applicable)
[ ] Git state clean — migration branch created from latest main
[ ] Rollback plan documented and tested
[ ] Breaking change list reviewed from upstream changelog
[ ] Team notified of migration window
[ ] Feature flags in place for gradual rollout (if applicable)
[ ] Monitoring and alerting configured for regression detection
[ ] Performance baseline captured (response times, memory, CPU)
[ ] Lock file committed (package-lock.json, yarn.lock, Cargo.lock, etc.)
```

## Breaking Change Detection Patterns

```
How do you detect breaking changes?
│
├─ Semver Analysis
│  ├─ Major version bump → breaking changes guaranteed
│  ├─ Check CHANGELOG.md or BREAKING_CHANGES.md in repo
│  └─ npm: npx npm-check-updates --target major
│
├─ Changelog Parsing
│  ├─ Search for: "BREAKING", "removed", "deprecated", "renamed"
│  ├─ GitHub: compare releases page between versions
│  └─ Read migration guide if one exists
│
├─ Compiler / Runtime Warnings
│  ├─ Enable all deprecation warnings before upgrading
│  ├─ Python: python -Wd (turn deprecation warnings to errors)
│  ├─ Node: node --throw-deprecation
│  └─ TypeScript: strict mode catches type-level breaks
│
├─ Codemods (automated detection + fix)
│  ├─ jscodeshift — JavaScript/TypeScript AST transforms
│  ├─ ast-grep — language-agnostic structural search/replace
│  ├─ rector — PHP automated refactoring
│  ├─ gofmt / gofumpt — Go formatting changes
│  └─ 2to3 — Python 2 to 3 (legacy)
│
└─ Type Checking
   ├─ TypeScript: tsc --noEmit catches API shape changes
   ├─ Python: mypy / pyright after upgrade
   └─ Go: go vet ./... after upgrade
```

## Codemod Quick Reference

| Ecosystem | Tool | Command | Use Case |
|-----------|------|---------|----------|
| **JS/TS** | jscodeshift | `npx jscodeshift -t transform.ts src/` | Custom AST transforms |
| **JS/TS** | ast-grep | `sg --pattern 'old($$$)' --rewrite 'new($$$)'` | Structural find/replace |
| **React** | react-codemod | `npx codemod@latest react/19/migration-recipe` | React version upgrades |
| **Next.js** | next-codemod | `npx @next/codemod@latest` | Next.js version upgrades |
| **Vue** | vue-codemod | `npx @vue/codemod src/` | Vue 2 to 3 transforms |
| **PHP** | Rector | `vendor/bin/rector process src` | PHP version + framework upgrades |
| **Python** | pyupgrade | `pyupgrade --py312-plus *.py` | Python version syntax upgrades |
| **Python** | django-upgrade | `django-upgrade --target-version 5.0 *.py` | Django version upgrades |
| **Go** | gofmt | `gofmt -w .` | Go formatting updates |
| **Go** | gofix | `go fix ./...` | Go API changes |
| **Rust** | cargo fix | `cargo fix --edition` | Rust edition migration |
| **Multi** | ast-grep | `sg scan --rule rules.yml` | Any language with custom rules |

## Rollback Strategy Decision Tree

```
Migration failed or caused issues — how to roll back?
│
├─ Code-only change, no data migration
│  ├─ Small number of commits
│  │  └─ Git Revert
│  │     git revert --no-commit HEAD~N..HEAD && git commit
│  │     Pros: clean history, safe for shared branches
│  │     Cons: merge conflicts if code has diverged
│  │
│  └─ Entire feature branch
│     └─ Revert merge commit
│        git revert -m 1 <merge-commit-sha>
│
├─ Feature flag controlled
│  └─ Toggle flag off
│     Instant rollback, no deployment needed
│     Keep old code path until new path is proven
│
├─ Database schema changed
│  ├─ Reversible migration exists
│  │  └─ Run down migration
│  │     rails db:rollback / php artisan migrate:rollback / alembic downgrade
│  │
│  └─ Irreversible migration (dropped column, changed type)
│     └─ Restore from backup + replay write-ahead log
│        This is why you take backups BEFORE migration
│
└─ Infrastructure / deployment
   ├─ Blue-Green deployment
   │  └─ Switch traffic back to blue (old) environment
   │
   ├─ Canary deployment
   │  └─ Route 100% traffic back to stable version
   │
   └─ Container orchestration (K8s)
      └─ kubectl rollout undo deployment/app
```

## Common Gotchas

| Gotcha | Why It Happens | Prevention |
|--------|---------------|------------|
| Upgrading multiple major versions at once | Each major version may have sequential breaking changes that compound | Upgrade one major version at a time, verify, then proceed |
| Lock file not committed before migration | Cannot reproduce pre-migration dependency state | Always commit lock files; take a snapshot branch before starting |
| Running codemods without committing first | Cannot diff what the codemod changed vs your manual changes | Commit clean state, run codemod, commit codemod changes separately |
| Ignoring deprecation warnings in current version | Deprecated APIs are removed in next major version | Fix all deprecation warnings BEFORE upgrading |
| Testing only happy paths after migration | Edge cases and error paths are most likely to break | Run full test suite plus manual exploratory testing |
| Not checking transitive dependencies | A direct dep upgrade may pull in incompatible transitive deps | Use `npm ls`, `pip show`, `cargo tree` to inspect dependency tree |
| Assuming codemods catch everything | Codemods handle common patterns, not all patterns | Review codemod output manually; check for skipped files |
| Skipping the migration guide | Framework authors document known pitfalls and workarounds | Read the official migration guide end-to-end before starting |
| Migrating in a long-lived branch | Main branch diverges, causing painful merge conflicts | Use feature flags for incremental migration on main |
| Not updating CI to test both versions | CI passes on old version but new version has failures | Add matrix testing for both versions during transition |
| Database migration without backup | Irreversible schema changes with no recovery path | Always backup before migration; test rollback procedure |
| Forgetting to update Docker/CI base images | Code upgraded but runtime is still old version | Update Dockerfile FROM, CI config, and deployment manifests |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/framework-upgrades.md` | React 18→19, Next.js Pages→App Router, Vue 2→3, Laravel 10→11, Angular, Django upgrade paths | ~700 |
| `references/language-upgrades.md` | Python 3.9→3.13, Node 18→22, TypeScript 4→5, Go 1.20→1.23, Rust 2021→2024, PHP 8.1→8.4 | ~600 |
| `references/dependency-management.md` | Audit tools, update strategies, lock files, monorepo deps, supply chain security | ~550 |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `testing-ops` | Ensuring test coverage before migration, writing regression tests after |
| `debug-ops` | Diagnosing failures introduced by migration, bisecting breaking commits |
| `git-workflow` | Branch strategy for migration, git bisect to find breaking change |
| `refactor-ops` | Code transformations that often accompany version upgrades |
| `ci-cd-ops` | Updating CI pipelines to test against new versions, matrix builds |
| `container-orchestration` | Updating base images, Dockerfile changes for new runtime versions |
| `security-ops` | Vulnerability remediation that triggers dependency upgrades |
