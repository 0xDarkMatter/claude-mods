# Testing Reference

Vue 3 testing with Vitest, Vue Test Utils, Pinia, Vue Router, MSW, Playwright, and Nuxt test utils.

---

## Vitest Setup for Vue

### Installation

```bash
npm install -D vitest @vue/test-utils happy-dom @vitest/coverage-v8
# Or jsdom:
npm install -D jsdom
```

### vitest.config.ts

```ts
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',  // or 'jsdom'
    globals: true,             // describe/it/expect without importing
    setupFiles: ['./tests/setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'html'],
      thresholds: {
        lines: 80,
        branches: 75,
        functions: 80,
      },
      exclude: ['**/node_modules/**', '**/dist/**', '**/*.d.ts'],
    },
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
```

### tests/setup.ts — global test setup

```ts
import { config } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'

// Global component stubs
config.global.stubs = {
  RouterLink: true,
  RouterView: true,
  Teleport: true,
}

// Suppress Vue warnings in tests (optional — often better to fix them)
// config.global.config.warnHandler = () => null
```

### Auto-imports with unplugin-auto-import

```ts
// vitest.config.ts — if using auto-imports in app
import AutoImport from 'unplugin-auto-import/vite'

export default defineConfig({
  plugins: [
    vue(),
    AutoImport({
      imports: ['vue', 'vue-router', 'pinia'],
      dts: true,
    }),
  ],
  test: { globals: true },
})
```

---

## Vue Test Utils — Mounting

### mount vs shallowMount

```ts
import { mount, shallowMount } from '@vue/test-utils'
import UserCard from '@/components/UserCard.vue'

// mount — renders the full component tree (children included)
const wrapper = mount(UserCard, {
  props: { user: { id: 1, name: 'Alice' } },
})

// shallowMount — stubs child components (faster, more isolated)
// WARNING: can hide integration bugs; prefer mount for most cases
const wrapper = shallowMount(UserCard, {
  props: { user: { id: 1, name: 'Alice' } },
})
```

### Mounting options

```ts
const wrapper = mount(MyComponent, {
  props: {
    title: 'Hello',
    items: [1, 2, 3],
  },
  slots: {
    default: '<p>Default slot content</p>',
    header: '<h2>Header slot</h2>',
  },
  global: {
    plugins: [router, createTestingPinia()],
    stubs: {
      'FontAwesomeIcon': true,         // stub by name
      ChildComponent: { template: '<div class="child-stub" />' },
    },
    mocks: {
      $t: (key: string) => key,        // mock i18n
    },
    provide: {
      theme: ref('dark'),
    },
  },
  attachTo: document.body,             // needed for focus tests
})
```

---

## Component Testing Patterns

### Rendering and querying the DOM

```ts
import { mount } from '@vue/test-utils'
import { describe, it, expect } from 'vitest'
import UserList from '@/components/UserList.vue'

const users = [
  { id: 1, name: 'Alice', role: 'admin' },
  { id: 2, name: 'Bob', role: 'user' },
]

describe('UserList', () => {
  it('renders a list of users', () => {
    const wrapper = mount(UserList, { props: { users } })

    // Text content
    expect(wrapper.text()).toContain('Alice')

    // Element exists
    expect(wrapper.find('[data-testid="user-list"]').exists()).toBe(true)

    // Count elements
    expect(wrapper.findAll('.user-card')).toHaveLength(2)

    // Check attribute
    expect(wrapper.find('input').attributes('disabled')).toBeDefined()

    // Check CSS class
    expect(wrapper.find('.user-card').classes()).toContain('admin')
  })

  it('renders empty state when no users', () => {
    const wrapper = mount(UserList, { props: { users: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })
})
```

### User interactions

