---
name: refactor-ops
description: "Safe refactoring patterns - extract, rename, restructure with test-driven methodology and dead code detection. Use for: refactor, refactoring, extract function, extract component, rename, move file, restructure, dead code, unused imports, code smell, duplicate code, long function, god object, feature envy, DRY, technical debt, cleanup, simplify, decompose, inline, pull up, push down, strangler fig, parallel change."
allowed-tools: "Read Edit Write Bash Glob Grep Agent"
related-skills: [testing-ops, structural-search, debug-ops, code-stats, migrate-ops]
---

# Refactor Operations

Comprehensive refactoring skill covering safe transformation patterns, code smell detection, dead code elimination, and test-driven refactoring methodology.

## Refactoring Decision Tree

```
What kind of refactoring do you need?
│
├─ Extracting code into a new unit
│  ├─ A block of statements with a clear purpose
│  │  └─ Extract Function/Method
│  │     Identify inputs (params) and outputs (return value)
│  │
│  ├─ A UI element with its own state or props
│  │  └─ Extract Component (React, Vue, Svelte)
│  │     Move JSX/template + related state into new file
│  │
│  ├─ Reusable stateful logic (not UI)
│  │  └─ Extract Hook / Composable
│  │     React: useCustomHook, Vue: useComposable
│  │
│  ├─ A file has grown beyond 300-500 lines
│  │  └─ Extract Module
│  │     Split by responsibility, create barrel exports
│  │     Watch for circular dependencies
│  │
│  ├─ A class does too many things (SRP violation)
│  │  └─ Extract Class / Service
│  │     One responsibility per class, use dependency injection
│  │
│  └─ Magic numbers, hardcoded strings, env-specific values
│     └─ Extract Configuration
│        Constants file, env vars, feature flags
│
├─ Renaming for clarity
│  ├─ Variable, function, or method
│  │  └─ Rename Symbol
│  │     Update all references (IDE rename or ast-grep)
│  │
│  ├─ File or directory
│  │  └─ Rename File + Update Imports
│  │     git mv to preserve history, update all import paths
│  │
│  └─ Module or package
│     └─ Rename Module + Update All Consumers
│        Search for all import/require references
│        Consider re-exporting from old name temporarily
│
├─ Moving code to a better location
│  ├─ Function/class to a different file
│  │  └─ Move + Re-export from Original
│  │     Leave re-export for one release cycle
│  │
│  ├─ Files to a different directory
│  │  └─ Restructure + Update All Paths
│  │     Use IDE refactoring or find-and-replace
│  │
│  └─ Reorganize entire directory structure
│     └─ Incremental Migration
│        Move one module at a time, keep tests green
│
├─ Simplifying existing code
│  ├─ Function is too simple to justify its own name
│  │  └─ Inline Function
│  │     Replace call sites with the body
│  │
│  ├─ Variable used only once, right after assignment
│  │  └─ Inline Variable
│  │     Replace variable with expression
│  │
│  ├─ Deep nesting (> 3 levels)
│  │  └─ Guard Clauses + Early Returns
│  │     Invert conditions, return early
│  │
│  └─ Complex conditionals
│     └─ Decompose Conditional
│        Extract each branch into named function
│
└─ Removing dead code
   ├─ Unused imports
   │  └─ Lint + Auto-fix (eslint, ruff, goimports)
   │
   ├─ Unreachable code branches
   │  └─ Static analysis + manual review
   │
   ├─ Orphaned files (no imports point to them)
   │  └─ Dependency graph analysis (knip, ts-prune, vulture)
   │
   └─ Unused exports
      └─ ts-prune, knip, or manual grep for import references
```

## Safety Checklist

Run through this checklist before starting any refactoring:

```
Pre-Refactoring
[ ] All tests pass (full suite, not just related tests)
[ ] Working tree is clean (git status shows no uncommitted changes)
[ ] On a dedicated branch (not main/master)
[ ] CI is green on the base branch
[ ] You understand what the code does (read it, don't assume)
[ ] Characterization tests exist for untested code you will change

During Refactoring
[ ] Each commit compiles and all tests pass
[ ] Commits are small and focused (one refactoring per commit)
[ ] No behavior changes mixed with structural changes
[ ] Running tests after every change (use --watch mode)

Post-Refactoring
[ ] Full test suite passes
[ ] No new warnings from linter or type checker
[ ] Code review requested (refactoring PRs need fresh eyes)
[ ] Performance benchmarks unchanged (if applicable)
[ ] Documentation updated (if public API changed)
```

