---
name: testgen
description: "Generate tests with skill-preloaded routing, framework detection, and auto-TaskCreate. Triggers on: generate tests, write tests, testgen, create test file, add test coverage."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Task TaskCreate"
metadata:
  when_to_use: "Use when the user asks to generate or expand tests for a file, function, or directory — e.g. 'write tests for auth.ts', 'add coverage for the parser', 'create a test file for this module'."
  argument-hint: "<target> [--focus happy|edge|error|all] [--depth quick|normal|thorough] [--visual]"
  author: claude-mods
---

# TestGen Skill - AI Test Generation

Generate comprehensive tests with automatic framework detection, skill-preloaded general-purpose dispatch, and project convention matching.

## Architecture

```
testgen <target> [--type] [--focus] [--depth]
    │
    ├─→ Step 1: Analyze Target
    │     ├─ File exists? → Read and parse
    │     ├─ Function specified? → Extract signature
    │     ├─ Directory? → List source files
    │     └─ Find existing tests (avoid duplicates)
    │
    ├─→ Step 2: Detect Framework (parallel)
    │     ├─ package.json → jest/vitest/mocha/cypress/playwright
    │     ├─ pyproject.toml → pytest/unittest
    │     ├─ go.mod → go test
    │     ├─ Cargo.toml → cargo test
    │     ├─ composer.json → phpunit/pest
    │     └─ Check existing test patterns
    │
    ├─→ Step 3: Load Project Standards
    │     ├─ AGENTS.md, CLAUDE.md conventions
    │     ├─ Existing test file structure
    │     └─ Naming conventions (*.test.ts vs *.spec.ts)
    │
    ├─→ Step 4: Route to Test Generator (general-purpose + skill preload)
    │     ├─ .ts → general-purpose, preload typescript-ops
    │     ├─ .tsx/.jsx → general-purpose, preload react-ops
    │     ├─ .vue → general-purpose, preload vue-ops
    │     ├─ .py → general-purpose, preload python-pytest-ops
    │     ├─ .go → general-purpose, preload go-ops
    │     ├─ .rs → general-purpose, preload rust-ops
    │     ├─ .php → general-purpose, preload laravel-ops
    │     ├─ E2E/Cypress → general-purpose, preload cypress-ops
    │     ├─ Playwright → general-purpose, preload typescript-ops
    │     ├─ Shell/bash → general-purpose, preload bash-ops
    │     ├─ --visual → Chrome DevTools MCP
    │     └─ Multi-file → parallel general-purpose dispatch
    │
    ├─→ Step 5: Generate Tests
    │     ├─ Create test file in correct location
    │     ├─ Follow detected conventions
    │     └─ Include: happy path, edge cases, error handling
    │
    └─→ Step 6: Integration
          ├─ Auto-create task (TaskCreate) for verification
          └─ Suggest: run tests, /review, /save
```

## Execution Steps

### Step 1: Analyze Target

```bash
# Check if target exists
test -f "$TARGET" && echo "FILE" || test -d "$TARGET" && echo "DIRECTORY"

# For function-specific: extract signature
command -v ast-grep >/dev/null 2>&1 && ast-grep -p "function $FUNCTION_NAME" "$FILE"

# Fallback to ripgrep
rg "(?:function|const|def|public|private)\s+$FUNCTION_NAME" "$FILE" -A 10
```

**Check for existing tests:**
```bash
fd -e test.ts -e spec.ts -e test.js -e spec.js | rg "$BASENAME"
fd "test_*.py" | rg "$BASENAME"
```

### Step 2: Detect Framework

**JavaScript/TypeScript:**
```bash
cat package.json 2>/dev/null | jq -r '.devDependencies | keys[]' | grep -E 'jest|vitest|mocha|cypress|playwright|@testing-library'
```

**Python:**
```bash
grep -E "pytest|unittest|nose" pyproject.toml setup.py requirements*.txt 2>/dev/null
```

**Go:**
```bash
test -f go.mod && echo "go test available"
```

**Rust:**
```bash
test -f Cargo.toml && echo "cargo test available"
```

**PHP:**
```bash
cat composer.json 2>/dev/null | jq -r '.["require-dev"] | keys[]' | grep -E 'phpunit|pest|codeception'
```

### Step 3: Load Project Standards

```bash
# Claude Code conventions
cat AGENTS.md 2>/dev/null | head -50
cat CLAUDE.md 2>/dev/null | head -50

# Test config files
cat jest.config.* vitest.config.* pytest.ini pyproject.toml 2>/dev/null | head -30
```

**Test location conventions:**
```
# JavaScript
src/utils/helper.ts → src/utils/__tests__/helper.test.ts  # __tests__ folder
                    → src/utils/helper.test.ts            # co-located
                    → tests/utils/helper.test.ts          # separate tests/

# Python
app/utils/helper.py → tests/test_helper.py               # tests/ folder
                    → tests/utils/test_helper.py         # mirror structure

# Go
pkg/auth/token.go → pkg/auth/token_test.go               # co-located (required)

# Rust
src/auth.rs → src/auth.rs (mod tests { ... })            # inline tests
            → tests/auth_test.rs                          # integration tests
```

### Step 4: Route to Test Generator

Dispatch is skills-first: the generic `general-purpose` subagent preloads the relevant `-ops` skill before generating tests.

