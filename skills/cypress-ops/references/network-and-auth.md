# Network Stubbing & Authentication

Deep dive on `cy.intercept` and `cy.session`. The SKILL.md body covers the 80% path;
this file is the rest.

## cy.intercept — matching

```ts
// String shorthand: method + url glob
cy.intercept('GET', '/api/users');
cy.intercept('POST', '/api/users', { statusCode: 201 });

// routeMatcher object — match on more than method+url
cy.intercept({
  method: 'GET',
  url: '/api/orders/*',
  query: { status: 'open' },        // match only when ?status=open
  headers: { 'x-tenant': 'acme' },
});

// Regex urls
cy.intercept(/\/api\/orders\/\d+$/);
```

Glob (`*` one segment, `**` many) is the default for string URLs; pass a `RegExp` for
precise control. A later `cy.intercept` for the same route **overrides** an earlier one
within the same test — define the most specific matcher first if both could match.

## cy.intercept — stubbing variants

```ts
// Fixture file (cypress/fixtures/users.json)
cy.intercept('GET', '/api/users', { fixture: 'users.json' });

// Inline body + status + headers
cy.intercept('GET', '/api/users', {
  statusCode: 200,
  body: [{ id: 1, name: 'Alice' }],
  headers: { 'cache-control': 'no-store' },
});

// Force network failure / latency / offline
cy.intercept('GET', '/api/slow', { forceNetworkError: true });
cy.intercept('GET', '/api/slow', (req) => { req.reply({ delay: 2000, body: {} }); });
```

## cy.intercept — spying & modifying (the function form)

The function form gives the request (`req`) for inspection/mutation; `req.reply` /
`req.continue` control the response.

```ts
// Spy only (no stub) — let it hit the server, just observe
cy.intercept('POST', '/api/cart').as('addToCart');
cy.get('[data-test=add]').click();
cy.wait('@addToCart').then(({ request, response }) => {
  expect(request.body).to.deep.equal({ sku: 'ABC', qty: 1 });
  expect(response?.statusCode).to.eq(200);
});

// Mutate the outgoing request
cy.intercept('GET', '/api/me', (req) => {
  req.headers['authorization'] = 'Bearer test-token';
  req.continue();                 // pass through to the real server
});

// Mutate the real response before it reaches the app
cy.intercept('GET', '/api/feed', (req) => {
  req.reply((res) => {
    res.body.items = res.body.items.slice(0, 1);   // truncate for a deterministic test
  });
});

// Conditionally stub vs passthrough
cy.intercept('GET', '/api/flags', (req) => {
  if (req.query.exp === 'B') req.reply({ body: { variant: 'B' } });
  else req.continue();
});
```

## GraphQL (single endpoint, many operations)

GraphQL POSTs everything to one URL, so match on the **operation name** in the body:

```ts
const hasOperation = (req, name) =>
  req.body?.operationName === name;

cy.intercept('POST', '/graphql', (req) => {
  if (hasOperation(req, 'GetUser')) {
    req.reply({ fixture: 'gql/getUser.json' });
  }
  if (hasOperation(req, 'ListOrders')) {
    req.alias = 'gqlListOrders';          // dynamic alias per operation
    req.reply({ fixture: 'gql/listOrders.json' });
  }
});
cy.wait('@gqlListOrders');
```

## Waiting on multiple / counted requests

```ts
cy.wait(['@getUsers', '@getOrders']);     // both must fire

// Nth occurrence of a repeated request
cy.wait('@getUsers');                     // 1st
cy.wait('@getUsers');                     // 2nd
```

---

## cy.session — full mechanics

```ts
cy.session(id, setup);
cy.session(id, setup, options);
```

| Param / option | Behaviour |
|----------------|-----------|
| `id` | String / Array / Object cache key. Arrays & objects are deterministically stringified. Same id → same cached session |
| `setup` | Runs **only on cache miss** (or when `validate` fails). Establishes the session (login) |
| `validate()` | Runs after setup **and** after every restore. Throw / failing assertion → session invalid. After-restore failure re-runs `setup`; after-setup failure fails the test |
| `cacheAcrossSpecs` | `false` (default) = session lives for the spec. `true` = global, restorable in any spec in the run |

**Always-cleared invariant:** cookies, `localStorage`, and `sessionStorage` in **all
domains** are cleared before `setup` runs, *regardless of `testIsolation`*. So `setup`
starts from a clean slate every cache miss.

**Assert a logged-in signal inside `setup` before it returns** — otherwise Cypress caches
a half-authenticated state and every restore is broken.

## Faster auth: skip the UI

UI login is slow and re-tests the login form on every session. Prefer a programmatic login
in `setup`:

```ts
Cypress.Commands.add('loginByApi', (username, password) => {
  cy.session([username, password], () => {
    cy.request('POST', '/api/login', { username, password }).then(({ body }) => {
      window.localStorage.setItem('auth_token', body.token);   // or set a cookie
    });
  }, {
    validate() { cy.window().its('localStorage.auth_token').should('exist'); },
    cacheAcrossSpecs: true,
  });
});
```

Keep **one** UI-driven login test that exercises the real form; everything else uses the
API path.

## Cross-origin: cy.origin

Cypress confines a test to one superdomain. To interact with another origin (SSO provider,
OAuth consent screen on a domain you control), wrap those steps in `cy.origin`:

```ts
cy.origin('https://auth.example.com', () => {
  cy.get('[data-test=email]').type('user@example.com');
  cy.get('[data-test=password]').type('secret');
  cy.get('[data-test=submit]').click();
});
```

Caveats: variables must be passed in via the `args` option (the callback runs in a separate
context — no closure access); `data-test` selectors and commands work, but custom commands
need re-registering inside or via `Cypress.require`. Avoid testing third-party social-login
UIs you don't control (captchas, A/B tests, throttling, bans) — stub them or use `cy.request`
against the provider's API instead.

## Seed-via-request, assert-via-UI

The fastest way to set up state: create it through the API, verify through the UI.

```ts
beforeEach(() => {
  cy.request('POST', '/api/test/reset');                       // reset server state
  cy.request('POST', '/api/projects', { name: 'Apollo' });     // seed
});

it('shows the seeded project', () => {
  cy.visit('/projects');
  cy.contains('[data-test=project]', 'Apollo').should('be.visible');
});
```
