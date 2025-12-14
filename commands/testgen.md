---
description: "Generate tests with expert routing, framework detection, and auto-TodoWrite. Creates unit, integration, or E2E tests following project conventions."
---

# TestGen - AI Test Generation

Generate comprehensive tests for your code with automatic framework detection, expert agent routing, and project convention matching. Routes to specialized experts (python-expert, react-expert, cypress-expert) for domain-specific test patterns.

## Arguments

$ARGUMENTS

- `<file>`: Generate tests for specific file
- `<file>:<function>`: Generate tests for specific function/method
- `<directory>`: Generate tests for all files in directory
- `--type <unit|integration|e2e|component>`: Specify test type
- `--framework <jest|vitest|pytest|...>`: Override detected framework
- `--focus <happy|edge|error|all>`: Focus on specific test cases
- `--depth <quick|normal|thorough>`: Generation depth
- `--stubs`: Generate empty test stubs only

## Architecture

```
/testgen <target> [--type] [--focus] [--depth]
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
    │     ├─ composer.json → phpunit/pest
    │     ├─ Check existing test patterns
    │     └─ Fallback: infer from file extension
    │
    ├─→ Step 3: Load Project Standards
    │     ├─ AGENTS.md, CLAUDE.md conventions
    │     ├─ Existing test file structure
    │     ├─ Import styles and assertion library
    │     └─ Naming conventions (*.test.ts vs *.spec.ts)
    │
    ├─→ Step 4: Route to Expert Agent
    │     ├─ .ts → typescript-expert
    │     ├─ .tsx/.jsx → react-expert
    │     ├─ .vue → vue-expert
    │     ├─ .py → python-expert
    │     ├─ .php → laravel-expert
    │     ├─ E2E tests → cypress-expert
    │     └─ Multi-file → parallel expert dispatch
    │
    ├─→ Step 5: Generate Tests
    │     ├─ Create test file in correct location
    │     ├─ Follow detected conventions
    │     ├─ Include: happy path, edge cases, error handling
    │     └─ Add proper mocking for dependencies
    │
    └─→ Step 6: Integration
          ├─ Auto-create TodoWrite for generated tests
          ├─ Suggest: run tests to verify
          └─ Link to /saveplan for tracking
```

## Execution Steps

### Step 1: Analyze Target

```bash
# Check if target exists
test -f "$TARGET" && echo "FILE" || test -d "$TARGET" && echo "DIRECTORY"

# For function-specific: parse the file
# /testgen src/auth.ts:validateToken → extract validateToken signature
```

**Extract function signature:**
```bash
# Use ast-grep if available
command -v ast-grep >/dev/null 2>&1 && ast-grep -p "function $FUNCTION_NAME" "$FILE"

# Fallback to ripgrep
rg "(?:function|const|def|public|private)\s+$FUNCTION_NAME" "$FILE" -A 10
```

**Check for existing tests:**
```bash
# Find related test files
fd -e test.ts -e spec.ts -e test.js -e spec.js | rg "$BASENAME"

# Python
fd "test_*.py" | rg "$BASENAME"
```

### Step 2: Detect Framework

**JavaScript/TypeScript:**
```bash
# Check package.json devDependencies
cat package.json 2>/dev/null | jq -r '.devDependencies | keys[]' | grep -E 'jest|vitest|mocha|cypress|playwright|@testing-library'
```

**Python:**
```bash
# Check pyproject.toml or requirements
grep -E "pytest|unittest|nose" pyproject.toml setup.py requirements*.txt 2>/dev/null
```

**PHP:**
```bash
# Check composer.json
cat composer.json 2>/dev/null | jq -r '.["require-dev"] | keys[]' | grep -E 'phpunit|pest|codeception'
```

**Detect test patterns:**
```bash
# Find existing test files to match conventions
fd -e test.ts -e spec.ts -e test.tsx -e spec.tsx | head -3
fd "test_*.py" tests/ | head -3
```

### Step 3: Load Project Standards

