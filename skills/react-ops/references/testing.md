# Testing

React Testing Library, user-event, MSW, Vitest setup, hook testing, and accessibility testing.

---

## Philosophy

Test behavior, not implementation. Tests should resemble how users interact with your app.

- Query by what the user sees (role, label, text) — not by class names or IDs
- Interact the way users do (click, type, submit) — not by calling component methods
- Assert what the user sees as the outcome — not component state

---

## Vitest + RTL Setup

```bash
npm install -D vitest @testing-library/react @testing-library/user-event @testing-library/jest-dom jsdom
```

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,           // no import { describe, it, expect } needed
    setupFiles: ['./src/test/setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      exclude: ['**/*.stories.tsx', '**/index.ts'],
    },
  },
});
```

```typescript
// src/test/setup.ts
import '@testing-library/jest-dom'; // extends expect with DOM matchers
import { cleanup } from '@testing-library/react';
import { afterEach, beforeAll, afterAll } from 'vitest';
import { server } from './mocks/server';

// RTL cleanup after each test
afterEach(() => cleanup());

// MSW lifecycle
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

---

## Rendering and Queries

### Query Priority

```
1. getByRole         — semantic HTML, accessible name
2. getByLabelText    — form labels
3. getByPlaceholderText — input placeholders (prefer label)
4. getByText         — visible text content
5. getByDisplayValue — current input value
6. getByAltText      — img alt text
7. getByTitle        — title attribute
8. getByTestId       — last resort: data-testid="..."
```

### getBy vs queryBy vs findBy

| Variant | Returns | Throws | Async |
|---------|---------|--------|-------|
| `getBy*` | Element | If not found | No |
| `queryBy*` | Element or null | No | No |
| `findBy*` | Promise<Element> | If timeout | Yes |
| `getAllBy*` | Element[] | If none found | No |
| `queryAllBy*` | Element[] | No | No |
| `findAllBy*` | Promise<Element[]> | If timeout | Yes |

```tsx
import { render, screen } from '@testing-library/react';

test('renders user profile', () => {
  render(<UserProfile user={{ name: 'Alice', role: 'admin' }} />);

  // Role-based (preferred) — uses ARIA roles
  expect(screen.getByRole('heading', { name: 'Alice' })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: /edit profile/i })).toBeEnabled();

  // Text content
  expect(screen.getByText('admin')).toBeInTheDocument();

  // For content that should NOT be present
  expect(screen.queryByRole('button', { name: /delete/i })).not.toBeInTheDocument();
});
```

---

## User Interactions

Always use `@testing-library/user-event` over `fireEvent` — it simulates real browser events including pointer events, focus, keyboard navigation.

```tsx
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

describe('LoginForm', () => {
  // Create user instance once per test — manages pointer state
  const user = userEvent.setup();

  test('submits with valid credentials', async () => {
    const onLogin = vi.fn();
    render(<LoginForm onLogin={onLogin} />);

    // Type into inputs (fires focus, input, change, keydown/up events)
    await user.type(screen.getByLabelText(/email/i), 'alice@example.com');
    await user.type(screen.getByLabelText(/password/i), 'password123');

    // Click submit
    await user.click(screen.getByRole('button', { name: /sign in/i }));

    expect(onLogin).toHaveBeenCalledWith({
      email: 'alice@example.com',
      password: 'password123',
    });
  });

  test('shows validation error for empty email', async () => {
    render(<LoginForm onLogin={vi.fn()} />);

    // Tab to trigger blur validation without typing
    await user.click(screen.getByLabelText(/email/i));
    await user.tab();

    expect(screen.getByRole('alert')).toHaveTextContent(/email is required/i);
  });

  test('disables submit while loading', async () => {
    render(<LoginForm onLogin={() => new Promise(() => {})} />); // never resolves

    await user.type(screen.getByLabelText(/email/i), 'alice@example.com');
    await user.type(screen.getByLabelText(/password/i), 'pass');
    await user.click(screen.getByRole('button', { name: /sign in/i }));

    expect(screen.getByRole('button', { name: /signing in/i })).toBeDisabled();
  });
});
```

### Select, Keyboard, Upload

```tsx
// Select dropdown
await user.selectOptions(screen.getByRole('combobox', { name: /country/i }), 'Canada');
expect(screen.getByRole('option', { name: 'Canada' })).toBeSelected();

// Keyboard shortcuts
await user.keyboard('{Escape}');          // press Escape
await user.keyboard('{Control>}k{/Control}'); // Ctrl+K

// File upload
const file = new File(['content'], 'test.pdf', { type: 'application/pdf' });
await user.upload(screen.getByLabelText(/upload/i), file);

// Clear an input
await user.clear(screen.getByRole('textbox', { name: /search/i }));
```