## Extract Patterns Quick Reference

| Pattern | When to Use | Key Considerations |
|---------|-------------|-------------------|
| **Extract Function** | Block of code has a clear single purpose, used or could be reused | Name should describe WHAT, not HOW. Pure functions preferred. |
| **Extract Component** | UI element has own state, props, or rendering logic | Props interface should be minimal. Avoid prop drilling. |
| **Extract Hook/Composable** | Stateful logic shared across components | Must start with `use`. Return stable references. |
| **Extract Module** | File exceeds 300-500 lines, has multiple responsibilities | One module = one responsibility. Barrel exports for public API. |
| **Extract Class/Service** | Object handles too many concerns | Dependency injection over hard-coded dependencies. |
| **Extract Configuration** | Magic numbers, environment-specific values, feature flags | Type-safe config objects over loose constants. |

## Rename Patterns Quick Reference

| What to Rename | Method | Pitfalls |
|----------------|--------|----------|
| **Variable/function** | IDE rename (F2) or `ast-grep` | String references (logs, error messages) not caught by IDE |
| **Class/type** | IDE rename + update file name to match | Serialized data may reference old name (JSON, DB) |
| **File** | `git mv old new` + update all imports | Import paths in test files, storybook, config files often missed |
| **Directory** | `git mv` + bulk import update | Barrel re-exports, path aliases in tsconfig/webpack |
| **Package/module** | Rename + re-export from old name | External consumers need deprecation period |

## Move/Restructure Quick Reference

| Scenario | Strategy | Safety Net |
|----------|----------|------------|
| **Single file move** | `git mv` + update imports + re-export from old path | `rg 'old/path'` to find all references |
| **Multiple related files** | Move together, update barrel exports | Run type checker after each move |
| **Directory restructure** | Incremental: one directory per PR | Keep old paths working via re-exports |
| **Monorepo package split** | Extract to new package, update all consumers | Version the new package, pin consumers |

## Dead Code Detection Workflow

```
Step 1: Automated Detection
│
├─ TypeScript/JavaScript
│  ├─ knip (comprehensive: files, deps, exports)
│  │  └─ npx knip --reporter compact
│  ├─ ts-prune (unused exports)
│  │  └─ npx ts-prune
│  └─ eslint (unused vars/imports)
│     └─ eslint --rule 'no-unused-vars: error'
│
├─ Python
│  ├─ vulture (dead code finder)
│  │  └─ vulture src/ --min-confidence 80
│  ├─ ruff (unused imports)
│  │  └─ ruff check --select F401
│  └─ coverage.py (unreachable branches)
│     └─ coverage run && coverage report --show-missing
│
├─ Go
│  └─ staticcheck / golangci-lint
│     └─ golangci-lint run --enable unused,deadcode
│
├─ Rust
│  └─ Compiler warnings (dead_code, unused_imports)
│     └─ cargo build 2>&1 | rg 'warning.*unused'
│
Step 2: Manual Verification
│  ├─ Check if "unused" code is used via reflection/dynamic import
│  ├─ Check if exports are part of public API consumed externally
│  ├─ Check if code is used in scripts, tests, or tooling not in the scan
│  └─ Check if code is behind a feature flag or A/B test
│
Step 3: Remove with Confidence
│  ├─ Remove in small batches, not all at once
│  ├─ One commit per logical group of dead code
│  └─ Keep git history -- you can always recover
```

## Code Smell Detection

| Smell | Heuristic | Refactoring |
|-------|-----------|-------------|
| **Long function** | > 20 lines or > 5 levels of indentation | Extract Function, Decompose Conditional |
| **God object** | Class with > 10 methods or > 500 lines | Extract Class, Split by responsibility |
| **Feature envy** | Method uses another object's data more than its own | Move Method to the class whose data it uses |
| **Duplicate code** | Same logic in 2+ places (> 5 similar lines) | Extract Function, Extract Module |
| **Deep nesting** | > 3 levels of if/for/while nesting | Guard Clauses, Early Returns, Extract Function |
| **Primitive obsession** | Using strings/numbers where a type would be safer | Value Objects, Branded Types, Enums |
| **Shotgun surgery** | One change requires editing 5+ files | Move related code together, Extract Module |
| **Dead code** | Unreachable branches, unused exports/imports | Delete it (git has history) |
| **Data clumps** | Same group of parameters passed together repeatedly | Extract Parameter Object or Config Object |
| **Long parameter list** | Function takes > 4 parameters | Extract Parameter Object, Builder Pattern |

## Test-Driven Refactoring Methodology