```ts
import { mount, flushPromises } from '@vue/test-utils'
import SearchInput from '@/components/SearchInput.vue'
import { nextTick } from 'vue'

describe('SearchInput', () => {
  it('emits search event when user types and submits', async () => {
    const wrapper = mount(SearchInput)

    // Fill input
    await wrapper.find('input').setValue('vue testing')

    // Click button
    await wrapper.find('button[type="submit"]').trigger('click')

    // Check emitted events
    expect(wrapper.emitted('search')).toBeTruthy()
    expect(wrapper.emitted('search')![0]).toEqual(['vue testing'])
  })

  it('clears input on escape key', async () => {
    const wrapper = mount(SearchInput)
    await wrapper.find('input').setValue('hello')
    await wrapper.find('input').trigger('keydown', { key: 'Escape' })

    expect((wrapper.find('input').element as HTMLInputElement).value).toBe('')
  })
})
```

### Async behavior

```ts
import { mount, flushPromises } from '@vue/test-utils'
import { vi } from 'vitest'
import PostList from '@/components/PostList.vue'

describe('PostList', () => {
  it('shows loading then content after fetch', async () => {
    // Mock fetch
    vi.spyOn(global, 'fetch').mockResolvedValueOnce({
      ok: true,
      json: async () => [{ id: 1, title: 'Post One' }],
    } as Response)

    const wrapper = mount(PostList)

    // Initially shows loading
    expect(wrapper.find('[data-testid="loading"]').exists()).toBe(true)

    // Wait for all promises to resolve
    await flushPromises()

    // Now shows content
    expect(wrapper.find('[data-testid="loading"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('Post One')
  })
})
```

### Slot testing

```ts
import { mount } from '@vue/test-utils'
import Card from '@/components/Card.vue'

describe('Card slots', () => {
  it('renders named slots', () => {
    const wrapper = mount(Card, {
      slots: {
        header: '<h2 data-testid="card-header">My Title</h2>',
        default: '<p>Card body</p>',
        footer: '<button>Action</button>',
      },
    })

    expect(wrapper.find('[data-testid="card-header"]').text()).toBe('My Title')
    expect(wrapper.find('p').text()).toBe('Card body')
  })

  it('renders scoped slot with data', () => {
    const wrapper = mount(DataTable, {
      props: { items: [{ id: 1, name: 'Alice' }] },
      slots: {
        row: `<template #row="{ item }">
          <span data-testid="row-name">{{ item.name }}</span>
        </template>`,
      },
    })

    expect(wrapper.find('[data-testid="row-name"]').text()).toBe('Alice')
  })
})
```

---

## Testing Composables

### Simple composable test

```ts
// tests/composables/useCounter.test.ts
import { describe, it, expect } from 'vitest'
import { useCounter } from '@/composables/useCounter'

describe('useCounter', () => {
  it('starts at initial value', () => {
    const { count } = useCounter(5)
    expect(count.value).toBe(5)
  })

  it('increments and decrements', () => {
    const { count, increment, decrement } = useCounter(0)
    increment()
    increment()
    expect(count.value).toBe(2)
    decrement()
    expect(count.value).toBe(1)
  })

  it('resets to initial value', () => {
    const { count, increment, reset } = useCounter(10)
    increment()
    reset()
    expect(count.value).toBe(10)
  })
})
```

### Composable requiring component context (lifecycle hooks)

```ts
// tests/composables/useEventListener.test.ts
import { describe, it, expect, vi } from 'vitest'
import { defineComponent, ref } from 'vue'
import { mount } from '@vue/test-utils'
import { useEventListener } from '@/composables/useEventListener'

describe('useEventListener', () => {
  it('adds and removes event listener with component lifecycle', async () => {
    const handler = vi.fn()

    // Wrap in a component to get lifecycle
    const TestComponent = defineComponent({
      setup() {
        useEventListener(window, 'resize', handler)
      },
      template: '<div />',
    })

    const wrapper = mount(TestComponent)

    // Trigger event
    window.dispatchEvent(new Event('resize'))
    expect(handler).toHaveBeenCalledTimes(1)

    // Unmount — listener should be removed
    wrapper.unmount()
    window.dispatchEvent(new Event('resize'))
    expect(handler).toHaveBeenCalledTimes(1) // still 1, not 2
  })
})
```