---

## Async Testing

```tsx
import { render, screen, waitFor, waitForElementToBeRemoved } from '@testing-library/react';

test('loads and displays users', async () => {
  render(<UserList />);

  // Assert loading state
  expect(screen.getByRole('status')).toHaveTextContent(/loading/i);

  // Wait for async operation to complete
  await waitFor(() => {
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  // Alternatively: wait for element to disappear
  await waitForElementToBeRemoved(() => screen.queryByRole('status'));

  // Assert loaded state
  expect(screen.getByRole('list')).toBeInTheDocument();
  expect(screen.getAllByRole('listitem')).toHaveLength(3);
});

// findBy* — combines waitFor + getBy
test('shows error on failed load', async () => {
  server.use(
    http.get('/api/users', () => HttpResponse.error())
  );

  render(<UserList />);

  // findBy waits up to 1000ms by default
  const error = await screen.findByRole('alert');
  expect(error).toHaveTextContent(/failed to load/i);
});
```

---

## Custom Render with Providers

```tsx
// src/test/utils.tsx
import { render, RenderOptions } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router-dom';
import { ReactNode } from 'react';

interface WrapperOptions {
  initialRoute?: string;
}

function createWrapper({ initialRoute = '/' }: WrapperOptions = {}) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },    // no retries in tests
      mutations: { retry: false },
    },
  });

  return function Wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[initialRoute]}>
          {children}
        </MemoryRouter>
      </QueryClientProvider>
    );
  };
}

// Custom render — drop-in replacement for RTL's render
function customRender(
  ui: React.ReactElement,
  options: WrapperOptions & Omit<RenderOptions, 'wrapper'> = {}
) {
  const { initialRoute, ...renderOptions } = options;
  return render(ui, {
    wrapper: createWrapper({ initialRoute }),
    ...renderOptions,
  });
}

// Re-export everything from RTL so tests only need to import from here
export * from '@testing-library/react';
export { customRender as render };
```

```tsx
// Usage in tests — exact same API as RTL
import { render, screen } from '../test/utils';

test('navigates to profile', async () => {
  const user = userEvent.setup();
  render(<App />, { initialRoute: '/dashboard' });

  await user.click(screen.getByRole('link', { name: /profile/i }));
  expect(screen.getByRole('heading', { name: /your profile/i })).toBeInTheDocument();
});
```

---

## MSW (Mock Service Worker)

MSW intercepts real network requests — no mocking of fetch/axios needed.

```typescript
// src/test/mocks/handlers.ts
import { http, HttpResponse } from 'msw';

const mockUsers: User[] = [
  { id: '1', name: 'Alice', email: 'alice@example.com' },
  { id: '2', name: 'Bob', email: 'bob@example.com' },
];

export const handlers = [
  // GET /api/users
  http.get('/api/users', () => {
    return HttpResponse.json(mockUsers);
  }),

  // GET /api/users/:id
  http.get('/api/users/:id', ({ params }) => {
    const user = mockUsers.find(u => u.id === params.id);
    if (!user) return new HttpResponse(null, { status: 404 });
    return HttpResponse.json(user);
  }),

  // POST /api/users
  http.post('/api/users', async ({ request }) => {
    const body = await request.json() as Partial<User>;
    const newUser = { id: crypto.randomUUID(), ...body } as User;
    return HttpResponse.json(newUser, { status: 201 });
  }),

  // DELETE /api/users/:id
  http.delete('/api/users/:id', ({ params }) => {
    return new HttpResponse(null, { status: 204 });
  }),
];
```

```typescript
// src/test/mocks/server.ts
import { setupServer } from 'msw/node';
import { handlers } from './handlers';

export const server = setupServer(...handlers);
```

```tsx
// Override handlers in specific tests
import { server } from '../test/mocks/server';
import { http, HttpResponse } from 'msw';

test('shows error when API fails', async () => {
  // Override default handler for this test only
  server.use(
    http.get('/api/users', () => {
      return HttpResponse.json({ message: 'Internal Server Error' }, { status: 500 });
    })
  );

  render(<UserList />);
  await screen.findByRole('alert');
  expect(screen.getByRole('alert')).toHaveTextContent(/something went wrong/i);
});
```

---

## Hook Testing