```
Refactoring Untested Code
│
├─ Step 1: Write Characterization Tests
│  │  Capture CURRENT behavior, even if it seems wrong
│  │  These tests document what the code actually does
│  └─ Goal: safety net, not correctness proof
│
├─ Step 2: Verify Coverage
│  │  Run coverage tool, ensure all paths you will touch are covered
│  └─ Add more tests if coverage is insufficient
│
├─ Step 3: Refactor in Small Steps
│  │  One transformation at a time
│  │  Run tests after EVERY change
│  └─ If tests fail, undo and try smaller step
│
├─ Step 4: Improve Tests
│  │  Now that code is cleaner, write better tests
│  │  Replace characterization tests with intention-revealing tests
│  └─ Add edge cases discovered during refactoring
│
└─ Step 5: Commit and Review
   │  Separate commits: tests first, then refactoring
   └─ Reviewers can verify tests pass on old code too
```

## Tool Reference

| Tool | Language | Use Case | Command |
|------|----------|----------|---------|
| **ast-grep** | Multi | Structural search and replace | `sg -p 'console.log($$$)' -r '' -l js` |
| **jscodeshift** | JS/TS | Large-scale AST-based codemods | `jscodeshift -t transform.js src/` |
| **eslint --fix** | JS/TS | Auto-fix lint violations | `eslint --fix 'src/**/*.ts'` |
| **ruff** | Python | Fast linting and auto-fix | `ruff check --fix src/` |
| **goimports** | Go | Organize imports | `goimports -w .` |
| **clippy** | Rust | Lint and suggest improvements | `cargo clippy --fix` |
| **knip** | JS/TS | Find unused files, deps, exports | `npx knip` |
| **ts-prune** | TS | Find unused exports | `npx ts-prune` |
| **vulture** | Python | Find dead code | `vulture src/ --min-confidence 80` |
| **rope** | Python | Refactoring library | Python API for rename, extract, move |
| **IDE rename** | All | Rename with reference updates | F2 in VS Code, Shift+F6 in JetBrains |
| **sd** | All | Find and replace in files | `sd 'oldName' 'newName' src/**/*.ts` |

## Common Gotchas

| Gotcha | Why It Happens | Prevention |
|--------|---------------|------------|
| Refactoring and behavior change in same commit | Tempting to "fix while you're in there" | Separate commits: refactor first, then change behavior |
| Breaking public API during internal refactor | Renamed/moved exports consumed by external code | Re-export from old path, deprecation warnings |
| Circular dependencies after extracting modules | New module imports from original, original imports from new | Dependency graph check after each extraction |
| Tests pass but runtime breaks | Tests mock the refactored code, hiding the break | Integration tests alongside unit tests |
| git history lost after file move | Used `cp` + `rm` instead of `git mv` | Always `git mv`, verify with `git log --follow` |
| Renaming misses string references | IDE rename only catches code references, not configs/docs | `rg 'oldName'` across entire repo after rename |
| Over-abstracting (premature DRY) | Extracting after seeing only 2 occurrences | Rule of three: wait for 3 duplicates before extracting |
| Extracting coupled code | New function has 8 parameters because code is entangled | Refactor coupling first, then extract |
| Dead code removal breaks reflection/plugins | Dynamic imports, dependency injection, decorators | Grep for string references, check plugin registries |
| Performance regression after extraction | Extra function calls, lost inlining, cache misses | Benchmark before and after for hot paths |
| Merge conflicts from large refactoring PR | Long-lived branch diverges from main | Small PRs, merge main frequently, or use stacked PRs |
| Type errors after moving files | Path aliases, tsconfig paths, barrel exports not updated | Run type checker after every file move |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/extract-patterns.md` | Extract function, component, hook, module, class, configuration -- with before/after examples in multiple languages | ~700 |
| `references/code-smells.md` | Code smell catalog with detection heuristics, tools by language, complexity metrics | ~650 |
| `references/safe-methodology.md` | Test-driven refactoring, strangler fig, parallel change, branch by abstraction, feature flags, rollback | ~550 |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `testing-ops` | Write characterization tests before refactoring, test strategy for refactored code |
| `structural-search` | Use ast-grep for structural find-and-replace across codebase |
| `debug-ops` | When refactoring exposes hidden bugs or introduces regressions |
| `code-stats` | Measure complexity before and after refactoring to quantify improvement |
| `migrate-ops` | Large-scale migrations that require systematic refactoring |
| `git-ops` | Branch strategy for refactoring PRs, stacked PRs, bisect to find regressions |
