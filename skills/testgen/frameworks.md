# TestGen Framework Examples

Code examples for each supported testing framework. These are loaded on-demand when the testgen skill detects a specific framework.

---

## Jest/Vitest (TypeScript)

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

---

## React Testing Library

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

---

## pytest (Python)

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

---

## Go (Table-Driven Tests)

```go
package auth

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValidateToken(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		token   string
		want    bool
		wantErr error
	}{
		{
			name:  "valid token",
			token: "eyJhbGciOiJIUzI1NiIs...",
			want:  true,
		},
		{
			name:  "empty string",
			token: "",
			want:  false,
		},
		{
			name:  "malformed token",
			token: "not.a.token",
			want:  false,
		},
		{
			name:    "nil token",
			token:   "",
			wantErr: ErrTokenNil,
		},
	}

	for _, tt := range tests {
		tt := tt // capture range variable
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := ValidateToken(tt.token)

			if tt.wantErr != nil {
				require.ErrorIs(t, err, tt.wantErr)
				return
			}

			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestValidateToken_Expired(t *testing.T) {
	token := createTestToken(t, TokenClaims{
		UserID: 123,
		Exp:    time.Now().Add(-1 * time.Hour),
	})

	got, err := ValidateToken(token)

	require.NoError(t, err)
	assert.False(t, got, "expired token should be invalid")
}

func TestValidateToken_Integration(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	client := NewAuthClient(testConfig)
	token, _ := client.GenerateToken(TestUser)

	got, err := ValidateToken(token)

	require.NoError(t, err)
	assert.True(t, got)
}

func BenchmarkValidateToken(b *testing.B) {
	token := createValidToken()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ValidateToken(token)
	}
}

func createTestToken(t *testing.T, claims TokenClaims) string {
	t.Helper()
	token, err := generateToken(claims, testSecret)
	require.NoError(t, err)
	return token
}
```

---

## Rust (#[test] Patterns)

```rust
use crate::auth::{validate_token, TokenError, TokenClaims};
use std::time::{Duration, SystemTime};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_token_returns_ok() {
        let token = create_test_token(TokenClaims {
            user_id: 123,
            exp: future_time(),
        });

        let result = validate_token(&token);

        assert!(result.is_ok());
        assert!(result.unwrap());
    }

    #[test]
    fn empty_token_returns_false() {
        let result = validate_token("");

        assert!(result.is_ok());
        assert!(!result.unwrap());
    }

    #[test]
    fn malformed_token_returns_false() {
        let result = validate_token("not.a.token");

        assert!(result.is_ok());
        assert!(!result.unwrap());
    }

    #[test]
    fn expired_token_returns_false() {
        let token = create_test_token(TokenClaims {
            user_id: 123,
            exp: past_time(),
        });

        let result = validate_token(&token);

        assert!(result.is_ok());
        assert!(!result.unwrap(), "expired token should be invalid");
    }

    #[test]
    #[should_panic(expected = "Token cannot be null")]
    fn null_token_panics() {
        validate_token_unchecked(None);
    }

    #[test]
    fn returns_token_error_for_invalid_signature() {
        let token = "eyJhbGciOiJIUzI1NiIs.tampered.signature";

        let result = validate_token(token);

        assert!(matches!(result, Err(TokenError::InvalidSignature)));
    }

    #[test]
    fn rejects_various_invalid_tokens() {
        let invalid_tokens = [
            ("empty", ""),
            ("single_part", "abc"),
            ("two_parts", "a.b"),
            ("whitespace", "   "),
            ("special_chars", "!@#$%"),
        ];

        for (name, token) in invalid_tokens {
            let result = validate_token(token);
            assert!(
                result.is_ok() && !result.unwrap(),
                "case '{}' should return false",
                name
            );
        }
    }

    #[tokio::test]
    async fn async_validation_works() {
        let token = create_test_token(valid_claims());

        let result = validate_token_async(&token).await;

        assert!(result.is_ok());
    }

    fn create_test_token(claims: TokenClaims) -> String {
        crate::auth::generate_token(&claims, TEST_SECRET).unwrap()
    }

    fn valid_claims() -> TokenClaims {
        TokenClaims {
            user_id: 123,
            exp: future_time(),
        }
    }

    fn future_time() -> SystemTime {
        SystemTime::now() + Duration::from_secs(3600)
    }

    fn past_time() -> SystemTime {
        SystemTime::now() - Duration::from_secs(3600)
    }

    const TEST_SECRET: &[u8] = b"test_secret_key";
}

#[cfg(test)]
mod property_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn doesnt_crash_on_arbitrary_input(s in "\\PC*") {
            let _ = validate_token(&s);
        }

        #[test]
        fn valid_tokens_always_validate(user_id in 1u64..1000000) {
            let token = create_test_token(TokenClaims {
                user_id,
                exp: future_time(),
            });

            let result = validate_token(&token);
            prop_assert!(result.is_ok());
            prop_assert!(result.unwrap());
        }
    }
}
```

---

## PHPUnit (PHP)

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

---

## Pest (PHP)

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

---

## Cypress (E2E)

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

---

## Cypress (Component)

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

## Playwright (E2E)

```typescript
import { test, expect } from '@playwright/test';

test.describe('Login Flow', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/login');
  });

  test('should login with valid credentials', async ({ page }) => {
    await page.getByRole('textbox', { name: /email/i }).fill('user@example.com');
    await page.getByRole('textbox', { name: /password/i }).fill('password123');
    await page.getByRole('button', { name: /submit/i }).click();

    await expect(page).toHaveURL(/dashboard/);
    await expect(page.getByText(/welcome/i)).toBeVisible();
  });

  test('should show error with invalid credentials', async ({ page }) => {
    await page.route('**/api/login', async (route) => {
      await route.fulfill({
        status: 401,
        body: JSON.stringify({ error: 'Invalid credentials' }),
      });
    });

    await page.getByRole('textbox', { name: /email/i }).fill('user@example.com');
    await page.getByRole('textbox', { name: /password/i }).fill('wrong');
    await page.getByRole('button', { name: /submit/i }).click();

    await expect(page.getByTestId('error-message')).toBeVisible();
    await expect(page).toHaveURL(/login/);
  });

  test('should validate email format', async ({ page }) => {
    await page.getByRole('textbox', { name: /email/i }).fill('invalid-email');
    await page.getByRole('button', { name: /submit/i }).click();

    await expect(page.getByText(/invalid email/i)).toBeVisible();
  });

  test('should persist session after reload', async ({ page, context }) => {
    await page.getByRole('textbox', { name: /email/i }).fill('user@example.com');
    await page.getByRole('textbox', { name: /password/i }).fill('password123');
    await page.getByRole('button', { name: /submit/i }).click();
    await expect(page).toHaveURL(/dashboard/);

    await page.reload();
    await expect(page.getByText(/welcome/i)).toBeVisible();
  });

  test('should be accessible', async ({ page }) => {
    const accessibilityScanResults = await new AxeBuilder({ page }).analyze();
    expect(accessibilityScanResults.violations).toEqual([]);
  });
});

test.describe('Login Form - Visual', () => {
  test('matches snapshot', async ({ page }) => {
    await page.goto('/login');
    await expect(page).toHaveScreenshot('login-form.png');
  });

  test('error state matches snapshot', async ({ page }) => {
    await page.goto('/login');
    await page.getByRole('textbox', { name: /email/i }).fill('invalid');
    await page.getByRole('button', { name: /submit/i }).click();

    await expect(page).toHaveScreenshot('login-form-error.png');
  });
});
```