```tsx
import { renderHook, act } from '@testing-library/react';
import { useCounter } from './useCounter';

test('useCounter increments correctly', () => {
  const { result } = renderHook(() => useCounter(0));

  expect(result.current.count).toBe(0);

  act(() => result.current.increment());
  expect(result.current.count).toBe(1);

  act(() => result.current.incrementBy(5));
  expect(result.current.count).toBe(6);

  act(() => result.current.reset());
  expect(result.current.count).toBe(0);
});

// Test hooks that use context
test('useTheme reads from ThemeProvider', () => {
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <ThemeProvider initialTheme="dark">{children}</ThemeProvider>
  );

  const { result } = renderHook(() => useTheme(), { wrapper });
  expect(result.current.theme).toBe('dark');

  act(() => result.current.toggleTheme());
  expect(result.current.theme).toBe('light');
});

// Test async hooks
test('useFetch returns data', async () => {
  const { result } = renderHook(() => useFetch<User[]>('/api/users'));

  expect(result.current.isLoading).toBe(true);

  await waitFor(() => {
    expect(result.current.isLoading).toBe(false);
  });

  expect(result.current.data).toHaveLength(2);
  expect(result.current.error).toBeNull();
});
```

---

## Component Testing Patterns

### Modal

```tsx
test('modal opens and closes', async () => {
  const user = userEvent.setup();
  render(<DeleteConfirmation onDelete={vi.fn()} />);

  // Modal should not be in DOM initially
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

  await user.click(screen.getByRole('button', { name: /delete/i }));
  expect(screen.getByRole('dialog')).toBeInTheDocument();
  expect(screen.getByRole('dialog')).toHaveAccessibleName(/confirm deletion/i);

  await user.click(screen.getByRole('button', { name: /cancel/i }));
  await waitForElementToBeRemoved(() => screen.queryByRole('dialog'));
});
```

### Form Validation

```tsx
test('validates required fields on submit', async () => {
  const user = userEvent.setup();
  const onSubmit = vi.fn();
  render(<ContactForm onSubmit={onSubmit} />);

  // Submit empty form
  await user.click(screen.getByRole('button', { name: /submit/i }));

  // Errors appear
  expect(screen.getByText(/name is required/i)).toBeInTheDocument();
  expect(screen.getByText(/email is required/i)).toBeInTheDocument();

  // Form was not submitted
  expect(onSubmit).not.toHaveBeenCalled();
});
```

---

## Accessibility Testing

```tsx
import { axe, toHaveNoViolations } from 'jest-axe';

expect.extend(toHaveNoViolations());

test('has no accessibility violations', async () => {
  const { container } = render(<LoginForm onLogin={vi.fn()} />);
  const results = await axe(container);
  expect(results).toHaveNoViolations();
});

// Test keyboard navigation
test('modal is keyboard accessible', async () => {
  const user = userEvent.setup();
  render(<Modal isOpen onClose={vi.fn()} title="Confirm">Content</Modal>);

  const dialog = screen.getByRole('dialog');

  // Dialog should have correct ARIA attributes
  expect(dialog).toHaveAttribute('aria-modal', 'true');
  expect(dialog).toHaveAccessibleName('Confirm');

  // Escape closes modal
  await user.keyboard('{Escape}');
  // ... assert closed
});

// Test screen reader text
test('icon button has accessible name', () => {
  render(<button aria-label="Close menu"><XIcon /></button>);
  expect(screen.getByRole('button', { name: /close menu/i })).toBeInTheDocument();
});
```

---

## Snapshot Testing

Use sparingly — for stable UI components where visual regression is more important than behavior.

```tsx
// PREFER behavioral tests over snapshots
// Use snapshots only for:
// - Stable design system components (Button, Badge, Avatar)
// - Complex SVG/icon output
// - Error messages with specific formatting

import { render } from '@testing-library/react';

test('Badge renders correctly', () => {
  const { container } = render(<Badge variant="success" count={5} />);
  expect(container.firstChild).toMatchSnapshot();
});

// Update snapshots when intentional changes are made:
// vitest --update-snapshots
```

---

## Anti-patterns

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| Query by CSS class or id | Brittle, implementation detail | Query by role, label, or text |
| `fireEvent` instead of `userEvent` | Doesn't fire real browser events | Use `@testing-library/user-event` |
| Testing internal state | Tests break on refactor | Test rendered output and behavior |
| Mocking React components | Hides integration bugs | Test with real components; mock network instead |
| No async awaiting | Tests pass before assertions run | Always `await` user interactions and async queries |
| `data-testid` as first choice | Couples tests to implementation | Last resort after semantic queries fail |
| Test per implementation detail | Brittle test suite | Test per user story / behavior |
| No error case tests | Only happy path covered | Test loading, error, empty, and edge states |
