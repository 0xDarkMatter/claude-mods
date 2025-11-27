---
description: "Generate tests for code with automatic framework detection. Creates unit tests, integration tests, or test stubs based on your stack."
---

# Test - Generate Tests

Generate tests for your code with automatic framework detection.

## Arguments

$ARGUMENTS

- File path: Generate tests for specific file
- Function name: Generate tests for specific function
- `--type <unit|integration|e2e>`: Specify test type
- `--framework <jest|vitest|pytest|etc>`: Override detected framework

## What This Command Does

1. **Detect Test Framework**
   - Scan package.json, pyproject.toml, etc.
   - Identify existing test patterns
   - Determine conventions in use

2. **Analyze Target Code**
   - Parse functions/classes
   - Identify inputs/outputs
   - Find edge cases

3. **Generate Tests**
   - Create test file in correct location
   - Follow project conventions
   - Include common edge cases

## Framework Detection

### JavaScript/TypeScript
```bash
# Check package.json for:
- jest
- vitest
- mocha
- ava
- @testing-library/*
```

### Python
```bash
# Check for:
- pytest (pyproject.toml, pytest.ini)
- unittest (default)
- nose2
```

### Other
- Go: built-in testing
- Rust: built-in testing
- PHP: PHPUnit

## Execution Steps

### Step 1: Detect Framework

```bash
# JavaScript
cat package.json | jq '.devDependencies | keys[]' | grep -E 'jest|vitest|mocha'

# Python
grep -l "pytest" pyproject.toml setup.py requirements*.txt 2>/dev/null
```

### Step 2: Analyze Target Code

Read the target file and extract:
- Function signatures
- Input parameters and types
- Return types
- Dependencies/imports
- Existing patterns

### Step 3: Determine Test Location

```
# JavaScript conventions
src/utils/helper.ts → src/utils/__tests__/helper.test.ts
                   → src/utils/helper.test.ts
                   → tests/utils/helper.test.ts

# Python conventions
app/utils/helper.py → tests/test_helper.py
                   → app/utils/test_helper.py
                   → tests/utils/test_helper.py
```

### Step 4: Generate Test File

Create comprehensive tests including:
- Happy path
- Edge cases (null, empty, boundary values)
- Error cases
- Async handling (if applicable)

## Output Format

### Jest/Vitest (TypeScript)

```typescript
import { describe, it, expect, vi } from 'vitest';
import { functionName } from '../path/to/module';

describe('functionName', () => {
  it('should handle normal input', () => {
    const result = functionName('input');
    expect(result).toBe('expected');
  });

  it('should handle empty input', () => {
    expect(() => functionName('')).toThrow();
  });

  it('should handle null input', () => {
    expect(functionName(null)).toBeNull();
  });
});
```

### pytest (Python)

```python
import pytest
from app.module import function_name

class TestFunctionName:
    def test_normal_input(self):
        result = function_name("input")
        assert result == "expected"

    def test_empty_input(self):
        with pytest.raises(ValueError):
            function_name("")

    def test_none_input(self):
        assert function_name(None) is None
```

## Usage Examples

```bash
# Generate tests for a file
/test src/utils/auth.ts

# Generate tests for specific function
/test src/utils/auth.ts:validateToken

# Specify test type
/test src/api/users.ts --type integration

# Override framework detection
/test src/helpers.js --framework jest

# Generate test stubs only (no implementation)
/test src/complex.ts --stubs
```

## Test Types

| Type | Purpose | Generated For |
|------|---------|---------------|
| `unit` | Test isolated functions | Pure functions, utilities |
| `integration` | Test component interactions | API routes, services |
| `e2e` | End-to-end flows | User journeys |
| `snapshot` | UI snapshot tests | React components |

## Flags

| Flag | Effect |
|------|--------|
| `--type <type>` | Specify test type |
| `--framework <fw>` | Override framework detection |
| `--stubs` | Generate empty test stubs only |
| `--coverage` | Focus on uncovered code paths |
| `--verbose` | Explain test reasoning |

## Smart Features

### Dependency Mocking
Automatically detects and mocks:
- External API calls
- Database operations
- File system operations
- Environment variables

### Edge Case Generation
Automatically includes tests for:
- Null/undefined values
- Empty strings/arrays
- Boundary values (0, -1, MAX_INT)
- Invalid types
- Async error handling

### Convention Following
Matches existing project patterns:
- Test file naming
- Directory structure
- Import styles
- Assertion library

## Integration

After generating tests:

```bash
# Run the new tests
npm test -- --watch <test-file>
pytest <test-file> -v

# Check coverage
npm test -- --coverage
pytest --cov=app
```

## Notes

- Generated tests are starting points, refine as needed
- Review mocks for accuracy
- Add integration tests manually for complex flows
- Use `--stubs` when you want to write tests yourself