**Check for conventions:**
```bash
# Claude Code conventions
cat AGENTS.md 2>/dev/null | head -50
cat CLAUDE.md 2>/dev/null | head -50

# Test config files
cat jest.config.* vitest.config.* pytest.ini pyproject.toml 2>/dev/null | head -30
```

**Determine test location convention:**
```
# JavaScript conventions (detect which is used)
src/utils/helper.ts → src/utils/__tests__/helper.test.ts  # __tests__ folder
                    → src/utils/helper.test.ts            # co-located
                    → tests/utils/helper.test.ts          # separate tests/

# Python conventions
app/utils/helper.py → tests/test_helper.py               # tests/ folder
                    → tests/utils/test_helper.py         # mirror structure
                    → app/utils/test_helper.py           # co-located

# PHP conventions
app/Services/UserService.php → tests/Unit/Services/UserServiceTest.php
                             → tests/Feature/UserServiceTest.php
```

### Step 4: Route to Expert Agent

| File Pattern | Primary Expert | Secondary |
|--------------|----------------|-----------|
| `*.ts` | typescript-expert | - |
| `*.tsx`, `*.jsx` | react-expert | typescript-expert |
| `*.vue` | vue-expert | typescript-expert |
| `*.py` | python-expert | - |
| `*.php` | laravel-expert | - |
| `*.cy.ts`, `cypress/*` | cypress-expert | - |
| `*.spec.ts` (Playwright) | - | typescript-expert |
| `*.sh`, `*.bash` | bash-expert | - |

**Invoke via Task tool:**
```
Task tool with subagent_type: "[detected]-expert"
Prompt includes:
  - Source file content
  - Function signatures to test
  - Detected framework and conventions
  - Requested test type and focus
  - Project conventions from AGENTS.md
```

### Step 5: Generate Tests

The expert produces tests following this structure:

**Include test categories based on --focus:**

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

**Auto-create TodoWrite:**
```
TodoWrite:
  - content: "Run generated tests for src/auth.ts"
    status: "pending"
    activeForm: "Running generated tests for auth.ts"
```

**Suggest next steps:**
```
Tests generated: src/auth.test.ts

Next steps:
1. Run tests: npm test src/auth.test.ts
2. Review and refine edge cases
3. Use /saveplan to track test coverage goals
```

---

## Expert Routing Details

### TypeScript/JavaScript → typescript-expert

Generates tests with:
- Proper type imports
- Generic type handling
- Async/await patterns
- Mock typing

### React/JSX → react-expert

Generates tests with:
- React Testing Library patterns
- Component rendering tests
- Hook testing (renderHook)
- Event simulation
- Accessibility queries (getByRole)

### Vue → vue-expert

Generates tests with:
- Vue Test Utils patterns
- Composition API testing
- Pinia store mocking
- Component mounting

### Python → python-expert

Generates tests with:
- pytest fixtures
- Parametrized tests
- Mock/patch patterns
- Async test handling
- Type hint verification

### PHP/Laravel → laravel-expert

Generates tests with:
- PHPUnit/Pest patterns
- Database transactions
- Factory usage
- HTTP testing
- Mocking facades

### E2E → cypress-expert

Generates tests with:
- Page object patterns
- Custom commands
- Network stubbing
- Visual testing
- CI configuration

---

## Framework-Specific Output

### Jest/Vitest (TypeScript)

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { validateToken, TokenError } from '../auth';

