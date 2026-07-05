---
name: cypress-ops
description: "Cypress end-to-end and component testing operations - selector/retry-ability strategy, cy.intercept network stubbing, cy.session auth, component vs e2e, flake diagnosis, CI, Test Replay. Use for: cypress, e2e test, component test, cy.get, cy.intercept, cy.session, data-cy, data-test, retry-ability, flake, flaky test, cypress.config, cy.mount, Test Replay, custom commands, fixtures."
when_to_use: "Use when writing or fixing Cypress e2e/component tests — e.g. 'pick stable selectors and data-cy', 'stub network with cy.intercept', 'share login with cy.session', 'diagnose a flaky retry-ability test'. For Playwright or other runners, use playwright-ops / testing-ops."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "playwright-ops, testing-ops, ci-cd-ops"
---

# Cypress Operations

> Facts verified as of 2026-07.

**Version context (verified against docs.cypress.io, 2026-06):** Cypress 14.x, Test
Replay (v13+), `cy.session` with `cacheAcrossSpecs`. APIs move — confirm against the live
docs when a detail is load-bearing.

End-to-end and component testing with Cypress (`cypress`, TS/JS). The runner executes
tests *inside* a real browser via the **Cypress App** (`cypress open`) or headlessly
(`cypress run`). The defining mental model: **`cy.*` commands are not promises** — they
enqueue onto an async command chain that Cypress drains for you. Internalise that and the
agentic gotchas below disappear.

## Quick Start

```bash
npm install -D cypress
npx cypress open                  # launch the Cypress App: pick E2E or Component, real browser
npx cypress run                   # headless run, all specs (CI default)
npx cypress run --spec "cypress/e2e/auth/*.cy.ts"
npx cypress run --component       # run component specs
npx cypress run --browser chrome --headed
npx cypress run --record --key <k>  # upload to Cypress Cloud (enables Test Replay, v13+)
```

Specs live in `cypress/e2e/**/*.cy.ts` (E2E) and beside components or `cypress/component/`
(component). Config is a single `cypress.config.ts` at the repo root.

## The Async Command Queue (read this first)

`cy.get(...)` returns a **Chainer**, not the element and not a Promise. Commands are
*scheduled*, then run in order after the test function returns. This is the source of
nearly every Cypress mistake an agent makes.

```ts
// WRONG — cy.get does not return a value; `el` is a Chainer, this is meaningless
const el = cy.get('[data-test=total]');
if (el.text() === '$0') { /* never works */ }

// WRONG — async/await does nothing useful; cy commands aren't awaitable promises
const text = await cy.get('[data-test=total]');   // do NOT do this

// RIGHT — yield the value into a callback; assertions inside .should() retry
cy.get('[data-test=total]').should('have.text', '$0');

// RIGHT — need the raw value? use .then() (but it does NOT retry — see below)
cy.get('[data-test=total]').invoke('text').then((text) => {
  // text is a string here; runs after the queue reaches this point
});
```

Rules that follow from this:
- **No `const`/`let` to "store" a command result.** Use `.as()` aliases + `cy.get('@alias')`.
- **No `async/await` on `cy.*`.** The queue handles ordering. Mixing in real promises?
  wrap them with `cy.then(() => promise)` or `cy.wrap(promise)`.
- **No `if/else` on element state read synchronously.** Conditional testing is an
  anti-pattern in Cypress (the DOM may not have settled); make the app deterministic, or
  drive the branch off a server/`cy.intercept` state you control. Deep dive:
  [references/network-and-auth.md](references/network-and-auth.md).

## Retry-ability (why you almost never need waits)

Cypress retries **queries** and **assertions** until they pass or the command times out
(default 4s). It does **not** retry **actions** (`.click()`, `.type()`, `.select()`) —
those fire once, though the queries *leading up to* them retry until the element is
actionable (visible, not disabled, not animating).

| Construct | Retries? | Use for |
|-----------|----------|---------|
| `cy.get` / `.find` / `.contains` / `.its` / `.invoke` (queries) | Yes — whole chain re-queries | Locating/reading DOM that may not be ready |
| `.should(...)` / `expect` inside it | Yes — the callback re-runs | Assertions; conditional waits on settled state |
| `.click` / `.type` / `.select` (actions) | No — fire once | Interactions (leading queries still retry) |
| `.then(cb)` | **No** — runs once, no retry protection | Extracting a value; NOT for assertions |

```ts
// .should(callback) retries the whole callback — safe for racy DOM
cy.get('[data-test=rows] li').should(($li) => {
  expect($li).to.have.length(3);
  expect($li.first()).to.contain('Alice');
});

// .then() does NOT retry — capturing $el here then asserting later races the render
```

If you reach for `cy.wait(3000)`, you're missing an assertion or an aliased intercept.
The only legitimate `cy.wait` takes an **alias** (`cy.wait('@getUsers')`), never a number.

## Selector Strategy