| File Pattern | Dispatch | Preload |
|--------------|----------|---------|
| `*.ts` | general-purpose | `skills/typescript-ops/SKILL.md` |
| `*.tsx`, `*.jsx` | general-purpose | `skills/react-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.vue` | general-purpose | `skills/vue-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.py` | general-purpose | `skills/python-pytest-ops/SKILL.md` |
| `*.go` | general-purpose | `skills/go-ops/SKILL.md` |
| `*.rs` | general-purpose | `skills/rust-ops/SKILL.md` |
| `*.php` | general-purpose | `skills/laravel-ops/SKILL.md` |
| `*.cy.ts`, `cypress/*` | general-purpose | `skills/cypress-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.spec.ts` (Playwright) | general-purpose | `skills/playwright-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `playwright/*`, `e2e/*` | general-purpose | `skills/playwright-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.sh`, `*.bash` | general-purpose | `skills/bash-ops/SKILL.md` |
| (--visual flag) | Chrome DevTools MCP | `skills/typescript-ops/SKILL.md` |

**Invoke via Task tool:**
```
Task tool with subagent_type: "general-purpose" (or surviving specialist from table)
model: "sonnet"
Prompt includes:
  - Skill preloading (domain knowledge):
    "First, read these files for testing context:
     - Read: skills/security-ops/references/owasp-detailed.md
     - Read: skills/testing-ops/SKILL.md
     - Read: [Preload column for the matched file pattern]"
  - Source file content
  - Function signatures to test
  - Detected framework and conventions
  - Requested test type and focus
```

**Language-specific preloads** (append to the preloading section above):

| Language | Additional Preload | Why |
|----------|-------------------|-----|
| Python | `skills/python-pytest-ops/SKILL.md` | Fixtures, marks, parametrize, async testing |
| Go | `skills/go-ops/SKILL.md` | Table-driven tests, benchmarks, testify |
| Rust | `skills/rust-ops/SKILL.md` | Property testing, criterion, proptest |

### Step 5: Generate Tests

**Test categories based on --focus:**

| Focus | What to Generate |
|-------|------------------|
| `happy` | Normal input, expected output |
| `edge` | Boundary values, empty inputs, nulls |
| `error` | Invalid inputs, exceptions, error handling |
| `all` | All of the above (default) |

**Depth levels:**

| Depth | Coverage |
|-------|----------|
| `quick` | Happy path only, 1-2 tests per function |
| `normal` | Happy + common edge cases (default) |
| `thorough` | Comprehensive: all paths, mocking, async |

### Step 6: Integration

**Auto-create task:**
```
TaskCreate:
  subject: "Run generated tests for src/auth.ts"
  description: "Verify generated tests pass and review edge cases"
  activeForm: "Running generated tests for auth.ts"
```

**Suggest next steps:**
```
Tests generated: src/auth.test.ts

Next steps:
1. Run tests: npm test src/auth.test.ts
2. Review and refine edge cases
3. Use /save to persist tasks across sessions
```

---

## Routing Details

### TypeScript/JavaScript (preload typescript-ops)
- Proper type imports
- Generic type handling
- Async/await patterns
- Mock typing

### React/JSX (preload react-ops)
- React Testing Library patterns
- Component rendering tests
- Hook testing (renderHook)
- Accessibility queries (getByRole)

### Vue (preload vue-ops)
- Vue Test Utils patterns
- Composition API testing
- Pinia store mocking

### Python (preload python-pytest-ops)
- pytest fixtures
- Parametrized tests
- Mock/patch patterns
- Async test handling

### Go (preload go-ops)
- Table-driven tests (`[]struct` pattern)
- `testing.T` and subtests (`t.Run`)
- Testify assertions (when detected)
- Benchmark functions (`testing.B`)
- Parallel tests (`t.Parallel()`)

### Rust (preload rust-ops)
- `#[test]` attribute functions
- `#[cfg(test)]` module organization
- `#[should_panic]` for error testing
- proptest/quickcheck for property testing

### PHP/Laravel (preload laravel-ops)
- PHPUnit/Pest patterns
- Database transactions
- Factory usage

### E2E/Cypress (preload cypress-ops)
- Page object patterns
- Custom commands
- Network stubbing

### Shell/bash (preload bash-ops)
- bats / shunit2 patterns
- Stubbing external commands
- Exit-code and stderr assertions

### Playwright (preload typescript-ops)
- Page object model patterns
- Locator strategies
- Visual regression testing

---

## CLI Tool Integration

| Tool | Purpose | Fallback |
|------|---------|----------|
| `jq` | Parse package.json | Read tool |
| `rg` | Find existing tests | Grep tool |
| `ast-grep` | Parse function signatures | ripgrep patterns |
| `fd` | Find test files | Glob tool |
| Chrome DevTools MCP | Visual testing (--visual) | Playwright/Cypress |

**Graceful degradation:**
```bash
command -v jq >/dev/null 2>&1 && cat package.json | jq '.devDependencies' || cat package.json
```

---

## Reference Files

For framework-specific code examples, see:
- `frameworks.md` - Complete test examples for all supported languages
- `visual-testing.md` - Chrome DevTools integration for --visual flag

---

## Integration

| Command | Relationship |
|---------|--------------|
| `/review` | Review generated tests before committing |
| `/explain` | Understand complex code before testing |
| `/save` | Track test coverage goals |