describe('validateToken', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('happy path', () => {
    it('should return true for valid JWT token', () => {
      const token = 'eyJhbGciOiJIUzI1NiIs...';
      expect(validateToken(token)).toBe(true);
    });

    it('should decode payload correctly', () => {
      const token = createTestToken({ userId: 123 });
      const result = validateToken(token);
      expect(result.payload.userId).toBe(123);
    });
  });

  describe('edge cases', () => {
    it('should handle empty string', () => {
      expect(validateToken('')).toBe(false);
    });

    it('should handle malformed token', () => {
      expect(validateToken('not.a.token')).toBe(false);
    });

    it('should handle expired token', () => {
      const expiredToken = createTestToken({ exp: Date.now() - 1000 });
      expect(validateToken(expiredToken)).toBe(false);
    });
  });

  describe('error handling', () => {
    it('should throw TokenError for null input', () => {
      expect(() => validateToken(null)).toThrow(TokenError);
    });

    it('should throw with descriptive message', () => {
      expect(() => validateToken(null)).toThrow('Token cannot be null');
    });
  });
});
```

### React Testing Library

```typescript
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { LoginForm } from '../LoginForm';

describe('LoginForm', () => {
  const mockOnSubmit = vi.fn();

  beforeEach(() => {
    mockOnSubmit.mockClear();
  });

  it('renders email and password fields', () => {
    render(<LoginForm onSubmit={mockOnSubmit} />);

    expect(screen.getByRole('textbox', { name: /email/i })).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
  });

  it('submits form with credentials', async () => {
    const user = userEvent.setup();
    render(<LoginForm onSubmit={mockOnSubmit} />);

    await user.type(screen.getByRole('textbox', { name: /email/i }), 'test@example.com');
    await user.type(screen.getByLabelText(/password/i), 'password123');
    await user.click(screen.getByRole('button', { name: /submit/i }));

    expect(mockOnSubmit).toHaveBeenCalledWith({
      email: 'test@example.com',
      password: 'password123',
    });
  });

  it('shows validation error for invalid email', async () => {
    const user = userEvent.setup();
    render(<LoginForm onSubmit={mockOnSubmit} />);

    await user.type(screen.getByRole('textbox', { name: /email/i }), 'invalid');
    await user.click(screen.getByRole('button', { name: /submit/i }));

    expect(await screen.findByText(/invalid email/i)).toBeInTheDocument();
    expect(mockOnSubmit).not.toHaveBeenCalled();
  });

  it('disables submit button while loading', () => {
    render(<LoginForm onSubmit={mockOnSubmit} isLoading />);

    expect(screen.getByRole('button', { name: /submit/i })).toBeDisabled();
  });
});
```

### pytest (Python)

```python
import pytest
from unittest.mock import Mock, patch, AsyncMock
from app.auth import validate_token, TokenError

class TestValidateToken:
    """Tests for validate_token function."""

    def test_valid_token_returns_true(self):
        """Should return True for valid JWT token."""
        token = "eyJhbGciOiJIUzI1NiIs..."
        assert validate_token(token) is True

    def test_decodes_payload_correctly(self, valid_token):
        """Should decode payload with correct user ID."""
        result = validate_token(valid_token)
        assert result.payload["userId"] == 123

    @pytest.mark.parametrize("invalid_input", [
        "",
        "not.a.token",
        "a.b",
        None,
    ])
    def test_rejects_invalid_tokens(self, invalid_input):
        """Should return False for invalid token formats."""
        assert validate_token(invalid_input) is False

    def test_rejects_expired_token(self, expired_token):
        """Should return False for expired tokens."""
        assert validate_token(expired_token) is False

    def test_raises_token_error_for_null(self):
        """Should raise TokenError with descriptive message."""
        with pytest.raises(TokenError, match="Token cannot be null"):
            validate_token(None)

    @pytest.fixture
    def valid_token(self):
        """Create a valid test token."""
        return create_test_token({"userId": 123})

    @pytest.fixture
    def expired_token(self):
        """Create an expired test token."""
        return create_test_token({"exp": time.time() - 1000})


class TestValidateTokenAsync:
    """Tests for async token validation."""

    @pytest.mark.asyncio
    async def test_async_validation(self):
        """Should validate token asynchronously."""
        token = create_test_token({"userId": 456})
        result = await validate_token_async(token)
        assert result.valid is True

    @pytest.mark.asyncio
    async def test_handles_network_timeout(self):
        """Should handle network timeout gracefully."""
        with patch("app.auth.fetch_public_key", new_callable=AsyncMock) as mock:
            mock.side_effect = TimeoutError()

            with pytest.raises(TokenError, match="Validation timeout"):
                await validate_token_async("token")