### Composable with mocked fetch

```ts
// tests/composables/useFetch.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { defineComponent, ref } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import { useFetch } from '@/composables/useFetch'

const mockData = { id: 1, name: 'Alice' }

describe('useFetch', () => {
  beforeEach(() => {
    vi.spyOn(global, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => mockData,
    } as Response)
  })

  it('fetches data and updates refs', async () => {
    const TestComponent = defineComponent({
      setup() {
        const { data, pending, error } = useFetch<typeof mockData>('/api/user')
        return { data, pending, error }
      },
      template: '<div />',
    })

    const wrapper = mount(TestComponent)
    expect(wrapper.vm.pending).toBe(true)

    await flushPromises()
    expect(wrapper.vm.pending).toBe(false)
    expect(wrapper.vm.data).toEqual(mockData)
    expect(wrapper.vm.error).toBeNull()
  })
})
```

---

## Pinia Testing

### createTestingPinia — mock store

```ts
import { mount } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'
import { vi } from 'vitest'
import UserProfile from '@/components/UserProfile.vue'
import { useUserStore } from '@/stores/user'

describe('UserProfile', () => {
  it('displays user name from store', () => {
    const wrapper = mount(UserProfile, {
      global: {
        plugins: [
          createTestingPinia({
            initialState: {
              user: { currentUser: { id: 1, name: 'Alice', role: 'admin' } },
            },
          }),
        ],
      },
    })

    expect(wrapper.text()).toContain('Alice')
  })

  it('calls logout action when button clicked', async () => {
    const wrapper = mount(UserProfile, {
      global: {
        plugins: [
          createTestingPinia({
            createSpy: vi.fn,          // makes all actions spies
          }),
        ],
      },
    })

    const store = useUserStore()
    await wrapper.find('[data-testid="logout-btn"]').trigger('click')
    expect(store.logout).toHaveBeenCalledOnce()
  })

  it('can stub specific action', async () => {
    const wrapper = mount(UserProfile, {
      global: {
        plugins: [
          createTestingPinia({
            createSpy: vi.fn,
            stubActions: false,        // let real actions run
          }),
        ],
      },
    })

    const store = useUserStore()
    // Override specific action
    store.logout = vi.fn().mockResolvedValue(undefined)
  })
})
```

### Testing store in isolation

```ts
import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect, vi } from 'vitest'
import { useCartStore } from '@/stores/cart'

describe('useCartStore', () => {
  beforeEach(() => {
    // Create a fresh pinia before each test
    setActivePinia(createPinia())
  })

  it('adds item to cart', () => {
    const cart = useCartStore()
    const product = { id: '1', name: 'Widget', price: 9.99 }

    cart.addItem(product)
    expect(cart.items).toHaveLength(1)
    expect(cart.total).toBe(9.99)
  })

  it('increments quantity for duplicate item', () => {
    const cart = useCartStore()
    const product = { id: '1', name: 'Widget', price: 9.99 }

    cart.addItem(product)
    cart.addItem(product)

    expect(cart.items).toHaveLength(1)
    expect(cart.items[0].quantity).toBe(2)
  })

  it('calls API when placing order', async () => {
    const fetchSpy = vi.spyOn(global, 'fetch').mockResolvedValueOnce({
      ok: true,
      json: async () => ({ orderId: 'abc123' }),
    } as Response)

    const cart = useCartStore()
    await cart.checkout()

    expect(fetchSpy).toHaveBeenCalledWith('/api/orders', expect.any(Object))
  })
})
```

---

## Vue Router Testing

### Router mock for navigation testing