**Prefer a dedicated test attribute over CSS classes, IDs, or tag names** — the latter are
brittle and change with styling/refactors. Cypress recommends `data-cy` **or** `data-test`
(the Cypress Real World App standardises on **`data-test`**); pick one and enforce it.

```ts
// GOOD — decoupled from styling and structure
cy.get('[data-test=submit]').click();

// AVOID — couples the test to CSS/markup that changes for non-test reasons
cy.get('.btn-primary').click();
cy.get('#submit').click();
```

Wrap the convention in a custom command so specs stay terse:

```ts
// cypress/support/commands.ts
Cypress.Commands.add('getBySel', (sel, ...args) =>
  cy.get(`[data-test=${sel}]`, ...args));
Cypress.Commands.add('getBySelLike', (sel, ...args) =>
  cy.get(`[data-test*=${sel}]`, ...args));  // substring match
// usage: cy.getBySel('submit').click();
```

Reserve `cy.contains('Log In')` for when the **visible text itself** is what you're
asserting; otherwise it couples tests to copy.

## Network Stubbing — `cy.intercept`

`cy.intercept` is the single API for spying on and stubbing network traffic. **Set it up
before the action that triggers the request**, alias it, then wait on the alias.

```ts
// Stub with a fixture, alias, wait
cy.intercept('GET', '/api/users', { fixture: 'users.json' }).as('getUsers');
cy.visit('/users');
cy.wait('@getUsers');                       // resolves when the request fires

// Inline body / status
cy.intercept('POST', '/api/login', { statusCode: 401, body: { error: 'nope' } }).as('login');

// routeMatcher object (method + glob/regex url) + dynamic reply
cy.intercept({ method: 'GET', url: '/api/orders/*' }, (req) => {
  req.reply((res) => { res.body.hasMore = false; });   // tweak the real response
}).as('orders');

// Assert against the captured request/response
cy.wait('@login').its('response.statusCode').should('eq', 401);

// Wait on several at once
cy.wait(['@getUsers', '@orders']);
```

**Stub what you don't own, exercise what you do.** Stubbing third-party/slow endpoints
makes tests fast and deterministic; hitting your real backend (seeded via `cy.request`)
verifies the client↔server contract. Decide per endpoint. GraphQL, request modification,
and seed-via-`cy.request` patterns: [references/network-and-auth.md](references/network-and-auth.md).

## Authentication — `cy.session`

Log in **once**, cache the session, restore it across tests (and optionally specs). This is
the biggest suite-speed win after stubbing.

```ts
// cypress/support/commands.ts
Cypress.Commands.add('login', (username: string, password: string) => {
  cy.session(
    [username, password],                   // cache key — array/object is stringified
    () => {                                  // setup: runs only on cache miss
      cy.visit('/login');
      cy.get('[data-test=name]').type(username);
      cy.get('[data-test=password]').type(password);
      cy.get('form').contains('Log In').click();
      cy.url().should('contain', '/dashboard');   // assert logged-in before caching!
    },
    {
      validate() {                           // runs after setup AND after each restore
        cy.getCookie('auth_token').should('exist');  // invalid -> setup re-runs
      },
      cacheAcrossSpecs: true,                // default false; true = reuse in every spec
    },
  );
});
```

Critical behaviour: **cookies, `localStorage`, and `sessionStorage` across all domains are
cleared before `setup` runs, regardless of `testIsolation`.** Faster still: skip the UI and
log in via `cy.request` inside `setup`, persisting the token. Patterns (API login, token
priming, `cy.origin` for cross-origin SSO): [references/network-and-auth.md](references/network-and-auth.md).

## Component vs E2E Testing

Same runner, two testing types. **E2E** drives a deployed app through `cy.visit`.
**Component** mounts a single component in a real browser via `cy.mount` — no server, no
navigation, props/events under direct control.

| | E2E | Component |
|---|---|---|
| Entry | `cy.visit('/path')` | `cy.mount(<Comp/>)` |
| Needs running app server | Yes | No (bundler dev server only) |
| Spec location | `cypress/e2e/**/*.cy.ts` | beside the component / `cypress/component/` |
| Support file | `cypress/support/e2e.ts` | `cypress/support/component.ts` (registers `cy.mount`) |
| Best for | User flows, integration, auth | Props/events/slots, edge states, visual |

```ts
// cypress/support/component.ts  (React example)
import { mount } from 'cypress/react';
Cypress.Commands.add('mount', mount);

// Button.cy.tsx
cy.mount(<Button label="Save" onClick={cy.stub().as('onClick')} />);
cy.get('[data-test=button]').click();
cy.get('@onClick').should('have.been.calledOnce');
```

Frameworks: React 18–19, Vue 3, Angular 18–21, Svelte 5. Bundlers: Vite 5–8 (React/Vue/
Svelte) or webpack 5 (all + Next.js). Configured under `component.devServer.{framework,bundler}`.
Mounting per framework, store/router mocking, slots: [references/component-testing.md](references/component-testing.md).

## Test Isolation, Fixtures, Custom Commands