```

### PHPUnit (PHP)

```php
<?php

namespace Tests\Unit\Services;

use PHPUnit\Framework\TestCase;
use App\Services\AuthService;
use App\Exceptions\TokenException;
use Mockery;

class AuthServiceTest extends TestCase
{
    private AuthService $service;

    protected function setUp(): void
    {
        parent::setUp();
        $this->service = new AuthService();
    }

    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    /** @test */
    public function it_validates_correct_token(): void
    {
        $token = $this->createValidToken(['user_id' => 123]);

        $result = $this->service->validateToken($token);

        $this->assertTrue($result);
    }

    /** @test */
    public function it_rejects_expired_token(): void
    {
        $token = $this->createExpiredToken();

        $result = $this->service->validateToken($token);

        $this->assertFalse($result);
    }

    /** @test */
    public function it_throws_for_null_token(): void
    {
        $this->expectException(TokenException::class);
        $this->expectExceptionMessage('Token cannot be null');

        $this->service->validateToken(null);
    }

    /**
     * @test
     * @dataProvider invalidTokenProvider
     */
    public function it_rejects_invalid_tokens(string $invalidToken): void
    {
        $result = $this->service->validateToken($invalidToken);

        $this->assertFalse($result);
    }

    public static function invalidTokenProvider(): array
    {
        return [
            'empty string' => [''],
            'malformed' => ['not.a.token'],
            'missing parts' => ['a.b'],
        ];
    }
}
```

### Pest (PHP)

```php
<?php

use App\Services\AuthService;
use App\Exceptions\TokenException;

describe('AuthService', function () {
    beforeEach(function () {
        $this->service = new AuthService();
    });

    describe('validateToken', function () {
        it('validates correct token', function () {
            $token = createValidToken(['user_id' => 123]);

            expect($this->service->validateToken($token))->toBeTrue();
        });

        it('rejects expired token', function () {
            $token = createExpiredToken();

            expect($this->service->validateToken($token))->toBeFalse();
        });

        it('throws for null token', function () {
            $this->service->validateToken(null);
        })->throws(TokenException::class, 'Token cannot be null');

        it('rejects invalid tokens', function (string $invalidToken) {
            expect($this->service->validateToken($invalidToken))->toBeFalse();
        })->with([
            'empty string' => '',
            'malformed' => 'not.a.token',
            'missing parts' => 'a.b',
        ]);
    });
});
```

### Cypress (E2E)

```typescript
describe('Login Flow', () => {
  beforeEach(() => {
    cy.visit('/login');
  });

  it('should login with valid credentials', () => {
    cy.get('[data-cy=email]').type('user@example.com');
    cy.get('[data-cy=password]').type('password123');
    cy.get('[data-cy=submit]').click();

    cy.url().should('include', '/dashboard');
    cy.get('[data-cy=welcome]').should('contain', 'Welcome');
  });

  it('should show error with invalid credentials', () => {
    cy.intercept('POST', '/api/login', {
      statusCode: 401,
      body: { error: 'Invalid credentials' },
    }).as('loginRequest');

    cy.get('[data-cy=email]').type('user@example.com');
    cy.get('[data-cy=password]').type('wrong');
    cy.get('[data-cy=submit]').click();

    cy.wait('@loginRequest');
    cy.get('[data-cy=error]').should('be.visible');
    cy.url().should('include', '/login');
  });

  it('should persist session after reload', () => {
    cy.login('user@example.com', 'password123');
    cy.visit('/dashboard');
    cy.reload();

    cy.get('[data-cy=welcome]').should('be.visible');
  });
});
```

### Cypress (Component)

```typescript
import LoginForm from './LoginForm.vue';