```ts
import { mount, RouterLinkStub } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import NavBar from '@/components/NavBar.vue'

describe('NavBar navigation', () => {
  it('has correct links', () => {
    const wrapper = mount(NavBar, {
      global: {
        stubs: { RouterLink: RouterLinkStub },
      },
    })

    const links = wrapper.findAllComponents(RouterLinkStub)
    expect(links.some((l) => l.props('to') === '/')).toBe(true)
    expect(links.some((l) => l.props('to') === '/about')).toBe(true)
  })

  it('navigates on click', async () => {
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/', component: { template: '<div>Home</div>' } },
        { path: '/about', component: { template: '<div>About</div>' } },
      ],
    })

    const wrapper = mount(NavBar, {
      global: { plugins: [router] },
    })

    await router.isReady()
    await wrapper.find('[data-testid="about-link"]').trigger('click')
    await router.isReady()

    expect(router.currentRoute.value.path).toBe('/about')
  })
})
```

### Testing components that use useRoute/useRouter

```ts
import { mount } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import UserView from '@/views/UserView.vue'

describe('UserView', () => {
  it('loads user from route param', async () => {
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/users/:id', component: UserView }],
    })

    await router.push('/users/42')
    await router.isReady()

    const wrapper = mount(UserView, {
      global: { plugins: [router] },
    })

    await flushPromises()
    // UserView reads route.params.id = '42'
    expect(wrapper.text()).toContain('User 42')
  })
})
```

---

## API Mocking with MSW

### Setup

```bash
npm install -D msw
npx msw init public/
```

```ts
// tests/mocks/handlers.ts
import { http, HttpResponse } from 'msw'
import type { User } from '@/types'

export const handlers = [
  http.get('/api/users', () => {
    return HttpResponse.json<User[]>([
      { id: 1, name: 'Alice', email: 'alice@example.com' },
      { id: 2, name: 'Bob', email: 'bob@example.com' },
    ])
  }),

  http.get('/api/users/:id', ({ params }) => {
    const user = { id: Number(params.id), name: 'Alice', email: 'alice@example.com' }
    return HttpResponse.json(user)
  }),

  http.post('/api/users', async ({ request }) => {
    const body = await request.json() as Partial<User>
    return HttpResponse.json({ ...body, id: 999 }, { status: 201 })
  }),
]
```

```ts
// tests/setup.ts — global MSW setup
import { setupServer } from 'msw/node'
import { handlers } from './mocks/handlers'

const server = setupServer(...handlers)

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
```

```ts
// Override handlers per test
import { http, HttpResponse } from 'msw'

it('shows error when API fails', async () => {
  server.use(
    http.get('/api/users', () => {
      return HttpResponse.json({ message: 'Server Error' }, { status: 500 })
    })
  )
  // ... test error state
})
```

---

## Snapshot Testing

```ts
import { mount } from '@vue/test-utils'
import { describe, it, expect } from 'vitest'
import Button from '@/components/Button.vue'

describe('Button', () => {
  it('matches snapshot', () => {
    const wrapper = mount(Button, {
      props: { variant: 'primary', size: 'md' },
      slots: { default: 'Click me' },
    })

    // HTML snapshot
    expect(wrapper.html()).toMatchSnapshot()
  })

  it('matches inline snapshot', () => {
    const wrapper = mount(Button, {
      props: { variant: 'danger' },
      slots: { default: 'Delete' },
    })

    expect(wrapper.html()).toMatchInlineSnapshot(`
      "<button class="btn btn-danger">Delete</button>"
    `)
  })
})
```

---

## E2E with Playwright

### Setup

```bash
npm install -D @playwright/test
npx playwright install
```

### Page Object pattern for Vue apps

```ts
// tests/e2e/pages/LoginPage.ts
import { Page, Locator } from '@playwright/test'

export class LoginPage {
  readonly page: Page
  readonly emailInput: Locator
  readonly passwordInput: Locator
  readonly submitButton: Locator
  readonly errorMessage: Locator

  constructor(page: Page) {
    this.page = page
    this.emailInput = page.getByLabel('Email')
    this.passwordInput = page.getByLabel('Password')
    this.submitButton = page.getByRole('button', { name: 'Sign in' })
    this.errorMessage = page.getByTestId('login-error')
  }

  async goto() {
    await this.page.goto('/login')
  }

  async login(email: string, password: string) {
    await this.emailInput.fill(email)
    await this.passwordInput.fill(password)
    await this.submitButton.click()
  }
}
```