- **`testIsolation: true`** (default, E2E) clears cookies/storage and resets to `about:blank`
  before each test. Each test must pass run **in isolation** (`it.only` to verify) — never
  rely on a previous test's state. Reset *server-side* state in `beforeEach`, not `afterEach`
  (an `after` hook may not run if you refresh mid-test).
- **Multiple assertions per test are fine** — don't split into one-assertion tests; state
  reset between tests costs more than extra assertions.
- **Fixtures** are static JSON in `cypress/fixtures/`, loaded by `cy.fixture('users.json')`
  or referenced directly in `cy.intercept(..., { fixture: 'users.json' })`.
- **Custom commands** (`Cypress.Commands.add`) live in `cypress/support/commands.ts`; add
  the `cypress/react` (etc.) types and a `declare global` block for TS autocomplete.

## CI

```yaml
# GitHub Actions — the official cypress-io/github-action handles install + cache + run
- uses: actions/checkout@v5
- uses: cypress-io/github-action@v6
  with:
    build: npm run build
    start: npm start                 # boots app, waits on baseUrl before running
    wait-on: 'http://localhost:3000'
    browser: chrome
    record: true                     # upload to Cypress Cloud (Test Replay)
  env:
    CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
```

| Decision | Guidance |
|----------|----------|
| Start the app | Start it **before** Cypress (`start` + `wait-on`), kill after — never `cy.exec` a server mid-test |
| Parallelism | `cypress run --record --parallel` splits specs across machines — **requires Cypress Cloud** (paid). Free alternative: shard specs manually across matrix jobs with `--spec` |
| Retries | Config `retries: { runMode: 2, openMode: 0 }` — surface flakes as a queue, don't paper over them |
| Debugging CI failures | **Test Replay** (v13+, Chromium-only) over video: captures DOM, network, console, errors for time-travel debugging in Cloud |

Full workflows (matrix sharding, containers, artifact upload): [references/ci-and-flake.md](references/ci-and-flake.md).

## Flake Diagnosis

Most Cypress flake traces to one of: an action chained where a query/assertion belonged, a
missing aliased `cy.wait`, conditional logic on un-settled DOM, or leaked state between tests.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| "element detached from DOM" | re-render between query and action | split the chain; let the action's leading query retry |
| passes alone, fails in suite | inter-test state coupling | reset server state in `beforeEach`; `it.only` to confirm |
| `cy.wait(number)` "fixes" it | racing the network | replace with `cy.intercept(...).as()` + `cy.wait('@alias')` |
| value read with `.then()` is stale | `.then` doesn't retry | move the assertion into `.should(cb)` |

Diagnosis tooling (Test Replay, `cypress run --headed`, time-travel in the App, screenshots/
video), retry config, and a systematic playbook: [references/ci-and-flake.md](references/ci-and-flake.md).

## Cypress vs Playwright (one-table decision)

| Factor | Cypress | Playwright |
|--------|---------|-----------|
| Execution model | In-browser, async command queue (no `await`) | Out-of-process, real `async/await` |
| Browsers | Chrome-family, Firefox, Electron; WebKit experimental | Chromium, Firefox, **WebKit (real Safari)** |
| Parallelism | Cypress Cloud (paid) or manual sharding | Free, built-in, shardable |
| Multi-tab / multi-origin | Constrained (`cy.origin` for cross-origin) | Native |
| Component testing | **Mature, first-class** | Experimental |
| Interactive DX | The original benchmark (Cypress App, time-travel) | UI mode (excellent) |
| API testing | `cy.request` / `cy.intercept` | Built-in `request` context |

Reach for **Cypress** when component-testing maturity, an existing Cypress investment, or its
in-browser DX dominate. Default to **Playwright** for new E2E needing WebKit, free parallelism,
or heavy multi-tab/multi-origin work. Sibling skill: `playwright-ops`.

## Config Skeleton

Full commented production template: [assets/cypress.config.template.ts](assets/cypress.config.template.ts)

```ts
import { defineConfig } from 'cypress';

export default defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',        // cy.visit('/path') resolves against this
    specPattern: 'cypress/e2e/**/*.cy.{ts,tsx}',
    retries: { runMode: 2, openMode: 0 },    // retry in CI only
    setupNodeEvents(on, config) { return config; },
  },
  component: {
    devServer: { framework: 'react', bundler: 'vite' },
  },
  // testIsolation defaults true; viewportWidth/Height, defaultCommandTimeout tunable here
});
```

## References

| File | Contents |
|------|----------|
| [references/network-and-auth.md](references/network-and-auth.md) | `cy.intercept` matching/modifying/GraphQL, `cy.session` deep dive, API login, `cy.origin`, seed-via-request |
| [references/component-testing.md](references/component-testing.md) | Per-framework `cy.mount`, store/router/context mocking, slots/events, Vite vs webpack config |
| [references/ci-and-flake.md](references/ci-and-flake.md) | Full GH Actions workflows, sharding, Test Replay, retry config, systematic flake playbook |
| [assets/cypress.config.template.ts](assets/cypress.config.template.ts) | Commented production config template (E2E + component) |