describe('LoginForm Component', () => {
  it('renders login form', () => {
    cy.mount(LoginForm);

    cy.get('[data-cy=email]').should('exist');
    cy.get('[data-cy=password]').should('exist');
    cy.get('[data-cy=submit]').should('contain', 'Login');
  });

  it('emits submit event with credentials', () => {
    const onSubmitSpy = cy.spy().as('submitSpy');
    cy.mount(LoginForm, { props: { onSubmit: onSubmitSpy } });

    cy.get('[data-cy=email]').type('user@example.com');
    cy.get('[data-cy=password]').type('password123');
    cy.get('[data-cy=submit]').click();

    cy.get('@submitSpy').should('have.been.calledWith', {
      email: 'user@example.com',
      password: 'password123',
    });
  });

  it('validates email format', () => {
    cy.mount(LoginForm);

    cy.get('[data-cy=email]').type('invalid-email');
    cy.get('[data-cy=submit]').click();

    cy.get('[data-cy=email-error]').should('contain', 'Invalid email');
  });
});
```

---

## Usage Examples

```bash
# Generate tests for a file
/testgen src/utils/auth.ts

# Generate tests for specific function
/testgen src/utils/auth.ts:validateToken

# Generate tests for directory
/testgen src/services/

# Specify test type
/testgen src/api/users.ts --type integration

# Override framework detection
/testgen src/helpers.js --framework jest

# Focus on edge cases only
/testgen src/parser.ts --focus edge

# Quick generation (happy path only)
/testgen src/utils.ts --depth quick

# Thorough generation (all cases + mocking)
/testgen src/complex-service.ts --depth thorough

# Generate test stubs only (no implementation)
/testgen src/new-feature.ts --stubs

# Generate E2E tests
/testgen src/pages/Login.tsx --type e2e

# Generate component tests
/testgen src/components/Button.vue --type component
```

---

## Focus Modes

| Mode | What's Generated | Use When |
|------|------------------|----------|
| `--focus happy` | Normal inputs, expected outputs | Quick smoke tests |
| `--focus edge` | Boundaries, empty, null, limits | Hardening existing code |
| `--focus error` | Invalid inputs, exceptions | Error handling coverage |
| `--focus all` | Everything (default) | New code, full coverage |

---

## Depth Modes

| Mode | Coverage | Output Size |
|------|----------|-------------|
| `--depth quick` | Happy path, 1-2 tests/function | Minimal |
| `--depth normal` | Happy + common edges (default) | Moderate |
| `--depth thorough` | All paths, mocking, async, types | Comprehensive |

---

## Smart Features

### Dependency Detection
Automatically identifies and mocks:
- External API calls (fetch, axios, httpx)
- Database operations (queries, transactions)
- File system operations
- Environment variables
- Third-party services

### Test Location Intelligence
Detects project convention:
```bash
# Scans existing tests to match pattern
fd -e test.ts -e spec.ts | head -5

# Matches: __tests__/, co-located, or tests/
```

### Import Style Matching
Matches existing test imports:
```typescript
// Detects: vitest vs jest vs mocha
// Detects: @testing-library vs enzyme
// Detects: expect() style vs assert
```

---

## CLI Tool Integration

| Tool | Purpose | Fallback |
|------|---------|----------|
| `jq` | Parse package.json | Read tool |
| `rg` | Find existing tests | Grep tool |
| `ast-grep` | Parse function signatures | ripgrep patterns |
| `fd` | Find test files | Glob tool |

**Graceful degradation:**
```bash
command -v jq >/dev/null 2>&1 && cat package.json | jq '.devDependencies' || cat package.json
```

---

## Integration

| Command | Relationship |
|---------|--------------|
| `/review` | Review generated tests before committing |
| `/explain` | Understand complex code before testing |
| `/saveplan` | Track test coverage goals |
| `/testgen` | This command |

---

## Notes

- Generated tests are starting points - refine as needed
- Review mocks for accuracy and completeness
- Expert routing improves framework-specific patterns
- Use `--stubs` when you prefer to write test logic yourself
- Always run generated tests to verify they pass
- Consider `/review` on generated tests before committing