```ts
// tests/e2e/auth.spec.ts
import { test, expect } from '@playwright/test'
import { LoginPage } from './pages/LoginPage'

test.describe('Authentication', () => {
  test('successful login redirects to dashboard', async ({ page }) => {
    const loginPage = new LoginPage(page)
    await loginPage.goto()
    await loginPage.login('alice@example.com', 'password123')

    await expect(page).toHaveURL('/dashboard')
    await expect(page.getByTestId('welcome-message')).toContainText('Alice')
  })

  test('invalid credentials shows error', async ({ page }) => {
    const loginPage = new LoginPage(page)
    await loginPage.goto()
    await loginPage.login('bad@example.com', 'wrong')

    await expect(loginPage.errorMessage).toBeVisible()
    await expect(loginPage.errorMessage).toContainText('Invalid credentials')
  })
})
```

### playwright.config.ts

```ts
import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'Mobile Safari', use: { ...devices['iPhone 13'] } },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: !process.env.CI,
  },
})
```

---

## Nuxt Testing

### Setup with @nuxt/test-utils

```bash
npm install -D @nuxt/test-utils vitest @vue/test-utils happy-dom
```

```ts
// vitest.config.ts for Nuxt
import { defineVitestConfig } from '@nuxt/test-utils/config'

export default defineVitestConfig({
  test: {
    environment: 'nuxt',    // uses Nuxt-aware environment
    environmentOptions: {
      nuxt: {
        rootDir: '.',
        overrides: {
          ssr: false,      // disable SSR for component tests
        },
      },
    },
  },
})
```

### Testing Nuxt components with renderSuspended

```ts
import { describe, it, expect } from 'vitest'
import { renderSuspended } from '@nuxt/test-utils/runtime'
import { screen } from '@testing-library/vue'
import MyComponent from '@/components/MyComponent.vue'

describe('MyComponent', () => {
  it('renders correctly', async () => {
    await renderSuspended(MyComponent, {
      props: { title: 'Hello Nuxt' },
    })

    expect(screen.getByText('Hello Nuxt')).toBeDefined()
  })
})
```

### Testing Nuxt composables

```ts
import { describe, it, expect } from 'vitest'
import { mountSuspended } from '@nuxt/test-utils/runtime'
import { defineComponent } from 'vue'

describe('useMyNuxtComposable', () => {
  it('works with Nuxt context', async () => {
    const TestComponent = defineComponent({
      setup() {
        const state = useState('test', () => 'initial')
        return { state }
      },
      template: '<div>{{ state }}</div>',
    })

    const wrapper = await mountSuspended(TestComponent)
    expect(wrapper.text()).toBe('initial')
  })
})
```

---

## Common Testing Pitfalls

| Pitfall | Problem | Fix |
|---------|---------|-----|
| Not awaiting `nextTick` | DOM not updated after reactive change | `await nextTick()` or `await wrapper.vm.$nextTick()` after triggering updates |
| Not awaiting `flushPromises` | Async operations still pending | `await flushPromises()` after triggering async actions |
| Using `shallowMount` exclusively | Child component bugs hidden | Default to `mount()`, use `shallowMount` only for focused unit tests |
| Testing implementation details | Brittle tests that break on refactor | Test behavior and output, not internal refs or methods |
| Missing `setActivePinia` in store tests | Pinia has no active instance | Call `setActivePinia(createPinia())` in `beforeEach` |
| Forgetting `router.isReady()` | Navigation not complete | Await `router.isReady()` after `router.push()` in tests |
| Not cleaning up global mocks | Tests pollute each other | Use `afterEach(() => vi.restoreAllMocks())` or `vi.resetAllMocks()` |
| Querying by text that changes | Brittle to copy changes | Use `data-testid` attributes or ARIA roles for stable selectors |
