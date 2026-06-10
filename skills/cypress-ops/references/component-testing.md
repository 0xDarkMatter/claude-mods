# Component Testing

Cypress Component Testing mounts a single component in a **real browser** (not jsdom) via a
bundler dev server — no app server, no navigation. You get the same time-travel debugging,
real CSS, and DevTools as E2E, scoped to one component.

## Supported matrix

| Framework | Versions | Bundlers |
|-----------|----------|----------|
| React | 18–19 | Vite 5–8, webpack 5 |
| Vue | 3 | Vite 5–8, webpack 5 |
| Angular | 18–21 | webpack 5 |
| Svelte | 5 | Vite 5–8, webpack 5 |
| Next.js | 14–16 | webpack 5 |

Configure under `component.devServer` — Cypress infers most of the dev-server wiring:

```ts
// cypress.config.ts
import { defineConfig } from 'cypress';

export default defineConfig({
  component: {
    devServer: {
      framework: 'react',     // 'react' | 'vue' | 'angular' | 'svelte' | 'next' | 'nuxt' | ...
      bundler: 'vite',        // 'vite' | 'webpack'
    },
    specPattern: 'src/**/*.cy.{ts,tsx,js,jsx}',
  },
});
```

## Registering cy.mount

`cy.mount` is **not** built in — register it once in the component support file so every
spec gets it (and so types resolve):

```ts
// cypress/support/component.ts  (React)
import { mount } from 'cypress/react';
import './commands';

Cypress.Commands.add('mount', mount);

declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof mount;
    }
  }
}
```

Swap the import per framework: `cypress/react`, `cypress/vue`, `cypress/angular`,
`cypress/svelte`.

## Mounting per framework

```tsx
// React — JSX, props inline
cy.mount(<Stepper initial={5} onChange={cy.stub().as('onChange')} />);

// Vue 3 — props/slots via options object
cy.mount(Stepper, {
  props: { count: 100 },
  slots: { default: 'Label text' },
});

// Angular — component class + config object
cy.mount(StepperComponent, {
  componentProperties: { count: 100 },
});

// Svelte 5
cy.mount(Stepper, { props: { count: 100 } });
```

## Asserting props, events, slots

Spy on callbacks with `cy.stub().as(...)`, drive the component through the DOM, assert the
spy fired:

```tsx
it('emits on increment', () => {
  cy.mount(<Stepper initial={0} onChange={cy.stub().as('onChange')} />);
  cy.get('[data-test=increment]').click();
  cy.get('[data-test=count]').should('have.text', '1');
  cy.get('@onChange').should('have.been.calledWith', 1);
});
```

## Mocking stores / router / context

Components that consume a store, router, or context need a provider wrapper at mount.
Compose it in a local helper so specs stay clean:

```tsx
// React — wrap in providers
function mountWithProviders(ui: React.ReactNode, { route = '/' } = {}) {
  window.history.pushState({}, '', route);
  return cy.mount(
    <MemoryRouter initialEntries={[route]}>
      <QueryClientProvider client={new QueryClient()}>{ui}</QueryClientProvider>
    </MemoryRouter>,
  );
}
```

```ts
// Vue — global plugins/stubs
cy.mount(UserCard, {
  global: {
    plugins: [createTestingPinia()],
    stubs: { RouterLink: true },
  },
});
```

## Network in component tests

`cy.intercept` works in component tests exactly as in E2E — stub the component's data
fetches:

```tsx
cy.intercept('GET', '/api/user/1', { fixture: 'user.json' }).as('getUser');
cy.mount(<UserProfile id={1} />);
cy.wait('@getUser');
cy.get('[data-test=name]').should('have.text', 'Alice');
```

## When component vs E2E

| Test it as a **component** when… | Test it **E2E** when… |
|----------------------------------|------------------------|
| Verifying props/events/slots in isolation | Verifying a multi-page user flow |
| Exercising many edge states (loading/error/empty) cheaply | Auth, routing, real backend integration |
| Visual states of one component | Cross-component / cross-page behaviour |
| No server or navigation required | The app must actually be running |

A healthy suite uses **component tests for breadth** (many states, fast) and **E2E for the
critical user journeys** — not E2E for everything.
